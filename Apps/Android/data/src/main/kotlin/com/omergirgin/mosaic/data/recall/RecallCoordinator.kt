package com.omergirgin.mosaic.data.recall

import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.context.utf8Length
import com.omergirgin.mosaic.core.net.embeddings.EmbeddingClient
import com.omergirgin.mosaic.core.net.embeddings.EmbeddingClientFactory
import com.omergirgin.mosaic.core.net.embeddings.EmbeddingInputFormatter
import com.omergirgin.mosaic.core.net.embeddings.EmbeddingPurpose
import com.omergirgin.mosaic.core.provider.supportsEmbeddings
import com.omergirgin.mosaic.core.retrieval.EmbeddingMath
import com.omergirgin.mosaic.core.retrieval.EmbeddingVectorCodec
import com.omergirgin.mosaic.core.retrieval.HybridMemoryRetriever
import com.omergirgin.mosaic.core.retrieval.LocalRetrievalPreparation
import com.omergirgin.mosaic.core.retrieval.RecallQuery
import com.omergirgin.mosaic.core.retrieval.RetrievalAttributes
import com.omergirgin.mosaic.core.retrieval.RetrievalCandidate
import com.omergirgin.mosaic.core.retrieval.RetrievalSourceKind
import com.omergirgin.mosaic.core.retrieval.RetrievedContext
import com.omergirgin.mosaic.core.retrieval.SemanticScoreSet
import com.omergirgin.mosaic.core.retrieval.SmartMemoryRanker
import com.omergirgin.mosaic.data.db.CanonicalMessageRow
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.embeddings.AuthenticatedProfile
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfileEntity
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfilePolicy
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfileResolver
import com.omergirgin.mosaic.data.embeddings.EmbeddingUsageRecorder
import com.omergirgin.mosaic.data.embeddings.embeddingBatches
import com.omergirgin.mosaic.data.index.SemanticVectorStore
import com.omergirgin.mosaic.data.index.VectorWrite
import com.omergirgin.mosaic.data.repo.ProviderRepositoryImpl
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** One selected excerpt and the source that must revalidate it before the request. */
internal class SelectedRecall(val candidate: RecallCandidate, val source: RecallCandidateSource)

/** Recall prepared for one chat request. */
internal class PreparedRecall(
  /** Rendered `<mosaic_recalled_context>` block, or null when nothing was recalled. */
  val systemContent: String?,
  /** null when recall had nothing to disclose (no items, destinations or warnings). */
  val receipt: RecallReceipt?,
  val scope: RecallScope?,
  val selected: List<SelectedRecall>,
) {
  val hasExcerpts: Boolean get() = !systemContent.isNullOrEmpty()

  /** iOS layer order: curated memory first, then recalled context. */
  fun appendTo(memoryContent: String?): String? =
    listOfNotNull(memoryContent?.takeIf { it.isNotEmpty() }, systemContent?.takeIf { it.isNotEmpty() })
      .joinToString("\n\n")
      .ifEmpty { null }

  /** Drops every excerpt (keeping destinations and warnings for the receipt). */
  fun withoutExcerpts(warning: String): PreparedRecall {
    val base = receipt ?: RecallReceipt(emptyList(), listOf(LOCAL_ENGINE), emptyList(), emptyList())
    return PreparedRecall(null, base.copy(items = emptyList(), warnings = base.warnings + warning), scope, emptyList())
  }

  companion object {
    val NONE = PreparedRecall(null, null, null, emptyList())
    const val LOCAL_ENGINE = "Local hybrid"
    const val DID_NOT_FIT_WARNING =
      "Recalled excerpts did not fit this model's context window, so Turing AI sent the request without them."
    const val STALE_BEFORE_SEND_WARNING =
      "Some recalled sources changed before the request was sent, so Turing AI omitted recalled excerpts."
  }
}

/**
 * Port of iOS `SemanticMemoryCoordinator`: snapshots every registered source for the request's
 * audience, builds the 96-item local pool, optionally lets the selected chat model rank up to 40
 * of them (smart memory, see [SmartMemoryRecall]), otherwise runs up to four embedding profiles in
 * parallel (each an isolated vector space, lazily filling missing vectors), fuses rankings, and revalidates
 * the selected excerpts. Recall never blocks sending: every failure degrades to local lexical
 * recall with a receipt warning. Without an enabled profile the vector store is never opened.
 */
internal class RecallCoordinator(
  private val db: MosaicDatabase,
  private val registry: RecallSourceRegistry,
  private val resolver: EmbeddingProfileResolver,
  private val vectors: SemanticVectorStore,
  private val usage: EmbeddingUsageRecorder,
  private val retriever: HybridMemoryRetriever = HybridMemoryRetriever(),
  private val jobTimeoutMillis: Long = 15_000,
  /** Optional smart memory stage (model relevance check); null disables it. */
  private val smartMemory: SmartMemoryRecall? = null,
) {
  private val dao = db.recall()

  /**
   * Recall for the newest user turn in [history] (the request being prepared). [rankingConnection]
   * is the interactive chat's authenticated connection for smart memory; unattended callers
   * (scheduled prompts) pass null, like iOS.
   */
  suspend fun prepare(
    conversationId: String,
    projectId: String?,
    history: List<CanonicalMessageRow>,
    rankingConnection: ProviderConnection? = null,
  ): PreparedRecall {
    val userTurns = history.filter { it.role == ChatRole.USER.rawValue }.map { it.content.trim() }
    val current = userTurns.lastOrNull().orEmpty()
    if (current.isEmpty()) return PreparedRecall.NONE
    return prepare(RecallScope(conversationId, projectId), RecallQuery.make(current, userTurns), rankingConnection)
  }

  suspend fun prepare(scope: RecallScope, query: String, rankingConnection: ProviderConnection? = null): PreparedRecall {
    val smart = SmartRankingSlot()
    return prepareRanked(scope, query, rankingConnection, smart).withSmartRanking(smart.outcome)
  }

  private suspend fun prepareRanked(
    scope: RecallScope,
    query: String,
    rankingConnection: ProviderConnection?,
    smart: SmartRankingSlot,
  ): PreparedRecall {
    var snapshot: Snapshot? = null
    var preparation: LocalRetrievalPreparation? = null
    val destinations = ArrayList<RecallEmbeddingDestination>()
    try {
      val currentSnapshot = snapshot(scope)
      snapshot = currentSnapshot
      if (currentSnapshot.entries.isEmpty()) return disclosure(currentSnapshot.warnings, destinations)
      val check = cancellationCheck()
      val prepared = withContext(Dispatchers.Default) {
        retriever.prepare(query, currentSnapshot.entries.map { it.core }, MAXIMUM_LOCAL_POOL, check)
      }
      preparation = prepared
      val warnings = ArrayList(currentSnapshot.warnings)

      // Smart memory (iOS order): one bounded relevance check with the selected chat model before
      // embeddings. A validated selection replaces embedding ranking; any failure falls through.
      if (rankingConnection != null && smartMemory != null && smartMemory.isEnabled()) {
        val pool = SmartMemoryRanker.pool(prepared.candidatePool, rankingConnection.contextWindowTokens)
        if (pool.isNotEmpty()) {
          val poolEntries = pool.mapNotNull { currentSnapshot.byId[it.id] }
          val outcome = smartMemory.rank(scope.conversationId, query, pool, rankingConnection) {
            val ids = poolEntries.mapTo(HashSet()) { it.candidate.id }
            poolEntries.size == pool.size &&
              validIds(scope, poolEntries.map { SelectedRecall(it.candidate, it.source) }) == ids
          }
          smart.outcome = outcome
          warnings += outcome.warning
          val scores = outcome.scores
          if (scores != null) {
            val ranked = Snapshot(
              currentSnapshot.entries.filter { it.candidate.id in scores.scores },
              currentSnapshot.warnings,
            )
            return validated(scope, query, ranked, listOf(scores), prepared, warnings, destinations)
          }
        }
      }

      val profiles = db.embeddingProfiles().enabled(EmbeddingProfilePolicy.MAXIMUM_ENABLED_PROFILES)
      // Semantic recall disabled: never initialize the rebuildable vector store.
      if (profiles.isEmpty()) return validated(scope, query, currentSnapshot, emptyList(), prepared, warnings, destinations)
      if (db.embeddingProfiles().enabledCount() > EmbeddingProfilePolicy.MAXIMUM_ENABLED_PROFILES) {
        warnings += "Only the four most recently updated embedding profiles were used for this request."
      }

      val poolIds = prepared.candidatePool.mapTo(HashSet()) { it.id }
      val jobs = ArrayList<EmbeddingJob>()
      for (profile in profiles) {
        currentCoroutineContext().ensureActive()
        val provider = resolver.provider(profile)
        if (provider == null || !provider.isEnabled) {
          warnings += "${profile.displayName} is not connected to an enabled provider."
          continue
        }
        if (!ProviderRepositoryImpl.kindOf(provider).supportsEmbeddings) {
          warnings += "${provider.displayName} does not expose a compatible embedding API."
          continue
        }
        val eligible = currentSnapshot.entries.filter { isEligible(it.candidate.kind, profile) }
        if (eligible.isEmpty()) continue
        val auth = try {
          resolver.authenticate(profile, provider)
        } catch (error: CancellationException) {
          throw error
        } catch (error: Exception) {
          warnings += "${profile.displayName} could not read its provider key: ${error.message ?: "the key is unavailable."}"
          continue
        }
        jobs += EmbeddingJob(
          auth = auth,
          client = EmbeddingClientFactory.make(auth.connection),
          query = query,
          candidates = eligible,
          pool = eligible.filter { it.candidate.id in poolIds },
        )
      }
      if (jobs.isEmpty()) return validated(scope, query, currentSnapshot, emptyList(), prepared, warnings, destinations)

      for (job in jobs) {
        destinations += RecallEmbeddingDestination(
          profileName = job.auth.profile.displayName,
          providerName = job.auth.provider.displayName,
          providerKind = job.auth.connection.provider.rawId,
          host = job.auth.connection.destinationHost,
          modelId = job.auth.modelId,
        )
      }
      val results = coroutineScope { jobs.map { job -> async { run(job, scope) } }.awaitAll() }
      if (vectors.isTemporary) {
        warnings += "The persistent vector cache was unavailable, so this session is using a temporary index."
      }
      currentCoroutineContext().ensureActive()

      val scoreSets = ArrayList<SemanticScoreSet>()
      for (result in results.sortedBy { it.job.auth.profile.id }) {
        result.warning?.let { warnings += it }
        if (result.scores.isEmpty() && result.writes.isEmpty()) continue
        if (!resolver.isCurrent(result.job.auth)) {
          warnings += "${result.job.auth.profile.displayName} changed before recall completed; its stale result was ignored."
          continue
        }
        if (result.scores.isNotEmpty()) {
          scoreSets += SemanticScoreSet(result.job.auth.profile.displayName, result.job.auth.profile.weight, result.scores)
        }
        persist(result, scope, warnings)
      }
      return validated(scope, query, currentSnapshot, scoreSets, prepared, warnings, destinations)
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      val warning = "Automatic recall fell back because the local index could not be read."
      val fallbackSnapshot = snapshot
      val fallbackPreparation = preparation
      if (fallbackSnapshot == null || fallbackPreparation == null) return disclosure(listOf(warning), destinations)
      return try {
        validated(scope, query, fallbackSnapshot, emptyList(), fallbackPreparation, listOf(warning), destinations)
      } catch (inner: CancellationException) {
        throw inner
      } catch (inner: Exception) {
        disclosure(listOf(warning), destinations)
      }
    }
  }

  /** Final check right before the provider call: every selected excerpt is still current. */
  suspend fun isCurrent(prepared: PreparedRecall): Boolean {
    if (prepared.selected.isEmpty()) return true
    val scope = prepared.scope ?: return false
    val ids = prepared.selected.map { it.candidate.id }
    if (ids.toSet().size != ids.size) return false
    return try {
      validIds(scope, prepared.selected) == ids.toSet()
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      false
    }
  }

  /** [prepared] when still current, else the same recall without excerpts and with a warning. */
  suspend fun revalidated(prepared: PreparedRecall): PreparedRecall =
    if (!prepared.hasExcerpts || isCurrent(prepared)) prepared
    else prepared.withoutExcerpts(PreparedRecall.STALE_BEFORE_SEND_WARNING)

  // region snapshot

  private class Entry(val candidate: RecallCandidate, val source: RecallCandidateSource, val core: RetrievalCandidate)

  private class Snapshot(val entries: List<Entry>, val warnings: List<String>) {
    val byId: Map<String, Entry> = entries.associateBy { it.candidate.id }
  }

  private suspend fun snapshot(scope: RecallScope): Snapshot {
    val entries = ArrayList<Entry>()
    val seen = HashSet<String>()
    val warnings = ArrayList<String>()
    for (source in registry.snapshot()) {
      currentCoroutineContext().ensureActive()
      val candidates = try {
        source.candidates(scope)
      } catch (error: CancellationException) {
        throw error
      } catch (error: Exception) {
        if (warnings.isEmpty()) warnings += "Some recall sources could not be read; recall used the remaining sources."
        continue
      }
      // Defensive per-lane ceilings for registered sources.
      var bytes = 0L
      var count = 0
      for (candidate in candidates) {
        if (count >= RecallLimits.MAXIMUM_CANDIDATES_PER_SOURCE) break
        if (candidate.text.isBlank() || !seen.add(candidate.id)) continue
        bytes += utf8Length(candidate.text)
        if (bytes > RecallLimits.MAXIMUM_CANDIDATE_UTF8_BYTES_PER_SOURCE) break
        entries += Entry(candidate, source, candidate.toCore())
        count += 1
      }
    }
    return Snapshot(entries, warnings)
  }

  private fun RecallCandidate.toCore() = RetrievalCandidate(
    id = id,
    kind = when (kind) {
      RecallSourceKind.CONVERSATION_MESSAGE -> RetrievalSourceKind.CONVERSATION_MESSAGE
      RecallSourceKind.DOCUMENT_CHUNK -> RetrievalSourceKind.DOCUMENT_CHUNK
      RecallSourceKind.MEMORY_TOPIC -> RetrievalSourceKind.MEMORY_TOPIC
    },
    containerId = containerId,
    title = title?.takeIf { it.isNotBlank() } ?: defaultTitle(kind),
    content = text,
    createdAt = createdAt,
    attributes = attributes,
    confidence = confidence,
    importance = importance,
    weight = if (weight.isFinite()) weight else 1.0,
  )

  private fun defaultTitle(kind: RecallSourceKind): String = when (kind) {
    RecallSourceKind.CONVERSATION_MESSAGE -> "Earlier conversation"
    RecallSourceKind.DOCUMENT_CHUNK -> "Imported document"
    RecallSourceKind.MEMORY_TOPIC -> "Memory"
  }

  // endregion

  // region validation

  /** IDs still current for [scope]; empty when the chat itself left the audience. */
  private suspend fun validIds(scope: RecallScope, selected: List<SelectedRecall>): Set<String> {
    if (selected.isEmpty()) return emptySet()
    val conversation = dao.conversationScope(scope.conversationId) ?: return emptySet()
    if (conversation.projectId != scope.projectId) return emptySet()
    val valid = HashSet<String>()
    for ((source, group) in selected.groupBy { it.source }) {
      currentCoroutineContext().ensureActive()
      val candidates = group.map { it.candidate }
      val ids = try {
        source.validate(scope, candidates)
      } catch (error: CancellationException) {
        throw error
      } catch (error: Exception) {
        emptySet()
      }
      candidates.mapNotNullTo(valid) { it.id.takeIf { id -> id in ids } }
    }
    return valid
  }

  private suspend fun validated(
    scope: RecallScope,
    query: String,
    snapshot: Snapshot,
    scoreSets: List<SemanticScoreSet>,
    preparation: LocalRetrievalPreparation,
    warnings: List<String>,
    destinations: List<RecallEmbeddingDestination>,
  ): PreparedRecall {
    var current = snapshot.entries
    val currentWarnings = ArrayList(warnings)
    val check = cancellationCheck()
    // At most six items can be selected; rechecking after each removal keeps a newly surfaced
    // stale item from replacing a stale top result indefinitely.
    repeat(MAXIMUM_ITEMS + 1) {
      val candidates = current.map { it.core }
      val context = withContext(Dispatchers.Default) {
        retriever.retrieve(query, candidates, scoreSets, preparation.scores, currentWarnings, check)
      }
      if (context.items.isEmpty()) return build(context, scope, emptyList(), destinations)
      val selected = context.items.mapNotNull { item ->
        snapshot.byId[item.candidate.id]?.let { SelectedRecall(it.candidate, it.source) }
      }
      val valid = validIds(scope, selected)
      val invalid = selected.map { it.candidate.id }.filterTo(HashSet()) { it !in valid }
      if (invalid.isEmpty() && selected.size == context.items.size) return build(context, scope, selected, destinations)
      current = current.filter { it.candidate.id !in invalid }
      if (currentWarnings.none { it.contains("changed while recall was running") }) {
        currentWarnings += "Some recalled sources changed while recall was running, so Turing AI excluded their stale excerpts."
      }
    }
    return disclosure(
      currentWarnings + "Recall changed repeatedly during this request, so Turing AI omitted retrieved excerpts.",
      destinations,
    )
  }

  private fun build(
    context: RetrievedContext,
    scope: RecallScope,
    selected: List<SelectedRecall>,
    destinations: List<RecallEmbeddingDestination>,
  ): PreparedRecall {
    val items = context.items.map { item ->
      val candidate = item.candidate
      RecalledItem(
        kind = when (candidate.kind) {
          RetrievalSourceKind.CONVERSATION_MESSAGE -> RecallSourceKind.CONVERSATION_MESSAGE
          RetrievalSourceKind.DOCUMENT_CHUNK -> RecallSourceKind.DOCUMENT_CHUNK
          RetrievalSourceKind.MEMORY_TOPIC -> RecallSourceKind.MEMORY_TOPIC
        },
        id = candidate.id,
        containerId = candidate.containerId,
        title = candidate.title,
        excerpt = candidate.content,
        pageNumber = candidate.pageNumber,
        isOcrDerived = candidate.isOcrDerived,
        isEvent = candidate.isEvent,
        recordedAt = if (candidate.isEvent) {
          candidate.attributes[RetrievalAttributes.RECORDED_AT] ?: HybridMemoryRetriever.iso8601(candidate.createdAt)
        } else {
          null
        },
        createdAt = candidate.createdAt,
        relevance = item.relevance,
      )
    }
    if (items.isEmpty() && context.warnings.isEmpty() && destinations.isEmpty()) return PreparedRecall.NONE
    val receipt = RecallReceipt(
      items = items,
      engines = listOf(PreparedRecall.LOCAL_ENGINE) + context.embeddingProfilesUsed,
      embeddingDestinations = destinations,
      warnings = context.warnings,
    )
    return PreparedRecall(context.systemContent.takeIf { items.isNotEmpty() }, receipt, scope, selected)
  }

  private fun disclosure(warnings: List<String>, destinations: List<RecallEmbeddingDestination>): PreparedRecall {
    if (warnings.isEmpty() && destinations.isEmpty()) return PreparedRecall.NONE
    return PreparedRecall(
      systemContent = null,
      receipt = RecallReceipt(emptyList(), listOf(PreparedRecall.LOCAL_ENGINE), destinations, warnings),
      scope = null,
      selected = emptyList(),
    )
  }

  // endregion

  // region embedding jobs

  private class EmbeddingJob(
    val auth: AuthenticatedProfile,
    val client: EmbeddingClient,
    val query: String,
    val candidates: List<Entry>,
    /** Eligible members of the 96-item local pool: the only items embedded on demand. */
    val pool: List<Entry>,
  )

  /** Confined to one job coroutine; a batch is added only after it was fully validated. */
  private class JobProgress {
    val scores = HashMap<String, Double>()
    val writes = ArrayList<Pair<Entry, VectorWrite>>()
    var inputTokens: Int? = null

    fun addTokens(tokens: Int?) {
      if (tokens != null) inputTokens = (inputTokens ?: 0) + tokens
    }
  }

  private class JobResult(
    val job: EmbeddingJob,
    val scores: Map<String, Double>,
    val writes: List<Pair<Entry, VectorWrite>>,
    val warning: String?,
  )

  private class StaleProfileException : Exception()

  private suspend fun run(job: EmbeddingJob, scope: RecallScope): JobResult {
    val progress = JobProgress()
    val name = job.auth.profile.displayName
    try {
      val completed = withTimeoutOrNull(jobTimeoutMillis) {
        perform(job, scope, progress)
        true
      }
      // Timeouts keep only batches that were validated before the deadline.
      val warning = if (completed == null) "$name exceeded the recall time limit; local recall was used." else null
      return JobResult(job, progress.scores.toMap(), progress.writes.toList(), warning)
    } catch (error: StaleProfileException) {
      return JobResult(job, emptyMap(), emptyList(), "$name changed while recall was running; its stale result was ignored.")
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      return JobResult(job, progress.scores.toMap(), progress.writes.toList(), "$name was unavailable; local recall was used.")
    } finally {
      usage.record(job.auth, progress.inputTokens, scope.conversationId)
    }
  }

  private suspend fun perform(job: EmbeddingJob, scope: RecallScope, progress: JobProgress) {
    val auth = job.auth
    val kind = auth.connection.provider
    val queryResult = job.client.embed(
      listOf(EmbeddingInputFormatter.query(job.query, kind, auth.modelId)),
      auth.modelId,
      EmbeddingPurpose.QUERY,
    )
    progress.addTokens(queryResult.inputTokens)
    val queryVector = queryResult.vectors.firstOrNull() ?: throw IllegalStateException("Missing query vector.")

    val validVectorIds = HashSet<String>()
    for (page in job.candidates.chunked(SemanticVectorStore.MAXIMUM_PAGE_SIZE)) {
      currentCoroutineContext().ensureActive()
      val records = vectors.vectors(auth.profile.id, page.map { it.candidate.id }).associateBy { it.sourceId }
      val pageScores = withContext(Dispatchers.Default) {
        val scores = HashMap<String, Double>()
        for (entry in page) {
          val record = records[entry.candidate.id] ?: continue
          if (record.profileId != auth.profile.id || record.sourceKind != entry.candidate.kind.rawValue) continue
          if (record.embeddingSpaceId != auth.spaceId || record.contentFingerprint != entry.candidate.contentFingerprint) continue
          val vector = EmbeddingVectorCodec.decode(record.vectorData, record.dimensions) ?: continue
          if (vector.size != queryVector.size) continue
          scores[entry.candidate.id] = EmbeddingMath.cosineSimilarity(queryVector, vector)
        }
        scores
      }
      progress.scores.putAll(pageScores)
      validVectorIds += pageScores.keys
    }

    // Lazily fill vectors only for the local pool; everything else keeps its cached score.
    val missing = job.pool.filter { it.candidate.id !in validVectorIds }
    val batches = embeddingBatches(missing, EMBEDDING_BATCH_SIZE) {
      EmbeddingInputFormatter.document(it.candidate.text, kind, auth.modelId)
    }
    for (batch in batches) {
      currentCoroutineContext().ensureActive()
      val embedded = job.client.embed(
        batch.map { EmbeddingInputFormatter.document(it.candidate.text, kind, auth.modelId) },
        auth.modelId,
        EmbeddingPurpose.DOCUMENT,
      )
      progress.addTokens(embedded.inputTokens)
      if (embedded.vectors.size != batch.size) throw IllegalStateException("Embedding count mismatch.")
      // Revalidate after the network suspension: profile/provider/model and every source.
      if (!resolver.isCurrent(auth)) throw StaleProfileException()
      val currentIds = validIds(scope, batch.map { SelectedRecall(it.candidate, it.source) })
      val batchScores = HashMap<String, Double>()
      val batchWrites = ArrayList<Pair<Entry, VectorWrite>>()
      batch.forEachIndexed { index, entry ->
        if (entry.candidate.id !in currentIds) return@forEachIndexed
        val vector = embedded.vectors[index]
        if (vector.size == queryVector.size) {
          batchScores[entry.candidate.id] = EmbeddingMath.cosineSimilarity(queryVector, vector)
        }
        batchWrites += entry to VectorWrite(
          profileId = auth.profile.id,
          sourceKind = entry.candidate.kind.rawValue,
          sourceId = entry.candidate.id,
          embeddingSpaceId = auth.spaceId,
          contentFingerprint = entry.candidate.contentFingerprint,
          vector = vector,
        )
      }
      // No suspension between these two: a timeout either keeps the whole batch or none of it.
      progress.scores.putAll(batchScores)
      progress.writes.addAll(batchWrites)
    }
    if (!resolver.isCurrent(auth)) throw StaleProfileException()
  }

  private suspend fun persist(result: JobResult, scope: RecallScope, warnings: MutableList<String>) {
    if (result.writes.isEmpty()) return
    val validIds = validIds(scope, result.writes.map { SelectedRecall(it.first.candidate, it.first.source) })
    val current = result.writes.filter { it.first.candidate.id in validIds }.map { it.second }
    if (current.size != result.writes.size) {
      warnings += "Some embedding cache entries changed before they could be saved, so Turing AI discarded them."
    }
    try {
      for (page in current.chunked(SemanticVectorStore.MAXIMUM_PAGE_SIZE)) {
        currentCoroutineContext().ensureActive()
        vectors.upsert(page)
      }
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      warnings += "${result.job.auth.profile.displayName} vectors could not be cached; they will be requested again later."
    }
  }

  private fun isEligible(kind: RecallSourceKind, profile: EmbeddingProfileEntity): Boolean = when (kind) {
    RecallSourceKind.CONVERSATION_MESSAGE, RecallSourceKind.MEMORY_TOPIC -> profile.indexesConversations
    RecallSourceKind.DOCUMENT_CHUNK -> profile.indexesDocuments
  }

  // endregion

  private suspend fun cancellationCheck(): () -> Unit {
    val context = currentCoroutineContext()
    return { context.ensureActive() }
  }

  private companion object {
    const val MAXIMUM_LOCAL_POOL = 96
    const val MAXIMUM_ITEMS = 6
    const val EMBEDDING_BATCH_SIZE = 32
  }
}

package com.omergirgin.mosaic.data.embeddings

import com.omergirgin.mosaic.core.net.embeddings.EmbeddingClient
import com.omergirgin.mosaic.core.net.embeddings.EmbeddingClientFactory
import com.omergirgin.mosaic.core.net.embeddings.EmbeddingInputFormatter
import com.omergirgin.mosaic.core.net.embeddings.EmbeddingPurpose
import com.omergirgin.mosaic.core.retrieval.EmbeddingVectorCodec
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.index.SemanticVectorStore
import com.omergirgin.mosaic.data.index.VectorMetadataRow
import com.omergirgin.mosaic.data.index.VectorWrite
import com.omergirgin.mosaic.data.recall.RecallChunkRow
import com.omergirgin.mosaic.data.recall.RecallSourceKind
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeoutOrNull

internal class DocumentIndexRebuildException :
  IllegalStateException(
    "Existing document vectors could not be cleared, so the rebuild did not start. Local lexical recall remains available."
  )

/**
 * Port of iOS `SemanticDocumentIndexPipeline`: document health, backfill and safe rebuild of the
 * rebuildable document-vector cache. Sources and vectors are consumed in bounded pages; backfill
 * embeds at most 32 chunks per profile job and revalidates profile, provider, model, document and
 * chunk fingerprint after every network suspension before an exact cache write.
 */
internal class DocumentIndexer(
  private val db: MosaicDatabase,
  private val resolver: EmbeddingProfileResolver,
  private val vectors: SemanticVectorStore,
  private val usage: EmbeddingUsageRecorder,
  private val jobTimeoutMillis: Long = 60_000,
) {
  private val dao = db.recall()
  private val profiles = db.embeddingProfiles()

  // region health

  private class HealthAccumulator(
    val profile: EmbeddingProfileEntity,
    val availability: EmbeddingProfileAvailability,
    val expectedSpaceId: String?,
  ) {
    var hasMixedDimensions = false
    var indexedDocumentCount = 0
    var validVectorCount = 0
    var missingVectorCount = 0
    var staleVectorCount = 0

    fun health() = DocumentProfileHealth(
      profileId = profile.id,
      displayName = profile.displayName,
      availability = availability,
      indexedDocumentCount = indexedDocumentCount,
      validVectorCount = validVectorCount,
      missingVectorCount = missingVectorCount,
      staleVectorCount = staleVectorCount,
    )
  }

  suspend fun health(): DocumentIndexHealth {
    val all = profiles.all()
    // Without any profile there are no vectors to inspect: never open the cache just to count.
    val inspectVectors = all.isNotEmpty() || vectors.isOpen
    val activeIds = activeDocumentProfiles(all).mapTo(HashSet()) { it.id }
    val accumulators = all.filter { it.isEnabled && it.indexesDocuments }.map { profile ->
      val provider = resolver.provider(profile)
      when {
        profile.id !in activeIds -> HealthAccumulator(profile, EmbeddingProfileAvailability.PROFILE_LIMIT_EXCEEDED, null)
        provider != null && resolver.isUsable(provider) ->
          HealthAccumulator(profile, EmbeddingProfileAvailability.AVAILABLE, resolver.spaceId(provider, profile.modelId))
        else -> HealthAccumulator(profile, EmbeddingProfileAvailability.PROVIDER_UNAVAILABLE, null)
      }
    }
    for (accumulator in accumulators) {
      val space = accumulator.expectedSpaceId ?: continue
      accumulator.hasMixedDimensions = vectors.hasMixedDimensions(accumulator.profile.id, space)
    }

    var enabledDocumentCount = 0
    var chunkCount = 0
    var offset = 0
    while (true) {
      currentCoroutineContext().ensureActive()
      val documentIds = dao.enabledDocumentIds(offset, DOCUMENT_PAGE_SIZE)
      if (documentIds.isEmpty()) break
      enabledDocumentCount += documentIds.size
      for (documentId in documentIds) {
        var cursor = -1
        var hasChunks = false
        val fullyIndexed = BooleanArray(accumulators.size) { true }
        while (true) {
          val page = dao.chunkPage(documentId, cursor, HEALTH_PAGE_SIZE)
          if (page.isEmpty()) break
          cursor = page.last().chunkIndex
          val chunks = page.filter { it.content.isNotBlank() }
          if (chunks.isNotEmpty()) {
            hasChunks = true
            chunkCount += chunks.size
            val fingerprints = chunks.associate { it.id to EmbeddingVectorCodec.fingerprint(it.content) }
            accumulators.forEachIndexed { index, accumulator ->
              if (accumulator.availability == EmbeddingProfileAvailability.PROFILE_LIMIT_EXCEEDED) {
                accumulator.missingVectorCount += chunks.size
                fullyIndexed[index] = false
                return@forEachIndexed
              }
              val stored = vectors.metadata(accumulator.profile.id, chunks.map { it.id }).associateBy { it.sourceId }
              for (chunk in chunks) {
                val record = stored[chunk.id]
                if (record == null) {
                  accumulator.missingVectorCount += 1
                  fullyIndexed[index] = false
                } else if (isCurrentVector(record, accumulator, fingerprints[chunk.id])) {
                  accumulator.validVectorCount += 1
                } else {
                  accumulator.staleVectorCount += 1
                  fullyIndexed[index] = false
                }
              }
            }
          }
          if (page.size < HEALTH_PAGE_SIZE) break
        }
        if (hasChunks) {
          accumulators.forEachIndexed { index, accumulator -> if (fullyIndexed[index]) accumulator.indexedDocumentCount += 1 }
        }
      }
      offset += documentIds.size
      if (documentIds.size < DOCUMENT_PAGE_SIZE) break
    }

    var storedVectorCount = 0
    var orphanVectorCount = 0
    var cursor = ""
    while (inspectVectors) {
      currentCoroutineContext().ensureActive()
      val page = vectors.metadataPage(RecallSourceKind.DOCUMENT_CHUNK.rawValue, cursor, HEALTH_PAGE_SIZE)
      if (page.isEmpty()) break
      storedVectorCount += page.size
      val existingProfiles = profiles.existingIds(page.map { it.profileId }.distinct()).toHashSet()
      val existingChunks = dao.existingChunkIds(page.map { it.sourceId }.distinct()).toHashSet()
      orphanVectorCount += page.count { it.profileId !in existingProfiles || it.sourceId !in existingChunks }
      cursor = page.last().cacheKey
      if (page.size < HEALTH_PAGE_SIZE) break
    }

    return DocumentIndexHealth(
      enabledDocumentCount = enabledDocumentCount,
      chunkCount = chunkCount,
      storedVectorCount = storedVectorCount,
      orphanVectorCount = orphanVectorCount,
      profiles = accumulators.map { it.health() },
      isTemporary = vectors.isTemporary,
    )
  }

  private fun isCurrentVector(record: VectorMetadataRow, accumulator: HealthAccumulator, fingerprint: String?): Boolean =
    accumulator.availability == EmbeddingProfileAvailability.AVAILABLE &&
      !accumulator.hasMixedDimensions &&
      record.sourceKind == RecallSourceKind.DOCUMENT_CHUNK.rawValue &&
      record.embeddingSpaceId == accumulator.expectedSpaceId &&
      record.contentFingerprint == fingerprint &&
      EmbeddingVectorCodec.isValidEncoding(record.byteCount, record.dimensions)

  // endregion

  // region indexing

  /** Backfills every enabled document. Failures are warnings: lexical recall stays available. */
  suspend fun indexAllEnabledDocuments(): List<String> {
    val warnings = WarningBag()
    var offset = 0
    val session = IndexSession()
    while (true) {
      try {
        currentCoroutineContext().ensureActive()
        val documentIds = dao.enabledDocumentIds(offset, DOCUMENT_PAGE_SIZE)
        if (documentIds.isEmpty()) break
        warnings += index(documentIds, session)
        offset += documentIds.size
        if (documentIds.size < DOCUMENT_PAGE_SIZE) break
      } catch (error: CancellationException) {
        throw error
      } catch (error: Exception) {
        warnings += "Document vectors could not be cached; local lexical recall remains available."
        break
      }
    }
    return warnings.values
  }

  /** Backfills specific (e.g. newly imported) documents. */
  suspend fun index(documentIds: Collection<String>): List<String> = index(documentIds.distinct().sorted(), IndexSession())

  /** Profiles authenticated once per run; their clients keep one dimension per model across pages. */
  private class IndexSession {
    var profiles: List<Pair<AuthenticatedProfile, EmbeddingClient>>? = null
  }

  private class IndexJob(val auth: AuthenticatedProfile, val client: EmbeddingClient, val chunks: List<RecallChunkRow>)

  private class IndexedVector(val chunk: RecallChunkRow, val fingerprint: String, val vector: FloatArray)

  private class IndexResult(val job: IndexJob, val vectors: List<IndexedVector>, val warning: String?)

  private suspend fun index(documentIds: List<String>, session: IndexSession): List<String> {
    val warnings = WarningBag()
    if (documentIds.isEmpty()) return warnings.values
    try {
      val active = session.profiles ?: authenticatedProfiles(warnings).also { session.profiles = it }
      if (active.isEmpty()) return warnings.values
      var discarded = 0
      for (documentId in documentIds) {
        currentCoroutineContext().ensureActive()
        val document = dao.enabledDocument(documentId) ?: continue
        var cursor = -1
        while (true) {
          val page = dao.chunkPage(document.id, cursor, INDEX_PAGE_SIZE)
          if (page.isEmpty()) break
          cursor = page.last().chunkIndex
          val chunks = page.filter { it.content.isNotBlank() }
          val fingerprints = chunks.associate { it.id to EmbeddingVectorCodec.fingerprint(it.content) }

          val jobs = ArrayList<IndexJob>()
          for ((auth, client) in active) {
            if (chunks.isEmpty()) break
            val stored = vectors.metadata(auth.profile.id, chunks.map { it.id }).associateBy { it.sourceId }
            val missing = chunks.filter { chunk ->
              val record = stored[chunk.id] ?: return@filter true
              record.sourceKind != RecallSourceKind.DOCUMENT_CHUNK.rawValue ||
                record.embeddingSpaceId != auth.spaceId ||
                record.contentFingerprint != fingerprints[chunk.id] ||
                !EmbeddingVectorCodec.isValidEncoding(record.byteCount, record.dimensions)
            }
            if (missing.isNotEmpty()) jobs += IndexJob(auth, client, missing)
          }

          val results = coroutineScope { jobs.map { async { run(it) } }.awaitAll() }
          for (result in results) {
            result.warning?.let { warnings += it }
            if (result.vectors.isEmpty()) continue
            if (!resolver.isCurrent(result.job.auth)) {
              discarded += result.vectors.size
              continue
            }
            val validIds = currentChunkIds(result.vectors)
            val writes = result.vectors.mapNotNull { indexed ->
              if (indexed.chunk.id !in validIds) {
                discarded += 1
                return@mapNotNull null
              }
              VectorWrite(
                profileId = result.job.auth.profile.id,
                sourceKind = RecallSourceKind.DOCUMENT_CHUNK.rawValue,
                sourceId = indexed.chunk.id,
                embeddingSpaceId = result.job.auth.spaceId,
                contentFingerprint = indexed.fingerprint,
                vector = indexed.vector,
              )
            }
            try {
              writes.chunked(SemanticVectorStore.MAXIMUM_PAGE_SIZE).forEach { vectors.upsert(it) }
            } catch (error: CancellationException) {
              throw error
            } catch (error: Exception) {
              warnings += "New document vectors could not be saved; local lexical recall remains available."
            }
          }
          if (page.size < INDEX_PAGE_SIZE) break
        }
      }
      if (discarded > 0) {
        warnings += "$discarded outdated document vectors were discarded because their profile, provider, model, or source changed during indexing."
      }
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      warnings += "Document vectors could not be cached; local lexical recall remains available."
    }
    if (vectors.isTemporary) warnings += "The persistent vector cache is unavailable; remote vectors will be temporary."
    return warnings.values
  }

  private suspend fun authenticatedProfiles(warnings: WarningBag): List<Pair<AuthenticatedProfile, EmbeddingClient>> {
    if (profiles.enabledCount() > EmbeddingProfilePolicy.MAXIMUM_ENABLED_PROFILES) {
      warnings += "Only the four most recently updated embedding profiles were indexed."
    }
    val result = ArrayList<Pair<AuthenticatedProfile, EmbeddingClient>>()
    for (profile in activeDocumentProfiles(profiles.enabled(EmbeddingProfilePolicy.MAXIMUM_ENABLED_PROFILES))) {
      val provider = resolver.provider(profile)
      if (provider == null || !resolver.isUsable(provider)) {
        warnings += "${profile.displayName} has no enabled embedding provider."
        continue
      }
      try {
        val auth = resolver.authenticate(profile, provider)
        result += auth to EmbeddingClientFactory.make(auth.connection)
      } catch (error: CancellationException) {
        throw error
      } catch (error: Exception) {
        warnings += "${profile.displayName} could not access its provider credential."
      }
    }
    return result
  }

  private suspend fun run(job: IndexJob): IndexResult {
    val produced = ArrayList<IndexedVector>()
    var tokens: Int? = null
    val name = job.auth.profile.displayName
    try {
      val completed = withTimeoutOrNull(jobTimeoutMillis) {
        val kind = job.auth.connection.provider
        for (batch in embeddingBatches(job.chunks, INDEX_PAGE_SIZE) { EmbeddingInputFormatter.document(it.content, kind, job.auth.modelId) }) {
          val embedded = job.client.embed(
            batch.map { EmbeddingInputFormatter.document(it.content, kind, job.auth.modelId) },
            job.auth.modelId,
            EmbeddingPurpose.DOCUMENT,
          )
          embedded.inputTokens?.let { tokens = (tokens ?: 0) + it }
          if (embedded.vectors.size != batch.size) throw IllegalStateException("Embedding count mismatch.")
          produced += batch.mapIndexed { index, chunk ->
            IndexedVector(chunk, EmbeddingVectorCodec.fingerprint(chunk.content), embedded.vectors[index])
          }
        }
        true
      }
      val warning = if (completed == null) "$name did not finish document indexing in time." else null
      return IndexResult(job, produced.toList(), warning)
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      return IndexResult(job, produced.toList(), "$name indexed only part of the document; missing chunks will retry later.")
    } finally {
      usage.record(job.auth, tokens, conversationId = null)
    }
  }

  /** Chunks that still exist, belong to an enabled document and have the embedded text. */
  private suspend fun currentChunkIds(indexed: List<IndexedVector>): Set<String> {
    val expected = indexed.associateBy { it.chunk.id }
    val valid = HashSet<String>()
    for (page in expected.keys.chunked(SemanticVectorStore.MAXIMUM_PAGE_SIZE)) {
      for (row in dao.chunkValidation(page)) {
        val item = expected[row.id] ?: continue
        if (row.documentId == item.chunk.documentId && row.isEnabled &&
          EmbeddingVectorCodec.fingerprint(row.content) == item.fingerprint
        ) {
          valid += row.id
        }
      }
    }
    return valid
  }

  // endregion

  // region rebuild

  /**
   * Clears document vectors of the active profiles plus truly dangling vectors (deleted profile,
   * chunk or message) in bounded pages, then regenerates every enabled document. Source text,
   * disabled-profile caches and conversation vectors of existing messages are kept.
   */
  suspend fun rebuildAllEnabledDocuments(): List<String> {
    try {
      val activeIds = activeDocumentProfiles(profiles.enabled(EmbeddingProfilePolicy.MAXIMUM_ENABLED_PROFILES))
        .mapTo(HashSet()) { it.id }
      sweep(RecallSourceKind.DOCUMENT_CHUNK) { page, existingProfiles ->
        val existingChunks = dao.existingChunkIds(page.map { it.sourceId }.distinct()).toHashSet()
        page.filter { it.profileId in activeIds || it.profileId !in existingProfiles || it.sourceId !in existingChunks }
      }
      sweep(RecallSourceKind.CONVERSATION_MESSAGE) { page, existingProfiles ->
        val existingMessages = dao.existingMessageIds(page.map { it.sourceId }.distinct()).toHashSet()
        page.filter { it.profileId !in existingProfiles || it.sourceId !in existingMessages }
      }
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      throw DocumentIndexRebuildException()
    }
    return indexAllEnabledDocuments()
  }

  private suspend fun sweep(
    kind: RecallSourceKind,
    select: suspend (page: List<VectorMetadataRow>, existingProfiles: Set<String>) -> List<VectorMetadataRow>,
  ) {
    var cursor = ""
    while (true) {
      currentCoroutineContext().ensureActive()
      val page = vectors.metadataPage(kind.rawValue, cursor, HEALTH_PAGE_SIZE)
      if (page.isEmpty()) break
      val existingProfiles = profiles.existingIds(page.map { it.profileId }.distinct()).toHashSet()
      vectors.delete(select(page, existingProfiles).map { it.cacheKey })
      cursor = page.last().cacheKey
      if (page.size < HEALTH_PAGE_SIZE) break
    }
  }

  // endregion

  /** The (at most four) most recently updated enabled profiles that index documents. */
  private fun activeDocumentProfiles(all: List<EmbeddingProfileEntity>): List<EmbeddingProfileEntity> =
    all.filter { it.isEnabled }
      .sortedWith(compareByDescending<EmbeddingProfileEntity> { it.updatedAt }.thenBy { it.id })
      .take(EmbeddingProfilePolicy.MAXIMUM_ENABLED_PROFILES)
      .filter { it.indexesDocuments }

  /** Ordered, de-duplicated warnings. */
  private class WarningBag {
    private val set = LinkedHashSet<String>()
    val values: List<String> get() = set.toList()
    operator fun plusAssign(value: String) {
      set += value
    }
    operator fun plusAssign(values: List<String>) {
      set += values
    }
  }

  private companion object {
    const val INDEX_PAGE_SIZE = 32
    const val HEALTH_PAGE_SIZE = 128
    const val DOCUMENT_PAGE_SIZE = 64
  }
}

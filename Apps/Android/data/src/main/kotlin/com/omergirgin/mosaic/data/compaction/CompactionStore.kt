package com.omergirgin.mosaic.data.compaction

import androidx.room.withTransaction
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.context.ContextCandidate
import com.omergirgin.mosaic.core.context.compaction.CompactionContent
import com.omergirgin.mosaic.core.context.compaction.CompactionException
import com.omergirgin.mosaic.core.context.compaction.CompactionFailure
import com.omergirgin.mosaic.core.context.compaction.CompactionGenerationPlan
import com.omergirgin.mosaic.core.context.compaction.CompactionMode
import com.omergirgin.mosaic.core.context.compaction.CompactionSnapshot
import com.omergirgin.mosaic.core.context.compaction.CompactionTelemetrySnapshot
import com.omergirgin.mosaic.core.context.compaction.ConversationCompactionPlanner
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.data.db.CompactionArtifactEntity
import com.omergirgin.mosaic.data.db.CompactionHeadEntity
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.RequestContextEventEntity
import com.omergirgin.mosaic.data.db.UsageRecordEntity
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.internal.newId
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

internal enum class CompactionEventStatus(val rawValue: String) {
  GENERATING("generating"),
  GENERATED("generated"),
  FAILED("failed"),
  CANCELLED("cancelled"),
}

/** Bounded, content-free audit payload of one summary attempt event. */
@Serializable
internal data class CompactionEventPayload(
  val version: Int = 1,
  val attemptId: String,
  val status: String,
  val mode: String,
  val providerId: String,
  val providerKind: String,
  val providerName: String,
  val providerEndpoint: String,
  val modelId: String,
  /** Current user message the answer responds to, and the canonical source length. */
  val sourceThroughMessageId: String? = null,
  val sourceMessageCount: Int = 0,
  /** Raw messages offered to the summarizer (only the new delta when extending). */
  val attemptedMessageCount: Int = 0,
  val attemptedFirstMessageId: String? = null,
  val attemptedLastMessageId: String? = null,
  val coveredMessageCount: Int = 0,
  val previousArtifactId: String? = null,
  val estimatedRequestTokens: Int = 0,
  val estimatedInputTokensBefore: Int = 0,
  val estimatedInputTokensAfter: Int? = null,
  val extraRequestCount: Int = 0,
  val responseId: String? = null,
  val inputTokens: Int? = null,
  val outputTokens: Int? = null,
  val artifactId: String? = null,
  /** Summary actually attached after this attempt (an older one after a failure, or none). */
  val activeArtifactId: String? = null,
  val error: String? = null,
  val warnings: List<String> = emptyList(),
)

/** The committed `generating` event an in-flight attempt must terminate. */
internal data class PendingCompactionAttempt(
  val conversationId: String,
  val assistantMessageId: String,
  val generatingSequence: Int,
  val connection: ProviderConnection,
  val base: CompactionEventPayload,
)

/** Active head as read from storage; [snapshot] is null unless it validated against the chat. */
internal data class LoadedCompactionHead(
  val rawArtifactId: String?,
  val snapshot: CompactionSnapshot?,
  /** The head pointed at an artifact that no longer matches the chat (edit/delete/corruption). */
  val invalidated: Boolean,
)

@Serializable
private data class ArtifactIntegrityEnvelope(
  val id: String,
  val conversationId: String,
  val lineagePreviousCompactionId: String?,
  val coverageParentArtifactId: String?,
  val coverageDeltaJson: String,
  val coveredMessageCount: Int,
  val mode: String,
  val promptVersion: String,
  val contentSchemaVersion: Int,
  val contentJson: String,
  val renderedSummary: String,
  val sourceFingerprint: String,
  val providerId: String,
  val providerKind: String,
  val providerName: String,
  val providerEndpoint: String,
  val providerHost: String?,
  val modelId: String,
  val responseId: String?,
  val inputTokens: Int?,
  val outputTokens: Int?,
  val estimatedSourceTokens: Int,
  val estimatedSummaryTokens: Int,
  val chainDepth: Int,
  val warningsJson: String,
  val createdAt: Long,
)

/**
 * Persistence for app-owned summaries (port of the compaction parts of iOS
 * `NormalizedContextStore`). Artifacts are immutable; the head is a compare-and-swap pointer;
 * attempt events are append-only and idempotent.
 */
internal class CompactionStore(private val db: MosaicDatabase) {
  private val dao = db.compaction()

  /** Reads the head and projects its artifact, validating it against the canonical [messages]. */
  suspend fun activeSnapshot(
    conversationId: String,
    messages: List<ContextCandidate>,
    planner: ConversationCompactionPlanner,
  ): LoadedCompactionHead {
    val artifactId = dao.head(conversationId)?.activeArtifactId ?: return LoadedCompactionHead(null, null, false)
    val snapshot = project(artifactId, conversationId, messages)?.takeIf { planner.isValid(it, conversationId, messages) }
    return LoadedCompactionHead(artifactId, snapshot, invalidated = snapshot == null)
  }

  /** Whether any summary attempt was already recorded for this reply. */
  suspend fun hasAttempt(assistantMessageId: String): Boolean = dao.lastEventSequence(assistantMessageId) >= 0

  suspend fun appendGenerating(
    conversationId: String,
    assistantMessageId: String,
    connection: ProviderConnection,
    plan: CompactionGenerationPlan,
    sourceThroughMessageId: String?,
    sourceMessageCount: Int,
  ): PendingCompactionAttempt = withContext(NonCancellable) {
    val base = CompactionEventPayload(
      attemptId = plan.attemptId,
      status = CompactionEventStatus.GENERATING.rawValue,
      mode = plan.mode.rawValue,
      providerId = connection.id,
      providerKind = connection.provider.rawId,
      providerName = connection.displayName.take(512),
      providerEndpoint = connection.credentialBinding.endpoint.take(2_048),
      modelId = connection.modelId.take(512),
      sourceThroughMessageId = sourceThroughMessageId,
      sourceMessageCount = sourceMessageCount,
      attemptedMessageCount = plan.inputMessages.size,
      attemptedFirstMessageId = plan.inputMessages.firstOrNull()?.id,
      attemptedLastMessageId = plan.inputMessages.lastOrNull()?.id,
      coveredMessageCount = plan.coveredMessages.size,
      previousArtifactId = plan.previousSnapshot?.id,
      estimatedRequestTokens = plan.estimatedRequestTokens,
      estimatedInputTokensBefore = plan.estimatedInputTokensBefore,
      extraRequestCount = 1,
      warnings = boundedWarnings(
        plan.warnings + "Turing AI records the possible extra request before opening the provider stream so an " +
          "interrupted app cannot hide provider usage."
      ),
    )
    db.withTransaction {
      val sequence = dao.lastEventSequence(assistantMessageId) + 1
      dao.insertEvent(event(conversationId, assistantMessageId, sequence, base, MonotonicClock.now()))
      PendingCompactionAttempt(conversationId, assistantMessageId, sequence, connection, base)
    }
  }

  /**
   * Appends the attempt's terminal event (and its reported usage) unless one already exists, so
   * an exception racing a completed activation can never record two outcomes.
   */
  suspend fun appendTerminal(
    pending: PendingCompactionAttempt,
    status: CompactionEventStatus,
    telemetry: CompactionTelemetrySnapshot,
    error: String?,
    activeArtifactId: String?,
    warnings: List<String>,
  ) = withContext(NonCancellable) {
    val payload = terminalPayload(pending, status, telemetry, error, activeArtifactId, artifactId = null, estimatedAfter = null, warnings)
    db.withTransaction {
      if (!dao.hasTerminal(pending.base.attemptId)) {
        val now = MonotonicClock.now()
        dao.insertEvent(event(pending.conversationId, pending.assistantMessageId, pending.generatingSequence + 1, payload, now))
        usageRow(pending, telemetry, now)?.let { db.usage().insert(it) }
      }
    }
  }

  /**
   * Stores the validated summary once, advances the head only if it still points where this
   * attempt started ([expectedHeadArtifactId]), and appends the `generated` event plus usage, all
   * atomically. A moved head means another writer won: the result fails closed.
   */
  suspend fun activate(
    pending: PendingCompactionAttempt,
    snapshot: CompactionSnapshot,
    expectedHeadArtifactId: String?,
    telemetry: CompactionTelemetrySnapshot,
    estimatedInputTokensAfter: Int,
  ) = withContext(NonCancellable) {
    db.withTransaction {
      val head = dao.head(snapshot.conversationId)
      if (head?.activeArtifactId != expectedHeadArtifactId) throw CompactionException(CompactionFailure.STALE_SOURCE)
      if (dao.hasTerminal(pending.base.attemptId)) throw CompactionException(CompactionFailure.STALE_SOURCE)
      val parentCount = snapshot.previousCompactionId?.let { previousId ->
        val parent = dao.coverage(previousId)
        if (parent == null || parent.conversationId != snapshot.conversationId) {
          throw CompactionException(CompactionFailure.INVALID_LINEAGE)
        }
        parent.coveredMessageCount
      } ?: 0
      if (parentCount > snapshot.coveredMessageIds.size) throw CompactionException(CompactionFailure.INVALID_LINEAGE)
      val now = MonotonicClock.now()
      dao.insertArtifact(artifactEntity(snapshot, snapshot.coveredMessageIds.drop(parentCount)))
      dao.upsertHead(
        CompactionHeadEntity(
          conversationId = snapshot.conversationId,
          activeArtifactId = snapshot.id,
          revision = (head?.revision ?: 0) + 1,
          updatedAt = now,
        )
      )
      val payload = terminalPayload(
        pending,
        CompactionEventStatus.GENERATED,
        telemetry,
        error = null,
        activeArtifactId = snapshot.id,
        artifactId = snapshot.id,
        estimatedAfter = estimatedInputTokensAfter,
        warnings = emptyList(),
      )
      dao.insertEvent(event(pending.conversationId, pending.assistantMessageId, pending.generatingSequence + 1, payload, now))
      usageRow(pending, telemetry, now)?.let { db.usage().insert(it) }
    }
  }

  /**
   * Launch repair: no summary request survives its process, so the newest dangling `generating`
   * events (bounded) each get one `failed` terminal event. Idempotent through the unique event key.
   */
  suspend fun reconcileInterrupted(): Int = withContext(NonCancellable) {
    var inserted = 0
    for (event in dao.danglingGenerating(MAXIMUM_RECOVERED_EVENTS)) {
      val generating = runCatching { EventJson.decodeFromString(CompactionEventPayload.serializer(), event.payloadJson) }
        .getOrNull()
      val payload = (generating ?: CompactionEventPayload(
        attemptId = event.attemptId,
        status = CompactionEventStatus.GENERATING.rawValue,
        mode = "",
        providerId = "",
        providerKind = "",
        providerName = "",
        providerEndpoint = "",
        modelId = "",
      )).copy(
        status = CompactionEventStatus.FAILED.rawValue,
        extraRequestCount = 1,
        estimatedInputTokensAfter = null,
        artifactId = null,
        activeArtifactId = null,
        error = "Turing AI recovered an interrupted history-compression audit after the app stopped.",
        warnings = listOf("No partial or unvalidated summary was activated."),
      )
      if (event.eventSequence == Int.MAX_VALUE) continue
      val row = event(event.conversationId, event.assistantMessageId, event.eventSequence + 1, payload, MonotonicClock.now())
      if (dao.insertEvent(row) != -1L) inserted++
    }
    inserted
  }

  // region projection

  private suspend fun project(artifactId: String, conversationId: String, messages: List<ContextCandidate>): CompactionSnapshot? {
    val artifact = dao.artifact(artifactId) ?: return null
    if (artifact.conversationId != conversationId) return null
    if (artifact.payloadFingerprint != integrityFingerprint(artifact)) return null
    val mode = CompactionMode.fromRaw(artifact.mode) ?: return null
    val kind = ProviderKind.fromRawId(artifact.providerKind) ?: return null
    if (!lineageIsConsistent(artifact, mode)) return null
    val content = runCatching { EventJson.decodeFromString(CompactionContent.serializer(), artifact.contentJson) }.getOrNull()
      ?: return null
    if (content.schemaVersion != artifact.contentSchemaVersion) return null
    val warnings = runCatching { EventJson.decodeFromString(StringList, artifact.warningsJson) }.getOrNull() ?: return null
    val coverage = resolveCoverage(artifact, messages) ?: return null
    return CompactionSnapshot(
      id = artifact.id,
      conversationId = artifact.conversationId,
      previousCompactionId = artifact.lineagePreviousCompactionId,
      mode = mode,
      promptVersion = artifact.promptVersion,
      content = content,
      coveredMessageIds = coverage,
      sourceFingerprint = artifact.sourceFingerprint,
      providerId = artifact.providerId,
      providerKind = kind,
      providerName = artifact.providerName,
      providerEndpoint = artifact.providerEndpoint,
      providerHost = artifact.providerHost,
      modelId = artifact.modelId,
      responseId = artifact.responseId,
      inputTokens = artifact.inputTokens,
      outputTokens = artifact.outputTokens,
      estimatedSourceTokens = artifact.estimatedSourceTokens,
      estimatedSummaryTokens = artifact.estimatedSummaryTokens,
      chainDepth = artifact.chainDepth,
      warnings = warnings,
      createdAt = artifact.createdAt,
    )
  }

  private fun lineageIsConsistent(artifact: CompactionArtifactEntity, mode: CompactionMode): Boolean = when (mode) {
    CompactionMode.INITIAL -> artifact.chainDepth == 1 && artifact.lineagePreviousCompactionId == null
    CompactionMode.REBUILD -> artifact.chainDepth == 1 && artifact.lineagePreviousCompactionId != null
    CompactionMode.EXTEND -> artifact.chainDepth >= 2 && artifact.lineagePreviousCompactionId != null
  }

  /**
   * Rebuilds coverage by walking coverage parents (lightweight rows only) and requires each delta
   * to sit at exactly its offset in the canonical transcript. Cycles, cross-chat parents, missing
   * parents and any mismatch fail closed.
   */
  private suspend fun resolveCoverage(artifact: CompactionArtifactEntity, messages: List<ContextCandidate>): List<String>? {
    val chain = ArrayList<Pair<String, Int>>() // (deltaJson, coveredMessageCount), newest first
    val visited = HashSet<String>()
    visited += artifact.id
    chain += artifact.coverageDeltaJson to artifact.coveredMessageCount
    var parentId = artifact.coverageParentArtifactId
    while (parentId != null) {
      if (!visited.add(parentId) || chain.size >= MAXIMUM_COVERAGE_DEPTH) return null
      val parent = dao.coverage(parentId) ?: return null
      if (parent.conversationId != artifact.conversationId) return null
      chain += parent.coverageDeltaJson to parent.coveredMessageCount
      parentId = parent.coverageParentArtifactId
    }

    val coverage = ArrayList<String>(artifact.coveredMessageCount.coerceIn(0, messages.size))
    val seen = HashSet<String>()
    for ((deltaJson, coveredCount) in chain.asReversed()) {
      val delta = runCatching { EventJson.decodeFromString(StringList, deltaJson) }.getOrNull() ?: return null
      val start = coverage.size
      val end = start + delta.size
      if (end != coveredCount || end > messages.size) return null
      for ((offset, id) in delta.withIndex()) {
        if (messages[start + offset].id != id || !seen.add(id)) return null
      }
      coverage += delta
    }
    return coverage
  }

  // endregion

  // region rows

  private fun artifactEntity(snapshot: CompactionSnapshot, delta: List<String>): CompactionArtifactEntity {
    val unsigned = CompactionArtifactEntity(
      id = snapshot.id,
      conversationId = snapshot.conversationId,
      lineagePreviousCompactionId = snapshot.previousCompactionId,
      coverageParentArtifactId = snapshot.previousCompactionId,
      coverageDeltaJson = EventJson.encodeToString(StringList, delta),
      coveredMessageCount = snapshot.coveredMessageIds.size,
      mode = snapshot.mode.rawValue,
      promptVersion = snapshot.promptVersion,
      contentSchemaVersion = snapshot.content.schemaVersion,
      contentJson = EventJson.encodeToString(CompactionContent.serializer(), snapshot.content),
      renderedSummary = snapshot.renderedSummary,
      sourceFingerprint = snapshot.sourceFingerprint,
      providerId = snapshot.providerId,
      providerKind = snapshot.providerKind.rawId,
      providerName = snapshot.providerName,
      providerEndpoint = snapshot.providerEndpoint,
      providerHost = snapshot.providerHost,
      modelId = snapshot.modelId,
      responseId = snapshot.responseId,
      inputTokens = snapshot.inputTokens,
      outputTokens = snapshot.outputTokens,
      estimatedSourceTokens = snapshot.estimatedSourceTokens,
      estimatedSummaryTokens = snapshot.estimatedSummaryTokens,
      chainDepth = snapshot.chainDepth,
      warningsJson = EventJson.encodeToString(StringList, snapshot.warnings),
      payloadFingerprint = "",
      createdAt = snapshot.createdAt,
    )
    return unsigned.copy(payloadFingerprint = integrityFingerprint(unsigned))
  }

  private fun integrityFingerprint(artifact: CompactionArtifactEntity): String {
    val envelope = ArtifactIntegrityEnvelope(
      id = artifact.id,
      conversationId = artifact.conversationId,
      lineagePreviousCompactionId = artifact.lineagePreviousCompactionId,
      coverageParentArtifactId = artifact.coverageParentArtifactId,
      coverageDeltaJson = artifact.coverageDeltaJson,
      coveredMessageCount = artifact.coveredMessageCount,
      mode = artifact.mode,
      promptVersion = artifact.promptVersion,
      contentSchemaVersion = artifact.contentSchemaVersion,
      contentJson = artifact.contentJson,
      renderedSummary = artifact.renderedSummary,
      sourceFingerprint = artifact.sourceFingerprint,
      providerId = artifact.providerId,
      providerKind = artifact.providerKind,
      providerName = artifact.providerName,
      providerEndpoint = artifact.providerEndpoint,
      providerHost = artifact.providerHost,
      modelId = artifact.modelId,
      responseId = artifact.responseId,
      inputTokens = artifact.inputTokens,
      outputTokens = artifact.outputTokens,
      estimatedSourceTokens = artifact.estimatedSourceTokens,
      estimatedSummaryTokens = artifact.estimatedSummaryTokens,
      chainDepth = artifact.chainDepth,
      warningsJson = artifact.warningsJson,
      createdAt = artifact.createdAt,
    )
    return sha256(IntegrityJson.encodeToString(ArtifactIntegrityEnvelope.serializer(), envelope))
  }

  private fun terminalPayload(
    pending: PendingCompactionAttempt,
    status: CompactionEventStatus,
    telemetry: CompactionTelemetrySnapshot,
    error: String?,
    activeArtifactId: String?,
    artifactId: String?,
    estimatedAfter: Int?,
    warnings: List<String>,
  ): CompactionEventPayload {
    val telemetryWarnings = if (telemetry.discardedInvalidUsage) {
      listOf("The provider emitted invalid usage counters, so Turing AI omitted those untrusted values.")
    } else {
      emptyList()
    }
    return pending.base.copy(
      status = status.rawValue,
      extraRequestCount = if (telemetry.requestStarted) 1 else 0,
      responseId = telemetry.responseId,
      inputTokens = telemetry.inputTokens,
      outputTokens = telemetry.outputTokens,
      artifactId = artifactId,
      activeArtifactId = activeArtifactId,
      estimatedInputTokensAfter = estimatedAfter,
      error = error?.take(2_000),
      warnings = boundedWarnings(warnings + telemetryWarnings),
    )
  }

  private fun event(
    conversationId: String,
    assistantMessageId: String,
    sequence: Int,
    payload: CompactionEventPayload,
    createdAt: Long,
  ) = RequestContextEventEntity(
    id = UUID.nameUUIDFromBytes("request-context-event:$assistantMessageId:$sequence".toByteArray(Charsets.UTF_8)).toString(),
    conversationId = conversationId,
    assistantMessageId = assistantMessageId,
    eventSequence = sequence,
    attemptId = payload.attemptId,
    status = payload.status,
    payloadJson = EventJson.encodeToString(CompactionEventPayload.serializer(), payload),
    createdAt = createdAt,
  )

  /** Failed and cancelled summary requests may still have been billed; record what was reported. */
  private fun usageRow(pending: PendingCompactionAttempt, telemetry: CompactionTelemetrySnapshot, now: Long): UsageRecordEntity? {
    if (!telemetry.usageReported || (telemetry.inputTokens == null && telemetry.outputTokens == null)) return null
    val connection = pending.connection
    return UsageRecordEntity(
      id = newId(),
      providerId = connection.id,
      providerKind = connection.provider.rawId,
      providerName = connection.displayName,
      modelId = connection.modelId,
      destinationHost = connection.destinationHost,
      category = USAGE_CATEGORY,
      inputTokens = telemetry.inputTokens,
      outputTokens = telemetry.outputTokens,
      conversationId = pending.conversationId,
      messageId = pending.assistantMessageId,
      createdAt = now,
    )
  }

  private fun boundedWarnings(warnings: List<String>): List<String> = warnings.take(16).map { it.take(1_024) }

  private fun sha256(value: String): String =
    MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

  // endregion

  companion object {
    const val USAGE_CATEGORY = "Compaction"
    private const val MAXIMUM_COVERAGE_DEPTH = 1_024
    private const val MAXIMUM_RECOVERED_EVENTS = 64
    private val StringList = ListSerializer(String.serializer())
    private val EventJson = Json {
      ignoreUnknownKeys = true
      encodeDefaults = true
      explicitNulls = false
    }
    /** Stable field set for the integrity hash (nulls included so a dropped value is detected). */
    private val IntegrityJson = Json {
      encodeDefaults = true
      explicitNulls = true
    }
  }
}

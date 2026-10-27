package com.omergirgin.mosaic.data.memory

import androidx.room.withTransaction
import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.context.MemoryContextScope
import com.omergirgin.mosaic.core.context.utf8Length
import com.omergirgin.mosaic.core.memory.AutomaticMemoryExtractionAction
import com.omergirgin.mosaic.core.memory.AutomaticMemoryExtractionAttemptTelemetry
import com.omergirgin.mosaic.core.memory.AutomaticMemoryExtractionEnvelope
import com.omergirgin.mosaic.core.memory.AutomaticMemoryExtractionException
import com.omergirgin.mosaic.core.memory.AutomaticMemoryExtractionGenerationResult
import com.omergirgin.mosaic.core.memory.AutomaticMemoryExtractionPrompt
import com.omergirgin.mosaic.core.memory.AutomaticMemoryExtractionTelemetryCollector
import com.omergirgin.mosaic.core.memory.AutomaticMemoryExtractor
import com.omergirgin.mosaic.core.memory.AutomaticMemoryFormationPreparation
import com.omergirgin.mosaic.core.memory.AutomaticMemoryFormationResult
import com.omergirgin.mosaic.core.memory.AutomaticMemoryLimits
import com.omergirgin.mosaic.core.memory.AutomaticMemoryRules
import com.omergirgin.mosaic.core.memory.AutomaticMemorySourceFingerprint
import com.omergirgin.mosaic.core.memory.AutomaticMemorySourceMessage
import com.omergirgin.mosaic.core.memory.AutomaticMemoryTopicSnapshot
import com.omergirgin.mosaic.core.memory.MemoryFormationJobStatus
import com.omergirgin.mosaic.core.memory.MemoryOrigin
import com.omergirgin.mosaic.core.memory.MemoryRevisionKind
import com.omergirgin.mosaic.core.memory.MemoryStability
import com.omergirgin.mosaic.core.memory.MemoryTopicKind
import com.omergirgin.mosaic.core.memory.MemoryTopicStatus
import com.omergirgin.mosaic.core.memory.memoryScopeFromRaw
import com.omergirgin.mosaic.core.memory.sha256Hex
import com.omergirgin.mosaic.data.db.MemoryEvidenceEntity
import com.omergirgin.mosaic.data.db.MemoryFormationAuditEntity
import com.omergirgin.mosaic.data.db.MemoryFormationJobEntity
import com.omergirgin.mosaic.data.db.MemoryRevisionEntity
import com.omergirgin.mosaic.data.db.MemoryTopicEntity
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.UsageRecordEntity
import com.omergirgin.mosaic.data.internal.ErrorSanitizer
import com.omergirgin.mosaic.data.internal.newId
import com.omergirgin.mosaic.data.model.MessageStatus
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.cancellation.CancellationException

internal class AutomaticMemoryStoreException(val reason: Reason) : Exception(reason.message) {
  enum class Reason(val message: String) {
    SOURCE_UNAVAILABLE("The completed chat turn is no longer available for memory formation."),
    STALE_SOURCE("The chat changed while Turing AI was forming memory, so the stale result was discarded."),
    INVALID_OPERATION("The proposed memory change failed deterministic validation."),
    MISSING_TOPIC("The proposed memory target is no longer available."),
    PROVIDER_UNAVAILABLE("The provider originally used for this memory update is unavailable or disabled."),
    PROVIDER_DELETED("This automatic memory job was abandoned because its provider configuration was deleted."),
    PROJECT_UNAVAILABLE("This chat's project is archived or unavailable, so automatic memory was not updated."),
    COUNTER_OVERFLOW("The memory history exceeded Turing AI's supported counter range."),
    REQUEST_ALREADY_ACTIVE("This automatic memory request is already running."),
    INTERRUPTED_REQUEST_REQUIRES_EXPLICIT_RETRY(
      "Turing AI stopped an interrupted automatic memory request to avoid charging for an automatic duplicate. " +
        "Retry it explicitly if you want to run it again."
    ),
    SUPERSEDED("This memory attempt was replaced by an attempt using the updated memory rules."),
  }
}

/**
 * Process-local liveness: a crash clears it while leaving the durable audit, which is exactly the
 * signal recovery uses to prohibit an automatic paid resend.
 */
internal class AutomaticMemoryInFlightRegistry {
  private val jobIds = ConcurrentHashMap.newKeySet<String>()
  fun begin(jobId: String): Boolean = jobIds.add(jobId)
  fun end(jobId: String) {
    jobIds.remove(jobId)
  }
  operator fun contains(jobId: String): Boolean = jobId in jobIds
}

internal data class AutomaticMemoryPendingJob(
  val id: String,
  val conversationId: String,
  val throughUserMessageId: String,
  val assistantMessageId: String,
  val providerConfigurationId: String?,
  val modelIdentifier: String?,
  val status: MemoryFormationJobStatus,
  val attemptCount: Int,
  val updatedAt: Long,
)

/**
 * Owns automatic-memory source validation and the single atomic consolidation commit (port of iOS
 * `AutomaticMemoryStore`). Every mutation runs in one Room transaction; a stale or invalid result
 * throws and rolls back as a whole.
 */
internal class AutomaticMemoryStore(
  private val db: MosaicDatabase,
  private val inFlight: AutomaticMemoryInFlightRegistry,
) {
  private val dao = db.automaticMemory()

  // region job lifecycle

  /** Idempotent per (prompt version, conversation, user message, source fingerprint). */
  suspend fun enqueue(
    conversationId: String,
    throughUserMessageId: String,
    assistantMessageId: String,
    provider: ProviderConnection,
    now: Long,
    promptVersion: String = AutomaticMemoryExtractionPrompt.VERSION,
  ): String? = db.withTransaction {
    val source = validatedSource(conversationId, throughUserMessageId, assistantMessageId)
    val conversation = db.conversations().get(conversationId) ?: fail(Reason.SOURCE_UNAVAILABLE)
    // Archived-project chats do not enqueue work that cannot pass the audience gate.
    val projectId = conversation.projectId
    if (projectId != null && !isActiveProject(projectId)) return@withTransaction null
    val fingerprint = AutomaticMemorySourceFingerprint.make(listOf(source))
    val key = jobKey(promptVersion, conversationId, throughUserMessageId, fingerprint)
    val existing = dao.jobByKey(key)
    if (existing != null) {
      val status = statusOf(existing.status)
      return@withTransaction if (status == MemoryFormationJobStatus.COMPLETE || status == MemoryFormationJobStatus.REJECTED) null else existing.id
    }
    val job = MemoryFormationJobEntity(
      id = newId(),
      jobKey = key,
      conversationId = conversationId,
      throughUserMessageId = throughUserMessageId,
      assistantMessageId = assistantMessageId,
      sourceFingerprint = fingerprint,
      promptVersion = promptVersion,
      status = MemoryFormationJobStatus.PENDING.rawValue,
      attemptCount = 0,
      providerConfigurationId = provider.id,
      providerKind = provider.provider.rawId,
      providerDisplayName = bounded(provider.displayName),
      modelIdentifier = provider.modelId,
      providerEndpoint = provider.credentialBinding.endpoint,
      outputFingerprint = null,
      lastError = null,
      startedAt = null,
      completedAt = null,
      createdAt = now,
      updatedAt = now,
    )
    dao.insertJob(job)
    job.id
  }

  private sealed interface PrepareOutcome {
    data class Ready(val preparation: AutomaticMemoryFormationPreparation) : PrepareOutcome
    data object Skip : PrepareOutcome
    data object Interrupted : PrepareOutcome
  }

  /**
   * Captures the exact source, current audience and bounded existing-topic snapshot, then marks a
   * new attempt. An attempt whose request already started is never resumed implicitly.
   */
  suspend fun prepare(jobId: String, provider: ProviderConnection, now: Long): AutomaticMemoryFormationPreparation? {
    val outcome = db.withTransaction {
      val job = dao.job(jobId) ?: return@withTransaction PrepareOutcome.Skip
      val status = statusOf(job.status)
      if (status == MemoryFormationJobStatus.COMPLETE || status == MemoryFormationJobStatus.REJECTED) {
        return@withTransaction PrepareOutcome.Skip
      }
      if (!matchesProvider(job, provider)) fail(Reason.PROVIDER_UNAVAILABLE)
      if (status == MemoryFormationJobStatus.GENERATING) {
        val audit = dao.audit(job.id)
        if (audit != null && audit.attemptCount == job.attemptCount && audit.requestStarted) {
          reconcileInterruptedRequest(job, audit, now)
          return@withTransaction PrepareOutcome.Interrupted
        }
      }
      val source = validatedSource(job.conversationId, job.throughUserMessageId, job.assistantMessageId)
      if (AutomaticMemorySourceFingerprint.make(listOf(source)) != job.sourceFingerprint) fail(Reason.STALE_SOURCE)
      val conversation = db.conversations().get(job.conversationId) ?: fail(Reason.SOURCE_UNAVAILABLE)
      val projectId = conversation.projectId
      val projectName = projectId?.let { id ->
        val project = db.projects().get(id)
        if (project == null || project.isArchived) fail(Reason.PROJECT_UNAVAILABLE)
        project.name
      }
      val topics = visibleTopics(job.conversationId, projectId)
      val generating = job.copy(
        status = MemoryFormationJobStatus.GENERATING.rawValue,
        attemptCount = if (job.attemptCount < Int.MAX_VALUE) job.attemptCount + 1 else job.attemptCount,
        providerConfigurationId = provider.id,
        providerKind = provider.provider.rawId,
        providerDisplayName = bounded(provider.displayName),
        modelIdentifier = provider.modelId,
        providerEndpoint = provider.credentialBinding.endpoint,
        lastError = null,
        startedAt = now,
        completedAt = null,
        updatedAt = now,
      )
      dao.updateJob(generating)
      PrepareOutcome.Ready(
        AutomaticMemoryFormationPreparation(
          jobId = job.id,
          conversationId = job.conversationId,
          throughUserMessageId = job.throughUserMessageId,
          assistantMessageId = job.assistantMessageId,
          sourceFingerprint = job.sourceFingerprint,
          messages = listOf(source),
          existingTopics = topics,
          projectId = projectId,
          projectName = projectName,
        )
      )
    }
    return when (outcome) {
      is PrepareOutcome.Ready -> outcome.preparation
      PrepareOutcome.Skip -> null
      // Committed as failed above; surfaced only after the commit so the receipt survives.
      PrepareOutcome.Interrupted -> fail(Reason.INTERRUPTED_REQUEST_REQUIRES_EXPLICIT_RETRY)
    }
  }

  /**
   * Commits the paid-request boundary before the provider stream may open. A current-attempt
   * receipt can be started only once, preventing an accidental duplicate call.
   */
  suspend fun markRequestStarted(jobId: String, provider: ProviderConnection, expectedProjectId: String?, now: Long) {
    db.withTransaction {
      val job = dao.job(jobId) ?: fail(Reason.STALE_SOURCE)
      if (statusOf(job.status) != MemoryFormationJobStatus.GENERATING || !matchesProvider(job, provider) || job.attemptCount <= 0) {
        fail(Reason.STALE_SOURCE)
      }
      val conversation = db.conversations().get(job.conversationId) ?: fail(Reason.SOURCE_UNAVAILABLE)
      if (conversation.projectId != expectedProjectId) fail(Reason.STALE_SOURCE)
      if (expectedProjectId != null && !isActiveProject(expectedProjectId)) fail(Reason.STALE_SOURCE)
      val audit = dao.audit(job.id)
      if (audit != null && audit.attemptCount == job.attemptCount && audit.requestStarted) {
        fail(Reason.INTERRUPTED_REQUEST_REQUIRES_EXPLICIT_RETRY)
      }
      val opened = job.copy(startedAt = now, updatedAt = now)
      dao.updateJob(opened)
      upsertAudit(opened, MemoryFormationJobStatus.GENERATING, null, true, null, null, false, null, now)
    }
  }

  /** Checkpoints provider-reported usage while the request is in flight. */
  suspend fun recordAttemptTelemetry(
    jobId: String,
    provider: ProviderConnection,
    telemetry: AutomaticMemoryExtractionAttemptTelemetry,
    now: Long,
  ) {
    db.withTransaction {
      val job = dao.job(jobId)
      val audit = dao.audit(jobId)
      if (!telemetry.requestStarted || job == null || statusOf(job.status) != MemoryFormationJobStatus.GENERATING ||
        !matchesProvider(job, provider) || audit == null || audit.attemptCount != job.attemptCount || !audit.requestStarted
      ) {
        fail(Reason.STALE_SOURCE)
      }
      upsertAudit(
        job, MemoryFormationJobStatus.GENERATING, telemetry.providerMessageId, true,
        telemetry.inputTokenCount, telemetry.outputTokenCount, telemetry.didDiscardInvalidTelemetry, null, now,
      )
    }
  }

  /**
   * Marks the job failed (retryable) or rejected ("Not applied"). Returns false when the job no
   * longer exists (its conversation was deleted), so the caller can still record billed usage.
   */
  suspend fun markTerminal(
    jobId: String,
    outcome: MemoryFormationJobStatus,
    error: Throwable,
    redacting: String?,
    telemetry: AutomaticMemoryExtractionAttemptTelemetry?,
    now: Long,
  ): Boolean = db.withTransaction {
    check(outcome == MemoryFormationJobStatus.FAILED || outcome == MemoryFormationJobStatus.REJECTED)
    val job = dao.job(jobId) ?: return@withTransaction false
    val status = statusOf(job.status)
    if (status == MemoryFormationJobStatus.COMPLETE) return@withTransaction true
    // Never turn an immutable rejection back into a retryable job.
    if (status == MemoryFormationJobStatus.REJECTED && outcome != MemoryFormationJobStatus.REJECTED) return@withTransaction true
    val existingAudit = dao.audit(jobId)
    if (status == outcome && existingAudit != null) return@withTransaction true

    val message = describe(error, redacting)
    val terminal = job.copy(status = outcome.rawValue, lastError = message, completedAt = null, updatedAt = now)
    dao.updateJob(terminal)
    val current = existingAudit?.takeIf { it.attemptCount == terminal.attemptCount }
    val audit = upsertAudit(
      terminal,
      outcome,
      providerMessageId = telemetry?.providerMessageId ?: current?.providerMessageId,
      requestStarted = telemetry?.requestStarted == true || current?.requestStarted == true,
      inputTokenCount = telemetry?.inputTokenCount ?: current?.inputTokenCount,
      outputTokenCount = telemetry?.outputTokenCount ?: current?.outputTokenCount,
      didDiscardInvalidTelemetry = telemetry?.didDiscardInvalidTelemetry == true || current?.didDiscardInvalidTelemetry == true,
      errorDescription = message,
      now = now,
    )
    // Only a live attempt ends here; billed tokens are reported exactly once per attempt.
    if (status == MemoryFormationJobStatus.GENERATING) recordUsage(terminal, audit, now)
    true
  }

  /**
   * Unfinished jobs that may continue (never started a provider request in their current attempt).
   * Interrupted attempts are reconciled to failed exactly once, without any automatic resend.
   */
  suspend fun pendingJobs(now: Long): List<AutomaticMemoryPendingJob> = db.withTransaction {
    val result = mutableListOf<AutomaticMemoryPendingJob>()
    for (job in dao.unfinishedJobs(MAXIMUM_PENDING_JOBS)) {
      val status = statusOf(job.status)
      if (status == MemoryFormationJobStatus.GENERATING) {
        if (job.id in inFlight) continue
        val audit = dao.audit(job.id)
        if (audit != null && audit.attemptCount == job.attemptCount && audit.requestStarted) {
          reconcileInterruptedRequest(job, audit, now)
          continue
        }
      }
      result += job.toPending()
    }
    result
  }

  suspend fun newestFailedJob(): MemoryFormationJobEntity? = dao.newestFailedJob()

  /** [after] is the (updatedAt, id) keyset cursor of the previous page's last job. */
  suspend fun failedJobsPage(after: Pair<Long, String>?, boundary: MemoryFormationJobEntity, limit: Int): List<AutomaticMemoryPendingJob> =
    dao.failedJobsPage(
      afterUpdatedAt = after?.first ?: Long.MIN_VALUE,
      afterId = after?.second ?: "",
      boundaryUpdatedAt = boundary.updatedAt,
      boundaryId = boundary.id,
      limit = limit,
    ).map { it.toPending() }

  suspend fun job(id: String): MemoryFormationJobEntity? = dao.job(id)

  // endregion

  // region consolidation

  /** The single atomic consolidation commit, rechecking everything after the network suspension. */
  suspend fun apply(result: AutomaticMemoryExtractionGenerationResult, now: Long): AutomaticMemoryFormationResult = db.withTransaction {
    val job = dao.job(result.jobId) ?: fail(Reason.SOURCE_UNAVAILABLE)
    if (statusOf(job.status) == MemoryFormationJobStatus.COMPLETE) return@withTransaction AutomaticMemoryFormationResult()
    if (statusOf(job.status) != MemoryFormationJobStatus.GENERATING ||
      job.sourceFingerprint != result.sourceFingerprint ||
      job.providerConfigurationId != result.providerConfigurationId ||
      job.providerKind != result.providerKind.rawId ||
      job.modelIdentifier != result.modelIdentifier ||
      job.providerEndpoint != result.providerEndpoint
    ) {
      fail(Reason.STALE_SOURCE)
    }
    val source = validatedSource(job.conversationId, job.throughUserMessageId, job.assistantMessageId)
    if (AutomaticMemorySourceFingerprint.make(listOf(source)) != job.sourceFingerprint) fail(Reason.STALE_SOURCE)
    // A project move during the provider call wins: the stale audience fails closed.
    val conversation = db.conversations().get(job.conversationId) ?: fail(Reason.SOURCE_UNAVAILABLE)
    if (conversation.projectId != result.projectId) fail(Reason.STALE_SOURCE)
    val projectId = result.projectId
    if (projectId != null && !isActiveProject(projectId)) fail(Reason.STALE_SOURCE)
    if (result.envelope.schemaVersion != AutomaticMemoryExtractionEnvelope.CURRENT_SCHEMA_VERSION ||
      result.envelope.operations.size > AutomaticMemoryExtractor.MAXIMUM_OPERATIONS ||
      result.existingTopics.size > AutomaticMemoryExtractor.MAXIMUM_EXISTING_TOPICS
    ) {
      fail(Reason.INVALID_OPERATION)
    }
    val expectedTopics = HashMap<String, AutomaticMemoryTopicSnapshot>()
    for (expected in result.existingTopics) {
      if (!snapshotMatchesAudience(expected, job.conversationId, projectId) || expectedTopics.put(expected.id, expected) != null) {
        fail(Reason.INVALID_OPERATION)
      }
    }

    var created = 0
    var updated = 0
    var reinforced = 0
    var forgotten = 0
    val operationKeys = HashSet<String>()

    for (operation in result.envelope.operations) {
      val isUpsert = operation.action == AutomaticMemoryExtractionAction.UPSERT
      if (operation.evidenceMessageIds != listOf(source.id) ||
        (projectId != null && operation.scope == MemoryContextScope.GLOBAL && operation.targetId == null) ||
        (isUpsert && (operation.confidence < AutomaticMemoryRules.MINIMUM_UPSERT_CONFIDENCE ||
          (operation.kind == MemoryTopicKind.EVENT && (operation.stability != MemoryStability.EVOLVING ||
            operation.confidence < AutomaticMemoryRules.MINIMUM_EVENT_CONFIDENCE)) ||
          AutomaticMemoryExtractor.containsLikelySecret(operation)))
      ) {
        fail(Reason.INVALID_OPERATION)
      }
      val canonicalKey = AutomaticMemoryRules.canonicalKey(
        operation.canonicalKey, operation.kind, operation.scope, job.conversationId, projectId,
      ) ?: fail(Reason.INVALID_OPERATION)
      if (!operationKeys.add(canonicalKey)) fail(Reason.INVALID_OPERATION)

      var topic = resolveTopic(operation.targetId, canonicalKey, operation.kind, job.conversationId, projectId, operation.scope)
      if (topic != null) {
        // Compare-and-swap against the snapshot the provider saw: an edit, pause, forget, move or
        // competing consolidation during the request wins and this stale result fails closed.
        val expected = expectedTopics[topic.id] ?: fail(Reason.STALE_SOURCE)
        if (!matchesCurrentState(topic, expected)) fail(Reason.STALE_SOURCE)
      }
      if (operation.action == AutomaticMemoryExtractionAction.FORGET && topic == null) continue
      if (topic != null && topic.origin == MemoryOrigin.MANUAL.rawValue) {
        val sameValue = AutomaticMemoryRules.normalizedValue(topic.content) == AutomaticMemoryRules.normalizedValue(operation.content)
        val isSafeReinforcement = isUpsert && topic.status == MemoryTopicStatus.ACTIVE.rawValue && sameValue
        if (!isSafeReinforcement) {
          if (operation.targetId != topic.id) fail(Reason.INVALID_OPERATION)
          if (isUpsert && !sameValue && operation.confidence < AutomaticMemoryRules.MINIMUM_MANUAL_OVERRIDE_CONFIDENCE) {
            fail(Reason.INVALID_OPERATION)
          }
        }
      }
      // A delayed older report cannot overwrite a later resolution or refresh its recency.
      if (topic != null && topic.kind == MemoryTopicKind.EVENT.rawValue && source.createdAt < topic.lastConfirmedAt) continue

      var wasCreated = false
      if (isUpsert && topic == null) {
        val newTopic = MemoryTopicEntity(
          id = newId(),
          canonicalKey = canonicalKey,
          title = operation.title,
          content = operation.content,
          kind = operation.kind.rawValue,
          scope = operation.scope.rawValue,
          conversationId = if (operation.scope == MemoryContextScope.CONVERSATION) job.conversationId else null,
          projectId = if (operation.scope == MemoryContextScope.PROJECT) projectId ?: fail(Reason.INVALID_OPERATION) else null,
          status = MemoryTopicStatus.ACTIVE.rawValue,
          origin = MemoryOrigin.AUTOMATIC.rawValue,
          confidence = operation.confidence,
          importance = operation.importance,
          stability = operation.stability.rawValue,
          isEnabled = true,
          lastConfirmedAt = now,
          lastUsedAt = null,
          useCount = 0,
          evidenceCount = 0,
          revision = 1,
          createdAt = now,
          updatedAt = now,
        )
        validateText(newTopic.title, newTopic.content)
        dao.insertTopic(newTopic)
        topic = newTopic
        wasCreated = true
        created++
      }
      val current = topic ?: continue

      val evidence = insertEvidenceIfNeeded(operation.evidenceMessageIds, current, job, source, result, operation.confidence, now)
      val added = if (evidence == null) 0 else 1
      if (current.evidenceCount > Int.MAX_VALUE - added) fail(Reason.COUNTER_OVERFLOW)

      val previousTitle: String?
      val previousContent: String?
      val nextRevision: Int
      val revisionKind: MemoryRevisionKind
      var next: MemoryTopicEntity
      if (wasCreated) {
        if (!isUpsert || added != 1) fail(Reason.INVALID_OPERATION)
        previousTitle = null
        previousContent = null
        nextRevision = 1
        revisionKind = MemoryRevisionKind.CREATED
        next = current.copy(evidenceCount = added, revision = 1, lastConfirmedAt = now, updatedAt = now)
      } else {
        if (current.revision == Int.MAX_VALUE) fail(Reason.COUNTER_OVERFLOW)
        previousTitle = current.title
        previousContent = current.content
        nextRevision = current.revision + 1
        val evidenceCount = current.evidenceCount + added
        if (!isUpsert) {
          revisionKind = MemoryRevisionKind.FORGOTTEN
          next = current.copy(
            status = MemoryTopicStatus.FORGOTTEN.rawValue, isEnabled = false, evidenceCount = evidenceCount,
            revision = nextRevision, lastConfirmedAt = now, updatedAt = now,
          )
          forgotten++
        } else {
          val sameValue = AutomaticMemoryRules.normalizedValue(current.content) == AutomaticMemoryRules.normalizedValue(operation.content)
          val wasForgotten = current.status == MemoryTopicStatus.FORGOTTEN.rawValue
          // A user-paused active topic stays paused; only an explicit restatement after a
          // forgotten topic reactivates it. Background work must not undo UI intent.
          val shouldEnable = if (wasForgotten) true else current.isEnabled
          if (sameValue && !wasForgotten) {
            revisionKind = MemoryRevisionKind.REINFORCED
            val preservesManual = current.origin == MemoryOrigin.MANUAL.rawValue
            next = current.copy(
              title = if (preservesManual) current.title else operation.title,
              content = if (preservesManual) current.content else operation.content,
              confidence = if (preservesManual) 1.0 else AutomaticMemoryRules.reinforcedConfidence(current.confidence, operation.confidence),
              importance = maxOf(current.importance, operation.importance),
              stability = AutomaticMemoryRules.moreStable(stabilityOf(current.stability), operation.stability).rawValue,
              status = MemoryTopicStatus.ACTIVE.rawValue,
              isEnabled = shouldEnable,
              evidenceCount = evidenceCount,
              revision = nextRevision,
              lastConfirmedAt = now,
              updatedAt = now,
            )
            reinforced++
          } else {
            revisionKind = if (wasForgotten) MemoryRevisionKind.REACTIVATED else MemoryRevisionKind.UPDATED
            next = current.copy(
              title = operation.title,
              content = operation.content,
              confidence = operation.confidence,
              importance = maxOf(current.importance, operation.importance),
              stability = operation.stability.rawValue,
              status = MemoryTopicStatus.ACTIVE.rawValue,
              isEnabled = shouldEnable,
              origin = MemoryOrigin.AUTOMATIC.rawValue,
              evidenceCount = evidenceCount,
              revision = nextRevision,
              lastConfirmedAt = now,
              updatedAt = now,
            )
            updated++
          }
        }
      }
      // Events keep the report date of the user message, never the processing time.
      if (next.kind == MemoryTopicKind.EVENT.rawValue) next = next.copy(lastConfirmedAt = minOf(source.createdAt, next.updatedAt))
      validateText(next.title, next.content)
      dao.updateTopic(next)
      dao.insertRevision(
        MemoryRevisionEntity(
          id = newId(),
          revisionKey = "${next.id}/$nextRevision",
          topicId = next.id,
          sequence = nextRevision,
          kind = revisionKind.rawValue,
          previousTitle = previousTitle,
          previousContent = previousContent,
          title = next.title,
          content = next.content,
          sourceEvidenceId = evidence?.id,
          createdAt = now,
        )
      )
    }

    val completed = job.copy(
      status = MemoryFormationJobStatus.COMPLETE.rawValue,
      outputFingerprint = sha256Hex(result.envelope.canonicalJson()),
      lastError = null,
      completedAt = now,
      updatedAt = now,
    )
    dao.updateJob(completed)
    val audit = upsertAudit(
      completed, MemoryFormationJobStatus.COMPLETE, result.providerMessageId, result.requestStarted,
      result.inputTokenCount, result.outputTokenCount, result.didDiscardInvalidTelemetry, null, now,
    )
    recordUsage(completed, audit, now)
    AutomaticMemoryFormationResult(created, updated, reinforced, forgotten)
  }

  // endregion

  // region helpers

  private suspend fun validatedSource(conversationId: String, userMessageId: String, assistantMessageId: String): AutomaticMemorySourceMessage {
    val user = dao.sourceMessage(userMessageId)
    val assistant = dao.sourceMessage(assistantMessageId)
    if (user == null || assistant == null ||
      user.conversationId != conversationId || assistant.conversationId != conversationId ||
      user.role != ChatRole.USER.rawValue || user.status != MessageStatus.COMPLETE.name ||
      assistant.role != ChatRole.ASSISTANT.rawValue || assistant.status != MessageStatus.COMPLETE.name ||
      user.content.isBlank()
    ) {
      fail(Reason.SOURCE_UNAVAILABLE)
    }
    // Message text only: attachment contents live in their own table and are never evidence.
    return AutomaticMemorySourceMessage(user.id, ChatRole.USER, user.content, user.createdAt)
  }

  private suspend fun resolveTopic(
    targetId: String?,
    canonicalKey: String,
    kind: MemoryTopicKind,
    conversationId: String,
    projectId: String?,
    scope: MemoryContextScope,
  ): MemoryTopicEntity? {
    if (targetId != null) {
      val topic = dao.topic(targetId) ?: fail(Reason.MISSING_TOPIC)
      if (topic.scope != scope.rawValue || topic.kind != kind.rawValue || topic.canonicalKey != canonicalKey ||
        !topicMatchesAudience(topic, conversationId, projectId)
      ) {
        fail(Reason.INVALID_OPERATION)
      }
      return topic
    }
    val topic = dao.topicByKey(canonicalKey) ?: return null
    if (topic.kind != kind.rawValue || topic.scope != scope.rawValue || !topicMatchesAudience(topic, conversationId, projectId)) {
      fail(Reason.INVALID_OPERATION)
    }
    return topic
  }

  private suspend fun insertEvidenceIfNeeded(
    evidenceMessageIds: List<String>,
    topic: MemoryTopicEntity,
    job: MemoryFormationJobEntity,
    source: AutomaticMemorySourceMessage,
    result: AutomaticMemoryExtractionGenerationResult,
    confidence: Double,
    now: Long,
  ): MemoryEvidenceEntity? {
    if (source.id !in evidenceMessageIds) fail(Reason.INVALID_OPERATION)
    val key = "${topic.id}/${source.id}/${job.sourceFingerprint}"
    if (dao.evidenceKeyExists(key)) return null
    val evidence = MemoryEvidenceEntity(
      id = newId(),
      evidenceKey = key,
      topicId = topic.id,
      conversationId = job.conversationId,
      sourceMessageId = source.id,
      assistantMessageId = job.assistantMessageId,
      excerpt = AutomaticMemoryRules.boundedUtf8(
        AutomaticMemoryRules.boundedExcerpt(source.content),
        AutomaticMemoryLimits.EVIDENCE_EXCERPT_BYTES,
      ),
      sourceFingerprint = job.sourceFingerprint,
      providerConfigurationId = result.providerConfigurationId,
      providerKind = result.providerKind.rawId,
      providerDisplayName = bounded(result.providerDisplayName),
      modelIdentifier = result.modelIdentifier,
      providerEndpoint = result.providerEndpoint,
      confidence = confidence,
      createdAt = now,
    )
    dao.insertEvidence(evidence)
    return evidence
  }

  /** Global + current-conversation + current-project heads, newest first, bounded to 128. */
  private suspend fun visibleTopics(conversationId: String, projectId: String?): List<AutomaticMemoryTopicSnapshot> {
    val limit = AutomaticMemoryExtractor.MAXIMUM_EXISTING_TOPICS
    val candidates = dao.activeGlobalTopicsByRecency(limit) +
      dao.activeConversationTopicsByRecency(conversationId, limit) +
      (projectId?.let { dao.activeProjectTopicsByRecency(it, limit) } ?: emptyList())
    return candidates
      .sortedWith(compareByDescending<MemoryTopicEntity> { it.updatedAt }.thenBy { it.id })
      .take(limit)
      .mapNotNull { it.toSnapshot() }
  }

  private suspend fun reconcileInterruptedRequest(job: MemoryFormationJobEntity, audit: MemoryFormationAuditEntity, now: Long) {
    if (audit.jobKey != job.jobKey || audit.attemptCount != job.attemptCount || !audit.requestStarted) fail(Reason.INVALID_OPERATION)
    val failed = job.copy(status = MemoryFormationJobStatus.FAILED.rawValue, lastError = INTERRUPTED_MESSAGE, completedAt = null, updatedAt = now)
    dao.updateJob(failed)
    val updatedAudit = upsertAudit(
      failed, MemoryFormationJobStatus.FAILED, audit.providerMessageId, true,
      audit.inputTokenCount, audit.outputTokenCount, audit.didDiscardInvalidTelemetry, INTERRUPTED_MESSAGE, now,
    )
    recordUsage(failed, updatedAudit, now)
  }

  /**
   * Replaces the latest-attempt values and adjusts all-time totals by delta, so repeated
   * cumulative usage events never double-count tokens (iOS `upsertFormationAudit`).
   */
  private suspend fun upsertAudit(
    job: MemoryFormationJobEntity,
    outcome: MemoryFormationJobStatus,
    providerMessageId: String?,
    requestStarted: Boolean,
    inputTokenCount: Int?,
    outputTokenCount: Int?,
    didDiscardInvalidTelemetry: Boolean,
    errorDescription: String?,
    now: Long,
  ): MemoryFormationAuditEntity {
    var discarded = didDiscardInvalidTelemetry
    val boundedMessageId = providerMessageId?.let {
      if (it.isNotBlank() && utf8Length(it) <= AutomaticMemoryLimits.PROVENANCE_BYTES) it else {
        discarded = true
        null
      }
    }
    fun boundedTokens(value: Int?): Int? = value?.let {
      if (it in 0..AutomaticMemoryExtractionTelemetryCollector.MAX_TOKENS) it else {
        discarded = true
        null
      }
    }
    val input = boundedTokens(inputTokenCount)
    val output = boundedTokens(outputTokenCount)
    val existing = dao.audit(job.id)
    if (existing != null) {
      if (existing.jobKey != job.jobKey || job.attemptCount < existing.attemptCount) fail(Reason.INVALID_OPERATION)
      discarded = discarded || existing.didDiscardInvalidTelemetry
      val isNewAttempt = job.attemptCount > existing.attemptCount
      val latestMessageId = boundedMessageId ?: if (isNewAttempt) null else existing.providerMessageId
      val latestInput = input ?: if (isNewAttempt) null else existing.inputTokenCount
      val latestOutput = output ?: if (isNewAttempt) null else existing.outputTokenCount
      val latestStarted = requestStarted || (!isNewAttempt && existing.requestStarted)
      fun cumulative(total: Int, previous: Int?, value: Int?): Int {
        val base = if (isNewAttempt) total else {
          val prior = previous ?: 0
          if (prior > total) {
            discarded = true
            return total
          }
          total - prior
        }
        value ?: return base
        val sum = base.toLong() + value
        if (sum > Int.MAX_VALUE) {
          discarded = true
          return Int.MAX_VALUE
        }
        return sum.toInt()
      }
      val cumulativeInput = cumulative(existing.cumulativeInputTokenCount, existing.inputTokenCount, latestInput)
      val cumulativeOutput = cumulative(existing.cumulativeOutputTokenCount, existing.outputTokenCount, latestOutput)
      var requests = existing.providerRequestCount
      if (isNewAttempt && latestStarted) {
        if (requests < Int.MAX_VALUE) requests++ else discarded = true
      }
      val updated = existing.copy(
        attemptCount = job.attemptCount,
        outcome = outcome.rawValue,
        providerConfigurationId = job.providerConfigurationId,
        providerKind = job.providerKind,
        providerDisplayName = job.providerDisplayName,
        modelIdentifier = job.modelIdentifier,
        providerEndpoint = job.providerEndpoint,
        providerMessageId = latestMessageId,
        requestStarted = latestStarted,
        inputTokenCount = latestInput,
        outputTokenCount = latestOutput,
        providerRequestCount = requests,
        cumulativeInputTokenCount = cumulativeInput,
        cumulativeOutputTokenCount = cumulativeOutput,
        didDiscardInvalidTelemetry = discarded,
        errorDescription = errorDescription,
        startedAt = job.startedAt,
        finishedAt = now,
        updatedAt = now,
      )
      dao.updateAudit(updated)
      return updated
    }
    val audit = MemoryFormationAuditEntity(
      id = newId(),
      jobId = job.id,
      jobKey = job.jobKey,
      attemptCount = job.attemptCount,
      outcome = outcome.rawValue,
      providerConfigurationId = job.providerConfigurationId,
      providerKind = job.providerKind,
      providerDisplayName = job.providerDisplayName,
      modelIdentifier = job.modelIdentifier,
      providerEndpoint = job.providerEndpoint,
      providerMessageId = boundedMessageId,
      requestStarted = requestStarted,
      inputTokenCount = input,
      outputTokenCount = output,
      providerRequestCount = if (requestStarted) 1 else 0,
      cumulativeInputTokenCount = input ?: 0,
      cumulativeOutputTokenCount = output ?: 0,
      didDiscardInvalidTelemetry = discarded,
      errorDescription = errorDescription,
      startedAt = job.startedAt,
      finishedAt = now,
      createdAt = now,
      updatedAt = now,
    )
    dao.insertAudit(audit)
    return audit
  }

  /** One "Memory" usage row per finished attempt that started a request and reported tokens. */
  private suspend fun recordUsage(job: MemoryFormationJobEntity, audit: MemoryFormationAuditEntity, now: Long) {
    if (!audit.requestStarted || (audit.inputTokenCount == null && audit.outputTokenCount == null)) return
    val kind = job.providerKind ?: return
    val model = job.modelIdentifier ?: return
    db.usage().insert(
      UsageRecordEntity(
        id = newId(),
        providerId = job.providerConfigurationId,
        providerKind = kind,
        providerName = job.providerDisplayName.orEmpty(),
        modelId = model,
        destinationHost = hostOf(job.providerEndpoint),
        category = USAGE_CATEGORY,
        inputTokens = audit.inputTokenCount,
        outputTokens = audit.outputTokenCount,
        conversationId = job.conversationId,
        messageId = job.assistantMessageId,
        createdAt = now,
      )
    )
  }

  private suspend fun isActiveProject(id: String): Boolean = db.projects().get(id)?.isArchived == false

  private fun matchesProvider(job: MemoryFormationJobEntity, provider: ProviderConnection): Boolean =
    job.providerConfigurationId == provider.id &&
      job.providerKind == provider.provider.rawId &&
      job.modelIdentifier == provider.modelId &&
      job.providerEndpoint == provider.credentialBinding.endpoint

  private fun topicMatchesAudience(topic: MemoryTopicEntity, conversationId: String, projectId: String?): Boolean =
    when (topic.scope) {
      MemoryContextScope.GLOBAL.rawValue -> topic.conversationId == null && topic.projectId == null
      MemoryContextScope.PROJECT.rawValue -> topic.conversationId == null && topic.projectId != null && topic.projectId == projectId
      MemoryContextScope.CONVERSATION.rawValue -> topic.conversationId == conversationId && topic.projectId == null
      else -> false
    }

  private fun snapshotMatchesAudience(topic: AutomaticMemoryTopicSnapshot, conversationId: String, projectId: String?): Boolean =
    when (topic.scope) {
      MemoryContextScope.GLOBAL -> topic.conversationId == null && topic.projectId == null
      MemoryContextScope.PROJECT -> topic.conversationId == null && topic.projectId != null && topic.projectId == projectId
      MemoryContextScope.CONVERSATION -> topic.conversationId == conversationId && topic.projectId == null
    }

  private fun matchesCurrentState(topic: MemoryTopicEntity, expected: AutomaticMemoryTopicSnapshot): Boolean =
    topic.id == expected.id &&
      topic.canonicalKey == expected.canonicalKey &&
      topic.title == expected.title &&
      topic.content == expected.content &&
      topic.kind == expected.kind.rawValue &&
      topic.scope == expected.scope.rawValue &&
      topic.conversationId == expected.conversationId &&
      topic.projectId == expected.projectId &&
      topic.status == expected.status.rawValue &&
      topic.origin == expected.origin.rawValue &&
      topic.confidence == expected.confidence &&
      topic.importance == expected.importance &&
      topic.stability == expected.stability.rawValue &&
      topic.isEnabled == expected.isEnabled &&
      topic.lastConfirmedAt == expected.lastConfirmedAt &&
      topic.evidenceCount == expected.evidenceCount &&
      topic.revision == expected.revision &&
      topic.createdAt == expected.createdAt &&
      topic.updatedAt == expected.updatedAt

  private fun validateText(title: String, content: String) {
    if (AutomaticMemoryRules.textProblem(title, content) != null) fail(Reason.INVALID_OPERATION)
  }

  private fun MemoryFormationJobEntity.toPending() = AutomaticMemoryPendingJob(
    id = id,
    conversationId = conversationId,
    throughUserMessageId = throughUserMessageId,
    assistantMessageId = assistantMessageId,
    providerConfigurationId = providerConfigurationId,
    modelIdentifier = modelIdentifier,
    status = statusOf(status),
    attemptCount = attemptCount,
    updatedAt = updatedAt,
  )

  // endregion

  companion object {
    const val USAGE_CATEGORY = "Memory"
    private const val MAXIMUM_PENDING_JOBS = 16
    private const val INTERRUPTED_MESSAGE =
      "Turing AI found an interrupted automatic memory request. It was not retried automatically to avoid a duplicate provider charge."

    fun jobKey(promptVersion: String, conversationId: String, throughUserMessageId: String, sourceFingerprint: String): String =
      sha256Hex("$promptVersion|${conversationId.lowercase()}|${throughUserMessageId.lowercase()}|$sourceFingerprint")

    fun statusOf(raw: String): MemoryFormationJobStatus = MemoryFormationJobStatus.fromRaw(raw) ?: MemoryFormationJobStatus.FAILED

    fun stabilityOf(raw: String): MemoryStability = MemoryStability.fromRaw(raw) ?: MemoryStability.EVOLVING

    fun hostOf(endpoint: String?): String? = endpoint?.let { runCatching { URI(it).host }.getOrNull() }

    /** User-facing, sanitized and bounded failure text; never includes the API key. */
    fun describe(error: Throwable, secret: String?): String {
      val raw = when (error) {
        is AutomaticMemoryStoreException, is AutomaticMemoryExtractionException -> error.message.orEmpty()
        is CancellationException -> "The automatic memory request was interrupted."
        else -> ErrorSanitizer.describe(error, secret)
      }
      val bounded = AutomaticMemoryRules.boundedUtf8(ErrorSanitizer.sanitize(raw, secret), AutomaticMemoryLimits.FORMATION_ERROR_BYTES)
      return bounded.ifBlank { "Memory formation failed." }
    }

    private fun bounded(value: String): String = AutomaticMemoryRules.boundedUtf8(value, AutomaticMemoryLimits.PROVENANCE_BYTES)
  }
}

internal typealias Reason = AutomaticMemoryStoreException.Reason

internal fun fail(reason: Reason): Nothing = throw AutomaticMemoryStoreException(reason)

/** Maps a row to the immutable snapshot used for extraction payloads and compare-and-swap. */
internal fun MemoryTopicEntity.toSnapshot(): AutomaticMemoryTopicSnapshot? {
  return AutomaticMemoryTopicSnapshot(
    id = id,
    canonicalKey = canonicalKey,
    title = title,
    content = content,
    kind = MemoryTopicKind.fromRaw(kind) ?: return null,
    scope = memoryScopeFromRaw(scope) ?: return null,
    conversationId = conversationId,
    projectId = projectId,
    status = MemoryTopicStatus.fromRaw(status) ?: return null,
    origin = MemoryOrigin.fromRaw(origin) ?: return null,
    confidence = confidence,
    importance = importance,
    stability = MemoryStability.fromRaw(stability) ?: return null,
    isEnabled = isEnabled,
    lastConfirmedAt = lastConfirmedAt,
    lastUsedAt = lastUsedAt,
    useCount = useCount,
    evidenceCount = evidenceCount,
    revision = revision,
    createdAt = createdAt,
    updatedAt = updatedAt,
  )
}

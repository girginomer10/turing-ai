package com.omergirgin.mosaic.data.memory

import android.util.Log
import com.omergirgin.mosaic.core.chat.ProviderClientFactory
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.context.ContextLimitsResolver
import com.omergirgin.mosaic.core.context.ContextLimitsSource
import com.omergirgin.mosaic.core.memory.AutomaticMemoryExtractionAttemptTelemetry
import com.omergirgin.mosaic.core.memory.AutomaticMemoryExtractionTelemetryCollector
import com.omergirgin.mosaic.core.memory.AutomaticMemoryExtractor
import com.omergirgin.mosaic.core.memory.AutomaticMemoryFormationResult
import com.omergirgin.mosaic.core.memory.MemoryFormationJobStatus
import com.omergirgin.mosaic.core.provider.profile
import com.omergirgin.mosaic.data.api.SettingsRepository
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.UsageRecordEntity
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.internal.newId
import com.omergirgin.mosaic.data.model.ModelChoice
import com.omergirgin.mosaic.data.repo.ProviderRepositoryImpl
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Runs automatic-memory formation (port of iOS `AutomaticMemoryFormationCoordinator` plus the
 * launch recovery and explicit retry flows). Provider calls are serialized process-wide; the
 * durable job/audit rows are the source of truth for spend safety:
 * - a reply never waits for, or is changed by, this work;
 * - the request start is committed before the stream opens, and an interrupted attempt is
 *   reconciled to failed exactly once instead of being resent automatically;
 * - failed jobs are retried only when the person asks.
 */
internal class AutomaticMemoryFormation(
  private val db: MosaicDatabase,
  private val providers: ProviderRepositoryImpl,
  private val settings: SettingsRepository,
  private val scope: CoroutineScope,
) {
  private val inFlight = AutomaticMemoryInFlightRegistry()
  val store = AutomaticMemoryStore(db, inFlight)
  private val extractor = AutomaticMemoryExtractor()
  private val providerCalls = Mutex()
  private val _isRetrying = MutableStateFlow(false)
  val isRetrying: StateFlow<Boolean> = _isRetrying.asStateFlow()

  /**
   * Chat hook: called once an assistant reply is durably COMPLETE. Returns immediately; the
   * extraction uses the exact provider/model/endpoint/key binding the reply used.
   */
  fun afterCompletedReply(
    conversationId: String,
    assistantMessageId: String,
    boundaryCreatedAt: Long,
    boundaryId: String,
    connection: ProviderConnection,
  ) {
    scope.launch {
      try {
        if (!settings.settings.first().automaticMemoryEnabled) return@launch
        val userMessageId = db.automaticMemory().lastUserMessageBefore(conversationId, boundaryCreatedAt, boundaryId)
          ?: return@launch
        formMemory(conversationId, userMessageId, assistantMessageId, connection, resumingJobId = null)
      } catch (error: CancellationException) {
        throw error
      } catch (error: Exception) {
        // Isolated from the successful reply; the durable job keeps a bounded error for review.
        Log.i(TAG, "Automatic memory was not updated (${error.javaClass.simpleName}).")
      }
    }
  }

  /** Startup: reconcile interrupted attempts, then continue jobs that never started a request. */
  fun startRecovery(ready: Job) {
    scope.launch {
      ready.join()
      runCatching { recover() }.onFailure { Log.w(TAG, "Automatic memory recovery stopped (${it.javaClass.simpleName}).") }
    }
  }

  suspend fun formMemory(
    conversationId: String,
    throughUserMessageId: String,
    assistantMessageId: String,
    connection: ProviderConnection,
    resumingJobId: String?,
  ): AutomaticMemoryFormationResult = providerCalls.withLock {
    val jobId = try {
      store.enqueue(conversationId, throughUserMessageId, assistantMessageId, connection, MonotonicClock.now())
    } catch (error: AutomaticMemoryStoreException) {
      // Immutable source loss is recorded as Not applied and never offered for another paid retry.
      if (resumingJobId != null && error.reason == Reason.SOURCE_UNAVAILABLE) {
        withContext(NonCancellable) {
          store.markTerminal(resumingJobId, MemoryFormationJobStatus.REJECTED, error, connection.apiKey, null, MonotonicClock.now())
        }
      }
      throw error
    }
    if (resumingJobId != null && resumingJobId != jobId) {
      // A prompt-version upgrade creates a new audited job; retire the old queue entry.
      store.markTerminal(
        resumingJobId, MemoryFormationJobStatus.REJECTED, AutomaticMemoryStoreException(Reason.SUPERSEDED),
        connection.apiKey, null, MonotonicClock.now(),
      )
    }
    jobId ?: return AutomaticMemoryFormationResult()
    if (!inFlight.begin(jobId)) throw AutomaticMemoryStoreException(Reason.REQUEST_ALREADY_ACTIVE)
    val telemetry = AutomaticMemoryExtractionTelemetryCollector()
    try {
      val preparation = store.prepare(jobId, connection, MonotonicClock.now()) ?: return AutomaticMemoryFormationResult()
      val limits = ContextLimitsResolver.resolve(
        connection.contextWindowTokens ?: FALLBACK_CONTEXT_WINDOW,
        connection.maximumOutputTokens ?: FALLBACK_OUTPUT,
        ContextLimitsSource.DOCUMENTED,
      )
      val generated = extractor.generate(
        preparation = preparation,
        connection = connection,
        client = ProviderClientFactory.make(connection),
        policy = limits.policy,
        telemetry = telemetry,
        beforeOpeningStream = {
          store.markRequestStarted(jobId, connection, preparation.projectId, MonotonicClock.now())
        },
        telemetryDidChange = { snapshot ->
          store.recordAttemptTelemetry(jobId, connection, snapshot, MonotonicClock.now())
        },
      )
      store.apply(generated, MonotonicClock.now())
    } catch (error: Throwable) {
      withContext(NonCancellable) {
        val outcome = if (isNonRetryableLocalFailure(error)) MemoryFormationJobStatus.REJECTED else MemoryFormationJobStatus.FAILED
        val snapshot = telemetry.snapshot
        val recorded = runCatching {
          store.markTerminal(jobId, outcome, error, connection.apiKey, snapshot, MonotonicClock.now())
        }.getOrDefault(true)
        // The chat was deleted mid-request: the job is gone, but billed usage is still reported.
        if (!recorded) runCatching { recordDetachedUsage(connection, conversationId, assistantMessageId, snapshot) }
      }
      throw error
    } finally {
      inFlight.end(jobId)
    }
  }

  /**
   * Explicit retry of failed jobs up to the newest failure at the time of the request (keyset
   * pages of 16), each with its chat's original provider/model.
   */
  suspend fun retryFailed(): MemoryRetryOutcome {
    if (!_isRetrying.compareAndSet(expect = false, update = true)) return MemoryRetryOutcome(0, 0, 0)
    // Application scope: leaving the Memory screen must not cancel a paid request mid-flight.
    return scope.async {
      try {
        retryFailedPages()
      } finally {
        _isRetrying.value = false
      }
    }.await()
  }

  private suspend fun retryFailedPages(): MemoryRetryOutcome {
    val boundary = store.newestFailedJob() ?: return MemoryRetryOutcome(0, 0, 0)
    var completed = 0
    var remaining = 0
    var notApplied = 0
    var cursor: AutomaticMemoryPendingJob? = null
    val attempted = HashSet<String>()
    while (true) {
      val page = store.failedJobsPage(cursor?.let { it.updatedAt to it.id }, boundary, PAGE_SIZE)
      if (page.isEmpty()) break
      cursor = page.last()
      for (job in page) {
        if (!attempted.add(job.id)) continue
        when (val lookup = connectionFor(job)) {
          ConnectionLookup.Deleted -> {
            providerCalls.withLock {
              store.markTerminal(
                job.id, MemoryFormationJobStatus.REJECTED, AutomaticMemoryStoreException(Reason.PROVIDER_DELETED),
                null, null, MonotonicClock.now(),
              )
            }
            notApplied++
          }
          is ConnectionLookup.Unavailable -> remaining++
          is ConnectionLookup.Ready -> try {
            formMemory(job.conversationId, job.throughUserMessageId, job.assistantMessageId, lookup.connection, job.id)
            completed++
          } catch (error: CancellationException) {
            throw error
          } catch (error: Exception) {
            val status = store.job(job.id)?.status
            if (status == null || status == MemoryFormationJobStatus.REJECTED.rawValue) notApplied++ else remaining++
          }
        }
      }
      if (page.size < PAGE_SIZE) break
    }
    return MemoryRetryOutcome(completed, remaining, notApplied)
  }

  private suspend fun recover() {
    val attempted = HashSet<String>()
    repeat(MAX_RECOVERY_ROUNDS) {
      val jobs = providerCalls.withLock { store.pendingJobs(MonotonicClock.now()) }
      if (!settings.settings.first().automaticMemoryEnabled) return
      val fresh = jobs.filter { attempted.add(it.id) }
      if (fresh.isEmpty()) return
      for (job in fresh) {
        when (val lookup = connectionFor(job)) {
          ConnectionLookup.Deleted -> providerCalls.withLock {
            store.markTerminal(
              job.id, MemoryFormationJobStatus.REJECTED, AutomaticMemoryStoreException(Reason.PROVIDER_DELETED),
              null, null, MonotonicClock.now(),
            )
          }
          is ConnectionLookup.Unavailable -> providerCalls.withLock {
            store.markTerminal(job.id, MemoryFormationJobStatus.FAILED, lookup.error, null, null, MonotonicClock.now())
          }
          is ConnectionLookup.Ready -> runCatching {
            formMemory(job.conversationId, job.throughUserMessageId, job.assistantMessageId, lookup.connection, job.id)
          }.onFailure { if (it is CancellationException) throw it }
        }
      }
    }
  }

  private sealed interface ConnectionLookup {
    data object Deleted : ConnectionLookup
    data class Unavailable(val error: Exception) : ConnectionLookup
    data class Ready(val connection: ProviderConnection) : ConnectionLookup
  }

  /** Rebuilds the job's original immutable provider binding (identity, model, endpoint, key). */
  private suspend fun connectionFor(job: AutomaticMemoryPendingJob): ConnectionLookup {
    val providerId = job.providerConfigurationId ?: return ConnectionLookup.Deleted
    val modelId = job.modelIdentifier ?: return ConnectionLookup.Deleted
    // Provider IDs are never reused, so a missing row is permanent.
    if (db.providers().get(providerId) == null) return ConnectionLookup.Deleted
    return try {
      val resolved = providers.resolveModel(ModelChoice(providerId, modelId))
      val key = providers.keyFor(resolved.provider, resolved.kind, required = resolved.kind.profile.requiresApiKey)
      ConnectionLookup.Ready(resolved.connectionWithoutKey().copy(apiKey = key))
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      ConnectionLookup.Unavailable(AutomaticMemoryStoreException(Reason.PROVIDER_UNAVAILABLE))
    }
  }

  private suspend fun recordDetachedUsage(
    connection: ProviderConnection,
    conversationId: String,
    assistantMessageId: String,
    telemetry: AutomaticMemoryExtractionAttemptTelemetry,
  ) {
    if (!telemetry.requestStarted || (telemetry.inputTokenCount == null && telemetry.outputTokenCount == null)) return
    db.usage().insert(
      UsageRecordEntity(
        id = newId(),
        providerId = connection.id,
        providerKind = connection.provider.rawId,
        providerName = connection.displayName,
        modelId = connection.modelId,
        destinationHost = connection.destinationHost,
        category = AutomaticMemoryStore.USAGE_CATEGORY,
        inputTokens = telemetry.inputTokenCount,
        outputTokens = telemetry.outputTokenCount,
        conversationId = conversationId,
        messageId = assistantMessageId,
        createdAt = MonotonicClock.now(),
      )
    )
  }

  private fun isNonRetryableLocalFailure(error: Throwable): Boolean =
    error is AutomaticMemoryStoreException && error.reason in NON_RETRYABLE

  private companion object {
    const val TAG = "TuringMemory"
    const val PAGE_SIZE = 16
    const val MAX_RECOVERY_ROUNDS = 8
    const val FALLBACK_CONTEXT_WINDOW = 32_768
    const val FALLBACK_OUTPUT = 4_096
    val NON_RETRYABLE = setOf(Reason.SOURCE_UNAVAILABLE, Reason.COUNTER_OVERFLOW, Reason.PROVIDER_DELETED, Reason.SUPERSEDED)
  }
}

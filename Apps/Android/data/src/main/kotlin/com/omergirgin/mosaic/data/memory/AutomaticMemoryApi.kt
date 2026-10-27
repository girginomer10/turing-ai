package com.omergirgin.mosaic.data.memory

import com.omergirgin.mosaic.core.memory.MemoryFormationJobStatus
import com.omergirgin.mosaic.core.memory.MemoryOrigin
import com.omergirgin.mosaic.core.memory.MemoryRevisionKind
import com.omergirgin.mosaic.core.memory.MemoryStability
import com.omergirgin.mosaic.core.memory.MemoryTopicKind
import com.omergirgin.mosaic.core.memory.MemoryTopicStatus
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.data.model.MemoryScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/*
 * UI-facing automatic-memory contract (learned topics, their sources and history, and formation
 * activity). Immutable snapshots only; Room entities stay private to the data layer.
 */

enum class LearnedTopicState { ACTIVE, PAUSED, FORGOTTEN }

/** One learned topic head. [revision] and [updatedAt] are the compare-and-swap token for edits. */
data class LearnedTopic(
  val id: String,
  val title: String,
  val content: String,
  val kind: MemoryTopicKind,
  val scope: MemoryScope,
  val projectId: String?,
  val projectName: String?,
  val conversationId: String?,
  val conversationTitle: String?,
  val status: MemoryTopicStatus,
  val origin: MemoryOrigin,
  val isEnabled: Boolean,
  val confidence: Double,
  val importance: Double,
  val stability: MemoryStability,
  /** For events: the report date of the latest supporting user message. */
  val lastConfirmedAt: Long,
  val lastUsedAt: Long?,
  val useCount: Int,
  val evidenceCount: Int,
  val revision: Int,
  val createdAt: Long,
  val updatedAt: Long,
) {
  val isEvent: Boolean get() = kind == MemoryTopicKind.EVENT

  val state: LearnedTopicState
    get() = when {
      status == MemoryTopicStatus.FORGOTTEN -> LearnedTopicState.FORGOTTEN
      !isEnabled -> LearnedTopicState.PAUSED
      else -> LearnedTopicState.ACTIVE
    }
}

/** Exact user-message evidence with the provider/model/host that extracted it. */
data class LearnedTopicEvidence(
  val id: String,
  val conversationId: String,
  val conversationTitle: String?,
  val sourceMessageId: String,
  /** False once the source message was deleted; the excerpt copy remains for audit. */
  val sourceAvailable: Boolean,
  val excerpt: String,
  val providerName: String?,
  val providerKind: ProviderKind?,
  val modelId: String?,
  val providerHost: String?,
  val confidence: Double,
  val createdAt: Long,
)

data class LearnedTopicRevision(
  val id: String,
  val sequence: Int,
  val kind: MemoryRevisionKind,
  val previousTitle: String?,
  val previousContent: String?,
  val title: String,
  val content: String,
  val hasSourceEvidence: Boolean,
  val createdAt: Long,
)

data class LearnedTopicDetail(
  val topic: LearnedTopic,
  /** Newest first, bounded to 100. */
  val evidence: List<LearnedTopicEvidence>,
  /** Newest first, bounded to 100. */
  val revisions: List<LearnedTopicRevision>,
  val totalEvidenceCount: Int,
  val totalRevisionCount: Int,
)

/** Receipt for the latest attempt of one formation job, with cumulative retry totals. */
data class MemoryFormationRun(
  val id: String,
  val jobId: String,
  val outcome: MemoryFormationJobStatus,
  val attemptCount: Int,
  val providerName: String?,
  val providerKind: ProviderKind?,
  val modelId: String?,
  val providerHost: String?,
  val requestStarted: Boolean,
  val inputTokens: Int?,
  val outputTokens: Int?,
  val providerRequestCount: Int,
  val cumulativeInputTokens: Int,
  val cumulativeOutputTokens: Int,
  val didDiscardInvalidTelemetry: Boolean,
  val errorDescription: String?,
  val startedAt: Long?,
  val finishedAt: Long,
) {
  val cumulativeTotalTokens: Long get() = cumulativeInputTokens.toLong() + cumulativeOutputTokens.toLong()
}

data class MemoryFormationActivity(
  /** Newest first, bounded to 20. */
  val recentRuns: List<MemoryFormationRun> = emptyList(),
  /** Failed jobs that can be retried explicitly. */
  val failedJobCount: Int = 0,
  /** Waiting or running jobs. */
  val unfinishedJobCount: Int = 0,
  val totalProviderRequests: Long = 0,
  val totalInputTokens: Long = 0,
  val totalOutputTokens: Long = 0,
)

data class MemoryRetryOutcome(
  val completed: Int,
  /** Still failed (provider disabled, key missing, provider error...). */
  val remaining: Int,
  /** Permanently impossible (source or provider deleted): recorded as Not applied. */
  val notApplied: Int,
)

interface AutomaticMemoryRepository {
  /** All learned topics (active, paused and forgotten), newest first. [query] filters title/content. */
  fun observeTopics(query: String = ""): Flow<List<LearnedTopic>>
  fun observeTopicDetail(id: String): Flow<LearnedTopicDetail?>
  fun observeActivity(): Flow<MemoryFormationActivity>
  val isRetryingFailedUpdates: StateFlow<Boolean>

  /** The correction becomes authoritative (manual origin); the previous value stays in history. */
  suspend fun correctTopic(topic: LearnedTopic, title: String, content: String)
  /** Pause/resume; enabling a forgotten topic restores it ("Remember again"). */
  suspend fun setTopicEnabled(topic: LearnedTopic, enabled: Boolean)
  /** Stops recall while keeping sources and history. */
  suspend fun forgetTopic(topic: LearnedTopic)

  /**
   * Explicitly retries failed formation jobs with each chat's original provider/model. May use
   * provider credits. Runs in the application scope so leaving the screen does not cancel it.
   */
  suspend fun retryFailedUpdates(): MemoryRetryOutcome
}

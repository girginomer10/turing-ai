package com.omergirgin.mosaic.core.context.compaction

import com.omergirgin.mosaic.core.chat.ProviderClient
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.StreamEvent
import com.omergirgin.mosaic.core.chat.TokenUsage
import com.omergirgin.mosaic.core.context.ConservativeTokenEstimator
import com.omergirgin.mosaic.core.context.ContextPolicy
import com.omergirgin.mosaic.core.context.utf8Length
import java.util.UUID
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** What one summary attempt disclosed before it ended, including failed and cancelled ones. */
data class CompactionTelemetrySnapshot(
  val requestStarted: Boolean = false,
  val usageReported: Boolean = false,
  val responseId: String? = null,
  val inputTokens: Int? = null,
  val outputTokens: Int? = null,
  val discardedInvalidUsage: Boolean = false,
)

/**
 * Progress holder so failed, malformed, oversized and cancelled streams can still disclose usage
 * and provider response IDs emitted before termination (usage may already have been billed).
 */
class CompactionTelemetry {
  private val lock = Any()
  private var state = CompactionTelemetrySnapshot()

  fun markRequestStarted() = synchronized(lock) { state = state.copy(requestStarted = true) }

  fun record(usage: TokenUsage) = synchronized(lock) {
    var next = state.copy(usageReported = true)
    usage.inputTokens?.let { input ->
      next = if (input in 0..MAXIMUM_COUNTER) next.copy(inputTokens = input) else next.copy(discardedInvalidUsage = true)
    }
    usage.outputTokens?.let { output ->
      next = if (output in 0..MAXIMUM_COUNTER) next.copy(outputTokens = output) else next.copy(discardedInvalidUsage = true)
    }
    state = next
  }

  fun record(responseId: String?) {
    if (responseId == null) return
    synchronized(lock) { state = state.copy(responseId = responseId.take(512)) }
  }

  val snapshot: CompactionTelemetrySnapshot get() = synchronized(lock) { state }

  private companion object {
    const val MAXIMUM_COUNTER = 1_000_000_000
  }
}

data class CompactionGenerationResult(val snapshot: CompactionSnapshot, val attemptId: String)

/**
 * Port of iOS `ConversationCompactor`. Streams one summary request through the caller's captured
 * client (the same immutable provider connection as the final answer) and validates the result.
 * Nothing is persisted here; partial or malformed output never leaves this function.
 */
class ConversationCompactor(
  val policy: CompactionPolicy = CompactionPolicy.STANDARD,
  val estimator: ConservativeTokenEstimator = ConservativeTokenEstimator(),
  private val clock: () -> Long = System::currentTimeMillis,
) {
  suspend fun generate(
    plan: CompactionGenerationPlan,
    connection: ProviderConnection,
    client: ProviderClient,
    contextPolicy: ContextPolicy,
    telemetry: CompactionTelemetry = CompactionTelemetry(),
  ): CompactionGenerationResult {
    val request = ConversationCompactionPlanner(contextPolicy, policy, estimator).summaryRequest(plan)
    currentCoroutineContext().ensureActive()
    val response = StringBuilder()
    var responseBytes = 0
    var didComplete = false
    telemetry.markRequestStarted()

    client.stream(request).collect { event ->
      currentCoroutineContext().ensureActive()
      when (event) {
        is StreamEvent.TextDelta -> {
          val bytes = utf8Length(event.text)
          if (responseBytes.toLong() + bytes > policy.maximumSummaryUtf8Bytes) {
            throw CompactionException(CompactionFailure.RESPONSE_TOO_LARGE)
          }
          response.append(event.text)
          responseBytes += bytes
        }
        is StreamEvent.Usage -> telemetry.record(event.usage)
        is StreamEvent.Completed -> {
          telemetry.record(event.responseId)
          didComplete = true
        }
        is StreamEvent.Citations -> Unit
      }
    }
    currentCoroutineContext().ensureActive()
    if (!didComplete) throw CompactionException(CompactionFailure.INCOMPLETE_RESPONSE)

    val content = parseAndValidate(response.toString())
    val rendered = content.render()
    if (rendered.isEmpty()) throw CompactionException(CompactionFailure.EMPTY_RESPONSE)
    val chainDepth = if (plan.mode == CompactionMode.EXTEND) {
      val previousDepth = plan.previousSnapshot?.chainDepth ?: 0
      if (previousDepth == Int.MAX_VALUE) throw CompactionException(CompactionFailure.INVALID_LINEAGE)
      previousDepth + 1
    } else {
      1
    }
    val usage = telemetry.snapshot
    val snapshot = CompactionSnapshot(
      id = UUID.randomUUID().toString(),
      conversationId = plan.conversationId,
      previousCompactionId = plan.previousSnapshot?.id,
      mode = plan.mode,
      promptVersion = CompactionPrompt.VERSION,
      content = content,
      coveredMessageIds = plan.coveredMessages.map { it.id },
      sourceFingerprint = plan.sourceFingerprint,
      providerId = connection.id,
      providerKind = connection.provider,
      providerName = connection.displayName,
      providerEndpoint = connection.credentialBinding.endpoint,
      providerHost = connection.destinationHost,
      modelId = connection.modelId,
      responseId = usage.responseId,
      inputTokens = usage.inputTokens,
      outputTokens = usage.outputTokens,
      estimatedSourceTokens = plan.estimatedRequestTokens,
      estimatedSummaryTokens = estimator.estimate(rendered),
      chainDepth = chainDepth,
      warnings = plan.warnings,
      createdAt = clock(),
    )
    return CompactionGenerationResult(snapshot, plan.attemptId)
  }

  /**
   * Accepts exactly one JSON object (optionally inside a single ```json fence) with the supported
   * schema version, allowed item kinds and bounded text. Anything else is rejected.
   */
  fun parseAndValidate(response: String): CompactionContent {
    var candidate = response.trim()
    if (candidate.isEmpty()) throw CompactionException(CompactionFailure.EMPTY_RESPONSE)
    if (candidate.startsWith("```json") && candidate.endsWith("```") && candidate.length >= 10) {
      candidate = candidate.removePrefix("```json").removeSuffix("```").trim()
    } else if (candidate.startsWith("```") || candidate.endsWith("```")) {
      throw CompactionException(CompactionFailure.INVALID_OUTPUT)
    }
    val content = try {
      CompactionJson.decodeFromString(CompactionContent.serializer(), candidate)
    } catch (_: Exception) {
      throw CompactionException(CompactionFailure.INVALID_OUTPUT)
    }
    val valid = content.schemaVersion == CompactionContent.CURRENT_SCHEMA_VERSION &&
      content.items.size <= MAXIMUM_ITEMS &&
      content.overview.codePointCount(0, content.overview.length) <= MAXIMUM_OVERVIEW_CHARACTERS &&
      content.items.all { item ->
        item.text.isNotBlank() && item.text.codePointCount(0, item.text.length) <= MAXIMUM_ITEM_CHARACTERS
      } &&
      (content.overview.isNotBlank() || content.items.isNotEmpty())
    if (!valid) throw CompactionException(CompactionFailure.INVALID_OUTPUT)
    return content
  }

  private companion object {
    const val MAXIMUM_ITEMS = 64
    const val MAXIMUM_OVERVIEW_CHARACTERS = 6_000
    const val MAXIMUM_ITEM_CHARACTERS = 2_000
  }
}

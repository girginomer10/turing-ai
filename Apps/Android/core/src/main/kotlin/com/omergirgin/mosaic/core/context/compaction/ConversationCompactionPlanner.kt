package com.omergirgin.mosaic.core.context.compaction

import com.omergirgin.mosaic.core.chat.ChatMessage
import com.omergirgin.mosaic.core.chat.ChatRequest
import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.context.ConservativeTokenEstimator
import com.omergirgin.mosaic.core.context.ContextCandidate
import com.omergirgin.mosaic.core.context.ContextPlan
import com.omergirgin.mosaic.core.context.ContextPolicy
import com.omergirgin.mosaic.core.context.utf8Length
import java.security.MessageDigest
import java.util.UUID
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
private data class SummaryPayloadMessage(
  /** Photos are never sent to the summarizer; the count keeps the transcript honest. */
  @SerialName("attached_photos") val attachedPhotos: Int? = null,
  val content: String,
  val id: String,
  val role: String,
)

@Serializable
private data class SummaryPayload(
  val messages: List<SummaryPayloadMessage>,
  val mode: String,
  @SerialName("previous_summary") val previousSummary: CompactionContent? = null,
  @SerialName("schema_version") val schemaVersion: Int = 1,
)

/**
 * Port of iOS `ConversationCompactionPlanner`: pure selection and validation logic with no
 * persistence or network work.
 *
 * At roughly [CompactionPolicy.triggerPercent] of the safe input budget it selects the contiguous
 * oldest prefix of completed turns for one bounded summary request targeting
 * [CompactionPolicy.targetPercent]. Before allowing that extra request it measures the fixed
 * instructions, JSON envelope, optional prior summary, raw batch, output reserve and safety
 * margin, so a large legacy chat gets at most one safe batch per send.
 */
class ConversationCompactionPlanner(
  val contextPolicy: ContextPolicy,
  val compactionPolicy: CompactionPolicy = CompactionPolicy.STANDARD,
  val estimator: ConservativeTokenEstimator = ConservativeTokenEstimator(),
) {
  fun decision(
    conversationId: String,
    messages: List<ContextCandidate>,
    systemPrompt: String?,
    existingSnapshot: CompactionSnapshot?,
  ): CompactionDecision {
    if (messages.lastOrNull()?.role != ChatRole.USER) return CompactionDecision.NotNeeded

    val systemTokens = estimator.estimateSystemPrompt(systemPrompt).toLong()
    val tokenPrefix = LongArray(messages.size + 1)
    for (index in messages.indices) tokenPrefix[index + 1] = tokenPrefix[index] + estimator.estimate(messages[index])
    val totalMessageTokens = tokenPrefix[messages.size]
    val rawInputTokens = systemTokens + totalMessageTokens
    val available = contextPolicy.availableInputTokens
    if (rawInputTokens < percentage(compactionPolicy.triggerPercent, available)) return CompactionDecision.NotNeeded

    val validSnapshot = existingSnapshot?.takeIf { isValid(it, conversationId, messages) }
    val reuseOrNotNeeded: CompactionDecision =
      validSnapshot?.let { CompactionDecision.Reuse(it) } ?: CompactionDecision.NotNeeded
    val coveredCount = validSnapshot?.coveredMessageIds?.size ?: 0
    val protectedStart = protectedRawStart(messages)
    if (protectedStart == null || protectedStart <= coveredCount) return reuseOrNotNeeded

    val targetTokens = percentage(compactionPolicy.targetPercent, available)
    if (validSnapshot != null) {
      val summaryTokens = summaryContextTokens(validSnapshot.content)
      val compacted = systemTokens + summaryTokens + (totalMessageTokens - tokenPrefix[coveredCount])
      if (compacted <= targetTokens) return CompactionDecision.Reuse(validSnapshot)
    }

    // Only cut after an assistant reply that follows at least one user turn, so the summarized
    // prefix always ends on a completed turn.
    val eligibleCutoffs = ArrayList<Int>()
    var prefixContainsUser = (0 until coveredCount).any { messages[it].role == ChatRole.USER }
    for (cutoff in (coveredCount + 1)..protectedStart) {
      val newest = messages[cutoff - 1]
      if (newest.role == ChatRole.USER) prefixContainsUser = true
      if (newest.role == ChatRole.ASSISTANT && prefixContainsUser) eligibleCutoffs += cutoff
    }
    if (eligibleCutoffs.isEmpty()) return reuseOrNotNeeded

    val maximumOutput = maxOf(
      128,
      minOf(contextPolicy.maximumOutputTokens, minOf(2_048, contextPolicy.contextWindowTokens / 16)),
    )
    val summaryRequestBudget = maxOf(
      1L,
      contextPolicy.contextWindowTokens.toLong() - maximumOutput - contextPolicy.safetyMarginTokens,
    )
    val anticipatedSummaryTokens = anticipatedSummaryContextTokens()
    val encodedPrefix = LongArray(messages.size + 1)
    for (index in messages.indices) {
      encodedPrefix[index + 1] = encodedPrefix[index] + encodedPayloadMessageBytes(messages[index])
    }
    val incrementalMode = if (validSnapshot == null) CompactionMode.INITIAL else CompactionMode.EXTEND
    val incrementalBase = estimateSummaryRequestBase(incrementalMode, validSnapshot?.content)

    fun requestTokens(start: Int, end: Int, base: Long): Long =
      base + (encodedPrefix[end] - encodedPrefix[start]) + maxOf(0, end - start - 1)

    fun compactedInput(cutoff: Int): Long =
      systemTokens + anticipatedSummaryTokens + (totalMessageTokens - tokenPrefix[cutoff])

    var selectedCutoff: Int? = null
    var selectedRequestTokens = 0L
    var firstTurnExceededBudget = false
    for (cutoff in eligibleCutoffs) {
      val tokens = requestTokens(coveredCount, cutoff, incrementalBase)
      if (tokens > summaryRequestBudget) {
        firstTurnExceededBudget = selectedCutoff == null
        break
      }
      selectedCutoff = cutoff
      selectedRequestTokens = tokens
      if (compactedInput(cutoff) <= targetTokens) break
    }

    if (selectedCutoff == null) {
      if (validSnapshot != null) return CompactionDecision.Reuse(validSnapshot)
      if (firstTurnExceededBudget) {
        return CompactionDecision.Unavailable(
          "The oldest complete turn is larger than the selected model's safe summary-request budget, so " +
            "Turing AI kept it local and used recent raw history instead."
        )
      }
      return CompactionDecision.NotNeeded
    }

    val anticipatedAfter = compactedInput(selectedCutoff)
    val anticipatedRequired =
      systemTokens + anticipatedSummaryTokens + (totalMessageTokens - tokenPrefix[protectedStart])
    if (anticipatedRequired > available || anticipatedAfter + 256 >= rawInputTokens) {
      if (validSnapshot != null) return CompactionDecision.Reuse(validSnapshot)
      return CompactionDecision.Unavailable(
        "Compressing older turns could not create enough safe room because the protected system, memory, " +
          "and recent context already fills the selected model's input budget."
      )
    }

    var mode = incrementalMode
    var inputMessages = messages.subList(coveredCount, selectedCutoff).toList()
    val planWarnings = ArrayList<String>()
    if (validSnapshot != null && validSnapshot.chainDepth >= compactionPolicy.maximumChainDepthBeforeRebuild) {
      val rebuildTokens = requestTokens(0, selectedCutoff, estimateSummaryRequestBase(CompactionMode.REBUILD, null))
      if (rebuildTokens <= summaryRequestBudget) {
        mode = CompactionMode.REBUILD
        inputMessages = messages.subList(0, selectedCutoff).toList()
        selectedRequestTokens = rebuildTokens
      } else {
        planWarnings +=
          "The raw prefix was too large for a safe one-request rebuild, so Turing AI extended the existing summary instead."
      }
    }

    val covered = messages.subList(0, selectedCutoff).toList()
    return CompactionDecision.Generate(
      CompactionGenerationPlan(
        attemptId = UUID.randomUUID().toString(),
        conversationId = conversationId,
        mode = mode,
        previousSnapshot = if (mode == CompactionMode.INITIAL) null else validSnapshot,
        inputMessages = inputMessages,
        coveredMessages = covered,
        sourceFingerprint = sourceFingerprint(covered),
        maximumOutputTokens = maximumOutput,
        estimatedRequestTokens = selectedRequestTokens.clampToInt(),
        estimatedInputTokensBefore = rawInputTokens.clampToInt(),
        warnings = planWarnings,
      )
    )
  }

  /**
   * An exact answer retry must not repeat an automatic paid compaction call: it reuses the
   * unchanged valid snapshot when available, otherwise the caller uses the raw-history planner.
   */
  fun retryDecision(
    conversationId: String,
    messages: List<ContextCandidate>,
    existingSnapshot: CompactionSnapshot?,
  ): CompactionDecision =
    if (existingSnapshot != null && isValid(existingSnapshot, conversationId, messages)) {
      CompactionDecision.Reuse(existingSnapshot)
    } else {
      CompactionDecision.NotNeeded
    }

  /**
   * Providers may return less concise summaries than requested. A validated result is activated
   * only when it creates real savings twice: the complete request must shrink, and the summary
   * must be smaller than the exact context it replaces (the raw prefix for initial/rebuild, or the
   * prior summary plus the new raw delta for an extension).
   */
  fun createsMinimumSavings(
    compactedPlan: ContextPlan,
    generatedSnapshot: CompactionSnapshot,
    generationPlan: CompactionGenerationPlan,
    minimumSavingsTokens: Int = 256,
  ): Boolean {
    val minimum = minimumSavingsTokens.coerceAtLeast(0).toLong()
    val after = compactedPlan.receipt.estimatedInputTokens.toLong()
    val before = generationPlan.estimatedInputTokensBefore.toLong()
    if (after >= before || before - after <= minimum) return false

    val replacedTokens: Long = when (generationPlan.mode) {
      CompactionMode.INITIAL, CompactionMode.REBUILD -> generationPlan.coveredMessages.sumOf { estimator.estimate(it).toLong() }
      CompactionMode.EXTEND -> {
        val previous = generationPlan.previousSnapshot ?: return false
        summaryContextTokens(previous.content) + generationPlan.inputMessages.sumOf { estimator.estimate(it).toLong() }
      }
    }
    val generatedTokens = summaryContextTokens(generatedSnapshot.content)
    return generatedTokens < replacedTokens && replacedTokens - generatedTokens > minimum
  }

  /**
   * The snapshot must belong to this conversation, use the supported prompt/schema, end on an
   * assistant turn, and match the exact authoritative raw prefix (IDs and content fingerprint).
   * Edits, deletes and reorders therefore fail closed; appending newer turns stays valid.
   */
  fun isValid(snapshot: CompactionSnapshot, conversationId: String, messages: List<ContextCandidate>): Boolean {
    val count = snapshot.coveredMessageIds.size
    if (snapshot.conversationId != conversationId) return false
    if (snapshot.promptVersion != CompactionPrompt.VERSION) return false
    if (snapshot.content.schemaVersion != CompactionContent.CURRENT_SCHEMA_VERSION) return false
    if (count <= 0 || count > messages.size) return false
    if (snapshot.coveredMessageIds.toHashSet().size != count) return false
    if (messages[count - 1].role != ChatRole.ASSISTANT) return false
    for (index in 0 until count) {
      if (snapshot.coveredMessageIds[index] != messages[index].id) return false
    }
    return snapshot.sourceFingerprint == sourceFingerprint(messages.subList(0, count))
  }

  /** The single summary request: fixed instructions as system text, transcript as JSON data. */
  fun summaryRequest(plan: CompactionGenerationPlan): ChatRequest {
    val payload = SummaryPayload(
      messages = plan.inputMessages.map(::payloadMessage),
      mode = plan.mode.rawValue,
      previousSummary = if (plan.mode == CompactionMode.EXTEND) plan.previousSnapshot?.content else null,
    )
    val content = CompactionJson.encodeToString(SummaryPayload.serializer(), payload)
    return ChatRequest(
      messages = listOf(ChatMessage(id = plan.attemptId, role = ChatRole.USER, content = content)),
      systemPrompt = CompactionPrompt.INSTRUCTIONS,
      maxOutputTokens = plan.maximumOutputTokens,
      webSearch = false,
    )
  }

  /** Estimated size of the synthetic summary pair for [content]. */
  fun summaryContextTokens(content: CompactionContent): Long =
    SummaryContextMessages.of(PLACEHOLDER_ID, content).sumOf { estimator.estimate(it).toLong() }

  private fun protectedRawStart(messages: List<ContextCandidate>): Int? {
    val userStarts = messages.indices.filter { messages[it].role == ChatRole.USER }
    if (userStarts.size <= compactionPolicy.minimumRecentTurns) return null
    val offset = (userStarts.size - (compactionPolicy.minimumRecentTurns + 1)).coerceAtLeast(0)
    return userStarts[offset]
  }

  private fun estimateSummaryRequestBase(mode: CompactionMode, previousSummary: CompactionContent?): Long {
    val payload = SummaryPayload(
      messages = emptyList(),
      mode = mode.rawValue,
      previousSummary = if (mode == CompactionMode.EXTEND) previousSummary else null,
    )
    val text = CompactionJson.encodeToString(SummaryPayload.serializer(), payload)
    return estimator.estimateSystemPrompt(CompactionPrompt.INSTRUCTIONS).toLong() +
      estimator.estimate(ContextCandidate(PLACEHOLDER_ID, ChatRole.USER, text))
  }

  private fun anticipatedSummaryContextTokens(): Long =
    summaryContextTokens(
      CompactionContent(
        items = emptyList(),
        overview = "s".repeat(compactionPolicy.anticipatedSummaryUtf8Bytes),
        schemaVersion = CompactionContent.CURRENT_SCHEMA_VERSION,
      )
    )

  private fun encodedPayloadMessageBytes(message: ContextCandidate): Long =
    utf8Length(CompactionJson.encodeToString(SummaryPayloadMessage.serializer(), payloadMessage(message))).toLong()

  private fun payloadMessage(message: ContextCandidate) = SummaryPayloadMessage(
    attachedPhotos = message.imageCount.takeIf { it > 0 },
    content = message.content,
    id = message.id,
    role = message.role.rawValue,
  )

  private fun percentage(percent: Int, value: Int): Long = maxOf(1L, (value.toLong() * percent + 99) / 100)

  companion object {
    private const val PLACEHOLDER_ID = "00000000-0000-0000-0000-000000000000"
    private const val COMPLETE_STATUS = "complete"

    /**
     * Stable across launches and platforms: each field (lowercased message ID, role, the fixed
     * status `complete`, exact content) is UTF-8 length-prefixed to prevent delimiter collisions,
     * then hashed with SHA-256. Only completed rows can reach the planner.
     */
    fun sourceFingerprint(messages: List<ContextCandidate>): String {
      val digest = MessageDigest.getInstance("SHA-256")
      fun append(value: String) {
        val bytes = value.toByteArray(Charsets.UTF_8)
        digest.update("${bytes.size}:".toByteArray(Charsets.UTF_8))
        digest.update(bytes)
      }
      for (message in messages) {
        append(message.id.lowercase())
        append(message.role.rawValue)
        append(COMPLETE_STATUS)
        append(message.content)
      }
      return digest.digest().joinToString("") { "%02x".format(it) }
    }
  }
}

internal fun Long.clampToInt(): Int = coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt()

package com.omergirgin.mosaic.core.context

import com.omergirgin.mosaic.core.chat.ChatRole

/**
 * One provider-facing history message as the planner sees it. Content is the exact text that will
 * be sent (including inlined attachment text); images are counted, not loaded, so a long chat with
 * many photos can be planned without materializing every photo.
 */
data class ContextCandidate(
  val id: String,
  val role: ChatRole,
  val content: String,
  val imageCount: Int = 0,
)

enum class ContextStrategy {
  /** The complete history fit. */
  FULL,
  /** Oldest whole turns were omitted; the newest turns are verbatim. */
  RECENT_ONLY,
  /** An app-owned summary pair replaced an oldest prefix; a contiguous raw suffix follows it. */
  SUMMARY_AND_RECENT,
}

/**
 * Partition of the original history for one request. [includedMessageIds] (raw, verbatim),
 * [summarizedMessageIds] (represented by the summary pair), [recalledMessageIds] (exact
 * same-chat excerpts) and [omittedMessageIds] (nothing sent) are disjoint, except that a recalled
 * ID may also be summary-covered.
 */
data class ContextPlanReceipt(
  val strategy: ContextStrategy,
  val originalMessageCount: Int,
  val includedMessageIds: List<String>,
  val omittedMessageIds: List<String>,
  val estimatedInputTokens: Int,
  val contextWindowTokens: Int,
  val maximumOutputTokens: Int,
  val safetyMarginTokens: Int,
  val inputBudgetTokens: Int,
  val warnings: List<String>,
  val summarizedMessageIds: List<String> = emptyList(),
  val recalledMessageIds: List<String> = emptyList(),
)

data class ContextPlan(val messages: List<ContextCandidate>, val receipt: ContextPlanReceipt)

sealed class ContextPlanningException(message: String) : Exception(message) {
  class MissingCurrentUserMessage :
    ContextPlanningException("Turing AI could not find the current user message for this request.")

  class RequiredContentExceedsBudget(val requiredTokens: Int, val availableTokens: Int) :
    ContextPlanningException(
      "The current message and attached context need about $requiredTokens input tokens, but the " +
        "safe request budget is $availableTokens. Shorten the message or remove some attached " +
        "context, then try again. No chat-generation request was sent."
    )
}

/**
 * Port of iOS `ConversationContextPlanner`. Selects one contiguous suffix of complete turns:
 * it never character-truncates a message, never creates holes in history, and always protects
 * the current user message plus [ContextPolicy.minimumRecentTurns] completed prior turns. When
 * the protected content cannot fit, it throws before any provider request is made.
 *
 * Rolling compaction lives in `compaction/`: `ConversationCompactionPlanner` decides whether an
 * oldest prefix should be summarized, and `planWithSummary` plans the summary pair plus a raw
 * suffix with the same protected-turn rules. Same-chat exact recall (`recall/`) runs last.
 */
class ContextPlanner(
  val policy: ContextPolicy,
  val estimator: ConservativeTokenEstimator = ConservativeTokenEstimator(),
  /** Disclosures attached to every receipt (e.g. fallback limits). */
  val warnings: List<String> = emptyList(),
) {
  fun plan(messages: List<ContextCandidate>, systemPrompt: String?): ContextPlan {
    val finalMessage = messages.lastOrNull()
    if (finalMessage == null || finalMessage.role != ChatRole.USER) {
      throw ContextPlanningException.MissingCurrentUserMessage()
    }

    val systemTokens = estimator.estimateSystemPrompt(systemPrompt)
    val costs = messages.map(estimator::estimate)
    val allInputTokens = costs.fold(systemTokens, ::saturatingAdd)
    val inputBudget = policy.availableInputTokens

    if (allInputTokens <= inputBudget) {
      return ContextPlan(messages, receipt(ContextStrategy.FULL, messages, messages, allInputTokens, warnings))
    }

    val turnStarts = messages.indices.filter { messages[it].role == ChatRole.USER }
    // minimumRecentTurns counts completed prior turns; the pending current turn is extra.
    val protectedTurnOffset = (turnStarts.size - (policy.minimumRecentTurns + 1)).coerceAtLeast(0)
    val protectedStart = turnStarts[protectedTurnOffset]
    val protectedTokens = sumFrom(costs, protectedStart, messages.size, systemTokens)

    if (protectedTokens > inputBudget) {
      throw ContextPlanningException.RequiredContentExceedsBudget(protectedTokens, inputBudget)
    }

    var includedStart = protectedStart
    var estimated = protectedTokens
    for (turnIndex in protectedTurnOffset - 1 downTo 0) {
      val turnStart = turnStarts[turnIndex]
      val turnTokens = sumFrom(costs, turnStart, includedStart, 0)
      if (saturatingAdd(estimated, turnTokens) > inputBudget) break
      estimated = saturatingAdd(estimated, turnTokens)
      includedStart = turnStart
    }

    // A malformed leading assistant-only prefix is only kept when everything fits; once turns are
    // omitted the suffix always starts on a user turn so the transcript stays coherent.
    val included = messages.subList(includedStart, messages.size).toList()
    val omittedCount = messages.size - included.size
    val omissionWarning =
      "$omittedCount earlier message${if (omittedCount == 1) " was" else "s were"} left out because " +
        "the conversation no longer fits this model's safe input budget. The newest turns were sent " +
        "unchanged."
    return ContextPlan(
      included,
      receipt(ContextStrategy.RECENT_ONLY, messages, included, estimated, warnings + omissionWarning),
    )
  }

  private fun sumFrom(costs: List<Int>, from: Int, until: Int, initial: Int): Int {
    var total = initial
    for (index in from until until) total = saturatingAdd(total, costs[index])
    return total
  }

  private fun receipt(
    strategy: ContextStrategy,
    all: List<ContextCandidate>,
    included: List<ContextCandidate>,
    estimatedInputTokens: Int,
    warnings: List<String>,
  ): ContextPlanReceipt {
    val includedIds = included.map { it.id }
    val includedSet = includedIds.toHashSet()
    return ContextPlanReceipt(
      strategy = strategy,
      originalMessageCount = all.size,
      includedMessageIds = includedIds,
      omittedMessageIds = all.asSequence().map { it.id }.filterNot(includedSet::contains).toList(),
      estimatedInputTokens = estimatedInputTokens,
      contextWindowTokens = policy.contextWindowTokens,
      maximumOutputTokens = policy.maximumOutputTokens,
      safetyMarginTokens = policy.safetyMarginTokens,
      inputBudgetTokens = policy.availableInputTokens,
      warnings = warnings,
    )
  }
}

package com.omergirgin.mosaic.data.compaction

import android.util.Log
import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.chat.ProviderClientFactory
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.context.ContextCandidate
import com.omergirgin.mosaic.core.context.ContextPlan
import com.omergirgin.mosaic.core.context.ContextPlanner
import com.omergirgin.mosaic.core.context.ContextPlanningException
import com.omergirgin.mosaic.core.context.ContextPolicy
import com.omergirgin.mosaic.core.context.compaction.CompactionDecision
import com.omergirgin.mosaic.core.context.compaction.CompactionException
import com.omergirgin.mosaic.core.context.compaction.CompactionFailure
import com.omergirgin.mosaic.core.context.compaction.CompactionGenerationPlan
import com.omergirgin.mosaic.core.context.compaction.CompactionSnapshot
import com.omergirgin.mosaic.core.context.compaction.CompactionTelemetry
import com.omergirgin.mosaic.core.context.compaction.CompactionTelemetrySnapshot
import com.omergirgin.mosaic.core.context.compaction.ConversationCompactionPlanner
import com.omergirgin.mosaic.core.context.compaction.ConversationCompactor
import com.omergirgin.mosaic.core.context.compaction.planAfterCompactionFailure
import com.omergirgin.mosaic.core.context.compaction.planWithSummary
import com.omergirgin.mosaic.core.context.compaction.withWarning
import com.omergirgin.mosaic.core.context.recall.SameChatRecallOrigin as CoreRecallOrigin
import com.omergirgin.mosaic.core.context.recall.SameChatRecallSource
import com.omergirgin.mosaic.core.context.recall.SameConversationRecallPlanner
import com.omergirgin.mosaic.data.db.CanonicalMessageRow
import com.omergirgin.mosaic.data.db.Codecs
import com.omergirgin.mosaic.data.db.ContextReceiptEntity
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.internal.ErrorSanitizer
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.model.ContextReceipt
import com.omergirgin.mosaic.data.model.ConversationSummaryReceipt
import com.omergirgin.mosaic.data.model.SameChatExcerpt
import com.omergirgin.mosaic.data.model.SameChatRecallOrigin
import com.omergirgin.mosaic.data.model.SummaryStatus
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext

/** Everything the planning step needs for one answer; [connection] carries the key. */
internal class ContextPlanningInput(
  val conversationId: String,
  val conversationTitle: String,
  val assistantMessageId: String,
  /** False for an exact retry: never start a new paid summary request, only reuse. */
  val allowNewCompaction: Boolean,
  val connection: ProviderConnection,
  val policy: ContextPolicy,
  val limitWarnings: List<String>,
  val systemPrompt: String?,
  /** Canonical rows (oldest first) aligned 1:1 with [candidates]; the last one is the current user turn. */
  val rows: List<CanonicalMessageRow>,
  val candidates: List<ContextCandidate>,
  /** Re-reads the same canonical rows from storage (authoritative source check). */
  val reloadRows: suspend () -> List<CanonicalMessageRow>,
)

/** Final plan plus the receipt disclosures the engine merges into its [ContextReceipt]. */
internal class PlannedContext(
  val plan: ContextPlan,
  val summary: ConversationSummaryReceipt?,
  val summarizedMessageIds: List<String>,
  val sameChatExcerpts: List<SameChatExcerpt>,
) {
  fun applyTo(receipt: ContextReceipt): ContextReceipt =
    receipt.copy(summary = summary, summarizedMessageIds = summarizedMessageIds, sameChatExcerpts = sameChatExcerpts)
}

/** Prevents two concurrent paid compaction requests for the same chat within the process. */
internal object CompactionExecutionGate {
  private val active = HashSet<String>()

  fun tryAcquire(conversationId: String): Boolean = synchronized(active) { active.add(conversationId) }

  fun release(conversationId: String) {
    synchronized(active) { active.remove(conversationId) }
  }
}

/**
 * The application-owned planning step of the send path (iOS `ConversationView.startGeneration`
 * context section): rolling compaction through the same immutable provider connection, an
 * explicit visible fallback to the recent-raw planner, same-chat exact recall, and canonical
 * re-reads before deciding, after the summary call and before the final stream.
 */
internal class ConversationContextCoordinator(private val db: MosaicDatabase) {
  private val store = CompactionStore(db)

  /**
   * Outcome of the summary attempt already made for a reply. A caller may replan the same reply
   * (e.g. without optional recall after a budget failure); the attempt is disclosed again instead
   * of issuing a second paid request. Entries are dropped once planning succeeds.
   */
  private val attemptedReplies = ConcurrentHashMap<String, ConversationSummaryReceipt>()

  private class BaseOutcome(val plan: ContextPlan, val summary: ConversationSummaryReceipt?)

  suspend fun plan(input: ContextPlanningInput): PlannedContext {
    require(input.rows.size == input.candidates.size) { "Turing AI could not prepare this chat's history." }
    val planner = ContextPlanner(input.policy, warnings = input.limitWarnings)
    val compactionPlanner = ConversationCompactionPlanner(input.policy, estimator = planner.estimator)
    val messages = input.candidates

    val loaded = store.activeSnapshot(input.conversationId, messages, compactionPlanner)
    val decision = if (input.allowNewCompaction) {
      compactionPlanner.decision(input.conversationId, messages, input.systemPrompt, loaded.snapshot)
    } else {
      compactionPlanner.retryDecision(input.conversationId, messages, loaded.snapshot)
    }

    var base = when (decision) {
      CompactionDecision.NotNeeded -> BaseOutcome(planner.plan(messages, input.systemPrompt), null)
      is CompactionDecision.Unavailable ->
        BaseOutcome(planner.plan(messages, input.systemPrompt).withWarning(decision.warning), null)
      is CompactionDecision.Reuse -> reuse(input, planner, decision.snapshot)
      is CompactionDecision.Generate -> generate(input, planner, compactionPlanner, decision.plan, loaded)
    }
    // Only disclose an invalidated summary when one would actually have been considered.
    if (loaded.invalidated && decision != CompactionDecision.NotNeeded) {
      base = BaseOutcome(base.plan.withWarning(INVALIDATED_SUMMARY_WARNING), base.summary)
    }

    currentCoroutineContext().ensureActive()
    val job = currentCoroutineContext()[Job]
    val recall = SameConversationRecallPlanner(planner.estimator).plan(
      query = input.rows.last().content,
      conversationId = input.conversationId,
      conversationTitle = input.conversationTitle,
      sources = input.rows.mapNotNull { row ->
        if (row.role != ChatRole.USER.rawValue || row.content.isBlank()) null
        else SameChatRecallSource(row.id, row.content, row.createdAt)
      },
      basePlan = base.plan,
      originalMessages = messages,
      policy = input.policy,
      nowMillis = System.currentTimeMillis(),
      cancellationCheck = { job?.ensureActive() },
    )
    val baseReceipt = base.plan.receipt
    val finalPlan = ContextPlan(
      messages = recall.messages,
      receipt = baseReceipt.copy(
        includedMessageIds = recall.finalRawIncludedMessageIds,
        omittedMessageIds = recall.finalOmittedMessageIds,
        summarizedMessageIds = recall.summarizedMessageIds,
        recalledMessageIds = recall.recalledMessageIds,
        estimatedInputTokens = recall.estimatedInputTokens,
        warnings = if (recall.eligibleCandidateCount > 0) baseReceipt.warnings + recall.warnings else baseReceipt.warnings,
      ),
    )

    // Immediately before the answer stream: the authoritative transcript must be unchanged.
    requireUnchanged(input, FINAL_STALE_MESSAGE)
    attemptedReplies.remove(input.assistantMessageId)
    return PlannedContext(
      plan = finalPlan,
      summary = base.summary,
      summarizedMessageIds = recall.summarizedMessageIds,
      sameChatExcerpts = recall.items.map { item ->
        SameChatExcerpt(
          messageId = item.id,
          text = item.content,
          origin = if (item.origin == CoreRecallOrigin.SUMMARIZED) SameChatRecallOrigin.SUMMARIZED else SameChatRecallOrigin.OMITTED,
          createdAt = item.createdAt,
          isTruncated = item.isTruncated,
        )
      },
    )
  }

  private fun reuse(input: ContextPlanningInput, planner: ContextPlanner, snapshot: CompactionSnapshot): BaseOutcome =
    try {
      BaseOutcome(
        planner.planWithSummary(input.candidates, input.systemPrompt, input.conversationId, snapshot),
        reusedReceipt(snapshot),
      )
    } catch (_: ContextPlanningException) {
      BaseOutcome(planner.plan(input.candidates, input.systemPrompt).withWarning(REUSE_DID_NOT_FIT_WARNING), null)
    } catch (_: CompactionException) {
      BaseOutcome(planner.plan(input.candidates, input.systemPrompt).withWarning(REUSE_DID_NOT_FIT_WARNING), null)
    }

  private suspend fun generate(
    input: ContextPlanningInput,
    planner: ContextPlanner,
    compactionPlanner: ConversationCompactionPlanner,
    generationPlan: CompactionGenerationPlan,
    loaded: LoadedCompactionHead,
  ): BaseOutcome {
    val conversationId = input.conversationId
    val messages = input.candidates
    // At most one summary request per reply, even if this reply is planned again.
    val earlierAttempt = attemptedReplies[input.assistantMessageId]
      ?: if (store.hasAttempt(input.assistantMessageId)) ALREADY_ATTEMPTED_RECEIPT else null
    if (earlierAttempt != null) {
      val fallback = planner.planAfterCompactionFailure(
        messages, input.systemPrompt, conversationId, generationPlan.previousSnapshot, ONE_ATTEMPT_WARNING,
      )
      val active = fallback.usedSnapshot
      return BaseOutcome(
        fallback.plan,
        earlierAttempt.copy(
          status = if (active == null && earlierAttempt.status == SummaryStatus.GENERATED) {
            SummaryStatus.FAILED
          } else {
            earlierAttempt.status
          },
          text = active?.renderedSummary,
          providerName = active?.providerName,
          providerKind = active?.providerKind,
          modelId = active?.modelId,
          host = active?.providerHost,
          summaryCreatedAt = active?.createdAt,
        ),
      )
    }
    if (!CompactionExecutionGate.tryAcquire(conversationId)) {
      val fallback = planner.planAfterCompactionFailure(
        messages, input.systemPrompt, conversationId, generationPlan.previousSnapshot, DUPLICATE_WARNING,
      )
      return BaseOutcome(
        fallback.plan,
        attemptReceipt(SummaryStatus.FAILED, fallback.usedSnapshot, null, 0, "A duplicate history-compression request was prevented."),
      )
    }

    var pending: PendingCompactionAttempt? = null
    val telemetry = CompactionTelemetry()
    try {
      // Re-read canonical rows and the head after acquiring the gate: a newer summary or an
      // edited transcript must not cause a duplicate or stale paid request.
      requireUnchanged(input, CompactionFailure.STALE_SOURCE.userMessage)
      val gateHead = store.activeSnapshot(conversationId, messages, compactionPlanner)
      val planIsCurrent = gateHead.rawArtifactId == loaded.rawArtifactId &&
        gateHead.snapshot?.id == generationPlan.previousSnapshot?.id
      if (!planIsCurrent) {
        val fallback = planner.planAfterCompactionFailure(
          messages, input.systemPrompt, conversationId, gateHead.snapshot, NEWER_SUMMARY_WARNING,
        )
        val summary = fallback.usedSnapshot?.let(::reusedReceipt)
          ?: attemptReceipt(SummaryStatus.FAILED, null, null, 0, "A stale duplicate history-compression request was prevented.")
        return BaseOutcome(fallback.plan, summary)
      }

      // Committed before the provider stream opens so an interrupted app cannot hide the request.
      val attempt = store.appendGenerating(
        conversationId = conversationId,
        assistantMessageId = input.assistantMessageId,
        connection = input.connection,
        plan = generationPlan,
        sourceThroughMessageId = messages.lastOrNull()?.id,
        sourceMessageCount = messages.size,
      )
      pending = attempt

      val generated = try {
        ConversationCompactor(estimator = planner.estimator).generate(
          plan = generationPlan,
          connection = input.connection,
          client = ProviderClientFactory.make(input.connection),
          contextPolicy = input.policy,
          telemetry = telemetry,
        )
      } catch (error: CancellationException) {
        // A user stop propagates (the outer handler records "cancelled"); any other cancellation
        // is an abnormal stream end and falls back like a failure.
        if (!currentCoroutineContext().isActive) throw error
        pending = null
        return failedAttempt(input, planner, generationPlan, attempt, telemetry, error, GENERATION_FAILED_WARNING, NOT_SAVED)
      } catch (error: Exception) {
        pending = null
        return failedAttempt(input, planner, generationPlan, attempt, telemetry, error, GENERATION_FAILED_WARNING, NOT_SAVED)
      }

      // After the asynchronous call: the exact raw source must still match.
      requireUnchanged(input, CompactionFailure.STALE_SOURCE.userMessage)
      if (!compactionPlanner.isValid(generated.snapshot, conversationId, messages)) {
        throw CompactionException(CompactionFailure.STALE_SOURCE)
      }

      val compacted = try {
        if (generated.snapshot.previousCompactionId != gateHead.snapshot?.id) {
          throw CompactionException(CompactionFailure.STALE_SOURCE)
        }
        val compactedPlan = planner.planWithSummary(messages, input.systemPrompt, conversationId, generated.snapshot)
        if (!compactionPlanner.createsMinimumSavings(compactedPlan, generated.snapshot, generationPlan)) {
          throw CompactionException(CompactionFailure.INSUFFICIENT_SAVINGS)
        }
        compactedPlan
      } catch (error: CompactionException) {
        pending = null
        return failedAttempt(input, planner, generationPlan, attempt, telemetry, error, NOT_ACTIVATED_WARNING, NOT_ACTIVATED_DETAIL)
      } catch (error: ContextPlanningException) {
        pending = null
        return failedAttempt(input, planner, generationPlan, attempt, telemetry, error, NOT_ACTIVATED_WARNING, NOT_ACTIVATED_DETAIL)
      }

      store.activate(
        pending = attempt,
        snapshot = generated.snapshot,
        expectedHeadArtifactId = gateHead.rawArtifactId,
        telemetry = telemetry.snapshot,
        estimatedInputTokensAfter = compacted.receipt.estimatedInputTokens,
      )
      pending = null
      val usage = telemetry.snapshot
      val snapshot = generated.snapshot
      val summary = ConversationSummaryReceipt(
        status = SummaryStatus.GENERATED,
        text = snapshot.renderedSummary,
        providerName = snapshot.providerName,
        providerKind = snapshot.providerKind,
        modelId = snapshot.modelId,
        host = snapshot.providerHost,
        summaryCreatedAt = snapshot.createdAt,
        extraRequestCount = 1,
        inputTokens = usage.inputTokens,
        outputTokens = usage.outputTokens,
        error = null,
      )
      rememberAttempt(input.assistantMessageId, summary)
      return BaseOutcome(compacted, summary)
    } catch (error: CancellationException) {
      pending?.let { attempt ->
        val userStop = !currentCoroutineContext().isActive
        recordAbandonedAttempt(
          input, generationPlan, attempt, telemetry.snapshot,
          if (userStop) SummaryStatus.CANCELLED else SummaryStatus.FAILED,
          if (userStop) "History compression was stopped before completion." else "The history-compression request was interrupted.",
        )
      }
      throw error
    } catch (error: Exception) {
      pending?.let { attempt ->
        recordAbandonedAttempt(
          input, generationPlan, attempt, telemetry.snapshot, SummaryStatus.FAILED,
          ErrorSanitizer.describe(error, input.connection.apiKey),
        )
      }
      throw error
    } finally {
      CompactionExecutionGate.release(conversationId)
    }
  }

  /** Records the failed attempt, then plans the explicit fallback (last valid summary or raw). */
  private suspend fun failedAttempt(
    input: ContextPlanningInput,
    planner: ContextPlanner,
    generationPlan: CompactionGenerationPlan,
    pending: PendingCompactionAttempt,
    telemetry: CompactionTelemetry,
    error: Throwable,
    warning: String,
    auditDetail: String,
  ): BaseOutcome {
    val description = ErrorSanitizer.describe(error, input.connection.apiKey)
    val fallback = runCatching {
      planner.planAfterCompactionFailure(
        input.candidates, input.systemPrompt, input.conversationId, generationPlan.previousSnapshot, warning,
      )
    }
    val usage = telemetry.snapshot
    store.appendTerminal(
      pending = pending,
      status = CompactionEventStatus.FAILED,
      telemetry = usage,
      error = description,
      activeArtifactId = fallback.getOrNull()?.usedSnapshot?.id,
      warnings = listOf(auditDetail),
    )
    rememberAttempt(
      input.assistantMessageId,
      attemptReceipt(SummaryStatus.FAILED, null, usage, if (usage.requestStarted) 1 else 0, description),
    )
    // A raw fallback that cannot fit the protected turns fails the request visibly here.
    val plan = fallback.getOrThrow()
    val active = plan.usedSnapshot
    val disclosed = if (active != null && usage.requestStarted) {
      plan.plan.withWarning(
        "Turing AI reused the last valid summary from ${active.providerName} · ${active.modelId} after this attempt failed."
      )
    } else {
      plan.plan
    }
    return BaseOutcome(
      disclosed,
      attemptReceipt(SummaryStatus.FAILED, active, usage, if (usage.requestStarted) 1 else 0, description),
    )
  }

  /**
   * Terminal audit for an attempt abandoned by a stop or an error after `generating` was
   * committed, plus a receipt on the reply so the extra request stays visible even though the
   * answer request was never sent. Never throws.
   */
  private suspend fun recordAbandonedAttempt(
    input: ContextPlanningInput,
    generationPlan: CompactionGenerationPlan,
    pending: PendingCompactionAttempt,
    telemetry: CompactionTelemetrySnapshot,
    status: SummaryStatus,
    description: String,
  ) = withContext(NonCancellable) {
    try {
      store.appendTerminal(
        pending = pending,
        status = if (status == SummaryStatus.CANCELLED) CompactionEventStatus.CANCELLED else CompactionEventStatus.FAILED,
        telemetry = telemetry,
        error = description,
        activeArtifactId = null,
        warnings = listOf("No partial or unvalidated summary was activated."),
      )
      val count = generationPlan.inputMessages.size
      val receipt = ContextReceipt(
        projectName = null,
        projectInstructions = null,
        pinnedFacts = emptyList(),
        includedMessageIds = emptyList(),
        omittedMessageIds = emptyList(),
        estimatedInputTokens = generationPlan.estimatedInputTokensBefore,
        inputBudgetTokens = input.policy.availableInputTokens,
        warnings = listOf(
          "The answer request was not sent. Only the history-summary request was made: fixed summarizer " +
            "instructions plus $count earlier message${if (count == 1) "" else "s"} of this chat.",
          "No partial or unvalidated summary was activated.",
        ),
        summary = attemptReceipt(status, null, telemetry, if (telemetry.requestStarted) 1 else 0, description),
      )
      db.receipts().upsert(
        ContextReceiptEntity(
          messageId = input.assistantMessageId,
          conversationId = input.conversationId,
          json = Codecs.encodeReceipt(receipt),
          createdAt = MonotonicClock.now(),
        )
      )
    } catch (error: Exception) {
      // The `generating` event stays and is repaired on the next launch. Only the type is logged.
      Log.w(TAG, "Could not finalize a history-compression audit (${error.javaClass.simpleName}).")
    }
  }

  private fun rememberAttempt(assistantMessageId: String, summary: ConversationSummaryReceipt) {
    // Bounded: entries only outlive planning when the reply itself failed.
    if (attemptedReplies.size >= 64) attemptedReplies.clear()
    attemptedReplies[assistantMessageId] = summary
  }

  private suspend fun requireUnchanged(input: ContextPlanningInput, message: String) {
    currentCoroutineContext().ensureActive()
    if (input.reloadRows() != input.rows) throw CompactionException(CompactionFailure.STALE_SOURCE, message)
  }

  private fun reusedReceipt(snapshot: CompactionSnapshot) = ConversationSummaryReceipt(
    status = SummaryStatus.REUSED,
    text = snapshot.renderedSummary,
    providerName = snapshot.providerName,
    providerKind = snapshot.providerKind,
    modelId = snapshot.modelId,
    host = snapshot.providerHost,
    summaryCreatedAt = snapshot.createdAt,
    extraRequestCount = 0,
    inputTokens = snapshot.inputTokens,
    outputTokens = snapshot.outputTokens,
    error = null,
  )

  private fun attemptReceipt(
    status: SummaryStatus,
    active: CompactionSnapshot?,
    telemetry: CompactionTelemetrySnapshot?,
    extraRequestCount: Int,
    error: String?,
  ) = ConversationSummaryReceipt(
    status = status,
    text = active?.renderedSummary,
    providerName = active?.providerName,
    providerKind = active?.providerKind,
    modelId = active?.modelId,
    host = active?.providerHost,
    summaryCreatedAt = active?.createdAt,
    extraRequestCount = extraRequestCount,
    inputTokens = telemetry?.inputTokens,
    outputTokens = telemetry?.outputTokens,
    error = error,
  )

  private companion object {
    const val TAG = "TuringCompaction"
    const val FINAL_STALE_MESSAGE = "The chat changed while Turing AI was preparing this reply. Try sending again."
    const val INVALIDATED_SUMMARY_WARNING =
      "The saved summary of older messages no longer matches this chat (a covered message changed or was " +
        "deleted), so Turing AI did not use it."
    const val REUSE_DID_NOT_FIT_WARNING =
      "The stored summary did not fit the selected model's smaller safe input budget, so Turing AI used recent " +
        "raw history for this request."
    const val DUPLICATE_WARNING =
      "Another request is already compressing this chat, so Turing AI avoided a duplicate provider request."
    const val NEWER_SUMMARY_WARNING =
      "A newer app-owned summary became active before this request started, so Turing AI avoided a duplicate " +
        "provider request."
    const val GENERATION_FAILED_WARNING =
      "The new compression attempt failed, so Turing AI kept using the last valid summary when it fit."
    const val NOT_ACTIVATED_WARNING =
      "The new summary did not fit or create enough safe room, so Turing AI kept using the last valid summary " +
        "when it fit."
    const val ONE_ATTEMPT_WARNING =
      "Turing AI already made one history-summary request for this reply and did not repeat it."
    val ALREADY_ATTEMPTED_RECEIPT = ConversationSummaryReceipt(
      status = SummaryStatus.FAILED,
      text = null,
      providerName = null,
      providerKind = null,
      modelId = null,
      host = null,
      summaryCreatedAt = null,
      extraRequestCount = 0,
      inputTokens = null,
      outputTokens = null,
      error = "A history-summary request was already made for this reply; see Usage for its reported tokens.",
    )
    const val NOT_SAVED = "No partial or unvalidated summary was saved."
    const val NOT_ACTIVATED_DETAIL =
      "The generated summary was validated but not activated because it did not fit with the protected recent " +
        "turns or reduce the request enough."
  }
}

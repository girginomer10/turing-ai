package com.omergirgin.mosaic.data.recall

import android.util.Log
import com.omergirgin.mosaic.core.chat.ProviderClientFactory
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.TokenUsage
import com.omergirgin.mosaic.core.retrieval.RetrievalCandidate
import com.omergirgin.mosaic.core.retrieval.SemanticScoreSet
import com.omergirgin.mosaic.core.retrieval.SmartMemoryRanker
import com.omergirgin.mosaic.core.retrieval.SmartMemoryRankingException
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.UsageRecordEntity
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.internal.newId
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/** Result of the smart memory stage for one recall. */
internal class SmartRankingOutcome(
  /** The validated selection (possibly empty); null when ranking fell back. */
  val scores: SemanticScoreSet?,
  /** Usage or fallback disclosure for the receipt (iOS warning text). */
  val warning: String,
  val receipt: SmartRankingReceipt,
)

/** Carries the smart memory outcome out of every recall return path, including fallbacks. */
internal class SmartRankingSlot {
  var outcome: SmartRankingOutcome? = null
}

/**
 * Attaches the smart memory receipt (and keeps its usage/fallback disclosure in the warnings,
 * even when a later stage replaced them with its own fallback warning).
 */
internal fun PreparedRecall.withSmartRanking(outcome: SmartRankingOutcome?): PreparedRecall {
  outcome ?: return this
  val base = receipt ?: RecallReceipt(emptyList(), listOf(PreparedRecall.LOCAL_ENGINE), emptyList(), emptyList())
  val warnings = if (outcome.warning in base.warnings) base.warnings else listOf(outcome.warning) + base.warnings
  return PreparedRecall(systemContent, base.copy(warnings = warnings, smartRanking = outcome.receipt), scope, selected)
}

/**
 * Smart memory stage of iOS `SemanticMemoryCoordinator.retrieve`: before embeddings, the bounded
 * local pool (at most 40 short excerpts) is checked once by the chat model the user selected.
 * Only exact candidate IDs are accepted; any invalid, failed, interrupted or timed-out ranking
 * falls back to local matching/enabled embeddings with a receipt warning. The request is
 * recorded as "Smart memory" usage before it starts, so an interrupted attempt stays visible.
 */
internal class SmartMemoryRecall(
  private val db: MosaicDatabase,
  private val enabled: suspend () -> Boolean,
  private val timeoutMillis: Long = SmartMemoryRanker.TIMEOUT_MILLIS,
) {
  /** Unreadable settings never trigger an extra paid request. */
  suspend fun isEnabled(): Boolean = try {
    enabled()
  } catch (error: CancellationException) {
    throw error
  } catch (error: Exception) {
    false
  }

  /**
   * Ranks [pool] with [connection]. [isPoolCurrent] must confirm every pool item is still current
   * immediately before any excerpt leaves the device. Caller cancellation is rethrown.
   */
  suspend fun rank(
    conversationId: String,
    query: String,
    pool: List<RetrievalCandidate>,
    connection: ProviderConnection,
    isPoolCurrent: suspend () -> Boolean,
  ): SmartRankingOutcome {
    var usage: TokenUsage? = null
    var usageId: String? = null
    var sent = false
    try {
      if (!isPoolCurrent()) throw SmartMemoryRankingException("A candidate changed before ranking.")
      usageId = begin(connection, conversationId)
      sent = true
      val result = SmartMemoryRanker.rank(
        query = query,
        candidates = pool,
        client = ProviderClientFactory.make(connection),
        timeoutMillis = timeoutMillis,
        onUsage = { usage = it },
      )
      usage = result.usage ?: usage
      val reported = usage
      val warning = if (reported != null) {
        "Smart memory used ${reported.inputTokens?.toString() ?: "unreported"} input and " +
          "${reported.outputTokens?.toString() ?: "unreported"} output tokens with the selected chat model."
      } else {
        "Smart memory used the selected chat model; token usage was not reported."
      }
      return SmartRankingOutcome(
        scores = result.scores,
        warning = warning,
        receipt = receipt(SmartRankingStatus.USED, connection, pool.size, result.scores.scores.size, reported),
      )
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      // Only the type is logged; provider messages could echo request content.
      Log.i(TAG, "Smart memory fell back (${error.javaClass.simpleName}).")
      return SmartRankingOutcome(
        scores = null,
        warning = FALLBACK_WARNING,
        receipt = receipt(SmartRankingStatus.FALLBACK, connection, if (sent) pool.size else 0, 0, usage),
      )
    } finally {
      usageId?.let { finish(it, usage) }
    }
  }

  private fun receipt(
    status: SmartRankingStatus,
    connection: ProviderConnection,
    candidates: Int,
    selected: Int,
    usage: TokenUsage?,
  ) = SmartRankingReceipt(
    status = status,
    providerName = connection.displayName,
    providerKind = connection.provider.rawId,
    host = connection.destinationHost,
    modelId = connection.modelId,
    candidateCount = candidates,
    selectedCount = selected,
    inputTokens = usage?.inputTokens,
    outputTokens = usage?.outputTokens,
  )

  /** Bookkeeping never fails recall; a row that could not be written leaves the id null. */
  private suspend fun begin(connection: ProviderConnection, conversationId: String): String? =
    withContext(NonCancellable) {
      val id = newId()
      runCatching {
        db.usage().insert(
          UsageRecordEntity(
            id = id,
            providerId = connection.id,
            providerKind = connection.provider.rawId,
            providerName = connection.displayName,
            modelId = connection.modelId,
            destinationHost = connection.destinationHost,
            category = USAGE_CATEGORY,
            inputTokens = null,
            outputTokens = null,
            conversationId = conversationId,
            messageId = null,
            createdAt = MonotonicClock.now(),
          )
        )
        id
      }.getOrNull()
    }

  private suspend fun finish(id: String, usage: TokenUsage?) {
    if (usage == null) return
    withContext(NonCancellable) {
      runCatching { db.usage().reportTokens(id, usage.inputTokens, usage.outputTokens) }
    }
  }

  companion object {
    private const val TAG = "TuringRecall"
    /** iOS usage category for the relevance request. */
    const val USAGE_CATEGORY = "Smart memory"
    const val FALLBACK_WARNING =
      "Smart memory was unavailable; used local matching or enabled embeddings. The attempted relevance check " +
        "may have consumed provider credits."
  }
}

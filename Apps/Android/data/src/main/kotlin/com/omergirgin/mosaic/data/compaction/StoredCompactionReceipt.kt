package com.omergirgin.mosaic.data.compaction

import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.data.model.ConversationSummaryReceipt
import com.omergirgin.mosaic.data.model.SameChatExcerpt
import com.omergirgin.mosaic.data.model.SameChatRecallOrigin
import com.omergirgin.mosaic.data.model.SummaryStatus
import kotlinx.serialization.Serializable

/*
 * On-disk shape of the compaction/recall parts of a context receipt. Field names are part of the
 * storage format; every field has a default so older receipt JSON keeps decoding.
 */

@Serializable
internal data class StoredSummaryReceipt(
  /** `SummaryStatus.name`; unknown values decode as NONE. */
  val status: String = SummaryStatus.NONE.name,
  val text: String? = null,
  val providerName: String? = null,
  /** `ProviderKind.rawId`. */
  val providerKind: String? = null,
  val modelId: String? = null,
  val host: String? = null,
  val summaryCreatedAt: Long? = null,
  val extraRequestCount: Int = 0,
  val inputTokens: Int? = null,
  val outputTokens: Int? = null,
  val error: String? = null,
)

@Serializable
internal data class StoredSameChatExcerpt(
  val messageId: String,
  val text: String,
  /** `SameChatRecallOrigin.name`. */
  val origin: String,
  val createdAt: Long = 0,
  val isTruncated: Boolean = false,
)

internal object CompactionReceiptCodec {
  fun store(summary: ConversationSummaryReceipt?): StoredSummaryReceipt? = summary?.let {
    StoredSummaryReceipt(
      status = it.status.name,
      text = it.text,
      providerName = it.providerName,
      providerKind = it.providerKind?.rawId,
      modelId = it.modelId,
      host = it.host,
      summaryCreatedAt = it.summaryCreatedAt,
      extraRequestCount = it.extraRequestCount,
      inputTokens = it.inputTokens,
      outputTokens = it.outputTokens,
      error = it.error,
    )
  }

  fun load(stored: StoredSummaryReceipt?): ConversationSummaryReceipt? = stored?.let {
    ConversationSummaryReceipt(
      status = SummaryStatus.entries.firstOrNull { status -> status.name == it.status } ?: SummaryStatus.NONE,
      text = it.text,
      providerName = it.providerName,
      providerKind = it.providerKind?.let(ProviderKind::fromRawId),
      modelId = it.modelId,
      host = it.host,
      summaryCreatedAt = it.summaryCreatedAt,
      extraRequestCount = it.extraRequestCount,
      inputTokens = it.inputTokens,
      outputTokens = it.outputTokens,
      error = it.error,
    )
  }

  fun storeExcerpts(excerpts: List<SameChatExcerpt>): List<StoredSameChatExcerpt> = excerpts.map {
    StoredSameChatExcerpt(it.messageId, it.text, it.origin.name, it.createdAt, it.isTruncated)
  }

  /** An excerpt with an unknown origin label is dropped rather than shown with a wrong label. */
  fun loadExcerpts(stored: List<StoredSameChatExcerpt>): List<SameChatExcerpt> = stored.mapNotNull { excerpt ->
    val origin = SameChatRecallOrigin.entries.firstOrNull { it.name == excerpt.origin } ?: return@mapNotNull null
    SameChatExcerpt(excerpt.messageId, excerpt.text, origin, excerpt.createdAt, excerpt.isTruncated)
  }
}

package com.omergirgin.mosaic.data.recall

import kotlinx.serialization.Serializable

/**
 * Cross-chat, document and topic recall attached to one request (part of `ContextReceipt`).
 * Recalled text was sent as untrusted reference data; [warnings] disclose every fallback.
 */
data class RecallReceipt(
  val items: List<RecalledItem>,
  /** Ranking engines used, e.g. "Local hybrid" plus each embedding profile that contributed. */
  val engines: List<String>,
  /** Embedding profiles that received the recall query and/or candidate excerpts. */
  val embeddingDestinations: List<RecallEmbeddingDestination>,
  val warnings: List<String>,
  /**
   * Smart memory relevance check for this request (null when it did not run). Its usage and any
   * fallback are also spelled out in [warnings], like iOS.
   */
  val smartRanking: SmartRankingReceipt? = null,
)

enum class SmartRankingStatus(val rawValue: String) {
  /** The model's validated selection ranked recall ("Smart memory" engine). */
  USED("used"),
  /** Invalid, failed, interrupted or timed-out ranking; local matching/embeddings were used. */
  FALLBACK("fallback"),
}

/** The extra relevance request sent to the selected chat model (provider, host and usage). */
data class SmartRankingReceipt(
  val status: SmartRankingStatus,
  val providerName: String,
  /** `ProviderKind.rawId`. */
  val providerKind: String,
  val host: String?,
  val modelId: String,
  /** Short candidate excerpts sent (at most 40). */
  val candidateCount: Int,
  /** Exact candidate IDs the model selected (at most six); 0 on fallback. */
  val selectedCount: Int,
  /** Reported usage; null when the provider did not report it. */
  val inputTokens: Int?,
  val outputTokens: Int?,
)

/** One excerpt included in the request (the exact, possibly truncated, text sent). */
data class RecalledItem(
  val kind: RecallSourceKind,
  val id: String,
  val containerId: String,
  val title: String,
  val excerpt: String,
  /** 1-based PDF page for document chunks. */
  val pageNumber: Int?,
  val isOcrDerived: Boolean,
  /** Dated personal report (learned-topic event), never a standing fact. */
  val isEvent: Boolean,
  val recordedAt: String?,
  val createdAt: Long,
  val relevance: Double,
)

/** Where an embedding request for this recall went (profile, connection, host and model). */
data class RecallEmbeddingDestination(
  val profileName: String,
  val providerName: String,
  /** `ProviderKind.rawId`. */
  val providerKind: String,
  val host: String?,
  val modelId: String,
)

/* Versioned storage form inside the receipt JSON; field names are part of the storage format. */

@Serializable
internal data class StoredRecallReceipt(
  val items: List<StoredRecalledItem> = emptyList(),
  val engines: List<String> = emptyList(),
  val destinations: List<StoredRecallDestination> = emptyList(),
  val warnings: List<String> = emptyList(),
  /** Added together with smart ranking; absent in older receipts. */
  val smart: StoredSmartRanking? = null,
)

@Serializable
internal data class StoredSmartRanking(
  val status: String,
  val providerName: String,
  val providerKind: String,
  val host: String? = null,
  val modelId: String,
  val candidates: Int = 0,
  val selected: Int = 0,
  val input: Int? = null,
  val output: Int? = null,
)

@Serializable
internal data class StoredRecalledItem(
  val kind: String,
  val id: String,
  val containerId: String,
  val title: String = "",
  val excerpt: String = "",
  val page: Int? = null,
  val ocr: Boolean = false,
  val event: Boolean = false,
  val recordedAt: String? = null,
  val createdAt: Long = 0,
  val relevance: Double = 0.0,
)

@Serializable
internal data class StoredRecallDestination(
  val profileName: String,
  val providerName: String,
  val providerKind: String,
  val host: String? = null,
  val modelId: String,
)

internal fun RecallReceipt.toStored(): StoredRecallReceipt = StoredRecallReceipt(
  items = items.map {
    StoredRecalledItem(
      kind = it.kind.rawValue,
      id = it.id,
      containerId = it.containerId,
      title = it.title,
      excerpt = it.excerpt,
      page = it.pageNumber,
      ocr = it.isOcrDerived,
      event = it.isEvent,
      recordedAt = it.recordedAt,
      createdAt = it.createdAt,
      relevance = if (it.relevance.isFinite()) it.relevance else 0.0,
    )
  },
  engines = engines,
  destinations = embeddingDestinations.map {
    StoredRecallDestination(it.profileName, it.providerName, it.providerKind, it.host, it.modelId)
  },
  warnings = warnings,
  smart = smartRanking?.let {
    StoredSmartRanking(
      status = it.status.rawValue,
      providerName = it.providerName,
      providerKind = it.providerKind,
      host = it.host,
      modelId = it.modelId,
      candidates = it.candidateCount,
      selected = it.selectedCount,
      input = it.inputTokens,
      output = it.outputTokens,
    )
  },
)

internal fun StoredRecallReceipt.toModel(): RecallReceipt = RecallReceipt(
  items = items.mapNotNull { stored ->
    val kind = RecallSourceKind.entries.firstOrNull { it.rawValue == stored.kind } ?: return@mapNotNull null
    RecalledItem(
      kind = kind,
      id = stored.id,
      containerId = stored.containerId,
      title = stored.title,
      excerpt = stored.excerpt,
      pageNumber = stored.page,
      isOcrDerived = stored.ocr,
      isEvent = stored.event,
      recordedAt = stored.recordedAt,
      createdAt = stored.createdAt,
      relevance = stored.relevance,
    )
  },
  engines = engines,
  embeddingDestinations = destinations.map {
    RecallEmbeddingDestination(it.profileName, it.providerName, it.providerKind, it.host, it.modelId)
  },
  warnings = warnings,
  smartRanking = smart?.let { stored ->
    SmartRankingReceipt(
      status = SmartRankingStatus.entries.firstOrNull { it.rawValue == stored.status } ?: SmartRankingStatus.FALLBACK,
      providerName = stored.providerName,
      providerKind = stored.providerKind,
      host = stored.host,
      modelId = stored.modelId,
      candidateCount = stored.candidates,
      selectedCount = stored.selected,
      inputTokens = stored.input,
      outputTokens = stored.output,
    )
  },
)

internal object RecallReceiptCodec {
  fun store(receipt: RecallReceipt): StoredRecallReceipt = receipt.toStored()

  fun load(stored: StoredRecallReceipt): RecallReceipt = stored.toModel()
}

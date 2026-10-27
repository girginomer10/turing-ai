package com.omergirgin.mosaic.core.retrieval

/** Raw values match iOS `RetrievalSourceKind` and appear in the rendered recall block. */
enum class RetrievalSourceKind(val rawValue: String) {
  CONVERSATION_MESSAGE("conversation_message"),
  DOCUMENT_CHUNK("document_chunk"),
  MEMORY_TOPIC("memory_topic");

  companion object {
    fun fromRawValue(raw: String): RetrievalSourceKind? = entries.firstOrNull { it.rawValue == raw }
  }
}

/** Well-known attribute keys rendered on a recalled `<source>` element. */
object RetrievalAttributes {
  const val PAGE = "page"
  /** `"ocr"` when the excerpt's text came from on-device OCR. */
  const val EXTRACTION = "extraction"
  /** `"event"` marks a dated personal report (capped at two items per request). */
  const val MEMORY_LAYER = "memory_layer"
  /** ISO-8601 instant the event was reported; defaults to the candidate's creation date. */
  const val RECORDED_AT = "recorded_at"

  const val EXTRACTION_OCR = "ocr"
  const val MEMORY_LAYER_EVENT = "event"

  private val keyPattern = Regex("[a-z][a-z0-9_]{0,31}")

  internal fun isRenderableKey(key: String): Boolean = keyPattern.matches(key)
}

/** Immutable snapshot of one recallable item handed to [HybridMemoryRetriever]. */
data class RetrievalCandidate(
  val id: String,
  val kind: RetrievalSourceKind,
  /** Diversification container (conversation, document or topic ID). */
  val containerId: String,
  val title: String,
  val content: String,
  val createdAt: Long,
  val attributes: Map<String, String> = emptyMap(),
  /** Learned-topic confidence/importance in 0...1 (iOS defaults 0.65 / 0.5 when absent). */
  val confidence: Double? = null,
  val importance: Double? = null,
  /** Multiplies the fused score (event recency decay); 1.0 is neutral. */
  val weight: Double = 1.0,
) {
  val pageNumber: Int? get() = attributes[RetrievalAttributes.PAGE]?.toIntOrNull()
  val isOcrDerived: Boolean get() = attributes[RetrievalAttributes.EXTRACTION] == RetrievalAttributes.EXTRACTION_OCR
  val isEvent: Boolean get() = attributes[RetrievalAttributes.MEMORY_LAYER] == RetrievalAttributes.MEMORY_LAYER_EVENT
}

/** Cosine scores from one embedding profile. Each profile is its own vector space. */
class SemanticScoreSet(val profileName: String, weight: Double = 1.0, val scores: Map<String, Double>) {
  val weight: Double = maxOf(0.05, weight)
}

class LocalRetrievalPreparation(
  val candidatePool: List<RetrievalCandidate>,
  val scores: Map<String, Double>,
)

/** One selected excerpt; [candidate] carries the (possibly truncated) excerpt text. */
data class RetrievedItem(val candidate: RetrievalCandidate, val relevance: Double)

/** Exact past-chat, document and topic excerpts attached to one request. */
data class RetrievedContext(
  /** Rendered untrusted-data block; empty when nothing was selected. */
  val systemContent: String,
  val items: List<RetrievedItem>,
  val embeddingProfilesUsed: List<String> = emptyList(),
  val warnings: List<String> = emptyList(),
) {
  val isEmpty: Boolean get() = items.isEmpty()

  companion object {
    val EMPTY = RetrievedContext("", emptyList())
  }
}

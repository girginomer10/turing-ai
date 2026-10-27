package com.omergirgin.mosaic.data.recall

/*
 * Seam between cross-chat/document recall (retrieval) and automatic memory (learned topics).
 * Retrieval owns ranking, embeddings and prompt rendering; other features contribute candidates
 * through [RecallCandidateSource] and register them in DataContainer
 * (`RecallSourceRegistry.register`).
 */

enum class RecallSourceKind(val rawValue: String) {
  CONVERSATION_MESSAGE("conversation_message"),
  DOCUMENT_CHUNK("document_chunk"),
  MEMORY_TOPIC("memory_topic"),
}

/** Audience of one request (iOS project scope rules). */
data class RecallScope(
  val conversationId: String,
  /** null = unassigned chat: global + unassigned sources only. */
  val projectId: String?,
)

/** Immutable snapshot of one recallable item. Never a Room entity. */
data class RecallCandidate(
  val kind: RecallSourceKind,
  /** Stable source ID (message, chunk or topic ID). */
  val id: String,
  /** Container used for diversification (conversation, document or topic ID). */
  val containerId: String,
  val title: String?,
  val text: String,
  /** SHA-256 hex of [text]; vectors and receipts are bound to it. */
  val contentFingerprint: String,
  val createdAt: Long,
  /**
   * Extra attributes rendered with the item. Well-known keys are in [RecallAttributes]
   * (`memory_layer="event"` + `recorded_at` for events, `page`, `extraction="ocr"`); other keys must
   * match `[a-z][a-z0-9_]{0,31}` to be rendered.
   */
  val attributes: Map<String, String> = emptyMap(),
  /** Ranking hint, e.g. event recency decay in 0.15...1.0. 1.0 = neutral. */
  val weight: Double = 1.0,
  /** Learned-topic confidence in 0...1 (topic candidates only; default 0.65). */
  val confidence: Double? = null,
  /** Learned-topic importance in 0...1 (topic candidates only; default 0.5). */
  val importance: Double? = null,
)

/** Attribute keys understood by the retriever (same names as the iOS recall block). */
object RecallAttributes {
  const val PAGE = "page"
  const val EXTRACTION = "extraction"
  const val MEMORY_LAYER = "memory_layer"
  /** ISO-8601 UTC instant, e.g. `2026-10-09T08:15:00Z` (see `HybridMemoryRetriever.iso8601`). */
  const val RECORDED_AT = "recorded_at"
  const val EXTRACTION_OCR = "ocr"
  /** At most two event items are recalled per request. */
  const val MEMORY_LAYER_EVENT = "event"
}

fun interface RecallCandidateSource {
  /** Bounded snapshot of candidates visible to [scope]. Must not block the main thread. */
  suspend fun candidates(scope: RecallScope): List<RecallCandidate>

  /**
   * IDs of [candidates] (previously returned by this source) that are still current for [scope]:
   * same text fingerprint, still enabled/active, still inside the audience. Called after every
   * network suspension and immediately before the chat request. The default re-reads [candidates];
   * sources with a cheaper by-ID lookup should override it.
   */
  suspend fun validate(scope: RecallScope, candidates: List<RecallCandidate>): Set<String> {
    if (candidates.isEmpty()) return emptySet()
    val current = candidates(scope).associateBy { it.id }
    return candidates.mapNotNullTo(HashSet()) { candidate ->
      val fresh = current[candidate.id] ?: return@mapNotNullTo null
      candidate.id.takeIf {
        fresh.kind == candidate.kind &&
          fresh.containerId == candidate.containerId &&
          fresh.contentFingerprint == candidate.contentFingerprint
      }
    }
  }
}

/**
 * Optional hook (registered by automatic memory): earlier-chat user messages already consolidated
 * as learned-topic evidence are suppressed from raw cross-chat recall, so pausing, forgetting or
 * correcting the topic cannot be bypassed through its old source excerpt.
 */
fun interface RecallMessageSuppression {
  suspend fun suppressedMessageIds(messageIds: List<String>): Set<String>
}

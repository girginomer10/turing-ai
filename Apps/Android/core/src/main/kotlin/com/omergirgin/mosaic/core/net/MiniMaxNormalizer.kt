package com.omergirgin.mosaic.core.net

import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import com.omergirgin.mosaic.core.chat.StreamEvent

/**
 * MiniMax documents `delta.content` as the full text accumulated so far, while every other
 * OpenAI-compatible host sends true deltas. Forwarding snapshots directly would duplicate all
 * prior text in chat, automation and compaction output, so this request-local normalizer emits
 * only the new suffix.
 *
 * Comparison happens on UTF-8 bytes: the previous snapshot is a complete string, so its byte
 * length is always a code point boundary in the next snapshot and the suffix decodes cleanly. A
 * snapshot that does not extend the previous one fails closed rather than guessing at a merge.
 */
internal class MiniMaxStreamNormalizer {
  private var accumulated = ByteArray(0)

  fun normalize(events: List<StreamEvent>): List<StreamEvent> {
    if (events.none { it is StreamEvent.TextDelta }) return events
    val normalized = ArrayList<StreamEvent>(events.size)
    for (event in events) {
      if (event !is StreamEvent.TextDelta) {
        normalized += event
        continue
      }
      val snapshot = event.text.encodeToByteArray()
      if (snapshot.size > MAX_STREAM_TEXT_BYTES) {
        throw ProviderFailures.of(ProviderErrorKind.RESPONSE_TOO_LARGE)
      }
      if (!snapshot.startsWith(accumulated)) {
        throw ProviderFailures.of(
          ProviderErrorKind.INVALID_RESPONSE,
          "MiniMax returned a streaming snapshot that does not extend the earlier text.",
        )
      }
      val suffix = snapshot.copyOfRange(accumulated.size, snapshot.size)
      accumulated = snapshot
      if (suffix.isNotEmpty()) normalized += StreamEvent.TextDelta(suffix.decodeToString())
    }
    return normalized
  }

  private fun ByteArray.startsWith(prefix: ByteArray): Boolean {
    if (prefix.size > size) return false
    for (index in prefix.indices) if (this[index] != prefix[index]) return false
    return true
  }
}

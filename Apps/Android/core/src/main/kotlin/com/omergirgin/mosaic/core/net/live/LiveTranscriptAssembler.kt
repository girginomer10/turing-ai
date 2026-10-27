package com.omergirgin.mosaic.core.net.live

data class LiveTranscriptSnapshot(
  val finalizedText: String,
  val interimText: String?,
  val displayText: String,
  val languageCode: String?,
) {
  companion object {
    val EMPTY = LiveTranscriptSnapshot(finalizedText = "", interimText = null, displayText = "", languageCode = null)
  }
}

/**
 * Deterministic reducer for rendering speculative text without committing it: interim hypotheses
 * replace each other, and only final events are appended to [LiveTranscriptSnapshot.finalizedText].
 */
class LiveTranscriptAssembler(private val maximumTranscriptBytes: Int = DEFAULT_MAXIMUM_TRANSCRIPT_BYTES) {
  init {
    if (maximumTranscriptBytes !in 1..DEFAULT_MAXIMUM_TRANSCRIPT_BYTES) {
      throw LiveTranscriptionException.invalidConfiguration(
        "The transcript size limit must be between 1 byte and $DEFAULT_MAXIMUM_TRANSCRIPT_BYTES bytes."
      )
    }
  }

  var snapshot: LiveTranscriptSnapshot = LiveTranscriptSnapshot.EMPTY
    private set

  fun consume(event: LiveTranscriptionEvent): LiveTranscriptSnapshot {
    when (event) {
      is LiveTranscriptionEvent.InterimTranscript -> {
        val interim = event.text.trim().ifEmpty { null }
        val displayText = joinTranscript(snapshot.finalizedText, interim.orEmpty())
        validate(displayText)
        snapshot = snapshot.copy(
          interimText = interim,
          displayText = displayText,
          languageCode = event.languageCode ?: snapshot.languageCode,
        )
      }
      is LiveTranscriptionEvent.FinalTranscript -> {
        val finalizedText = joinTranscript(snapshot.finalizedText, event.text.trim())
        validate(finalizedText)
        snapshot = LiveTranscriptSnapshot(
          finalizedText = finalizedText,
          interimText = null,
          displayText = finalizedText,
          languageCode = event.languageCode ?: snapshot.languageCode,
        )
      }
      is LiveTranscriptionEvent.Ended -> snapshot = snapshot.copy(interimText = null, displayText = snapshot.finalizedText)
      LiveTranscriptionEvent.SetupComplete,
      LiveTranscriptionEvent.TurnComplete,
      is LiveTranscriptionEvent.DurationLimitApproaching,
      is LiveTranscriptionEvent.GoAway -> Unit
    }
    return snapshot
  }

  fun reset() {
    snapshot = LiveTranscriptSnapshot.EMPTY
  }

  private fun validate(text: String) {
    if (text.length > maximumTranscriptBytes || text.encodeToByteArray().size > maximumTranscriptBytes) {
      throw LiveTranscriptionException.of(LiveTranscriptionException.Kind.RESPONSE_TOO_LARGE)
    }
  }

  companion object {
    const val DEFAULT_MAXIMUM_TRANSCRIPT_BYTES = 4 * 1_024 * 1_024
  }
}

private const val PUNCTUATION_WITHOUT_LEADING_SPACE = ",.;:!?%…)]}"

/**
 * Joins dictated text onto existing text: no separator after whitespace or before closing
 * punctuation, one space otherwise (iOS `join` / `joinedDraftText`).
 */
fun joinTranscript(existing: String, addition: String): String {
  if (existing.isEmpty()) return addition
  if (addition.isEmpty()) return existing
  if (existing.last().isWhitespace()) return existing + addition
  if (addition.first() in PUNCTUATION_WITHOUT_LEADING_SPACE) return existing + addition
  return "$existing $addition"
}

package com.omergirgin.mosaic.core.net.live

import kotlinx.coroutines.channels.ReceiveChannel

/** How Gemini Live balances literal transcription against readability. */
enum class LiveTranscriptionMode(val wireValue: String) {
  VERBATIM("VERBATIM"),
  SMART("SMART"),
}

/**
 * Provider-independent options for one live transcription session. An empty language list asks
 * the provider to detect the language; hints use BCP-47 syntax such as `tr-TR` or `en-US`.
 */
class LiveTranscriptionConfiguration(
  languageCodes: List<String> = emptyList(),
  val mode: LiveTranscriptionMode = LiveTranscriptionMode.SMART,
  customVocabulary: List<String> = emptyList(),
) {
  val languageCodes: List<String>
  val customVocabulary: List<String>

  init {
    if (languageCodes.size > MAXIMUM_LANGUAGE_COUNT) {
      throw LiveTranscriptionException.invalidConfiguration(
        "Live transcription supports at most $MAXIMUM_LANGUAGE_COUNT language hints."
      )
    }
    if (!languageCodes.all(::isValidLanguageCode)) {
      throw LiveTranscriptionException.invalidConfiguration("Language hints must be valid BCP-47 identifiers.")
    }
    if (customVocabulary.size > MAXIMUM_VOCABULARY_COUNT) {
      throw LiveTranscriptionException.invalidConfiguration(
        "Custom vocabulary supports at most $MAXIMUM_VOCABULARY_COUNT entries."
      )
    }
    val normalized = customVocabulary.map { it.trim() }
    if (!normalized.all { it.isNotEmpty() && it.encodeToByteArray().size <= MAXIMUM_VOCABULARY_ENTRY_BYTES }) {
      throw LiveTranscriptionException.invalidConfiguration(
        "Custom vocabulary entries must be non-empty and at most $MAXIMUM_VOCABULARY_ENTRY_BYTES bytes."
      )
    }
    if (normalized.sumOf { it.encodeToByteArray().size } > MAXIMUM_VOCABULARY_BYTES) {
      throw LiveTranscriptionException.invalidConfiguration("Custom vocabulary exceeds the live transcription size limit.")
    }
    this.languageCodes = languageCodes.toList()
    this.customVocabulary = normalized
  }

  companion object {
    const val MAXIMUM_LANGUAGE_COUNT = 8
    const val MAXIMUM_VOCABULARY_COUNT = 1_000
    const val MAXIMUM_VOCABULARY_ENTRY_BYTES = 128
    const val MAXIMUM_VOCABULARY_BYTES = 128 * 1_024

    private fun isValidLanguageCode(value: String): Boolean {
      if (value.isEmpty() || value.length > 63) return false
      if (value.first() == '-' || value.last() == '-') return false
      var previousWasHyphen = false
      for (char in value) {
        val isHyphen = char == '-'
        if (!(char in 'a'..'z' || char in 'A'..'Z' || char in '0'..'9' || isHyphen)) return false
        if (isHyphen && previousWasHyphen) return false
        previousWasHyphen = isHyphen
      }
      return true
    }
  }
}

/** A bounded packet of raw signed 16-bit little-endian, mono, 16 kHz PCM audio. */
class LivePcm16Chunk(data: ByteArray) {
  val data: ByteArray

  init {
    if (data.isEmpty()) throw LiveTranscriptionException.invalidAudioChunk("An audio chunk cannot be empty.")
    if (data.size % BYTES_PER_FRAME != 0) {
      throw LiveTranscriptionException.invalidAudioChunk("PCM16 audio must contain complete two-byte frames.")
    }
    if (data.size > MAXIMUM_FRAME_COUNT * BYTES_PER_FRAME) {
      throw LiveTranscriptionException.invalidAudioChunk("An audio chunk cannot exceed $MAXIMUM_FRAME_COUNT PCM frames.")
    }
    this.data = data
  }

  val frameCount: Int get() = data.size / BYTES_PER_FRAME

  companion object {
    const val SAMPLE_RATE = 16_000
    const val CHANNEL_COUNT = 1
    const val BYTES_PER_FRAME = 2
    const val MAXIMUM_FRAME_COUNT = 2_048
    /** 100 ms of audio per chunk. */
    const val FRAMES_PER_CHUNK = SAMPLE_RATE / 10
  }
}

enum class LiveTranscriptionEndReason { CANCELLED, DURATION_LIMIT_REACHED }

/**
 * Events stay independent from chat providers so dictated text can be sent to any configured
 * model after transcription.
 */
sealed interface LiveTranscriptionEvent {
  data object SetupComplete : LiveTranscriptionEvent
  data class InterimTranscript(val text: String, val languageCode: String?) : LiveTranscriptionEvent
  data class FinalTranscript(val text: String, val languageCode: String?) : LiveTranscriptionEvent
  data object TurnComplete : LiveTranscriptionEvent
  /** Local wrap-up warning 15 s before the hard session limit (585 s into a 600 s session). */
  data class DurationLimitApproaching(val timeLeftSeconds: Double) : LiveTranscriptionEvent
  /** The provider asked to close this connection. */
  data class GoAway(val timeLeftSeconds: Double?) : LiveTranscriptionEvent
  data class Ended(val reason: LiveTranscriptionEndReason) : LiveTranscriptionEvent
}

enum class LiveFinalizationResult {
  /** Gemini emitted a final transcript after Turing AI closed the audio stream. */
  FINAL_TRANSCRIPT_RECEIVED,
  /** Gemini confirmed that the current turn completed after the audio stream closed. */
  TURN_COMPLETED,
  /** The bounded drain elapsed without a speculative transcript left unresolved (silence). */
  NOTHING_PENDING,
  /** The bounded drain elapsed while an interim transcript was still unresolved. */
  TIMED_OUT;

  val mayHaveUnconfirmedWords: Boolean get() = this == TIMED_OUT
}

/** Failure of a live transcription session. Messages are user-presentable and never contain the key. */
class LiveTranscriptionException(val kind: Kind, message: String) : Exception(message) {
  enum class Kind {
    MISSING_API_KEY,
    INVALID_CONFIGURATION,
    INVALID_AUDIO_CHUNK,
    SETUP_NOT_COMPLETE,
    SETUP_TIMED_OUT,
    SESSION_ENDED,
    FINALIZATION_TIMED_OUT,
    BACKPRESSURE,
    RESPONSE_TOO_LARGE,
    INVALID_RESPONSE,
    PROVIDER,
    TRANSPORT,
  }

  companion object {
    fun of(kind: Kind): LiveTranscriptionException = LiveTranscriptionException(kind, defaultMessage(kind))

    fun invalidConfiguration(message: String) = LiveTranscriptionException(Kind.INVALID_CONFIGURATION, message)
    fun invalidAudioChunk(message: String) = LiveTranscriptionException(Kind.INVALID_AUDIO_CHUNK, message)
    fun provider(message: String) = LiveTranscriptionException(Kind.PROVIDER, message)
    fun transport(message: String) = LiveTranscriptionException(Kind.TRANSPORT, message)

    fun defaultMessage(kind: Kind): String = when (kind) {
      Kind.MISSING_API_KEY -> "Add a Google API key before starting live transcription."
      Kind.INVALID_CONFIGURATION -> "Turing AI could not prepare the live transcription request."
      Kind.INVALID_AUDIO_CHUNK -> "The microphone produced audio Turing AI could not send."
      Kind.SETUP_NOT_COMPLETE ->
        "Live transcription is still connecting. Wait for setupComplete before sending audio."
      Kind.SETUP_TIMED_OUT -> "Gemini Live did not finish setting up the transcription session in time."
      Kind.SESSION_ENDED -> "This live transcription session has ended."
      Kind.FINALIZATION_TIMED_OUT ->
        "Gemini Live did not confirm the final transcript before the session closed. Finalized text " +
          "remains in the draft, but the last unconfirmed words may be missing."
      Kind.BACKPRESSURE -> "Live transcription could not keep up with the audio stream."
      Kind.RESPONSE_TOO_LARGE -> "The live transcription response exceeded Turing AI’s safety limit."
      Kind.INVALID_RESPONSE -> "Gemini Live returned a response Turing AI could not read."
      Kind.PROVIDER -> "Gemini Live reported an error."
      Kind.TRANSPORT -> "Turing AI could not reach Gemini Live."
    }
  }
}

/** One connected Gemini Live session. Audio may be sent only after [LiveTranscriptionEvent.SetupComplete]. */
interface LiveTranscriptionSession {
  /**
   * Bounded event stream. It closes normally after [LiveTranscriptionEvent.Ended] or a GoAway close,
   * and with the session's (sanitized) failure otherwise.
   */
  val events: ReceiveChannel<LiveTranscriptionEvent>

  /** Queues one chunk; fails with BACKPRESSURE when the outbound queue exceeds its bound. */
  fun send(chunk: LivePcm16Chunk)

  /**
   * Signals the end of audio and drains provider events up to a bounded deadline. The result
   * distinguishes confirmed completion and silence from an unresolved interim hypothesis.
   */
  suspend fun endAudio(): LiveFinalizationResult

  /** Ends the session immediately. Idempotent. */
  fun cancel()
}

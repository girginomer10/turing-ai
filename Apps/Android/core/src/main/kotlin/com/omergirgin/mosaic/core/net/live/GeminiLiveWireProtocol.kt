package com.omergirgin.mosaic.core.net.live

import com.omergirgin.mosaic.core.net.ProviderErrorSanitizer
import com.omergirgin.mosaic.core.net.decodeUtf8Strict
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.Request

/** A raw WebSocket message from Gemini Live (it sends JSON in binary frames as well as text). */
internal sealed interface LiveWebSocketMessage {
  class Text(val text: String) : LiveWebSocketMessage
  class Binary(val bytes: ByteArray) : LiveWebSocketMessage
}

/** Gemini Live's dedicated speech-to-text WebSocket wire format (iOS `GeminiLiveTranscriptionWireProtocol`). */
internal object GeminiLiveWireProtocol {
  const val MODEL_IDENTIFIER = "gemini-3.5-transcribe-live"
  const val QUALIFIED_MODEL_IDENTIFIER = "models/$MODEL_IDENTIFIER"
  const val WEB_SOCKET_HOST = "generativelanguage.googleapis.com"
  const val WEB_SOCKET_PATH = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
  const val ENDPOINT = "wss://$WEB_SOCKET_HOST$WEB_SOCKET_PATH"

  const val MAXIMUM_SESSION_MILLIS = 600_000L
  /** The local wrap-up event fires this long before the hard limit (585 s into 600 s). */
  const val WRAP_UP_LEAD_MILLIS = 15_000L
  const val MAXIMUM_INBOUND_MESSAGE_BYTES = 1 * 1_024 * 1_024
  const val MAXIMUM_TRANSCRIPT_EVENT_BYTES = 256 * 1_024
  const val MAXIMUM_TOTAL_TRANSCRIPT_BYTES = 4 * 1_024 * 1_024
  const val STREAM_BUFFER_LIMIT = 256

  private const val MAXIMUM_API_KEY_BYTES = 4 * 1_024
  private const val PCM_MIME_TYPE = "audio/pcm;rate=16000"
  private val json = Json

  /** Trimmed key, validated for size and for being a legal header value. */
  fun normalizedApiKey(rawApiKey: String?): String {
    val apiKey = rawApiKey?.trim().orEmpty()
    if (apiKey.isEmpty()) throw LiveTranscriptionException.of(LiveTranscriptionException.Kind.MISSING_API_KEY)
    if (apiKey.encodeToByteArray().size > MAXIMUM_API_KEY_BYTES) {
      throw LiveTranscriptionException.invalidConfiguration("The Google API key exceeds Turing AI’s safety limit.")
    }
    // OkHttp quotes an invalid header value in its exception; reject before it can see the key.
    if (apiKey.any { it !in ' '..'~' }) {
      throw LiveTranscriptionException(
        LiveTranscriptionException.Kind.MISSING_API_KEY,
        "The saved Google API key contains characters that cannot be sent. Paste the key again.",
      )
    }
    return apiKey
  }

  /**
   * The fixed Gemini Live endpoint. The key travels in the `x-goog-api-key` header (as for every
   * other Google request in the app) instead of iOS's `?key=` query, so it is never part of a URL.
   */
  fun webSocketRequest(apiKey: String, endpoint: String = ENDPOINT): Request =
    Request.Builder()
      .url(endpoint)
      .header("x-goog-api-key", normalizedApiKey(apiKey))
      .build()

  fun setupMessage(configuration: LiveTranscriptionConfiguration): String =
    buildJsonObject {
      putJsonObject("setup") {
        put("model", QUALIFIED_MODEL_IDENTIFIER)
        putJsonObject("generationConfig") {
          putJsonArray("responseModalities") { add("TEXT") }
        }
        putJsonObject("inputAudioTranscription") {
          if (configuration.languageCodes.isNotEmpty()) {
            putJsonArray("languageCodes") { configuration.languageCodes.forEach { add(it) } }
          }
          put("mode", configuration.mode.wireValue)
          if (configuration.customVocabulary.isNotEmpty()) {
            putJsonArray("customVocabulary") { configuration.customVocabulary.forEach { add(it) } }
          }
        }
      }
    }.toString()

  fun audioMessage(chunk: LivePcm16Chunk): String =
    buildJsonObject {
      putJsonObject("realtimeInput") {
        putJsonObject("audio") {
          put("data", Base64.getEncoder().encodeToString(chunk.data))
          put("mimeType", PCM_MIME_TYPE)
        }
      }
    }.toString()

  fun audioStreamEndMessage(): String =
    buildJsonObject { putJsonObject("realtimeInput") { put("audioStreamEnd", true) } }.toString()

  /** Decodes one server message into zero or more events; provider errors are thrown sanitized. */
  fun decodeServerMessage(message: LiveWebSocketMessage, redacting: String?): List<LiveTranscriptionEvent> {
    val text = when (message) {
      is LiveWebSocketMessage.Text -> {
        // UTF-16 length is a lower bound of the UTF-8 size; check the exact size only when close.
        if (message.text.length > MAXIMUM_INBOUND_MESSAGE_BYTES ||
          message.text.encodeToByteArray().size > MAXIMUM_INBOUND_MESSAGE_BYTES
        ) {
          throw LiveTranscriptionException.of(LiveTranscriptionException.Kind.RESPONSE_TOO_LARGE)
        }
        message.text
      }
      is LiveWebSocketMessage.Binary -> {
        if (message.bytes.size > MAXIMUM_INBOUND_MESSAGE_BYTES) {
          throw LiveTranscriptionException.of(LiveTranscriptionException.Kind.RESPONSE_TOO_LARGE)
        }
        decodeUtf8Strict(message.bytes, 0, message.bytes.size) ?: throw invalidResponse()
      }
    }

    val envelope = runCatching { json.parseToJsonElement(text.removePrefix("﻿")) }.getOrNull() as? JsonObject
      ?: throw invalidResponse()

    envelope["error"]?.let { errorValue ->
      val providerError = errorValue as? JsonObject ?: throw invalidResponse()
      throw LiveTranscriptionException.provider(LiveTranscriptionRedactor.sanitize(providerErrorMessage(providerError), redacting))
    }

    val events = ArrayList<LiveTranscriptionEvent>(2)
    envelope["setupComplete"]?.let { value ->
      if (value !is JsonObject) throw invalidResponse()
      events += LiveTranscriptionEvent.SetupComplete
    }

    envelope["serverContent"]?.let { value ->
      val serverContent = value as? JsonObject ?: throw invalidResponse()
      serverContent["interimInputTranscription"]?.let { interim ->
        val (transcript, language) = transcript(interim)
        events += LiveTranscriptionEvent.InterimTranscript(transcript, language)
      }
      serverContent["inputTranscription"]?.let { final ->
        val (transcript, language) = transcript(final)
        events += LiveTranscriptionEvent.FinalTranscript(transcript, language)
      }
      serverContent["turnComplete"]?.let { turnComplete ->
        val flag = boolean(turnComplete) ?: throw invalidResponse()
        if (flag) events += LiveTranscriptionEvent.TurnComplete
      }
    }

    envelope["goAway"]?.let { value ->
      val goAway = value as? JsonObject ?: throw invalidResponse()
      events += LiveTranscriptionEvent.GoAway(timeLeftSeconds(goAway))
    }
    return events
  }

  private fun transcript(raw: JsonElement): Pair<String, String?> {
    val transcript = raw as? JsonObject ?: throw invalidResponse()
    val text = string(transcript["text"]) ?: throw invalidResponse()
    if (text.encodeToByteArray().size > MAXIMUM_TRANSCRIPT_EVENT_BYTES) {
      throw LiveTranscriptionException.of(LiveTranscriptionException.Kind.RESPONSE_TOO_LARGE)
    }
    val languageCode = transcript["languageCode"]?.let { rawLanguage ->
      val value = string(rawLanguage)
      if (value == null || value.encodeToByteArray().size > 63) throw invalidResponse()
      value
    }
    return text to languageCode
  }

  private fun timeLeftSeconds(goAway: JsonObject): Double? {
    val raw = goAway["timeLeft"] ?: return null
    string(raw)?.let { duration ->
      val seconds = duration.takeIf { it.endsWith("s") }?.dropLast(1)?.toDoubleOrNull()
      if (seconds == null || !seconds.isFinite() || seconds < 0) throw invalidResponse()
      return seconds
    }
    val duration = raw as? JsonObject ?: throw invalidResponse()
    if (duration["seconds"] == null && duration["nanos"] == null) throw invalidResponse()
    val seconds = number(duration["seconds"]) ?: 0.0
    val nanos = number(duration["nanos"]) ?: 0.0
    if (!seconds.isFinite() || !nanos.isFinite() || seconds < 0 || nanos < 0) throw invalidResponse()
    return seconds + nanos / 1_000_000_000
  }

  private fun string(value: JsonElement?): String? =
    (value as? JsonPrimitive)?.takeIf { it.isString }?.content

  private fun boolean(value: JsonElement): Boolean? {
    val primitive = value as? JsonPrimitive ?: return null
    if (primitive.isString || primitive is JsonNull) return null
    return when (primitive.content) {
      "true" -> true
      "false" -> false
      else -> null
    }
  }

  /** NSNumber or numeric string, as iOS accepts for protobuf Duration fields. */
  private fun number(value: JsonElement?): Double? {
    val primitive = value as? JsonPrimitive ?: return null
    if (primitive is JsonNull) return null
    return primitive.content.toDoubleOrNull()
  }

  private fun providerErrorMessage(error: JsonObject): String {
    string(error["message"])?.takeIf { it.isNotEmpty() }?.let { return it }
    string(error["status"])?.takeIf { it.isNotEmpty() }?.let { return it }
    (error["code"] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toDoubleOrNull()?.let {
      return "Gemini Live returned error ${it.toLong()}."
    }
    return LiveTranscriptionRedactor.FALLBACK_MESSAGE
  }

  private fun invalidResponse() = LiveTranscriptionException.of(LiveTranscriptionException.Kind.INVALID_RESPONSE)
}

/** Redacts the key (raw and percent-encoded) and key-bearing query values from any error text. */
internal object LiveTranscriptionRedactor {
  const val FALLBACK_MESSAGE = "Gemini Live returned an error response Turing AI could not read."
  private const val REDACTION = "••••"
  private val queryNames = listOf("key", "api_key", "apikey", "access_token")

  fun sanitize(raw: String, redacting: String?): String {
    var value = raw
    for (name in queryNames) value = redactQueryValue(name, value)
    // Applies the shared key-variant redaction, control-character removal and 2,000-char cap.
    if (ProviderErrorSanitizer.cleanedText(value).isEmpty()) return FALLBACK_MESSAGE
    return ProviderErrorSanitizer.sanitized(value, redacting)
  }

  private fun redactQueryValue(name: String, input: String): String {
    val output = StringBuilder(input)
    var searchStart = 0
    while (searchStart < output.length) {
      val nameStart = output.indexOf(name, searchStart, ignoreCase = true)
      if (nameStart < 0) break
      val nameEnd = nameStart + name.length
      val marker = if (nameStart > 0) output[nameStart - 1] else ' '
      if ((marker != '?' && marker != '&') || nameEnd >= output.length || output[nameEnd] != '=') {
        searchStart = nameEnd
        continue
      }
      val valueStart = nameEnd + 1
      var valueEnd = valueStart
      while (valueEnd < output.length) {
        val char = output[valueEnd]
        if (char == '&' || char == '#' || char == '"' || char == '\'' || char.isWhitespace()) break
        valueEnd++
      }
      output.replace(valueStart, valueEnd, REDACTION)
      searchStart = valueStart + REDACTION.length
    }
    return output.toString()
  }
}

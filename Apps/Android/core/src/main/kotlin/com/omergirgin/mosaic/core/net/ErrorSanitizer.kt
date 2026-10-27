package com.omergirgin.mosaic.core.net

import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import com.omergirgin.mosaic.core.chat.ProviderException
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.UnknownHostException
import java.net.UnknownServiceException
import java.nio.charset.CharacterCodingException
import javax.net.ssl.SSLException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/**
 * Turns provider error bodies and stream failures into short, user-presentable text: the API key
 * (and its percent-encoded forms) is redacted, control characters are removed, whitespace is
 * collapsed, HTML error pages are ignored, and the result is capped at 2,000 characters.
 */
object ProviderErrorSanitizer {
  const val MAXIMUM_LENGTH: Int = 2_000
  private const val FALLBACK_MESSAGE = "The provider returned an error response Turing AI could not read."
  private const val REDACTION = "••••"

  /** Extracts the provider's own message from a JSON/plain error body. Empty input stays empty. */
  fun bodyMessage(raw: String, secret: String?): String {
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) return ""
    val parsed = runCatching { ProviderJson.parse(trimmed) }.getOrNull()
    // Google wraps some streaming errors in a one-element array: `[{"error": {...}}]`.
    val json = parsed as? JsonObject ?: (parsed as? JsonArray)?.firstOrNull() as? JsonObject
    val candidate =
      when {
        json != null -> providerErrorMessage(json) ?: FALLBACK_MESSAGE
        looksLikeMarkup(trimmed) -> FALLBACK_MESSAGE
        else -> trimmed
      }
    return sanitized(candidate, secret)
  }

  /** Presentable description of any error thrown by a provider client or the transport. */
  fun describe(error: Throwable, secret: String?): String {
    val providerError = error as? ProviderException ?: ProviderFailures.from(error, secret)
    return sanitized(providerError.message.orEmpty(), secret)
  }

  internal fun sanitized(raw: String, secret: String?): String {
    var value = raw
    if (!secret.isNullOrEmpty()) {
      // Longest first so a whitespace-padded variant cannot leave its trimmed core behind.
      for (variant in secretVariants(secret).sortedByDescending { it.length }) {
        if (variant.isNotEmpty()) value = value.replace(variant, REDACTION)
      }
    }
    return cleanedText(value).ifEmpty { FALLBACK_MESSAGE }.prefixCodePoints(MAXIMUM_LENGTH)
  }

  /** Control/format characters become spaces, then whitespace runs collapse to one space. */
  internal fun cleanedText(raw: String): String {
    val withoutControls = StringBuilder(raw.length)
    raw.codePoints().forEach { codePoint ->
      val type = Character.getType(codePoint)
      // Foundation's `.controlCharacters` covers both Cc and Cf (bidi overrides, zero-width marks).
      if (type == Character.CONTROL.toInt() || type == Character.FORMAT.toInt()) {
        withoutControls.append(' ')
      } else {
        withoutControls.appendCodePoint(codePoint)
      }
    }
    return collapseWhitespace(withoutControls.toString())
  }

  private fun collapseWhitespace(value: String): String {
    val output = StringBuilder(value.length)
    var pendingSpace = false
    value.codePoints().forEach { codePoint ->
      if (Character.isWhitespace(codePoint) || Character.isSpaceChar(codePoint)) {
        pendingSpace = output.isNotEmpty()
      } else {
        if (pendingSpace) output.append(' ')
        pendingSpace = false
        output.appendCodePoint(codePoint)
      }
    }
    return output.toString()
  }

  private fun secretVariants(secret: String): Set<String> {
    val trimmed = secret.trim()
    val values = listOf(secret, trimmed)
    val variants = values.toMutableSet()
    for (value in values) {
      if (value.isEmpty()) continue
      for (lowercaseHex in listOf(false, true)) {
        variants += percentEncode(value, lowercaseHex, ::isUrlQueryAllowed)
        variants += percentEncode(value, lowercaseHex) { Character.isLetterOrDigit(it) }
      }
    }
    return variants
  }

  private fun isUrlQueryAllowed(codePoint: Int): Boolean =
    codePoint < 0x80 &&
      (Character.isLetterOrDigit(codePoint) || codePoint.toChar() in "!$&'()*+,-./:;=?@_~")

  private fun looksLikeMarkup(value: String): Boolean {
    val lowercased = value.lowercase()
    return lowercased.startsWith("<") ||
      "<!doctype" in lowercased ||
      "<html" in lowercased ||
      "<body" in lowercased
  }
}

/** Provider-reported error text inside a JSON body or SSE event, using the same keys as iOS. */
internal fun providerErrorMessage(json: JsonObject): String? {
  json["error"].objectOrNull()?.get("message").stringOrNull()?.let { return it }
  json["error"].stringOrNull()?.takeIf { it.isNotEmpty() }?.let { return it }
  if (json["type"].stringOrNull() == "error") {
    return json["message"].stringOrNull() ?: "The provider reported an error."
  }
  json["detail"].stringOrNull()?.takeIf { it.isNotEmpty() }?.let { return it }
  json["detail"].objectListOrNull()?.firstNotNullOfOrNull { it["msg"].stringOrNull() }?.let { return it }
  return null
}

/** Factory for [ProviderException]s with the iOS default wording, and the throwable mapper. */
internal object ProviderFailures {
  fun of(kind: ProviderErrorKind, message: String? = null, httpStatus: Int? = null): ProviderException =
    ProviderException(kind, message ?: defaultMessage(kind), httpStatus)

  fun provider(message: String): ProviderException = ProviderException(ProviderErrorKind.PROVIDER, message)

  fun defaultMessage(kind: ProviderErrorKind): String =
    when (kind) {
      ProviderErrorKind.INVALID_ENDPOINT -> "The provider endpoint is not a valid URL."
      ProviderErrorKind.INSECURE_ENDPOINT ->
        "Remote provider endpoints must use HTTPS. HTTP is allowed only on a trusted local network."
      ProviderErrorKind.MISSING_API_KEY -> "Add an API key for this provider before sending a message."
      ProviderErrorKind.MISSING_MODEL -> "Choose or enter a model ID before sending a message."
      ProviderErrorKind.INVALID_RESPONSE -> "The provider returned a response Turing AI could not read."
      ProviderErrorKind.RESPONSE_TOO_LARGE -> "The provider response exceeded Turing AI’s safety limit."
      ProviderErrorKind.UNSUPPORTED_OPERATION ->
        "This provider connection does not support embeddings in Turing AI."
      ProviderErrorKind.CHAT_UNAVAILABLE ->
        "This provider connection is for embeddings and cannot send chat messages."
      ProviderErrorKind.MODEL_CATALOG_UNAVAILABLE ->
        "This provider does not publish a compatible model catalog. Enter an exact model ID instead."
      ProviderErrorKind.AUTHENTICATION -> "The provider rejected the API key."
      ProviderErrorKind.RATE_LIMITED -> "The provider is rate limiting requests. Try again shortly."
      ProviderErrorKind.HTTP_STATUS -> "The provider returned an HTTP error."
      ProviderErrorKind.CONNECTIVITY -> "Turing AI could not reach the provider."
      ProviderErrorKind.PROVIDER -> "The provider reported an error."
    }

  /**
   * Maps anything thrown below the client boundary to a sanitized [ProviderException]. Provider-
   * supplied text is re-sanitized with the key; parser exceptions are never attached as causes
   * because their messages can quote raw response bytes.
   */
  fun from(error: Throwable, secret: String?): ProviderException =
    when (error) {
      is ProviderException ->
        when (error.kind) {
          ProviderErrorKind.PROVIDER,
          ProviderErrorKind.HTTP_STATUS,
          ProviderErrorKind.AUTHENTICATION,
          ProviderErrorKind.RATE_LIMITED -> {
            val message =
              ProviderErrorSanitizer.bodyMessage(error.message.orEmpty(), secret).ifEmpty {
                error.httpStatus?.let { "The provider returned HTTP $it." } ?: defaultMessage(error.kind)
              }
            ProviderException(error.kind, message, error.httpStatus)
          }
          else -> error
        }
      is CharacterCodingException -> of(ProviderErrorKind.INVALID_RESPONSE)
      // Android's network security policy rejects cleartext before a socket opens.
      is UnknownServiceException ->
        if (error.message.orEmpty().contains("CLEARTEXT", ignoreCase = true)) {
          ProviderException(
            ProviderErrorKind.INSECURE_ENDPOINT,
            "This device's network security policy blocked HTTP to this host. Use HTTPS or a trusted local-network address.",
            cause = error,
          )
        } else {
          ProviderException(
            ProviderErrorKind.CONNECTIVITY,
            "A secure connection to the provider could not be established.",
            cause = error,
          )
        }
      is InterruptedIOException ->
        ProviderException(
          ProviderErrorKind.CONNECTIVITY,
          "The provider did not respond before the network timeout.",
          cause = error,
        )
      is UnknownHostException ->
        ProviderException(
          ProviderErrorKind.CONNECTIVITY,
          "The provider host could not be found. Check the endpoint and your network connection.",
          cause = error,
        )
      is ConnectException, is NoRouteToHostException ->
        ProviderException(
          ProviderErrorKind.CONNECTIVITY,
          "Turing AI could not connect to the provider. Check the endpoint and that the server is running.",
          cause = error,
        )
      is SSLException ->
        ProviderException(
          ProviderErrorKind.CONNECTIVITY,
          "A secure connection to the provider could not be established.",
          cause = error,
        )
      is IOException ->
        ProviderException(
          ProviderErrorKind.CONNECTIVITY,
          "The connection to the provider was interrupted.",
          cause = error,
        )
      else -> of(ProviderErrorKind.INVALID_RESPONSE)
    }
}

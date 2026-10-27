package com.omergirgin.mosaic.ui.providers

import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import com.omergirgin.mosaic.core.chat.ProviderException
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.profile
import java.net.URI
import com.omergirgin.mosaic.core.net.EndpointPolicy as CoreEndpointPolicy

internal const val INVALID_ENDPOINT_MESSAGE =
  "Enter a complete address beginning with https://, or use http:// only for a local network address. " +
    "Addresses can't contain credentials, a query or a fragment."

internal const val INSECURE_ENDPOINT_MESSAGE =
  "For your security, a remote service must use https://. Plain http:// is allowed only for localhost " +
    "or a private local network address."

/**
 * Endpoint field rules for the editor. Validation itself is the network layer's
 * [CoreEndpointPolicy] (HTTPS except trusted local network; no credentials, query or fragment), so
 * inline feedback matches exactly what the repository enforces on save.
 */
internal object EndpointForm {
  /** Returns a user-facing problem with [text] for [kind], or null when it can be saved. */
  fun issue(kind: ProviderKind, text: String): String? {
    val value = text.trim()
    if (value.isEmpty()) {
      return if (kind.profile.baseUrl == null) "Enter the service address for this connection." else null
    }
    return try {
      CoreEndpointPolicy.validate(value)
      null
    } catch (e: ProviderException) {
      if (e.kind == ProviderErrorKind.INSECURE_ENDPOINT) INSECURE_ENDPOINT_MESSAGE else INVALID_ENDPOINT_MESSAGE
    } catch (_: RuntimeException) {
      INVALID_ENDPOINT_MESSAGE
    }
  }

  /**
   * The value stored in the draft: null means "preset default", so an address identical to the
   * preset keeps following preset updates instead of freezing an explicit copy.
   */
  fun draftValue(kind: ProviderKind, text: String): String? {
    val value = text.trim()
    if (value.isEmpty()) return null
    val default = kind.profile.baseUrl
    if (default != null && normalized(default) == normalized(value)) return null
    return value
  }

  /** Base URL that requests would actually use for this draft. */
  fun effective(kind: ProviderKind, text: String): String? = draftValue(kind, text) ?: kind.profile.baseUrl

  fun host(url: String?): String? = url?.let { runCatching { URI(it.trim()).host }.getOrNull() }

  /** Loopback names the device itself, which on a phone is rarely where the server runs. */
  fun isLoopback(host: String?): Boolean {
    val value = host?.lowercase()?.trim('[', ']') ?: return false
    return value == "localhost" || value == "::1" || value.startsWith("127.")
  }

  private fun normalized(value: String) = value.trim().trimEnd('/').lowercase()
}

/** Port of iOS ProviderRequestLimitPolicy: bounds and the derived input budget. */
internal object RequestLimitPolicy {
  val contextWindowRange = 2_048..2_000_000
  val maximumOutputRange = 128..1_000_000

  fun safetyMarginTokens(contextWindowTokens: Int): Int = maxOf(512, minOf(2_048, contextWindowTokens / 8))

  fun validationIssue(contextWindowTokens: Int?, maximumOutputTokens: Int?): String? {
    if (contextWindowTokens == null || contextWindowTokens !in contextWindowRange) {
      return "Enter a context window between 2048 and 2000000 tokens."
    }
    if (maximumOutputTokens == null || maximumOutputTokens !in maximumOutputRange) {
      return "Enter a maximum output between 128 and 1000000 tokens."
    }
    if (maximumOutputTokens >= contextWindowTokens - safetyMarginTokens(contextWindowTokens)) {
      return "Maximum output plus the safety margin must be smaller than the context window."
    }
    return null
  }

  /** Tokens left for history, instructions and memory after output and the safety margin. */
  fun estimatedInputBudget(contextWindowTokens: Int?, maximumOutputTokens: Int?): Int? {
    if (validationIssue(contextWindowTokens, maximumOutputTokens) != null) return null
    return contextWindowTokens!! - maximumOutputTokens!! - safetyMarginTokens(contextWindowTokens)
  }
}

/** Only custom connections carry a user-chosen name in simple view (iOS display-name policy). */
internal object DisplayNamePolicy {
  fun usesCustomName(kind: ProviderKind, advanced: Boolean): Boolean = kind == ProviderKind.CUSTOM || advanced

  fun resolved(kind: ProviderKind, entered: String): String =
    entered.trim().ifEmpty { kind.profile.displayName }
}

/** Exact model IDs are free-form but bounded, single-line and non-empty (iOS parity). */
internal fun modelIdIssue(value: String): String? {
  val trimmed = value.trim()
  return when {
    trimmed.isEmpty() -> "Enter a model ID."
    trimmed.any { it == '\n' || it == '\r' } -> "A model ID must be on one line."
    trimmed.toByteArray(Charsets.UTF_8).size > 2_048 -> "This model ID is too long."
    else -> null
  }
}

internal enum class ErrorContext { GENERAL, DISCOVERY, TEST }

/**
 * Human-readable explanation for provider and validation failures, distinguishing configuration,
 * authentication, rate limits, connectivity and provider errors (DESIGN.md AI transparency).
 * [redacting] removes a just-typed key from any echoed message.
 */
internal fun providerErrorMessage(
  error: Throwable,
  context: ErrorContext = ErrorContext.GENERAL,
  redacting: String = "",
): String {
  val message = when (error) {
    is ProviderException -> providerExceptionMessage(error, context)
    else -> limited(error.message.orEmpty()).ifEmpty { "Something went wrong. Please try again." }
  }
  return if (redacting.isBlank()) message else message.replace(redacting, "••••")
}

private fun providerExceptionMessage(error: ProviderException, context: ErrorContext): String {
  val detail = limited(error.message.orEmpty())
  return when (error.kind) {
    ProviderErrorKind.INVALID_ENDPOINT -> INVALID_ENDPOINT_MESSAGE
    ProviderErrorKind.INSECURE_ENDPOINT -> INSECURE_ENDPOINT_MESSAGE
    ProviderErrorKind.MISSING_API_KEY ->
      "Enter an API key for this service. It's stored only on this device, protected by Android Keystore."
    ProviderErrorKind.MISSING_MODEL -> "Enter or choose a model ID."
    ProviderErrorKind.INVALID_RESPONSE ->
      if (context == ErrorContext.DISCOVERY) {
        "The service responded, but Turing AI could not read its model list. You can still enter an exact model ID."
      } else {
        "The service sent a response Turing AI could not read."
      }
    ProviderErrorKind.RESPONSE_TOO_LARGE -> "The service's response was too large to read safely."
    ProviderErrorKind.UNSUPPORTED_OPERATION -> detail.ifEmpty { "This service doesn't support this action." }
    ProviderErrorKind.CHAT_UNAVAILABLE ->
      "This connection provides embeddings only and cannot send chat messages."
    ProviderErrorKind.MODEL_CATALOG_UNAVAILABLE ->
      "Catalog unavailable: this service does not publish a compatible model list here. Enter an exact model ID instead."
    ProviderErrorKind.AUTHENTICATION ->
      if (error.httpStatus == 403) {
        if (context == ErrorContext.DISCOVERY) {
          "The API key does not have permission to list models (HTTP 403)."
        } else {
          "The service refused this API key (HTTP 403). Check the key's permissions and model access."
        }
      } else {
        "The service rejected the API key (HTTP ${error.httpStatus ?: 401}). Check the key and try again."
      }
    ProviderErrorKind.RATE_LIMITED -> "The service is rate limiting requests (HTTP 429). Wait a moment and try again."
    ProviderErrorKind.HTTP_STATUS -> httpMessage(error.httpStatus, detail, context)
    // The network layer already explains timeouts, DNS and TLS failures in plain words.
    ProviderErrorKind.CONNECTIVITY -> detail.ifEmpty {
      "Turing AI could not reach the service. Check the address and your network connection; a server " +
        "on your computer must accept connections from this device."
    }
    ProviderErrorKind.PROVIDER -> detail.ifEmpty { "The service reported an error." }
  }
}

private fun httpMessage(status: Int?, detail: String, context: ErrorContext): String = when (status) {
  401 -> "The service rejected the API key (HTTP 401). Check the key and try again."
  402 -> "The service requires billing or available credit before it can complete this request (HTTP 402)."
  403 -> "The API key does not have permission for this request (HTTP 403)."
  404 ->
    if (context == ErrorContext.DISCOVERY) {
      "The service does not expose a model catalog at this address (HTTP 404). Enter the model ID manually, or check the address."
    } else {
      "The service returned HTTP 404. Check the address and the exact model ID."
    }
  429 -> "The service is rate limiting requests (HTTP 429). Wait a moment and try again."
  in 500..599 -> "The service is temporarily unavailable (HTTP $status). Try again later."
  null -> detail.ifEmpty { "The service returned an error." }
  else -> detail.ifEmpty { "The service returned HTTP $status." }
}

private fun limited(value: String): String = value.replace('\n', ' ').replace('\r', ' ').trim().take(400)

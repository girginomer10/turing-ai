package com.omergirgin.mosaic.core.net

import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import com.omergirgin.mosaic.core.chat.ProviderException
import com.omergirgin.mosaic.core.provider.ProviderAuthenticationStyle
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.profile
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.ResponseBody
import okio.Buffer

/**
 * Timeouts per request family, in seconds. OkHttp's read timeout is an idle deadline between
 * bytes (like URLSession's request timeout) and the call timeout is the finite resource ceiling.
 * Research and reasoning models can stay silent for minutes before the first token, hence the
 * 15-minute streaming idle window.
 */
internal enum class ProviderTimeoutPolicy(
  val connectSeconds: Long,
  val idleSeconds: Long,
  val callSeconds: Long,
) {
  STREAMING(connectSeconds = 60, idleSeconds = 15 * 60, callSeconds = 24 * 60 * 60),
  MODEL_CATALOG(connectSeconds = 30, idleSeconds = 30, callSeconds = 5 * 60),
  EMBEDDINGS(connectSeconds = 60, idleSeconds = 120, callSeconds = 5 * 60),
}

/**
 * Shared transport for chat, catalog and (later) embedding requests. All clients derive from one
 * base [OkHttpClient], so they share its connection pool and dispatcher.
 *
 * Redirects are never followed: OkHttp would replay custom auth headers (`x-api-key`, `api-key`,
 * `x-goog-api-key`) to the new location, so a 3xx surfaces as an HTTP error instead (iOS parity).
 * No cookie jar or cache is installed, matching the ephemeral URLSession on iOS.
 */
internal object ProviderHttp {
  const val ERROR_BODY_LIMIT: Int = 16 * 1_024

  private val jsonMediaType = "application/json".toMediaType()

  private val base: OkHttpClient by lazy {
    OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).build()
  }

  private val clients = ConcurrentHashMap<ProviderTimeoutPolicy, OkHttpClient>()

  fun client(policy: ProviderTimeoutPolicy): OkHttpClient =
    clients.computeIfAbsent(policy) {
      base
        .newBuilder()
        .connectTimeout(policy.connectSeconds, TimeUnit.SECONDS)
        .readTimeout(policy.idleSeconds, TimeUnit.SECONDS)
        .writeTimeout(policy.idleSeconds, TimeUnit.SECONDS)
        .callTimeout(policy.callSeconds, TimeUnit.SECONDS)
        .build()
    }

  /** JSON body without OkHttp's implicit `; charset=utf-8` suffix (some hosts compare exactly). */
  fun jsonBody(json: String): RequestBody = json.encodeToByteArray().toRequestBody(jsonMediaType)

  /** Performs a request and returns its bounded success body; non-2xx becomes a sanitized error. */
  suspend fun fetch(
    request: Request,
    policy: ProviderTimeoutPolicy,
    limit: Int,
    secret: String?,
  ): ByteArray =
    client(policy).executeCancellable(request) { response ->
      response.requireSuccess(secret)
      response.body.readBounded(limit, truncate = false)
    }
}

/**
 * Runs a blocking OkHttp call on [Dispatchers.IO] and cancels the socket as soon as the calling
 * coroutine is cancelled. Blocking reads ignore coroutine cancellation, so a sibling coroutine
 * waits for cancellation and calls [okhttp3.Call.cancel], which makes the pending read throw.
 */
internal suspend fun <T> OkHttpClient.executeCancellable(
  request: Request,
  block: suspend (Response) -> T,
): T = coroutineScope {
  val call = newCall(request)
  val finished = AtomicBoolean(false)
  val canceller =
    launch(start = CoroutineStart.UNDISPATCHED) {
      try {
        awaitCancellation()
      } finally {
        if (!finished.get()) call.cancel()
      }
    }
  try {
    withContext(Dispatchers.IO) { call.execute().use { response -> block(response) } }.also { finished.set(true) }
  } finally {
    canceller.cancel()
  }
}

/** Throws the mapped HTTP failure for any non-2xx status, reading at most 16 KiB of the body. */
internal fun Response.requireSuccess(secret: String?) {
  if (code in 200..299) return
  val raw = body.readBounded(ProviderHttp.ERROR_BODY_LIMIT, truncate = true).decodeToString()
  throw httpFailure(code, raw, secret)
}

internal fun httpFailure(status: Int, rawBody: String, secret: String?): ProviderException {
  val kind =
    when (status) {
      401, 403 -> ProviderErrorKind.AUTHENTICATION
      429 -> ProviderErrorKind.RATE_LIMITED
      else -> ProviderErrorKind.HTTP_STATUS
    }
  val message =
    if (status in 300..399) {
      "The provider redirected the request (HTTP $status). Turing AI does not follow redirects so " +
        "the API key stays on the configured endpoint; update the base URL instead."
    } else {
      ProviderErrorSanitizer.bodyMessage(rawBody, secret).ifEmpty { "The provider returned HTTP $status." }
    }
  return ProviderException(kind, message, httpStatus = status)
}

/**
 * Reads at most [limit] bytes. With [truncate] the remainder is discarded (error bodies);
 * otherwise a longer body fails with RESPONSE_TOO_LARGE before it can be buffered.
 */
internal fun ResponseBody.readBounded(limit: Int, truncate: Boolean): ByteArray {
  val source = source()
  val buffer = Buffer()
  while (buffer.size < limit) {
    val read = source.read(buffer, minOf(64L * 1_024, limit - buffer.size))
    if (read == -1L) return buffer.readByteArray()
  }
  if (truncate || source.exhausted()) return buffer.readByteArray()
  throw ProviderFailures.of(ProviderErrorKind.RESPONSE_TOO_LARGE)
}

internal object ProviderCredentials {
  /** iOS parity: presets that require a key fail before any request is built. */
  fun requireKeyIfNeeded(connection: ProviderConnection) {
    if (connection.provider.profile.requiresApiKey && connection.apiKey.isNullOrBlank()) {
      throw ProviderFailures.of(ProviderErrorKind.MISSING_API_KEY)
    }
  }

  /**
   * Trimmed key safe for an HTTP header. OkHttp quotes the offending value in its exception for
   * non-standard header names, so invalid characters are rejected here, before it can see them.
   */
  fun headerValue(connection: ProviderConnection): String? {
    val key = connection.apiKey?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    if (key.any { it !in ' '..'~' }) {
      throw ProviderException(
        ProviderErrorKind.MISSING_API_KEY,
        "The saved API key contains characters that cannot be sent to the provider. Paste the key again.",
      )
    }
    return key
  }
}

/** Header placement per [ProviderAuthenticationStyle]; keys never go into URLs. */
internal fun Request.Builder.providerAuthentication(connection: ProviderConnection): Request.Builder {
  val key = ProviderCredentials.headerValue(connection) ?: return this
  when (connection.provider.profile.authenticationStyle) {
    ProviderAuthenticationStyle.API_KEY_HEADER -> header("api-key", key)
    ProviderAuthenticationStyle.ANTHROPIC -> {
      header("x-api-key", key)
      header("anthropic-version", "2023-06-01")
    }
    ProviderAuthenticationStyle.GOOGLE -> header("x-goog-api-key", key)
    ProviderAuthenticationStyle.BEARER -> {
      header("Authorization", "Bearer $key")
      // OpenRouter attributes traffic to the app through this header.
      if (connection.provider == ProviderKind.OPENROUTER) header("X-Title", "Turing AI")
    }
  }
  return this
}

package com.omergirgin.mosaic.core.chat

import com.omergirgin.mosaic.core.net.HttpProviderClient
import kotlinx.coroutines.flow.Flow

interface ProviderClient {
  /** Live catalog, filtered to chat-capable models. Throws [ProviderException] (MODEL_CATALOG_UNAVAILABLE etc.). */
  suspend fun listModels(): List<DiscoveredModel>

  /**
   * Cold stream of events. Emits [StreamEvent.Completed] exactly once on terminal success; any
   * provider stop that is not a clean completion (length, safety, refusal...) is thrown as a
   * [ProviderException]. Cancelling the collector cancels the HTTP call.
   */
  fun stream(request: ChatRequest): Flow<StreamEvent>
}

enum class ProviderErrorKind {
  INVALID_ENDPOINT,
  INSECURE_ENDPOINT,
  MISSING_API_KEY,
  MISSING_MODEL,
  INVALID_RESPONSE,
  RESPONSE_TOO_LARGE,
  UNSUPPORTED_OPERATION,
  CHAT_UNAVAILABLE,
  MODEL_CATALOG_UNAVAILABLE,
  /** 401/403 */
  AUTHENTICATION,
  /** 429 */
  RATE_LIMITED,
  /** Other HTTP status. */
  HTTP_STATUS,
  /** I/O, DNS, TLS, timeout. */
  CONNECTIVITY,
  /** Provider reported an error or an incomplete/blocked stop. */
  PROVIDER,
}

/** Message is already sanitized: secrets redacted, control characters stripped, <= 2,000 chars. */
class ProviderException(
  val kind: ProviderErrorKind,
  message: String,
  val httpStatus: Int? = null,
  cause: Throwable? = null,
) : Exception(message, cause)

/**
 * Creates the client for one immutable connection snapshot. Clients are cheap and stateless; all
 * of them share one pooled OkHttp transport.
 */
object ProviderClientFactory {
  fun make(connection: ProviderConnection): ProviderClient = HttpProviderClient(connection)
}

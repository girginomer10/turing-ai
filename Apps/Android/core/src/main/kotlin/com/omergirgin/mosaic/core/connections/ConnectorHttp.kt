package com.omergirgin.mosaic.core.connections

import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import com.omergirgin.mosaic.core.chat.ProviderException
import com.omergirgin.mosaic.core.net.BoundedSseDecoder
import com.omergirgin.mosaic.core.net.SseEvent
import com.omergirgin.mosaic.core.net.executeCancellable
import java.io.IOException
import java.net.URI
import java.util.concurrent.TimeUnit
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.serialization.json.JsonElement
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.Buffer

/** App-built request. [toString] never prints headers or the body (they may carry credentials). */
class ConnectorRequest(
  val url: String,
  val method: String = "GET",
  val headers: List<Pair<String, String>> = emptyList(),
  val body: ByteArray? = null,
  val contentType: String? = null,
) {
  fun withHeader(name: String, value: String) = ConnectorRequest(url, method, headers + (name to value), body, contentType)

  override fun toString(): String = "ConnectorRequest($method ${url.substringBefore('?')})"

  companion object {
    fun form(url: String, values: Map<String, String>) =
      ConnectorRequest(url, "POST", body = ConnectorText.form(values), contentType = "application/x-www-form-urlencoded")

    fun json(url: String, value: JsonElement, headers: List<Pair<String, String>> = emptyList()) =
      ConnectorRequest(url, "POST", headers, value.encoded.encodeToByteArray(), "application/json")
  }
}

class ConnectorResponse(val status: Int, val headers: Map<String, String>, val body: ByteArray) {
  fun requireSuccess(): ByteArray {
    if (status !in 200..299) throw ConnectorException(ConnectorException.Kind.HTTP, status)
    return body
  }
}

/** Each call supplies its own origin allowlist; tests and previews can substitute a transport. */
interface ConnectorTransport {
  suspend fun send(
    request: ConnectorRequest,
    allowedHosts: Set<String>,
    maximumBytes: Int = 2_000_000,
    rpcId: String? = null,
  ): ConnectorResponse
}

/**
 * Fixed-origin connector transport (iOS `ConnectorHTTP`): HTTPS on port 443 to an allowlisted host
 * only, no cookies, no cache, never following redirects (credentials can't move to another
 * origin), bounded bodies. MCP event streams are framed byte by byte — empty lines are event
 * delimiters, so a line-reader that drops them must never be used — and reading stops at the
 * event that carries this request's JSON-RPC reply.
 */
class ConnectorHttp(private val client: OkHttpClient = sharedClient) : ConnectorTransport {
  override suspend fun send(
    request: ConnectorRequest,
    allowedHosts: Set<String>,
    maximumBytes: Int,
    rpcId: String?,
  ): ConnectorResponse {
    if (!isAllowed(request.url, allowedHosts)) throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    val url = request.url.toHttpUrlOrNull() ?: throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    val builder = Request.Builder().url(url)
    for ((name, value) in request.headers) {
      // Header values come from the app and validated tokens; never echo a rejected value.
      if (value.any { it !in ' '..'~' }) throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
      builder.header(name, value)
    }
    val body = request.body?.toRequestBody(request.contentType?.toMediaTypeOrNull())
    builder.method(request.method, body ?: if (request.method == "POST") ByteArray(0).toRequestBody(null) else null)
    return try {
      client.executeCancellable(builder.build()) { response -> read(response, maximumBytes, rpcId) }
    } catch (error: CancellationException) {
      throw error
    } catch (error: ConnectorException) {
      throw error
    } catch (error: ProviderException) {
      // The shared SSE decoder reports oversized or malformed framing as provider errors.
      throw ConnectorException(
        if (error.kind == ProviderErrorKind.RESPONSE_TOO_LARGE) ConnectorException.Kind.TOO_LARGE
        else ConnectorException.Kind.INVALID_RESPONSE
      )
    } catch (_: IOException) {
      throw ConnectorException(ConnectorException.Kind.NETWORK)
    } catch (_: IllegalArgumentException) {
      throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    }
  }

  private fun read(response: Response, maximumBytes: Int, rpcId: String?): ConnectorResponse {
    val headers = response.headers.names().associate { name -> name.lowercase() to (response.header(name) ?: "") }
    val body = response.body
    if (body.contentLength() > maximumBytes) throw ConnectorException(ConnectorException.Kind.TOO_LARGE)
    val type = headers["content-type"].orEmpty().lowercase()
    if (rpcId != null && response.code == 200 && "text/event-stream" in type) {
      val decoder = RpcEventDecoder(rpcId, maximumBytes)
      val source = body.source()
      val chunk = Buffer()
      while (source.read(chunk, 8_192) != -1L) {
        while (!chunk.exhausted()) {
          decoder.consume(chunk.readByte())?.let { return ConnectorResponse(response.code, headers, it) }
        }
      }
      decoder.finish()?.let { return ConnectorResponse(response.code, headers, it) }
      throw ConnectorException(ConnectorException.Kind.INVALID_RESPONSE)
    }
    val buffer = Buffer()
    val source = body.source()
    while (true) {
      val read = source.read(buffer, 64L * 1_024)
      if (read == -1L) break
      if (buffer.size > maximumBytes) throw ConnectorException(ConnectorException.Kind.TOO_LARGE)
    }
    return ConnectorResponse(response.code, headers, buffer.readByteArray())
  }

  companion object {
    private val sharedClient: OkHttpClient by lazy {
      OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .callTimeout(90, TimeUnit.SECONDS)
        .build()
    }

    /** HTTPS, an exact allowlisted host, default port, no user info and no fragment. */
    fun isAllowed(url: String?, hosts: Set<String>): Boolean {
      if (url == null) return false
      val uri = runCatching { URI(url) }.getOrNull() ?: return false
      if (uri.scheme != "https" || uri.rawUserInfo != null || uri.rawFragment != null) return false
      if (uri.port != -1 && uri.port != 443) return false
      val host = uri.host?.lowercase() ?: return false
      val parsed = url.toHttpUrlOrNull() ?: return false
      return host in hosts && parsed.host == host
    }
  }
}

/** Matches only this request's JSON-RPC reply inside an event stream (iOS `ConnectorRPCEventDecoder`). */
internal class RpcEventDecoder(private val id: String, private val maximumBytes: Int) {
  private var total = 0
  private val stream = BoundedSseDecoder()

  fun consume(byte: Byte): ByteArray? {
    if (++total > maximumBytes) throw ConnectorException(ConnectorException.Kind.TOO_LARGE)
    val event = stream.consume(byte) ?: return null
    return reply(event)
  }

  fun finish(): ByteArray? = stream.finish().firstNotNullOfOrNull(::reply)

  private fun reply(event: SseEvent): ByteArray? {
    val data = event.data.encodeToByteArray()
    val value = runCatching { ConnectorJson.parse(data) }.getOrNull() ?: return null
    return if (value["id"].stringValue == id) data else null
  }
}

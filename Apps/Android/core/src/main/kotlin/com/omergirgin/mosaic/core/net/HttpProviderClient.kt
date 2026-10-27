package com.omergirgin.mosaic.core.net

import com.omergirgin.mosaic.core.chat.ChatRequest
import com.omergirgin.mosaic.core.chat.DiscoveredModel
import com.omergirgin.mosaic.core.chat.ProviderClient
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.StreamEvent
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.channelFlow
import okhttp3.Response

/**
 * OkHttp-backed [ProviderClient] for every chat preset. Request building, wire dialect and stream
 * semantics follow the iOS `URLSessionProviderClient`; this class only sequences them and maps
 * every failure to a sanitized [com.omergirgin.mosaic.core.chat.ProviderException].
 */
internal class HttpProviderClient(private val connection: ProviderConnection) : ProviderClient {
  override suspend fun listModels(): List<DiscoveredModel> = withProviderErrors {
    val accumulator = ModelCatalogAccumulator()
    var cursor: String? = null
    do {
      currentCoroutineContext().ensureActive()
      val request = ModelCatalogRequests.build(connection, cursor)
      val body =
        ProviderHttp.fetch(
          request,
          ProviderTimeoutPolicy.MODEL_CATALOG,
          ModelCatalogLimits.RESPONSE_BYTE_LIMIT,
          connection.apiKey,
        )
      cursor = accumulator.consume(ModelCatalogParser.decodePage(body, connection.provider))
    } while (cursor != null)
    accumulator.result
  }

  /**
   * The consumer side is unbounded so a slow collector never stalls the socket; the pipeline's
   * 512 KiB text and 4,096 control-event budgets are what bound the buffered payload.
   */
  override fun stream(request: ChatRequest): Flow<StreamEvent> =
    channelFlow {
        withProviderErrors {
          val (httpRequest, wire) = ChatRequestFactory.build(connection, request)
          ProviderHttp.client(ProviderTimeoutPolicy.STREAMING).executeCancellable(httpRequest) { response ->
            response.requireSuccess(connection.apiKey)
            pump(response, StreamEventPipeline(connection.provider, wire)) { send(it) }
          }
        }
      }
      .buffer(Channel.UNLIMITED)

  /** Reads SSE bytes until a terminal event or EOF; returns as soon as Completed is delivered. */
  private suspend fun pump(
    response: Response,
    pipeline: StreamEventPipeline,
    send: suspend (StreamEvent) -> Unit,
  ) {
    val decoder = BoundedSseDecoder()
    val source = response.body.source()
    val chunk = ByteArray(8 * 1_024)
    while (true) {
      val read = source.read(chunk)
      if (read == -1) break
      for (index in 0 until read) {
        val event = decoder.consume(chunk[index]) ?: continue
        if (deliver(pipeline.consume(event), send)) return
      }
    }
    for (event in decoder.finish()) {
      if (deliver(pipeline.consume(event), send)) return
    }
    // A clean EOF without a terminal event completes the flow without Completed; consumers treat
    // that as an interrupted answer (iOS parity).
    deliver(pipeline.finish(), send)
  }

  private suspend fun deliver(events: List<StreamEvent>, send: suspend (StreamEvent) -> Unit): Boolean {
    for (event in events) {
      send(event)
      if (event is StreamEvent.Completed) return true
    }
    return false
  }

  /**
   * Cancellation passes through untouched. An I/O error raised because the call was cancelled
   * is converted back into cancellation instead of being reported as a connectivity failure.
   */
  private suspend inline fun <T> withProviderErrors(block: () -> T): T =
    try {
      block()
    } catch (error: CancellationException) {
      throw error
    } catch (error: Throwable) {
      currentCoroutineContext().ensureActive()
      throw ProviderFailures.from(error, connection.apiKey)
    }
}

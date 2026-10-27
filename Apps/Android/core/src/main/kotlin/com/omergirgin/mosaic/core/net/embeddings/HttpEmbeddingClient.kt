package com.omergirgin.mosaic.core.net.embeddings

import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import com.omergirgin.mosaic.core.net.ProviderFailures
import com.omergirgin.mosaic.core.net.ProviderHttp
import com.omergirgin.mosaic.core.net.ProviderTimeoutPolicy
import com.omergirgin.mosaic.core.net.utf8Size
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/**
 * OkHttp-backed [EmbeddingClient] sharing the chat transport (no redirects, no cookies or cache,
 * endpoint policy, header authentication, sanitized errors). Port of iOS
 * `URLSessionEmbeddingProviderClient`.
 */
internal class HttpEmbeddingClient(private val connection: ProviderConnection) : EmbeddingClient {
  /** Keeps every request for one model in one dimension for the whole job, not just one call. */
  private val dimensionsByModel = HashMap<String, Int>()

  override suspend fun embed(inputs: List<String>, modelId: String, purpose: EmbeddingPurpose): EmbeddingResult {
    try {
      if (inputs.isEmpty()) throw ProviderFailures.of(ProviderErrorKind.INVALID_RESPONSE)
      if (inputs.size > EmbeddingBatchPolicy.APPLICATION_MAXIMUM_INPUT_COUNT) {
        throw ProviderFailures.of(ProviderErrorKind.RESPONSE_TOO_LARGE)
      }
      var totalBytes = 0L
      for (input in inputs) {
        totalBytes += input.utf8Size()
        if (totalBytes > EmbeddingBatchPolicy.MAXIMUM_BATCH_UTF8_BYTES) {
          throw ProviderFailures.of(ProviderErrorKind.RESPONSE_TOO_LARGE)
        }
      }

      val vectors = ArrayList<FloatArray>(inputs.size)
      var dimension: Int? = null
      var reportedTokens: Int? = null
      for (batch in EmbeddingBatchPolicy.batches(inputs, connection.provider, modelId)) {
        currentCoroutineContext().ensureActive()
        val request = EmbeddingWire.request(connection, modelId, batch, purpose)
        val body = ProviderHttp.fetch(request, ProviderTimeoutPolicy.EMBEDDINGS, RESPONSE_LIMIT, connection.apiKey)
        val decoded = EmbeddingWire.decode(body, batch.size, connection.provider)
        // A provider must not change dimensions between split batches.
        val batchDimension = decoded.vectors.first().size
        if (dimension != null && dimension != batchDimension) throw ProviderFailures.of(ProviderErrorKind.INVALID_RESPONSE)
        dimension = batchDimension
        vectors += decoded.vectors
        decoded.inputTokens?.let { reportedTokens = (reportedTokens ?: 0) + it }
      }
      if (vectors.size != inputs.size || dimension == null) throw ProviderFailures.of(ProviderErrorKind.INVALID_RESPONSE)
      synchronized(dimensionsByModel) {
        val expected = dimensionsByModel[modelId]
        if (expected != null && expected != dimension) throw ProviderFailures.of(ProviderErrorKind.INVALID_RESPONSE)
        dimensionsByModel[modelId] = dimension
      }
      return EmbeddingResult(vectors, reportedTokens)
    } catch (error: CancellationException) {
      throw error
    } catch (error: Throwable) {
      currentCoroutineContext().ensureActive()
      throw ProviderFailures.from(error, connection.apiKey)
    }
  }

  private companion object {
    const val RESPONSE_LIMIT = 32 * 1_024 * 1_024
  }
}

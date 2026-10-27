package com.omergirgin.mosaic.core.net.embeddings

import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import com.omergirgin.mosaic.core.net.EndpointPolicy
import com.omergirgin.mosaic.core.net.GeminiWire
import com.omergirgin.mosaic.core.net.ProviderCredentials
import com.omergirgin.mosaic.core.net.ProviderFailures
import com.omergirgin.mosaic.core.net.ProviderHttp
import com.omergirgin.mosaic.core.net.ProviderJson
import com.omergirgin.mosaic.core.net.at
import com.omergirgin.mosaic.core.net.intOrNull
import com.omergirgin.mosaic.core.net.objectListOrNull
import com.omergirgin.mosaic.core.net.objectOrNull
import com.omergirgin.mosaic.core.net.providerAuthentication
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.supportsEmbeddings
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.HttpUrl
import okhttp3.Request

/** One decoded provider batch: vectors in input order plus reported input tokens. */
internal class DecodedEmbeddings(val vectors: List<FloatArray>, val inputTokens: Int?)

/**
 * Port of the embedding parts of iOS `ProviderWireProtocol`. Official Qwen endpoints use the native
 * DashScope text API and official Cohere endpoints `/v2/embed`; Gemini uses batch embeddings;
 * every other preset (hosted, local, custom) keeps the OpenAI-compatible `/embeddings` envelope,
 * with Voyage, Jina and NVIDIA purpose fields.
 */
internal object EmbeddingWire {
  fun request(
    connection: ProviderConnection,
    modelId: String,
    inputs: List<String>,
    purpose: EmbeddingPurpose,
  ): Request {
    val provider = connection.provider
    if (!provider.supportsEmbeddings) throw ProviderFailures.of(ProviderErrorKind.UNSUPPORTED_OPERATION)
    if (modelId.isBlank()) {
      throw ProviderFailures.of(ProviderErrorKind.MISSING_MODEL, "Choose or enter an embedding model ID.")
    }
    if (inputs.isEmpty() || inputs.any { it.isEmpty() }) throw ProviderFailures.of(ProviderErrorKind.INVALID_RESPONSE)
    val baseUrl = EndpointPolicy.validatedBaseUrl(connection.resolvedBaseUrl)
    ProviderCredentials.requireKeyIfNeeded(connection)

    val nativeQwen = provider == ProviderKind.QWEN && isOfficialQwenCompatibleEndpoint(baseUrl)
    val nativeCohere = provider == ProviderKind.COHERE &&
      EndpointPolicy.isExactOfficialEndpoint(baseUrl, "api.cohere.ai", "/compatibility/v1")
    val endpoint = when {
      provider == ProviderKind.GOOGLE -> {
        val model = EndpointPolicy.encodedPathSegment(GeminiWire.normalizedModelId(modelId))
        EndpointPolicy.appending("models/$model:batchEmbedContents", baseUrl)
      }
      nativeQwen -> EndpointPolicy.replacingPath(baseUrl, "/api/v1/services/embeddings/text-embedding/text-embedding")
      nativeCohere -> EndpointPolicy.replacingPath(baseUrl, "/v2/embed")
      else -> EndpointPolicy.appending("embeddings", baseUrl)
    }

    val body = when {
      provider == ProviderKind.GOOGLE -> geminiBody(modelId, inputs, purpose)
      nativeQwen -> qwenBody(modelId, inputs, purpose)
      nativeCohere -> buildJsonObject {
        put("model", modelId)
        putJsonArray("texts") { inputs.forEach { add(it) } }
        put("input_type", if (purpose == EmbeddingPurpose.QUERY) "search_query" else "search_document")
        putJsonArray("embedding_types") { add("float") }
        put("truncate", "NONE")
      }
      else -> compatibleBody(provider, modelId, inputs, purpose)
    }

    return Request.Builder()
      .url(endpoint)
      .post(ProviderHttp.jsonBody(body.toString()))
      .header("Accept", "application/json")
      .providerAuthentication(connection)
      .build()
  }

  fun decode(bytes: ByteArray, expectedCount: Int, provider: ProviderKind): DecodedEmbeddings {
    if (expectedCount <= 0) throw invalid()
    val root = runCatching { ProviderJson.parse(bytes) }.getOrNull().objectOrNull() ?: throw invalid()
    val usage = reportedInputTokens(root)

    if (provider == ProviderKind.GOOGLE) {
      val records = root["embeddings"].objectListOrNull()
      if (records == null || records.size != expectedCount) throw invalid()
      val vectors = records.map { vector(it["values"]) }
      return DecodedEmbeddings(sameDimensions(vectors), usage)
    }

    val output = root["output"].objectOrNull()
    if (provider == ProviderKind.QWEN && output != null) {
      val records = output["embeddings"].objectListOrNull()
      if (records == null || records.size != expectedCount) throw invalid()
      return DecodedEmbeddings(indexed(records, "text_index", expectedCount), usage)
    }

    val cohere = root["embeddings"].objectOrNull()
    if (provider == ProviderKind.COHERE && cohere != null) {
      val raw = cohere["float"] as? JsonArray
      if (raw == null || raw.size != expectedCount) throw invalid()
      return DecodedEmbeddings(sameDimensions(raw.map(::vector)), usage)
    }

    val records = root["data"].objectListOrNull()
    if (records == null || records.size != expectedCount) throw invalid()
    return DecodedEmbeddings(indexed(records, "index", expectedCount), usage)
  }

  private fun geminiBody(modelId: String, inputs: List<String>, purpose: EmbeddingPurpose): JsonObject {
    val model = GeminiWire.normalizedModelId(modelId)
    return buildJsonObject {
      putJsonArray("requests") {
        for (input in inputs) {
          addJsonObject {
            put("model", "models/$model")
            putJsonObject("content") {
              putJsonArray("parts") { addJsonObject { put("text", input) } }
            }
            // gemini-embedding-2 takes its intent from the input prefix instead.
            if (model.lowercase() != "gemini-embedding-2") {
              putJsonObject("embedContentConfig") {
                put("taskType", if (purpose == EmbeddingPurpose.QUERY) "RETRIEVAL_QUERY" else "RETRIEVAL_DOCUMENT")
              }
            }
          }
        }
      }
    }
  }

  private fun qwenBody(modelId: String, inputs: List<String>, purpose: EmbeddingPurpose): JsonObject {
    val model = modelId.trim().lowercase()
    return buildJsonObject {
      put("model", modelId)
      putJsonObject("input") { putJsonArray("texts") { inputs.forEach { add(it) } } }
      putJsonObject("parameters") {
        put("text_type", if (purpose == EmbeddingPurpose.QUERY) "query" else "document")
        if (model in setOf("qwen3.7-text-embedding", "text-embedding-v3", "text-embedding-v4")) {
          put("output_type", "dense")
        }
        if (purpose == EmbeddingPurpose.QUERY && model in setOf("qwen3.7-text-embedding", "text-embedding-v4")) {
          put("instruct", EmbeddingInputFormatter.qwenInstruction)
        }
      }
    }
  }

  private fun compatibleBody(
    provider: ProviderKind,
    modelId: String,
    inputs: List<String>,
    purpose: EmbeddingPurpose,
  ): JsonObject = buildJsonObject {
    put("model", modelId)
    putJsonArray("input") { inputs.forEach { add(it) } }
    if (provider != ProviderKind.VOYAGE_AI && provider != ProviderKind.JINA_AI && provider != ProviderKind.FIREWORKS_AI) {
      put("encoding_format", "float")
    }
    when (provider) {
      ProviderKind.VOYAGE_AI -> put("input_type", if (purpose == EmbeddingPurpose.QUERY) "query" else "document")
      ProviderKind.JINA_AI -> put("task", if (purpose == EmbeddingPurpose.QUERY) "retrieval.query" else "retrieval.passage")
      ProviderKind.NVIDIA_NIM -> {
        if (nvidiaModelAcceptsInputType(modelId)) {
          put("input_type", if (purpose == EmbeddingPurpose.QUERY) "query" else "passage")
        }
        put("modality", "text")
      }
      else -> Unit
    }
  }

  /** NVIDIA GTE/GTR identifiers reject `input_type`. */
  private fun nvidiaModelAcceptsInputType(modelId: String): Boolean {
    val model = modelId.lowercase()
    val pathComponent = model.substringAfterLast('/')
    val tokens = pathComponent.split('-', '_')
    return "gte" !in tokens && "gtr" !in tokens
  }

  private fun isOfficialQwenCompatibleEndpoint(url: HttpUrl): Boolean {
    if (url.scheme != "https" || url.port != 443) return false
    if (EndpointPolicy.trimmedEncodedPath(url) != "/compatible-mode/v1") return false
    val host = url.host.lowercase()
    val sharedDomains = setOf(
      "dashscope.aliyuncs.com",
      "dashscope-intl.aliyuncs.com",
      "dashscope-us.aliyuncs.com",
      "cn-hongkong.dashscope.aliyuncs.com",
    )
    return host in sharedDomains || host.endsWith(".maas.aliyuncs.com")
  }

  private fun indexed(records: List<JsonObject>, indexKey: String, expectedCount: Int): List<FloatArray> {
    val vectors = arrayOfNulls<FloatArray>(expectedCount)
    for (record in records) {
      val index = record[indexKey].intOrNull() ?: throw invalid()
      if (index !in 0 until expectedCount || vectors[index] != null) throw invalid()
      vectors[index] = vector(record["embedding"])
    }
    val decoded = vectors.map { it ?: throw invalid() }
    return sameDimensions(decoded)
  }

  /** A non-empty array of finite JSON numbers (strings and booleans rejected). */
  private fun vector(element: JsonElement?): FloatArray {
    val array = element as? JsonArray ?: throw invalid()
    if (array.isEmpty()) throw invalid()
    return FloatArray(array.size) { index ->
      val primitive = array[index] as? JsonPrimitive ?: throw invalid()
      if (primitive.isString || primitive.content == "true" || primitive.content == "false" || primitive.content == "null") {
        throw invalid()
      }
      val value = primitive.content.toFloatOrNull() ?: throw invalid()
      if (!value.isFinite()) throw invalid()
      value
    }
  }

  private fun sameDimensions(vectors: List<FloatArray>): List<FloatArray> {
    val dimensions = vectors.firstOrNull()?.size ?: throw invalid()
    if (dimensions <= 0 || vectors.any { it.size != dimensions }) throw invalid()
    return vectors
  }

  /** OpenAI/Voyage/Jina/DashScope `usage`, or Cohere `meta.billed_units`. Gemini reports none. */
  private fun reportedInputTokens(root: JsonObject): Int? {
    val usage = root["usage"].objectOrNull()
    val fromUsage = usage?.let {
      it["prompt_tokens"].intOrNull() ?: it["input_tokens"].intOrNull() ?: it["total_tokens"].intOrNull()
    }
    return (fromUsage ?: root.at("meta.billed_units.input_tokens").intOrNull())?.takeIf { it >= 0 }
  }

  private fun invalid() = ProviderFailures.of(ProviderErrorKind.INVALID_RESPONSE)
}

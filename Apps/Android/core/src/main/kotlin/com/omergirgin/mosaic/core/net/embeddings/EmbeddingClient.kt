package com.omergirgin.mosaic.core.net.embeddings

import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.retrieval.EmbeddingVectorCodec

/** Embedding requests carry an explicit retrieval intent; each wire maps it to its own field. */
enum class EmbeddingPurpose { QUERY, DOCUMENT }

/** Vectors in input order, plus input tokens when the provider reported them. */
class EmbeddingResult(val vectors: List<FloatArray>, val inputTokens: Int?)

interface EmbeddingClient {
  /**
   * Embeds at most 64 inputs (250,000 UTF-8 bytes) for [modelId], splitting provider batches while
   * preserving order. Every response must keep the expected count and one nonzero dimension, also
   * across split batches and across calls on the same client. Throws
   * [com.omergirgin.mosaic.core.chat.ProviderException] with a sanitized message.
   */
  suspend fun embed(inputs: List<String>, modelId: String, purpose: EmbeddingPurpose): EmbeddingResult
}

object EmbeddingClientFactory {
  /** One client per retrieval or indexing job: its dimension guard spans the whole job. */
  fun make(connection: ProviderConnection): EmbeddingClient = HttpEmbeddingClient(connection)
}

/** Provider batch limits (Alibaba Model Studio and Baidu Qianfan publish smaller ceilings). */
object EmbeddingBatchPolicy {
  const val APPLICATION_MAXIMUM_INPUT_COUNT: Int = 64
  const val MAXIMUM_BATCH_UTF8_BYTES: Int = 250_000

  fun maximumInputCount(provider: ProviderKind, modelId: String): Int {
    val model = modelId.trim().lowercase()
    return when (provider) {
      // qwen3.7-text-embedding accepts 20 texts; text-embedding-v4 and unknown IDs stay at 10.
      ProviderKind.QWEN -> if (model == "qwen3.7-text-embedding") 20 else 10
      // Qianfan text embeddings accept 16 texts; tao-8k accepts one.
      ProviderKind.BAIDU_QIANFAN -> if (model == "tao-8k") 1 else 16
      else -> APPLICATION_MAXIMUM_INPUT_COUNT
    }
  }

  fun <T> batches(inputs: List<T>, provider: ProviderKind, modelId: String): List<List<T>> =
    inputs.chunked(maximumInputCount(provider, modelId))
}

/** Model-specific input prefixes and the vector-space identity of a profile. */
object EmbeddingInputFormatter {
  private const val E5_INSTRUCTION = "Given a user's question, retrieve relevant passages from their memory"
  private val E5_NAME = Regex("(^|[/:_\\-])e5-")
  private const val QWEN_INSTRUCTION =
    "Given a user's current message, retrieve relevant passages from their previous conversations and imported documents"

  fun query(text: String, provider: ProviderKind, modelId: String): String {
    val model = modelId.lowercase()
    if (provider == ProviderKind.GOOGLE && "gemini-embedding-2" in model) return "task: search result | query: $text"
    if (provider == ProviderKind.TINFOIL || "nomic-embed" in model) return "search_query: $text"
    if ("qwen3-embedding" in model) return "Instruct: $QWEN_INSTRUCTION\nQuery: $text"
    if ("embeddinggemma" in model) return "task: search result | query: $text"
    if ("arctic-embed" in model) return "query: $text"
    if (isNemotronEmbed(model) && provider != ProviderKind.NVIDIA_NIM) return "query: $text"
    if (isE5(model)) {
      return if ("instruct" in model) "Instruct: $E5_INSTRUCTION\nQuery: $text" else "query: $text"
    }
    return text
  }

  /** intfloat/e5-*, multilingual-e5-*: matched by name so hosted and local copies both format correctly. */
  private fun isE5(model: String): Boolean = "multilingual-e5" in model || E5_NAME.containsMatchIn(model)

  /**
   * nvidia/nemotron-*-embed-*: benchmarks/memory measured +0.069 MRR@10 with `query:`/`passage:` text prefixes on an
   * OpenAI-compatible route. NVIDIA NIM carries the same intent in the `input_type` request field, so its text stays raw.
   */
  private fun isNemotronEmbed(model: String): Boolean = "nemotron" in model && "embed" in model

  /**
   * Models whose input formatting was added after "embedding-format-v2". Their identity changes so vectors embedded
   * from unformatted text rebuild instead of being compared with formatted queries.
   */
  internal fun formatRevision(modelId: String, provider: ProviderKind? = null): String? {
    val model = modelId.lowercase()
    if ("embeddinggemma" in model || "arctic-embed" in model || isE5(model)) return "input-format-v3"
    if (isNemotronEmbed(model) && provider != ProviderKind.NVIDIA_NIM) return "input-format-v3"
    return null
  }

  fun document(text: String, provider: ProviderKind, modelId: String): String {
    val model = modelId.lowercase()
    if (provider == ProviderKind.GOOGLE && "gemini-embedding-2" in model) return "title: none | text: $text"
    if (provider == ProviderKind.TINFOIL || "nomic-embed" in model) return "search_document: $text"
    if ("embeddinggemma" in model) return "title: none | text: $text"
    if (isNemotronEmbed(model) && provider != ProviderKind.NVIDIA_NIM) return "passage: $text"
    if (isE5(model) && "instruct" !in model) return "passage: $text"
    return text
  }

  /**
   * Provider + resolved base URL + model identify one vector space. Any change makes stored vectors
   * stale instead of comparing incompatible spaces.
   */
  fun spaceIdentifier(provider: ProviderKind, resolvedBaseUrl: String?, modelId: String): String =
    EmbeddingVectorCodec.fingerprint(
      listOfNotNull("embedding-format-v2", provider.rawId, resolvedBaseUrl.orEmpty(), modelId, formatRevision(modelId, provider))
        .joinToString("|")
    )

  internal val qwenInstruction: String get() = QWEN_INSTRUCTION
}

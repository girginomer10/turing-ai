package com.omergirgin.mosaic.core.net

import com.omergirgin.mosaic.core.chat.DiscoveredModel
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.ProviderModelCatalogKind
import com.omergirgin.mosaic.core.provider.profile
import com.omergirgin.mosaic.core.provider.supportsModelDiscovery
import java.net.URI
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request

/** Public helpers the provider editor needs to describe a catalog test honestly. */
object ModelCatalogSupport {
  /**
   * True when the connection's catalog request is AI/ML API's exact public catalog, which is sent
   * without a credential. A successful listing then proves reachability only, not the key.
   */
  fun usesUnauthenticatedPublicCatalog(connection: ProviderConnection): Boolean {
    if (connection.provider != ProviderKind.AIML_API) return false
    return runCatching { ModelCatalogRequests.build(connection.copy(apiKey = null), cursor = null) }.isSuccess
  }
}

internal data class ModelCatalogPage(val models: List<DiscoveredModel>, val nextCursor: String?)

internal object ModelCatalogLimits {
  const val PAGE_LIMIT = 50
  const val MODEL_LIMIT = 10_000
  const val RESPONSE_BYTE_LIMIT = 4 * 1_024 * 1_024
  const val IDENTIFIER_BYTE_LIMIT = 1_024
  const val TOTAL_IDENTIFIER_BYTE_LIMIT = 4L * 1_024 * 1_024
  const val CURSOR_BYTE_LIMIT = 4_096
}

/** Builds one catalog page request: vendor route, paging parameters, and authentication. */
internal object ModelCatalogRequests {
  fun build(connection: ProviderConnection, cursor: String?): Request {
    val kind = connection.provider
    if (!kind.supportsModelDiscovery) throw unavailable()
    val baseUrl = EndpointPolicy.validatedBaseUrl(connection.resolvedBaseUrl)
    val catalogKind = kind.profile.modelCatalogKind
    val pageUrl = pageUrl(endpoint(catalogKind, baseUrl), catalogKind, cursor)
    val isPublicCatalog = kind == ProviderKind.AIML_API && isExactPublicAimlCatalog(pageUrl)
    if (!isPublicCatalog) ProviderCredentials.requireKeyIfNeeded(connection)
    val builder = Request.Builder().url(pageUrl).get().header("Accept", "application/json")
    // AI/ML API's official catalog is public; never attach a credential it does not need.
    if (!isPublicCatalog) builder.providerAuthentication(connection)
    return builder.build()
  }

  private fun endpoint(catalogKind: ProviderModelCatalogKind, baseUrl: HttpUrl): HttpUrl =
    when (catalogKind) {
      ProviderModelCatalogKind.XAI -> EndpointPolicy.appending("language-models", baseUrl)
      ProviderModelCatalogKind.DEEP_INFRA ->
        if (EndpointPolicy.isExactOfficialEndpoint(baseUrl, "api.deepinfra.com", "/v1/openai")) {
          "https://api.deepinfra.com/v1/models".toHttpUrl()
        } else {
          EndpointPolicy.appending("models", baseUrl)
        }
      ProviderModelCatalogKind.FIREWORKS ->
        if (EndpointPolicy.isExactOfficialEndpoint(baseUrl, "api.fireworks.ai", "/inference/v1")) {
          EndpointPolicy.replacingPath(baseUrl, "/v1/accounts/fireworks/models")
            .newBuilder()
            .addEncodedQueryParameter("filter", "supports_serverless=true")
            .build()
        } else {
          EndpointPolicy.appending("models", baseUrl)
        }
      ProviderModelCatalogKind.COHERE ->
        if (EndpointPolicy.isExactOfficialEndpoint(baseUrl, "api.cohere.ai", "/compatibility/v1")) {
          EndpointPolicy.replacingPath(baseUrl, "/v1/models").newBuilder().addQueryParameter("endpoint", "chat").build()
        } else {
          EndpointPolicy.appending("models", baseUrl)
        }
      ProviderModelCatalogKind.AIML_API ->
        if (EndpointPolicy.isExactOfficialEndpoint(baseUrl, "api.aimlapi.com", "/v1")) {
          "https://api.aimlapi.com/models".toHttpUrl()
        } else {
          EndpointPolicy.appending("models", baseUrl)
        }
      ProviderModelCatalogKind.SILICON_FLOW ->
        EndpointPolicy.appending("models", baseUrl).newBuilder().addQueryParameter("sub_type", "chat").build()
      ProviderModelCatalogKind.LM_STUDIO -> {
        // Only LM Studio's native typed catalog marks chat models; the `/v1/models` mirror does not.
        if (EndpointPolicy.trimmedEncodedPath(baseUrl) != "/v1") throw unavailable()
        EndpointPolicy.replacingPath(baseUrl, "/api/v1/models")
      }
      ProviderModelCatalogKind.UNAVAILABLE -> throw unavailable()
      ProviderModelCatalogKind.STANDARD,
      ProviderModelCatalogKind.ARCHITECTURE_TEXT_OUTPUT,
      ProviderModelCatalogKind.TOP_LEVEL_TEXT_OUTPUT,
      ProviderModelCatalogKind.OPEN_ROUTER,
      ProviderModelCatalogKind.TOP_LEVEL_ARRAY,
      ProviderModelCatalogKind.ANTHROPIC,
      ProviderModelCatalogKind.GEMINI,
      ProviderModelCatalogKind.MISTRAL,
      ProviderModelCatalogKind.TINFOIL,
      ProviderModelCatalogKind.FEATHERLESS,
      ProviderModelCatalogKind.VERCEL,
      ProviderModelCatalogKind.TENCENT_TOKEN_HUB,
      ProviderModelCatalogKind.BAIDU_QIANFAN,
      ProviderModelCatalogKind.POE -> EndpointPolicy.appending("models", baseUrl)
    }

  private fun pageUrl(endpoint: HttpUrl, catalogKind: ProviderModelCatalogKind, cursor: String?): HttpUrl {
    val builder = endpoint.newBuilder()
    when (catalogKind) {
      ProviderModelCatalogKind.ANTHROPIC -> {
        builder.addQueryParameter("limit", "1000")
        ModelCatalogParser.validatedCursor(cursor)?.let { builder.addQueryParameter("after_id", it) }
      }
      ProviderModelCatalogKind.GEMINI -> {
        builder.addQueryParameter("pageSize", "1000")
        ModelCatalogParser.validatedCursor(cursor)?.let { builder.addQueryParameter("pageToken", it) }
      }
      ProviderModelCatalogKind.FIREWORKS -> {
        builder.addQueryParameter("pageSize", "200")
        ModelCatalogParser.validatedCursor(cursor)?.let { builder.addQueryParameter("pageToken", it) }
      }
      ProviderModelCatalogKind.COHERE -> {
        builder.addQueryParameter("page_size", "1000")
        ModelCatalogParser.validatedCursor(cursor)?.let { builder.addQueryParameter("page_token", it) }
      }
      ProviderModelCatalogKind.FEATHERLESS -> {
        builder.addQueryParameter("conversational", "true")
        builder.addQueryParameter("available_on_current_plan", "true")
        builder.addQueryParameter("page", validatedPageNumber(cursor).toString())
        builder.addQueryParameter("per_page", "1000")
      }
      ProviderModelCatalogKind.OPEN_ROUTER -> {
        builder.addQueryParameter("output_modalities", "text")
        if (cursor != null) throw invalid()
      }
      else -> if (cursor != null) throw invalid()
    }
    return builder.build()
  }

  private fun validatedPageNumber(cursor: String?): Int {
    val value = ModelCatalogParser.validatedCursor(cursor) ?: return 1
    val page = value.toIntOrNull()
    if (page == null || page < 1 || page.toString() != value) throw invalid()
    return page
  }

  private fun isExactPublicAimlCatalog(url: HttpUrl): Boolean =
    EndpointPolicy.isExactOfficialEndpoint(url, "api.aimlapi.com", "/models") &&
      url.encodedUsername.isEmpty() &&
      url.encodedPassword.isEmpty() &&
      url.encodedQuery == null &&
      url.encodedFragment == null
}

/**
 * Decodes one catalog page into positively identified text-chat models. Every catalog shape keeps
 * offline, embedding, image, audio and other non-chat records out of the chat picker; absence of a
 * capability marker is never treated as chat support.
 */
internal object ModelCatalogParser {
  fun decodePage(body: ByteArray, provider: ProviderKind): ModelCatalogPage {
    val catalogKind = provider.profile.modelCatalogKind
    val payload = ProviderJson.parse(body)
    var nextCursor: String? = null
    val selected: List<Pair<String, JsonObject>> =
      when (catalogKind) {
        ProviderModelCatalogKind.ANTHROPIC -> {
          val json = payload.objectOrNull() ?: throw invalid()
          val records = json["data"].objectListOrNull() ?: throw invalid()
          val hasMore = json["has_more"].booleanOrNull() ?: throw invalid()
          if (hasMore) nextCursor = paginationCursor(json, "last_id") ?: throw invalid()
          records.mapNotNull { record ->
            if (record["type"].stringOrNull() != "model") return@mapNotNull null
            record["id"].stringOrNull()?.let { it to record }
          }
        }
        ProviderModelCatalogKind.GEMINI -> {
          val json = payload.objectOrNull() ?: throw invalid()
          val models = json["models"].objectListOrNull() ?: throw invalid()
          nextCursor = paginationCursor(json, "nextPageToken")
          models.mapNotNull { model ->
            val name = model["name"].stringOrNull() ?: return@mapNotNull null
            val methods = model["supportedGenerationMethods"].stringListOrNull() ?: return@mapNotNull null
            val id = GeminiWire.normalizedModelId(name)
            if ("generateContent" in methods && isGeminiTextChatModel(id)) id to model else null
          }
        }
        ProviderModelCatalogKind.XAI -> {
          val records = payload.objectOrNull()?.get("models").objectListOrNull() ?: throw invalid()
          records.withIds { it["id"].stringOrNull() }
        }
        ProviderModelCatalogKind.MISTRAL ->
          arrayOrDataRecords(payload).withIds { record ->
            val chat = record["capabilities"].objectOrNull()?.get("completion_chat").booleanOrNull()
            if (chat == true) record["id"].stringOrNull() else null
          }
        ProviderModelCatalogKind.TOP_LEVEL_ARRAY ->
          arrayOrDataRecords(payload).withIds { record ->
            if (record["type"].stringOrNull() == "chat") record["id"].stringOrNull() else null
          }
        ProviderModelCatalogKind.FIREWORKS -> {
          val json = payload.objectOrNull() ?: throw invalid()
          val records = json["models"].objectListOrNull() ?: json["data"].objectListOrNull() ?: throw invalid()
          nextCursor = paginationCursor(json, "nextPageToken")
          records.withIds { record ->
            if (record["conversationConfig"] !is JsonObject) return@withIds null
            record["name"].stringOrNull() ?: record["id"].stringOrNull()
          }
        }
        ProviderModelCatalogKind.COHERE -> {
          val json = payload.objectOrNull() ?: throw invalid()
          val records = json["models"].objectListOrNull() ?: throw invalid()
          nextCursor = paginationCursor(json, "next_page_token")
          records.withIds { it["name"].stringOrNull() ?: it["id"].stringOrNull() }
        }
        ProviderModelCatalogKind.VERCEL ->
          dataRecords(payload).withIds { record ->
            if (record["type"].stringOrNull()?.lowercase() != "language") return@withIds null
            if (record.containsKey("modalities")) {
              val output = record["modalities"].objectOrNull()?.get("output").stringListOrNull()
              if (output == null || !output.containsText()) return@withIds null
            }
            record["id"].stringOrNull()
          }
        ProviderModelCatalogKind.TENCENT_TOKEN_HUB ->
          dataRecords(payload).withIds { record ->
            if (record["status"].stringOrNull()?.lowercase() != "online") return@withIds null
            if (record["object"].stringOrNull() != "model") return@withIds null
            record["id"].stringOrNull()?.takeIf(::isTencentTextChatModel)
          }
        ProviderModelCatalogKind.BAIDU_QIANFAN ->
          dataRecords(payload).withIds { record ->
            record["id"].stringOrNull()?.takeIf { it.isNotBlank() && isBaiduTextChatModel(record) }
          }
        ProviderModelCatalogKind.ARCHITECTURE_TEXT_OUTPUT,
        ProviderModelCatalogKind.OPEN_ROUTER,
        ProviderModelCatalogKind.POE ->
          dataRecords(payload).withIds { record -> architectureTextOutputId(record, provider) }
        ProviderModelCatalogKind.TOP_LEVEL_TEXT_OUTPUT ->
          dataRecords(payload).withIds { record ->
            val output = record["output_modalities"].stringListOrNull()
            if (output != null && output.containsText()) record["id"].stringOrNull() else null
          }
        ProviderModelCatalogKind.AIML_API -> arrayOrDataRecords(payload).withIds(::aimlChatModelId)
        ProviderModelCatalogKind.FEATHERLESS -> {
          val json = payload.objectOrNull() ?: throw invalid()
          val records = json["data"].objectListOrNull() ?: throw invalid()
          val pagination = json["pagination"].objectOrNull() ?: throw invalid()
          val currentPage = pagination["current_page"].intOrNull() ?: throw invalid()
          val totalPages = pagination["total_pages"].intOrNull() ?: throw invalid()
          val consistent =
            currentPage >= 1 && totalPages >= 0 && if (totalPages == 0) currentPage == 1 else currentPage <= totalPages
          if (!consistent) throw invalid()
          nextCursor = if (currentPage < totalPages) (currentPage + 1).toString() else null
          records.withIds { it["id"].stringOrNull() }
        }
        ProviderModelCatalogKind.LM_STUDIO -> {
          val records = payload.objectOrNull()?.get("models").objectListOrNull() ?: throw invalid()
          records.withIds { record ->
            if (record["type"].stringOrNull()?.lowercase() != "llm") return@withIds null
            record["key"].stringOrNull()?.takeIf { it.isNotBlank() }
          }
        }
        ProviderModelCatalogKind.TINFOIL ->
          dataRecords(payload).withIds { record ->
            val endpoints = record["endpoints"].stringListOrNull()
            val isChat = record["type"].stringOrNull() == "chat" && endpoints?.contains("/v1/chat/completions") == true
            if (isChat) record["id"].stringOrNull() else null
          }
        ProviderModelCatalogKind.DEEP_INFRA ->
          dataRecords(payload).withIds { record ->
            val tags =
              record["metadata"].objectOrNull()?.get("tags").stringListOrNull().orEmpty().map { it.lowercase() }
            if (tags.any { it in DEEP_INFRA_CHAT_TAGS }) record["id"].stringOrNull() else null
          }
        ProviderModelCatalogKind.STANDARD,
        ProviderModelCatalogKind.SILICON_FLOW -> dataRecords(payload).withIds { it["id"].stringOrNull() }
        ProviderModelCatalogKind.UNAVAILABLE -> throw unavailable()
      }
    val models =
      selected.distinctBy { it.first }.sortedBy { it.first }.map { (id, record) -> discovered(id, record, catalogKind) }
    return ModelCatalogPage(models, nextCursor)
  }

  /** Empty cursors end paging; overlong ones are rejected before they reach a URL. */
  fun validatedCursor(cursor: String?): String? {
    if (cursor.isNullOrEmpty()) return null
    if (cursor.utf8Size() > ModelCatalogLimits.CURSOR_BYTE_LIMIT) {
      throw ProviderFailures.of(ProviderErrorKind.RESPONSE_TOO_LARGE)
    }
    return cursor
  }

  private fun paginationCursor(json: JsonObject, key: String): String? {
    if (!json.containsKey(key)) return null
    val raw = json[key]
    if (raw is JsonNull) return null
    return validatedCursor(raw.stringOrNull() ?: throw invalid())
  }

  private fun dataRecords(payload: JsonElement): List<JsonObject> =
    payload.objectOrNull()?.get("data").objectListOrNull() ?: throw invalid()

  private fun arrayOrDataRecords(payload: JsonElement): List<JsonObject> =
    payload.objectListOrNull() ?: payload.objectOrNull()?.get("data").objectListOrNull() ?: throw invalid()

  private inline fun List<JsonObject>.withIds(id: (JsonObject) -> String?): List<Pair<String, JsonObject>> =
    mapNotNull { record -> id(record)?.let { it to record } }

  private fun List<String>.containsText(): Boolean = any { it.lowercase() == "text" }

  private fun architectureTextOutputId(record: JsonObject, provider: ProviderKind): String? {
    val output = record["architecture"].objectOrNull()?.get("output_modalities").stringListOrNull()
    if (output == null || !output.containsText()) return null
    if (provider == ProviderKind.HUGGINGFACE && record.containsKey("providers")) {
      // Hugging Face lists router models whose inference providers may all be offline.
      val providers = record["providers"].objectListOrNull() ?: return null
      if (providers.none { it["status"].stringOrNull()?.lowercase() == "live" }) return null
    }
    if (provider == ProviderKind.POE && record.containsKey("supported_endpoints")) {
      // Public bots also publish an empty array when endpoint metadata is unspecified.
      val endpoints = record["supported_endpoints"].stringListOrNull() ?: return null
      if (endpoints.isNotEmpty() && "/v1/chat/completions" !in endpoints) return null
    }
    val id = record["id"].stringOrNull()
    // OpenRouter's `:batch` variants are not served by the streaming chat route.
    if (provider == ProviderKind.OPENROUTER && id?.endsWith(":batch") == true) return null
    return id
  }

  /**
   * The AI/ML registry identifies the wire endpoint in `type`; its playground tags also mark
   * Responses- and Anthropic-only entries as chat, so those tags are not capabilities.
   */
  private fun aimlChatModelId(record: JsonObject): String? {
    val type = record["type"].stringOrNull()?.lowercase() ?: return null
    val id = record["id"].stringOrNull()?.takeIf { it.isNotBlank() } ?: return null
    if (type == "openai/chat-completions") return id
    if (type != "chat-completion") return null
    val endpoints = record["endpoints"].stringListOrNull() ?: return null
    val servesChatCompletions =
      endpoints.any { endpoint ->
        runCatching { URI(endpoint).path }.getOrNull()?.lowercase() == "/v1/chat/completions"
      }
    return if (servesChatCompletions) id else null
  }

  /**
   * Gemini's `generateContent` method also covers media generation and specialized agents. Keep
   * text Gemini/Gemma families while excluding documented families that need a different request
   * or produce non-text output.
   */
  private fun isGeminiTextChatModel(identifier: String): Boolean {
    val normalized = identifier.lowercase()
    if (!normalized.startsWith("gemini-") && !normalized.startsWith("gemma-")) return false
    if (normalized.split('-').any { it in GEMINI_SPECIALIZED_TOKENS }) return false
    return "computer-use" !in normalized && "deep-research" !in normalized
  }

  /**
   * TokenHub's catalog has no modality field, so discovery stays on documented language and
   * text-output understanding families instead of guessing from the absence of media words.
   */
  private fun isTencentTextChatModel(identifier: String): Boolean {
    val normalized = identifier.lowercase()
    if (normalized in TENCENT_EXACT_IDS) return true
    if (TENCENT_FAMILY_PREFIXES.any { normalized.startsWith(it) }) return true
    // MiniMax language IDs use M plus a numeric generation (M2.7, M-3-0); requiring the digit
    // keeps a future `minimax-music-*` ID out.
    val prefix = "minimax-m"
    if (!normalized.startsWith(prefix)) return false
    val suffix = normalized.substring(prefix.length)
    if (suffix.firstOrNull()?.isDigit() == true) return true
    return suffix.firstOrNull() == '-' && suffix.getOrNull(1)?.isDigit() == true
  }

  /**
   * Qianfan marks text-output foundation models as `chat`, `multimodal`, or `image2text`.
   * Multimodal records must explicitly advertise text output; a chat/image2text record that
   * supplies contradictory non-text output metadata is rejected too.
   */
  private fun isBaiduTextChatModel(record: JsonObject): Boolean {
    val type = record["type"].stringOrNull()?.lowercase() ?: return false
    var outputModalities: List<String>? = null
    if (record.containsKey("architecture")) {
      val architecture = record["architecture"].objectOrNull() ?: return false
      if (architecture.containsKey("output_modalities")) {
        outputModalities = architecture["output_modalities"].stringListOrNull() ?: return false
      }
    }
    val explicitlyOutputsText = outputModalities?.containsText() == true
    return when (type) {
      "chat", "image2text" -> outputModalities == null || explicitlyOutputsText
      "multimodal" -> explicitlyOutputsText
      else -> false
    }
  }

  /** Display name and limits only where the catalog documents them; never inferred. */
  private fun discovered(id: String, record: JsonObject, catalogKind: ProviderModelCatalogKind): DiscoveredModel {
    val keys = metadataKeys(catalogKind)
    val displayName =
      keys.display.firstNotNullOfOrNull { record.at(it).stringOrNull() }
        ?.let { ProviderErrorSanitizer.cleanedText(it).prefixCodePoints(200) }
        ?.takeIf { it.isNotEmpty() && it != id }
    return DiscoveredModel(
      id = id,
      displayName = displayName,
      contextWindowTokens = keys.context.firstNotNullOfOrNull { record.at(it).intOrNull()?.takeIf(::isPlausibleLimit) },
      maximumOutputTokens = keys.output.firstNotNullOfOrNull { record.at(it).intOrNull()?.takeIf(::isPlausibleLimit) },
    )
  }

  private fun isPlausibleLimit(value: Int): Boolean = value in 1..100_000_000

  private class MetadataKeys(val display: List<String>, val context: List<String>, val output: List<String>)

  private fun metadataKeys(catalogKind: ProviderModelCatalogKind): MetadataKeys =
    when (catalogKind) {
      ProviderModelCatalogKind.ANTHROPIC -> MetadataKeys(listOf("display_name"), listOf("max_input_tokens"), listOf("max_tokens"))
      ProviderModelCatalogKind.GEMINI -> MetadataKeys(listOf("displayName"), listOf("inputTokenLimit"), listOf("outputTokenLimit"))
      ProviderModelCatalogKind.MISTRAL -> MetadataKeys(emptyList(), listOf("max_context_length"), emptyList())
      ProviderModelCatalogKind.TOP_LEVEL_ARRAY -> MetadataKeys(listOf("display_name"), listOf("context_length"), emptyList())
      ProviderModelCatalogKind.FIREWORKS -> MetadataKeys(listOf("displayName"), listOf("contextLength"), emptyList())
      ProviderModelCatalogKind.COHERE -> MetadataKeys(emptyList(), listOf("context_length"), emptyList())
      ProviderModelCatalogKind.VERCEL -> MetadataKeys(listOf("name"), listOf("context_window"), listOf("max_tokens"))
      ProviderModelCatalogKind.OPEN_ROUTER ->
        MetadataKeys(listOf("name"), listOf("context_length", "top_provider.context_length"), listOf("top_provider.max_completion_tokens"))
      ProviderModelCatalogKind.FEATHERLESS -> MetadataKeys(emptyList(), listOf("context_length"), listOf("max_completion_tokens"))
      ProviderModelCatalogKind.AIML_API -> MetadataKeys(listOf("info.name"), listOf("info.contextLength"), emptyList())
      ProviderModelCatalogKind.TOP_LEVEL_TEXT_OUTPUT -> MetadataKeys(emptyList(), listOf("context_length"), emptyList())
      ProviderModelCatalogKind.LM_STUDIO -> MetadataKeys(listOf("display_name"), listOf("max_context_length"), emptyList())
      ProviderModelCatalogKind.DEEP_INFRA -> MetadataKeys(emptyList(), listOf("metadata.context_length"), emptyList())
      ProviderModelCatalogKind.STANDARD,
      ProviderModelCatalogKind.TINFOIL,
      ProviderModelCatalogKind.SILICON_FLOW -> MetadataKeys(emptyList(), listOf("context_length", "context_window"), emptyList())
      else -> MetadataKeys(emptyList(), emptyList(), emptyList())
    }

  private val DEEP_INFRA_CHAT_TAGS = setOf("chat", "chat-completions", "text-generation", "llm")
  private val GEMINI_SPECIALIZED_TOKENS =
    setOf("image", "tts", "live", "audio", "transcribe", "transcription", "robotics", "omni", "embedding", "embeddings")
  private val TENCENT_EXACT_IDS =
    setOf("hy3", "hy3-preview", "hy4-preview", "hy-role", "hunyuan-role-latest", "tc-code-latest", "youtu-vita")
  private val TENCENT_FAMILY_PREFIXES =
    listOf(
      "hy3-",
      "hy4-",
      "hy-mt2-",
      "deepseek-",
      "deepseek/",
      "glm-",
      "kimi-",
      "qwen3.5-",
      "hy-vision-",
      "hunyuan-t1-vision-",
      "hunyuan-turbos-vision-video-",
    )
}

/**
 * Merges catalog pages under the iOS budgets: 50 pages, 10,000 unique IDs, 1,024 UTF-8 bytes per
 * ID, 4 MiB of retained IDs, no control characters, and no repeated cursor (a cycle would
 * otherwise page forever). A page is applied atomically or not at all.
 */
internal class ModelCatalogAccumulator(
  private val maximumPageCount: Int = ModelCatalogLimits.PAGE_LIMIT,
  private val maximumModelCount: Int = ModelCatalogLimits.MODEL_LIMIT,
) {
  private var pageCount = 0
  private val seenCursors = HashSet<String>()
  private val models = HashMap<String, DiscoveredModel>()
  private var totalIdentifierBytes = 0L

  val result: List<DiscoveredModel> get() = models.values.sortedBy { it.id }

  /** Returns the next cursor, or null when the catalog is complete. */
  fun consume(page: ModelCatalogPage): String? {
    val nextPageCount = pageCount + 1
    if (nextPageCount > maximumPageCount) throw tooLarge()
    val additions = LinkedHashMap<String, DiscoveredModel>()
    var nextTotalBytes = totalIdentifierBytes
    for (model in page.models) {
      val id = model.id
      if (id.isBlank()) throw invalid()
      val bytes = id.utf8Size()
      if (bytes > ModelCatalogLimits.IDENTIFIER_BYTE_LIMIT) throw tooLarge()
      if (id.codePoints().anyMatch { Character.getType(it) == Character.CONTROL.toInt() }) throw invalid()
      if (id in models || id in additions) continue
      additions[id] = model
      if (models.size + additions.size > maximumModelCount) throw tooLarge()
      nextTotalBytes += bytes
      if (nextTotalBytes > ModelCatalogLimits.TOTAL_IDENTIFIER_BYTE_LIMIT) throw tooLarge()
    }
    val nextCursor = page.nextCursor
    if (nextCursor != null) {
      if (nextPageCount >= maximumPageCount) throw tooLarge()
      if (nextCursor in seenCursors) throw invalid()
    }
    pageCount = nextPageCount
    models.putAll(additions)
    totalIdentifierBytes = nextTotalBytes
    nextCursor?.let(seenCursors::add)
    return nextCursor
  }
}

private fun invalid() = ProviderFailures.of(ProviderErrorKind.INVALID_RESPONSE)

private fun tooLarge() = ProviderFailures.of(ProviderErrorKind.RESPONSE_TOO_LARGE)

private fun unavailable() = ProviderFailures.of(ProviderErrorKind.MODEL_CATALOG_UNAVAILABLE)

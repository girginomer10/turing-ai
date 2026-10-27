package com.omergirgin.mosaic.core.net

import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.StreamEvent
import com.omergirgin.mosaic.core.chat.TokenUsage
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.profile
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.HttpUrl

/**
 * OpenAI Chat Completions (`POST /chat/completions`, SSE). Shared by every preset except OpenAI,
 * Anthropic and Google, including local runtimes and custom endpoints.
 */
internal object OpenAIChatCompletionsWire : ChatWireProtocol {
  override val dialect = ChatDialect.OPENAI_CHAT_COMPLETIONS

  override fun endpoint(baseUrl: HttpUrl, connection: ProviderConnection): HttpUrl =
    EndpointPolicy.appending("chat/completions", baseUrl)

  override fun body(connection: ProviderConnection, request: PreparedChatRequest): JsonObject =
    buildJsonObject {
      put("model", connection.modelId)
      putJsonArray("messages") {
        request.nonEmptySystemPrompt?.let { prompt ->
          addJsonObject {
            put("role", "system")
            put("content", prompt)
          }
        }
        for (message in request.messages) {
          addJsonObject {
            put("role", message.role.rawValue)
            put("content", content(message))
          }
        }
      }
      put("stream", true)
      put(maximumOutputTokensKey(connection), request.maxOutputTokens)
      if (connection.provider.profile.includesStreamingUsage) {
        putJsonObject("stream_options") { put("include_usage", true) }
      }
    }

  /** MiniMax and Kimi K3 reject the legacy `max_tokens` field. */
  private fun maximumOutputTokensKey(connection: ProviderConnection): String {
    val model = connection.modelId.trim().lowercase()
    val usesCompletionTokens =
      connection.provider == ProviderKind.MINIMAX || (connection.provider == ProviderKind.KIMI && model == "kimi-k3")
    return if (usesCompletionTokens) "max_completion_tokens" else "max_tokens"
  }

  private fun content(message: PreparedMessage): JsonElement {
    if (message.images.isEmpty()) return JsonPrimitive(message.content)
    return buildJsonArray {
      addJsonObject {
        put("type", "text")
        put("text", message.content)
      }
      for (image in message.images) {
        addJsonObject {
          put("type", "image_url")
          putJsonObject("image_url") {
            put("url", image.dataUrl)
            put("detail", "auto")
          }
        }
      }
    }
  }

  override fun decode(event: JsonObject): List<StreamEvent> {
    val events = ArrayList<StreamEvent>(3)
    var didComplete = false
    var completedResponseId: String? = null
    event["choices"].objectListOrNull()?.firstOrNull()?.let { choice ->
      choice["finish_reason"].stringOrNull()?.let { finishReason ->
        // Only `stop` (and some hosts' `normal`) is a clean answer; length, content_filter,
        // tool_calls and similar stops would otherwise persist a silently truncated reply.
        if (finishReason.lowercase() !in CLEAN_FINISH_REASONS) {
          throw ProviderFailures.provider("The provider stopped before a normal completion ($finishReason).")
        }
        didComplete = true
        completedResponseId = event["id"].stringOrNull()
      }
      choice["delta"].objectOrNull()?.get("content").stringOrNull()?.takeIf { it.isNotEmpty() }?.let {
        events += StreamEvent.TextDelta(it)
      }
    }
    event["usage"].objectOrNull()?.let { usage ->
      events +=
        StreamEvent.Usage(
          TokenUsage(
            inputTokens = usage["prompt_tokens"].intOrNull(),
            outputTokens = usage["completion_tokens"].intOrNull(),
          )
        )
    }
    if (didComplete) events += StreamEvent.Completed(completedResponseId)
    return events
  }

  private val CLEAN_FINISH_REASONS = setOf("stop", "normal")
}

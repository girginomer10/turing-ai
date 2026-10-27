package com.omergirgin.mosaic.core.net

import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.StreamEvent
import com.omergirgin.mosaic.core.chat.TokenUsage
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

/** Anthropic Messages API (`POST /messages`, SSE). */
internal object AnthropicMessagesWire : ChatWireProtocol {
  override val dialect = ChatDialect.ANTHROPIC_MESSAGES

  override fun endpoint(baseUrl: HttpUrl, connection: ProviderConnection): HttpUrl =
    EndpointPolicy.appending("messages", baseUrl)

  override fun body(connection: ProviderConnection, request: PreparedChatRequest): JsonObject =
    buildJsonObject {
      put("model", connection.modelId)
      putJsonArray("messages") {
        for (message in request.messages) {
          if (message.role != ChatRole.USER && message.role != ChatRole.ASSISTANT) continue
          addJsonObject {
            put("role", message.role.rawValue)
            put("content", content(message))
          }
        }
      }
      put("max_tokens", request.maxOutputTokens)
      put("stream", true)
      if (request.webSearch) {
        putJsonArray("tools") {
          addJsonObject {
            put("type", "web_search_20250305")
            put("name", "web_search")
            put("max_uses", 3)
          }
        }
        putJsonObject("tool_choice") { put("type", "auto") }
      }
      request.nonEmptySystemPrompt?.let { put("system", it) }
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
          put("type", "image")
          putJsonObject("source") {
            put("type", "base64")
            put("media_type", image.mimeType)
            put("data", image.base64)
          }
        }
      }
    }
  }

  override fun decode(event: JsonObject): List<StreamEvent> =
    when (event["type"].stringOrNull()) {
      "content_block_delta" -> {
        val delta = event["delta"].objectOrNull()
        when (delta?.get("type").stringOrNull()) {
          "citations_delta" -> {
            val source = delta?.get("citation").objectOrNull()?.let(WebSearchSupport::source)
            if (source == null) emptyList() else listOf(StreamEvent.Citations(listOf(source)))
          }
          "text_delta" -> {
            val text = delta?.get("text").stringOrNull()
            if (text == null) emptyList() else listOf(StreamEvent.TextDelta(text))
          }
          else -> emptyList()
        }
      }
      "message_start" -> {
        val usage = event["message"].objectOrNull()?.get("usage").objectOrNull()
        listOf(StreamEvent.Usage(TokenUsage(inputTokens = usage?.get("input_tokens").intOrNull())))
      }
      "message_delta" -> {
        val stopReason = event["delta"].objectOrNull()?.get("stop_reason").stringOrNull()
        // max_tokens, refusal, pause_turn, tool_use... are not a complete text answer.
        if (stopReason != null && stopReason !in CLEAN_STOP_REASONS) {
          throw ProviderFailures.provider("Anthropic stopped before a normal completion ($stopReason).")
        }
        val usage = event["usage"].objectOrNull()
        listOf(StreamEvent.Usage(TokenUsage(outputTokens = usage?.get("output_tokens").intOrNull())))
      }
      "message_stop" -> listOf(StreamEvent.Completed(null))
      "error" -> throw ProviderFailures.provider(providerErrorMessage(event) ?: "Anthropic reported an error.")
      else -> emptyList()
    }

  private val CLEAN_STOP_REASONS = setOf("end_turn", "stop_sequence")
}

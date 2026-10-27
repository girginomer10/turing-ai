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
import okhttp3.HttpUrl

/** OpenAI Responses API (`POST /responses`, SSE). Used only by the OpenAI preset. */
internal object OpenAIResponsesWire : ChatWireProtocol {
  override val dialect = ChatDialect.OPENAI_RESPONSES

  override fun endpoint(baseUrl: HttpUrl, connection: ProviderConnection): HttpUrl =
    EndpointPolicy.appending("responses", baseUrl)

  override fun body(connection: ProviderConnection, request: PreparedChatRequest): JsonObject =
    buildJsonObject {
      put("model", connection.modelId)
      putJsonArray("input") {
        for (message in request.messages) {
          if (message.role == ChatRole.SYSTEM) continue
          addJsonObject {
            put("role", message.role.rawValue)
            put("content", content(message))
          }
        }
      }
      put("max_output_tokens", request.maxOutputTokens)
      put("stream", true)
      // Turing AI keeps history locally; do not ask OpenAI to retain the response.
      put("store", false)
      if (request.webSearch) {
        putJsonArray("tools") { addJsonObject { put("type", "web_search") } }
        put("tool_choice", "required")
      }
      request.nonEmptySystemPrompt?.let { put("instructions", it) }
    }

  private fun content(message: PreparedMessage): JsonElement {
    if (message.images.isEmpty()) return JsonPrimitive(message.content)
    return buildJsonArray {
      addJsonObject {
        put("type", "input_text")
        put("text", message.content)
      }
      for (image in message.images) {
        addJsonObject {
          put("type", "input_image")
          put("image_url", image.dataUrl)
          put("detail", "auto")
        }
      }
    }
  }

  override fun decode(event: JsonObject): List<StreamEvent> =
    when (event["type"].stringOrNull()) {
      "response.output_text.annotation.added" -> {
        val source = event["annotation"].objectOrNull()?.let(WebSearchSupport::source)
        if (source == null) emptyList() else listOf(StreamEvent.Citations(listOf(source)))
      }
      "response.output_text.delta" -> textDelta(event)
      // Refusals are visible assistant output in the Responses API. Keep the provider's
      // explanation instead of completing with an apparently empty answer.
      "response.refusal.delta" -> textDelta(event)
      "response.completed" -> completed(event["response"].objectOrNull())
      "response.failed", "response.incomplete" -> {
        val response = event["response"].objectOrNull()
        val errorMessage = response?.get("error").objectOrNull()?.get("message").stringOrNull()
        val reason = response?.get("incomplete_details").objectOrNull()?.get("reason").stringOrNull()
        throw ProviderFailures.provider(
          errorMessage
            ?: reason?.let { "OpenAI stopped before completion ($it)." }
            ?: "OpenAI could not complete the response."
        )
      }
      else -> emptyList()
    }

  private fun textDelta(event: JsonObject): List<StreamEvent> {
    val delta = event["delta"].stringOrNull() ?: return emptyList()
    return listOf(StreamEvent.TextDelta(delta))
  }

  private fun completed(response: JsonObject?): List<StreamEvent> {
    val events = ArrayList<StreamEvent>(3)
    for (item in response?.get("output").objectListOrNull().orEmpty()) {
      for (content in item["content"].objectListOrNull().orEmpty()) {
        val sources = content["annotations"].objectListOrNull().orEmpty().mapNotNull(WebSearchSupport::source)
        if (sources.isNotEmpty()) events += StreamEvent.Citations(sources)
      }
    }
    response?.get("usage").objectOrNull()?.let { usage ->
      events +=
        StreamEvent.Usage(
          TokenUsage(inputTokens = usage["input_tokens"].intOrNull(), outputTokens = usage["output_tokens"].intOrNull())
        )
    }
    events += StreamEvent.Completed(response?.get("id").stringOrNull())
    return events
  }
}

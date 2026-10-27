package com.omergirgin.mosaic.core.net

import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.StreamEvent
import com.omergirgin.mosaic.core.chat.TokenUsage
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.HttpUrl

/**
 * Gemini `models/{model}:streamGenerateContent?alt=sse`. The key travels in `x-goog-api-key`,
 * never in the `key=` query parameter Google also accepts.
 */
internal object GeminiWire : ChatWireProtocol {
  override val dialect = ChatDialect.GEMINI

  override fun endpoint(baseUrl: HttpUrl, connection: ProviderConnection): HttpUrl {
    val model = EndpointPolicy.encodedPathSegment(normalizedModelId(connection.modelId))
    return EndpointPolicy.appending("models/$model:streamGenerateContent", baseUrl)
      .newBuilder()
      .query(null)
      .addQueryParameter("alt", "sse")
      .build()
  }

  /** Catalog names are `models/<id>`; requests and saved selections use the bare ID. */
  fun normalizedModelId(identifier: String): String = identifier.removePrefix("models/")

  override fun body(connection: ProviderConnection, request: PreparedChatRequest): JsonObject =
    buildJsonObject {
      putJsonArray("contents") {
        for (message in request.messages) {
          if (message.role != ChatRole.USER && message.role != ChatRole.ASSISTANT) continue
          addJsonObject {
            put("role", if (message.role == ChatRole.ASSISTANT) "model" else "user")
            putJsonArray("parts") {
              addJsonObject { put("text", message.content) }
              for (image in message.images) {
                addJsonObject {
                  putJsonObject("inlineData") {
                    put("mimeType", image.mimeType)
                    put("data", image.base64)
                  }
                }
              }
            }
          }
        }
      }
      putJsonObject("generationConfig") { put("maxOutputTokens", request.maxOutputTokens) }
      request.nonEmptySystemPrompt?.let { prompt ->
        putJsonObject("systemInstruction") { putJsonArray("parts") { addJsonObject { put("text", prompt) } } }
      }
    }

  override fun decode(event: JsonObject): List<StreamEvent> {
    event["promptFeedback"].objectOrNull()?.get("blockReason").stringOrNull()?.let { blockReason ->
      throw ProviderFailures.provider("Gemini blocked the prompt ($blockReason).")
    }
    val events = ArrayList<StreamEvent>(4)
    event["candidates"].objectListOrNull()?.firstOrNull()?.let { candidate ->
      val parts = candidate["content"].objectOrNull()?.get("parts").objectListOrNull().orEmpty()
      for (part in parts) {
        val text = part["text"].stringOrNull()
        if (!text.isNullOrEmpty()) events += StreamEvent.TextDelta(text)
      }
      candidate["finishReason"].stringOrNull()?.let { finishReason ->
        // MAX_TOKENS, SAFETY, RECITATION, BLOCKLIST... are not a complete answer.
        if (finishReason != "STOP") {
          throw ProviderFailures.provider("Gemini stopped before a normal completion ($finishReason).")
        }
        events += StreamEvent.Completed(null)
      }
    }
    // Cumulative per chunk; the pipeline's UsageCoalescer keeps only the newest counters.
    event["usageMetadata"].objectOrNull()?.let { usage ->
      events +=
        StreamEvent.Usage(
          TokenUsage(
            inputTokens = usage["promptTokenCount"].intOrNull(),
            outputTokens = usage["candidatesTokenCount"].intOrNull(),
          )
        )
    }
    return events
  }
}

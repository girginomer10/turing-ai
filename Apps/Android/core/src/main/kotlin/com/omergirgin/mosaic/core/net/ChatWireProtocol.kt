package com.omergirgin.mosaic.core.net

import com.omergirgin.mosaic.core.chat.ChatImageInput
import com.omergirgin.mosaic.core.chat.ChatRequest
import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import com.omergirgin.mosaic.core.chat.StreamEvent
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.supportsChat
import java.util.Base64
import kotlinx.serialization.json.JsonObject
import okhttp3.HttpUrl
import okhttp3.Request

/**
 * Provider identity is not a transport: OpenAI uses Responses, Anthropic uses Messages, Google uses
 * Gemini content generation, and every other preset (hosted, local, custom) speaks OpenAI Chat
 * Completions.
 */
internal enum class ChatDialect { OPENAI_RESPONSES, OPENAI_CHAT_COMPLETIONS, ANTHROPIC_MESSAGES, GEMINI }

/** One streaming chat wire format: route, request body, and per-event decoding. */
internal interface ChatWireProtocol {
  val dialect: ChatDialect

  fun endpoint(baseUrl: HttpUrl, connection: ProviderConnection): HttpUrl

  fun body(connection: ProviderConnection, request: PreparedChatRequest): JsonObject

  /** Decodes one SSE JSON payload. Throws [com.omergirgin.mosaic.core.chat.ProviderException] for non-clean stops. */
  fun decode(event: JsonObject): List<StreamEvent>
}

internal object ChatWireProtocols {
  fun dialect(kind: ProviderKind): ChatDialect =
    when (kind) {
      ProviderKind.OPENAI -> ChatDialect.OPENAI_RESPONSES
      ProviderKind.ANTHROPIC -> ChatDialect.ANTHROPIC_MESSAGES
      ProviderKind.GOOGLE -> ChatDialect.GEMINI
      else -> ChatDialect.OPENAI_CHAT_COMPLETIONS
    }

  fun forProvider(kind: ProviderKind): ChatWireProtocol =
    when (dialect(kind)) {
      ChatDialect.OPENAI_RESPONSES -> OpenAIResponsesWire
      ChatDialect.OPENAI_CHAT_COMPLETIONS -> OpenAIChatCompletionsWire
      ChatDialect.ANTHROPIC_MESSAGES -> AnthropicMessagesWire
      ChatDialect.GEMINI -> GeminiWire
    }
}

/** A validated photo with canonical (unwrapped, standard-alphabet) base64. */
internal class PreparedImage(val mimeType: String, val base64: String) {
  val dataUrl: String get() = "data:$mimeType;base64,$base64"
}

internal class PreparedMessage(val role: ChatRole, val content: String, val images: List<PreparedImage>)

internal class PreparedChatRequest(
  val messages: List<PreparedMessage>,
  val systemPrompt: String?,
  val maxOutputTokens: Int,
  val webSearch: Boolean,
) {
  val nonEmptySystemPrompt: String? get() = systemPrompt?.takeIf { it.isNotEmpty() }
}

/** Builds the HTTP request for a streaming chat call after every local precondition has passed. */
internal object ChatRequestFactory {
  private const val MAX_IMAGES_PER_REQUEST = 16
  private const val MAX_IMAGE_BYTES = 1_048_576
  private val supportedImageTypes = setOf("image/jpeg", "image/png")

  fun build(connection: ProviderConnection, request: ChatRequest): Pair<Request, ChatWireProtocol> {
    if (!connection.provider.supportsChat) throw ProviderFailures.of(ProviderErrorKind.CHAT_UNAVAILABLE)
    if (connection.modelId.isBlank()) throw ProviderFailures.of(ProviderErrorKind.MISSING_MODEL)
    val baseUrl = EndpointPolicy.validatedBaseUrl(connection.resolvedBaseUrl)
    ProviderCredentials.requireKeyIfNeeded(connection)
    val prepared = prepare(request)
    if (request.webSearch && !WebSearchSupport.isSupported(connection)) {
      throw ProviderFailures.provider(
        "Web search is unavailable for this connection and model. Choose a supported OpenAI or Claude model, or turn off Web search."
      )
    }
    val wire = ChatWireProtocols.forProvider(connection.provider)
    val httpRequest =
      Request.Builder()
        .url(wire.endpoint(baseUrl, connection))
        .post(ProviderHttp.jsonBody(wire.body(connection, prepared).toString()))
        .header("Accept", "text/event-stream")
        .providerAuthentication(connection)
        .build()
    return httpRequest to wire
  }

  private fun prepare(request: ChatRequest): PreparedChatRequest {
    val imageCount = request.messages.sumOf { it.images.size }
    // Photos are user input only; an image on another role would be a caller bug or tampering.
    if (imageCount > MAX_IMAGES_PER_REQUEST || request.messages.any { it.images.isNotEmpty() && it.role != ChatRole.USER }) {
      throw invalidPhotos()
    }
    val messages =
      request.messages.map { message ->
        PreparedMessage(message.role, message.content, message.images.map(::preparedImage))
      }
    return PreparedChatRequest(
      messages = messages,
      systemPrompt = request.systemPrompt,
      maxOutputTokens = request.maxOutputTokens.coerceAtLeast(1),
      webSearch = request.webSearch,
    )
  }

  private fun preparedImage(image: ChatImageInput): PreparedImage {
    if (image.mimeType !in supportedImageTypes) throw invalidPhotos()
    // Tolerate line-wrapped base64 (android.util.Base64.DEFAULT) but nothing else non-canonical.
    val compact = image.base64Data.filterNot { it == '\n' || it == '\r' || it == ' ' || it == '\t' }
    val bytes = runCatching { Base64.getDecoder().decode(compact) }.getOrNull() ?: throw invalidPhotos()
    if (bytes.isEmpty() || bytes.size > MAX_IMAGE_BYTES) throw invalidPhotos()
    return PreparedImage(image.mimeType, Base64.getEncoder().encodeToString(bytes))
  }

  private fun invalidPhotos() = ProviderFailures.provider("Invalid or too many photo attachments.")
}

package com.omergirgin.mosaic.core.chat

import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.profile
import java.net.URI

enum class ChatRole(val rawValue: String) { SYSTEM("system"), USER("user"), ASSISTANT("assistant") }

/** A JPEG/PNG image already normalized on-device (<= 1024 px long edge, <= 1 MiB, no metadata). */
data class ChatImageInput(val mimeType: String, val base64Data: String)

data class ChatMessage(
  val id: String,
  val role: ChatRole,
  val content: String,
  val images: List<ChatImageInput> = emptyList(),
)

/** Immutable request snapshot handed to a provider client. Clients never touch storage. */
data class ChatRequest(
  val messages: List<ChatMessage>,
  val systemPrompt: String? = null,
  val maxOutputTokens: Int = 8_192,
  val webSearch: Boolean = false,
)

data class TokenUsage(val inputTokens: Int? = null, val outputTokens: Int? = null)

data class WebSource(val title: String?, val url: String)

sealed interface StreamEvent {
  data class TextDelta(val text: String) : StreamEvent
  data class Citations(val sources: List<WebSource>) : StreamEvent
  data class Usage(val usage: TokenUsage) : StreamEvent
  /** Terminal success. A stream that ends without this is a failure. */
  data class Completed(val responseId: String?) : StreamEvent
}

/**
 * Non-secret identity of the adapter and exact base endpoint authorized to receive a credential
 * (scheme://host:port/path, path percent-encoding preserved, trailing slashes trimmed).
 */
data class CredentialBinding(val provider: ProviderKind, val endpoint: String) {
  companion object {
    fun of(provider: ProviderKind, baseUrl: String?): CredentialBinding {
      val uri = baseUrl?.let { runCatching { URI(it.trim()) }.getOrNull() }
      val scheme = uri?.scheme?.lowercase()
      val host = uri?.host?.lowercase()
      if (uri == null || scheme == null || host == null) return CredentialBinding(provider, "unresolved")
      val port = if (uri.port != -1) uri.port else if (scheme == "https") 443 else 80
      var path = uri.rawPath.orEmpty()
      while (path.length > 1 && path.endsWith("/")) path = path.dropLast(1)
      return CredentialBinding(provider, "$scheme://$host:$port$path")
    }
  }

  val storageKey: String get() = "${provider.rawId}|$endpoint"
}

/** Everything a client needs for one request: resolved endpoint, model, limits and the key. */
data class ProviderConnection(
  val id: String,
  val displayName: String,
  val provider: ProviderKind,
  /** User override; null means the preset default. */
  val baseUrl: String?,
  val modelId: String,
  val contextWindowTokens: Int? = null,
  val maximumOutputTokens: Int? = null,
  val apiKey: String? = null,
) {
  val resolvedBaseUrl: String? get() = baseUrl?.takeIf { it.isNotBlank() } ?: provider.profile.baseUrl
  val credentialBinding: CredentialBinding get() = CredentialBinding.of(provider, resolvedBaseUrl)

  /** Host shown in the UI for transparency ("Show the provider, model, and destination host"). */
  val destinationHost: String?
    get() = resolvedBaseUrl?.let { runCatching { URI(it).host }.getOrNull() }

  override fun toString(): String =
    "ProviderConnection(id=$id, provider=${provider.rawId}, model=$modelId, host=$destinationHost)"
}

/** Model returned by a live catalog, already filtered to positively identified text-chat models. */
data class DiscoveredModel(
  val id: String,
  val displayName: String? = null,
  val contextWindowTokens: Int? = null,
  val maximumOutputTokens: Int? = null,
)

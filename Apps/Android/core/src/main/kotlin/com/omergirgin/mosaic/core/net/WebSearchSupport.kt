package com.omergirgin.mosaic.core.net

import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.WebSource
import com.omergirgin.mosaic.core.provider.ProviderKind
import kotlinx.serialization.json.JsonObject
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * Explicit per-chat web search through each vendor's native tool only (OpenAI Responses
 * `web_search`, Anthropic `web_search_20250305`). Compatible gateways never receive these
 * vendor-specific tool schemas.
 */
object WebSearchSupport {
  private const val OPENAI_HOST = "api.openai.com"
  private const val ANTHROPIC_HOST = "api.anthropic.com"

  /** Model rule alone, assuming the preset's official endpoint. Prefer the connection overload. */
  fun isSupported(kind: ProviderKind, modelId: String): Boolean {
    val model = modelId.lowercase()
    return when (kind) {
      ProviderKind.OPENAI ->
        "nano" !in model &&
          "search-preview" !in model &&
          (model.startsWith("gpt-4.1") ||
            model.startsWith("gpt-5") ||
            model.startsWith("gpt-6") ||
            model == "o3" ||
            model == "o4-mini")
      ProviderKind.ANTHROPIC ->
        model.startsWith("claude-sonnet-4") ||
          model.startsWith("claude-opus-4") ||
          model.startsWith("claude-haiku-4") ||
          model.startsWith("claude-sonnet-5") ||
          model.startsWith("claude-opus-5") ||
          model.startsWith("claude-fable-5") ||
          model.startsWith("claude-haiku-5") ||
          model.startsWith("claude-3-7")
      else -> false
    }
  }

  /** Model rule plus the resolved destination: a custom base URL never gets the native tool. */
  fun isSupported(connection: ProviderConnection): Boolean {
    val officialHost =
      when (connection.provider) {
        ProviderKind.OPENAI -> OPENAI_HOST
        ProviderKind.ANTHROPIC -> ANTHROPIC_HOST
        else -> return false
      }
    val host = connection.resolvedBaseUrl?.trim()?.toHttpUrlOrNull()?.host
    return host == officialHost && isSupported(connection.provider, connection.modelId)
  }

  /** A provider citation (`url_citation` annotation or Anthropic citation) as a safe [WebSource]. */
  internal fun source(json: JsonObject): WebSource? {
    val url = json["url"].stringOrNull() ?: return null
    val title = (json["title"].stringOrNull() ?: url.toHttpUrlOrNull()?.host ?: "Source").prefixCodePoints(500)
    val start = json["start_index"].intOrNull()
    val end = json["end_index"].intOrNull()
    if ((start ?: 0) < 0 || (end ?: 0) < 0 || (end ?: 0) > 2_000_000) return null
    return WebSource(title, url).takeIf(::isValid)
  }

  /** Rejects links that could carry credentials, break Markdown rendering, or exceed sane sizes. */
  internal fun isValid(source: WebSource): Boolean {
    val url = source.url
    if ((source.title?.utf8Size() ?: 0) > 2_048 || url.utf8Size() > 8_192) return false
    if ('<' in url || '>' in url || url.any { it.isWhitespace() || it.isISOControl() }) return false
    val parsed = url.toHttpUrlOrNull() ?: return false
    return parsed.host.isNotEmpty() && parsed.encodedUsername.isEmpty() && parsed.encodedPassword.isEmpty()
  }
}

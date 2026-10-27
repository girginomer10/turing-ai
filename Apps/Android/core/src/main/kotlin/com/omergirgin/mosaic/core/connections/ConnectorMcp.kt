package com.omergirgin.mosaic.core.connections

import com.omergirgin.mosaic.core.chat.WebSource
import java.net.URI
import java.util.UUID
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Vendor-hosted MCP over Streamable HTTP (iOS `ConnectorMCP`): initialize + initialized
 * notification, protocol-version and session headers, paginated `tools/list`, `tools/call`, and
 * strict JSON-RPC ID matching (also inside SSE response bodies). No legacy standalone SSE transport.
 */
class ConnectorMcp(
  val service: ConnectorId,
  private val token: String,
  private val transport: ConnectorTransport,
) {
  private val lock = Mutex()
  private var sessionId: String? = null
  private var version = "2025-06-18"
  private var initialized = false

  suspend fun tools(): List<ConnectorTool> = lock.withLock {
    initialize()
    val tools = ArrayList<ConnectorTool>()
    var cursor: String? = null
    val seen = HashSet<String>()
    do {
      val params = cursor?.let { jsonObject("cursor" to JsonPrimitive(it)) } ?: JsonObject(emptyMap())
      val result = rpc("tools/list", params)
      val values = result["tools"].arrayValue ?: throw ConnectorException(ConnectorException.Kind.INVALID_RESPONSE)
      for (value in values) {
        val name = value["name"].stringValue
        val schema = value["inputSchema"].objectValue
        if (name.isNullOrEmpty() || ConnectorText.utf8Size(name) > 256 || schema == null ||
          ConnectorText.utf8Size(schema.encoded) > 32_768 || tools.any { it.name == name }
        ) {
          throw ConnectorException(ConnectorException.Kind.INVALID_RESPONSE)
        }
        tools += ConnectorTool(
          service = service,
          name = name,
          description = ConnectorText.bounded(value["description"].stringValue ?: name, 1_600),
          inputSchema = schema,
          needsApproval = !isKnownRead(service, name),
        )
      }
      if (tools.size > 500) throw ConnectorException(ConnectorException.Kind.TOO_LARGE)
      cursor = result["nextCursor"].stringValue
      if (cursor != null && (cursor.length > 4_096 || !seen.add(cursor) || seen.size >= 20)) {
        throw ConnectorException(ConnectorException.Kind.TOO_LARGE)
      }
    } while (cursor != null)
    tools
  }

  /** Structured tool errors stay evidence. A write is never retried after an uncertain response. */
  suspend fun call(name: String, arguments: JsonElement): ConnectorResult = lock.withLock {
    initialize()
    val value = rpc("tools/call", jsonObject("name" to JsonPrimitive(name), "arguments" to arguments))
    ConnectorResult(value, sources(value, service))
  }

  private suspend fun initialize() {
    if (initialized) return
    val result = rpc(
      "initialize",
      jsonObject(
        "protocolVersion" to JsonPrimitive(version),
        "capabilities" to JsonObject(emptyMap()),
        "clientInfo" to jsonObject("name" to JsonPrimitive("Turing AI"), "version" to JsonPrimitive("0.1.0")),
      ),
    )
    val negotiated = result["protocolVersion"].stringValue
    if (negotiated !in SUPPORTED_VERSIONS) throw ConnectorException(ConnectorException.Kind.INVALID_RESPONSE)
    version = negotiated!!
    rpc("notifications/initialized", JsonObject(emptyMap()), notification = true)
    initialized = true
  }

  private suspend fun rpc(method: String, params: JsonElement, notification: Boolean = false): JsonElement {
    val address = service.mcpUrl ?: throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
    val host = runCatching { URI(address).host }.getOrNull() ?: throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
    val id = UUID.randomUUID().toString()
    val payload = linkedMapOf<String, JsonElement>(
      "jsonrpc" to JsonPrimitive("2.0"), "method" to JsonPrimitive(method), "params" to params,
    )
    if (!notification) payload["id"] = JsonPrimitive(id)
    val headers = mutableListOf(
      "Accept" to "application/json, text/event-stream",
      "Authorization" to "Bearer $token",
    )
    if (method != "initialize") headers += "MCP-Protocol-Version" to version
    sessionId?.let { headers += "Mcp-Session-Id" to it }
    val response = transport.send(
      ConnectorRequest(address, "POST", headers, JsonObject(payload).encoded.encodeToByteArray(), "application/json"),
      allowedHosts = setOf(host),
      maximumBytes = 2_000_000,
      rpcId = if (notification) null else id,
    )
    val data = response.requireSuccess()
    response.headers["mcp-session-id"]?.let { session ->
      if (session.length > 1_024 || session.any { it.code !in 0x21..0x7e }) {
        throw ConnectorException(ConnectorException.Kind.INVALID_RESPONSE)
      }
      sessionId = session
    }
    if (notification) return JsonNull
    val value = ConnectorJson.parse(data)
    if (value["jsonrpc"].stringValue != "2.0" || value["id"].stringValue != id) {
      throw ConnectorException(ConnectorException.Kind.INVALID_RESPONSE)
    }
    val obj = value as JsonObject
    if (!obj["error"].isNullOrMissing || !obj.containsKey("result")) {
      throw ConnectorException(ConnectorException.Kind.REMOTE_FAILURE)
    }
    return obj.getValue("result")
  }

  companion object {
    private val SUPPORTED_VERSIONS = setOf("2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25")

    /** Exact app-maintained read names; neither server annotations nor a prefix authorize new tools. */
    fun isKnownRead(service: ConnectorId, name: String): Boolean {
      val names = when (service) {
        ConnectorId.LINEAR -> setOf(
          "get_user", "list_users", "get_issue", "list_issues", "get_project", "list_projects",
          "list_teams", "get_team", "list_comments", "list_cycles", "get_document",
          "list_documents", "search_documentation", "list_issue_statuses", "list_issue_labels",
        )
        ConnectorId.NOTION -> setOf(
          "notion-search", "notion-fetch", "notion-get-users", "notion-get-user", "notion-get-self",
          "notion-get-comments", "notion-get-teams",
        )
        ConnectorId.GITHUB -> setOf(
          "get_me", "search_repositories", "search_code", "search_issues", "search_pull_requests",
          "search_users", "get_file_contents", "list_commits", "get_commit", "list_branches",
          "list_issues", "issue_read", "pull_request_read", "list_pull_requests",
          "get_latest_release", "list_releases", "get_tag", "list_tags",
        )
        ConnectorId.ATLASSIAN -> setOf(
          "getAccessibleAtlassianResources", "atlassianUserInfo", "search", "fetch", "getJiraIssue",
          "searchJiraIssuesUsingJql", "getConfluencePage", "getConfluenceSpaces",
          "getPagesInConfluenceSpace", "searchConfluenceUsingCql",
          "getJiraProjectIssueTypesMetadata", "getVisibleJiraProjects",
        )
        // Cloudflare Code Mode can execute arbitrary service operations: always review.
        else -> emptySet()
      }
      return name in names
    }

    private val LINK_KEYS = listOf("url", "webUrl", "webLink", "htmlLink", "html_url", "source_url", "link", "uri")

    /** Public http(s) links found in a result (including JSON nested in text content), at most 50. */
    fun sources(value: JsonElement, service: ConnectorId): List<WebSource> {
      val result = ArrayList<WebSource>()
      fun visit(element: JsonElement, depth: Int) {
        if (depth >= 12 || result.size >= 50) return
        when (element) {
          is JsonObject -> {
            for (key in LINK_KEYS) {
              val address = element[key].stringValue ?: continue
              val uri = runCatching { URI(address) }.getOrNull() ?: continue
              if (uri.scheme !in setOf("https", "http") || uri.rawUserInfo != null || uri.host == null) continue
              if (ConnectorText.utf8Size(address) > 2_048 || result.any { it.url == address }) continue
              val title = element["title"].stringValue ?: element["name"].stringValue ?: service.title
              result += WebSource(ConnectorText.bounded(title, 300), address)
            }
            for (child in element.values) visit(child, depth + 1)
          }
          is JsonArray -> element.take(200).forEach { visit(it, depth + 1) }
          is JsonPrimitive -> {
            val string = element.stringValue ?: return
            if (string.length >= 500_000) return
            val trimmed = string.trimStart()
            if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) return
            val decoded = runCatching { ConnectorJson.parse(string) }.getOrNull() ?: return
            if (decoded != element) visit(decoded, depth + 1)
          }
        }
      }
      visit(value, 0)
      return result
    }
  }
}

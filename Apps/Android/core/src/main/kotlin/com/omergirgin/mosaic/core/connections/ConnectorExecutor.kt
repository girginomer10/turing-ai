package com.omergirgin.mosaic.core.connections

import com.omergirgin.mosaic.core.chat.WebSource
import java.net.URI
import java.util.UUID
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Runs tools for one chat request under one immutable [selection] (iOS `ConnectorExecutor`): every
 * binding is revalidated before and after each operation, continuation URLs reach the model only as
 * opaque local handles, and a write runs only when its exact call was approved.
 */
class ConnectorExecutor(
  private val selection: ConnectorSelection,
  private val store: ConnectorStore,
  private val transport: ConnectorTransport,
  private val device: DeviceConnectorBridge?,
  private val pdf: PdfTextReader?,
) {
  private val lock = Mutex()
  private val mcp = HashMap<ConnectorId, ConnectorMcp>()
  private val discovered = HashMap<String, ConnectorTool>()
  private val nextPages = HashMap<String, Pair<ConnectorId, String>>()

  suspend fun validate() {
    for ((service, id) in selection.bindings) {
      store.validate(service, id)
      if (service.isDevice && device?.isAuthorized(service) != true) throw ConnectorException(ConnectorException.Kind.DENIED)
    }
  }

  suspend fun tools(services: List<ConnectorId>): List<ConnectorTool> {
    validate()
    val tools = ArrayList<ConnectorTool>()
    for (service in services) {
      val id = selection.bindings[service] ?: throw ConnectorException(ConnectorException.Kind.CHANGED)
      when {
        service.isDevice -> tools += DeviceConnectorTools.tools(service)
        service.mcpUrl != null -> {
          val client = ConnectorMcp(service, store.token(service, id), transport)
          tools += client.tools()
          lock.withLock { mcp[service] = client }
        }
        service == ConnectorId.DROPBOX -> tools += dropboxTools
        else -> tools += ConnectorRest.operations(service).map { it.tool }
      }
      if (service.isMicrosoft || service == ConnectorId.READWISE) tools += nextPageTool(service)
    }
    validate()
    lock.withLock { for (tool in tools) discovered[tool.id] = tool }
    return tools
  }

  suspend fun call(call: ConnectorToolCall, approved: Boolean = false): ConnectorResult {
    validate()
    val tool = lock.withLock { discovered[call.tool] }
    val binding = tool?.let { selection.bindings[it.service] }
    if (tool == null || binding == null || (tool.needsApproval && !approved)) {
      throw ConnectorException(ConnectorException.Kind.DENIED)
    }
    ConnectorSchema.validate(call.arguments, tool.inputSchema)
    val result: ConnectorResult
    if (tool.service.isDevice) {
      result = (device ?: throw ConnectorException(ConnectorException.Kind.DENIED)).call(tool, call.arguments)
    } else {
      val token = store.token(tool.service, binding)
      validate()
      val client = lock.withLock { mcp[tool.service] }
      result = when {
        client != null -> client.call(tool.name, call.arguments)
        tool.service == ConnectorId.DROPBOX -> dropbox(tool.name, call.arguments, token)
        tool.name == "next_page" -> {
          val key = call.arguments["cursor"].stringValue
          val page = key?.let { lock.withLock { nextPages[it] } }
          if (page == null || page.first != tool.service) throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
          // Keep the service's exact validated continuation, including its query.
          read(
            ConnectorRequest(
              page.second,
              headers = listOf("Authorization" to RestOperation.authorization(tool.service, token), "Accept" to "application/json"),
            ),
            tool.service,
          )
        }
        else -> {
          val operation = ConnectorRest.operations(tool.service).firstOrNull { it.name == tool.name }
            ?: throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
          val request = operation.request(call.arguments, token)
          if (tool.service == ConnectorId.ONEDRIVE && tool.name == "read_file") oneDriveFile(request) else read(request, tool.service)
        }
      }
    }
    validate()
    return result
  }

  private suspend fun read(request: ConnectorRequest, service: ConnectorId): ConnectorResult {
    val requestUri = URI(request.url)
    val host = requestUri.host ?: throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    val response = transport.send(request, setOf(host), 2_000_000)
    val data = response.requireSuccess()
    var value: JsonElement = if (data.isEmpty()) jsonObject("completed" to JsonPrimitive(true)) else ConnectorJson.parse(data)
    if (value is JsonObject) {
      // Continuation URLs never come from the model. The service must keep the exact HTTPS origin
      // and resource path; only an opaque local handle reaches the model.
      val map = value.toMutableMap()
      val next = map["@odata.nextLink"].stringValue ?: if (service == ConnectorId.READWISE) map["next"].stringValue else null
      map.remove("@odata.nextLink")
      if (service == ConnectorId.READWISE) map.remove("next")
      if (next != null) {
        val nextUri = runCatching { URI(next) }.getOrNull()
        if (nextUri != null && ConnectorHttp.isAllowed(next, setOf(host)) && nextUri.rawPath == requestUri.rawPath && request.method == "GET") {
          val key = UUID.randomUUID().toString()
          lock.withLock { nextPages[key] = service to next }
          map["next_page_cursor"] = JsonPrimitive(key)
        } else {
          map["pagination_notice"] = JsonPrimitive("The service returned an unsupported continuation; narrow the search.")
        }
      }
      value = JsonObject(map)
    }
    value = sanitized(value)
    val sources = ConnectorMcp.sources(value, service).toMutableList()
    if (service == ConnectorId.TODOIST) {
      val tasks = value["results"].arrayValue?.toList() ?: if (value["content"].stringValue == null) emptyList() else listOf(value)
      for (task in tasks) {
        val id = task["id"].stringValue ?: continue
        val title = task["content"].stringValue ?: continue
        if (!ConnectorText.validId(id)) continue
        sources += WebSource(ConnectorText.bounded(title, 300), "https://app.todoist.com/app/task/$id")
      }
    }
    return ConnectorResult(value, sources)
  }

  private suspend fun oneDriveFile(request: ConnectorRequest): ConnectorResult {
    val item = ConnectorJson.parse(transport.send(request, setOf("graph.microsoft.com"), 64_000).requireSuccess())
    val name = item["name"].stringValue
    val size = item["size"].numberValue
    val address = item["@microsoft.graph.downloadUrl"].stringValue
    val host = address?.let(ConnectorFileText::microsoftDownloadHost)
    if (name == null || size == null || size < 0 || size > 2_000_000 ||
      ConnectorFileText.extension(name) !in ConnectorFileText.READABLE_EXTENSIONS || host == null
    ) {
      throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    }
    validate()
    // The signed URL comes only from authenticated Graph metadata and never reaches the model,
    // a source receipt or a log. The unsigned download carries no bearer token and no redirects.
    val response = transport.send(ConnectorRequest(address), setOf(host), 2_000_000)
    return ConnectorResult(
      ConnectorFileText.extract(response.requireSuccess(), name, pdf),
      ConnectorMcp.sources(sanitized(item), ConnectorId.ONEDRIVE),
    )
  }

  private suspend fun dropbox(name: String, arguments: JsonElement, token: String): ConnectorResult {
    var body = arguments
    var host = "api.dropboxapi.com"
    val route = when (name) {
      "search" -> {
        body = jsonObject("query" to (arguments["query"] ?: JsonPrimitive("")), "options" to jsonObject("max_results" to JsonPrimitive(50)))
        "files/search_v2"
      }
      "search_continue" -> "files/search/continue_v2"
      "list_folder" -> {
        body = jsonObject("path" to (arguments["path"] ?: JsonPrimitive("")), "limit" to JsonPrimitive(50))
        "files/list_folder"
      }
      "list_continue" -> "files/list_folder/continue"
      "read_file" -> {
        val path = arguments["path"].stringValue
        if (path == null || ConnectorFileText.extension(path) !in ConnectorFileText.READABLE_EXTENSIONS) {
          throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
        }
        host = "content.dropboxapi.com"
        "files/download"
      }
      else -> throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    }
    val url = "https://$host/2/$route"
    val authorization = "Authorization" to "Bearer $token"
    val request = if (name == "read_file") {
      ConnectorRequest(url, "POST", listOf(authorization, "Dropbox-API-Arg" to ConnectorFileText.asciiHeader(body)))
    } else {
      ConnectorRequest.json(url, body, listOf(authorization))
    }
    val data = transport.send(request, setOf(host), 2_000_000).requireSuccess()
    if (name == "read_file") return ConnectorResult(ConnectorFileText.extract(data, arguments["path"].stringValue.orEmpty(), pdf))
    return ConnectorResult(sanitized(ConnectorJson.parse(data)))
  }

  companion object {
    /** Removes signed download URLs and token-like fields before results reach a model. */
    fun sanitized(value: JsonElement): JsonElement = when (value) {
      is JsonObject -> JsonObject(
        value.filterKeys { key ->
          val lower = key.lowercase()
          "downloadurl" !in lower && lower !in setOf("access_token", "refresh_token", "client_secret")
        }.mapValues { sanitized(it.value) }
      )
      is JsonArray -> JsonArray(value.map(::sanitized))
      else -> value
    }

    /** Verifies a personal token (or a fresh OAuth token) and returns a short account label. */
    suspend fun verify(service: ConnectorId, token: String, transport: ConnectorTransport): String {
      if (token.isEmpty() || ConnectorText.utf8Size(token) > 16_384 || token.any { it.code !in 0x21..0x7e }) {
        throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
      }
      if (service.mcpUrl != null) {
        val tools = ConnectorMcp(service, token, transport).tools()
        if (tools.isEmpty()) throw ConnectorException(ConnectorException.Kind.DENIED)
        return "Connected · ${tools.size} available tools"
      }
      val endpoint = when (service) {
        ConnectorId.TODOIST -> "https://api.todoist.com/api/v1/user"
        ConnectorId.READWISE -> "https://readwise.io/api/v2/auth/"
        ConnectorId.AIRTABLE -> "https://api.airtable.com/v0/meta/whoami"
        ConnectorId.CLICKUP -> "https://api.clickup.com/api/v2/user"
        ConnectorId.RAINDROP -> "https://api.raindrop.io/rest/v1/user"
        ConnectorId.DROPBOX -> "https://api.dropboxapi.com/2/users/get_current_account"
        else -> if (service.isMicrosoft) "https://graph.microsoft.com/v1.0/me" else throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
      }
      val headers = listOf("Authorization" to RestOperation.authorization(service, token), "Accept" to "application/json")
      val request = ConnectorRequest(endpoint, if (service == ConnectorId.DROPBOX) "POST" else "GET", headers)
      val data = transport.send(request, setOf(URI(endpoint).host), 64_000).requireSuccess()
      if (data.isEmpty()) return "Connected account"
      val value = ConnectorJson.parse(data)
      val label = value["email"].stringValue ?: value["userPrincipalName"].stringValue ?: value["displayName"].stringValue
        ?: value["user"]["email"].stringValue ?: value["name"]["display_name"].stringValue ?: "Connected account"
      return ConnectorText.bounded(label, 300)
    }

    private fun nextPageTool(service: ConnectorId) = ConnectorTool(
      service, "next_page",
      "Read the next page using next_page_cursor from a previous result in this request. Never pass a URL.",
      stringToolSchema(mapOf("cursor" to "next_page_cursor from a previous result"), listOf("cursor"), maxLength = 64),
      needsApproval = false,
    )

    private val dropboxTools: List<ConnectorTool> by lazy {
      fun tool(name: String, description: String, fields: Map<String, String>, required: List<String>) =
        ConnectorTool(ConnectorId.DROPBOX, name, description, stringToolSchema(fields, required, maxLength = null), needsApproval = false)
      listOf(
        tool(
          "search", "Search Dropbox files by phrase. Returns metadata; follow cursor using search_continue.",
          mapOf("query" to "Short search phrase"), listOf("query"),
        ),
        tool("search_continue", "Read next Dropbox search page.", mapOf("cursor" to "Search result cursor"), listOf("cursor")),
        tool(
          "list_folder", "List folder contents, empty path for root. Follow cursor using list_continue when has_more.",
          mapOf("path" to "Folder path or empty string"), listOf("path"),
        ),
        tool("list_continue", "Read next folder page.", mapOf("cursor" to "Folder result cursor"), listOf("cursor")),
        tool(
          "read_file",
          "Read selected text/Markdown/CSV/JSON/log or selectable PDF text (file up to 2MB, text up to 30KB, PDF up to 20 pages). No OCR or Office parsing.",
          mapOf("path" to "Exact file path ending .txt, .md, .csv, .json, .log or .pdf"), listOf("path"),
        ),
      )
    }
  }
}

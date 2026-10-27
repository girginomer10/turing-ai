package com.omergirgin.mosaic.core.connections

import java.util.UUID
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Object schema whose properties are all bounded strings (app-owned tool descriptors). */
fun stringToolSchema(fields: Map<String, String>, required: List<String>, maxLength: Int? = 4_096): JsonObject =
  jsonObject(
    "type" to JsonPrimitive("object"),
    "properties" to JsonObject(
      fields.toSortedMap().mapValues { (_, description) ->
        val property = linkedMapOf<String, JsonElement>("type" to JsonPrimitive("string"), "description" to JsonPrimitive(description))
        if (maxLength != null) property["maxLength"] = JsonPrimitive(maxLength)
        JsonObject(property)
      }
    ),
    "required" to JsonArray(required.map(::JsonPrimitive)),
    "additionalProperties" to JsonPrimitive(false),
  )

/**
 * One app-owned REST operation (iOS `ConnectorRESTOperation`). The model supplies only string
 * arguments for declared parameters; it can never choose the URL, method or authorization header.
 */
data class RestOperation(
  val service: ConnectorId,
  val name: String,
  val description: String,
  val endpoint: String,
  val method: String = "GET",
  val required: List<String> = emptyList(),
  val parameters: Map<String, String> = emptyMap(),
  val fixed: Map<String, String> = emptyMap(),
  val bodyKeys: List<String> = emptyList(),
  val readOnly: Boolean = true,
) {
  val tool: ConnectorTool
    get() = ConnectorTool(service, name, description, stringToolSchema(parameters, required), needsApproval = !readOnly)

  fun request(arguments: JsonElement, token: String): ConnectorRequest {
    ConnectorSchema.validate(arguments, tool.inputSchema)
    val args = arguments as? JsonObject ?: throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    var path = endpoint
    val query = fixed.toMutableMap()
    val body = linkedMapOf<String, JsonElement>()
    for ((key, value) in args) {
      val string = value.stringValue ?: throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
      val placeholder = "{$key}"
      when {
        placeholder in path -> {
          if (string.isEmpty() || string == "." || string == ".." || ConnectorText.utf8Size(string) > 1_024) {
            throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
          }
          // OData string literal inside search(q='...'): a quote is escaped by doubling it.
          val pathValue = if (service == ConnectorId.ONEDRIVE && key == "query") string.replace("'", "''") else string
          // Only unreserved characters stay literal (no '.', '/', '?', '#'), so a value can't change the route.
          path = path.replace(placeholder, ConnectorText.percentEncode(pathValue).replace(".", "%2E"))
        }
        key in bodyKeys -> body[key] = JsonPrimitive(string)
        else -> query[key] = string
      }
    }
    if (service == ConnectorId.ONEDRIVE && "/items/root/" in path) path = path.replace("/items/root/", "/root/")
    if ('{' in path) throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    val url = if (query.isEmpty()) path else {
      path + "?" + query.entries.sortedBy { it.key }.joinToString("&") {
        ConnectorText.percentEncode(it.key, extraAllowed = "$") + "=" + ConnectorText.percentEncode(it.value)
      }
    }
    val headers = mutableListOf(
      "Authorization" to authorization(service, token),
      "Accept" to "application/json",
    )
    if (!readOnly && service == ConnectorId.TODOIST) headers += "X-Request-Id" to UUID.randomUUID().toString()
    return if (method == "POST") {
      ConnectorRequest(url, "POST", headers, JsonObject(body).encoded.encodeToByteArray(), "application/json")
    } else {
      ConnectorRequest(url, method, headers)
    }
  }

  companion object {
    fun authorization(service: ConnectorId, token: String): String = when (service) {
      ConnectorId.READWISE -> "Token $token"
      ConnectorId.CLICKUP -> token
      else -> "Bearer $token"
    }
  }
}

/** App-maintained REST catalogs (iOS `ConnectorREST.operations`). */
object ConnectorRest {
  fun operations(service: ConnectorId): List<RestOperation> {
    fun get(
      name: String,
      description: String,
      endpoint: String,
      required: List<String> = emptyList(),
      parameters: Map<String, String> = emptyMap(),
      fixed: Map<String, String> = emptyMap(),
    ) = RestOperation(service, name, description, endpoint, required = required, parameters = parameters, fixed = fixed)

    val cursor = mapOf("cursor" to "Pagination cursor returned by the previous page; omit on first page.")
    val page = mapOf("page" to "Zero-based page number. Continue until the service reports no more results.")
    return when (service) {
      ConnectorId.TODOIST -> listOf(
        get("projects", "List projects, with next_cursor for more pages.", "https://api.todoist.com/api/v1/projects", parameters = cursor),
        get(
          "tasks", "List active tasks. Use project_id for a specific project. Follow next_cursor.",
          "https://api.todoist.com/api/v1/tasks", parameters = cursor + ("project_id" to "Project ID"),
        ),
        get(
          "search",
          "Find active tasks with Todoist filter syntax, e.g. today, overdue, search: phrase. Follow next_cursor.",
          "https://api.todoist.com/api/v1/tasks/filter", listOf("query"), cursor + ("query" to "Todoist filter expression"),
        ),
        get("task", "Read a task by ID.", "https://api.todoist.com/api/v1/tasks/{id}", listOf("id"), mapOf("id" to "Task ID")),
        get(
          "comments", "Read task comments; follow next_cursor.", "https://api.todoist.com/api/v1/comments",
          listOf("task_id"), cursor + ("task_id" to "Task ID"),
        ),
        RestOperation(
          service, "create_task", "Create exactly one task after user review.", "https://api.todoist.com/api/v1/tasks",
          method = "POST", required = listOf("content"),
          parameters = mapOf(
            "content" to "Task title", "description" to "Task notes",
            "project_id" to "Destination project ID; omit for Inbox", "due_string" to "Due date in natural language",
          ),
          bodyKeys = listOf("content", "description", "project_id", "due_string"), readOnly = false,
        ),
        RestOperation(
          service, "complete_task", "Complete the specified task after user review.",
          "https://api.todoist.com/api/v1/tasks/{id}/close", method = "POST", required = listOf("id"),
          parameters = mapOf("id" to "Exact task ID to complete"), readOnly = false,
        ),
      )
      ConnectorId.OUTLOOK_MAIL -> listOf(
        get(
          "search",
          "Search Outlook mail using OData \$filter for dates/from or quoted \$search for full text. Do not combine \$search and \$filter. Use next_page tool for more.",
          "https://graph.microsoft.com/v1.0/me/messages",
          parameters = mapOf(
            "\$search" to "Quoted Outlook search expression, e.g. \"subject:invoice\"",
            "\$filter" to
              "OData filter e.g. receivedDateTime ge 2026-09-06T00:00:00Z and receivedDateTime lt 2026-09-07T00:00:00Z",
          ),
          fixed = mapOf("\$top" to "25", "\$select" to "id,subject,from,receivedDateTime,bodyPreview,webLink"),
        ),
        get(
          "message", "Read a selected email's body.", "https://graph.microsoft.com/v1.0/me/messages/{id}", listOf("id"),
          mapOf("id" to "Message ID"), mapOf("\$select" to "id,subject,from,toRecipients,receivedDateTime,body,webLink"),
        ),
      )
      ConnectorId.OUTLOOK_CALENDAR -> listOf(
        get("calendars", "List Outlook calendars.", "https://graph.microsoft.com/v1.0/me/calendars"),
        get(
          "events", "Read events in explicit ISO8601 range from the default calendar. Use next_page for more.",
          "https://graph.microsoft.com/v1.0/me/calendarView", listOf("startDateTime", "endDateTime"),
          mapOf(
            "startDateTime" to "ISO8601 range start including offset", "endDateTime" to "ISO8601 range end including offset",
          ),
          mapOf("\$top" to "50"),
        ),
      )
      ConnectorId.OUTLOOK_CONTACTS -> listOf(
        get(
          "contacts", "Search Outlook contacts with OData filter. Follow next_page for more.",
          "https://graph.microsoft.com/v1.0/me/contacts",
          parameters = mapOf("\$filter" to "Optional startswith(displayName,'Name') filter"),
          fixed = mapOf("\$top" to "50", "\$select" to "id,displayName,emailAddresses,mobilePhone,businessPhones,companyName"),
        ),
      )
      ConnectorId.MICROSOFT_TODO -> listOf(
        get("lists", "List Microsoft To Do lists.", "https://graph.microsoft.com/v1.0/me/todo/lists"),
        get(
          "tasks", "Read tasks in a list. Use OData filter and next_page as needed.",
          "https://graph.microsoft.com/v1.0/me/todo/lists/{listId}/tasks", listOf("listId"),
          mapOf("listId" to "List ID", "\$filter" to "Optional OData filter, e.g. status ne 'completed'"), mapOf("\$top" to "50"),
        ),
      )
      ConnectorId.ONEDRIVE -> listOf(
        get(
          "search", "Search OneDrive files by keyword; returns metadata, not file contents.",
          "https://graph.microsoft.com/v1.0/me/drive/root/search(q='{query}')", listOf("query"),
          mapOf("query" to "Short search phrase"), mapOf("\$top" to "50", "\$select" to "id,name,webUrl,size,file,folder,description"),
        ),
        get(
          "children", "List a folder's children; root is the root folder. Use next_page for more.",
          "https://graph.microsoft.com/v1.0/me/drive/items/{id}/children", listOf("id"), mapOf("id" to "Folder ID or root"),
          mapOf("\$top" to "50", "\$select" to "id,name,webUrl,size,file,folder,description"),
        ),
        get(
          "read_file",
          "Read a selected small text/Markdown/CSV/JSON/log file or selectable PDF text. File size limit 2MB. PDF extraction is bounded to 20 pages; no OCR or Office document parsing.",
          "https://graph.microsoft.com/v1.0/me/drive/items/{id}", listOf("id"), mapOf("id" to "File ID from a search or folder listing"),
        ),
        get(
          "item", "Read file metadata. This does not download document content.",
          "https://graph.microsoft.com/v1.0/me/drive/items/{id}", listOf("id"), mapOf("id" to "Item ID"),
          mapOf("\$select" to "id,name,webUrl,size,file,folder,description"),
        ),
      )
      ConnectorId.READWISE -> listOf(
        get(
          "books",
          "Find books/documents by category or source, page-number pagination starts at 1. Inspect titles then fetch highlights with book_id.",
          "https://readwise.io/api/v2/books/",
          parameters = mapOf(
            "page" to "Page starting at 1", "category" to "books, articles, tweets, podcasts, supplementals",
            "source" to "Optional source filter",
          ),
          fixed = mapOf("page_size" to "50"),
        ),
        get(
          "highlights", "Read highlights, preferably from a selected book. Follow next_page for more.",
          "https://readwise.io/api/v2/highlights/",
          parameters = mapOf("book_id" to "Book ID", "updated__gt" to "ISO8601 date filter", "page" to "Page starting at 1"),
          fixed = mapOf("page_size" to "50"),
        ),
      )
      ConnectorId.AIRTABLE -> listOf(
        get(
          "bases", "List permitted bases. Requires schema.bases:read. Follow offset.", "https://api.airtable.com/v0/meta/bases",
          parameters = mapOf("offset" to "Next offset"),
        ),
        get(
          "tables", "Inspect tables and fields before writing a filter formula.",
          "https://api.airtable.com/v0/meta/bases/{baseId}/tables", listOf("baseId"), mapOf("baseId" to "Base ID"),
        ),
        get(
          "records", "Read table records using filterByFormula and view; follow offset.",
          "https://api.airtable.com/v0/{baseId}/{tableId}", listOf("baseId", "tableId"),
          mapOf(
            "baseId" to "Base ID", "tableId" to "Table ID", "filterByFormula" to "Optional Airtable formula",
            "view" to "Optional view", "offset" to "Next offset",
          ),
          mapOf("pageSize" to "50"),
        ),
      )
      ConnectorId.CLICKUP -> listOf(
        get("workspaces", "List authorized workspaces.", "https://api.clickup.com/api/v2/team"),
        get(
          "tasks",
          "Read filtered workspace tasks. Page starts at 0; continue until last_page or fewer results. Date filters are milliseconds since Unix epoch.",
          "https://api.clickup.com/api/v2/team/{team_id}/task", listOf("team_id"),
          page + mapOf(
            "team_id" to "Workspace ID", "due_date_gt" to "Due date lower bound epoch milliseconds",
            "due_date_lt" to "Due date upper bound epoch milliseconds", "include_closed" to "true to include completed tasks",
          ),
        ),
        get("task", "Read one task.", "https://api.clickup.com/api/v2/task/{id}", listOf("id"), mapOf("id" to "Task ID")),
      )
      ConnectorId.RAINDROP -> listOf(
        get("collections", "List bookmark collections.", "https://api.raindrop.io/rest/v1/collections"),
        get(
          "search", "Search bookmarks in a collection, 0 for all. Page starts at 0; continue while a page is full.",
          "https://api.raindrop.io/rest/v1/raindrops/{collectionId}", listOf("collectionId"),
          page + mapOf(
            "collectionId" to "Collection ID or 0", "search" to "Search text with optional Raindrop filters",
            "sort" to "-created, created, title or -title",
          ),
          mapOf("perpage" to "50"),
        ),
        get(
          "bookmark", "Read bookmark metadata and excerpt, not the entire linked website.",
          "https://api.raindrop.io/rest/v1/raindrop/{id}", listOf("id"), mapOf("id" to "Bookmark ID"),
        ),
      )
      else -> emptyList()
    }
  }
}

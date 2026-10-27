import Foundation

struct ConnectorRESTOperation: Sendable {
  let service: ConnectorID
  let name: String
  let description: String
  let endpoint: String
  var method = "GET"
  var required: [String] = []
  var parameters: [String: String] = [:]
  var fixed: [String: String] = [:]
  var bodyKeys: [String] = []
  var readOnly = true
  var tool: ConnectorTool {
    .init(
      service: service, name: name, description: description,
      inputSchema: .object([
        "type": .string("object"),
        "properties": .object(
          parameters.mapValues {
            .object([
              "type": .string("string"), "description": .string($0), "maxLength": .number(4096),
            ])
          }), "required": .array(required.map(ConnectorJSON.string)),
        "additionalProperties": .bool(false),
      ]), needsApproval: !readOnly)
  }
  func request(_ arguments: ConnectorJSON, token: String) throws -> URLRequest {
    try ConnectorSchema.validate(arguments, schema: tool.inputSchema)
    guard let args = arguments.object else { throw ConnectorError.invalidArguments }
    var path = endpoint
    var query = fixed
    var body: [String: ConnectorJSON] = [:]
    for (key, value) in args {
      guard let string = value.string else { throw ConnectorError.invalidArguments }
      if path.contains("{" + key + "}") {
        guard !string.isEmpty, string != ".", string != "..", string.utf8.count <= 1024 else {
          throw ConnectorError.invalidArguments
        }
        let safe = CharacterSet(
          charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~")
        let pathValue =
          service == .oneDrive && key == "query"
          ? string.replacingOccurrences(of: "'", with: "''") : string
        guard let encoded = pathValue.addingPercentEncoding(withAllowedCharacters: safe) else {
          throw ConnectorError.invalidArguments
        }
        path = path.replacingOccurrences(of: "{" + key + "}", with: encoded)
      } else if bodyKeys.contains(key) {
        body[key] = .string(string)
      } else {
        query[key] = string
      }
    }
    if service == .oneDrive, path.contains("/items/root/") {
      path = path.replacingOccurrences(of: "/items/root/", with: "/root/")
    }
    guard !path.contains("{"), var components = URLComponents(string: path) else {
      throw ConnectorError.invalidArguments
    }
    if !query.isEmpty {
      components.queryItems = query.sorted(by: { $0.key < $1.key }).map {
        .init(name: $0.key, value: $0.value)
      }
    }
    guard let url = components.url else { throw ConnectorError.invalidArguments }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue(Self.authorization(service, token: token), forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if method == "POST" {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(ConnectorJSON.object(body))
    }
    if !readOnly, service == .todoist {
      request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
    }
    return request
  }
  static func authorization(_ service: ConnectorID, token: String) -> String {
    switch service {
    case .readwise: "Token " + token
    case .clickup: token
    default: "Bearer " + token
    }
  }
}

enum ConnectorREST {
  static func operations(_ service: ConnectorID) -> [ConnectorRESTOperation] {
    func get(
      _ name: String, _ description: String, _ endpoint: String, _ required: [String] = [],
      _ parameters: [String: String] = [:], _ fixed: [String: String] = [:]
    ) -> ConnectorRESTOperation {
      .init(
        service: service, name: name, description: description, endpoint: endpoint,
        required: required, parameters: parameters, fixed: fixed)
    }
    let cursor = ["cursor": "Pagination cursor returned by the previous page; omit on first page."]
    let page = [
      "page": "Zero-based page number. Continue until the service reports no more results."
    ]
    switch service {
    case .todoist:
      return [
        get(
          "projects", "List projects, with next_cursor for more pages.",
          "https://api.todoist.com/api/v1/projects", [], cursor),
        get(
          "tasks", "List active tasks. Use project_id for a specific project. Follow next_cursor.",
          "https://api.todoist.com/api/v1/tasks", [],
          cursor.merging(["project_id": "Project ID"]) { _, b in b }),
        get(
          "search",
          "Find active tasks with Todoist filter syntax, e.g. today, overdue, search: phrase. Follow next_cursor.",
          "https://api.todoist.com/api/v1/tasks/filter", ["query"],
          cursor.merging(["query": "Todoist filter expression"]) { _, b in b }),
        get(
          "task", "Read a task by ID.", "https://api.todoist.com/api/v1/tasks/{id}", ["id"],
          ["id": "Task ID"]),
        get(
          "comments", "Read task comments; follow next_cursor.",
          "https://api.todoist.com/api/v1/comments", ["task_id"],
          cursor.merging(["task_id": "Task ID"]) { _, b in b }),
        .init(
          service: service, name: "create_task",
          description: "Create exactly one task after user review.",
          endpoint: "https://api.todoist.com/api/v1/tasks", method: "POST", required: ["content"],
          parameters: [
            "content": "Task title", "description": "Task notes",
            "project_id": "Destination project ID; omit for Inbox",
            "due_string": "Due date in natural language",
          ], bodyKeys: ["content", "description", "project_id", "due_string"], readOnly: false),
        .init(
          service: service, name: "complete_task",
          description: "Complete the specified task after user review.",
          endpoint: "https://api.todoist.com/api/v1/tasks/{id}/close", method: "POST",
          required: ["id"], parameters: ["id": "Exact task ID to complete"], readOnly: false),
      ]
    case .googleCalendar:
      return [
        get(
          "calendars", "List accessible calendars; nextPageToken indicates more.",
          "https://www.googleapis.com/calendar/v3/users/me/calendarList", [],
          ["pageToken": "Next page token"]),
        get(
          "events",
          "Find calendar events in an explicit RFC3339 date range. Use primary or a listed calendar ID. Follow nextPageToken.",
          "https://www.googleapis.com/calendar/v3/calendars/{calendarId}/events",
          ["calendarId", "timeMin", "timeMax"],
          [
            "calendarId": "Calendar ID or primary",
            "timeMin": "Range start RFC3339 including timezone",
            "timeMax": "Range end RFC3339 including timezone", "q": "Optional search text",
            "pageToken": "Next page token",
          ], ["maxResults": "50", "singleEvents": "true", "orderBy": "startTime"]),
        get(
          "event", "Read one calendar event.",
          "https://www.googleapis.com/calendar/v3/calendars/{calendarId}/events/{eventId}",
          ["calendarId", "eventId"], ["calendarId": "Calendar ID", "eventId": "Event ID"]),
      ]
    case .googleTasks:
      return [
        get(
          "lists", "List task lists; follow nextPageToken.",
          "https://tasks.googleapis.com/tasks/v1/users/@me/lists", [],
          ["pageToken": "Next page token"], ["maxResults": "100"]),
        get(
          "tasks",
          "Read tasks from a list. Follow nextPageToken; dueMin/dueMax use RFC3339. Completed tasks only if requested.",
          "https://tasks.googleapis.com/tasks/v1/lists/{listId}/tasks", ["listId"],
          [
            "listId": "List ID or @default", "pageToken": "Next page token",
            "dueMin": "Earliest due date", "dueMax": "Latest due date",
            "showCompleted": "true or false",
            "showHidden": "true to include completed tasks hidden by Google",
          ], ["maxResults": "100", "showCompleted": "false"]),
      ]
    case .outlookMail:
      return [
        get(
          "search",
          "Search Outlook mail using OData $filter for dates/from or quoted $search for full text. Do not combine $search and $filter. Use next_page tool for more.",
          "https://graph.microsoft.com/v1.0/me/messages", [],
          [
            "$search": "Quoted Outlook search expression, e.g. \"subject:invoice\"",
            "$filter":
              "OData filter e.g. receivedDateTime ge 2026-09-06T00:00:00Z and receivedDateTime lt 2026-09-07T00:00:00Z",
          ], ["$top": "25", "$select": "id,subject,from,receivedDateTime,bodyPreview,webLink"]),
        get(
          "message", "Read a selected email's body.",
          "https://graph.microsoft.com/v1.0/me/messages/{id}", ["id"], ["id": "Message ID"],
          ["$select": "id,subject,from,toRecipients,receivedDateTime,body,webLink"]),
      ]
    case .outlookCalendar:
      return [
        get(
          "calendars", "List Outlook calendars.", "https://graph.microsoft.com/v1.0/me/calendars"),
        get(
          "events",
          "Read events in explicit ISO8601 range from the default calendar. Use next_page for more.",
          "https://graph.microsoft.com/v1.0/me/calendarView", ["startDateTime", "endDateTime"],
          [
            "startDateTime": "ISO8601 range start including offset",
            "endDateTime": "ISO8601 range end including offset",
          ], ["$top": "50"]),
      ]
    case .outlookContacts:
      return [
        get(
          "contacts", "Search Outlook contacts with OData filter. Follow next_page for more.",
          "https://graph.microsoft.com/v1.0/me/contacts", [],
          ["$filter": "Optional startswith(displayName,'Name') filter"],
          [
            "$top": "50",
            "$select": "id,displayName,emailAddresses,mobilePhone,businessPhones,companyName",
          ])
      ]
    case .microsoftToDo:
      return [
        get(
          "lists", "List Microsoft To Do lists.", "https://graph.microsoft.com/v1.0/me/todo/lists"),
        get(
          "tasks", "Read tasks in a list. Use OData filter and next_page as needed.",
          "https://graph.microsoft.com/v1.0/me/todo/lists/{listId}/tasks", ["listId"],
          ["listId": "List ID", "$filter": "Optional OData filter, e.g. status ne 'completed'"],
          ["$top": "50"]),
      ]
    case .oneDrive:
      return [
        get(
          "search", "Search OneDrive files by keyword; returns metadata, not file contents.",
          "https://graph.microsoft.com/v1.0/me/drive/root/search(q='{query}')", ["query"],
          ["query": "Short search phrase"],
          ["$top": "50", "$select": "id,name,webUrl,size,file,folder,description"]),
        get(
          "children", "List a folder's children; root is the root folder. Use next_page for more.",
          "https://graph.microsoft.com/v1.0/me/drive/items/{id}/children", ["id"],
          ["id": "Folder ID or root"],
          ["$top": "50", "$select": "id,name,webUrl,size,file,folder,description"]),
        get(
          "read_file",
          "Read a selected small text/Markdown/CSV/JSON/log file or selectable PDF text. File size limit 2MB. PDF extraction is bounded to 20 pages; no OCR or Office document parsing.",
          "https://graph.microsoft.com/v1.0/me/drive/items/{id}", ["id"],
          ["id": "File ID from a search or folder listing"]),
        get(
          "item", "Read file metadata. This does not download document content.",
          "https://graph.microsoft.com/v1.0/me/drive/items/{id}", ["id"], ["id": "Item ID"],
          ["$select": "id,name,webUrl,size,file,folder,description"]),
      ]
    case .readwise:
      return [
        get(
          "books",
          "Find books/documents by category or source, page-number pagination starts at 1. Inspect titles then fetch highlights with book_id.",
          "https://readwise.io/api/v2/books/", [],
          [
            "page": "Page starting at 1",
            "category": "books, articles, tweets, podcasts, supplementals",
            "source": "Optional source filter",
          ], ["page_size": "50"]),
        get(
          "highlights",
          "Read highlights, preferably from a selected book. Follow next_page for more.",
          "https://readwise.io/api/v2/highlights/", [],
          [
            "book_id": "Book ID", "updated__gt": "ISO8601 date filter",
            "page": "Page starting at 1",
          ], ["page_size": "50"]),
      ]
    case .airtable:
      return [
        get(
          "bases", "List permitted bases. Requires schema.bases:read. Follow offset.",
          "https://api.airtable.com/v0/meta/bases", [], ["offset": "Next offset"]),
        get(
          "tables", "Inspect tables and fields before writing a filter formula.",
          "https://api.airtable.com/v0/meta/bases/{baseId}/tables", ["baseId"],
          ["baseId": "Base ID"]),
        get(
          "records", "Read table records using filterByFormula and view; follow offset.",
          "https://api.airtable.com/v0/{baseId}/{tableId}", ["baseId", "tableId"],
          [
            "baseId": "Base ID", "tableId": "Table ID",
            "filterByFormula": "Optional Airtable formula", "view": "Optional view",
            "offset": "Next offset",
          ], ["pageSize": "50"]),
      ]
    case .clickup:
      return [
        get("workspaces", "List authorized workspaces.", "https://api.clickup.com/api/v2/team"),
        get(
          "tasks",
          "Read filtered workspace tasks. Page starts at 0; continue until last_page or fewer results. Date filters are milliseconds since Unix epoch.",
          "https://api.clickup.com/api/v2/team/{team_id}/task", ["team_id"],
          page.merging([
            "team_id": "Workspace ID", "due_date_gt": "Due date lower bound epoch milliseconds",
            "due_date_lt": "Due date upper bound epoch milliseconds",
            "include_closed": "true to include completed tasks",
          ]) { _, b in b }),
        get(
          "task", "Read one task.", "https://api.clickup.com/api/v2/task/{id}", ["id"],
          ["id": "Task ID"]),
      ]
    case .raindrop:
      return [
        get(
          "collections", "List bookmark collections.", "https://api.raindrop.io/rest/v1/collections"
        ),
        get(
          "search",
          "Search bookmarks in a collection, 0 for all. Page starts at 0; continue while a page is full.",
          "https://api.raindrop.io/rest/v1/raindrops/{collectionId}", ["collectionId"],
          page.merging([
            "collectionId": "Collection ID or 0",
            "search": "Search text with optional Raindrop filters",
            "sort": "-created, created, title or -title",
          ]) { _, b in b }, ["perpage": "50"]),
        get(
          "bookmark", "Read bookmark metadata and excerpt, not the entire linked website.",
          "https://api.raindrop.io/rest/v1/raindrop/{id}", ["id"], ["id": "Bookmark ID"]),
      ]
    default: return []
    }
  }
}

enum ConnectorSchema {
  static func validate(_ value: ConnectorJSON, schema: ConnectorJSON, depth: Int = 0) throws {
    guard depth <= 20, value.encoded.utf8.count <= 32_768 else {
      throw ConnectorError.invalidArguments
    }
    if let allowed = schema["enum"].array, !allowed.contains(value) {
      throw ConnectorError.invalidArguments
    }
    switch schema["type"].string {
    case "object":
      guard let object = value.object else { throw ConnectorError.invalidArguments }
      let properties = schema["properties"].object ?? [:]
      let required = schema["required"].array?.compactMap(\.string) ?? []
      guard required.allSatisfy({ object[$0] != nil }),
        schema["additionalProperties"].bool != false
          || Set(object.keys).isSubset(of: Set(properties.keys))
      else { throw ConnectorError.invalidArguments }
      for (key, child) in object {
        if let field = properties[key] { try validate(child, schema: field, depth: depth + 1) }
      }
    case "array":
      guard let array = value.array, array.count <= 200 else {
        throw ConnectorError.invalidArguments
      }
      for child in array { try validate(child, schema: schema["items"], depth: depth + 1) }
    case "string":
      guard let string = value.string, string.utf8.count <= 16_384,
        Double(string.count) <= (schema["maxLength"].number ?? 16_384)
      else { throw ConnectorError.invalidArguments }
    case "number", "integer":
      guard let number = value.number, number.isFinite,
        schema["type"].string != "integer" || number.rounded() == number
      else { throw ConnectorError.invalidArguments }
    case "boolean": guard value.bool != nil else { throw ConnectorError.invalidArguments }
    default: break
    }
  }
}

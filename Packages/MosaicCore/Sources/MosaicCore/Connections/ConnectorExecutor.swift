import Foundation

actor ConnectorExecutor {
  private let selection: ConnectorSelection
  private let transport: any ConnectorTransport
  private let store: ConnectorStore
  private var mcp: [ConnectorID: ConnectorMCP] = [:]
  private var discovered: [String: ConnectorTool] = [:]
  private var nextPages: [String: (service: ConnectorID, url: URL)] = [:]
  private var googleLease: GoogleConnectionLease?
  init(
    selection: ConnectorSelection, transport: any ConnectorTransport = ConnectorHTTP(),
    store: ConnectorStore = .shared
  ) {
    self.selection = selection
    self.transport = transport
    self.store = store
  }
  func validate() async throws {
    for (service, id) in selection.bindings {
      try await store.validate(service, id: id)
      if service.isApple, !AppleConnections.authorized(service) { throw ConnectorError.denied }
      if let scope = service.googleService {
        let lease = try await GoogleConnectionStore.shared.lease()
        let marker = try await store.credential(service)
        guard lease.account.subject == marker?.label, lease.account.supports(scope) else {
          throw ConnectorError.changed
        }
        if let googleLease {
          try await GoogleConnectionStore.shared.validate(googleLease)
        } else {
          googleLease = lease
        }
      }
    }
  }
  func tools(for services: [ConnectorID]) async throws -> [ConnectorTool] {
    try await validate()
    var tools: [ConnectorTool] = []
    for service in services {
      guard let id = selection.bindings[service] else { throw ConnectorError.changed }
      if service.isApple {
        tools += AppleConnections.tools(service)
      } else if service.mcpURL != nil {
        let token = try await store.token(service, id: id)
        let client = ConnectorMCP(service: service, token: token, transport: transport)
        tools += try await client.tools()
        mcp[service] = client
      } else if service == .dropbox {
        tools += Self.dropboxTools
      } else {
        tools += ConnectorREST.operations(service).map(\.tool)
      }
      if service.isMicrosoft || service == .readwise {
        tools.append(Self.nextPageTool(service))
      }
    }
    try await validate()
    for tool in tools { discovered[tool.id] = tool }
    return tools
  }
  func call(_ call: ConnectorToolCall, approved: Bool = false) async throws -> ConnectorResult {
    try await validate()
    guard let tool = discovered[call.tool], let binding = selection.bindings[tool.service],
      !tool.needsApproval || approved
    else { throw ConnectorError.denied }
    try ConnectorSchema.validate(call.arguments, schema: tool.inputSchema)
    let result: ConnectorResult
    if tool.service.isApple {
      result = try await AppleConnections.shared.call(tool, arguments: call.arguments)
    } else {
      let token: String
      if let scope = tool.service.googleService {
        guard let account = googleLease?.account else { throw ConnectorError.changed }
        token = try await GoogleConnectionStore.shared.token(for: scope, subject: account.subject)
      } else {
        token = try await store.token(tool.service, id: binding)
      }
      try await validate()
      if let client = mcp[tool.service] {
        result = try await client.call(tool.name, arguments: call.arguments)
      } else if tool.service == .dropbox {
        result = try await dropbox(tool.name, arguments: call.arguments, token: token)
      } else {
        let request: URLRequest
        if tool.name == "next_page" {
          guard let key = call.arguments["cursor"].string, let page = nextPages[key],
            page.service == tool.service
          else { throw ConnectorError.invalidArguments }
          // Retain the service's exact validated continuation, including its query.
          var next = URLRequest(url: page.url)
          next.setValue(
            ConnectorRESTOperation.authorization(tool.service, token: token),
            forHTTPHeaderField: "Authorization")
          result = try await read(next, service: tool.service)
          try await validate()
          return result
        } else {
          guard
            let operation = ConnectorREST.operations(tool.service).first(where: {
              $0.name == tool.name
            })
          else { throw ConnectorError.invalidArguments }
          request = try operation.request(call.arguments, token: token)
        }
        if tool.service == .oneDrive, tool.name == "read_file" {
          result = try await oneDriveFile(request)
        } else {
          result = try await read(request, service: tool.service)
        }
      }
    }
    try await validate()
    return result
  }
  private func read(_ request: URLRequest, service: ConnectorID) async throws -> ConnectorResult {
    guard let host = request.url?.host else { throw ConnectorError.invalidArguments }
    let response = try await transport.send(
      request, allowedHosts: [host], maximumBytes: 2_000_000, rpcID: nil)
    let data = try response.requireSuccess()
    var value =
      data.isEmpty
      ? ConnectorJSON.object(["completed": .bool(true)]) : try ConnectorJSON.decode(data)
    if var object = value.object {
      // Continuation URLs are never accepted from the model. The service must retain the exact
      // original resource path, origin and HTTPS; only an opaque local handle reaches the model.
      let next =
        object["@odata.nextLink"]?.string ?? (service == .readwise ? object["next"]?.string : nil)
      object.removeValue(forKey: "@odata.nextLink")
      if service == .readwise { object.removeValue(forKey: "next") }
      if let next, let url = URL(string: next), ConnectorHTTP.isAllowed(url, hosts: [host]),
        url.path == request.url?.path, request.httpMethod == nil || request.httpMethod == "GET"
      {
        let key = UUID().uuidString
        nextPages[key] = (service, url)
        object["next_page_cursor"] = .string(key)
      } else if next != nil {
        object["pagination_notice"] = .string(
          "The service returned an unsupported continuation; narrow the search.")
      }
      value = .object(object)
    }
    value = Self.sanitized(value)
    var sources = ConnectorMCP.sources(value, service: service)
    if service == .todoist {
      let tasks = value["results"].array ?? (value["content"].string == nil ? [] : [value])
      sources += tasks.compactMap { task in
        guard let id = task["id"].string, GoogleWire.validID(id), let title = task["content"].string
        else { return nil }
        return WebSource(
          title: GoogleWire.bounded(title, bytes: 300),
          url: "https://app.todoist.com/app/task/" + id)
      }
    }
    return .init(value: value, sources: sources)
  }
  static func sanitized(_ value: ConnectorJSON) -> ConnectorJSON {
    if let object = value.object {
      return .object(
        object.filter {
          !$0.key.lowercased().contains("downloadurl")
            && !["access_token", "refresh_token", "client_secret"].contains($0.key.lowercased())
        }.mapValues(sanitized))
    }
    if let array = value.array { return .array(array.map(sanitized)) }
    return value
  }
  static func verify(
    _ service: ConnectorID, token: String, transport: any ConnectorTransport = ConnectorHTTP()
  ) async throws -> String {
    guard !token.isEmpty, token.utf8.count <= 16_384,
      !token.contains(where: { $0.isWhitespace || $0.isNewline })
    else { throw ConnectorError.invalidArguments }
    if service.mcpURL != nil {
      let tools = try await ConnectorMCP(service: service, token: token, transport: transport)
        .tools()
      guard !tools.isEmpty else { throw ConnectorError.denied }
      return "Connected · \(tools.count) available tools"
    }
    let endpoint: String
    switch service {
    case .todoist: endpoint = "https://api.todoist.com/api/v1/user"
    case .readwise: endpoint = "https://readwise.io/api/v2/auth/"
    case .airtable: endpoint = "https://api.airtable.com/v0/meta/whoami"
    case .clickup: endpoint = "https://api.clickup.com/api/v2/user"
    case .raindrop: endpoint = "https://api.raindrop.io/rest/v1/user"
    case .dropbox: endpoint = "https://api.dropboxapi.com/2/users/get_current_account"
    default:
      guard service.isMicrosoft else { throw ConnectorError.configuration }
      endpoint = "https://graph.microsoft.com/v1.0/me"
    }
    let url = URL(string: endpoint)!
    var request = URLRequest(url: url)
    request.setValue(
      ConnectorRESTOperation.authorization(service, token: token),
      forHTTPHeaderField: "Authorization")
    if service == .dropbox { request.httpMethod = "POST" }
    let response = try await transport.send(
      request, allowedHosts: [url.host!], maximumBytes: 64_000, rpcID: nil)
    let data = try response.requireSuccess()
    if data.isEmpty { return "Connected account" }
    let value = try ConnectorJSON.decode(data)
    return GoogleWire.bounded(
      value["email"].string ?? value["userPrincipalName"].string ?? value["displayName"].string
        ?? value["user"]["email"].string ?? "Connected account", bytes: 300)
  }
  private static func nextPageTool(_ service: ConnectorID) -> ConnectorTool {
    .init(
      service: service, name: "next_page",
      description:
        "Read the next page using next_page_cursor from a previous result in this request. Never pass a URL.",
      inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["cursor": .object(["type": .string("string")])]),
        "required": .array([.string("cursor")]), "additionalProperties": .bool(false),
      ]), needsApproval: false)
  }
  private static var dropboxTools: [ConnectorTool] {
    func tool(
      _ name: String, _ description: String, _ fields: [String: String], _ required: [String]
    ) -> ConnectorTool {
      .init(
        service: .dropbox, name: name, description: description,
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object(
            fields.mapValues { .object(["type": .string("string"), "description": .string($0)]) }),
          "required": .array(required.map(ConnectorJSON.string)),
          "additionalProperties": .bool(false),
        ]), needsApproval: false)
    }
    return [
      tool(
        "search",
        "Search Dropbox files by phrase. Returns metadata; follow cursor using search_continue.",
        ["query": "Short search phrase"], ["query"]),
      tool(
        "search_continue", "Read next Dropbox search page.", ["cursor": "Search result cursor"],
        ["cursor"]),
      tool(
        "list_folder",
        "List folder contents, empty path for root. Follow cursor using list_continue when has_more.",
        ["path": "Folder path or empty string"], ["path"]),
      tool(
        "list_continue", "Read next folder page.", ["cursor": "Folder result cursor"], ["cursor"]),
      tool(
        "read_file",
        "Read selected text/Markdown/CSV/JSON/log or selectable PDF text (file up to 2MB, text up to 30KB, PDF up to 20 pages). No OCR or Office parsing.",
        ["path": "Exact file path ending .txt, .md, .csv, .json, .log or .pdf"], ["path"]),
    ]
  }
  private func oneDriveFile(_ request: URLRequest) async throws -> ConnectorResult {
    let metadataResponse = try await transport.send(
      request, allowedHosts: ["graph.microsoft.com"], maximumBytes: 64_000, rpcID: nil)
    let item = try ConnectorJSON.decode(metadataResponse.requireSuccess())
    guard let name = item["name"].string, let size = item["size"].number, size >= 0,
      size <= 2_000_000,
      ["txt", "md", "csv", "json", "log", "pdf"].contains(
        (name as NSString).pathExtension.lowercased()),
      let address = item["@microsoft.graph.downloadUrl"].string, let url = URL(string: address),
      let host = ConnectorFileText.microsoftDownloadHost(url)
    else { throw ConnectorError.invalidArguments }
    try await validate()
    // Signed URL comes only from authenticated Graph metadata and never reaches the model,
    // source receipt or logs. The unsigned download has no bearer token and no redirects.
    let response = try await transport.send(
      URLRequest(url: url), allowedHosts: [host], maximumBytes: 2_000_000, rpcID: nil)
    return .init(
      value: try ConnectorFileText.extract(response.requireSuccess(), name: name),
      sources: ConnectorMCP.sources(Self.sanitized(item), service: .oneDrive))
  }

  private func dropbox(_ name: String, arguments: ConnectorJSON, token: String) async throws
    -> ConnectorResult
  {
    let route: String
    var body = arguments
    var host = "api.dropboxapi.com"
    switch name {
    case "search":
      route = "files/search_v2"
      body = .object([
        "query": arguments["query"], "options": .object(["max_results": .number(50)]),
      ])
    case "search_continue": route = "files/search/continue_v2"
    case "list_folder":
      route = "files/list_folder"
      body = .object(["path": arguments["path"], "limit": .number(50)])
    case "list_continue": route = "files/list_folder/continue"
    case "read_file":
      guard let path = arguments["path"].string,
        ["txt", "md", "csv", "json", "log", "pdf"].contains(
          (path as NSString).pathExtension.lowercased())
      else { throw ConnectorError.invalidArguments }
      route = "files/download"
      host = "content.dropboxapi.com"
    default: throw ConnectorError.invalidArguments
    }
    var request = URLRequest(url: URL(string: "https://" + host + "/2/" + route)!)
    request.httpMethod = "POST"
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    if name == "read_file" {
      request.setValue(ConnectorFileText.asciiHeader(body), forHTTPHeaderField: "Dropbox-API-Arg")
    } else {
      request.httpBody = try JSONEncoder().encode(body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let response = try await transport.send(
      request, allowedHosts: [host], maximumBytes: 2_000_000,
      rpcID: nil)
    let data = try response.requireSuccess()
    if name == "read_file" {
      return .init(value: try ConnectorFileText.extract(data, name: arguments["path"].string ?? ""))
    }
    return .init(value: try ConnectorJSON.decode(data))
  }
}

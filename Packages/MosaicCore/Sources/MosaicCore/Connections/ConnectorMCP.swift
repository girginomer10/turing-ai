import Foundation

actor ConnectorMCP {
  let service: ConnectorID
  private let token: String
  private let transport: any ConnectorTransport
  private var sessionID: String?
  private var version = "2025-06-18"
  private var initialized = false
  init(service: ConnectorID, token: String, transport: any ConnectorTransport = ConnectorHTTP()) {
    self.service = service
    self.token = token
    self.transport = transport
  }
  func tools() async throws -> [ConnectorTool] {
    try await initialize()
    var tools: [ConnectorTool] = []
    var cursor: String?
    var seen = Set<String>()
    repeat {
      let result = try await rpc(
        "tools/list", params: .object(cursor.map { ["cursor": .string($0)] } ?? [:]))
      guard let values = result["tools"].array else { throw ConnectorError.invalidResponse }
      for value in values {
        guard let name = value["name"].string, !name.isEmpty, name.utf8.count <= 256,
          value["inputSchema"].object != nil, value["inputSchema"].encoded.utf8.count <= 32_768,
          !tools.contains(where: { $0.name == name })
        else { throw ConnectorError.invalidResponse }
        tools.append(
          .init(
            service: service, name: name,
            description: GoogleWire.bounded(value["description"].string ?? name, bytes: 1600),
            inputSchema: value["inputSchema"],
            needsApproval: !Self.isKnownRead(service: service, name: name)))
      }
      guard tools.count <= 500 else { throw ConnectorError.tooLarge }
      cursor = result["nextCursor"].string
      if let cursor {
        guard cursor.count <= 4096, seen.insert(cursor).inserted, seen.count < 20 else {
          throw ConnectorError.tooLarge
        }
      }
    } while cursor != nil
    return tools
  }
  func call(_ name: String, arguments: ConnectorJSON) async throws -> ConnectorResult {
    try await initialize()
    let value = try await rpc(
      "tools/call", params: .object(["name": .string(name), "arguments": arguments]))
    // Preserve structured errors as evidence. Never retry a write after an uncertain response.
    return ConnectorResult(value: value, sources: Self.sources(value, service: service))
  }
  private func initialize() async throws {
    guard !initialized else { return }
    let result = try await rpc(
      "initialize",
      params: .object([
        "protocolVersion": .string(version), "capabilities": .object([:]),
        "clientInfo": .object(["name": .string("Turing AI"), "version": .string("0.1.0")]),
      ]))
    guard let negotiated = result["protocolVersion"].string,
      ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(negotiated)
    else { throw ConnectorError.invalidResponse }
    version = negotiated
    _ = try await rpc("notifications/initialized", params: .object([:]), notification: true)
    initialized = true
  }
  private func rpc(_ method: String, params: ConnectorJSON, notification: Bool = false) async throws
    -> ConnectorJSON
  {
    guard let address = service.mcpURL, let url = URL(string: address), let host = url.host else {
      throw ConnectorError.configuration
    }
    let id = UUID().uuidString
    var payload: [String: ConnectorJSON] = [
      "jsonrpc": .string("2.0"), "method": .string(method), "params": params,
    ]
    if !notification { payload["id"] = .string(id) }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(ConnectorJSON.object(payload))
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    if method != "initialize" {
      request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
    }
    if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
    let response = try await transport.send(
      request, allowedHosts: [host], maximumBytes: 2_000_000, rpcID: notification ? nil : id)
    let data = try response.requireSuccess()
    if let session = response.headers["mcp-session-id"] {
      guard session.utf8.count <= 1024,
        session.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e })
      else { throw ConnectorError.invalidResponse }
      sessionID = session
    }
    if notification { return .null }
    let value = try ConnectorJSON.decode(data)
    guard value["jsonrpc"].string == "2.0", value["id"].string == id else {
      throw ConnectorError.invalidResponse
    }
    guard value["error"] == .null, value.object?["result"] != nil else {
      throw ConnectorError.remoteFailure
    }
    return value["result"]
  }
  static func isKnownRead(service: ConnectorID, name: String) -> Bool {
    // Exact app-maintained names; neither server annotations nor a prefix can authorize new tools.
    let names: Set<String> =
      switch service {
      case .linear:
        [
          "get_user", "list_users", "get_issue", "list_issues", "get_project", "list_projects",
          "list_teams", "get_team", "list_comments", "list_cycles", "get_document",
          "list_documents", "search_documentation", "list_issue_statuses", "list_issue_labels",
        ]
      case .notion:
        [
          "notion-search", "notion-fetch", "notion-get-users", "notion-get-user", "notion-get-self",
          "notion-get-comments", "notion-get-teams",
        ]
      case .github:
        [
          "get_me", "search_repositories", "search_code", "search_issues", "search_pull_requests",
          "search_users", "get_file_contents", "list_commits", "get_commit", "list_branches",
          "list_issues", "issue_read", "pull_request_read", "list_pull_requests",
          "get_latest_release", "list_releases", "get_tag", "list_tags",
        ]
      case .atlassian:
        [
          "getAccessibleAtlassianResources", "atlassianUserInfo", "search", "fetch", "getJiraIssue",
          "searchJiraIssuesUsingJql", "getConfluencePage", "getConfluenceSpaces",
          "getPagesInConfluenceSpace", "searchConfluenceUsingCql",
          "getJiraProjectIssueTypesMetadata", "getVisibleJiraProjects",
        ]
      default: []  // Cloudflare Code Mode can execute arbitrary service operations: always review.
      }
    return names.contains(name)
  }
  static func sources(_ value: ConnectorJSON, service: ConnectorID) -> [WebSource] {
    var result: [WebSource] = []
    func visit(_ value: ConnectorJSON, depth: Int) {
      guard depth < 12, result.count < 50 else { return }
      if let object = value.object {
        for key in [
          "url", "webUrl", "webLink", "htmlLink", "html_url", "source_url", "link", "uri",
        ] {
          if let address = object[key]?.string, let url = URL(string: address),
            ["https", "http"].contains(url.scheme), url.user == nil, url.password == nil,
            url.host != nil, address.utf8.count <= 2048,
            !result.contains(where: { $0.url == address })
          {
            result.append(
              .init(
                title: GoogleWire.bounded(
                  object["title"]?.string ?? object["name"]?.string ?? service.title, bytes: 300),
                url: address))
          }
        }
        for child in object.values { visit(child, depth: depth + 1) }
      } else if let array = value.array {
        for child in array.prefix(200) { visit(child, depth: depth + 1) }
      } else if let string = value.string, string.utf8.count < 500_000,
        let decoded = try? ConnectorJSON.decode(Data(string.utf8)), decoded != value
      {
        visit(decoded, depth: depth + 1)
      }
    }
    visit(value, depth: 0)
    return result
  }
}

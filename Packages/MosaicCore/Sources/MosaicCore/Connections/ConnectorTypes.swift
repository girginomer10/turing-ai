import Foundation

/// Stable identifiers are device settings, never credentials. Google mail/Drive retain their
/// existing account-bound settings so an upgrade cannot silently grant new access.
enum ConnectorID: String, CaseIterable, Codable, Identifiable, Sendable {
  case todoist, linear, notion, atlassian, cloudflare, github
  case googleCalendar, googleTasks
  case outlookMail, outlookCalendar, outlookContacts, microsoftToDo, oneDrive, dropbox
  case readwise, airtable, clickup, raindrop
  case appleCalendar, appleReminders, appleContacts
  var id: String { rawValue }
  var title: String {
    switch self {
    case .todoist: "Todoist"
    case .linear: "Linear"
    case .notion: "Notion"
    case .atlassian: "Jira & Confluence"
    case .cloudflare: "Cloudflare"
    case .github: "GitHub"
    case .googleCalendar: "Google Calendar"
    case .googleTasks: "Google Tasks"
    case .outlookMail: "Outlook Mail"
    case .outlookCalendar: "Outlook Calendar"
    case .outlookContacts: "Outlook Contacts"
    case .microsoftToDo: "Microsoft To Do"
    case .oneDrive: "OneDrive"
    case .dropbox: "Dropbox"
    case .readwise: "Readwise"
    case .airtable: "Airtable"
    case .clickup: "ClickUp"
    case .raindrop: "Raindrop.io"
    case .appleCalendar: "Apple Calendar"
    case .appleReminders: "Apple Reminders"
    case .appleContacts: "Apple Contacts"
    }
  }
  var symbol: String {
    switch self {
    case .appleCalendar, .googleCalendar, .outlookCalendar: "calendar"
    case .appleReminders, .todoist, .googleTasks, .microsoftToDo: "checklist"
    case .appleContacts, .outlookContacts: "person.crop.rectangle"
    case .outlookMail: "envelope"
    case .dropbox, .oneDrive: "externaldrive"
    case .github: "chevron.left.forwardslash.chevron.right"
    case .cloudflare: "cloud"
    case .readwise, .raindrop: "bookmark"
    case .airtable: "tablecells"
    default: "square.stack.3d.up"
    }
  }
  var isApple: Bool { [.appleCalendar, .appleReminders, .appleContacts].contains(self) }
  var isMicrosoft: Bool {
    [.outlookMail, .outlookCalendar, .outlookContacts, .microsoftToDo, .oneDrive].contains(self)
  }
  var googleService: GoogleService? {
    switch self {
    case .googleCalendar: .calendar
    case .googleTasks: .tasks
    default: nil
    }
  }
  var credentialKey: String { isMicrosoft ? "microsoft" : rawValue }
  var mcpURL: String? {
    switch self {
    case .linear: "https://mcp.linear.app/mcp"
    case .notion: "https://mcp.notion.com/mcp"
    case .atlassian: "https://mcp.atlassian.com/v2/mcp"
    case .cloudflare: "https://mcp.cloudflare.com/mcp"
    case .github: "https://api.githubcopilot.com/mcp/"
    default: nil  // Todoist uses its public API with a personal token; no HTTPS callback needed.
    }
  }
  var supportsToken: Bool {
    !isApple && !isMicrosoft && googleService == nil && self != .notion && self != .dropbox
  }
  var supportsOAuth: Bool {
    [.linear, .notion, .atlassian, .cloudflare, .dropbox].contains(self) || isMicrosoft
  }
  var helpURL: URL {
    let address =
      switch self {
      case .todoist: "https://app.todoist.com/app/settings/integrations/developer"
      case .linear: "https://linear.app/settings/api"
      case .notion: "https://developers.notion.com/guides/mcp/build-mcp-client"
      case .atlassian: "https://id.atlassian.com/manage-profile/security/api-tokens"
      case .cloudflare: "https://dash.cloudflare.com/profile/api-tokens"
      case .github: "https://github.com/settings/personal-access-tokens"
      case .readwise: "https://readwise.io/access_token"
      case .airtable: "https://airtable.com/create/tokens"
      case .clickup: "https://developer.clickup.com/docs/authentication"
      case .raindrop: "https://app.raindrop.io/settings/integrations"
      case .dropbox: "https://www.dropbox.com/developers/apps"
      default: "https://entra.microsoft.com/"
      }
    return URL(string: address)!
  }
}

indirect enum ConnectorJSON: Codable, Sendable, Hashable {
  case object([String: ConnectorJSON])
  case array([ConnectorJSON])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  init(from decoder: any Decoder) throws {
    let box = try decoder.singleValueContainer()
    if box.decodeNil() {
      self = .null
    } else if let v = try? box.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? box.decode(String.self) {
      self = .string(v)
    } else if let v = try? box.decode(Double.self), v.isFinite {
      self = .number(v)
    } else if let v = try? box.decode([String: Self].self) {
      self = .object(v)
    } else {
      self = .array(try box.decode([Self].self))
    }
  }
  func encode(to encoder: any Encoder) throws {
    var box = encoder.singleValueContainer()
    switch self {
    case .object(let v): try box.encode(v)
    case .array(let v): try box.encode(v)
    case .string(let v): try box.encode(v)
    case .number(let v): try box.encode(v)
    case .bool(let v): try box.encode(v)
    case .null: try box.encodeNil()
    }
  }
  subscript(_ key: String) -> Self { object?[key] ?? .null }
  var object: [String: Self]? { if case .object(let v) = self { v } else { nil } }
  var array: [Self]? { if case .array(let v) = self { v } else { nil } }
  var string: String? { if case .string(let v) = self { v } else { nil } }
  var number: Double? { if case .number(let v) = self { v } else { nil } }
  var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
  var encoded: String {
    String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self)
  }
  static func decode(_ data: Data) throws -> Self {
    try JSONDecoder().decode(Self.self, from: data)
  }
}

struct ConnectorTool: Sendable, Identifiable, Codable {
  let service: ConnectorID
  let name: String
  let description: String
  let inputSchema: ConnectorJSON
  /// Only app-owned descriptors can mark a tool safe. Remote annotations are not authority.
  var needsApproval: Bool = true
  var id: String { service.rawValue + ":" + name }
}
struct ConnectorToolCall: Codable, Sendable, Equatable {
  let tool: String
  let arguments: ConnectorJSON
}
struct ConnectorResult: Sendable {
  let value: ConnectorJSON
  var sources: [WebSource] = []
}

enum ConnectorError: Error, LocalizedError, Equatable {
  case disconnected, changed, invalidResponse, invalidArguments, tooLarge, denied, configuration
  case http(Int)
  case remoteFailure
  var errorDescription: String? {
    switch self {
    case .disconnected: "Connect this account in Settings → Connections first."
    case .changed: "Connection access changed during this request. Please try again."
    case .invalidResponse:
      "The service returned an unsupported response. Please reconnect or try again."
    case .invalidArguments:
      "The model could not prepare a valid connection request. Try a more specific request."
    case .tooLarge: "The result exceeds the reading budget. Narrow the search or date range."
    case .denied: "Access was not granted. You can change the permission in Settings."
    case .configuration:
      "This sign-in needs a public client ID or an approved callback address. Open Connection setup."
    case .http(let code):
      "The service returned HTTP \(code). Check account permissions and try again."
    case .remoteFailure:
      "The service could not complete this action. Check the result before retrying a change."
    }
  }
}

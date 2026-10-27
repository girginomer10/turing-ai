import CryptoKit
import Foundation

public enum GoogleService: String, CaseIterable, Codable, Identifiable, Sendable {
  case gmail, drive, calendar, tasks
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .gmail: "Gmail"
    case .drive: "Google Drive"
    case .calendar: "Google Calendar"
    case .tasks: "Google Tasks"
    }
  }
  public var symbol: String {
    switch self {
    case .gmail: "envelope"
    case .drive: "externaldrive"
    case .calendar: "calendar"
    case .tasks: "checklist"
    }
  }
  var scope: String {
    switch self {
    case .gmail: "https://www.googleapis.com/auth/gmail.readonly"
    case .drive: "https://www.googleapis.com/auth/drive.readonly"
    case .calendar: "https://www.googleapis.com/auth/calendar.readonly"
    case .tasks: "https://www.googleapis.com/auth/tasks.readonly"
    }
  }
}

struct GoogleAccount: Codable, Equatable, Sendable {
  let subject: String
  let email: String
  let scopes: Set<String>
  func supports(_ service: GoogleService) -> Bool { scopes.contains(service.scope) }
}

struct GoogleCredential: Codable, Sendable {
  var account: GoogleAccount
  var accessToken: String
  var refreshToken: String
  var expiresAt: Date
  let clientID: String
}

struct GoogleOAuthConfiguration: Sendable {
  let clientID: String
  var callbackScheme: String { clientID.split(separator: ".").reversed().joined(separator: ".") }
  var redirectURI: String { callbackScheme + ":/oauthredirect" }
  var isValid: Bool {
    clientID.hasSuffix(".apps.googleusercontent.com")
      && clientID.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
      && clientID.count < 256
  }
  static var bundled: Self {
    Self(
      clientID: Bundle.main.object(forInfoDictionaryKey: "TuringGoogleClientID") as? String ?? "")
  }
}

struct GoogleOAuthAttempt: Sendable {
  let configuration: GoogleOAuthConfiguration
  let state: String
  let verifier: String
  let services: Set<GoogleService>
  var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded }

  func authorizationURL() throws -> URL {
    guard configuration.isValid, !services.isEmpty else {
      throw GoogleConnectionError.notConfigured
    }
    var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    url.queryItems = [
      .init(name: "client_id", value: configuration.clientID),
      .init(name: "redirect_uri", value: configuration.redirectURI),
      .init(name: "response_type", value: "code"),
      .init(
        name: "scope",
        value: (["openid", "email"] + services.map(\.scope).sorted()).joined(separator: " ")),
      .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
      .init(name: "code_challenge_method", value: "S256"),
      .init(name: "access_type", value: "offline"),
      .init(name: "prompt", value: "consent select_account"),
    ]
    return url.url!
  }

  func authorizationCode(from url: URL) throws -> String {
    guard url.scheme == configuration.callbackScheme, url.host == nil,
      url.path == "/oauthredirect", url.fragment == nil,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { throw GoogleConnectionError.invalidCallback }
    let items = components.queryItems ?? []
    func unique(_ name: String) -> String? {
      let matches = items.filter { $0.name == name }
      return matches.count == 1 ? matches[0].value : nil
    }
    guard unique("state") == state else { throw GoogleConnectionError.invalidCallback }
    guard !items.contains(where: { $0.name == "error" }), let code = unique("code"),
      !code.isEmpty, code.utf8.count <= 4096
    else { throw GoogleConnectionError.authorizationDenied }
    return code
  }
}

extension Data {
  fileprivate var base64URLEncoded: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  static func googleBase64URL(_ value: String) -> Data? {
    let text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    return Data(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4))
  }
}

struct ConnectedGoogleSource: Sendable, Equatable {
  let service: GoogleService
  let id: String
  let title: String
  let url: String
  let text: String
  var hasMoreResults = false
  var citation: WebSource { WebSource(title: "\(service.title): \(title)", url: url) }
}

enum GoogleConnectionError: Error, LocalizedError, Equatable {
  case notConfigured, invalidCallback, authorizationDenied, disconnected, accountChanged
  case invalidResponse, oversizedResponse, unsupportedFile, scopeMissing, invalidQuery
  case http(Int)
  var errorDescription: String? {
    switch self {
    case .notConfigured: "Google connections are not configured in this build yet."
    case .invalidCallback: "Google sign-in could not be verified. Please try again."
    case .authorizationDenied: "Google access was not granted. You can try connecting again."
    case .disconnected: "Connect your Google account in Settings → Connections, then try again."
    case .accountChanged: "The Google connection changed during this request. Please try again."
    case .invalidResponse: "Google returned an unreadable response. Please try again."
    case .oversizedResponse:
      "This Google item is too large to read in a chat. Choose a smaller file or message."
    case .unsupportedFile:
      "This file format cannot be read here yet. Open the source in Google Drive."
    case .scopeMissing:
      "Google did not grant access to this service. Reconnect and enable the required permission."
    case .invalidQuery:
      "The model could not prepare a valid Google search. Try a more specific request."
    case .http(let status):
      "Google request failed (HTTP \(status)). Check your connection and account permissions."
    }
  }
}

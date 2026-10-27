import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftUI

struct ConnectorOAuthAttempt: Sendable {
  let service: ConnectorID
  let clientID: String
  let authorizationEndpoint: String
  let tokenEndpoint: String
  let redirect: String
  let scope: String
  let resource: String?
  let state: String
  let verifier: String
  var challenge: String {
    Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
  func authorizationURL() throws -> URL {
    guard var url = URLComponents(string: authorizationEndpoint) else {
      throw ConnectorError.configuration
    }
    var values = [
      "response_type": "code", "client_id": clientID, "redirect_uri": redirect,
      "state": state, "code_challenge": challenge, "code_challenge_method": "S256",
    ]
    if !scope.isEmpty { values["scope"] = scope }
    if let resource { values["resource"] = resource }
    if service == .dropbox { values["token_access_type"] = "offline" }
    if service.isMicrosoft { values["prompt"] = "select_account" }
    url.queryItems = values.sorted(by: { $0.key < $1.key }).map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    guard let result = url.url else { throw ConnectorError.configuration }
    return result
  }
  func code(from callback: URL) throws -> String {
    guard let expected = URLComponents(string: redirect),
      let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
      actual.scheme == expected.scheme, actual.host == expected.host, actual.port == expected.port,
      actual.path == expected.path, actual.user == nil, actual.password == nil,
      actual.fragment == nil
    else { throw ConnectorError.denied }
    let items = actual.queryItems ?? []
    guard items.filter({ $0.name == "state" }).count == 1,
      items.first(where: { $0.name == "state" })?.value == state,
      !items.contains(where: { $0.name == "error" }),
      items.filter({ $0.name == "code" }).count == 1,
      let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty,
      code.utf8.count <= 4096
    else { throw ConnectorError.denied }
    return code
  }
}

enum ConnectorOAuth {
  static func allowedHosts(_ service: ConnectorID) -> Set<String> {
    if service.isMicrosoft { return ["login.microsoftonline.com"] }
    return switch service {
    case .linear: ["mcp.linear.app", "linear.app", "api.linear.app"]
    case .notion: ["mcp.notion.com", "api.notion.com"]
    case .atlassian: ["mcp.atlassian.com", "auth.atlassian.com"]
    case .cloudflare: ["mcp.cloudflare.com"]
    case .dropbox: ["www.dropbox.com", "api.dropboxapi.com"]
    default: []
    }
  }
  static func random() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw ConnectorError.invalidResponse
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }
  static func prepare(
    _ service: ConnectorID, clientID supplied: String,
    transport: any ConnectorTransport = ConnectorHTTP()
  ) async throws -> ConnectorOAuthAttempt {
    let redirect = "com.omergirgin.turing:/oauth/" + service.credentialKey
    var clientID = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
    var authorization: String
    var token: String
    var scope = ""
    var resource: String?
    let hosts = allowedHosts(service)
    if service.isMicrosoft {
      guard !clientID.isEmpty, UUID(uuidString: clientID) != nil else {
        throw ConnectorError.configuration
      }
      authorization = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
      token = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
      scope =
        "offline_access User.Read Mail.Read Calendars.Read Contacts.Read Tasks.Read Files.Read"
    } else if service == .dropbox {
      guard !clientID.isEmpty, clientID.count <= 256 else { throw ConnectorError.configuration }
      authorization = "https://www.dropbox.com/oauth2/authorize"
      token = "https://api.dropboxapi.com/oauth2/token"
      scope = "account_info.read files.metadata.read files.content.read"
    } else {
      guard let address = service.mcpURL, let endpoint = URL(string: address),
        let host = endpoint.host
      else { throw ConnectorError.configuration }
      resource = address
      let origin = "https://" + host
      var issuer = origin
      // RFC 9728 path-specific metadata first; root metadata is the compatibility fallback.
      for path in [
        "/.well-known/oauth-protected-resource" + endpoint.path,
        "/.well-known/oauth-protected-resource",
      ] {
        let response = try await transport.send(
          URLRequest(url: URL(string: origin + path)!), allowedHosts: [host], maximumBytes: 32_768,
          rpcID: nil)
        if response.status == 200 {
          let metadata = try ConnectorJSON.decode(response.data)
          if let found = metadata["authorization_servers"].array?.first?.string {
            guard ConnectorHTTP.isAllowed(URL(string: found), hosts: hosts) else {
              throw ConnectorError.configuration
            }
            issuer = found
          }
          break
        }
      }
      guard let issuerURL = URL(string: issuer), let issuerHost = issuerURL.host else {
        throw ConnectorError.configuration
      }
      let metadataURL =
        "https://" + issuerHost + "/.well-known/oauth-authorization-server"
        + (issuerURL.path == "/" ? "" : issuerURL.path)
      let response = try await transport.send(
        URLRequest(url: URL(string: metadataURL)!), allowedHosts: hosts, maximumBytes: 32_768,
        rpcID: nil)
      let metadata = try ConnectorJSON.decode(response.requireSuccess())
      guard
        metadata["issuer"].string?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
          == issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
        let auth = metadata["authorization_endpoint"].string,
        let exchange = metadata["token_endpoint"].string,
        ConnectorHTTP.isAllowed(URL(string: auth), hosts: hosts),
        ConnectorHTTP.isAllowed(URL(string: exchange), hosts: hosts),
        metadata["code_challenge_methods_supported"].array?.contains(.string("S256")) != false
      else { throw ConnectorError.configuration }
      authorization = auth
      token = exchange
      if service == .linear { scope = "read write" }
      if clientID.isEmpty {
        guard let registration = metadata["registration_endpoint"].string,
          ConnectorHTTP.isAllowed(URL(string: registration), hosts: hosts)
        else { throw ConnectorError.configuration }
        var request = URLRequest(url: URL(string: registration)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
          ConnectorJSON.object([
            "client_name": .string("Turing AI"), "redirect_uris": .array([.string(redirect)]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string("none"),
          ]))
        let registrationResponse = try await transport.send(
          request, allowedHosts: hosts, maximumBytes: 32_768, rpcID: nil)
        let registered = try ConnectorJSON.decode(registrationResponse.requireSuccess())
        guard let id = registered["client_id"].string, !id.isEmpty, id.utf8.count <= 2048,
          registered["token_endpoint_auth_method"].string == nil
            || registered["token_endpoint_auth_method"].string == "none"
        else { throw ConnectorError.configuration }
        clientID = id
      }
    }
    return try .init(
      service: service, clientID: clientID, authorizationEndpoint: authorization,
      tokenEndpoint: token, redirect: redirect, scope: scope, resource: resource, state: random(),
      verifier: random())
  }
  static func exchange(
    _ attempt: ConnectorOAuthAttempt, callback: URL,
    transport: any ConnectorTransport = ConnectorHTTP()
  ) async throws -> ConnectorCredential {
    var fields = [
      "grant_type": "authorization_code", "code": try attempt.code(from: callback),
      "client_id": attempt.clientID, "redirect_uri": attempt.redirect,
      "code_verifier": attempt.verifier,
    ]
    if let resource = attempt.resource { fields["resource"] = resource }
    let response = try await transport.send(
      GoogleWire.post(attempt.tokenEndpoint, values: fields),
      allowedHosts: allowedHosts(attempt.service), maximumBytes: 32_768, rpcID: nil)
    return try credential(
      from: ConnectorJSON.decode(response.requireSuccess()),
      previous: .init(
        token: "",
        label: "Authorized account", clientID: attempt.clientID,
        tokenEndpoint: attempt.tokenEndpoint, resource: attempt.resource))
  }
  static func credential(from value: ConnectorJSON, previous: ConnectorCredential) throws
    -> ConnectorCredential
  {
    guard let access = value["access_token"].string, !access.isEmpty, access.utf8.count <= 16_384,
      !access.contains(where: { $0.isNewline }),
      value["token_type"].string?.lowercased() == "bearer"
    else { throw ConnectorError.invalidResponse }
    var result = previous
    result.token = access
    if let refresh = value["refresh_token"].string {
      guard !refresh.isEmpty, refresh.utf8.count <= 16_384 else {
        throw ConnectorError.invalidResponse
      }
      result.refreshToken = refresh
    }
    if let seconds = value["expires_in"].number {
      guard seconds.isFinite, seconds > 0 else { throw ConnectorError.invalidResponse }
      result.expiresAt = Date().addingTimeInterval(min(seconds, 31_536_000))
    } else {
      result.expiresAt = nil
    }
    return result
  }
}

@MainActor @Observable
final class ConnectorSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
  var busy = false
  var error: String?
  private var task: Task<Void, Never>?
  private var session: ASWebAuthenticationSession?
  private var continuation: CheckedContinuation<URL, Error>?
  func connect(
    _ service: ConnectorID, clientID: String, completed: @escaping @MainActor () async -> Void
  ) {
    guard !busy else { return }
    busy = true
    error = nil
    task = Task { @MainActor in
      let operation = await ConnectorStore.shared.begin(service)
      defer {
        busy = false
        session = nil
        task = nil
      }
      do {
        let attempt = try await ConnectorOAuth.prepare(service, clientID: clientID)
        try Task.checkCancellation()
        let url = try attempt.authorizationURL()
        let callback = try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (pending: CheckedContinuation<URL, Error>) in
            continuation = pending
            let auth = ASWebAuthenticationSession(
              url: url, callbackURLScheme: "com.omergirgin.turing"
            ) { [weak self] url, _ in
              Task { @MainActor in self?.finish(url) }
            }
            auth.presentationContextProvider = self
            session = auth
            if !auth.start() { finish(nil) }
          }
        } onCancel: {
          Task { @MainActor [weak self] in self?.finish(nil) }
        }
        try Task.checkCancellation()
        var credential = try await ConnectorOAuth.exchange(attempt, callback: callback)
        credential.label = try await ConnectorExecutor.verify(service, token: credential.token)
        try await ConnectorStore.shared.save(credential, service: service, attempt: operation)
        await completed()
      } catch {
        await ConnectorStore.shared.cancel(service, attempt: operation)
        if !Task.isCancelled {
          self.error =
            (error as? ConnectorError)?.localizedDescription
            ?? "Sign-in did not finish. Please try again."
        }
      }
    }
  }
  private func finish(_ url: URL?) {
    guard let continuation else { return }
    self.continuation = nil
    if let url {
      continuation.resume(returning: url)
    } else {
      continuation.resume(throwing: ConnectorError.denied)
    }
  }
  func cancel() {
    task?.cancel()
    session?.cancel()
    finish(nil)
  }
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    #if os(iOS)
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    #else
      NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    #endif
  }
}

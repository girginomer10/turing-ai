import Foundation
import Security

protocol GoogleCredentialVault: Sendable {
  func load() throws -> GoogleCredential?
  func save(_ value: GoogleCredential) throws
  func clear() throws
}

/// Synchronous Keychain writes deliberately remain inside GoogleConnectionStore's actor turn.
/// An async vault write could otherwise resume after Disconnect and resurrect an old token.
struct GoogleKeychainVault: GoogleCredentialVault {
  private var query: [String: Any] {
    SecurityKeychainQueryBuilder.baseQuery(
      service: "com.omergirgin.turing.google-oauth",
      configurationID: UUID(uuidString: "BD519A0C-CBA0-4889-A3D9-4D0634C4200D")!,
      backend: .dataProtection)
  }
  func load() throws -> GoogleCredential? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw SecurityKeychainError.unexpectedStatus(status)
    }
    return try JSONDecoder().decode(GoogleCredential.self, from: data)
  }
  func save(_ value: GoogleCredential) throws {
    let data = try JSONEncoder().encode(value)
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      let item = SecurityKeychainQueryBuilder.newItem(
        from: query, data: data, backend: .dataProtection)
      let added = SecItemAdd(item as CFDictionary, nil)
      guard added == errSecSuccess else { throw SecurityKeychainError.unexpectedStatus(added) }
    } else if status != errSecSuccess {
      throw SecurityKeychainError.unexpectedStatus(status)
    }
  }
  func clear() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecurityKeychainError.unexpectedStatus(status)
    }
  }
}

struct GoogleConnectionLease: Sendable {
  let account: GoogleAccount
  let revision: UInt64
}

actor GoogleConnectionStore {
  static let shared = GoogleConnectionStore()
  private let vault: any GoogleCredentialVault
  private let transport: any GoogleHTTPTransport
  private var revision: UInt64 = 0
  private var refresh: (id: UUID, task: Task<GoogleCredential, Error>)?
  private var authorizationState: String?
  init(
    vault: any GoogleCredentialVault = GoogleKeychainVault(),
    transport: any GoogleHTTPTransport = GoogleHTTPClient()
  ) {
    self.vault = vault
    self.transport = transport
  }
  func account() async throws -> GoogleAccount? { try vault.load()?.account }
  func lease() async throws -> GoogleConnectionLease {
    let expected = revision
    guard let account = try vault.load()?.account else {
      throw GoogleConnectionError.disconnected
    }
    guard revision == expected else { throw GoogleConnectionError.accountChanged }
    return GoogleConnectionLease(account: account, revision: expected)
  }
  func validate(_ lease: GoogleConnectionLease) async throws {
    guard revision == lease.revision else { throw GoogleConnectionError.accountChanged }
    try await assertAccount(lease.account.subject)
    guard revision == lease.revision else { throw GoogleConnectionError.accountChanged }
  }

  func beginAuthorization(configuration: GoogleOAuthConfiguration, services: Set<GoogleService>)
    throws -> GoogleOAuthAttempt
  {
    func random() throws -> String {
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw GoogleConnectionError.invalidResponse
      }
      return bytes.map { String(format: "%02x", $0) }.joined()
    }
    let attempt = try GoogleOAuthAttempt(
      configuration: configuration, state: random(), verifier: random(), services: services)
    _ = try attempt.authorizationURL()
    revision &+= 1
    refresh?.task.cancel()
    refresh = nil
    authorizationState = attempt.state
    return attempt
  }

  func completeAuthorization(_ attempt: GoogleOAuthAttempt, callback: URL) async throws
    -> GoogleAccount
  {
    guard authorizationState == attempt.state else { throw GoogleConnectionError.invalidCallback }
    let code = try attempt.authorizationCode(from: callback)
    authorizationState = nil
    let expectedRevision = revision
    let request = GoogleWire.post(
      "https://oauth2.googleapis.com/token",
      values: [
        "client_id": attempt.configuration.clientID, "code": code,
        "redirect_uri": attempt.configuration.redirectURI, "code_verifier": attempt.verifier,
        "grant_type": "authorization_code",
      ])
    let token = try JSONDecoder().decode(
      GoogleTokenResponse.self, from: await transport.send(request, maximumBytes: 32_768))
    guard let refreshToken = token.refresh_token, !refreshToken.isEmpty,
      !token.access_token.isEmpty, token.expires_in > 0, token.expires_in.isFinite,
      token.token_type.lowercased() == "bearer"
    else { throw GoogleConnectionError.invalidResponse }
    // Identity is obtained from Google's authenticated endpoint, never from an unverified JWT.
    let user = try JSONDecoder().decode(
      GoogleUserInfo.self,
      from: await transport.send(
        GoogleWire.get(
          "https://openidconnect.googleapis.com/v1/userinfo", token: token.access_token),
        maximumBytes: 32_768))
    guard user.email_verified, !user.sub.isEmpty, !user.email.isEmpty else {
      throw GoogleConnectionError.invalidResponse
    }
    let returnedScopes = Set((token.scope ?? "").split(separator: " ").map(String.init))
    let requestedScopes = Set(attempt.services.map(\.scope)).union(["openid", "email"])
    let scopes = returnedScopes.intersection(requestedScopes)
    guard !attempt.services.filter({ scopes.contains($0.scope) }).isEmpty else {
      throw GoogleConnectionError.scopeMissing
    }
    let account = GoogleAccount(subject: user.sub, email: user.email, scopes: scopes)
    let credential = GoogleCredential(
      account: account, accessToken: token.access_token,
      refreshToken: refreshToken, expiresAt: .now.addingTimeInterval(min(token.expires_in, 86_400)),
      clientID: attempt.configuration.clientID)
    try Task.checkCancellation()
    guard revision == expectedRevision else { throw GoogleConnectionError.accountChanged }
    revision &+= 1
    refresh?.task.cancel()
    refresh = nil
    try vault.save(credential)
    return account
  }

  func disconnect() async throws {
    revision &+= 1
    authorizationState = nil
    refresh?.task.cancel()
    refresh = nil
    try vault.clear()
  }

  func token(for service: GoogleService, subject: String) async throws -> String {
    let expectedRevision = revision
    guard var credential = try vault.load() else { throw GoogleConnectionError.disconnected }
    guard credential.account.subject == subject else { throw GoogleConnectionError.accountChanged }
    guard credential.account.supports(service) else { throw GoogleConnectionError.scopeMissing }
    if credential.expiresAt <= .now.addingTimeInterval(60) {
      let pending: (id: UUID, task: Task<GoogleCredential, Error>)
      if let refresh {
        pending = refresh
      } else {
        let old = credential
        let transport = self.transport
        pending = (
          UUID(),
          Task {
            let request = GoogleWire.post(
              "https://oauth2.googleapis.com/token",
              values: [
                "client_id": old.clientID, "refresh_token": old.refreshToken,
                "grant_type": "refresh_token",
              ])
            let value = try JSONDecoder().decode(
              GoogleTokenResponse.self, from: await transport.send(request, maximumBytes: 32_768))
            guard !value.access_token.isEmpty, value.expires_in > 0, value.expires_in.isFinite,
              value.token_type.lowercased() == "bearer"
            else { throw GoogleConnectionError.invalidResponse }
            var updated = old
            updated.accessToken = value.access_token
            updated.refreshToken = value.refresh_token ?? old.refreshToken
            updated.expiresAt = .now.addingTimeInterval(min(value.expires_in, 86_400))
            if let scopes = value.scope {
              updated.account = GoogleAccount(
                subject: old.account.subject, email: old.account.email,
                scopes: Set(scopes.split(separator: " ").map(String.init)).intersection(
                  old.account.scopes))
            }
            return updated
          }
        )
        refresh = pending
      }
      do {
        credential = try await pending.task.value
        guard revision == expectedRevision else { throw GoogleConnectionError.accountChanged }
        if refresh?.id == pending.id {
          try vault.save(credential)
          refresh = nil
        }
      } catch {
        if refresh?.id == pending.id { refresh = nil }
        if error as? GoogleConnectionError == .http(400)
          || error as? GoogleConnectionError == .http(401)
        {
          throw GoogleConnectionError.disconnected
        }
        throw error
      }
    }
    try Task.checkCancellation()
    guard revision == expectedRevision else { throw GoogleConnectionError.accountChanged }
    guard credential.account.supports(service) else { throw GoogleConnectionError.scopeMissing }
    return credential.accessToken
  }

  func assertAccount(_ subject: String) async throws {
    guard try vault.load()?.account.subject == subject else {
      throw GoogleConnectionError.accountChanged
    }
  }
}

private struct GoogleTokenResponse: Decodable {
  let access_token: String
  let refresh_token: String?
  let expires_in: Double
  let token_type: String
  let scope: String?
}
private struct GoogleUserInfo: Decodable {
  let sub: String
  let email: String
  let email_verified: Bool
}

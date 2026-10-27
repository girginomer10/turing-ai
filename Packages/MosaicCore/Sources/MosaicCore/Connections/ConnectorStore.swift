import Foundation
import Security

struct ConnectorCredential: Codable, Sendable {
  var id = UUID()
  var token: String
  var label: String
  var refreshToken: String?
  var expiresAt: Date?
  var clientID: String?
  var tokenEndpoint: String?
  var resource: String?
}
protocol ConnectorVault: Sendable {
  func load(_ key: String) throws -> ConnectorCredential?
  func save(_ value: ConnectorCredential, key: String) throws
  func clear(_ key: String) throws
}
struct ConnectorKeychainVault: ConnectorVault {
  private func query(_ key: String) -> [String: Any] {
    SecurityKeychainQueryBuilder.baseQuery(
      service: "com.omergirgin.turing.connection." + key,
      configurationID: UUID(uuidString: "649ED01C-BFD6-4672-A008-1B4B201C78B1")!,
      backend: .dataProtection)
  }
  func load(_ key: String) throws -> ConnectorCredential? {
    var request = query(key)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw SecurityKeychainError.unexpectedStatus(status)
    }
    return try JSONDecoder().decode(ConnectorCredential.self, from: data)
  }
  func save(_ value: ConnectorCredential, key: String) throws {
    let data = try JSONEncoder().encode(value)
    let base = query(key)
    let status = SecItemUpdate(
      base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      let added = SecItemAdd(
        SecurityKeychainQueryBuilder.newItem(from: base, data: data, backend: .dataProtection)
          as CFDictionary, nil)
      guard added == errSecSuccess else { throw SecurityKeychainError.unexpectedStatus(added) }
    } else if status != errSecSuccess {
      throw SecurityKeychainError.unexpectedStatus(status)
    }
  }
  func clear(_ key: String) throws {
    let status = SecItemDelete(query(key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecurityKeychainError.unexpectedStatus(status)
    }
  }
}

actor ConnectorStore {
  static let shared = ConnectorStore()
  private let vault: any ConnectorVault
  private let transport: any ConnectorTransport
  private var attempts: [String: UUID] = [:]
  private var refreshing: [String: (id: UUID, task: Task<ConnectorCredential, Error>)] = [:]
  init(
    vault: any ConnectorVault = ConnectorKeychainVault(),
    transport: any ConnectorTransport = ConnectorHTTP()
  ) {
    self.vault = vault
    self.transport = transport
  }
  func credential(_ service: ConnectorID) throws -> ConnectorCredential? {
    try vault.load(service.credentialKey)
  }
  func begin(_ service: ConnectorID) -> UUID {
    let id = UUID()
    attempts[service.credentialKey] = id
    return id
  }
  func save(_ credential: ConnectorCredential, service: ConnectorID, attempt: UUID) throws {
    try Task.checkCancellation()
    guard attempts[service.credentialKey] == attempt else { throw ConnectorError.changed }
    refreshing.removeValue(forKey: service.credentialKey)?.task.cancel()
    try vault.save(credential, key: service.credentialKey)
    attempts.removeValue(forKey: service.credentialKey)
  }
  func cancel(_ service: ConnectorID, attempt: UUID) {
    if attempts[service.credentialKey] == attempt {
      attempts.removeValue(forKey: service.credentialKey)
    }
  }
  func disconnect(_ service: ConnectorID) throws {
    attempts.removeValue(forKey: service.credentialKey)
    refreshing.removeValue(forKey: service.credentialKey)?.task.cancel()
    try vault.clear(service.credentialKey)
  }
  func validate(_ service: ConnectorID, id: UUID) throws {
    try Task.checkCancellation()
    guard try vault.load(service.credentialKey)?.id == id else { throw ConnectorError.changed }
  }
  func token(_ service: ConnectorID, id: UUID) async throws -> String {
    try validate(service, id: id)
    guard let current = try vault.load(service.credentialKey) else {
      throw ConnectorError.disconnected
    }
    guard let expiry = current.expiresAt, expiry <= Date().addingTimeInterval(60) else {
      return current.token
    }
    let key = service.credentialKey
    let pending: (id: UUID, task: Task<ConnectorCredential, Error>)
    if let existing = refreshing[key] {
      pending = existing
    } else {
      let transport = self.transport
      pending = (
        UUID(),
        Task {
          guard let refresh = current.refreshToken, let clientID = current.clientID,
            let endpoint = current.tokenEndpoint,
            ConnectorHTTP.isAllowed(
              URL(string: endpoint), hosts: ConnectorOAuth.allowedHosts(service))
          else { throw ConnectorError.disconnected }
          var fields = [
            "grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID,
          ]
          if let resource = current.resource { fields["resource"] = resource }
          let response = try await transport.send(
            GoogleWire.post(endpoint, values: fields),
            allowedHosts: ConnectorOAuth.allowedHosts(service), maximumBytes: 32_768, rpcID: nil)
          let value = try ConnectorJSON.decode(response.requireSuccess())
          return try ConnectorOAuth.credential(from: value, previous: current)
        }
      )
      refreshing[key] = pending
    }
    do {
      let fresh = try await pending.task.value
      try validate(service, id: id)
      if refreshing[key]?.id == pending.id {
        try vault.save(fresh, key: key)
        refreshing.removeValue(forKey: key)
      }
      return fresh.token
    } catch {
      if refreshing[key]?.id == pending.id { refreshing.removeValue(forKey: key) }
      throw error
    }
  }
}

/// Device-only selections bind to a concrete connection generation. Reconnecting never silently
/// re-enables a different user's account. Defaults and per-chat overrides have identical semantics.
struct ConnectorSelection: Codable, Equatable, Sendable {
  var bindings: [ConnectorID: UUID] = [:]
  init(raw: String = "") {
    if let data = raw.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(Self.self, from: data)
    {
      self = decoded
    }
  }
  var raw: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
}

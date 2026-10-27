import Foundation
import Security

public protocol ProviderCredentialStoring: Sendable {
  func setAPIKey(
    _ apiKey: String,
    for configurationID: UUID,
    binding: ProviderCredentialBinding
  ) async throws
  func apiKey(
    for configurationID: UUID,
    expectedBinding: ProviderCredentialBinding
  ) async throws -> String?
  func removeAPIKey(for configurationID: UUID) async throws
}

public enum SecurityKeychainError: Error, Equatable, Sendable {
  case emptyAPIKey
  case bindingMismatch
  case invalidUTF8
  case legacyCredentialRequiresMigration
  case migrationVerificationFailed
  case unexpectedStatus(OSStatus)
}

/// Opaque rollback state for one Keychain item. Callers can retain and restore it without decoding
/// a credential or weakening destination-binding checks.
struct ProviderCredentialSnapshot: Sendable {
  fileprivate let data: Data?
}

extension SecurityKeychainError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .emptyAPIKey:
      "The API key cannot be empty."
    case .bindingMismatch:
      "The saved API key belongs to a different provider destination. Re-enter the key for this connection."
    case .invalidUTF8:
      "The stored API key is not valid UTF-8."
    case .legacyCredentialRequiresMigration:
      "This saved API key predates destination binding, and its endpoint cannot be verified. Re-enter it for this connection; the existing Keychain item was not removed."
    case .migrationVerificationFailed:
      "The saved API key could not be bound safely, so it was not used. Try again."
    case .unexpectedStatus(let status):
      SecCopyErrorMessageString(status, nil) as String?
        ?? "Keychain returned status \(status)."
    }
  }
}

/// The only persistence service that accepts or returns provider API keys.
/// SwiftData stores only `ProviderCredentialReference`; secret bytes stay in Keychain.
public actor SecurityKeychain: ProviderCredentialStoring {
  public static let shared = SecurityKeychain()

  public let service: String
  private let backend: SecurityKeychainBackend

  public init(service: String = "com.mosaic.ai.provider-credentials") {
    self.service = service
    self.backend = Self.defaultBackend()
  }

  public func setAPIKey(
    _ apiKey: String,
    for configurationID: UUID,
    binding: ProviderCredentialBinding
  ) async throws {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SecurityKeychainError.emptyAPIKey
    }

    let data = try ProviderCredentialEnvelope.encode(apiKey: apiKey, binding: binding)
    try store(data, for: configurationID)
  }

  func credentialSnapshot(for configurationID: UUID) async throws
    -> ProviderCredentialSnapshot
  {
    ProviderCredentialSnapshot(data: try storedData(for: configurationID))
  }

  func restoreCredentialSnapshot(
    _ snapshot: ProviderCredentialSnapshot,
    for configurationID: UUID
  ) async throws {
    if let data = snapshot.data {
      try store(data, for: configurationID)
    } else {
      try await removeAPIKey(for: configurationID)
    }
  }

  private func store(_ data: Data, for configurationID: UUID) throws {
    let query = baseQuery(for: configurationID)
    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )

    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      let item = SecurityKeychainQueryBuilder.newItem(
        from: query,
        data: data,
        backend: backend
      )

      let addStatus = SecItemAdd(item as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw SecurityKeychainError.unexpectedStatus(addStatus)
      }
    default:
      throw SecurityKeychainError.unexpectedStatus(updateStatus)
    }
  }

  public func apiKey(
    for configurationID: UUID,
    expectedBinding: ProviderCredentialBinding
  ) async throws -> String? {
    guard let data = try storedData(for: configurationID) else { return nil }
    return try ProviderCredentialEnvelope.decodeOrMigrate(
      data: data,
      expectedBinding: expectedBinding
    ) { migratedData in
      // `SecItemUpdate` replaces one Keychain item's value atomically. Actor isolation keeps the
      // read/write/readback sequence single-file within Mosaic, and the exact readback prevents
      // an unbound or concurrently replaced value from escaping to a network caller.
      try store(migratedData, for: configurationID)
      guard let verifiedData = try storedData(for: configurationID) else {
        throw SecurityKeychainError.migrationVerificationFailed
      }
      return verifiedData
    }
  }

  public func removeAPIKey(for configurationID: UUID) async throws {
    let status = SecItemDelete(baseQuery(for: configurationID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecurityKeychainError.unexpectedStatus(status)
    }
  }

  public nonisolated func credentialReference(
    for configurationID: UUID
  ) -> ProviderCredentialReference {
    ProviderCredentialReference(configurationID: configurationID)
  }

  private func baseQuery(for configurationID: UUID) -> [String: Any] {
    SecurityKeychainQueryBuilder.baseQuery(
      service: service,
      configurationID: configurationID,
      backend: backend
    )
  }

  private nonisolated static func defaultBackend() -> SecurityKeychainBackend {
    #if os(macOS)
      guard let task = SecTaskCreateFromSelf(nil) else {
        return .dataProtection
      }
      var entitlementError: Unmanaged<CFError>?
      let applicationIdentifier = SecTaskCopyValueForEntitlement(
        task,
        "com.apple.application-identifier" as CFString,
        &entitlementError
      )
      if let entitlementError {
        _ = entitlementError.takeRetainedValue()
        return .dataProtection
      }
      #if DEBUG && MOSAIC_LOCAL_ADHOC_KEYCHAIN
        let allowsLocalAdHocFallback = true
      #else
        let allowsLocalAdHocFallback = false
      #endif
      return SecurityKeychainBackend.macOS(
        applicationIdentifierIsPresent: applicationIdentifier != nil,
        entitlementLookupSucceeded: true,
        allowsLocalAdHocFallback: allowsLocalAdHocFallback
      )
    #else
      return .dataProtection
    #endif
  }

  private func storedData(for configurationID: UUID) throws -> Data? {
    var query = baseQuery(for: configurationID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else { throw SecurityKeychainError.invalidUTF8 }
      return data
    case errSecItemNotFound:
      return nil
    default:
      throw SecurityKeychainError.unexpectedStatus(status)
    }
  }
}

enum SecurityKeychainBackend: Equatable, Sendable {
  case dataProtection
  case localMacOSFileBased

  static func macOS(
    applicationIdentifierIsPresent: Bool,
    entitlementLookupSucceeded: Bool,
    allowsLocalAdHocFallback: Bool
  ) -> Self {
    guard
      entitlementLookupSucceeded,
      !applicationIdentifierIsPresent,
      allowsLocalAdHocFallback
    else {
      return .dataProtection
    }
    return .localMacOSFileBased
  }
}

enum SecurityKeychainQueryBuilder {
  static func baseQuery(
    service: String,
    configurationID: UUID,
    backend: SecurityKeychainBackend
  ) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: ProviderCredentialReference(
        configurationID: configurationID
      ).account,
    ]
    #if os(macOS)
      if backend == .dataProtection {
        query[kSecUseDataProtectionKeychain as String] = true
      }
    #endif
    return query
  }

  static func newItem(
    from baseQuery: [String: Any],
    data: Data,
    backend: SecurityKeychainBackend
  ) -> [String: Any] {
    var item = baseQuery
    item[kSecValueData as String] = data
    if backend == .dataProtection {
      item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }
    return item
  }
}

enum ProviderCredentialEnvelope {
  private static let prefix = Data("mosaic-provider-key-v1\0".utf8)

  static func encode(apiKey: String, binding: ProviderCredentialBinding) throws -> Data {
    let payload = Payload(apiKey: apiKey, binding: binding)
    var data = prefix
    data.append(try JSONEncoder().encode(payload))
    return data
  }

  static func decode(
    data: Data,
    expectedBinding: ProviderCredentialBinding
  ) throws -> String {
    switch try storedCredential(data: data) {
    case .legacy:
      // Raw credentials carry no destination proof. Only `decodeOrMigrate` may consume them, and
      // it persists and verifies a bound envelope before returning the key to its caller.
      throw SecurityKeychainError.legacyCredentialRequiresMigration
    case .bound(let payload):
      guard payload.binding == expectedBinding else {
        throw SecurityKeychainError.bindingMismatch
      }
      return payload.apiKey
    }
  }

  /// Resolves one Keychain read without ever returning an unbound legacy credential.
  ///
  /// `expectedBinding` must be the immutable snapshot built from the authoritative persisted
  /// provider configuration used by the request. A legacy value is upgraded once. The caller must
  /// atomically replace the Keychain value and return an exact readback; any failure closes access
  /// while retaining whichever credential bytes Keychain committed.
  static func decodeOrMigrate(
    data: Data,
    expectedBinding: ProviderCredentialBinding,
    persistMigration: (Data) throws -> Data
  ) throws -> String {
    switch try storedCredential(data: data) {
    case .bound:
      return try decode(data: data, expectedBinding: expectedBinding)
    case .legacy(let apiKey):
      guard isVerifiedLegacyPresetBinding(expectedBinding) else {
        // Legacy releases did not persist a binding alongside custom destinations. Guessing from
        // today's configuration could send an old key to a host or tenant path selected later.
        // Keep those bytes intact and require the user to bind a replacement explicitly.
        throw SecurityKeychainError.legacyCredentialRequiresMigration
      }
      let migratedData = try encode(apiKey: apiKey, binding: expectedBinding)
      let verifiedData = try persistMigration(migratedData)
      guard verifiedData == migratedData else {
        throw SecurityKeychainError.migrationVerificationFailed
      }
      return try decode(data: verifiedData, expectedBinding: expectedBinding)
    }
  }

  /// Exact preset destinations shipped while Mosaic still stored raw Keychain values.
  ///
  /// Keep this list independent from today's provider defaults: widening it when a provider moves
  /// would make an old unbound key eligible for a destination it never authorized.
  private static func isVerifiedLegacyPresetBinding(
    _ binding: ProviderCredentialBinding
  ) -> Bool {
    switch (binding.provider, binding.endpoint) {
    case (.openAI, "https://api.openai.com:443/v1"),
      (.anthropic, "https://api.anthropic.com:443/v1"),
      (.google, "https://generativelanguage.googleapis.com:443/v1beta"),
      (.mistral, "https://api.mistral.ai:443/v1"),
      (.openRouter, "https://openrouter.ai:443/api/v1"),
      (.deepInfra, "https://api.deepinfra.com:443/v1/openai"),
      (.tinfoil, "https://inference.tinfoil.sh:443/v1"),
      (.ollama, "http://127.0.0.1:11434/v1"):
      true
    default:
      false
    }
  }

  private static func storedCredential(data: Data) throws -> StoredCredential {
    guard data.starts(with: prefix) else {
      guard let apiKey = String(data: data, encoding: .utf8) else {
        throw SecurityKeychainError.invalidUTF8
      }
      return .legacy(apiKey)
    }

    let payloadData = Data(data.dropFirst(prefix.count))
    do {
      return .bound(try JSONDecoder().decode(Payload.self, from: payloadData))
    } catch {
      throw SecurityKeychainError.invalidUTF8
    }
  }

  private enum StoredCredential {
    case bound(Payload)
    case legacy(String)
  }

  private struct Payload: Codable {
    let apiKey: String
    let binding: ProviderCredentialBinding
  }
}

public typealias KeychainCredentialStore = SecurityKeychain

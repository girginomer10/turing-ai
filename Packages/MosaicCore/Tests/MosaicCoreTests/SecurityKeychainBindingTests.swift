import Foundation
import Security
import Testing

@testable import MosaicCore

struct SecurityKeychainBindingTests {
  @Test
  func localMacOSKeychainFallbackRequiresAnExplicitBuildAndMissingAppIdentifier() {
    #expect(
      SecurityKeychainBackend.macOS(
        applicationIdentifierIsPresent: false,
        entitlementLookupSucceeded: true,
        allowsLocalAdHocFallback: true
      ) == .localMacOSFileBased
    )
    #expect(
      SecurityKeychainBackend.macOS(
        applicationIdentifierIsPresent: true,
        entitlementLookupSucceeded: true,
        allowsLocalAdHocFallback: true
      ) == .dataProtection
    )
    #expect(
      SecurityKeychainBackend.macOS(
        applicationIdentifierIsPresent: false,
        entitlementLookupSucceeded: true,
        allowsLocalAdHocFallback: false
      ) == .dataProtection
    )
    #expect(
      SecurityKeychainBackend.macOS(
        applicationIdentifierIsPresent: false,
        entitlementLookupSucceeded: false,
        allowsLocalAdHocFallback: true
      ) == .dataProtection
    )
  }

  @Test
  func localMacOSFileBasedQueriesOmitDataProtectionOnlyAttributes() {
    let configurationID = UUID()
    let fallbackQuery = SecurityKeychainQueryBuilder.baseQuery(
      service: "com.mosaic.test",
      configurationID: configurationID,
      backend: .localMacOSFileBased
    )
    let fallbackItem = SecurityKeychainQueryBuilder.newItem(
      from: fallbackQuery,
      data: Data("dummy-key".utf8),
      backend: .localMacOSFileBased
    )
    #if os(macOS)
      #expect(!fallbackQuery.keys.contains(kSecUseDataProtectionKeychain as String))
    #endif
    #expect(!fallbackItem.keys.contains(kSecAttrAccessible as String))

    let dataProtectionQuery = SecurityKeychainQueryBuilder.baseQuery(
      service: "com.mosaic.test",
      configurationID: configurationID,
      backend: .dataProtection
    )
    let dataProtectionItem = SecurityKeychainQueryBuilder.newItem(
      from: dataProtectionQuery,
      data: Data("dummy-key".utf8),
      backend: .dataProtection
    )
    #if os(macOS)
      #expect(dataProtectionQuery[kSecUseDataProtectionKeychain as String] as? Bool == true)
    #endif
    #expect(
      dataProtectionItem[kSecAttrAccessible as String] as? String
        == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
    )
  }

  @Test
  func boundCredentialRejectsAReplacementDestination() throws {
    let oldBinding = ProviderCredentialBinding(
      provider: .custom,
      baseURL: URL(string: "https://old.example/proxy/v1/")
    )
    let newBinding = ProviderCredentialBinding(
      provider: .custom,
      baseURL: URL(string: "https://new.example/proxy/v1")
    )
    let data = try ProviderCredentialEnvelope.encode(
      apiKey: "new-destination-key",
      binding: newBinding
    )

    do {
      _ = try ProviderCredentialEnvelope.decode(
        data: data,
        expectedBinding: oldBinding
      )
      Issue.record("Expected a destination-bound credential mismatch")
    } catch let error as SecurityKeychainError {
      #expect(error == .bindingMismatch)
    }
  }

  @Test
  func boundCredentialRoundTripsForTheSameNormalizedDestination() throws {
    let savedBinding = ProviderCredentialBinding(
      provider: .openAI,
      baseURL: URL(string: "https://api.example/v1/")
    )
    let requestedBinding = ProviderCredentialBinding(
      provider: .openAI,
      baseURL: URL(string: "https://API.EXAMPLE:443/v1")
    )
    let data = try ProviderCredentialEnvelope.encode(
      apiKey: "same-destination-key",
      binding: savedBinding
    )

    #expect(savedBinding == requestedBinding)
    #expect(
      try ProviderCredentialEnvelope.decode(
        data: data,
        expectedBinding: requestedBinding
      ) == "same-destination-key"
    )
  }

  @Test
  func percentEncodedPathSeparatorIsNotEquivalentToARealSeparator() {
    let encodedSeparator = ProviderCredentialBinding(
      provider: .custom,
      baseURL: URL(string: "https://gateway.example/tenant%2Fproxy/v1")
    )
    let realSeparator = ProviderCredentialBinding(
      provider: .custom,
      baseURL: URL(string: "https://gateway.example/tenant/proxy/v1")
    )

    #expect(encodedSeparator != realSeparator)
  }

  @Test("legacy raw credential is persisted as a bound envelope before first use")
  func legacyRawCredentialMigratesOnceForItsAuthoritativeDestination() throws {
    let binding = ProviderCredentialBinding(
      provider: .anthropic,
      baseURL: URL(string: "https://api.anthropic.com/v1")
    )
    var persistedData = Data("legacy-key".utf8)
    var migrationWriteCount = 0

    #expect(
      try ProviderCredentialEnvelope.decodeOrMigrate(
        data: persistedData,
        expectedBinding: binding
      ) { migratedData in
        migrationWriteCount += 1
        persistedData = migratedData
        return persistedData
      } == "legacy-key"
    )
    #expect(migrationWriteCount == 1)
    #expect(
      try ProviderCredentialEnvelope.decode(
        data: persistedData,
        expectedBinding: binding
      ) == "legacy-key"
    )

    #expect(
      try ProviderCredentialEnvelope.decodeOrMigrate(
        data: persistedData,
        expectedBinding: binding
      ) { migratedData in
        migrationWriteCount += 1
        persistedData = migratedData
        return persistedData
      } == "legacy-key"
    )
    #expect(migrationWriteCount == 1)
  }

  @Test("migrated legacy credential rejects host and path changes without rebinding")
  func migratedLegacyCredentialRejectsDestinationChanges() throws {
    let originalBinding = ProviderCredentialBinding(
      provider: .openAI,
      baseURL: URL(string: "https://api.openai.com/v1")
    )
    let changedBindings = [
      ProviderCredentialBinding(
        provider: .openAI,
        baseURL: URL(string: "https://other.example/v1")
      ),
      ProviderCredentialBinding(
        provider: .openAI,
        baseURL: URL(string: "https://api.openai.com/other-tenant/v1")
      ),
    ]
    var persistedData = Data("legacy-key".utf8)

    _ = try ProviderCredentialEnvelope.decodeOrMigrate(
      data: persistedData,
      expectedBinding: originalBinding
    ) { migratedData in
      persistedData = migratedData
      return persistedData
    }

    for changedBinding in changedBindings {
      var attemptedRebinding = false
      do {
        _ = try ProviderCredentialEnvelope.decodeOrMigrate(
          data: persistedData,
          expectedBinding: changedBinding
        ) { migratedData in
          attemptedRebinding = true
          return migratedData
        }
        Issue.record("Expected the migrated credential to reject a changed destination")
      } catch let error as SecurityKeychainError {
        #expect(error == .bindingMismatch)
      }
      #expect(!attemptedRebinding)
    }
  }

  @Test("unverifiable legacy destination stays intact and fails closed")
  func legacyCredentialAtCustomDestinationCannotBeGuessed() throws {
    let binding = ProviderCredentialBinding(
      provider: .custom,
      baseURL: URL(string: "https://gateway.example/tenant/v1")
    )
    let legacyData = Data("legacy-key".utf8)
    var attemptedMigration = false

    do {
      _ = try ProviderCredentialEnvelope.decodeOrMigrate(
        data: legacyData,
        expectedBinding: binding
      ) { migratedData in
        attemptedMigration = true
        return migratedData
      }
      Issue.record("Expected an unverifiable legacy destination to fail closed")
    } catch let error as SecurityKeychainError {
      #expect(error == .legacyCredentialRequiresMigration)
    }
    #expect(!attemptedMigration)
    #expect(legacyData == Data("legacy-key".utf8))
  }

  @Test("legacy migration fails closed when Keychain readback is not exact")
  func legacyMigrationRequiresExactReadback() throws {
    let binding = ProviderCredentialBinding(
      provider: .openAI,
      baseURL: URL(string: "https://api.openai.com/v1")
    )

    do {
      _ = try ProviderCredentialEnvelope.decodeOrMigrate(
        data: Data("legacy-key".utf8),
        expectedBinding: binding
      ) { _ in
        Data("legacy-key".utf8)
      }
      Issue.record("Expected an unbound readback to fail closed")
    } catch let error as SecurityKeychainError {
      #expect(error == .migrationVerificationFailed)
    }
  }

  @Test("legacy raw credential cannot bypass migration")
  func legacyRawCredentialCannotDecodeDirectly() throws {
    let binding = ProviderCredentialBinding(
      provider: .anthropic,
      baseURL: URL(string: "https://api.anthropic.com/v1")
    )

    do {
      _ = try ProviderCredentialEnvelope.decode(
        data: Data("legacy-key".utf8),
        expectedBinding: binding
      )
      Issue.record("Expected a raw credential to require migration")
    } catch let error as SecurityKeychainError {
      #expect(error == .legacyCredentialRequiresMigration)
    }
  }
}

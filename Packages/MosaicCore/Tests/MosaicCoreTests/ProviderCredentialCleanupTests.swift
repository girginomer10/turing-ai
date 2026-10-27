import Foundation
import Testing

@testable import MosaicCore

@MainActor
@Suite("Provider credential cleanup", .serialized)
struct ProviderCredentialCleanupTests {
  @Test
  func tombstonePersistsOnlyNonSecretLocator() throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let locator = ProviderCredentialCleanupLocator(
      configurationID: UUID(),
      service: "com.example.credentials"
    )

    try fixture.store.record(locator)

    let reopened = ProviderCredentialCleanupTombstoneStore(fileURL: fixture.fileURL)
    #expect(try reopened.pendingLocators() == [locator])
    #expect(
      !String(decoding: try Data(contentsOf: fixture.fileURL), as: UTF8.self)
        .contains("secret-test-key")
    )
  }

  @Test
  func sourceFailureNeverRemovesCredentialAndClearsIntent() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let locator = ProviderCredentialCleanupLocator(
      configurationID: UUID(),
      service: "com.example.credentials"
    )
    var cleanupWasCalled = false

    await #expect(throws: TestFailure.sourceCommit) {
      try await ProviderConfigurationDeletionTransaction.execute(
        locator: locator,
        tombstones: fixture.store,
        commitSourceDeletion: { throw TestFailure.sourceCommit },
        removeCredential: { _ in cleanupWasCalled = true }
      )
    }

    #expect(!cleanupWasCalled)
    #expect(try fixture.store.pendingLocators().isEmpty)
  }

  @Test
  func cleanupFailureKeepsDeletedSourceAndDurableRetryIntent() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let locator = ProviderCredentialCleanupLocator(
      configurationID: UUID(),
      service: "com.example.credentials"
    )
    var sourceCommitted = false

    let outcome = try await ProviderConfigurationDeletionTransaction.execute(
      locator: locator,
      tombstones: fixture.store,
      commitSourceDeletion: { sourceCommitted = true },
      removeCredential: { _ in throw TestFailure.keychainCleanup }
    )

    #expect(sourceCommitted)
    #expect(
      outcome
        == .deletedWithCredentialCleanupPending(
          TestFailure.keychainCleanup.localizedDescription
        ))
    #expect(try fixture.store.pendingLocators() == [locator])
  }

  @Test
  func cleanupRunsOnlyAfterSourceCommitAndClearsTombstone() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let locator = ProviderCredentialCleanupLocator(
      configurationID: UUID(),
      service: "com.example.credentials"
    )
    var events: [String] = []

    let outcome = try await ProviderConfigurationDeletionTransaction.execute(
      locator: locator,
      tombstones: fixture.store,
      commitSourceDeletion: { events.append("source") },
      removeCredential: { _ in events.append("keychain") }
    )

    #expect(outcome == .deleted)
    #expect(events == ["source", "keychain"])
    #expect(try fixture.store.pendingLocators().isEmpty)
  }

  @Test
  func launchReconciliationPreservesKeyWhenProviderStillExists() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let locator = ProviderCredentialCleanupLocator(
      configurationID: UUID(),
      service: "com.example.credentials"
    )
    try fixture.store.record(locator)
    var cleanupWasCalled = false

    let failures = await ProviderConfigurationDeletionTransaction.reconcile(
      existingProviderIDs: [locator.configurationID],
      tombstones: fixture.store,
      removeCredential: { _ in cleanupWasCalled = true }
    )

    #expect(failures.isEmpty)
    #expect(!cleanupWasCalled)
    #expect(try fixture.store.pendingLocators().isEmpty)
  }

  @Test
  func launchReconciliationRetriesOnlyMissingProviderAndRetainsFailure() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let successful = ProviderCredentialCleanupLocator(
      configurationID: UUID(),
      service: "com.example.credentials"
    )
    let failing = ProviderCredentialCleanupLocator(
      configurationID: UUID(),
      service: "com.example.credentials"
    )
    try fixture.store.record(successful)
    try fixture.store.record(failing)

    let failures = await ProviderConfigurationDeletionTransaction.reconcile(
      existingProviderIDs: [],
      tombstones: fixture.store,
      removeCredential: { locator in
        if locator == failing { throw TestFailure.keychainCleanup }
      }
    )

    #expect(
      failures
        == [
          ProviderCredentialCleanupFailure(
            locator: failing,
            message: TestFailure.keychainCleanup.localizedDescription
          )
        ])
    #expect(try fixture.store.pendingLocators() == [failing])
  }

  @Test
  func corruptArchiveFailsClosedBeforeSourceCommit() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.directory,
      withIntermediateDirectories: true
    )
    try Data("not a cleanup archive".utf8).write(to: fixture.fileURL, options: .atomic)
    let locator = ProviderCredentialCleanupLocator(
      configurationID: UUID(),
      service: "com.example.credentials"
    )
    var sourceCommitted = false
    var cleanupWasCalled = false

    await #expect(throws: ProviderCredentialCleanupTombstoneError.invalidArchive) {
      try await ProviderConfigurationDeletionTransaction.execute(
        locator: locator,
        tombstones: fixture.store,
        commitSourceDeletion: { sourceCommitted = true },
        removeCredential: { _ in cleanupWasCalled = true }
      )
    }

    #expect(!sourceCommitted)
    #expect(!cleanupWasCalled)
    #expect(try Data(contentsOf: fixture.fileURL) == Data("not a cleanup archive".utf8))
  }

  private func makeFixture() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ProviderCredentialCleanupTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("cleanup.json")
    return Fixture(
      directory: directory,
      fileURL: fileURL,
      store: ProviderCredentialCleanupTombstoneStore(fileURL: fileURL)
    )
  }

  private struct Fixture {
    let directory: URL
    let fileURL: URL
    let store: ProviderCredentialCleanupTombstoneStore

    func remove() {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private enum TestFailure: Error, LocalizedError {
    case sourceCommit
    case keychainCleanup

    var errorDescription: String? {
      switch self {
      case .sourceCommit:
        "source commit failed"
      case .keychainCleanup:
        "keychain cleanup failed"
      }
    }
  }
}

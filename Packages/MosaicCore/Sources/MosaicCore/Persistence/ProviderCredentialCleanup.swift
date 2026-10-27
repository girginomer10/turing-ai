import Foundation

/// A non-secret, durable pointer to one provider credential. The service and account are captured
/// before the provider source row is deleted so cleanup can be retried after process termination.
struct ProviderCredentialCleanupLocator: Codable, Hashable, Sendable {
  let configurationID: UUID
  let service: String
}

enum ProviderCredentialCleanupTombstoneError: LocalizedError, Equatable {
  case invalidService
  case invalidArchive
  case persistenceFailed

  var errorDescription: String? {
    switch self {
    case .invalidService:
      "Turing AI could not create a safe Keychain cleanup record for this provider."
    case .invalidArchive:
      "Turing AI could not verify its pending Keychain cleanup record, so the provider was not deleted."
    case .persistenceFailed:
      "Turing AI could not save the Keychain cleanup record, so the provider was not deleted."
    }
  }
}

/// Stores only Keychain locators, never credential bytes. Atomic file replacement makes the intent
/// durable before the source transaction starts; a bounded, versioned archive fails closed if it
/// cannot be verified.
@MainActor
final class ProviderCredentialCleanupTombstoneStore {
  static let shared = ProviderCredentialCleanupTombstoneStore()

  private static let filename = "PendingProviderCredentialCleanup.json"
  private static let maximumArchiveBytes = 256 * 1_024
  private static let maximumLocatorCount = 1_024
  private static let maximumServiceUTF8Bytes = 512

  private struct Archive: Codable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let locators: [ProviderCredentialCleanupLocator]
  }

  private let injectedFileURL: URL?

  init(fileURL: URL? = nil) {
    injectedFileURL = fileURL
  }

  func record(_ locator: ProviderCredentialCleanupLocator) throws {
    guard Self.isValid(service: locator.service) else {
      throw ProviderCredentialCleanupTombstoneError.invalidService
    }

    var locators = try pendingLocators()
    if let index = locators.firstIndex(where: {
      $0.configurationID == locator.configurationID
    }) {
      locators[index] = locator
    } else {
      guard locators.count < Self.maximumLocatorCount else {
        throw ProviderCredentialCleanupTombstoneError.persistenceFailed
      }
      locators.append(locator)
    }
    try write(locators)
  }

  func discard(_ locator: ProviderCredentialCleanupLocator) {
    discard(configurationID: locator.configurationID)
  }

  func discard(configurationID: UUID) {
    guard var locators = try? pendingLocators() else { return }
    locators.removeAll { $0.configurationID == configurationID }
    try? write(locators)
  }

  func pendingLocators() throws -> [ProviderCredentialCleanupLocator] {
    let fileURL = try resolvedFileURL()
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    guard
      let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      fileSize <= Self.maximumArchiveBytes
    else {
      throw ProviderCredentialCleanupTombstoneError.invalidArchive
    }
    let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    guard data.count <= Self.maximumArchiveBytes else {
      throw ProviderCredentialCleanupTombstoneError.invalidArchive
    }
    let archive: Archive
    do {
      archive = try JSONDecoder().decode(Archive.self, from: data)
    } catch {
      throw ProviderCredentialCleanupTombstoneError.invalidArchive
    }
    guard
      archive.formatVersion == Archive.currentFormatVersion,
      archive.locators.count <= Self.maximumLocatorCount,
      archive.locators.allSatisfy({ Self.isValid(service: $0.service) }),
      Set(archive.locators.map(\.configurationID)).count == archive.locators.count
    else {
      throw ProviderCredentialCleanupTombstoneError.invalidArchive
    }
    return archive.locators.sorted {
      $0.configurationID.uuidString < $1.configurationID.uuidString
    }
  }

  private func write(_ locators: [ProviderCredentialCleanupLocator]) throws {
    let fileURL = try resolvedFileURL()
    let archive = Archive(
      formatVersion: Archive.currentFormatVersion,
      locators: locators.sorted {
        $0.configurationID.uuidString < $1.configurationID.uuidString
      }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(archive)
    } catch {
      throw ProviderCredentialCleanupTombstoneError.persistenceFailed
    }
    guard data.count <= Self.maximumArchiveBytes else {
      throw ProviderCredentialCleanupTombstoneError.persistenceFailed
    }
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: fileURL, options: [.atomic])
      guard try Data(contentsOf: fileURL) == data else {
        throw ProviderCredentialCleanupTombstoneError.persistenceFailed
      }
    } catch let error as ProviderCredentialCleanupTombstoneError {
      throw error
    } catch {
      throw ProviderCredentialCleanupTombstoneError.persistenceFailed
    }
  }

  private func resolvedFileURL() throws -> URL {
    if let injectedFileURL { return injectedFileURL }
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return
      applicationSupport
      .appendingPathComponent(MosaicSchema.libraryDirectoryName, isDirectory: true)
      .appendingPathComponent(Self.filename)
  }

  private static func isValid(service: String) -> Bool {
    !service.isEmpty && service.utf8.count <= maximumServiceUTF8Bytes
  }
}

enum ProviderConfigurationDeletionOutcome: Equatable, Sendable {
  case deleted
  case deletedWithCredentialCleanupPending(String)
}

struct ProviderCredentialCleanupFailure: Equatable, Sendable {
  let locator: ProviderCredentialCleanupLocator
  let message: String
}

/// Keeps source deletion authoritative while making external Keychain cleanup recoverable. A
/// tombstone is committed first. If the process exits before the source save, launch reconciliation
/// sees the provider row and clears the tombstone without touching its key. If the process exits
/// after the source save, reconciliation sees no provider row and finishes the idempotent cleanup.
@MainActor
enum ProviderConfigurationDeletionTransaction {
  static func execute(
    locator: ProviderCredentialCleanupLocator,
    tombstones: ProviderCredentialCleanupTombstoneStore = .shared,
    commitSourceDeletion: () throws -> Void,
    removeCredential: (ProviderCredentialCleanupLocator) async throws -> Void
  ) async throws -> ProviderConfigurationDeletionOutcome {
    try tombstones.record(locator)

    do {
      try commitSourceDeletion()
    } catch {
      tombstones.discard(locator)
      throw error
    }

    do {
      try await removeCredential(locator)
      tombstones.discard(locator)
      return .deleted
    } catch {
      return .deletedWithCredentialCleanupPending(error.localizedDescription)
    }
  }

  static func reconcile(
    existingProviderIDs: Set<UUID>,
    tombstones: ProviderCredentialCleanupTombstoneStore = .shared,
    removeCredential: (ProviderCredentialCleanupLocator) async throws -> Void
  ) async -> [ProviderCredentialCleanupFailure] {
    var failures: [ProviderCredentialCleanupFailure] = []
    let locators: [ProviderCredentialCleanupLocator]
    do {
      locators = try tombstones.pendingLocators()
    } catch {
      return []
    }
    for locator in locators {
      if existingProviderIDs.contains(locator.configurationID) {
        // The source transaction never committed. Preserve the live provider's credential.
        tombstones.discard(locator)
        continue
      }

      do {
        try await removeCredential(locator)
        tombstones.discard(locator)
      } catch {
        failures.append(
          ProviderCredentialCleanupFailure(
            locator: locator,
            message: error.localizedDescription
          )
        )
      }
    }
    return failures
  }
}

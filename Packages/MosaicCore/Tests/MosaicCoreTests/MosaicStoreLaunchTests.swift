import Foundation
import SwiftData
import Testing

@testable import MosaicCore

struct MosaicStoreLaunchTests {
  @MainActor
  @Test
  func successfulOpenReturnsTheCreatedContainer() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)

    let launch = MosaicModelContainer.open(using: { container })

    guard case .ready(let openedContainer) = launch else {
      Issue.record("Expected a ready store launch")
      return
    }
    #expect(openedContainer === container)
  }

  @MainActor
  @Test
  func failedOpenReturnsRecoveryWithoutTryingAnotherStore() {
    var attempts = 0

    let launch = MosaicModelContainer.open {
      attempts += 1
      throw StoreTestError.cannotOpen
    }

    guard case .recovery(let failure) = launch else {
      Issue.record("Expected a recovery store launch")
      return
    }
    #expect(attempts == 1)
    #expect(failure.diagnosticCode.contains("MosaicCoreTests"))
  }

  @MainActor
  @Test
  func diskStoreUsesDedicatedLocationAndReopensPersistedData() throws {
    let applicationSupport = try makeTemporaryApplicationSupportDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupport) }
    let conversationID = UUID()

    do {
      let container = try MosaicSchema.makeModelContainer(
        applicationSupportDirectory: applicationSupport
      )
      let context = container.mainContext
      context.insert(ConversationRecord(id: conversationID, title: "Dedicated store"))
      try context.save()
    }

    let dedicatedStore =
      applicationSupport
      .appendingPathComponent("Mosaic", isDirectory: true)
      .appendingPathComponent("Mosaic.store")
    #expect(FileManager.default.fileExists(atPath: dedicatedStore.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: applicationSupport.appendingPathComponent("default.store").path
      )
    )

    let reopened = try MosaicSchema.makeModelContainer(
      applicationSupportDirectory: applicationSupport
    )
    let conversations = try reopened.mainContext.fetch(FetchDescriptor<ConversationRecord>())
    #expect(conversations.map(\.id) == [conversationID])
  }

  @MainActor
  @Test
  func foreignDefaultStoreIsUntouchedAndDoesNotBlockDedicatedStore() throws {
    let applicationSupport = try makeTemporaryApplicationSupportDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupport) }
    let legacyStore = applicationSupport.appendingPathComponent("default.store")
    let foreignID = UUID()
    try createForeignStore(at: legacyStore, recordID: foreignID)
    let originalStoreFamily = try storeFamilySnapshot(at: legacyStore)

    let mosaicContainer = try MosaicSchema.makeModelContainer(
      applicationSupportDirectory: applicationSupport
    )
    #expect(try mosaicContainer.mainContext.fetchCount(FetchDescriptor<ConversationRecord>()) == 0)

    let dedicatedStore =
      applicationSupport
      .appendingPathComponent("Mosaic", isDirectory: true)
      .appendingPathComponent("Mosaic.store")
    #expect(FileManager.default.fileExists(atPath: dedicatedStore.path))
    #expect(FileManager.default.fileExists(atPath: legacyStore.path))
    #expect(try storeFamilySnapshot(at: legacyStore) == originalStoreFamily)
    #expect(try foreignRecordIDs(in: legacyStore) == [foreignID])
  }

  @MainActor
  @Test(arguments: LegacyStoreFixtureVersion.allCases)
  func recognizedLegacyStoreOpensAndReopensInPlace(
    version: LegacyStoreFixtureVersion
  ) throws {
    try verifyRecognizedLegacyOpenInPlace(version: version)
  }

  @MainActor
  @Test
  func unreadableLegacyMetadataFailsClosedWithoutCreatingDedicatedStore() throws {
    let applicationSupport = try makeTemporaryApplicationSupportDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupport) }
    let legacyStore = applicationSupport.appendingPathComponent("default.store")
    let originalBytes = Data("not-a-core-data-store".utf8)
    try originalBytes.write(to: legacyStore)

    #expect(throws: Error.self) {
      _ = try MosaicSchema.makeModelContainer(
        applicationSupportDirectory: applicationSupport
      )
    }

    let dedicatedStore =
      applicationSupport
      .appendingPathComponent("Mosaic", isDirectory: true)
      .appendingPathComponent("Mosaic.store")
    #expect(!FileManager.default.fileExists(atPath: dedicatedStore.path))
    #expect(try Data(contentsOf: legacyStore) == originalBytes)
  }

  @MainActor
  @Test
  func launchRecoveryRestoresIntoNewGenerationWithoutChangingFailedStore() async throws {
    let applicationSupport = try makeTemporaryApplicationSupportDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupport) }
    let conversationID = UUID()

    let backupContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    backupContainer.mainContext.insert(
      ConversationRecord(id: conversationID, title: "Recovered conversation")
    )
    try backupContainer.mainContext.save()
    let backup = try MosaicPortableBackup.export(from: backupContainer.mainContext)

    let mosaicDirectory = applicationSupport.appendingPathComponent("Mosaic", isDirectory: true)
    try FileManager.default.createDirectory(
      at: mosaicDirectory,
      withIntermediateDirectories: true
    )
    let failedStore = mosaicDirectory.appendingPathComponent("Mosaic.store")
    let failedStoreBytes = Data("not-a-swiftdata-store".utf8)
    try failedStoreBytes.write(to: failedStore)

    #expect(throws: Error.self) {
      _ = try MosaicSchema.makeModelContainer(
        applicationSupportDirectory: applicationSupport
      )
    }

    var restoredContainer: ModelContainer? = try await MosaicLaunchRecovery.restorePortableBackup(
      from: backup,
      applicationSupportDirectory: applicationSupport,
      recoveryCoordinator: MosaicLaunchRecoveryCoordinator()
    )
    let restoredIDs = try #require(restoredContainer).mainContext.fetch(
      FetchDescriptor<ConversationRecord>()
    ).map(\.id)
    #expect(restoredIDs == [conversationID])
    #expect(try Data(contentsOf: failedStore) == failedStoreBytes)
    #expect(
      FileManager.default.fileExists(
        atPath: mosaicDirectory.appendingPathComponent("ActiveStore.json").path
      )
    )

    restoredContainer = nil
    let reopened = try MosaicSchema.makeModelContainer(
      applicationSupportDirectory: applicationSupport
    )
    let reopenedIDs = try reopened.mainContext.fetch(FetchDescriptor<ConversationRecord>()).map(
      \.id)
    #expect(reopenedIDs == [conversationID])
    #expect(try Data(contentsOf: failedStore) == failedStoreBytes)
  }

  @MainActor
  @Test
  func rejectedLaunchRecoveryBackupDoesNotSelectOrChangeAnyStore() async throws {
    let applicationSupport = try makeTemporaryApplicationSupportDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupport) }
    let mosaicDirectory = applicationSupport.appendingPathComponent("Mosaic", isDirectory: true)
    try FileManager.default.createDirectory(
      at: mosaicDirectory,
      withIntermediateDirectories: true
    )
    let failedStore = mosaicDirectory.appendingPathComponent("Mosaic.store")
    let failedStoreBytes = Data("still-not-a-swiftdata-store".utf8)
    try failedStoreBytes.write(to: failedStore)

    await #expect(throws: MosaicPortableBackupError.malformedEnvelope) {
      _ = try await MosaicLaunchRecovery.restorePortableBackup(
        from: Data("not-a-portable-backup".utf8),
        applicationSupportDirectory: applicationSupport,
        recoveryCoordinator: MosaicLaunchRecoveryCoordinator()
      )
    }

    #expect(try Data(contentsOf: failedStore) == failedStoreBytes)
    #expect(
      !FileManager.default.fileExists(
        atPath: mosaicDirectory.appendingPathComponent("ActiveStore.json").path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: mosaicDirectory.appendingPathComponent("StoreGenerations").path
      )
    )
  }

  @MainActor
  @Test
  func failedLaunchRecoveryRemovesOnlyItsUnactivatedGeneration() async throws {
    let applicationSupport = try makeTemporaryApplicationSupportDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupport) }
    let mosaicDirectory = applicationSupport.appendingPathComponent("Mosaic", isDirectory: true)
    let generationsDirectory = mosaicDirectory.appendingPathComponent(
      "StoreGenerations",
      isDirectory: true
    )
    let activeGenerationID = UUID()
    let activeGenerationDirectory = generationsDirectory.appendingPathComponent(
      activeGenerationID.uuidString.lowercased(),
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: activeGenerationDirectory,
      withIntermediateDirectories: true
    )
    let activeStore = activeGenerationDirectory.appendingPathComponent("Mosaic.store")
    let activeStoreBytes = Data("existing-active-generation".utf8)
    try activeStoreBytes.write(to: activeStore)
    try MosaicSchema.activateStoreGeneration(
      id: activeGenerationID,
      in: applicationSupport
    )
    let activePointer = mosaicDirectory.appendingPathComponent("ActiveStore.json")
    let activePointerBytes = try Data(contentsOf: activePointer)

    let backupContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    backupContainer.mainContext.insert(ConversationRecord(title: "Staged then rejected"))
    try backupContainer.mainContext.save()
    let backup = try MosaicPortableBackup.export(from: backupContainer.mainContext)
    var unactivatedGenerationID: UUID?

    do {
      _ = try await MosaicLaunchRecovery.restorePortableBackup(
        from: backup,
        applicationSupportDirectory: applicationSupport,
        recoveryCoordinator: MosaicLaunchRecoveryCoordinator(),
        activateStoreGeneration: { generationID, _ in
          unactivatedGenerationID = generationID
          throw StoreTestError.cannotActivate
        }
      )
      Issue.record("Expected activation to fail")
    } catch StoreTestError.cannotActivate {
      // Expected. The staged generation must be removed without touching the active one.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(unactivatedGenerationID != nil)
    #expect(try Data(contentsOf: activePointer) == activePointerBytes)
    #expect(try Data(contentsOf: activeStore) == activeStoreBytes)
    let remainingGenerations = try FileManager.default.contentsOfDirectory(
      at: generationsDirectory,
      includingPropertiesForKeys: nil
    ).map(\.lastPathComponent)
    #expect(remainingGenerations == [activeGenerationID.uuidString.lowercased()])
  }

  @MainActor
  @Test
  func launchRecoveryLeaseRejectsASecondBackupBeforeItCanStage() async throws {
    let applicationSupport = try makeTemporaryApplicationSupportDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupport) }
    let coordinator = MosaicLaunchRecoveryCoordinator()
    let suspension = LaunchRecoverySuspension()
    let firstRestore = Task { @MainActor in
      try await coordinator.perform {
        await suspension.holdLease()
      }
    }
    while !suspension.didEnter {
      await Task.yield()
    }
    #expect(coordinator.isRestoring)

    let backupContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    backupContainer.mainContext.insert(ConversationRecord(title: "Must not stage"))
    try backupContainer.mainContext.save()
    let backup = try MosaicPortableBackup.export(from: backupContainer.mainContext)
    do {
      _ = try await MosaicLaunchRecovery.restorePortableBackup(
        from: backup,
        applicationSupportDirectory: applicationSupport,
        recoveryCoordinator: coordinator
      )
      Issue.record("Expected the concurrent restore to be rejected")
    } catch let error as MosaicLaunchRecoveryError {
      #expect(error == .restoreAlreadyInProgress)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: applicationSupport.appendingPathComponent("Mosaic/StoreGenerations").path
      )
    )

    suspension.releaseLease()
    try await firstRestore.value
    #expect(!coordinator.isRestoring)
  }

  @MainActor
  @Test
  func invalidActiveGenerationPointerFailsClosedWithoutOpeningFallbackStore() throws {
    let applicationSupport = try makeTemporaryApplicationSupportDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupport) }
    let mosaicDirectory = applicationSupport.appendingPathComponent("Mosaic", isDirectory: true)
    try FileManager.default.createDirectory(
      at: mosaicDirectory,
      withIntermediateDirectories: true
    )
    let pointerURL = mosaicDirectory.appendingPathComponent("ActiveStore.json")
    let pointerBytes = Data("not-a-valid-pointer".utf8)
    try pointerBytes.write(to: pointerURL)

    #expect(throws: MosaicStoreLocationError.invalidActiveStorePointer) {
      _ = try MosaicSchema.makeModelContainer(
        applicationSupportDirectory: applicationSupport
      )
    }

    #expect(try Data(contentsOf: pointerURL) == pointerBytes)
    #expect(
      !FileManager.default.fileExists(
        atPath: mosaicDirectory.appendingPathComponent("Mosaic.store").path
      )
    )
  }

  @MainActor
  @Test
  func unknownMosaicLikeLegacyFailsClosedWithoutCreatingDedicatedStore() throws {
    let applicationSupport = try makeTemporaryApplicationSupportDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupport) }
    let legacyStore = applicationSupport.appendingPathComponent("default.store")
    let conversationID = UUID()
    try createUnknownMosaicLikeStore(at: legacyStore, recordID: conversationID)
    let originalStoreFamily = try storeFamilySnapshot(at: legacyStore)

    #expect(throws: Error.self) {
      _ = try MosaicSchema.makeModelContainer(
        applicationSupportDirectory: applicationSupport
      )
    }

    let dedicatedStore =
      applicationSupport
      .appendingPathComponent("Mosaic", isDirectory: true)
      .appendingPathComponent("Mosaic.store")
    #expect(!FileManager.default.fileExists(atPath: dedicatedStore.path))
    #expect(try storeFamilySnapshot(at: legacyStore) == originalStoreFamily)
    #expect(try unknownMosaicLikeRecordIDs(in: legacyStore) == [conversationID])
  }

  @MainActor
  @Test
  func populatedUnversionedV1StoreMigratesToAdditiveV2() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MosaicSchemaMigration-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("Mosaic.store")
    let conversationID = UUID()
    let messageID = UUID()

    do {
      // This intentionally matches the pre-versioning constructor used by shipped builds.
      let legacySchema = Schema(MosaicSchemaV1.models)
      let legacyConfiguration = ModelConfiguration(
        "Mosaic",
        schema: legacySchema,
        url: storeURL,
        cloudKitDatabase: .none
      )
      let legacyContainer = try ModelContainer(
        for: legacySchema,
        configurations: [legacyConfiguration]
      )
      let context = legacyContainer.mainContext
      context.insert(
        ConversationRecord(
          id: conversationID,
          title: "Preserve me",
          modelIdentifier: "model-v1"
        )
      )
      context.insert(
        MessageRecord(
          id: messageID,
          conversationID: conversationID,
          role: .user,
          content: "Legacy content"
        )
      )
      try context.save()
    }

    let migratedContainer = try MosaicSchema.makeModelContainer(storeURL: storeURL)
    let context = migratedContainer.mainContext
    let conversations = try context.fetch(FetchDescriptor<ConversationRecord>())
    let messages = try context.fetch(FetchDescriptor<MessageRecord>())
    let normalizedEvents = try context.fetch(FetchDescriptor<RequestContextEventRecord>())

    #expect(conversations.map(\.id) == [conversationID])
    #expect(messages.map(\.id) == [messageID])
    #expect(normalizedEvents.isEmpty)
  }

  /// Optional disk fixture used by release validation. Point the environment variable at a copy,
  /// never the live store: opening it is expected to perform a lightweight migration in place.
  @MainActor
  @Test
  func providedLegacyStoreMigratesToTheCurrentOptionalCompactionSchema() throws {
    guard
      let fixturePath = ProcessInfo.processInfo.environment["MOSAIC_LEGACY_STORE_FIXTURE"],
      !fixturePath.isEmpty
    else {
      return
    }
    let schema = MosaicSchema.schema
    let configuration = ModelConfiguration(
      "LegacyMigrationSmoke",
      schema: schema,
      url: URL(fileURLWithPath: fixturePath),
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(
      for: schema,
      migrationPlan: MosaicSchemaMigrationPlan.self,
      configurations: [configuration]
    )
    let context = ModelContext(container)
    let existing = try context.fetch(FetchDescriptor<ConversationRecord>())

    #expect(existing.allSatisfy { $0.compactionSnapshotData == nil })

    let probe = ConversationRecord(title: "Migration probe")
    let probeID = probe.id
    context.insert(probe)
    try context.save()
    let saved = try context.fetch(
      FetchDescriptor<ConversationRecord>(
        predicate: #Predicate<ConversationRecord> { $0.id == probeID }
      )
    )
    #expect(saved.first?.compactionSnapshotData == nil)
  }

  @MainActor
  private func verifyRecognizedLegacyOpenInPlace(version: LegacyStoreFixtureVersion) throws {
    let applicationSupport = try makeTemporaryApplicationSupportDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupport) }
    let legacyStore = applicationSupport.appendingPathComponent("default.store")
    let conversationID = UUID()
    try createRecognizedLegacyStore(
      at: legacyStore,
      recordID: conversationID,
      version: version
    )

    do {
      let opened = try MosaicSchema.makeModelContainer(
        applicationSupportDirectory: applicationSupport
      )
      let conversations = try opened.mainContext.fetch(FetchDescriptor<ConversationRecord>())
      #expect(conversations.map(\.id) == [conversationID])
      #expect(try opened.mainContext.fetchCount(FetchDescriptor<RequestContextEventRecord>()) == 0)
    }

    let dedicatedStore =
      applicationSupport
      .appendingPathComponent("Mosaic", isDirectory: true)
      .appendingPathComponent("Mosaic.store")
    #expect(!FileManager.default.fileExists(atPath: dedicatedStore.path))
    #expect(FileManager.default.fileExists(atPath: legacyStore.path))

    let reopened = try MosaicSchema.makeModelContainer(
      applicationSupportDirectory: applicationSupport
    )
    let reopenedIDs = try reopened.mainContext.fetch(FetchDescriptor<ConversationRecord>()).map(
      \.id)
    #expect(reopenedIDs == [conversationID])
  }
}

private enum StoreTestError: Error {
  case cannotOpen
  case cannotActivate
}

@MainActor
private final class LaunchRecoverySuspension {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var didEnter = false

  func holdLease() async {
    didEnter = true
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func releaseLease() {
    continuation?.resume()
    continuation = nil
  }
}

enum LegacyStoreFixtureVersion: CaseIterable {
  case v1
  case v2
}

@MainActor
private func makeTemporaryApplicationSupportDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "MosaicApplicationSupport-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

@MainActor
private func createForeignStore(at storeURL: URL, recordID: UUID) throws {
  try autoreleasepool {
    let foreignSchema = Schema([EmbeddingVectorRecord.self])
    let configuration = ModelConfiguration(
      "ForeignDefaultStore",
      schema: foreignSchema,
      url: storeURL,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(
      for: foreignSchema,
      configurations: [configuration]
    )
    let context = container.mainContext
    context.insert(
      EmbeddingVectorRecord(
        id: recordID,
        profileID: UUID(),
        sourceKind: .conversationMessage,
        sourceID: UUID(),
        embeddingSpaceIdentifier: "foreign",
        contentFingerprint: "foreign",
        dimensions: 1,
        vectorData: Data([0])
      )
    )
    try context.save()
  }
}

@MainActor
private func foreignRecordIDs(in storeURL: URL) throws -> [UUID] {
  try autoreleasepool {
    let foreignSchema = Schema([EmbeddingVectorRecord.self])
    let configuration = ModelConfiguration(
      "ForeignDefaultStore",
      schema: foreignSchema,
      url: storeURL,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(
      for: foreignSchema,
      configurations: [configuration]
    )
    return try container.mainContext.fetch(FetchDescriptor<EmbeddingVectorRecord>()).map(\.id)
  }
}

@MainActor
private func createUnknownMosaicLikeStore(at storeURL: URL, recordID: UUID) throws {
  try autoreleasepool {
    let legacySchema = Schema([
      ConversationRecord.self,
      MessageRecord.self,
      MemoryRecord.self,
      ScheduledTaskRecord.self,
      ProviderConfigurationRecord.self,
    ])
    let configuration = ModelConfiguration(
      "UnknownMosaicLegacy",
      schema: legacySchema,
      url: storeURL,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(
      for: legacySchema,
      configurations: [configuration]
    )
    let context = container.mainContext
    context.insert(ConversationRecord(id: recordID, title: "Unknown Mosaic legacy"))
    try context.save()
  }
}

@MainActor
private func unknownMosaicLikeRecordIDs(in storeURL: URL) throws -> [UUID] {
  try autoreleasepool {
    let legacySchema = Schema([
      ConversationRecord.self,
      MessageRecord.self,
      MemoryRecord.self,
      ScheduledTaskRecord.self,
      ProviderConfigurationRecord.self,
    ])
    let configuration = ModelConfiguration(
      "UnknownMosaicLegacy",
      schema: legacySchema,
      url: storeURL,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(
      for: legacySchema,
      configurations: [configuration]
    )
    return try container.mainContext.fetch(FetchDescriptor<ConversationRecord>()).map(\.id)
  }
}

private struct StoreFamilySnapshot: Equatable {
  let durableMembers: [String: Data]
  let sharedMemorySize: UInt64?
}

private func storeFamilySnapshot(at storeURL: URL) throws -> StoreFamilySnapshot {
  let fileManager = FileManager.default
  let durableMembers = try ["", "-wal", "-journal"].reduce(
    into: [String: Data]()
  ) { snapshot, suffix in
    let memberURL = URL(fileURLWithPath: storeURL.path + suffix)
    guard fileManager.fileExists(atPath: memberURL.path) else { return }
    snapshot[suffix] = try Data(contentsOf: memberURL)
  }
  let sharedMemoryURL = URL(fileURLWithPath: storeURL.path + "-shm")
  let sharedMemorySize: UInt64?
  if fileManager.fileExists(atPath: sharedMemoryURL.path) {
    let attributes = try fileManager.attributesOfItem(atPath: sharedMemoryURL.path)
    sharedMemorySize = (attributes[.size] as? NSNumber)?.uint64Value
  } else {
    sharedMemorySize = nil
  }
  return StoreFamilySnapshot(
    durableMembers: durableMembers,
    // SQLite readers may update volatile lock/read-mark bytes in `-shm`; presence and size are the
    // stable invariants. The durable main, WAL, and rollback-journal bytes remain exact above.
    sharedMemorySize: sharedMemorySize
  )
}

@MainActor
private func createRecognizedLegacyStore(
  at storeURL: URL,
  recordID: UUID,
  version: LegacyStoreFixtureVersion
) throws {
  try autoreleasepool {
    let fixtureSchema: Schema
    let migrationPlan: (any SchemaMigrationPlan.Type)?
    switch version {
    case .v1:
      fixtureSchema = Schema(MosaicSchemaV1.models)
      migrationPlan = nil
    case .v2:
      fixtureSchema = MosaicSchema.schema
      migrationPlan = MosaicSchemaMigrationPlan.self
    }
    let configuration = ModelConfiguration(
      "Mosaic",
      schema: fixtureSchema,
      url: storeURL,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(
      for: fixtureSchema,
      migrationPlan: migrationPlan,
      configurations: [configuration]
    )
    let context = container.mainContext
    context.insert(ConversationRecord(id: recordID, title: "Legacy \(version)"))
    try context.save()
  }
}

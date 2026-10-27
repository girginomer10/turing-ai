import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite("Background iCloud sync", .serialized)
@MainActor
struct ICloudBackgroundSyncTests {
  @Test func unchangedLibraryDoesNotEnterExclusiveMaintenance() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = ModelContext(container)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = BackgroundSyncTestTransport()
    let coordinator = MosaicOperationCoordinator()
    let sync = ICloudLibraryCoordinator(
      transport: transport, directory: directory, enabled: true,
      coordinator: coordinator)
    let revision = coordinator.sourceActivityRevision
    await sync.sync(in: context)
    #expect(sync.status == "Up to date")
    #expect(coordinator.sourceActivityRevision == revision)
    #expect(!coordinator.isSourceAccessBlocked)
    #expect(coordinator.activeOperations.isEmpty)
    await sync.sync(in: context)
    #expect(sync.status == "Up to date")
    #expect(coordinator.sourceActivityRevision == revision)
  }
  @Test(arguments: [false, true])
  func incomingChangesNeverOverwriteEditsMadeDuringNetworkWork(interleave: Bool) async throws {
    let remoteContext = ModelContext(try MosaicSchema.makeModelContainer(inMemory: true))
    remoteContext.insert(MemoryRecord(title: "Cloud", content: "Remote fixture"))
    try remoteContext.save()
    var remote = CloudDeviceState(accountID: "fixture-account")
    try remote.observe(MosaicPortableBackup.captureSnapshot(from: remoteContext))

    let context = ModelContext(try MosaicSchema.makeModelContainer(inMemory: true))
    let coordinator = MosaicOperationCoordinator()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = BackgroundSyncTestTransport(
      envelope: remote.envelope,
      onFetch: {
        #expect(!coordinator.isSourceAccessBlocked)
        if interleave {
          context.insert(MemoryRecord(title: "Local", content: "Edited while iCloud was loading"))
          try coordinator.saveSourceChanges(in: context)
        }
      })
    let sync = ICloudLibraryCoordinator(
      transport: transport, directory: directory, enabled: true,
      coordinator: coordinator)
    await sync.sync(in: context)
    let saved = try ModelContext(context.container).fetch(FetchDescriptor<MemoryRecord>())
    if interleave {
      #expect(sync.status == "Changes saved locally; syncing on the next pass")
      #expect(saved.map(\.title) == ["Local"])
      #expect(coordinator.sourceStoreGenerationRevision == 0)
    } else {
      #expect(sync.status == "Up to date")
      #expect(saved.map(\.title) == ["Cloud"])
      #expect(coordinator.sourceStoreGenerationRevision == 1)
    }
    #expect(!coordinator.isSourceAccessBlocked)
  }

}

private actor BackgroundSyncTestTransport: ICloudLibraryTransporting {
  var envelope: CloudLibraryEnvelope
  let onFetch: (@MainActor @Sendable () throws -> Void)?
  init(
    envelope: CloudLibraryEnvelope = .init(),
    onFetch: (@MainActor @Sendable () throws -> Void)? = nil
  ) {
    self.envelope = envelope
    self.onFetch = onFetch
  }
  func account() -> String { "fixture-account" }
  func fetch() async throws -> CloudLibraryEnvelope {
    try await onFetch?()
    return envelope
  }
  func save(_ value: CloudLibraryEnvelope) { envelope = value }
}

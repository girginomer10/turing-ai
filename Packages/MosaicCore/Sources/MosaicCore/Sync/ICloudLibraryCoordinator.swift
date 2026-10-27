import Foundation
import Observation
import SwiftData

@Observable @MainActor
final class ICloudLibraryCoordinator {
  static let shared = ICloudLibraryCoordinator()
  var enabled: Bool {
    didSet { UserDefaults.standard.set(enabled, forKey: "iCloudLibraryEnabled") }
  }
  private(set) var isSyncing = false
  private(set) var status = "Not synced yet"
  private(set) var lastSync: Date?
  private(set) var recoveryBackup: URL?
  private(set) var conflicts: [CloudConflict] = []
  private(set) var conflictBackup: URL?
  private let transport: any ICloudLibraryTransporting
  private let coordinator: MosaicOperationCoordinator
  private let directory: URL
  private convenience init() {
    self.init(
      transport: ICloudLibraryTransport(),
      directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Mosaic/iCloud", isDirectory: true),
      enabled: UserDefaults.standard.bool(forKey: "iCloudLibraryEnabled"))
  }

  init(
    transport: any ICloudLibraryTransporting, directory: URL, enabled: Bool,
    coordinator: MosaicOperationCoordinator = .shared
  ) {
    self.coordinator = coordinator
    self.transport = transport
    self.directory = directory
    self.enabled = enabled
  }

  func sync(in context: ModelContext) async {
    guard enabled, !isSyncing, !coordinator.isSourceAccessBlocked,
      coordinator.activeOperations.isEmpty
    else { return }
    isSyncing = true
    status = "Checking iCloud…"
    defer { isSyncing = false }
    do {
      let account = try await transport.account()
      let directory = directory
      var state = try await Task.detached {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("device-state.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
          return CloudDeviceState(accountID: account)
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 768 * 1_024 * 1_024 else { throw MosaicPortableBackupError.malformedEnvelope }
        let existing = try JSONDecoder().decode(CloudDeviceState.self, from: Data(contentsOf: url))
        guard existing.version == 1, existing.accountID == account else {
          throw ChatAttachmentFailure(
            message:
              "This device library is linked to a different iCloud account. Sign back into that account. Your local data has not been uploaded to the new account."
          )
        }
        return existing
      }.value
      recoveryBackup = try await Task.detached { try Self.backups(in: directory).first }.value
      guard enabled,
        let captured = try await MosaicPortableBackup.captureBackgroundSyncSnapshot(
          from: context, coordinator: coordinator)
      else { return }
      let local = captured.snapshot
      state = try await Task.detached { [state] in
        var next = state
        try next.observe(local)
        try Self.persist(next, directory: directory)
        return next
      }.value
      let remote = try await transport.fetch()
      guard enabled, try await transport.account() == account else {
        throw ChatAttachmentFailure(
          message: "iCloud account changed during sync. Please try again.")
      }
      try await Task.detached {
        var validator = CloudDeviceState(accountID: account)
        try validator.merge(remote)
      }.value
      let pending = await Task.detached { [state] in state.conflicts(with: remote) }.value
      if !pending.isEmpty {
        let backup = directory.appendingPathComponent("Conflict-local.mosaicbackup")
        try await Task.detached {
          try MosaicPortableBackup.encode(snapshot: local).write(to: backup, options: .atomic)
          try JSONEncoder().encode(remote).write(
            to: directory.appendingPathComponent("Conflict-cloud.json"), options: .atomic)
        }.value
        conflictBackup = backup
        conflicts = pending
        status = "Choose which version to keep for \(pending.count) conflicting items"
        return
      }
      conflicts = []
      try state.applyResolutions(for: remote)
      let observedState = state
      let result = try await Task.detached {
        var next = observedState
        try next.merge(remote)
        let merged = try CloudLibraryMerge.snapshot(next.envelope, local: local)
        let records = try CloudLibraryMerge.records(merged)
        let needsChange = try CloudLibraryMerge.records(local) != records
        return (next, merged, records, needsChange)
      }.value
      state = result.0
      let merged = result.1
      let mergedRecords = result.2
      let needsLocalChange = result.3
      let plan =
        needsLocalChange
        ? try await MosaicPortableBackup.prepareSyncAsync(snapshot: merged) : nil
      guard enabled, !Task.isCancelled else { return }
      guard try await transport.account() == account else {
        throw ChatAttachmentFailure(message: "iCloud account changed. Sync stopped.")
      }
      status = "Syncing…"
      // Network and journal work never own the UI's exclusive maintenance lease.
      if state.envelope.entries != remote.entries { try await transport.save(state.envelope) }
      let uploadedState = state
      try await Task.detached { try Self.persist(uploadedState, directory: directory) }.value
      if let plan {
        let backup = directory.appendingPathComponent(
          "Before-iCloud-sync-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).mosaicbackup"
        )
        try await Task.detached {
          try MosaicPortableBackup.encode(snapshot: local).write(to: backup, options: .atomic)
        }.value
        recoveryBackup = backup
        // Only an actual incoming change reserves replacement. A newer local edit wins the
        // opportunity to keep working; re-merge it on the next pass rather than overwriting it.
        guard enabled, !Task.isCancelled, !context.hasChanges,
          coordinator.sourceActivityRevision == captured.revision,
          coordinator.beginVerifiedSourceSnapshotMaintenance()
        else {
          status = "Changes saved locally; syncing on the next pass"
          return
        }
        do {
          defer { coordinator.endExclusiveMaintenance() }
          state.pendingAppliedRecords = mergedRecords
          let committedState = state
          try await Task.detached { try Self.persist(committedState, directory: directory) }.value
          try await MosaicPortableBackup.replaceLiveStoreAsync(using: plan, in: context)
          coordinator.markSourceStoreReplaced()
        }
        try? await SemanticIndexStore.clearAllAsync()
      }
      state.pendingAppliedRecords = nil
      state.observed = mergedRecords
      state.acknowledged = state.envelope.entries.mapValues(\.revision)
      let finishedState = state
      try await Task.detached { try Self.persist(finishedState, directory: directory) }.value
      try await Task.detached {
        for old in try Self.backups(in: directory).dropFirst(10) {
          try? FileManager.default.removeItem(at: old)
        }
      }.value
      lastSync = .now
      status = "Up to date"
    } catch {
      if let backupError = error as? MosaicPortableBackupError,
        backupError == .liveStoreRecoveryFailed
      {
        coordinator.markSourceStoreUnavailable()
      }
      status = "Sync paused: " + error.localizedDescription
    }
  }
  func resolve(_ conflict: CloudConflict, useLocal: Bool, in context: ModelContext) async {
    guard !isSyncing, conflicts.contains(where: { $0.id == conflict.id }) else { return }
    isSyncing = true
    do {
      let account = try await transport.account()
      let directory = directory
      try await Task.detached {
        let file = directory.appendingPathComponent("device-state.json")
        var state = try JSONDecoder().decode(CloudDeviceState.self, from: Data(contentsOf: file))
        guard state.accountID == account else { throw MosaicPortableBackupError.malformedEnvelope }
        if state.resolutions == nil { state.resolutions = [:] }
        state.resolutions?[conflict.key] = CloudConflictResolution(
          local: conflict.local, remote: conflict.remote, useLocal: useLocal)
        try Self.persist(state, directory: directory)
      }.value
      conflicts.removeAll { $0.id == conflict.id }
    } catch { status = "Could not save choice: " + error.localizedDescription }
    isSyncing = false
    if conflicts.isEmpty { await sync(in: context) }
  }
  nonisolated private static func backups(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter {
        $0.lastPathComponent.hasPrefix("Before-iCloud-sync-") && $0.pathExtension == "mosaicbackup"
      }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }
  nonisolated private static func persist(_ state: CloudDeviceState, directory: URL) throws {
    let data = try JSONEncoder().encode(state)
    try data.write(to: directory.appendingPathComponent("device-state.json"), options: .atomic)
  }
}

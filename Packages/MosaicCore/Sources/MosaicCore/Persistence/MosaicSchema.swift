import CoreData
import Foundation
import Observation
import SwiftData

/// The exact source-of-truth schema shipped before normalized request receipts were introduced.
/// Keep this list frozen so an existing unversioned Mosaic store can be recognized as V1.
public enum MosaicSchemaV1: VersionedSchema {
  public static let versionIdentifier = Schema.Version(1, 0, 0)

  public static var models: [any PersistentModel.Type] {
    [
      ConversationRecord.self,
      MessageRecord.self,
      MemoryRecord.self,
      ScheduledTaskRecord.self,
      ProviderConfigurationRecord.self,
      EmbeddingProfileRecord.self,
      ImportedDocumentRecord.self,
      DocumentChunkRecord.self,
    ]
  }
}

/// V2 adds only new tables. Legacy receipt/snapshot blobs intentionally remain in the model for
/// dual-read rollback while a resumable application-level backfill creates normalized records.
public enum MosaicSchemaV2: VersionedSchema {
  public static let versionIdentifier = Schema.Version(2, 0, 0)

  public static var models: [any PersistentModel.Type] {
    MosaicSchemaV1.models + [
      RequestContextEventRecord.self,
      CompactionArtifactRecord.self,
      ConversationCompactionHeadRecord.self,
      NormalizedContextBackfillProgressRecord.self,
    ]
  }
}

/// V3 adds provider-neutral automatic-memory heads and immutable provenance/audit tables. Existing
/// V1/V2 models stay byte-for-byte unchanged so historical stores retain their original hashes.
public enum MosaicSchemaV3: VersionedSchema {
  public static let versionIdentifier = Schema.Version(3, 0, 0)

  public static var models: [any PersistentModel.Type] {
    MosaicSchemaV2.models + [
      MemoryTopicRecord.self,
      MemoryEvidenceRecord.self,
      MemoryRevisionRecord.self,
      MemoryFormationJobRecord.self,
    ]
  }
}

/// V4 adds project/workspace scoping and durable formation-attempt telemetry exclusively through
/// additive sidecar tables. V1-V3 model types remain unchanged, preserving their store hashes.
public enum MosaicSchemaV4: VersionedSchema {
  public static let versionIdentifier = Schema.Version(4, 0, 0)

  public static var models: [any PersistentModel.Type] {
    MosaicSchemaV3.models + [
      ProjectRecord.self,
      ProjectResourceBindingRecord.self,
      MemoryFormationAuditRecord.self,
    ]
  }
}

public enum MosaicSchemaV5: VersionedSchema {
  public static let versionIdentifier = Schema.Version(5, 0, 0)
  public static var models: [any PersistentModel.Type] {
    MosaicSchemaV4.models + [ProviderModelRecord.self, ScheduledTaskModelRecord.self]
  }
}

public enum MosaicSchemaV6: VersionedSchema {
  public static let versionIdentifier = Schema.Version(6, 0, 0)
  public static var models: [any PersistentModel.Type] {
    MosaicSchemaV5.models + [ExperienceRecord.self]
  }
}

public enum MosaicSchemaMigrationPlan: SchemaMigrationPlan {
  public static var schemas: [any VersionedSchema.Type] {
    [
      MosaicSchemaV1.self, MosaicSchemaV2.self, MosaicSchemaV3.self, MosaicSchemaV4.self,
      MosaicSchemaV5.self, MosaicSchemaV6.self,
    ]
  }

  public static var stages: [MigrationStage] {
    [
      .lightweight(fromVersion: MosaicSchemaV1.self, toVersion: MosaicSchemaV2.self),
      .lightweight(fromVersion: MosaicSchemaV2.self, toVersion: MosaicSchemaV3.self),
      .lightweight(fromVersion: MosaicSchemaV3.self, toVersion: MosaicSchemaV4.self),
      .lightweight(fromVersion: MosaicSchemaV4.self, toVersion: MosaicSchemaV5.self),
      .lightweight(fromVersion: MosaicSchemaV5.self, toVersion: MosaicSchemaV6.self),
    ]
  }
}

private struct MosaicActiveStorePointer: Codable, Sendable {
  static let currentFormatVersion = 1

  let formatVersion: Int
  let generationID: UUID
}

enum MosaicStoreLocationError: LocalizedError, Equatable, Sendable {
  case invalidActiveStorePointer
  case missingActiveStoreGeneration(UUID)

  var errorDescription: String? {
    switch self {
    case .invalidActiveStorePointer:
      "Turing AI could not verify the active local-library pointer. Restore a portable backup to create a new verified library generation."
    case .missingActiveStoreGeneration:
      "Turing AI could not find the active local-library generation. Restore a portable backup to create a new verified library generation."
    }
  }
}

@MainActor
public enum MosaicSchema {
  static let libraryDirectoryName = "Mosaic"
  fileprivate static let dedicatedStoreFilename = "Mosaic.store"
  fileprivate static let activeStorePointerFilename = "ActiveStore.json"
  fileprivate static let storeGenerationsDirectoryName = "StoreGenerations"
  private static let maximumActiveStorePointerBytes = 4 * 1_024

  public static var schema: Schema {
    Schema(versionedSchema: MosaicSchemaV6.self)
  }

  public static func makeModelContainer(
    inMemory: Bool = false,
    storeURL: URL? = nil
  ) throws -> ModelContainer {
    try makeModelContainer(
      inMemory: inMemory,
      storeURL: storeURL,
      applicationSupportDirectory: nil
    )
  }

  /// Testable disk-store entry point. Production callers resolve their platform's Application
  /// Support directory; tests inject an isolated equivalent so they never inspect or mutate the
  /// user's real library.
  static func makeModelContainer(
    inMemory: Bool = false,
    storeURL: URL? = nil,
    applicationSupportDirectory: URL?
  ) throws -> ModelContainer {
    precondition(storeURL == nil || !inMemory, "A disk URL cannot be used for an in-memory store.")
    let configuration: ModelConfiguration
    if let storeURL {
      configuration = ModelConfiguration(
        "Mosaic",
        schema: schema,
        url: storeURL,
        cloudKitDatabase: .none
      )
    } else if inMemory {
      configuration = ModelConfiguration(
        schema: schema,
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
      )
    } else {
      let applicationSupport = try resolvedApplicationSupportDirectory(
        applicationSupportDirectory
      )
      let directory = libraryDirectory(in: applicationSupport)
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let dedicatedStoreURL = directory.appendingPathComponent(dedicatedStoreFilename)
      let selectedStoreURL = try selectedStoreURL(
        dedicatedStoreURL: dedicatedStoreURL,
        legacyStoreURL: applicationSupport.appendingPathComponent("default.store"),
        libraryDirectory: directory
      )
      configuration = ModelConfiguration(
        "Mosaic",
        schema: schema,
        url: selectedStoreURL,
        cloudKitDatabase: .none
      )
    }
    return try makeContainer(configuration: configuration)
  }

  fileprivate static func resolvedApplicationSupportDirectory(
    _ applicationSupportDirectory: URL?
  ) throws -> URL {
    if let applicationSupportDirectory {
      return applicationSupportDirectory
    }
    return try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
  }

  fileprivate static func libraryDirectory(in applicationSupportDirectory: URL) -> URL {
    applicationSupportDirectory.appendingPathComponent(libraryDirectoryName, isDirectory: true)
  }

  fileprivate static func generationDirectory(
    id: UUID,
    in applicationSupportDirectory: URL
  ) -> URL {
    libraryDirectory(in: applicationSupportDirectory)
      .appendingPathComponent(storeGenerationsDirectoryName, isDirectory: true)
      .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }

  fileprivate static func generationStoreURL(
    id: UUID,
    in applicationSupportDirectory: URL
  ) -> URL {
    generationDirectory(id: id, in: applicationSupportDirectory)
      .appendingPathComponent(dedicatedStoreFilename)
  }

  fileprivate static func activeStorePointerURL(
    in applicationSupportDirectory: URL
  ) -> URL {
    libraryDirectory(in: applicationSupportDirectory)
      .appendingPathComponent(activeStorePointerFilename)
  }

  private static func makeContainer(configuration: ModelConfiguration) throws -> ModelContainer {
    let container = try ModelContainer(
      for: schema,
      migrationPlan: MosaicSchemaMigrationPlan.self,
      configurations: [configuration]
    )
    // Source writes are committed explicitly through MosaicOperationCoordinator so the exclusive
    // recovery lease cannot be bypassed by an automatic save from another window.
    container.mainContext.autosaveEnabled = false
    return container
  }

  /// Earlier builds relied on SwiftData's generic `default.store` filename. A readable store with
  /// Mosaic's exact V1/V2 entity set or its strong original core signature remains at that URL and
  /// is opened through the migration plan. Moving a potentially large live store is deferred to an
  /// explicit asynchronous workflow. A readable foreign store is ignored; an unreadable store
  /// fails closed so a real Mosaic library can never be silently shadowed by a new empty store.
  private static func selectedStoreURL(
    dedicatedStoreURL: URL,
    legacyStoreURL: URL,
    libraryDirectory: URL
  ) throws -> URL {
    let fileManager = FileManager.default
    let activeStorePointerURL = libraryDirectory.appendingPathComponent(
      activeStorePointerFilename
    )
    if fileManager.fileExists(atPath: activeStorePointerURL.path) {
      return try activeGenerationStoreURL(
        pointerURL: activeStorePointerURL,
        libraryDirectory: libraryDirectory
      )
    }
    guard !fileManager.fileExists(atPath: dedicatedStoreURL.path) else {
      return dedicatedStoreURL
    }
    guard fileManager.fileExists(atPath: legacyStoreURL.path) else {
      return dedicatedStoreURL
    }

    let legacyEntityNames = try modelEntityNames(at: legacyStoreURL)
    let knownEntityNameSets = [
      Set(Schema(MosaicSchemaV1.models).entities.map(\.name)),
      Set(Schema(MosaicSchemaV2.models).entities.map(\.name)),
      Set(schema.entities.map(\.name)),
    ]
    // Mosaic's first shipped store contained these five entities. Treat that strong signature as
    // potentially Mosaic even when later releases added entities or changed version hashes. The
    // migration plan then makes the authoritative compatibility decision and fails closed for an
    // unsupported historical revision instead of hiding it behind a new empty library.
    let mosaicCoreEntityNames = Set(
      Schema([
        ConversationRecord.self,
        MessageRecord.self,
        MemoryRecord.self,
        ScheduledTaskRecord.self,
        ProviderConfigurationRecord.self,
      ]).entities.map(\.name)
    )
    let appearsToBeMosaic =
      knownEntityNameSets.contains(legacyEntityNames)
      || mosaicCoreEntityNames.isSubset(of: legacyEntityNames)
    return appearsToBeMosaic
      ? legacyStoreURL
      : dedicatedStoreURL
  }

  private static func activeGenerationStoreURL(
    pointerURL: URL,
    libraryDirectory: URL
  ) throws -> URL {
    let fileManager = FileManager.default
    let pointer = try activeStorePointer(at: pointerURL)

    let storeURL =
      libraryDirectory
      .appendingPathComponent(storeGenerationsDirectoryName, isDirectory: true)
      .appendingPathComponent(pointer.generationID.uuidString.lowercased(), isDirectory: true)
      .appendingPathComponent(dedicatedStoreFilename)
    guard fileManager.fileExists(atPath: storeURL.path) else {
      throw MosaicStoreLocationError.missingActiveStoreGeneration(pointer.generationID)
    }
    return storeURL
  }

  fileprivate static func activeStoreGenerationID(
    in applicationSupportDirectory: URL
  ) throws -> UUID? {
    let pointerURL = activeStorePointerURL(in: applicationSupportDirectory)
    guard FileManager.default.fileExists(atPath: pointerURL.path) else { return nil }
    return try activeStorePointer(at: pointerURL).generationID
  }

  private static func activeStorePointer(at pointerURL: URL) throws -> MosaicActiveStorePointer {
    guard
      let size = try? pointerURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= maximumActiveStorePointerBytes,
      let data = try? Data(contentsOf: pointerURL),
      let pointer = try? JSONDecoder().decode(MosaicActiveStorePointer.self, from: data),
      pointer.formatVersion == MosaicActiveStorePointer.currentFormatVersion
    else {
      throw MosaicStoreLocationError.invalidActiveStorePointer
    }
    return pointer
  }

  static func activateStoreGeneration(
    id: UUID,
    in applicationSupportDirectory: URL
  ) throws {
    let libraryDirectory = libraryDirectory(in: applicationSupportDirectory)
    try FileManager.default.createDirectory(
      at: libraryDirectory,
      withIntermediateDirectories: true
    )
    let storeURL = generationStoreURL(id: id, in: applicationSupportDirectory)
    guard FileManager.default.fileExists(atPath: storeURL.path) else {
      throw MosaicStoreLocationError.missingActiveStoreGeneration(id)
    }
    let pointer = MosaicActiveStorePointer(
      formatVersion: MosaicActiveStorePointer.currentFormatVersion,
      generationID: id
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(pointer)
    guard data.count <= maximumActiveStorePointerBytes else {
      throw MosaicStoreLocationError.invalidActiveStorePointer
    }
    try data.write(
      to: activeStorePointerURL(in: applicationSupportDirectory),
      options: .atomic
    )
  }

  private static func modelEntityNames(at storeURL: URL) throws -> Set<String> {
    let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
      type: .sqlite,
      at: storeURL,
      options: [NSReadOnlyPersistentStoreOption: true]
    )
    guard let hashes = metadata[NSStoreModelVersionHashesKey] as? [String: Data] else {
      throw CocoaError(.persistentStoreIncompatibleVersionHash)
    }
    return Set(hashes.keys)
  }
}

public struct MosaicStoreFailure: Identifiable, Hashable, Sendable {
  public let id: UUID
  public let diagnosticCode: String

  public init(id: UUID = UUID(), diagnosticCode: String) {
    self.id = id
    self.diagnosticCode = diagnosticCode
  }

  init(error: Error) {
    let error = error as NSError
    self.init(diagnosticCode: "\(error.domain) (\(error.code))")
  }
}

public enum MosaicStoreLaunch {
  case ready(ModelContainer)
  case recovery(MosaicStoreFailure)

  public var isReady: Bool {
    if case .ready = self { return true }
    return false
  }
}

public enum MosaicLaunchRecoveryError: LocalizedError, Equatable, Sendable {
  case restoreAlreadyInProgress

  public var errorDescription: String? {
    switch self {
    case .restoreAlreadyInProgress:
      "Another Turing AI window is already restoring a backup. Wait for it to finish."
    }
  }
}

/// A process-wide launch-recovery lease shared by every scene. macOS can render the recovery
/// surface in both a WindowGroup and Settings, so view-local progress flags alone cannot prevent
/// two independently selected backups from racing to replace the active-generation pointer.
@Observable
@MainActor
public final class MosaicLaunchRecoveryCoordinator {
  public static let shared = MosaicLaunchRecoveryCoordinator()

  public private(set) var isRestoring = false

  public init() {}

  func perform<Result>(_ operation: () async throws -> Result) async throws -> Result {
    guard !isRestoring else {
      throw MosaicLaunchRecoveryError.restoreAlreadyInProgress
    }
    isRestoring = true
    defer { isRestoring = false }
    return try await operation()
  }
}

/// App-facing store opener used by both platform entry points. A source-of-truth store failure
/// never falls back to a disposable in-memory database and never terminates the process.
@MainActor
public enum MosaicModelContainer {
  public static func open(inMemory: Bool = false) -> MosaicStoreLaunch {
    open {
      try MosaicSchema.makeModelContainer(inMemory: inMemory)
    }
  }

  static func open(using opener: () throws -> ModelContainer) -> MosaicStoreLaunch {
    do {
      return .ready(try opener())
    } catch {
      return .recovery(MosaicStoreFailure(error: error))
    }
  }
}

/// Creates a fresh, fully verified store generation from a portable backup when the currently
/// selected SwiftData store cannot be opened. The failed store family is never moved, truncated, or
/// deleted. A small pointer is atomically updated only after the replacement generation has been
/// staged, saved, and read back successfully.
@MainActor
public enum MosaicLaunchRecovery {
  public static func restorePortableBackup(
    at url: URL,
    inMemory: Bool = false,
    recoveryCoordinator: MosaicLaunchRecoveryCoordinator = .shared,
    afterActivation: @escaping @MainActor (ModelContainer) async -> Void = { _ in }
  ) async throws -> ModelContainer {
    try await recoveryCoordinator.perform {
      let data = try await MosaicLaunchRecoveryFileReader.shared.read(url)
      let container = try await restorePortableBackupWithoutLease(
        from: data,
        inMemory: inMemory,
        applicationSupportDirectory: nil
      )
      await afterActivation(container)
      return container
    }
  }

  static func restorePortableBackup(
    from data: Data,
    inMemory: Bool = false,
    applicationSupportDirectory: URL?,
    recoveryCoordinator: MosaicLaunchRecoveryCoordinator = .shared,
    activateStoreGeneration: (UUID, URL) throws -> Void = { id, applicationSupport in
      try MosaicSchema.activateStoreGeneration(id: id, in: applicationSupport)
    }
  ) async throws -> ModelContainer {
    try await recoveryCoordinator.perform {
      try await restorePortableBackupWithoutLease(
        from: data,
        inMemory: inMemory,
        applicationSupportDirectory: applicationSupportDirectory,
        activateStoreGeneration: activateStoreGeneration
      )
    }
  }

  private static func restorePortableBackupWithoutLease(
    from data: Data,
    inMemory: Bool,
    applicationSupportDirectory: URL?,
    activateStoreGeneration: (UUID, URL) throws -> Void = { id, applicationSupport in
      try MosaicSchema.activateStoreGeneration(id: id, in: applicationSupport)
    }
  ) async throws -> ModelContainer {
    let plan = try await MosaicPortableBackup.prepareRestoreAsync(from: data)
    try Task.checkCancellation()

    if inMemory {
      let container = try MosaicSchema.makeModelContainer(inMemory: true)
      try await MosaicPortableBackup.replaceLiveStoreAsync(
        using: plan,
        in: container.mainContext
      )
      return container
    }

    let applicationSupport = try MosaicSchema.resolvedApplicationSupportDirectory(
      applicationSupportDirectory
    )
    var generationID = UUID()
    var generationDirectory = MosaicSchema.generationDirectory(
      id: generationID,
      in: applicationSupport
    )
    while FileManager.default.fileExists(atPath: generationDirectory.path) {
      generationID = UUID()
      generationDirectory = MosaicSchema.generationDirectory(
        id: generationID,
        in: applicationSupport
      )
    }
    var didActivateGeneration = false
    var stagedContainer: ModelContainer?
    defer {
      if !didActivateGeneration {
        stagedContainer = nil
        // `generationDirectory` was proven absent before this attempt, so this cleanup can never
        // target the original source or a generation created by another restore. If an unusual
        // filesystem failure reports an error after committing the atomic pointer, retain the now
        // selected generation rather than creating a dangling pointer.
        let selectedGenerationID = try? MosaicSchema.activeStoreGenerationID(
          in: applicationSupport
        )
        if selectedGenerationID != generationID {
          try? FileManager.default.removeItem(at: generationDirectory)
        }
      }
    }
    try FileManager.default.createDirectory(
      at: generationDirectory,
      withIntermediateDirectories: true
    )
    let storeURL = MosaicSchema.generationStoreURL(
      id: generationID,
      in: applicationSupport
    )
    stagedContainer = try MosaicSchema.makeModelContainer(storeURL: storeURL)
    try await MosaicPortableBackup.replaceLiveStoreAsync(
      using: plan,
      in: stagedContainer!.mainContext
    )

    // This is the only commit point. Before it, the failed source remains selected and untouched;
    // after the atomic pointer write, every future launch selects the verified generation above.
    try activateStoreGeneration(generationID, applicationSupport)
    didActivateGeneration = true
    return stagedContainer!
  }
}

private actor MosaicLaunchRecoveryFileReader {
  static let shared = MosaicLaunchRecoveryFileReader()

  func read(_ url: URL) throws -> Data {
    try Task.checkCancellation()
    let maximumBytes = MosaicPortableBackupLimits.default.maximumTotalBytes
    let hasScopedAccess = url.startAccessingSecurityScopedResource()
    defer {
      if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
    }

    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile != false else {
      throw CocoaError(.fileReadCorruptFile)
    }
    if let fileSize = values.fileSize, fileSize > maximumBytes {
      throw MosaicPortableBackupError.backupTooLarge(
        actual: fileSize,
        maximum: maximumBytes
      )
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = Data()
    data.reserveCapacity(min(values.fileSize ?? 0, maximumBytes))
    while true {
      try Task.checkCancellation()
      let remaining = maximumBytes - data.count
      let chunk = try handle.read(upToCount: min(1_048_576, remaining + 1)) ?? Data()
      guard !chunk.isEmpty else { break }
      guard chunk.count <= remaining else {
        throw MosaicPortableBackupError.backupTooLarge(
          actual: data.count + chunk.count,
          maximum: maximumBytes
        )
      }
      data.append(chunk)
    }
    return data
  }
}

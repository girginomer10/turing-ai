import Foundation
import SwiftData

enum ProviderModelsPortableArchive {
  static let namespace = "com.omergirgin.mosaic.models"

  private struct Payload: Codable {
    let id: UUID
    var providerID: UUID
    let modelIdentifier: String
    let enabled: Bool?
    let contextWindow: Int?
    let maximumOutput: Int?
  }

  static func isOwned(_ record: MosaicPortableExtensionRecord) -> Bool {
    record.namespace == namespace
  }

  private static func encode(_ payload: Payload, type: String) throws
    -> MosaicPortableExtensionRecord
  {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return MosaicPortableExtensionRecord(
      namespace: namespace, recordType: type, recordVersion: 1,
      id: payload.id, payload: try encoder.encode(payload))
  }

  private static func decode(_ record: MosaicPortableExtensionRecord) throws -> Payload {
    guard isOwned(record), record.recordVersion == 1,
      record.recordType == "provider_model" || record.recordType == "task_model"
    else {
      throw MosaicPortableBackupError.unsupportedExtensionRecord(
        namespace: record.namespace,
        recordType: record.recordType, version: record.recordVersion)
    }
    let payload = try JSONDecoder().decode(Payload.self, from: record.payload)
    guard payload.id == record.id, !payload.modelIdentifier.isEmpty,
      payload.modelIdentifier
        == payload.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
      payload.modelIdentifier.utf8.count <= 2_048,
      !payload.modelIdentifier.contains(where: { $0.isNewline }),
      (record.recordType == "provider_model") == (payload.enabled != nil),
      payload.contextWindow.map({ ProviderRequestLimitPolicy.contextWindowRange.contains($0) })
        ?? true,
      payload.maximumOutput.map({ $0 > 0 && $0 <= (payload.contextWindow ?? 16_777_216) }) ?? true
    else {
      throw MosaicPortableBackupError.invalidNormalizedInvariant(
        recordType: record.recordType, id: record.id, field: "model")
    }
    return payload
  }

  static func capture(
    from context: ModelContext, includesPendingChanges: Bool,
    limits: MosaicPortableBackupLimits, honorsCancellation: Bool = true
  ) throws -> [MosaicPortableExtensionRecord] {
    var result: [MosaicPortableExtensionRecord] = []
    var bytes = 0
    func append(_ payload: Payload, type: String) throws {
      if honorsCancellation { try Task.checkCancellation() }
      let record = try encode(payload, type: type)
      bytes += record.payload.count
      guard record.payload.count <= limits.maximumRecordBytes else {
        throw MosaicPortableBackupError.recordTooLarge(
          recordType: type, id: payload.id,
          actual: record.payload.count, maximum: limits.maximumRecordBytes)
      }
      guard bytes <= limits.maximumTotalBytes else {
        throw MosaicPortableBackupError.backupTooLarge(
          actual: bytes, maximum: limits.maximumTotalBytes)
      }
      result.append(record)
      guard result.count <= limits.maximumRecordCount else {
        throw MosaicPortableBackupError.tooManyRecords(
          actual: result.count, maximum: limits.maximumRecordCount)
      }
    }
    var offset = 0
    while true {
      var descriptor = FetchDescriptor<ProviderModelRecord>(sortBy: [
        SortDescriptor(\ProviderModelRecord.id)
      ])
      descriptor.fetchOffset = offset
      descriptor.fetchLimit = 64
      descriptor.includePendingChanges = includesPendingChanges
      let records = try context.fetch(descriptor)
      for record in records {
        try append(
          Payload(
            id: record.id, providerID: record.providerConfigurationID,
            modelIdentifier: record.modelIdentifier, enabled: record.isEnabled,
            contextWindow: record.contextWindowTokens, maximumOutput: record.maximumOutputTokens),
          type: "provider_model")
      }
      if records.count < 64 { break }
      offset += records.count
    }
    offset = 0
    while true {
      var descriptor = FetchDescriptor<ScheduledTaskModelRecord>(sortBy: [
        SortDescriptor(\ScheduledTaskModelRecord.taskID)
      ])
      descriptor.fetchOffset = offset
      descriptor.fetchLimit = 64
      descriptor.includePendingChanges = includesPendingChanges
      let records = try context.fetch(descriptor)
      for record in records {
        try append(
          Payload(
            id: record.taskID, providerID: record.providerConfigurationID,
            modelIdentifier: record.modelIdentifier, enabled: nil, contextWindow: nil,
            maximumOutput: nil), type: "task_model")
      }
      if records.count < 64 { break }
      offset += records.count
    }
    return result.sorted(by: MosaicPortableBackup.extensionRecordOrder)
  }

  static func validate(
    _ records: [MosaicPortableExtensionRecord], providers: Set<UUID>,
    tasks: [MosaicPortableScheduledTask]
  ) throws {
    var keys = Set<String>()
    let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    for record in records {
      let payload = try decode(record)
      let key =
        record.recordType == "provider_model"
        ? ProviderModelRecord.key(providerID: payload.providerID, model: payload.modelIdentifier)
        : payload.id.uuidString
      guard keys.insert(record.recordType + key).inserted else {
        throw MosaicPortableBackupError.duplicateKey(recordType: record.recordType, key: key)
      }
      // Task selections can intentionally reference a deleted provider, just like the task itself.
      let valid =
        record.recordType == "provider_model"
        ? providers.contains(payload.providerID)
        : tasksByID[payload.id]?.providerConfigurationID == payload.providerID
      guard valid else {
        throw MosaicPortableBackupError.invalidNormalizedInvariant(
          recordType: record.recordType, id: record.id, field: "provider_reference")
      }
    }
  }

  static func remapProviderConfigurationIDs(
    in records: [MosaicPortableExtensionRecord], using map: [UUID: UUID]
  ) throws -> [MosaicPortableExtensionRecord] {
    try records.map { record in
      var payload = try decode(record)
      payload.providerID = map[payload.providerID] ?? payload.providerID
      return try encode(payload, type: record.recordType)
    }.sorted(by: MosaicPortableBackup.extensionRecordOrder)
  }

  static func insert(
    _ records: [MosaicPortableExtensionRecord], into context: ModelContext,
    honorsCancellation: Bool = true
  ) throws {
    for record in records {
      if honorsCancellation { try Task.checkCancellation() }
      let payload = try decode(record)
      if let enabled = payload.enabled {
        context.insert(
          ProviderModelRecord(
            id: payload.id, providerConfigurationID: payload.providerID,
            modelIdentifier: payload.modelIdentifier, isEnabled: enabled,
            contextWindowTokens: payload.contextWindow, maximumOutputTokens: payload.maximumOutput))
      } else {
        context.insert(
          ScheduledTaskModelRecord(
            taskID: payload.id, providerConfigurationID: payload.providerID,
            modelIdentifier: payload.modelIdentifier))
      }
    }
  }

  static func deleteAll(from context: ModelContext, honorsCancellation: Bool = true) throws {
    if honorsCancellation { try Task.checkCancellation() }
    try context.enumerate(
      FetchDescriptor<ProviderModelRecord>(), batchSize: 64, allowEscapingMutations: true
    ) {
      if honorsCancellation { try Task.checkCancellation() }
      context.delete($0)
    }
    try context.enumerate(
      FetchDescriptor<ScheduledTaskModelRecord>(), batchSize: 64, allowEscapingMutations: true
    ) {
      if honorsCancellation { try Task.checkCancellation() }
      context.delete($0)
    }
  }
}

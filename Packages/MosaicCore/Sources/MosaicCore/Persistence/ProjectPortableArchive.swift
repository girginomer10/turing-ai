import Foundation
import SwiftData

private struct PortableProject: Codable, Hashable {
  let id: UUID
  let name: String
  let instructions: String
  let isArchived: Bool
  let createdAt: Date
  let updatedAt: Date

  init(_ record: ProjectRecord) {
    id = record.id
    name = record.name
    instructions = record.instructions
    isArchived = record.isArchived
    createdAt = record.createdAt
    updatedAt = record.updatedAt
  }

  var record: ProjectRecord {
    ProjectRecord(
      id: id,
      name: name,
      instructions: instructions,
      isArchived: isArchived,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

private struct PortableProjectResourceBinding: Codable, Hashable {
  let id: UUID
  let bindingKey: String
  let resourceKindRawValue: String
  let resourceID: UUID
  let projectID: UUID
  let createdAt: Date
  let updatedAt: Date

  init(_ record: ProjectResourceBindingRecord) {
    id = record.id
    bindingKey = record.bindingKey
    resourceKindRawValue = record.resourceKindRawValue
    resourceID = record.resourceID
    projectID = record.projectID
    createdAt = record.createdAt
    updatedAt = record.updatedAt
  }

  var record: ProjectResourceBindingRecord {
    ProjectResourceBindingRecord(
      id: id,
      resourceKind: ProjectResourceKind(rawValue: resourceKindRawValue) ?? .conversation,
      resourceID: resourceID,
      projectID: projectID,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

struct ProjectPortableMemberships: Sendable {
  let projectIDsByConversation: [UUID: UUID]
  let projectIDsByMemoryTopic: [UUID: UUID]

  static let empty = ProjectPortableMemberships(
    projectIDsByConversation: [:],
    projectIDsByMemoryTopic: [:]
  )
}

enum ProjectPortableArchive {
  static let namespace = "com.omergirgin.mosaic.project"
  static let recordVersion = 1

  private static let pageSize = 64
  private static let projectType = "project"
  private static let bindingType = "resource_binding"

  private enum Payload {
    case project(PortableProject)
    case binding(PortableProjectResourceBinding)
  }

  static func isOwned(_ record: MosaicPortableExtensionRecord) -> Bool {
    record.namespace == namespace
  }

  static func capture(
    from modelContext: ModelContext,
    includesPendingChanges: Bool,
    limits: MosaicPortableBackupLimits,
    honorsCancellation: Bool = true
  ) throws -> [MosaicPortableExtensionRecord] {
    var records: [MosaicPortableExtensionRecord] = []
    var approximateBytes = 0

    try capturePages(
      from: modelContext,
      makeDescriptor: projectDescriptor,
      key: \ProjectRecord.id,
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation
    ) { project in
      try append(
        payload: PortableProject(project),
        recordType: projectType,
        id: project.id,
        limits: limits,
        records: &records,
        approximateBytes: &approximateBytes
      )
    }
    try capturePages(
      from: modelContext,
      makeDescriptor: bindingDescriptor,
      key: \ProjectResourceBindingRecord.id,
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation
    ) { binding in
      try append(
        payload: PortableProjectResourceBinding(binding),
        recordType: bindingType,
        id: binding.id,
        limits: limits,
        records: &records,
        approximateBytes: &approximateBytes
      )
    }
    return records.sorted(by: MosaicPortableBackup.extensionRecordOrder)
  }

  @discardableResult
  static func validate(
    _ extensionRecords: [MosaicPortableExtensionRecord],
    conversationIDs: Set<UUID>,
    memories: [MosaicPortableMemory],
    automaticMemoryTopicScopes: [UUID: MemoryScope],
    documentIDs: Set<UUID>
  ) throws -> ProjectPortableMemberships {
    let payloads = try extensionRecords.map(decode)
    let projects = payloads.compactMap { payload -> PortableProject? in
      if case .project(let value) = payload { return value }
      return nil
    }
    let bindings = payloads.compactMap { payload -> PortableProjectResourceBinding? in
      if case .binding(let value) = payload { return value }
      return nil
    }

    var projectIDs: Set<UUID> = []
    for project in projects {
      guard projectIDs.insert(project.id).inserted else {
        throw MosaicPortableBackupError.duplicateID(recordType: "project", id: project.id)
      }
      try MosaicSourceFieldLimits.validateProject(
        name: project.name,
        instructions: project.instructions
      )
      guard project.createdAt <= project.updatedAt else {
        throw invalid(recordType: "project", id: project.id, field: "timestamps")
      }
    }

    var memoriesByID: [UUID: MosaicPortableMemory] = [:]
    for memory in memories {
      guard memoriesByID.updateValue(memory, forKey: memory.id) == nil else {
        throw MosaicPortableBackupError.duplicateID(recordType: "memory", id: memory.id)
      }
      if memory.scopeRawValue == MemoryScope.project.rawValue,
        memory.conversationID != nil
      {
        throw invalid(recordType: "memory", id: memory.id, field: "project_scope")
      }
    }

    var bindingIDs: Set<UUID> = []
    var bindingsByKey: [String: PortableProjectResourceBinding] = [:]
    var projectIDsByConversation: [UUID: UUID] = [:]
    var projectIDsByMemoryTopic: [UUID: UUID] = [:]
    for binding in bindings {
      guard bindingIDs.insert(binding.id).inserted else {
        throw MosaicPortableBackupError.duplicateID(
          recordType: "project_resource_binding",
          id: binding.id
        )
      }
      guard let kind = ProjectResourceKind(rawValue: binding.resourceKindRawValue) else {
        throw invalid(
          recordType: "project_resource_binding",
          id: binding.id,
          field: "resource_kind"
        )
      }
      let expectedKey = ProjectResourceBindingRecord.makeBindingKey(
        resourceKind: kind,
        resourceID: binding.resourceID
      )
      guard binding.bindingKey == expectedKey else {
        throw invalid(
          recordType: "project_resource_binding",
          id: binding.id,
          field: "binding_key"
        )
      }
      guard bindingsByKey.updateValue(binding, forKey: expectedKey) == nil else {
        throw MosaicPortableBackupError.duplicateKey(
          recordType: "project_resource_binding",
          key: expectedKey
        )
      }
      guard projectIDs.contains(binding.projectID) else {
        throw missing(
          recordType: "project_resource_binding",
          id: binding.id,
          field: "project",
          binding.projectID
        )
      }
      guard binding.createdAt <= binding.updatedAt else {
        throw invalid(
          recordType: "project_resource_binding",
          id: binding.id,
          field: "timestamps"
        )
      }

      switch kind {
      case .conversation:
        guard conversationIDs.contains(binding.resourceID) else {
          throw missingResource(binding)
        }
        projectIDsByConversation[binding.resourceID] = binding.projectID
      case .memory:
        guard let memory = memoriesByID[binding.resourceID] else {
          throw missingResource(binding)
        }
        guard memory.scopeRawValue == MemoryScope.project.rawValue,
          memory.conversationID == nil
        else {
          throw invalid(
            recordType: "project_resource_binding",
            id: binding.id,
            field: "resource_scope"
          )
        }
      case .memoryTopic:
        guard let scope = automaticMemoryTopicScopes[binding.resourceID] else {
          throw missingResource(binding)
        }
        guard scope == .project else {
          throw invalid(
            recordType: "project_resource_binding",
            id: binding.id,
            field: "resource_scope"
          )
        }
        projectIDsByMemoryTopic[binding.resourceID] = binding.projectID
      case .document:
        guard documentIDs.contains(binding.resourceID) else {
          throw missingResource(binding)
        }
      }
    }

    for memory in memories where memory.scopeRawValue == MemoryScope.project.rawValue {
      let key = ProjectResourceBindingRecord.makeBindingKey(
        resourceKind: .memory,
        resourceID: memory.id
      )
      guard bindingsByKey[key] != nil else {
        throw invalid(recordType: "memory", id: memory.id, field: "project_binding")
      }
    }
    for (topicID, scope) in automaticMemoryTopicScopes where scope == .project {
      let key = ProjectResourceBindingRecord.makeBindingKey(
        resourceKind: .memoryTopic,
        resourceID: topicID
      )
      guard bindingsByKey[key] != nil else {
        throw invalid(recordType: "memory_topic", id: topicID, field: "project_binding")
      }
    }

    return ProjectPortableMemberships(
      projectIDsByConversation: projectIDsByConversation,
      projectIDsByMemoryTopic: projectIDsByMemoryTopic
    )
  }

  /// Project records currently contain no operational provider locators. Decoding here keeps
  /// their preservation explicit in the same restore transformation that rekeys provider IDs.
  static func remapProviderConfigurationIDs(
    in extensionRecords: [MosaicPortableExtensionRecord],
    using _: [UUID: UUID]
  ) throws -> [MosaicPortableExtensionRecord] {
    _ = try extensionRecords.map(decode)
    return extensionRecords.sorted(by: MosaicPortableBackup.extensionRecordOrder)
  }

  static func insert(
    _ extensionRecords: [MosaicPortableExtensionRecord],
    into modelContext: ModelContext,
    honorsCancellation: Bool
  ) throws {
    let payloads = try extensionRecords.map(decode)
    for payload in payloads {
      if honorsCancellation { try Task.checkCancellation() }
      if case .project(let value) = payload { modelContext.insert(value.record) }
    }
    for payload in payloads {
      if honorsCancellation { try Task.checkCancellation() }
      if case .binding(let value) = payload { modelContext.insert(value.record) }
    }
  }

  static func deleteAll(
    in modelContext: ModelContext,
    honorsCancellation: Bool
  ) throws {
    try deleteAll(
      ProjectResourceBindingRecord.self,
      in: modelContext,
      honorsCancellation: honorsCancellation
    )
    try deleteAll(
      ProjectRecord.self,
      in: modelContext,
      honorsCancellation: honorsCancellation
    )
  }

  private static func decode(_ record: MosaicPortableExtensionRecord) throws -> Payload {
    guard record.namespace == namespace, record.recordVersion == recordVersion else {
      throw MosaicPortableBackupError.unsupportedExtensionRecord(
        namespace: record.namespace,
        recordType: record.recordType,
        version: record.recordVersion
      )
    }
    let decoder = JSONDecoder()
    do {
      switch record.recordType {
      case projectType:
        let payload = try decoder.decode(PortableProject.self, from: record.payload)
        guard payload.id == record.id else { throw CocoaError(.coderInvalidValue) }
        return .project(payload)
      case bindingType:
        let payload = try decoder.decode(PortableProjectResourceBinding.self, from: record.payload)
        guard payload.id == record.id else { throw CocoaError(.coderInvalidValue) }
        return .binding(payload)
      default:
        throw MosaicPortableBackupError.unsupportedExtensionRecord(
          namespace: record.namespace,
          recordType: record.recordType,
          version: record.recordVersion
        )
      }
    } catch let error as MosaicPortableBackupError {
      throw error
    } catch {
      throw invalid(recordType: "project_extension", id: record.id, field: "payload")
    }
  }

  private static func append<Payload: Encodable>(
    payload: Payload,
    recordType: String,
    id: UUID,
    limits: MosaicPortableBackupLimits,
    records: inout [MosaicPortableExtensionRecord],
    approximateBytes: inout Int
  ) throws {
    guard records.count < limits.maximumRecordCount else {
      throw MosaicPortableBackupError.tooManyRecords(
        actual: records.count + 1,
        maximum: limits.maximumRecordCount
      )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    let record = MosaicPortableExtensionRecord(
      namespace: namespace,
      recordType: recordType,
      recordVersion: recordVersion,
      id: id,
      payload: data
    )
    let encodedBytes = try encoder.encode(record).count
    guard encodedBytes <= limits.maximumRecordBytes else {
      throw MosaicPortableBackupError.recordTooLarge(
        recordType: "project_\(recordType)",
        id: id,
        actual: encodedBytes,
        maximum: limits.maximumRecordBytes
      )
    }
    let (nextBytes, overflow) = approximateBytes.addingReportingOverflow(encodedBytes)
    guard !overflow, nextBytes <= limits.maximumTotalBytes else {
      throw MosaicPortableBackupError.backupTooLarge(
        actual: overflow ? .max : nextBytes,
        maximum: limits.maximumTotalBytes
      )
    }
    approximateBytes = nextBytes
    records.append(record)
  }

  private static func capturePages<Source: PersistentModel>(
    from modelContext: ModelContext,
    makeDescriptor: (UUID?) -> FetchDescriptor<Source>,
    key: (Source) -> UUID,
    includesPendingChanges: Bool,
    honorsCancellation: Bool,
    body: (Source) throws -> Void
  ) throws {
    var cursor: UUID?
    while true {
      if honorsCancellation { try Task.checkCancellation() }
      var descriptor = makeDescriptor(cursor)
      descriptor.fetchLimit = pageSize
      descriptor.includePendingChanges = includesPendingChanges
      let page = try modelContext.fetch(descriptor)
      guard !page.isEmpty else { break }
      for source in page {
        if honorsCancellation { try Task.checkCancellation() }
        try body(source)
      }
      guard let last = page.last else { break }
      let nextCursor = key(last)
      guard cursor.map({ nextCursor > $0 }) ?? true else {
        throw MosaicPortableBackupError.persistenceFailure
      }
      cursor = nextCursor
      if page.count < pageSize { break }
    }
  }

  private static func projectDescriptor(after cursor: UUID?) -> FetchDescriptor<ProjectRecord> {
    if let cursor {
      return FetchDescriptor(
        predicate: #Predicate { $0.id > cursor },
        sortBy: [SortDescriptor(\ProjectRecord.id)]
      )
    }
    return FetchDescriptor(sortBy: [SortDescriptor(\ProjectRecord.id)])
  }

  private static func bindingDescriptor(
    after cursor: UUID?
  ) -> FetchDescriptor<ProjectResourceBindingRecord> {
    if let cursor {
      return FetchDescriptor(
        predicate: #Predicate { $0.id > cursor },
        sortBy: [SortDescriptor(\ProjectResourceBindingRecord.id)]
      )
    }
    return FetchDescriptor(sortBy: [SortDescriptor(\ProjectResourceBindingRecord.id)])
  }

  private static func deleteAll<T: PersistentModel>(
    _ type: T.Type,
    in modelContext: ModelContext,
    honorsCancellation: Bool
  ) throws {
    let descriptor = FetchDescriptor<T>()
    try modelContext.enumerate(
      descriptor,
      batchSize: pageSize,
      allowEscapingMutations: true
    ) { record in
      if honorsCancellation { try Task.checkCancellation() }
      modelContext.delete(record)
    }
  }

  private static func missingResource(
    _ binding: PortableProjectResourceBinding
  ) -> MosaicPortableBackupError {
    missing(
      recordType: "project_resource_binding",
      id: binding.id,
      field: "resource",
      binding.resourceID
    )
  }

  private static func missing(
    recordType: String,
    id: UUID,
    field: String,
    _ targetID: UUID
  ) -> MosaicPortableBackupError {
    .missingNormalizedReference(
      recordType: recordType,
      id: id,
      field: field,
      targetID: targetID
    )
  }

  private static func invalid(
    recordType: String,
    id: UUID,
    field: String
  ) -> MosaicPortableBackupError {
    .invalidNormalizedInvariant(recordType: recordType, id: id, field: field)
  }
}

import Foundation
import SwiftData

/// A named local workspace. Projects never own provider credentials; they only scope local
/// conversations, memories, and documents before Mosaic builds a provider request.
@Model
public final class ProjectRecord {
  @Attribute(.unique) public var id: UUID
  public var name: String
  public var instructions: String
  public var isArchived: Bool
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    instructions: String = "",
    isArchived: Bool = false,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.name = name
    self.instructions = instructions
    self.isArchived = isArchived
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var snapshot: MosaicProjectSnapshot {
    MosaicProjectSnapshot(
      id: id,
      name: name,
      instructions: instructions,
      isArchived: isArchived,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

/// Additive sidecar association used instead of changing historical V1-V3 models. The unique
/// binding key enforces one-project-per-resource while preserving old SwiftData version hashes.
@Model
public final class ProjectResourceBindingRecord {
  @Attribute(.unique) public var id: UUID
  @Attribute(.unique) public var bindingKey: String
  public var resourceKindRawValue: String
  public var resourceID: UUID
  public var projectID: UUID
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    resourceKind: ProjectResourceKind,
    resourceID: UUID,
    projectID: UUID,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    bindingKey = Self.makeBindingKey(resourceKind: resourceKind, resourceID: resourceID)
    resourceKindRawValue = resourceKind.rawValue
    self.resourceID = resourceID
    self.projectID = projectID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var resourceKind: ProjectResourceKind {
    get { ProjectResourceKind(rawValue: resourceKindRawValue) ?? .conversation }
    set {
      resourceKindRawValue = newValue.rawValue
      bindingKey = Self.makeBindingKey(resourceKind: newValue, resourceID: resourceID)
    }
  }

  public var snapshot: ProjectResourceBindingSnapshot {
    ProjectResourceBindingSnapshot(
      id: id,
      resourceKind: resourceKind,
      resourceID: resourceID,
      projectID: projectID,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }

  public func move(to projectID: UUID, at date: Date = .now) {
    self.projectID = projectID
    updatedAt = date
  }

  public static func makeBindingKey(
    resourceKind: ProjectResourceKind,
    resourceID: UUID
  ) -> String {
    "\(resourceKind.rawValue):\(resourceID.uuidString.lowercased())"
  }
}

enum ProjectBindingError: Error, Equatable, LocalizedError, Sendable {
  case projectUnavailable(UUID)
  case invalidResource
  case danglingBinding(UUID)
  case invalidAutomaticMemoryAudience(UUID)
  case mixedAutomaticMemoryEvidence(UUID)
  case automaticMemoryCanonicalConflict(UUID)
  case staleConversationAssignment(UUID)
  case staleProjectEdit(UUID)

  var errorDescription: String? {
    switch self {
    case .projectUnavailable:
      "The selected project is no longer available. Choose another project."
    case .invalidResource:
      "This item can no longer be assigned to a project."
    case .danglingBinding:
      "A project assignment points to an item that is no longer available."
    case .invalidAutomaticMemoryAudience:
      "Automatic memory provenance does not match its project audience."
    case .mixedAutomaticMemoryEvidence:
      "This chat shares an automatic project memory with another chat. Resolve that memory before moving the chat."
    case .automaticMemoryCanonicalConflict:
      "The destination already contains an automatic memory for the same topic."
    case .staleConversationAssignment:
      "This chat's project changed in another window. Refresh and try again."
    case .staleProjectEdit:
      "This project changed in another window or after a library restore. Close the editor and try again."
    }
  }
}

enum ProjectBindingStore {
  static func binding(
    resourceKind: ProjectResourceKind,
    resourceID: UUID,
    in modelContext: ModelContext,
    includesPendingChanges: Bool = true
  ) throws -> ProjectResourceBindingRecord? {
    let key = ProjectResourceBindingRecord.makeBindingKey(
      resourceKind: resourceKind,
      resourceID: resourceID
    )
    var descriptor = FetchDescriptor<ProjectResourceBindingRecord>(
      predicate: #Predicate { $0.bindingKey == key }
    )
    descriptor.fetchLimit = 1
    descriptor.includePendingChanges = includesPendingChanges
    return try modelContext.fetch(descriptor).first
  }

  @discardableResult
  static func assign(
    resourceKind: ProjectResourceKind,
    resourceID: UUID,
    to projectID: UUID?,
    in modelContext: ModelContext,
    now: Date = .now
  ) throws -> ProjectResourceBindingRecord? {
    guard
      try resourceExists(
        kind: resourceKind,
        id: resourceID,
        in: modelContext
      )
    else {
      throw ProjectBindingError.invalidResource
    }
    let existing = try binding(
      resourceKind: resourceKind,
      resourceID: resourceID,
      in: modelContext
    )
    if let projectID {
      var projectDescriptor = FetchDescriptor<ProjectRecord>(
        predicate: #Predicate { $0.id == projectID }
      )
      projectDescriptor.fetchLimit = 1
      guard let project = try modelContext.fetch(projectDescriptor).first, !project.isArchived
      else {
        throw ProjectBindingError.projectUnavailable(projectID)
      }
    }
    if resourceKind == .conversation {
      try AutomaticMemoryProjectReconciler.reconcileConversationMove(
        conversationID: resourceID,
        from: existing?.projectID,
        to: projectID,
        in: modelContext,
        now: now
      )
    }
    guard let projectID else {
      if let existing { modelContext.delete(existing) }
      return nil
    }
    if let existing {
      existing.move(to: projectID, at: now)
      return existing
    }
    let created = ProjectResourceBindingRecord(
      resourceKind: resourceKind,
      resourceID: resourceID,
      projectID: projectID,
      createdAt: now,
      updatedAt: now
    )
    modelContext.insert(created)
    return created
  }

  /// Compare-and-swap entry point for project pickers. The captured binding identity prevents a
  /// stale window from overwriting a move or removal completed elsewhere.
  @discardableResult
  static func assignConversation(
    conversationID: UUID,
    to projectID: UUID?,
    expected: ConversationProjectScope,
    in modelContext: ModelContext,
    now: Date = .now
  ) throws -> ProjectResourceBindingRecord? {
    // A long-lived UI context can retain an identity-cached binding after another window commits
    // a move. Re-read committed state through a fresh context before trusting the captured picker
    // snapshot, then ensure the mutation context represents that same committed generation.
    let validationContext = ModelContext(modelContext.container)
    validationContext.autosaveEnabled = false
    let committed = try binding(
      resourceKind: .conversation,
      resourceID: conversationID,
      in: validationContext,
      includesPendingChanges: false
    )
    guard expected.conversationID == conversationID,
      expected.projectID == committed?.projectID,
      expected.bindingID == committed?.id,
      expected.bindingUpdatedAt == committed?.updatedAt
    else {
      throw ProjectBindingError.staleConversationAssignment(conversationID)
    }

    let current = try binding(
      resourceKind: .conversation,
      resourceID: conversationID,
      in: modelContext,
      includesPendingChanges: true
    )
    guard current?.projectID == committed?.projectID,
      current?.id == committed?.id,
      current?.updatedAt == committed?.updatedAt
    else {
      throw ProjectBindingError.staleConversationAssignment(conversationID)
    }
    return try assign(
      resourceKind: .conversation,
      resourceID: conversationID,
      to: projectID,
      in: modelContext,
      now: now
    )
  }

  static func validate(
    _ binding: ProjectResourceBindingRecord,
    in modelContext: ModelContext
  ) throws {
    guard let kind = ProjectResourceKind(rawValue: binding.resourceKindRawValue),
      binding.bindingKey
        == ProjectResourceBindingRecord.makeBindingKey(
          resourceKind: kind,
          resourceID: binding.resourceID
        ),
      try resourceExists(kind: kind, id: binding.resourceID, in: modelContext)
    else {
      throw ProjectBindingError.invalidResource
    }
    let projectID = binding.projectID
    var projectDescriptor = FetchDescriptor<ProjectRecord>(
      predicate: #Predicate { $0.id == projectID }
    )
    projectDescriptor.fetchLimit = 1
    guard try modelContext.fetch(projectDescriptor).first != nil else {
      throw ProjectBindingError.projectUnavailable(binding.projectID)
    }
    switch kind {
    case .conversation:
      try AutomaticMemoryProjectReconciler.validateLiveAudience(
        evidencedBy: binding.resourceID,
        in: modelContext
      )
    case .memoryTopic:
      try AutomaticMemoryProjectReconciler.validateLiveAudience(
        topicIDs: Set([binding.resourceID]),
        in: modelContext
      )
    case .memory, .document:
      break
    }
  }

  /// Compare-and-swap project edit used by sheets that can outlive another window's commit. A
  /// fresh context prevents SwiftData's identity cache from making an old `updatedAt` look current.
  @discardableResult
  static func updateProject(
    id projectID: UUID,
    expected: MosaicProjectSnapshot,
    name: String,
    instructions: String,
    in modelContext: ModelContext,
    now: Date = .now
  ) throws -> ProjectRecord {
    guard expected.id == projectID else {
      throw ProjectBindingError.staleProjectEdit(projectID)
    }
    try MosaicSourceFieldLimits.validateProject(name: name, instructions: instructions)

    var committedDescriptor = FetchDescriptor<ProjectRecord>(
      predicate: #Predicate { $0.id == projectID }
    )
    committedDescriptor.fetchLimit = 1
    committedDescriptor.includePendingChanges = false
    let committedContext = ModelContext(modelContext.container)
    committedContext.autosaveEnabled = false
    guard let committed = try committedContext.fetch(committedDescriptor).first,
      committed.snapshot == expected
    else {
      throw ProjectBindingError.staleProjectEdit(projectID)
    }

    var mutationDescriptor = committedDescriptor
    mutationDescriptor.includePendingChanges = true
    guard let record = try modelContext.fetch(mutationDescriptor).first,
      record.snapshot == expected
    else {
      throw ProjectBindingError.staleProjectEdit(projectID)
    }
    record.name = name
    record.instructions = instructions
    record.updatedAt = now
    return record
  }

  static func projectID(
    resourceKind: ProjectResourceKind,
    resourceID: UUID,
    in modelContext: ModelContext,
    includesPendingChanges: Bool = false
  ) throws -> UUID? {
    try binding(
      resourceKind: resourceKind,
      resourceID: resourceID,
      in: modelContext,
      includesPendingChanges: includesPendingChanges
    )?.projectID
  }

  static func conversationScope(
    conversationID: UUID,
    in modelContext: ModelContext,
    includesPendingChanges: Bool = false
  ) throws -> ConversationProjectScope {
    let binding = try binding(
      resourceKind: .conversation,
      resourceID: conversationID,
      in: modelContext,
      includesPendingChanges: includesPendingChanges
    )
    return ConversationProjectScope(
      conversationID: conversationID,
      projectID: binding?.projectID,
      bindingID: binding?.id,
      bindingUpdatedAt: binding?.updatedAt
    )
  }

  static func projectIDs(
    resourceKind: ProjectResourceKind,
    resourceIDs: [UUID],
    in modelContext: ModelContext,
    includesPendingChanges: Bool = false
  ) throws -> [UUID: UUID] {
    guard !resourceIDs.isEmpty else { return [:] }
    let rawKind = resourceKind.rawValue
    let uniqueResourceIDs = Array(Set(resourceIDs))
    var result: [UUID: UUID] = [:]
    for start in stride(from: 0, to: uniqueResourceIDs.count, by: 128) {
      let end = min(start + 128, uniqueResourceIDs.count)
      let page = Array(uniqueResourceIDs[start..<end])
      var descriptor = FetchDescriptor<ProjectResourceBindingRecord>(
        predicate: #Predicate {
          $0.resourceKindRawValue == rawKind && page.contains($0.resourceID)
        }
      )
      descriptor.includePendingChanges = includesPendingChanges
      for binding in try modelContext.fetch(descriptor) {
        guard result.updateValue(binding.projectID, forKey: binding.resourceID) == nil else {
          throw ProjectBindingError.danglingBinding(binding.id)
        }
      }
    }
    return result
  }

  private static func resourceExists(
    kind: ProjectResourceKind,
    id: UUID,
    in modelContext: ModelContext
  ) throws -> Bool {
    switch kind {
    case .conversation:
      var descriptor = FetchDescriptor<ConversationRecord>(predicate: #Predicate { $0.id == id })
      descriptor.fetchLimit = 1
      return try !modelContext.fetch(descriptor).isEmpty
    case .memory:
      var descriptor = FetchDescriptor<MemoryRecord>(predicate: #Predicate { $0.id == id })
      descriptor.fetchLimit = 1
      guard let memory = try modelContext.fetch(descriptor).first else { return false }
      return memory.scope == .project && memory.conversationID == nil
    case .memoryTopic:
      var descriptor = FetchDescriptor<MemoryTopicRecord>(predicate: #Predicate { $0.id == id })
      descriptor.fetchLimit = 1
      guard let topic = try modelContext.fetch(descriptor).first else { return false }
      return topic.scope == .project && topic.conversationID == nil
    case .document:
      var descriptor = FetchDescriptor<ImportedDocumentRecord>(
        predicate: #Predicate { $0.id == id })
      descriptor.fetchLimit = 1
      return try !modelContext.fetch(descriptor).isEmpty
    }
  }
}

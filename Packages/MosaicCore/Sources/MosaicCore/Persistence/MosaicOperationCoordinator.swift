import Foundation
import Observation
import SwiftData

public enum MosaicOperationCoordinatorError: LocalizedError, Sendable {
  case maintenanceActive
  case exclusiveMaintenanceRequired
  case sourceStoreUnavailable

  public var errorDescription: String? {
    switch self {
    case .maintenanceActive:
      "Turing AI is replacing its local library. Try again after recovery finishes."
    case .exclusiveMaintenanceRequired:
      "Turing AI could not reserve the local library snapshot. Please try again."
    case .sourceStoreUnavailable:
      "Turing AI could not verify the local library. Restore a valid backup before making more changes."
    }
  }
}

public enum MosaicOperationID: Hashable, Sendable {
  case conversationRequest(UUID)
  case conversationCompactionRecovery(UUID)
  case liveTranscription(UUID)
  case scheduledTask(UUID)
  case librarySnapshot
  case scheduledTaskSweep
  case documentImport(UUID)
  case chatAttachmentImport(UUID)
  case semanticIndexing(UUID)
  case embeddingProfileDeletion(UUID)
  case memoryFormation(UUID)
  case providerMutation(UUID)
  case conversationDeletion(UUID)
  case documentDeletion(UUID)
}

/// A small process-local barrier between long-running provider/data work and exclusive store
/// replacement. The source-of-truth database is never replaced while an in-flight operation still
/// owns model objects from the previous generation or can write a derived cache for it.
@Observable
@MainActor
public final class MosaicOperationCoordinator {
  public static let shared = MosaicOperationCoordinator(availabilityDefaults: .standard)

  private static let sourceStoreUnavailableDefaultsKey =
    "com.omergirgin.mosaic.sourceStoreUnavailable"
  private let availabilityDefaults: UserDefaults?

  /// Invalidates optimistic background reads, including writes made by leased model actors.
  public private(set) var sourceActivityRevision: UInt64 = 0
  public private(set) var activeOperations: Set<MosaicOperationID> = []
  public private(set) var isExclusiveMaintenanceActive = false
  public private(set) var isSourceStoreUnavailable = false
  /// Stable, O(1) invalidation tokens for bounded root queries. These replace root-level hashes of
  /// every conversation or message and are shared across app windows.
  public private(set) var conversationCatalogRevision: UInt64 = 0
  public private(set) var messageSearchRevision: UInt64 = 0
  public private(set) var contextReceiptRevision: UInt64 = 0
  public private(set) var memoryLibraryRevision: UInt64 = 0
  public private(set) var projectCatalogRevision: UInt64 = 0
  /// Changes only when the complete source generation is replaced. Views with bounded local page
  /// caches use this token to discard models and receipts even when restored records reuse IDs.
  public private(set) var sourceStoreGenerationRevision: UInt64 = 0

  public var isSourceAccessBlocked: Bool {
    isExclusiveMaintenanceActive || isSourceStoreUnavailable || isConversationDeletionActive
      || isDocumentDeletionActive
  }

  public var isConversationDeletionActive: Bool {
    activeOperations.contains {
      if case .conversationDeletion = $0 { return true }
      return false
    }
  }

  public var isDocumentDeletionActive: Bool {
    activeOperations.contains {
      if case .documentDeletion = $0 { return true }
      return false
    }
  }

  public init() {
    availabilityDefaults = nil
    isSourceStoreUnavailable = false
  }

  init(availabilityDefaults: UserDefaults) {
    self.availabilityDefaults = availabilityDefaults
    isSourceStoreUnavailable = availabilityDefaults.bool(
      forKey: Self.sourceStoreUnavailableDefaultsKey
    )
  }

  private static func interactiveConversationID(for operation: MosaicOperationID) -> UUID? {
    switch operation {
    case .conversationRequest(let conversationID), .liveTranscription(let conversationID),
      .chatAttachmentImport(let conversationID):
      conversationID
    default:
      nil
    }
  }

  @discardableResult
  public func begin(_ operation: MosaicOperationID) -> Bool {
    guard !isSourceAccessBlocked else { return false }
    // Provider and embedding-profile deletion may suspend while their external stores are
    // cleaned. Keep that whole window mutually exclusive with provider-backed and semantic work,
    // so no request can recreate a vector after its profile has been removed.
    guard
      !activeOperations.contains(where: {
        switch $0 {
        case .providerMutation, .embeddingProfileDeletion:
          true
        default:
          false
        }
      })
    else { return false }
    switch operation {
    case .providerMutation, .embeddingProfileDeletion:
      guard activeOperations.isEmpty else { return false }
    default:
      break
    }
    if case .conversationDeletion = operation {
      guard activeOperations.isEmpty else { return false }
    }
    if case .documentDeletion = operation {
      guard activeOperations.isEmpty else { return false }
    }
    if case .documentImport = operation {
      guard
        !activeOperations.contains(where: {
          if case .documentImport = $0 { return true }
          return false
        })
      else { return false }
    }
    if case .liveTranscription = operation {
      guard
        !activeOperations.contains(where: {
          if case .liveTranscription = $0 { return true }
          return false
        })
      else { return false }
    }
    if let conversationID = Self.interactiveConversationID(for: operation) {
      guard
        !activeOperations.contains(where: {
          Self.interactiveConversationID(for: $0) == conversationID
        })
      else { return false }
    }
    let inserted = activeOperations.insert(operation).inserted
    if inserted && operation != .librarySnapshot { sourceActivityRevision &+= 1 }
    return inserted
  }

  /// Flushes pending UI-context changes and reserves the exclusive conversation-deletion lease in
  /// one main-actor turn. A rejected lease never flushes, and a failed flush never reserves, so a
  /// caller cannot start the destructive pipeline against an older source generation.
  @discardableResult
  public func beginConversationDeletion(
    conversationID: UUID,
    flushing modelContext: ModelContext
  ) throws -> Bool {
    guard !isSourceAccessBlocked, activeOperations.isEmpty else { return false }
    if modelContext.hasChanges {
      try saveSourceChanges(in: modelContext)
    }
    return activeOperations.insert(.conversationDeletion(conversationID)).inserted
  }

  /// Flushes pending UI changes before reserving an exclusive document-deletion lease. The source
  /// actor owns the destructive commit after this synchronous main-actor reservation succeeds.
  @discardableResult
  public func beginDocumentDeletion(
    documentID: UUID,
    flushing modelContext: ModelContext
  ) throws -> Bool {
    guard !isSourceAccessBlocked, activeOperations.isEmpty else { return false }
    if modelContext.hasChanges {
      try saveSourceChanges(in: modelContext)
    }
    return activeOperations.insert(.documentDeletion(documentID)).inserted
  }

  public func end(_ operation: MosaicOperationID) {
    if activeOperations.remove(operation) != nil && operation != .librarySnapshot {
      sourceActivityRevision &+= 1
    }
  }

  /// The only commit gate for source-of-truth UI contexts. Explicit saves make the process-local
  /// maintenance lease authoritative; a mutation attempted during restore is rolled back instead
  /// of surviving as a late write from another window.
  public func saveSourceChanges(in modelContext: ModelContext) throws {
    guard !isSourceStoreUnavailable else {
      modelContext.rollback()
      throw MosaicOperationCoordinatorError.sourceStoreUnavailable
    }
    guard !isExclusiveMaintenanceActive else {
      modelContext.rollback()
      throw MosaicOperationCoordinatorError.maintenanceActive
    }
    guard !isConversationDeletionActive else {
      modelContext.rollback()
      throw MosaicOperationCoordinatorError.maintenanceActive
    }
    guard !isDocumentDeletionActive else {
      modelContext.rollback()
      throw MosaicOperationCoordinatorError.maintenanceActive
    }
    try commitSourceChanges(in: modelContext)
  }

  /// Snapshot/export callers first reserve verified exclusive maintenance, then use this one
  /// exceptional commit gate to flush already-pending UI edits before reading the store.
  func flushSourceChangesForVerifiedSnapshot(in modelContext: ModelContext) throws {
    guard !isSourceStoreUnavailable else {
      modelContext.rollback()
      throw MosaicOperationCoordinatorError.sourceStoreUnavailable
    }
    guard isExclusiveMaintenanceActive else {
      modelContext.rollback()
      throw MosaicOperationCoordinatorError.exclusiveMaintenanceRequired
    }
    try commitSourceChanges(in: modelContext)
  }

  /// Publishes one bounded refresh after a verified whole-store replacement. Call only after the
  /// live save succeeds; all root windows observe the same revision without scanning the store.
  public func markSourceStoreReplaced() {
    sourceActivityRevision &+= 1
    isSourceStoreUnavailable = false
    availabilityDefaults?.removeObject(forKey: Self.sourceStoreUnavailableDefaultsKey)
    sourceStoreGenerationRevision &+= 1
    conversationCatalogRevision &+= 1
    messageSearchRevision &+= 1
    contextReceiptRevision &+= 1
    memoryLibraryRevision &+= 1
    projectCatalogRevision &+= 1
  }

  public func markConversationDeleted() {
    sourceActivityRevision &+= 1
    conversationCatalogRevision &+= 1
    messageSearchRevision &+= 1
    memoryLibraryRevision &+= 1
  }

  public func markMemoryLibraryChanged() {
    sourceActivityRevision &+= 1
    memoryLibraryRevision &+= 1
  }

  /// Latches a fail-closed state when neither the requested nor prior complete store generation
  /// can be verified. Normal operations and commits stay blocked, while Data & Recovery may begin
  /// another exclusive restore attempt that clears the latch only after exact read-back.
  public func markSourceStoreUnavailable() {
    sourceActivityRevision &+= 1
    isSourceStoreUnavailable = true
    availabilityDefaults?.set(true, forKey: Self.sourceStoreUnavailableDefaultsKey)
  }

  /// Enters an exclusive maintenance lease. The lease may span suspension while a dedicated
  /// model actor performs store work; callers must always release it with `defer`.
  @discardableResult
  public func beginExclusiveMaintenance() -> Bool {
    // Recovery must remain available while the source-store latch blocks normal operations.
    guard !isExclusiveMaintenanceActive, activeOperations.isEmpty else { return false }
    sourceActivityRevision &+= 1
    isExclusiveMaintenanceActive = true
    return true
  }

  /// Atomically verifies the source-generation latch and enters an export/snapshot lease. Recovery
  /// restore uses `beginExclusiveMaintenance()` directly because it must remain available while
  /// the latch is set; exports must never snapshot an unverified generation.
  @discardableResult
  public func beginVerifiedSourceSnapshotMaintenance() -> Bool {
    guard !isSourceStoreUnavailable else { return false }
    return beginExclusiveMaintenance()
  }

  public func endExclusiveMaintenance() {
    isExclusiveMaintenanceActive = false
  }

  private static func hasChanges<T: PersistentModel>(
    to _: T.Type,
    in modelContext: ModelContext
  ) -> Bool {
    modelContext.insertedModelsArray.contains { $0 is T }
      || modelContext.changedModelsArray.contains { $0 is T }
      || modelContext.deletedModelsArray.contains { $0 is T }
  }

  private func commitSourceChanges(in modelContext: ModelContext) throws {
    do {
      try Self.validatePendingSourceFields(in: modelContext)
    } catch {
      modelContext.rollback()
      throw error
    }
    let changesConversationCatalog =
      Self.hasChanges(
        to: ConversationRecord.self,
        in: modelContext
      ) || Self.hasChanges(to: ExperienceRecord.self, in: modelContext)
    let changesMessageSearch =
      changesConversationCatalog
      || Self.hasChanges(to: MessageRecord.self, in: modelContext)
    let changesContextReceipts = Self.hasChanges(
      to: RequestContextEventRecord.self,
      in: modelContext
    )
    let changesMemoryLibrary =
      Self.hasChanges(to: MemoryRecord.self, in: modelContext)
      || Self.hasChanges(to: MemoryTopicRecord.self, in: modelContext)
      || Self.hasChanges(to: MemoryEvidenceRecord.self, in: modelContext)
      || Self.hasChanges(to: MemoryRevisionRecord.self, in: modelContext)
      || Self.hasChanges(to: MemoryFormationJobRecord.self, in: modelContext)
      || Self.hasChanges(to: MemoryFormationAuditRecord.self, in: modelContext)
      || Self.hasChanges(to: ImportedDocumentRecord.self, in: modelContext)
      || Self.hasChanges(to: DocumentChunkRecord.self, in: modelContext)
      || Self.hasChanges(to: EmbeddingProfileRecord.self, in: modelContext)
      || Self.hasChanges(to: ProjectResourceBindingRecord.self, in: modelContext)
    let changesProjects =
      Self.hasChanges(to: ProjectRecord.self, in: modelContext)
      || Self.hasChanges(to: ProjectResourceBindingRecord.self, in: modelContext)
    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
    sourceActivityRevision &+= 1
    if changesConversationCatalog || changesProjects { conversationCatalogRevision &+= 1 }
    if changesMessageSearch { messageSearchRevision &+= 1 }
    if changesContextReceipts { contextReceiptRevision &+= 1 }
    if changesMemoryLibrary { memoryLibraryRevision &+= 1 }
    if changesProjects {
      projectCatalogRevision &+= 1
    }
  }

  private static func validatePendingSourceFields(in modelContext: ModelContext) throws {
    let pendingModels = modelContext.insertedModelsArray + modelContext.changedModelsArray
    for conversation in pendingModels.compactMap({ $0 as? ConversationRecord }) {
      try MosaicSourceFieldLimits.validateConversation(
        title: conversation.title,
        systemPrompt: conversation.systemPrompt,
        draft: conversation.draftText
      )
    }
    for project in pendingModels.compactMap({ $0 as? ProjectRecord }) {
      try MosaicSourceFieldLimits.validateProject(
        name: project.name,
        instructions: project.instructions
      )
    }
    for binding in pendingModels.compactMap({ $0 as? ProjectResourceBindingRecord }) {
      try ProjectBindingStore.validate(binding, in: modelContext)
    }
    for memory in pendingModels.compactMap({ $0 as? MemoryRecord }) {
      try MosaicSourceFieldLimits.validateMemory(
        title: memory.title,
        content: memory.content
      )
    }
    for topic in pendingModels.compactMap({ $0 as? MemoryTopicRecord }) {
      try MosaicSourceFieldLimits.validateMemoryTopic(topic)
    }
    for evidence in pendingModels.compactMap({ $0 as? MemoryEvidenceRecord }) {
      try MosaicSourceFieldLimits.validateMemoryEvidence(evidence)
    }
    let changedAutomaticTopicIDs = Set(
      pendingModels.compactMap { model -> UUID? in
        if let topic = model as? MemoryTopicRecord { return topic.id }
        if let evidence = model as? MemoryEvidenceRecord { return evidence.topicID }
        return nil
      }
    )
    try AutomaticMemoryProjectReconciler.validateLiveAudience(
      topicIDs: changedAutomaticTopicIDs,
      in: modelContext
    )
    for revision in pendingModels.compactMap({ $0 as? MemoryRevisionRecord }) {
      try MosaicSourceFieldLimits.validateMemoryRevision(revision)
    }
    for job in pendingModels.compactMap({ $0 as? MemoryFormationJobRecord }) {
      try MosaicSourceFieldLimits.validateMemoryFormationJob(job)
    }
    for audit in pendingModels.compactMap({ $0 as? MemoryFormationAuditRecord }) {
      try MosaicSourceFieldLimits.validateMemoryFormationAudit(audit)
    }
    for message in pendingModels.compactMap({ $0 as? MessageRecord }) {
      try MosaicSourceFieldLimits.validateMessageContent(message.content)
    }
  }

}

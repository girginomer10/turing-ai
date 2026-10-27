import Foundation
import SwiftData

struct MosaicConversationDeletionOutcome: Equatable, Sendable {
  let didDeleteConversation: Bool
  let vectorCleanupSucceeded: Bool
  let deletedVectorCount: Int
}

struct MosaicStagedConversationDeletion: Sendable {
  let didFindConversation: Bool
  let messageIDs: Set<UUID>
  let memoryTopicIDs: Set<UUID>
}

/// Stages the complete source-of-truth cascade on a private model executor. Cancellation is
/// observed only before `commitStagedDeletion`; after that boundary the caller must finish and
/// publish the committed result.
@ModelActor
actor MosaicConversationSourceDeletionRepository {
  func stageDeletion(conversationID: UUID) throws -> MosaicStagedConversationDeletion {
    // Staging intentionally spans a suspension before the explicit commit boundary. Never let the
    // private context's default autosave publish the destructive mutations during that interval.
    modelContext.autosaveEnabled = false
    try Task.checkCancellation()
    let targetID = conversationID
    var conversationDescriptor = FetchDescriptor<ConversationRecord>(
      predicate: #Predicate { $0.id == targetID }
    )
    conversationDescriptor.fetchLimit = 1
    conversationDescriptor.includePendingChanges = false
    guard let conversation = try modelContext.fetch(conversationDescriptor).first else {
      return MosaicStagedConversationDeletion(
        didFindConversation: false,
        messageIDs: [],
        memoryTopicIDs: []
      )
    }

    do {
      var messageIDs: Set<UUID> = []
      let messageDescriptor = FetchDescriptor<MessageRecord>(
        predicate: #Predicate { $0.conversationID == targetID }
      )
      try modelContext.enumerate(
        messageDescriptor,
        batchSize: 512,
        allowEscapingMutations: true
      ) { message in
        try Task.checkCancellation()
        messageIDs.insert(message.id)
        modelContext.delete(message)
      }

      try deleteAll(
        FetchDescriptor<RequestContextEventRecord>(
          predicate: #Predicate { $0.conversationID == targetID }
        )
      )
      try deleteAll(
        FetchDescriptor<CompactionArtifactRecord>(
          predicate: #Predicate { $0.conversationID == targetID }
        )
      )
      try deleteAll(
        FetchDescriptor<ConversationCompactionHeadRecord>(
          predicate: #Predicate { $0.conversationID == targetID }
        )
      )
      try deleteAll(
        FetchDescriptor<MemoryRecord>(
          predicate: #Predicate { $0.conversationID == targetID }
        )
      )
      let formationJobDescriptor = FetchDescriptor<MemoryFormationJobRecord>(
        predicate: #Predicate { $0.conversationID == targetID }
      )
      let formationJobIDs = Set(try modelContext.fetch(formationJobDescriptor).map(\.id))
      if !formationJobIDs.isEmpty {
        try deleteAll(
          FetchDescriptor<MemoryFormationAuditRecord>(
            predicate: #Predicate { formationJobIDs.contains($0.jobID) }
          )
        )
      }
      try deleteAll(formationJobDescriptor)

      let conversationTopicDescriptor = FetchDescriptor<MemoryTopicRecord>(
        predicate: #Predicate { $0.conversationID == targetID }
      )
      let conversationTopicIDs = Set(
        try modelContext.fetch(conversationTopicDescriptor).map(\.id)
      )
      var memoryTopicIDsToClean = conversationTopicIDs
      if !conversationTopicIDs.isEmpty {
        let topicBindingKind = ProjectResourceKind.memoryTopic.rawValue
        try deleteAll(
          FetchDescriptor<ProjectResourceBindingRecord>(
            predicate: #Predicate {
              $0.resourceKindRawValue == topicBindingKind
                && conversationTopicIDs.contains($0.resourceID)
            }
          )
        )
        try deleteAll(
          FetchDescriptor<MemoryEvidenceRecord>(
            predicate: #Predicate { conversationTopicIDs.contains($0.topicID) }
          )
        )
        try deleteAll(
          FetchDescriptor<MemoryRevisionRecord>(
            predicate: #Predicate { conversationTopicIDs.contains($0.topicID) }
          )
        )
        try deleteAll(conversationTopicDescriptor)
      }

      let sourceEvidenceDescriptor = FetchDescriptor<MemoryEvidenceRecord>(
        predicate: #Predicate { $0.conversationID == targetID }
      )
      let sourceEvidence = try modelContext.fetch(sourceEvidenceDescriptor)
      let affectedGlobalTopicIDs = Set(
        sourceEvidence.map(\.topicID)
      ).subtracting(conversationTopicIDs)
      let removedGlobalEvidenceIDs = Set(
        sourceEvidence.lazy.filter { affectedGlobalTopicIDs.contains($0.topicID) }.map(\.id)
      )
      if !removedGlobalEvidenceIDs.isEmpty {
        let revisionDescriptor = FetchDescriptor<MemoryRevisionRecord>(
          predicate: #Predicate { affectedGlobalTopicIDs.contains($0.topicID) }
        )
        try modelContext.enumerate(
          revisionDescriptor,
          batchSize: 512,
          allowEscapingMutations: true
        ) { revision in
          try Task.checkCancellation()
          if let evidenceID = revision.sourceEvidenceID,
            removedGlobalEvidenceIDs.contains(evidenceID)
          {
            revision.detachSourceEvidence()
          }
        }
      }
      try deleteAll(sourceEvidenceDescriptor)
      let now = Date.now
      for topicID in affectedGlobalTopicIDs {
        let remainingDescriptor = FetchDescriptor<MemoryEvidenceRecord>(
          predicate: #Predicate { $0.topicID == topicID && $0.conversationID != targetID }
        )
        let remainingEvidenceIDs = Set(try modelContext.fetch(remainingDescriptor).map(\.id))
        let remainingCount = remainingEvidenceIDs.count
        var topicDescriptor = FetchDescriptor<MemoryTopicRecord>(
          predicate: #Predicate { $0.id == topicID }
        )
        topicDescriptor.fetchLimit = 1
        guard let topic = try modelContext.fetch(topicDescriptor).first else { continue }
        let revisions = try modelContext.fetch(
          FetchDescriptor<MemoryRevisionRecord>(predicate: #Predicate { $0.topicID == topicID })
        )
        // Reinforcement supports the current value only after its last semantic change.
        // An older, contradicted value must not keep the current head active merely because
        // its evidence survived deletion. Manual corrections are independently authoritative.
        let valueRevision =
          revisions.filter {
            [.created, .updated, .reactivated, .userEdited].contains($0.snapshot.kind)
          }.map(\.sequence).max() ?? 0
        let currentValue = AutomaticMemoryStore.normalizedValue(topic.content)
        let hasCurrentEvidence = revisions.contains { revision in
          guard revision.sequence >= valueRevision,
            [.created, .updated, .reactivated, .reinforced].contains(revision.snapshot.kind),
            let evidenceID = revision.sourceEvidenceID,
            remainingEvidenceIDs.contains(evidenceID)
          else { return false }
          return AutomaticMemoryStore.normalizedValue(revision.content) == currentValue
        }
        let unsupportedAutomaticHead = topic.origin == .automatic && !hasCurrentEvidence
        if unsupportedAutomaticHead || topic.status == .forgotten {
          memoryTopicIDsToClean.insert(topic.id)
        }
        if unsupportedAutomaticHead, topic.status != .forgotten {
          guard topic.revision < Int.max else {
            throw AutomaticMemoryStoreError.counterOverflow
          }
          let nextRevision = topic.revision + 1
          topic.markForgottenAfterEvidenceRemoval(
            revision: nextRevision, remainingEvidenceCount: remainingCount, at: now
          )
          modelContext.insert(
            MemoryRevisionRecord(
              revisionKey: "\(topic.id.uuidString.lowercased())/\(nextRevision)",
              topicID: topic.id,
              sequence: nextRevision,
              kind: .forgotten,
              previousTitle: topic.title,
              previousContent: topic.content,
              title: topic.title,
              content: topic.content,
              sourceEvidenceID: nil,
              createdAt: now
            )
          )
        } else {
          topic.reconcileEvidenceCount(remainingCount, at: now)
        }
        try MosaicSourceFieldLimits.validateMemoryTopic(topic)
      }

      let taskDescriptor = FetchDescriptor<ScheduledTaskRecord>(
        predicate: #Predicate { $0.conversationID == targetID }
      )
      try modelContext.enumerate(
        taskDescriptor,
        batchSize: 512,
        allowEscapingMutations: true
      ) { task in
        try Task.checkCancellation()
        task.conversationID = nil
        task.updatedAt = now
      }

      let conversationBindingKey = ProjectResourceBindingRecord.makeBindingKey(
        resourceKind: .conversation,
        resourceID: targetID
      )
      try deleteAll(
        FetchDescriptor<ProjectResourceBindingRecord>(
          predicate: #Predicate { $0.bindingKey == conversationBindingKey }
        )
      )
      for row in try modelContext.fetch(
        FetchDescriptor<ExperienceRecord>(predicate: #Predicate { $0.ownerID == conversationID }))
      { modelContext.delete(row) }
      modelContext.delete(conversation)
      try AutomaticMemoryProjectReconciler.validateLiveAudience(
        topicIDs: affectedGlobalTopicIDs,
        in: modelContext
      )
      try Task.checkCancellation()
      return MosaicStagedConversationDeletion(
        didFindConversation: true,
        messageIDs: messageIDs,
        memoryTopicIDs: memoryTopicIDsToClean
      )
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  /// The destructive commit boundary. Deliberately does not inspect task cancellation.
  func commitStagedDeletion() throws {
    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  func rollbackStagedDeletion() {
    modelContext.rollback()
  }

  private func deleteAll<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws {
    try modelContext.enumerate(
      descriptor,
      batchSize: 512,
      allowEscapingMutations: true
    ) { record in
      try Task.checkCancellation()
      modelContext.delete(record)
    }
  }
}

/// Deletes conversation-message vectors and learned-topic vectors invalidated by the source
/// cascade. The cache is processed with stable keyset pages, so neither the whole vector table nor
/// vector blobs are retained on the UI actor.
@ModelActor
actor MosaicConversationVectorDeletionRepository {
  func deleteConversationVectors(
    messageSourceIDs: Set<UUID>,
    memoryTopicSourceIDs: Set<UUID>,
    batchSize requestedBatchSize: Int = 512
  ) throws -> Int {
    guard !messageSourceIDs.isEmpty || !memoryTopicSourceIDs.isEmpty else { return 0 }
    let messageSourceKind = RetrievalSourceKind.conversationMessage.rawValue
    let memoryTopicSourceKind = RetrievalSourceKind.memoryTopic.rawValue
    let batchSize = min(512, max(1, requestedBatchSize))
    var cursor: UUID?
    var targetCacheKeys: [String] = []

    // First finish a mutation-free scan. Deleting between limited SwiftData fetches can cause the
    // model executor to advance past rows that should belong to the next page.
    while true {
      let descriptor: FetchDescriptor<EmbeddingVectorRecord>
      if let cursor {
        let currentCursor = cursor
        descriptor = FetchDescriptor(
          predicate: #Predicate {
            ($0.sourceKindRawValue == messageSourceKind
              || $0.sourceKindRawValue == memoryTopicSourceKind)
              && $0.id > currentCursor
          },
          sortBy: [SortDescriptor(\EmbeddingVectorRecord.id)]
        )
      } else {
        descriptor = FetchDescriptor(
          predicate: #Predicate {
            $0.sourceKindRawValue == messageSourceKind
              || $0.sourceKindRawValue == memoryTopicSourceKind
          },
          sortBy: [SortDescriptor(\EmbeddingVectorRecord.id)]
        )
      }

      var pageDescriptor = descriptor
      pageDescriptor.fetchLimit = batchSize
      pageDescriptor.includePendingChanges = false
      let page = try modelContext.fetch(pageDescriptor)
      guard let nextCursor = page.last?.id else { break }
      targetCacheKeys.append(
        contentsOf: page.compactMap {
          switch $0.sourceKind {
          case .conversationMessage:
            messageSourceIDs.contains($0.sourceID) ? $0.cacheKey : nil
          case .memoryTopic:
            memoryTopicSourceIDs.contains($0.sourceID) ? $0.cacheKey : nil
          case .documentChunk:
            nil
          }
        }
      )
      cursor = nextCursor
      if page.count < batchSize { break }
    }

    var deletedCount = 0
    do {
      for (index, cacheKey) in targetCacheKeys.enumerated() {
        let targetKey = cacheKey
        var descriptor = FetchDescriptor<EmbeddingVectorRecord>(
          predicate: #Predicate { $0.cacheKey == targetKey }
        )
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = false
        if let vector = try modelContext.fetch(descriptor).first {
          modelContext.delete(vector)
          deletedCount += 1
        }
        if (index + 1).isMultiple(of: batchSize), modelContext.hasChanges {
          try modelContext.save()
        }
      }
      if modelContext.hasChanges { try modelContext.save() }
    } catch {
      modelContext.rollback()
      throw error
    }

    return deletedCount
  }
}

enum MosaicConversationDeletionPipeline {
  /// The potentially large source-ID set stays between background actors. Only this small outcome
  /// crosses back to the root view.
  nonisolated static func delete(
    conversationID: UUID,
    sourceRepository: MosaicConversationSourceDeletionRepository,
    vectorRepository: MosaicConversationVectorDeletionRepository,
    commitWillBegin: @escaping @MainActor @Sendable () throws -> Void = {}
  ) async throws -> MosaicConversationDeletionOutcome {
    let staged = try await sourceRepository.stageDeletion(conversationID: conversationID)
    guard staged.didFindConversation else {
      return MosaicConversationDeletionOutcome(
        didDeleteConversation: false,
        vectorCleanupSucceeded: true,
        deletedVectorCount: 0
      )
    }

    do {
      try Task.checkCancellation()
      try await commitWillBegin()
    } catch {
      await sourceRepository.rollbackStagedDeletion()
      throw error
    }

    try await sourceRepository.commitStagedDeletion()

    do {
      let deletedVectorCount = try await vectorRepository.deleteConversationVectors(
        messageSourceIDs: staged.messageIDs,
        memoryTopicSourceIDs: staged.memoryTopicIDs
      )
      return MosaicConversationDeletionOutcome(
        didDeleteConversation: true,
        vectorCleanupSucceeded: true,
        deletedVectorCount: deletedVectorCount
      )
    } catch {
      // Vectors are a rebuildable cache. Once the source commit succeeds, deletion remains an exact
      // success even if cache cleanup must be repaired later.
      return MosaicConversationDeletionOutcome(
        didDeleteConversation: true,
        vectorCleanupSucceeded: false,
        deletedVectorCount: 0
      )
    }
  }
}

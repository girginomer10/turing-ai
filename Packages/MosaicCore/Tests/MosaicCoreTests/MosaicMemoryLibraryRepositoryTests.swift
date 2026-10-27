import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite("Memory library repository", .serialized)
@MainActor
struct MosaicMemoryLibraryRepositoryTests {
  @Test("library and conversation reads are hard-capped keyset pages")
  func pagesAreBoundedAndDeterministic() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    var conversationIDs: [UUID] = []

    for index in 0..<40 {
      let timestamp = baseDate.addingTimeInterval(Double(index))
      let conversation = ConversationRecord(
        title: "Conversation \(index)",
        createdAt: timestamp,
        updatedAt: timestamp
      )
      conversationIDs.append(conversation.id)
      context.insert(conversation)
      context.insert(
        MemoryRecord(
          title: "Needle memory \(index)",
          content: "Bounded content \(index)",
          scope: index == 39 ? .conversation : .global,
          conversationID: index == 39 ? conversation.id : nil,
          createdAt: timestamp,
          updatedAt: timestamp
        )
      )
    }

    for index in 0..<20 {
      let timestamp = baseDate.addingTimeInterval(Double(index))
      let document = ImportedDocumentRecord(
        title: "Document \(index)",
        sourceFilename: "document-\(index).txt",
        mimeType: "text/plain",
        contentFingerprint: "fingerprint-\(index)",
        characterCount: 100 + index,
        createdAt: timestamp,
        updatedAt: timestamp
      )
      context.insert(document)
      for chunkIndex in 0...index {
        context.insert(
          DocumentChunkRecord(
            documentID: document.id,
            chunkIndex: chunkIndex,
            content: "Chunk \(chunkIndex)"
          )
        )
      }
    }
    context.insert(
      EmbeddingProfileRecord(
        displayName: "Enabled",
        providerConfigurationID: nil,
        modelIdentifier: "test",
        isEnabled: true
      )
    )
    context.insert(
      EmbeddingProfileRecord(
        displayName: "Disabled",
        providerConfigurationID: nil,
        modelIdentifier: "test",
        isEnabled: false
      )
    )
    let auditID = UUID()
    context.insert(
      MemoryFormationAuditRecord(
        id: auditID,
        jobID: UUID(),
        jobKey: "repository-audit-job",
        attemptCount: 1,
        outcome: .complete,
        providerConfigurationID: nil,
        providerKind: .openAI,
        providerDisplayName: "OpenAI",
        modelIdentifier: "memory-model",
        providerEndpoint: "https://api.openai.com:443/v1",
        providerMessageID: "memory-response",
        requestStarted: true,
        inputTokenCount: 90,
        outputTokenCount: 10,
        providerRequestCount: 1,
        cumulativeInputTokenCount: 90,
        cumulativeOutputTokenCount: 10,
        didDiscardInvalidTelemetry: false,
        errorDescription: nil,
        startedAt: baseDate,
        finishedAt: baseDate.addingTimeInterval(1),
        createdAt: baseDate,
        updatedAt: baseDate.addingTimeInterval(1)
      )
    )
    try context.save()

    let repository = MosaicMemoryLibraryRepository(modelContainer: container)
    let first = try await repository.snapshot(
      query: "needle",
      memoryAfter: nil,
      documentAfter: nil,
      pageSize: .max
    )
    #expect(first.memories.items.count == 16)
    #expect(first.documents.items.count == 16)
    #expect(first.memories.nextCursor != nil)
    #expect(first.documents.nextCursor != nil)
    #expect(first.enabledEmbeddingProfileCount == 1)
    #expect(first.recentFormationAudits.map(\.id) == [auditID])
    #expect(first.recentFormationAudits.first?.totalTokenCount == 100)
    #expect(first.memories.items.first?.conversationTitle == "Conversation 39")
    #expect(first.documents.items.first?.chunkCount == 20)

    let second = try await repository.snapshot(
      query: "needle",
      memoryAfter: first.memories.nextCursor,
      documentAfter: first.documents.nextCursor,
      pageSize: 16
    )
    #expect(second.memories.items.count == 16)
    #expect(second.documents.items.count == 4)
    #expect(Set(first.memories.items.map(\.id)).isDisjoint(with: second.memories.items.map(\.id)))
    #expect(Set(first.documents.items.map(\.id)).isDisjoint(with: second.documents.items.map(\.id)))

    let selectedID = try #require(conversationIDs.first)
    let choices = try await repository.conversationPage(
      query: "",
      after: nil,
      pageSize: .max,
      selectedID: selectedID
    )
    #expect(choices.items.count == 16)
    #expect(choices.nextCursor != nil)
    #expect(!choices.items.contains { $0.id == selectedID })
    #expect(choices.selectedItem?.id == selectedID)
  }

  @Test("a cancelled search never publishes a page")
  func cancellationStopsSearch() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    for index in 0..<256 {
      context.insert(MemoryRecord(title: "Memory \(index)", content: "No match"))
    }
    try context.save()
    let repository = MosaicMemoryLibraryRepository(modelContainer: container)
    let task = Task {
      try await repository.snapshot(
        query: "missing needle",
        memoryAfter: nil,
        documentAfter: nil,
        pageSize: 16
      )
    }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Expected the bounded search to observe cancellation")
    } catch is CancellationError {
      // Expected.
    }
  }
}

@Suite("Document deletion pipeline", .serialized)
@MainActor
struct MosaicDocumentDeletionPipelineTests {
  @Test("source commits first and orphan vectors are swept in bounded pages")
  func deletesDocumentAndOnlyOrphanDocumentVectors() async throws {
    let sourceContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let vectorContainer = try SemanticIndexStore.makeModelContainer(inMemory: true)
    let sourceContext = sourceContainer.mainContext
    let vectorContext = vectorContainer.mainContext
    let target = ImportedDocumentRecord(
      title: "Delete",
      sourceFilename: "delete.txt",
      mimeType: "text/plain",
      contentFingerprint: "delete",
      characterCount: 130
    )
    let retained = ImportedDocumentRecord(
      title: "Keep",
      sourceFilename: "keep.txt",
      mimeType: "text/plain",
      contentFingerprint: "keep",
      characterCount: 1
    )
    let project = ProjectRecord(name: "Scoped documents")
    sourceContext.insert(project)
    sourceContext.insert(target)
    sourceContext.insert(retained)
    try ProjectBindingStore.assign(
      resourceKind: .document,
      resourceID: target.id,
      to: project.id,
      in: sourceContext
    )
    let profileID = UUID()
    var firstTargetChunkID: UUID?
    for index in 0..<130 {
      let chunk = DocumentChunkRecord(
        documentID: target.id,
        chunkIndex: index,
        content: "Target \(index)"
      )
      if firstTargetChunkID == nil { firstTargetChunkID = chunk.id }
      sourceContext.insert(chunk)
      vectorContext.insert(
        EmbeddingVectorRecord(
          profileID: profileID,
          sourceKind: .documentChunk,
          sourceID: chunk.id,
          embeddingSpaceIdentifier: "test",
          contentFingerprint: "target-\(index)",
          dimensions: 1,
          vectorData: Data([0, 0, 0, 0])
        )
      )
    }
    let retainedChunk = DocumentChunkRecord(
      documentID: retained.id,
      chunkIndex: 0,
      content: "Retained"
    )
    sourceContext.insert(retainedChunk)
    vectorContext.insert(
      EmbeddingVectorRecord(
        profileID: profileID,
        sourceKind: .documentChunk,
        sourceID: retainedChunk.id,
        embeddingSpaceIdentifier: "test",
        contentFingerprint: "retained",
        dimensions: 1,
        vectorData: Data([0, 0, 0, 0])
      )
    )
    let conversationVectorID = try #require(firstTargetChunkID)
    vectorContext.insert(
      EmbeddingVectorRecord(
        profileID: UUID(),
        sourceKind: .conversationMessage,
        sourceID: conversationVectorID,
        embeddingSpaceIdentifier: "test",
        contentFingerprint: "conversation",
        dimensions: 1,
        vectorData: Data([0, 0, 0, 0])
      )
    )
    try sourceContext.save()
    try vectorContext.save()

    let sourceRepository = MosaicDocumentSourceDeletionRepository(
      modelContainer: sourceContainer
    )
    let vectorRepository = MosaicDocumentVectorDeletionRepository(
      modelContainer: vectorContainer
    )
    var crossedCommitBoundary = false
    let outcome = try await MosaicDocumentDeletionPipeline.delete(
      documentID: target.id,
      sourceRepository: sourceRepository,
      vectorRepository: vectorRepository,
      vectorBatchSize: 7
    ) {
      crossedCommitBoundary = true
    }

    #expect(crossedCommitBoundary)
    #expect(outcome.didDeleteDocument)
    #expect(outcome.vectorCleanupSucceeded)
    #expect(outcome.deletedVectorCount == 130)

    let sourceVerification = ModelContext(sourceContainer)
    let targetID = target.id
    #expect(
      try sourceVerification.fetch(
        FetchDescriptor<ImportedDocumentRecord>(
          predicate: #Predicate { $0.id == targetID }
        )
      ).isEmpty
    )
    #expect(
      try sourceVerification.fetch(
        FetchDescriptor<DocumentChunkRecord>(
          predicate: #Predicate { $0.documentID == targetID }
        )
      ).isEmpty
    )
    #expect(try sourceVerification.fetchCount(FetchDescriptor<ImportedDocumentRecord>()) == 1)
    #expect(try sourceVerification.fetchCount(FetchDescriptor<DocumentChunkRecord>()) == 1)
    #expect(
      try sourceVerification.fetchCount(FetchDescriptor<ProjectResourceBindingRecord>()) == 0
    )

    let vectorVerification = ModelContext(vectorContainer)
    let remaining = try vectorVerification.fetch(FetchDescriptor<EmbeddingVectorRecord>())
    #expect(remaining.count == 2)
    #expect(remaining.contains { $0.sourceID == retainedChunk.id })
    #expect(
      remaining.contains {
        $0.sourceID == conversationVectorID && $0.sourceKind == .conversationMessage
      }
    )
  }

  @Test("cancellation before commit rolls back the staged source deletion")
  func cancellationBeforeCommitRollsBack() async throws {
    let sourceContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let vectorContainer = try SemanticIndexStore.makeModelContainer(inMemory: true)
    let context = sourceContainer.mainContext
    let document = ImportedDocumentRecord(
      title: "Keep",
      sourceFilename: "keep.txt",
      mimeType: "text/plain",
      contentFingerprint: "keep",
      characterCount: 1
    )
    context.insert(document)
    context.insert(DocumentChunkRecord(documentID: document.id, chunkIndex: 0, content: "Keep"))
    try context.save()

    let task = Task {
      try await MosaicDocumentDeletionPipeline.delete(
        documentID: document.id,
        sourceRepository: MosaicDocumentSourceDeletionRepository(
          modelContainer: sourceContainer
        ),
        vectorRepository: MosaicDocumentVectorDeletionRepository(
          modelContainer: vectorContainer
        )
      )
    }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation before the source commit")
    } catch is CancellationError {
      // Expected.
    }

    let verification = ModelContext(sourceContainer)
    #expect(try verification.fetchCount(FetchDescriptor<ImportedDocumentRecord>()) == 1)
    #expect(try verification.fetchCount(FetchDescriptor<DocumentChunkRecord>()) == 1)
  }
}

@Suite("Memory library operation coordination", .serialized)
@MainActor
struct MosaicMemoryLibraryOperationCoordinatorTests {
  @Test("document deletion reserves an exclusive source lease without rejected flushes")
  func documentDeletionLeaseIsExclusive() throws {
    let coordinator = MosaicOperationCoordinator()
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let memory = MemoryRecord(title: "Saved", content: "Initial")
    context.insert(memory)
    try coordinator.saveSourceChanges(in: context)

    memory.content = "Pending"
    let indexing = MosaicOperationID.semanticIndexing(UUID())
    #expect(coordinator.begin(indexing))
    #expect(
      try !coordinator.beginDocumentDeletion(documentID: UUID(), flushing: context)
    )
    #expect(context.hasChanges)
    coordinator.end(indexing)

    let documentID = UUID()
    let deletion = MosaicOperationID.documentDeletion(documentID)
    #expect(try coordinator.beginDocumentDeletion(documentID: documentID, flushing: context))
    #expect(!context.hasChanges)
    #expect(coordinator.activeOperations == [deletion])
    #expect(coordinator.isDocumentDeletionActive)
    #expect(coordinator.isSourceAccessBlocked)
    #expect(!coordinator.begin(.conversationRequest(UUID())))
    coordinator.end(deletion)
    #expect(!coordinator.isSourceAccessBlocked)

    let firstImport = MosaicOperationID.documentImport(UUID())
    let secondImport = MosaicOperationID.documentImport(UUID())
    #expect(coordinator.begin(firstImport))
    #expect(!coordinator.begin(secondImport))
    coordinator.end(firstImport)
    #expect(coordinator.begin(secondImport))
    coordinator.end(secondImport)

    let verification = ModelContext(container)
    #expect(
      try #require(verification.fetch(FetchDescriptor<MemoryRecord>()).first).content == "Pending")
  }

  @Test("memory revisions and verified snapshot flush share the validated commit path")
  func revisionAndVerifiedSnapshotFlush() throws {
    let coordinator = MosaicOperationCoordinator()
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext

    context.insert(MemoryRecord(title: "Memory", content: "First"))
    try coordinator.saveSourceChanges(in: context)
    #expect(coordinator.memoryLibraryRevision == 1)

    context.insert(ConversationRecord(title: "Conversation"))
    try coordinator.saveSourceChanges(in: context)
    #expect(coordinator.memoryLibraryRevision == 1)

    let document = ImportedDocumentRecord(
      title: "Document",
      sourceFilename: "document.txt",
      mimeType: "text/plain",
      contentFingerprint: "document",
      characterCount: 1
    )
    context.insert(document)
    context.insert(DocumentChunkRecord(documentID: document.id, chunkIndex: 0, content: "x"))
    try coordinator.saveSourceChanges(in: context)
    #expect(coordinator.memoryLibraryRevision == 2)

    context.insert(
      EmbeddingProfileRecord(
        displayName: "Profile",
        providerConfigurationID: nil,
        modelIdentifier: "test"
      )
    )
    try coordinator.saveSourceChanges(in: context)
    #expect(coordinator.memoryLibraryRevision == 3)

    context.insert(MemoryRecord(title: "Must roll back", content: "No lease"))
    do {
      try coordinator.flushSourceChangesForVerifiedSnapshot(in: context)
      Issue.record("Expected a verified snapshot lease requirement")
    } catch MosaicOperationCoordinatorError.exclusiveMaintenanceRequired {
      // Expected.
    }
    #expect(!context.hasChanges)

    #expect(coordinator.beginVerifiedSourceSnapshotMaintenance())
    context.insert(MemoryRecord(title: "Snapshot", content: "Persisted"))
    try coordinator.flushSourceChangesForVerifiedSnapshot(in: context)
    #expect(coordinator.memoryLibraryRevision == 4)
    coordinator.endExclusiveMaintenance()

    coordinator.markSourceStoreReplaced()
    #expect(coordinator.memoryLibraryRevision == 5)
    coordinator.markConversationDeleted()
    #expect(coordinator.memoryLibraryRevision == 6)
    coordinator.markMemoryLibraryChanged()
    #expect(coordinator.memoryLibraryRevision == 7)
  }

  @Test("validated source commits reject and roll back oversized messages")
  func oversizedMessageRollsBack() throws {
    let coordinator = MosaicOperationCoordinator()
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversation = ConversationRecord(title: "Validated")
    context.insert(conversation)
    try coordinator.saveSourceChanges(in: context)

    context.insert(
      MessageRecord(
        conversationID: conversation.id,
        role: .user,
        content: String(
          repeating: "x",
          count: MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes + 1
        )
      )
    )
    do {
      try coordinator.saveSourceChanges(in: context)
      Issue.record("Expected the oversized message to be rejected")
    } catch MosaicSourceFieldLimitError.messageContent {
      // Expected; the coordinator also rolls back the pending insert.
    }
    #expect(!context.hasChanges)
    let verification = ModelContext(container)
    #expect(try verification.fetchCount(FetchDescriptor<MessageRecord>()) == 0)
  }
}

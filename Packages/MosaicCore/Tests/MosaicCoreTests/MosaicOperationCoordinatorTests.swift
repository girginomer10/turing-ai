import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite("Mosaic operation coordinator")
@MainActor
struct MosaicOperationCoordinatorTests {
  @Test("background snapshots keep chat available while preventing replacement")
  func backgroundSnapshotsAllowInteractionAndDetectInterleavedWriters() throws {
    let coordinator = MosaicOperationCoordinator()
    let context = ModelContext(try MosaicSchema.makeModelContainer(inMemory: true))
    let initial = coordinator.sourceActivityRevision
    #expect(coordinator.begin(.librarySnapshot))
    #expect(!coordinator.isSourceAccessBlocked)
    #expect(!coordinator.beginExclusiveMaintenance())
    #expect(coordinator.sourceActivityRevision == initial)
    let request = MosaicOperationID.conversationRequest(UUID())
    #expect(coordinator.begin(request))
    #expect(coordinator.sourceActivityRevision != initial)
    let duringRequest = coordinator.sourceActivityRevision
    coordinator.end(request)
    #expect(coordinator.sourceActivityRevision != duringRequest)
    let beforeSave = coordinator.sourceActivityRevision
    try coordinator.saveSourceChanges(in: context)
    #expect(coordinator.sourceActivityRevision != beforeSave)
    coordinator.end(.librarySnapshot)
    #expect(!coordinator.isSourceAccessBlocked)
    #expect(coordinator.beginExclusiveMaintenance())
  }

  @Test("exclusive maintenance waits for active provider work")
  func exclusiveMaintenanceWaitsForActiveProviderWork() {
    let coordinator = MosaicOperationCoordinator()
    let request = MosaicOperationID.conversationRequest(UUID())

    #expect(coordinator.begin(request))
    #expect(!coordinator.beginExclusiveMaintenance())

    coordinator.end(request)
    #expect(coordinator.beginExclusiveMaintenance())
    #expect(!coordinator.begin(.scheduledTask(UUID())))

    coordinator.endExclusiveMaintenance()
    #expect(coordinator.begin(.scheduledTask(UUID())))
  }

  @Test("operation registration is idempotent")
  func operationRegistrationIsIdempotent() {
    let coordinator = MosaicOperationCoordinator()
    let operation = MosaicOperationID.scheduledTask(UUID())

    #expect(coordinator.begin(operation))
    #expect(!coordinator.begin(operation))
    coordinator.end(operation)
    #expect(coordinator.activeOperations.isEmpty)
  }

  @Test("provider mutations cannot race provider-backed work")
  func providerMutationsOwnAnExclusiveOperationLease() {
    let coordinator = MosaicOperationCoordinator()
    let request = MosaicOperationID.memoryFormation(UUID())
    let mutation = MosaicOperationID.providerMutation(UUID())

    #expect(coordinator.begin(request))
    #expect(!coordinator.begin(mutation))
    coordinator.end(request)

    #expect(coordinator.begin(mutation))
    #expect(!coordinator.begin(.conversationRequest(UUID())))
    #expect(!coordinator.begin(.providerMutation(UUID())))
    coordinator.end(mutation)
    #expect(coordinator.begin(.conversationRequest(UUID())))
  }

  @Test("embedding profile deletion cannot race semantic vector work")
  func embeddingProfileDeletionOwnsAnExclusiveOperationLease() {
    let coordinator = MosaicOperationCoordinator()
    let profileID = UUID()
    let deletion = MosaicOperationID.embeddingProfileDeletion(profileID)
    let indexing = MosaicOperationID.semanticIndexing(UUID())

    #expect(coordinator.begin(indexing))
    #expect(!coordinator.begin(deletion))
    coordinator.end(indexing)

    let importOperation = MosaicOperationID.documentImport(UUID())
    #expect(coordinator.begin(importOperation))
    #expect(!coordinator.begin(deletion))
    coordinator.end(importOperation)

    #expect(coordinator.begin(deletion))
    #expect(!coordinator.begin(.conversationRequest(UUID())))
    #expect(!coordinator.begin(.scheduledTask(UUID())))
    #expect(!coordinator.begin(.semanticIndexing(UUID())))
    #expect(!coordinator.begin(.embeddingProfileDeletion(UUID())))
    coordinator.end(deletion)

    #expect(coordinator.begin(.conversationRequest(UUID())))
  }

  @Test("conversation deletion owns an exclusive source-operation lease")
  func conversationDeletionOwnsExclusiveSourceLease() {
    let coordinator = MosaicOperationCoordinator()
    let deletion = MosaicOperationID.conversationDeletion(UUID())
    let request = MosaicOperationID.conversationRequest(UUID())

    #expect(coordinator.begin(request))
    #expect(!coordinator.begin(deletion))
    coordinator.end(request)

    #expect(coordinator.begin(deletion))
    #expect(coordinator.isConversationDeletionActive)
    #expect(coordinator.isSourceAccessBlocked)
    #expect(!coordinator.begin(request))

    coordinator.end(deletion)
    #expect(!coordinator.isConversationDeletionActive)
    #expect(!coordinator.isSourceAccessBlocked)
  }

  @Test("conversation deletion rejection does not flush pending source changes")
  func rejectedConversationDeletionDoesNotFlushPendingChanges() throws {
    let coordinator = MosaicOperationCoordinator()
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversation = ConversationRecord(draftText: "Saved draft")
    context.insert(conversation)
    try coordinator.saveSourceChanges(in: context)

    conversation.draftText = "Pending draft"
    let request = MosaicOperationID.conversationRequest(UUID())
    #expect(coordinator.begin(request))
    #expect(
      try !coordinator.beginConversationDeletion(
        conversationID: UUID(),
        flushing: context
      )
    )
    #expect(context.hasChanges)
    #expect(coordinator.activeOperations == [request])

    let verification = ModelContext(container)
    let persisted = try #require(
      verification.fetch(FetchDescriptor<ConversationRecord>()).first
    )
    #expect(persisted.draftText == "Saved draft")

    coordinator.end(request)
    context.rollback()
  }

  @Test("one conversation accepts only one reply at a time")
  func oneConversationAcceptsOnlyOneReplyAtATime() {
    let coordinator = MosaicOperationCoordinator()
    let conversationID = UUID()

    #expect(coordinator.begin(.conversationRequest(conversationID)))
    #expect(!coordinator.begin(.conversationRequest(conversationID)))
    #expect(coordinator.begin(.conversationRequest(UUID())))

    coordinator.end(.conversationRequest(conversationID))
    #expect(coordinator.begin(.conversationRequest(conversationID)))
  }

  @Test("reply generation and live transcription share a per-conversation lease")
  func replyAndLiveTranscriptionSharePerConversationLease() {
    let coordinator = MosaicOperationCoordinator()
    let firstConversationID = UUID()
    let secondConversationID = UUID()

    #expect(coordinator.begin(.conversationRequest(firstConversationID)))
    #expect(!coordinator.begin(.liveTranscription(firstConversationID)))

    #expect(coordinator.begin(.liveTranscription(secondConversationID)))
    #expect(!coordinator.begin(.conversationRequest(secondConversationID)))
    #expect(!coordinator.begin(.liveTranscription(UUID())))

    coordinator.end(.conversationRequest(firstConversationID))
    #expect(!coordinator.begin(.liveTranscription(firstConversationID)))

    coordinator.end(.liveTranscription(secondConversationID))
    #expect(coordinator.begin(.liveTranscription(firstConversationID)))
    #expect(!coordinator.begin(.conversationRequest(firstConversationID)))

    coordinator.end(.liveTranscription(firstConversationID))
    #expect(coordinator.begin(.conversationRequest(firstConversationID)))
  }

  @Test("exclusive maintenance rejects and rolls back late source writes")
  func exclusiveMaintenanceRejectsLateSourceWrites() throws {
    let coordinator = MosaicOperationCoordinator()
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let existing = ConversationRecord(title: "Existing")
    context.insert(existing)
    try coordinator.saveSourceChanges(in: context)

    #expect(context.autosaveEnabled == false)
    #expect(coordinator.beginExclusiveMaintenance())
    context.insert(ConversationRecord(title: "Late write"))
    do {
      try coordinator.saveSourceChanges(in: context)
      Issue.record("Expected the maintenance lease to reject the write")
    } catch MosaicOperationCoordinatorError.maintenanceActive {
      // Expected: the helper also rolls the uncommitted insert back.
    }
    coordinator.endExclusiveMaintenance()

    let verificationContext = ModelContext(container)
    let conversations = try verificationContext.fetch(FetchDescriptor<ConversationRecord>())
    #expect(conversations.map(\.id) == [existing.id])
  }

  @Test("recovery maintenance flush uses the validated source commit path")
  func recoveryMaintenanceFlushValidatesAndPublishesRevisions() throws {
    let coordinator = MosaicOperationCoordinator()
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let memory = MemoryRecord(title: "Pending before restore", content: "Validated")
    context.insert(memory)

    #expect(coordinator.beginExclusiveMaintenance())
    try coordinator.flushSourceChangesForVerifiedSnapshot(in: context)
    #expect(coordinator.memoryLibraryRevision == 1)
    coordinator.endExclusiveMaintenance()

    context.insert(
      MemoryRecord(
        title: "Oversized pending source row",
        content: String(
          repeating: "x",
          count: MosaicSourceFieldLimits.maximumMemoryContentUTF8Bytes + 1
        )
      )
    )
    #expect(coordinator.beginExclusiveMaintenance())
    defer { coordinator.endExclusiveMaintenance() }
    do {
      try coordinator.flushSourceChangesForVerifiedSnapshot(in: context)
      Issue.record("Expected restore maintenance to validate pending source fields")
    } catch let error as MosaicSourceFieldLimitError {
      #expect(
        error
          == .memoryContent(
            actual: MosaicSourceFieldLimits.maximumMemoryContentUTF8Bytes + 1,
            maximum: MosaicSourceFieldLimits.maximumMemoryContentUTF8Bytes
          )
      )
    }

    #expect(!context.hasChanges)
    #expect(coordinator.memoryLibraryRevision == 1)
    let verificationContext = ModelContext(container)
    let memories = try verificationContext.fetch(FetchDescriptor<MemoryRecord>())
    #expect(memories.map(\.id) == [memory.id])
  }

  @Test("draft flush persists once and suppresses an expected maintenance rejection")
  func draftFlushPersistsAndStaysSilentDuringMaintenance() throws {
    let coordinator = MosaicOperationCoordinator()
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversation = ConversationRecord(draftText: "Initial draft")
    context.insert(conversation)
    try coordinator.saveSourceChanges(in: context)

    conversation.draftText = "Persisted before backgrounding"
    #expect(
      try ConversationDraftPersistence.flush(in: context, coordinator: coordinator) == .saved
    )
    #expect(
      try ConversationDraftPersistence.flush(in: context, coordinator: coordinator) == .noChanges
    )

    let savedContext = ModelContext(container)
    let saved = try #require(
      savedContext.fetch(FetchDescriptor<ConversationRecord>()).first
    )
    #expect(saved.draftText == "Persisted before backgrounding")

    #expect(coordinator.beginExclusiveMaintenance())
    conversation.draftText = "Must not cross restore maintenance"
    #expect(
      try ConversationDraftPersistence.flush(in: context, coordinator: coordinator)
        == .suppressedDuringMaintenance
    )
    coordinator.endExclusiveMaintenance()

    let verificationContext = ModelContext(container)
    let verified = try #require(
      verificationContext.fetch(FetchDescriptor<ConversationRecord>()).first
    )
    #expect(verified.draftText == "Persisted before backgrounding")
    #expect(!context.hasChanges)
  }

  @Test("source commits publish constant-time root invalidation tokens")
  func sourceCommitsPublishRootInvalidationTokens() throws {
    let coordinator = MosaicOperationCoordinator()
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversation = ConversationRecord(title: "Revision source")
    context.insert(conversation)

    try coordinator.saveSourceChanges(in: context)
    #expect(coordinator.conversationCatalogRevision == 1)
    #expect(coordinator.messageSearchRevision == 1)

    context.insert(
      MessageRecord(
        conversationID: conversation.id,
        role: .user,
        content: "Search revision"
      )
    )
    try coordinator.saveSourceChanges(in: context)
    #expect(coordinator.conversationCatalogRevision == 1)
    #expect(coordinator.messageSearchRevision == 2)

    coordinator.markSourceStoreReplaced()
    #expect(coordinator.sourceStoreGenerationRevision == 1)
    #expect(coordinator.conversationCatalogRevision == 2)
    #expect(coordinator.messageSearchRevision == 3)
    #expect(coordinator.contextReceiptRevision == 1)
  }

  @Test("unverified source latch blocks normal work but permits a recovery lease")
  func unverifiedSourceLatchFailsClosedUntilVerifiedReplacement() throws {
    let coordinator = MosaicOperationCoordinator()
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let existing = ConversationRecord(title: "Verified before failure")
    context.insert(existing)
    try coordinator.saveSourceChanges(in: context)

    coordinator.markSourceStoreUnavailable()
    #expect(coordinator.isSourceAccessBlocked)
    #expect(!coordinator.begin(.conversationRequest(UUID())))
    #expect(!coordinator.beginVerifiedSourceSnapshotMaintenance())
    context.insert(ConversationRecord(title: "Must roll back"))
    do {
      try coordinator.saveSourceChanges(in: context)
      Issue.record("Expected the unavailable-store latch to reject source writes")
    } catch MosaicOperationCoordinatorError.sourceStoreUnavailable {
      // Expected; the coordinator also rolls back the pending write.
    }
    #expect(!context.hasChanges)

    #expect(coordinator.beginExclusiveMaintenance())
    coordinator.endExclusiveMaintenance()
    coordinator.markSourceStoreReplaced()
    #expect(!coordinator.isSourceStoreUnavailable)
    #expect(!coordinator.isSourceAccessBlocked)
    #expect(coordinator.beginVerifiedSourceSnapshotMaintenance())
    coordinator.endExclusiveMaintenance()
    #expect(coordinator.begin(.conversationRequest(UUID())))

    let verificationContext = ModelContext(container)
    let conversations = try verificationContext.fetch(FetchDescriptor<ConversationRecord>())
    #expect(conversations.map(\.id) == [existing.id])
  }

  @Test("unverified source latch survives coordinator recreation")
  func unverifiedSourceLatchPersistsUntilReplacement() throws {
    let suiteName = "MosaicOperationCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = MosaicOperationCoordinator(availabilityDefaults: defaults)
    #expect(!first.isSourceStoreUnavailable)
    first.markSourceStoreUnavailable()

    let relaunched = MosaicOperationCoordinator(availabilityDefaults: defaults)
    #expect(relaunched.isSourceStoreUnavailable)
    #expect(relaunched.isSourceAccessBlocked)
    relaunched.markSourceStoreReplaced()

    let recovered = MosaicOperationCoordinator(availabilityDefaults: defaults)
    #expect(!recovered.isSourceStoreUnavailable)
    #expect(!recovered.isSourceAccessBlocked)
  }
}

@Suite("Conversation message search")
@MainActor
struct MosaicConversationMessageSearchTests {
  @Test("message content search runs through a model actor and returns container IDs")
  func findsMatchingConversationIDs() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let matchingConversation = ConversationRecord(title: "First")
    let otherConversation = ConversationRecord(title: "Second")
    context.insert(matchingConversation)
    context.insert(otherConversation)
    context.insert(
      MessageRecord(
        conversationID: matchingConversation.id,
        role: .user,
        content: "Mosaic remembers my Kadıköy preference."
      )
    )
    context.insert(
      MessageRecord(
        conversationID: otherConversation.id,
        role: .user,
        content: "An unrelated message."
      )
    )
    try MosaicOperationCoordinator().saveSourceChanges(in: context)

    let search = MosaicConversationMessageSearch(modelContainer: container)
    let matches = try await search.matchingConversationIDs(query: "kadıköy")

    #expect(matches == [matchingConversation.id])
  }
}

@Suite("Conversation sidebar catalog")
@MainActor
struct MosaicConversationSidebarCatalogTests {
  @Test("catalog returns bounded pages and combines title with message search off main")
  func returnsBoundedPagesAndSearchResults() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let baseDate = Date(timeIntervalSinceReferenceDate: 50_000)
    var activeIDs: [UUID] = []

    for index in 0..<130 {
      let conversation = ConversationRecord(
        title: index == 73 ? "Needle title" : "Chat \(index)",
        draftText: "Retained draft",
        createdAt: baseDate.addingTimeInterval(Double(index)),
        updatedAt: baseDate.addingTimeInterval(Double(index))
      )
      activeIDs.append(conversation.id)
      context.insert(conversation)
      if index == 5 {
        context.insert(
          MessageRecord(
            conversationID: conversation.id,
            role: .user,
            content: "A needle hidden in message content"
          )
        )
      }
    }
    for index in 0..<3 {
      context.insert(
        ConversationRecord(
          title: "Archived \(index)",
          draftText: "Retained archived draft",
          isArchived: true,
          createdAt: baseDate.addingTimeInterval(Double(index)),
          updatedAt: baseDate.addingTimeInterval(Double(index))
        )
      )
    }
    try MosaicOperationCoordinator().saveSourceChanges(in: context)

    let project = ProjectRecord(name: "Sidebar project")
    context.insert(project)
    try MosaicOperationCoordinator().saveSourceChanges(in: context)
    let projectBinding = try #require(
      try ProjectBindingStore.assign(
        resourceKind: .conversation,
        resourceID: activeIDs[129],
        to: project.id,
        in: context,
        now: baseDate.addingTimeInterval(1_000)
      )
    )
    try MosaicOperationCoordinator().saveSourceChanges(in: context)

    let catalog = MosaicConversationSidebarCatalog(modelContainer: container)
    let first = try await catalog.pages(
      query: "",
      activeOffset: 0,
      archivedOffset: 0,
      pageSize: 64
    )
    #expect(first.active.items.count == 64)
    #expect(first.active.items.first?.id == activeIDs[129])
    #expect(first.active.items.first?.projectID == project.id)
    #expect(first.active.items.first?.projectBindingID == projectBinding.id)
    #expect(first.active.items.first?.projectBindingUpdatedAt == projectBinding.updatedAt)
    #expect(first.active.hasNextPage)
    #expect(first.archived.items.count == 3)

    let last = try await catalog.pages(
      query: "",
      activeOffset: 128,
      archivedOffset: 0,
      pageSize: 64
    )
    #expect(last.active.items.map(\.id) == [activeIDs[1], activeIDs[0]])
    #expect(!last.active.hasNextPage)
    #expect(last.active.hasPreviousPage)

    let search = try await catalog.pages(
      query: "needle",
      activeOffset: 0,
      archivedOffset: 0,
      pageSize: 64
    )
    #expect(search.active.items.map(\.id) == [activeIDs[73], activeIDs[5]])
    #expect(!search.active.hasNextPage)
  }
}

@Suite("Conversation deletion pipeline", .serialized)
@MainActor
struct MosaicConversationDeletionPipelineTests {
  @Test("deleting one conversation first persists another conversation's pending draft")
  func deletionReservationFlushesPendingDraft() async throws {
    let sourceContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let vectorContainer = try SemanticIndexStore.makeModelContainer(inMemory: true)
    let context = sourceContainer.mainContext
    let coordinator = MosaicOperationCoordinator()
    let retained = ConversationRecord(title: "Keep", draftText: "Saved draft")
    let target = ConversationRecord(title: "Delete")
    context.insert(retained)
    context.insert(target)
    context.insert(
      MessageRecord(conversationID: target.id, role: .user, content: "Delete me")
    )
    try coordinator.saveSourceChanges(in: context)

    retained.draftText = "Pending draft persisted before deletion"
    let operation = MosaicOperationID.conversationDeletion(target.id)
    #expect(
      try coordinator.beginConversationDeletion(
        conversationID: target.id,
        flushing: context
      )
    )
    defer { coordinator.end(operation) }
    #expect(!context.hasChanges)
    #expect(coordinator.activeOperations == [operation])

    let sourceRepository = MosaicConversationSourceDeletionRepository(
      modelContainer: sourceContainer
    )
    let vectorRepository = MosaicConversationVectorDeletionRepository(
      modelContainer: vectorContainer
    )
    let outcome = try await MosaicConversationDeletionPipeline.delete(
      conversationID: target.id,
      sourceRepository: sourceRepository,
      vectorRepository: vectorRepository
    )
    #expect(outcome.didDeleteConversation)

    let verification = ModelContext(sourceContainer)
    let conversations = try verification.fetch(FetchDescriptor<ConversationRecord>())
    #expect(conversations.map(\.id) == [retained.id])
    #expect(conversations.first?.draftText == "Pending draft persisted before deletion")
  }

  @Test("large cascades commit off main and clean only matching conversation vectors")
  func deletesSourceCascadeAndScopedVectors() async throws {
    let sourceContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let vectorContainer = try SemanticIndexStore.makeModelContainer(inMemory: true)
    let sourceContext = sourceContainer.mainContext
    let vectorContext = vectorContainer.mainContext
    let target = ConversationRecord(title: "Delete me")
    let retained = ConversationRecord(title: "Keep me")
    let profileID = UUID()
    let documentProfileID = UUID()
    sourceContext.insert(target)
    sourceContext.insert(retained)

    var targetMessageIDs: [UUID] = []
    for index in 0..<513 {
      let message = MessageRecord(
        conversationID: target.id,
        role: .user,
        content: "Target \(index)"
      )
      targetMessageIDs.append(message.id)
      sourceContext.insert(message)
      vectorContext.insert(
        EmbeddingVectorRecord(
          profileID: profileID,
          sourceKind: .conversationMessage,
          sourceID: message.id,
          embeddingSpaceIdentifier: "test",
          contentFingerprint: "target-\(index)",
          dimensions: 1,
          vectorData: Data([0, 0, 0, 0])
        )
      )
    }
    let retainedMessage = MessageRecord(
      conversationID: retained.id,
      role: .user,
      content: "Retained"
    )
    sourceContext.insert(retainedMessage)
    vectorContext.insert(
      EmbeddingVectorRecord(
        profileID: profileID,
        sourceKind: .conversationMessage,
        sourceID: retainedMessage.id,
        embeddingSpaceIdentifier: "test",
        contentFingerprint: "retained",
        dimensions: 1,
        vectorData: Data([0, 0, 0, 0])
      )
    )
    vectorContext.insert(
      EmbeddingVectorRecord(
        profileID: documentProfileID,
        sourceKind: .documentChunk,
        sourceID: targetMessageIDs[0],
        embeddingSpaceIdentifier: "test",
        contentFingerprint: "document",
        dimensions: 1,
        vectorData: Data([0, 0, 0, 0])
      )
    )
    sourceContext.insert(
      MemoryRecord(
        title: "Scoped",
        content: "Delete",
        scope: .conversation,
        conversationID: target.id
      )
    )
    sourceContext.insert(
      MemoryRecord(title: "Global", content: "Keep")
    )
    let learnedTopic = MemoryTopicRecord(
      canonicalKey: "conversation:\(target.id.uuidString.lowercased()):project:cleanup",
      title: "Scoped learned topic",
      content: "This learned topic belongs only to the deleted chat.",
      kind: .project,
      scope: .conversation,
      conversationID: target.id,
      confidence: 0.9,
      importance: 0.7,
      stability: .evolving
    )
    sourceContext.insert(learnedTopic)
    vectorContext.insert(
      EmbeddingVectorRecord(
        profileID: profileID,
        sourceKind: .memoryTopic,
        sourceID: learnedTopic.id,
        embeddingSpaceIdentifier: "test",
        contentFingerprint: "learned-topic",
        dimensions: 1,
        vectorData: Data([0, 0, 0, 0])
      )
    )
    let linkedTask = ScheduledTaskRecord(
      title: "Linked",
      prompt: "Keep task",
      conversationID: target.id,
      scheduledAt: .now
    )
    sourceContext.insert(linkedTask)
    try sourceContext.save()
    try vectorContext.save()

    let sourceRepository = MosaicConversationSourceDeletionRepository(
      modelContainer: sourceContainer
    )
    let vectorRepository = MosaicConversationVectorDeletionRepository(
      modelContainer: vectorContainer
    )
    var crossedCommitBoundary = false
    let outcome = try await MosaicConversationDeletionPipeline.delete(
      conversationID: target.id,
      sourceRepository: sourceRepository,
      vectorRepository: vectorRepository
    ) {
      crossedCommitBoundary = true
    }

    #expect(crossedCommitBoundary)
    #expect(outcome.didDeleteConversation)
    #expect(outcome.vectorCleanupSucceeded)
    #expect(outcome.deletedVectorCount == 514)

    let sourceVerification = ModelContext(sourceContainer)
    let targetID = target.id
    #expect(
      try sourceVerification.fetch(FetchDescriptor<ConversationRecord>()).map(\.id)
        == [retained.id]
    )
    #expect(
      try sourceVerification.fetch(
        FetchDescriptor<MessageRecord>(
          predicate: #Predicate { $0.conversationID == targetID }
        )
      ).isEmpty
    )
    #expect(
      try sourceVerification.fetch(
        FetchDescriptor<MemoryRecord>(
          predicate: #Predicate { $0.conversationID == targetID }
        )
      ).isEmpty
    )
    let verifiedTask = try #require(
      sourceVerification.fetch(FetchDescriptor<ScheduledTaskRecord>()).first
    )
    #expect(verifiedTask.conversationID == nil)

    let vectorVerification = ModelContext(vectorContainer)
    let retainedVectors = try vectorVerification.fetch(FetchDescriptor<EmbeddingVectorRecord>())
    #expect(retainedVectors.count == 2)
    #expect(retainedVectors.contains { $0.sourceID == retainedMessage.id })
    #expect(retainedVectors.contains { $0.sourceKind == .documentChunk })
  }

  @Test("cancellation before the commit boundary rolls back the staged cascade")
  func cancellationBeforeCommitRollsBack() async throws {
    let sourceContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let vectorContainer = try SemanticIndexStore.makeModelContainer(inMemory: true)
    let context = sourceContainer.mainContext
    let conversation = ConversationRecord(title: "Keep after cancel")
    context.insert(conversation)
    context.insert(
      MessageRecord(conversationID: conversation.id, role: .user, content: "Still here")
    )
    try context.save()

    let sourceRepository = MosaicConversationSourceDeletionRepository(
      modelContainer: sourceContainer
    )
    let vectorRepository = MosaicConversationVectorDeletionRepository(
      modelContainer: vectorContainer
    )
    let deletion = Task {
      try await MosaicConversationDeletionPipeline.delete(
        conversationID: conversation.id,
        sourceRepository: sourceRepository,
        vectorRepository: vectorRepository
      )
    }
    deletion.cancel()
    do {
      _ = try await deletion.value
      Issue.record("Expected cancellation before the destructive commit")
    } catch is CancellationError {
      // Expected.
    }

    let verification = ModelContext(sourceContainer)
    #expect(try verification.fetchCount(FetchDescriptor<ConversationRecord>()) == 1)
    #expect(try verification.fetchCount(FetchDescriptor<MessageRecord>()) == 1)
  }

  @Test("staged deletion remains invisible until explicit commit and can roll back")
  func stagedDeletionDoesNotAutosaveBeforeCommit() async throws {
    let sourceContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = sourceContainer.mainContext
    let conversation = ConversationRecord(title: "Keep until commit")
    context.insert(conversation)
    context.insert(
      MessageRecord(conversationID: conversation.id, role: .user, content: "Still visible")
    )
    try context.save()

    let sourceRepository = MosaicConversationSourceDeletionRepository(
      modelContainer: sourceContainer
    )
    let staged = try await sourceRepository.stageDeletion(conversationID: conversation.id)
    #expect(staged.didFindConversation)

    await Task.yield()
    try await Task.sleep(for: .milliseconds(100))
    let beforeRollback = ModelContext(sourceContainer)
    #expect(try beforeRollback.fetchCount(FetchDescriptor<ConversationRecord>()) == 1)
    #expect(try beforeRollback.fetchCount(FetchDescriptor<MessageRecord>()) == 1)

    await sourceRepository.rollbackStagedDeletion()
    await Task.yield()
    let afterRollback = ModelContext(sourceContainer)
    #expect(try afterRollback.fetchCount(FetchDescriptor<ConversationRecord>()) == 1)
    #expect(try afterRollback.fetchCount(FetchDescriptor<MessageRecord>()) == 1)
  }
}

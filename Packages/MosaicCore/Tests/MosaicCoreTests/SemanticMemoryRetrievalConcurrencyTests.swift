import Foundation
import SwiftData
import Testing

@testable import MosaicCore

struct SemanticMemoryRetrievalConcurrencyTests {
  @MainActor
  @Test
  func zeroProfilesNeverInitializesOrReadsTheVectorStore() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let sourceConversation = ConversationRecord(title: "Pets", modelIdentifier: "model")
    let message = MessageRecord(
      conversationID: sourceConversation.id,
      role: .user,
      content: "Köpeğimin adı Luna ve tavuklu mamayı seviyor."
    )
    context.insert(sourceConversation)
    context.insert(message)
    try context.save()

    let vectorRepository = VectorRepositoryProbe()
    var factoryCalls = 0
    var temporaryIndexChecks = 0
    let result = await SemanticMemoryCoordinator.retrieve(
      query: "Luna hangi mamayı seviyor?",
      excluding: UUID(),
      sourceReader: SemanticRetrievalSourceReader(modelContainer: container),
      computeActor: SemanticRetrievalComputeActor(),
      makeVectorRepository: {
        factoryCalls += 1
        return vectorRepository
      },
      indexIsTemporary: {
        temporaryIndexChecks += 1
        return false
      }
    )

    #expect(result.items.first?.id == message.id)
    #expect(factoryCalls == 0)
    #expect(temporaryIndexChecks == 0)
    #expect(await vectorRepository.readCount == 0)
    #expect(await vectorRepository.writeCount == 0)
  }

  @MainActor
  @Test
  func modelActorSnapshotCapsEachSourceAndEmbeddingProfiles() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let sourceConversation = ConversationRecord(title: "History", modelIdentifier: "model")
    context.insert(sourceConversation)
    for index in 0..<6 {
      context.insert(
        MessageRecord(
          conversationID: sourceConversation.id,
          role: .user,
          content: "Earlier message \(index)",
          createdAt: .now.addingTimeInterval(Double(index))
        )
      )
    }
    let document = ImportedDocumentRecord(
      title: "Guide",
      sourceFilename: "guide.txt",
      mimeType: "text/plain",
      contentFingerprint: "guide",
      characterCount: 100
    )
    context.insert(document)
    for index in 0..<6 {
      context.insert(
        DocumentChunkRecord(
          documentID: document.id,
          chunkIndex: index,
          content: "Document chunk \(index)"
        )
      )
    }
    for index in 0..<3 {
      context.insert(
        EmbeddingProfileRecord(
          displayName: "Profile \(index)",
          providerConfigurationID: nil,
          modelIdentifier: "embedding-\(index)",
          updatedAt: .now.addingTimeInterval(Double(index))
        )
      )
    }
    try context.save()

    let snapshot = try await SemanticRetrievalSourceReader(
      modelContainer: container
    ).snapshot(
      excluding: UUID(),
      maximumCandidatesPerSource: 2,
      maximumProfiles: 1
    )

    #expect(snapshot.candidates.filter { $0.source == .conversationMessage }.count == 2)
    #expect(snapshot.candidates.filter { $0.source == .documentChunk }.count == 2)
    #expect(snapshot.candidates.count == 4)
    #expect(snapshot.selectedProfiles.count == 1)
    #expect(snapshot.enabledProfileCount == 3)
    #expect(snapshot.selectedProfiles.first?.displayName == "Profile 2")
  }

  @MainActor
  @Test
  func modelActorSnapshotCapsAggregateCandidatePayloadBytes() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversation = ConversationRecord(title: "Large history", modelIdentifier: "model")
    context.insert(conversation)
    let payload = String(repeating: "a", count: 200_000)
    for index in 0..<50 {
      context.insert(
        MessageRecord(
          conversationID: conversation.id,
          role: .user,
          content: "\(index)-\(payload)",
          createdAt: .now.addingTimeInterval(Double(index))
        )
      )
    }
    try context.save()

    let snapshot = try await SemanticRetrievalSourceReader(
      modelContainer: container
    ).snapshot(
      excluding: UUID(),
      maximumCandidatesPerSource: 100,
      maximumProfiles: 0
    )

    let messageCandidates = snapshot.candidates.filter {
      $0.source == .conversationMessage
    }
    #expect(messageCandidates.count < 50)
    #expect(messageCandidates.reduce(0) { $0 + $1.content.utf8.count } <= 8 * 1_024 * 1_024)
  }

  @Test
  func computeActorPropagatesStructuredCancellation() async {
    let computeActor = SemanticRetrievalComputeActor()
    let candidate = RetrievalCandidate(
      id: UUID(),
      source: .conversationMessage,
      containerID: UUID(),
      title: "Long source",
      content: String(repeating: "uzun hafıza içeriği ", count: 10_000),
      createdAt: .now
    )
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await computeActor.prepare(
        query: "hafıza",
        candidates: [candidate],
        maximumCount: 96
      )
    }

    do {
      _ = try await task.value
      Issue.record("Expected cancellation to stop local retrieval work")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func vectorPageRejectsStaleFingerprintBeforeCosineScoring() async throws {
    let profileID = UUID()
    let candidate = RetrievalCandidate(
      id: UUID(),
      source: .documentChunk,
      containerID: UUID(),
      title: "Current document",
      content: "Current content",
      createdAt: .now
    )
    let stale = SemanticStoredVectorSnapshot(
      profileID: profileID,
      sourceKind: .documentChunk,
      sourceID: candidate.id,
      embeddingSpaceIdentifier: "space",
      contentFingerprint: EmbeddingVectorCodec.fingerprint(for: "Old content"),
      dimensions: 2,
      vectorData: EmbeddingVectorCodec.encode([1, 0])
    )

    let evaluation = try await SemanticRetrievalComputeActor().evaluateVectorPage(
      queryVector: [1, 0],
      profileID: profileID,
      embeddingSpaceIdentifier: "space",
      candidates: [candidate],
      records: [stale]
    )

    #expect(evaluation.scores.isEmpty)
    #expect(evaluation.validVectorIDs.isEmpty)
  }

  @MainActor
  @Test
  func vectorRepositoryFetchesOnlyTheRequestedProfileAndCandidateIDs() async throws {
    let container = try SemanticIndexStore.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let selectedProfileID = UUID()
    let selectedSourceID = UUID()
    let otherSourceID = UUID()
    context.insert(
      EmbeddingVectorRecord(
        profileID: selectedProfileID,
        sourceKind: .conversationMessage,
        sourceID: selectedSourceID,
        embeddingSpaceIdentifier: "space",
        contentFingerprint: "selected",
        dimensions: 2,
        vectorData: EmbeddingVectorCodec.encode([1, 0])
      )
    )
    context.insert(
      EmbeddingVectorRecord(
        profileID: selectedProfileID,
        sourceKind: .conversationMessage,
        sourceID: otherSourceID,
        embeddingSpaceIdentifier: "space",
        contentFingerprint: "other source",
        dimensions: 2,
        vectorData: EmbeddingVectorCodec.encode([0, 1])
      )
    )
    context.insert(
      EmbeddingVectorRecord(
        profileID: UUID(),
        sourceKind: .conversationMessage,
        sourceID: selectedSourceID,
        embeddingSpaceIdentifier: "other space",
        contentFingerprint: "other profile",
        dimensions: 2,
        vectorData: EmbeddingVectorCodec.encode([0.5, 0.5])
      )
    )
    try context.save()

    let snapshots = try await SemanticRetrievalVectorRepository(
      modelContainer: container
    ).snapshots(
      profileID: selectedProfileID,
      candidateIDs: [selectedSourceID]
    )

    #expect(snapshots.count == 1)
    #expect(snapshots.first?.profileID == selectedProfileID)
    #expect(snapshots.first?.sourceID == selectedSourceID)
  }

  @MainActor
  @Test
  func vectorRepositoryRejectsDimensionsThatConflictWithThePersistedSpace() async throws {
    let container = try SemanticIndexStore.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let profileID = UUID()
    let existingSourceID = UUID()
    context.insert(
      EmbeddingVectorRecord(
        profileID: profileID,
        sourceKind: .conversationMessage,
        sourceID: existingSourceID,
        embeddingSpaceIdentifier: "stable-space",
        contentFingerprint: "existing",
        dimensions: 2,
        vectorData: EmbeddingVectorCodec.encode([1, 0])
      )
    )
    try context.save()

    let repository = SemanticRetrievalVectorRepository(modelContainer: container)
    let conflictingSourceID = UUID()
    let conflictingWrite = SemanticVectorWrite(
      profileID: profileID,
      sourceKind: .documentChunk,
      sourceID: conflictingSourceID,
      embeddingSpaceIdentifier: "stable-space",
      contentFingerprint: "conflicting",
      dimensions: 3,
      vectorData: EmbeddingVectorCodec.encode([0.2, 0.3, 0.5])
    )

    await #expect(throws: SemanticVectorRepositoryError.mixedEmbeddingDimensions) {
      try await repository.upsert([conflictingWrite])
    }

    try await SemanticDocumentIndexPipeline.deleteVectors(
      profileID: profileID,
      vectorContainer: container
    )
    try await repository.upsert([conflictingWrite])

    let independentSourceID = UUID()
    try await repository.upsert([
      SemanticVectorWrite(
        profileID: profileID,
        sourceKind: .documentChunk,
        sourceID: independentSourceID,
        embeddingSpaceIdentifier: "independent-space",
        contentFingerprint: "independent",
        dimensions: 3,
        vectorData: EmbeddingVectorCodec.encode([0.2, 0.3, 0.5])
      )
    ])

    let verification = ModelContext(container)
    let records = try verification.fetch(FetchDescriptor<EmbeddingVectorRecord>())
    #expect(records.count == 2)
    #expect(records.contains { $0.sourceID == conflictingSourceID && $0.dimensions == 3 })
    #expect(records.contains { $0.sourceID == independentSourceID && $0.dimensions == 3 })
  }

  @MainActor
  @Test
  func profileDeletionPurgesEveryVectorSourceKindAndPreservesOtherProfiles() async throws {
    let container = try SemanticIndexStore.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let deletedProfileID = UUID()
    let retainedProfileID = UUID()

    for sourceKind in RetrievalSourceKind.allCases {
      context.insert(
        EmbeddingVectorRecord(
          profileID: deletedProfileID,
          sourceKind: sourceKind,
          sourceID: UUID(),
          embeddingSpaceIdentifier: "deleted-space",
          contentFingerprint: sourceKind.rawValue,
          dimensions: 2,
          vectorData: EmbeddingVectorCodec.encode([1, 0])
        )
      )
    }
    let retainedSourceID = UUID()
    context.insert(
      EmbeddingVectorRecord(
        profileID: retainedProfileID,
        sourceKind: .conversationMessage,
        sourceID: retainedSourceID,
        embeddingSpaceIdentifier: "retained-space",
        contentFingerprint: "retained",
        dimensions: 2,
        vectorData: EmbeddingVectorCodec.encode([0, 1])
      )
    )
    try context.save()

    try await SemanticDocumentIndexPipeline.deleteVectors(
      profileID: deletedProfileID,
      vectorContainer: container
    )

    let verification = ModelContext(container)
    let records = try verification.fetch(FetchDescriptor<EmbeddingVectorRecord>())
    #expect(records.count == 1)
    #expect(records.first?.profileID == retainedProfileID)
    #expect(records.first?.sourceID == retainedSourceID)
  }

  @MainActor
  @Test
  func concurrentRepositoriesCannotEstablishDifferentDimensionsForAnEmptySpace() async throws {
    let container = try SemanticIndexStore.makeModelContainer(inMemory: true)
    let firstRepository = SemanticRetrievalVectorRepository(modelContainer: container)
    let secondRepository = SemanticRetrievalVectorRepository(modelContainer: container)
    let profileID = UUID()

    func attempt(
      repository: SemanticRetrievalVectorRepository,
      dimensions: Int,
      vector: [Float]
    ) async -> SemanticVectorRepositoryError? {
      do {
        try await repository.upsert([
          SemanticVectorWrite(
            profileID: profileID,
            sourceKind: .conversationMessage,
            sourceID: UUID(),
            embeddingSpaceIdentifier: "raced-space",
            contentFingerprint: UUID().uuidString,
            dimensions: dimensions,
            vectorData: EmbeddingVectorCodec.encode(vector)
          )
        ])
        return nil
      } catch let error as SemanticVectorRepositoryError {
        return error
      } catch {
        Issue.record("Unexpected repository error: \(error)")
        return .invalidVectorWrite
      }
    }

    async let firstOutcome = attempt(
      repository: firstRepository,
      dimensions: 2,
      vector: [1, 0]
    )
    async let secondOutcome = attempt(
      repository: secondRepository,
      dimensions: 3,
      vector: [0.2, 0.3, 0.5]
    )
    let outcomes = await [firstOutcome, secondOutcome]

    #expect(outcomes.filter { $0 == nil }.count == 1)
    #expect(outcomes.filter { $0 == .mixedEmbeddingDimensions }.count == 1)
    let verification = ModelContext(container)
    let records = try verification.fetch(FetchDescriptor<EmbeddingVectorRecord>())
    #expect(records.count == 1)
    #expect(Set(records.map(\.dimensions)).count == 1)
  }

  @MainActor
  @Test
  func preCancelledVectorWriteDoesNotReachTheCache() async throws {
    let container = try SemanticIndexStore.makeModelContainer(inMemory: true)
    let repository = SemanticRetrievalVectorRepository(modelContainer: container)
    let write = SemanticVectorWrite(
      profileID: UUID(),
      sourceKind: .conversationMessage,
      sourceID: UUID(),
      embeddingSpaceIdentifier: "space",
      contentFingerprint: "fingerprint",
      dimensions: 2,
      vectorData: EmbeddingVectorCodec.encode([1, 0])
    )
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await repository.upsert([write])
    }

    do {
      try await task.value
      Issue.record("Expected cancellation before the vector cache write")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let verificationContext = ModelContext(container)
    #expect(try verificationContext.fetchCount(FetchDescriptor<EmbeddingVectorRecord>()) == 0)
  }

  @MainActor
  @Test
  func postProviderValidationObservesAChangedSourceThroughAFreshContext() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversation = ConversationRecord(title: "Preferences", modelIdentifier: "model")
    let message = MessageRecord(
      conversationID: conversation.id,
      role: .user,
      content: "I prefer aisle seats."
    )
    context.insert(conversation)
    context.insert(message)
    try context.save()

    let reader = SemanticRetrievalSourceReader(modelContainer: container)
    let snapshot = try await reader.snapshot(
      excluding: UUID(),
      maximumCandidatesPerSource: 10,
      maximumProfiles: 4
    )
    let versions = try await SemanticRetrievalComputeActor().versions(
      for: snapshot.candidates
    )

    message.content = "I now prefer window seats."
    message.updatedAt = .now
    try context.save()

    let validIDs = try await reader.validCandidateIDs(for: versions)
    #expect(!validIDs.contains(message.id))
  }

  @Test
  func timeoutPreservesCompletedValidatedEmbeddingBatches() async throws {
    let provider = ProviderConnection(
      id: UUID(),
      displayName: "Slow embeddings",
      provider: .openAI,
      modelIdentifier: "embedding-test",
      apiKey: "test-only"
    )
    let profile = EmbeddingProfileSnapshot(
      id: UUID(),
      displayName: "Slow profile",
      backend: .provider,
      providerConfigurationID: provider.id,
      modelIdentifier: "embedding-test",
      weight: 1,
      isEnabled: true,
      indexesConversations: true,
      indexesDocuments: true
    )
    let candidates = (0..<33).map { index in
      RetrievalCandidate(
        id: UUID(),
        source: .conversationMessage,
        containerID: UUID(),
        title: "Candidate \(index)",
        content: "Remembered detail \(index)",
        createdAt: Date(timeIntervalSince1970: Double(index))
      )
    }
    let audience = ConversationProjectScope(
      conversationID: UUID(),
      projectID: nil,
      bindingID: nil,
      bindingUpdatedAt: nil
    )
    let client = SlowSecondBatchEmbeddingClient()
    let job = EmbeddingJob(
      profile: profile,
      providerSnapshot: provider,
      connection: provider,
      client: client,
      spaceIdentifier: "test-space",
      query: "remembered detail",
      candidates: candidates,
      candidatePool: candidates,
      audienceScope: audience
    )

    let result = try await SemanticMemoryCoordinator.run(
      job: job,
      sourceReader: AlwaysCurrentSemanticSourceReader(audienceScope: audience),
      vectorRepository: VectorRepositoryProbe(),
      computeActor: SemanticRetrievalComputeActor(),
      timeout: .milliseconds(500)
    )

    #expect(result.warning?.contains("exceeded the recall time limit") == true)
    #expect(result.writes.count == 32)
    #expect(result.writeVersions.count == 32)
    #expect(Set(result.writes.map(\.sourceID)) == Set(candidates.prefix(32).map(\.id)))
    #expect(await client.documentBatchCount == 2)
  }
}

private actor VectorRepositoryProbe: SemanticRetrievalVectorAccessing {
  private(set) var readCount = 0
  private(set) var writeCount = 0

  func snapshots(
    profileID _: UUID,
    candidateIDs _: [UUID]
  ) -> [SemanticStoredVectorSnapshot] {
    readCount += 1
    return []
  }

  func upsert(_ writes: [SemanticVectorWrite]) {
    writeCount += writes.count
  }
}

private struct AlwaysCurrentSemanticSourceReader: SemanticRetrievalSourceAccessing {
  let audienceScope: ConversationProjectScope

  func snapshot(
    excluding _: UUID,
    maximumCandidatesPerSource _: Int,
    maximumProfiles _: Int
  ) -> SemanticRetrievalSourceSnapshot {
    SemanticRetrievalSourceSnapshot(
      candidates: [],
      selectedProfiles: [],
      enabledProfileCount: 0,
      providersByID: [:],
      audienceScope: audienceScope
    )
  }

  func isCurrent(profile _: SemanticProfileVersion) -> Bool { true }

  func validCandidateIDs(for versions: [SemanticCandidateVersion]) -> Set<UUID> {
    Set(versions.map(\.id))
  }
}

private actor SlowSecondBatchEmbeddingClient: EmbeddingProviderClient {
  private(set) var documentBatchCount = 0

  func embed(
    _ inputs: [String],
    modelIdentifier _: String,
    purpose: EmbeddingInputPurpose
  ) async throws -> [[Float]] {
    if purpose == .query {
      return inputs.map { _ in [1, 0] }
    }
    documentBatchCount += 1
    if documentBatchCount == 2 {
      try await Task.sleep(for: .seconds(10))
    }
    return inputs.map { _ in [1, 0] }
  }
}

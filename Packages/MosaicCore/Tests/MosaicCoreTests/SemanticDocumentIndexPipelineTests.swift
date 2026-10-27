import SwiftData
import XCTest

@testable import MosaicCore

final class SemanticDocumentIndexPipelineTests: XCTestCase {
  @MainActor
  func testRuntimeHealthCountsPagedChunksAndVectorsExactly() async throws {
    let sourceContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let vectorContainer = try SemanticIndexStore.makeModelContainer(inMemory: true)
    let sourceContext = sourceContainer.mainContext
    let vectorContext = vectorContainer.mainContext

    let provider = ProviderConfigurationRecord(
      displayName: "Local",
      provider: .ollama,
      modelIdentifier: "chat"
    )
    let profile = EmbeddingProfileRecord(
      displayName: "Local embeddings",
      providerConfigurationID: provider.id,
      modelIdentifier: "qwen3-embedding:0.6b"
    )
    let document = ImportedDocumentRecord(
      title: "Large guide",
      sourceFilename: "guide.txt",
      mimeType: "text/plain",
      contentFingerprint: "large-guide",
      characterCount: 300_000
    )
    sourceContext.insert(provider)
    sourceContext.insert(profile)
    sourceContext.insert(document)
    let connection = ProviderConnection(
      id: provider.id,
      displayName: provider.displayName,
      provider: provider.provider,
      baseURL: provider.baseURL,
      modelIdentifier: provider.modelIdentifier
    )
    let spaceIdentifier = EmbeddingInputFormatter.spaceIdentifier(
      connection: connection,
      modelIdentifier: profile.modelIdentifier
    )
    for index in 0..<300 {
      let chunk = DocumentChunkRecord(
        documentID: document.id,
        chunkIndex: index,
        content: "Chunk \(index)"
      )
      sourceContext.insert(chunk)
      vectorContext.insert(
        EmbeddingVectorRecord(
          profileID: profile.id,
          sourceKind: .documentChunk,
          sourceID: chunk.id,
          embeddingSpaceIdentifier: spaceIdentifier,
          contentFingerprint: EmbeddingVectorCodec.fingerprint(for: chunk.content),
          dimensions: 2,
          vectorData: EmbeddingVectorCodec.encode([0.25, 0.75])
        )
      )
    }
    vectorContext.insert(
      EmbeddingVectorRecord(
        profileID: profile.id,
        sourceKind: .documentChunk,
        sourceID: UUID(),
        embeddingSpaceIdentifier: spaceIdentifier,
        contentFingerprint: "orphan",
        dimensions: 2,
        vectorData: EmbeddingVectorCodec.encode([0.5, 0.5])
      )
    )
    try sourceContext.save()
    try vectorContext.save()

    let health = try await SemanticDocumentIndexPipeline.health(
      sourceContainer: sourceContainer,
      vectorContainer: vectorContainer,
      isTemporary: false
    )

    XCTAssertEqual(health.enabledDocumentCount, 1)
    XCTAssertEqual(health.chunkCount, 300)
    XCTAssertEqual(health.storedVectorCount, 301)
    XCTAssertEqual(health.validVectorCount, 300)
    XCTAssertEqual(health.missingVectorCount, 0)
    XCTAssertEqual(health.staleVectorCount, 0)
    XCTAssertEqual(health.orphanVectorCount, 1)
    XCTAssertEqual(health.profiles.first?.indexedDocumentCount, 1)
  }

  @MainActor
  func testRuntimeHealthDetectsMixedDimensionsBeyondTheFirstVectorPage() async throws {
    let sourceContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let vectorContainer = try SemanticIndexStore.makeModelContainer(inMemory: true)
    let sourceContext = sourceContainer.mainContext
    let vectorContext = vectorContainer.mainContext

    let provider = ProviderConfigurationRecord(
      displayName: "Local",
      provider: .ollama,
      modelIdentifier: "chat"
    )
    let profile = EmbeddingProfileRecord(
      displayName: "Local embeddings",
      providerConfigurationID: provider.id,
      modelIdentifier: "qwen3-embedding:0.6b"
    )
    let document = ImportedDocumentRecord(
      title: "Paged guide",
      sourceFilename: "paged-guide.txt",
      mimeType: "text/plain",
      contentFingerprint: "paged-guide",
      characterCount: 129_000
    )
    sourceContext.insert(provider)
    sourceContext.insert(profile)
    sourceContext.insert(document)
    let connection = ProviderConnection(
      id: provider.id,
      displayName: provider.displayName,
      provider: provider.provider,
      baseURL: provider.baseURL,
      modelIdentifier: provider.modelIdentifier
    )
    let spaceIdentifier = EmbeddingInputFormatter.spaceIdentifier(
      connection: connection,
      modelIdentifier: profile.modelIdentifier
    )
    for index in 0..<129 {
      let chunk = DocumentChunkRecord(
        documentID: document.id,
        chunkIndex: index,
        content: "Chunk \(index)"
      )
      sourceContext.insert(chunk)
      let vector: [Float] = index == 128 ? [0.2, 0.3, 0.5] : [0.25, 0.75]
      vectorContext.insert(
        EmbeddingVectorRecord(
          profileID: profile.id,
          sourceKind: .documentChunk,
          sourceID: chunk.id,
          embeddingSpaceIdentifier: spaceIdentifier,
          contentFingerprint: EmbeddingVectorCodec.fingerprint(for: chunk.content),
          dimensions: vector.count,
          vectorData: EmbeddingVectorCodec.encode(vector)
        )
      )
    }
    try sourceContext.save()
    try vectorContext.save()

    let health = try await SemanticDocumentIndexPipeline.health(
      sourceContainer: sourceContainer,
      vectorContainer: vectorContainer,
      isTemporary: false
    )

    XCTAssertEqual(health.validVectorCount, 0)
    XCTAssertEqual(health.staleVectorCount, 129)
    XCTAssertEqual(health.missingVectorCount, 0)
    XCTAssertEqual(health.profiles.first?.indexedDocumentCount, 0)
    XCTAssertTrue(health.needsAttention)
  }

  @MainActor
  func testRuntimeHealthUsesTheSameGlobalFourProfileCohortAsRetrieval() async throws {
    let sourceContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let vectorContainer = try SemanticIndexStore.makeModelContainer(inMemory: true)
    let context = sourceContainer.mainContext
    let baseDate = Date(timeIntervalSinceReferenceDate: 1_000)

    var documentProfileIDs: [UUID] = []
    for index in 0..<4 {
      let profile = EmbeddingProfileRecord(
        displayName: "Document profile \(index)",
        providerConfigurationID: nil,
        modelIdentifier: "document-\(index)",
        indexesConversations: false,
        indexesDocuments: true,
        updatedAt: baseDate.addingTimeInterval(Double(index))
      )
      documentProfileIDs.append(profile.id)
      context.insert(profile)
    }
    context.insert(
      EmbeddingProfileRecord(
        displayName: "Newest chat-only profile",
        providerConfigurationID: nil,
        modelIdentifier: "chat-only",
        indexesConversations: true,
        indexesDocuments: false,
        updatedAt: baseDate.addingTimeInterval(100)
      )
    )
    try context.save()

    let health = try await SemanticDocumentIndexPipeline.health(
      sourceContainer: sourceContainer,
      vectorContainer: vectorContainer,
      isTemporary: false
    )

    let limitedIDs = Set(
      health.profiles.filter { $0.availability == .profileLimitExceeded }.map(\.profileID)
    )
    XCTAssertEqual(limitedIDs, Set([documentProfileIDs[0]]))
    XCTAssertEqual(health.profiles.filter { $0.availability == .providerUnavailable }.count, 3)
  }

  @MainActor
  func testRebuildClearsOnlyDocumentVectorPartitionAcrossPages() async throws {
    let sourceContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let vectorContainer = try SemanticIndexStore.makeModelContainer(inMemory: true)
    let sourceContext = sourceContainer.mainContext
    let vectorContext = vectorContainer.mainContext
    let profileID = UUID()
    for _ in 0..<300 {
      vectorContext.insert(
        EmbeddingVectorRecord(
          profileID: profileID,
          sourceKind: .documentChunk,
          sourceID: UUID(),
          embeddingSpaceIdentifier: "documents",
          contentFingerprint: "chunk",
          dimensions: 2,
          vectorData: EmbeddingVectorCodec.encode([0.1, 0.9])
        )
      )
    }
    let conversationVector = EmbeddingVectorRecord(
      profileID: profileID,
      sourceKind: .conversationMessage,
      sourceID: UUID(),
      embeddingSpaceIdentifier: "conversations",
      contentFingerprint: "message",
      dimensions: 2,
      vectorData: EmbeddingVectorCodec.encode([0.9, 0.1])
    )
    let disabledProfile = EmbeddingProfileRecord(
      displayName: "Disabled",
      providerConfigurationID: nil,
      modelIdentifier: "disabled",
      isEnabled: false
    )
    let disabledDocument = ImportedDocumentRecord(
      title: "Disabled source",
      sourceFilename: "disabled.txt",
      mimeType: "text/plain",
      contentFingerprint: "disabled-source",
      characterCount: 10,
      isEnabled: false
    )
    let retainedChunk = DocumentChunkRecord(
      documentID: disabledDocument.id,
      chunkIndex: 0,
      content: "Retained source"
    )
    sourceContext.insert(disabledProfile)
    sourceContext.insert(disabledDocument)
    sourceContext.insert(retainedChunk)
    let retainedDisabledVector = EmbeddingVectorRecord(
      profileID: disabledProfile.id,
      sourceKind: .documentChunk,
      sourceID: retainedChunk.id,
      embeddingSpaceIdentifier: "disabled",
      contentFingerprint: EmbeddingVectorCodec.fingerprint(for: retainedChunk.content),
      dimensions: 2,
      vectorData: EmbeddingVectorCodec.encode([0.2, 0.8])
    )
    vectorContext.insert(conversationVector)
    vectorContext.insert(retainedDisabledVector)
    try sourceContext.save()
    try vectorContext.save()

    let warnings = try await SemanticDocumentIndexPipeline.rebuildAllEnabledDocuments(
      sourceContainer: sourceContainer,
      vectorContainer: vectorContainer,
      isTemporary: false
    )

    XCTAssertTrue(warnings.isEmpty)
    let verificationContext = ModelContext(vectorContainer)
    let remaining = try verificationContext.fetch(FetchDescriptor<EmbeddingVectorRecord>())
    XCTAssertEqual(
      Set(remaining.map(\.id)),
      Set([conversationVector.id, retainedDisabledVector.id])
    )
  }
}

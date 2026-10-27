import Foundation
import XCTest

@testable import MosaicCore

final class SemanticDocumentIndexHealthTests: XCTestCase {
  @MainActor
  func testOnlyCurrentSpaceFingerprintAndDecodableVectorsCountAsReady() {
    let provider = ProviderConfigurationRecord(
      displayName: "DeepInfra",
      provider: .deepInfra,
      modelIdentifier: "chat-model"
    )
    let profile = EmbeddingProfileRecord(
      displayName: "Qwen",
      providerConfigurationID: provider.id,
      modelIdentifier: "Qwen/Qwen3-Embedding-0.6B"
    )
    let document = ImportedDocumentRecord(
      title: "Guide",
      sourceFilename: "guide.txt",
      mimeType: "text/plain",
      contentFingerprint: "document",
      characterCount: 30
    )
    let currentChunk = DocumentChunkRecord(
      documentID: document.id,
      chunkIndex: 0,
      content: "Current content"
    )
    let staleChunk = DocumentChunkRecord(
      documentID: document.id,
      chunkIndex: 1,
      content: "Changed content"
    )
    let missingChunk = DocumentChunkRecord(
      documentID: document.id,
      chunkIndex: 2,
      content: "Missing content"
    )
    let expectedSpace = EmbeddingInputFormatter.spaceIdentifier(
      connection: ProviderConnection(
        id: provider.id,
        displayName: provider.displayName,
        provider: provider.provider,
        baseURL: provider.baseURL,
        modelIdentifier: provider.modelIdentifier
      ),
      modelIdentifier: profile.modelIdentifier
    )
    let currentVector = EmbeddingVectorRecord(
      profileID: profile.id,
      sourceKind: .documentChunk,
      sourceID: currentChunk.id,
      embeddingSpaceIdentifier: expectedSpace,
      contentFingerprint: EmbeddingVectorCodec.fingerprint(for: currentChunk.content),
      dimensions: 2,
      vectorData: EmbeddingVectorCodec.encode([0.2, 0.8])
    )
    let staleVector = EmbeddingVectorRecord(
      profileID: profile.id,
      sourceKind: .documentChunk,
      sourceID: staleChunk.id,
      embeddingSpaceIdentifier: "old-space",
      contentFingerprint: EmbeddingVectorCodec.fingerprint(for: staleChunk.content),
      dimensions: 2,
      vectorData: EmbeddingVectorCodec.encode([0.5, 0.5])
    )
    let orphanVector = EmbeddingVectorRecord(
      profileID: profile.id,
      sourceKind: .documentChunk,
      sourceID: UUID(),
      embeddingSpaceIdentifier: expectedSpace,
      contentFingerprint: "orphan",
      dimensions: 2,
      vectorData: EmbeddingVectorCodec.encode([0.1, 0.9])
    )

    let health = SemanticDocumentIndexer.health(
      documents: [document],
      chunks: [currentChunk, staleChunk, missingChunk],
      profiles: [profile],
      providers: [provider],
      vectors: [currentVector, staleVector, orphanVector]
    )

    XCTAssertEqual(health.enabledDocumentCount, 1)
    XCTAssertEqual(health.chunkCount, 3)
    XCTAssertEqual(health.storedVectorCount, 3)
    XCTAssertEqual(health.validVectorCount, 1)
    XCTAssertEqual(health.staleVectorCount, 1)
    XCTAssertEqual(health.missingVectorCount, 1)
    XCTAssertEqual(health.orphanVectorCount, 1)
    XCTAssertEqual(health.profiles.first?.indexedDocumentCount, 0)
    XCTAssertTrue(health.needsAttention)
  }

  @MainActor
  func testMixedDimensionsInvalidateEveryVectorInTheEmbeddingSpace() {
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
      title: "Guide",
      sourceFilename: "guide.txt",
      mimeType: "text/plain",
      contentFingerprint: "guide",
      characterCount: 20
    )
    let chunks = [
      DocumentChunkRecord(
        documentID: document.id,
        chunkIndex: 0,
        content: "First chunk"
      ),
      DocumentChunkRecord(
        documentID: document.id,
        chunkIndex: 1,
        content: "Second chunk"
      ),
    ]
    let space = EmbeddingInputFormatter.spaceIdentifier(
      connection: ProviderConnection(
        id: provider.id,
        displayName: provider.displayName,
        provider: provider.provider,
        baseURL: provider.baseURL,
        modelIdentifier: provider.modelIdentifier
      ),
      modelIdentifier: profile.modelIdentifier
    )
    let vectors = [
      EmbeddingVectorRecord(
        profileID: profile.id,
        sourceKind: .documentChunk,
        sourceID: chunks[0].id,
        embeddingSpaceIdentifier: space,
        contentFingerprint: EmbeddingVectorCodec.fingerprint(for: chunks[0].content),
        dimensions: 2,
        vectorData: EmbeddingVectorCodec.encode([0.2, 0.8])
      ),
      EmbeddingVectorRecord(
        profileID: profile.id,
        sourceKind: .documentChunk,
        sourceID: chunks[1].id,
        embeddingSpaceIdentifier: space,
        contentFingerprint: EmbeddingVectorCodec.fingerprint(for: chunks[1].content),
        dimensions: 3,
        vectorData: EmbeddingVectorCodec.encode([0.2, 0.3, 0.5])
      ),
    ]

    let health = SemanticDocumentIndexer.health(
      documents: [document],
      chunks: chunks,
      profiles: [profile],
      providers: [provider],
      vectors: vectors
    )

    XCTAssertEqual(health.validVectorCount, 0)
    XCTAssertEqual(health.staleVectorCount, 2)
    XCTAssertEqual(health.missingVectorCount, 0)
    XCTAssertEqual(health.profiles.first?.indexedDocumentCount, 0)
    XCTAssertTrue(health.needsAttention)
  }

  @MainActor
  func testCompleteCoverageRequiresEveryChunkAndIgnoresDisabledDocuments() {
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
    let enabledDocument = ImportedDocumentRecord(
      title: "Enabled",
      sourceFilename: "enabled.txt",
      mimeType: "text/plain",
      contentFingerprint: "enabled",
      characterCount: 10
    )
    let disabledDocument = ImportedDocumentRecord(
      title: "Disabled",
      sourceFilename: "disabled.txt",
      mimeType: "text/plain",
      contentFingerprint: "disabled",
      characterCount: 10,
      isEnabled: false
    )
    let enabledChunk = DocumentChunkRecord(
      documentID: enabledDocument.id,
      chunkIndex: 0,
      content: "Enabled text"
    )
    let disabledChunk = DocumentChunkRecord(
      documentID: disabledDocument.id,
      chunkIndex: 0,
      content: "Disabled text"
    )
    let space = EmbeddingInputFormatter.spaceIdentifier(
      connection: ProviderConnection(
        id: provider.id,
        displayName: provider.displayName,
        provider: provider.provider,
        baseURL: provider.baseURL,
        modelIdentifier: provider.modelIdentifier
      ),
      modelIdentifier: profile.modelIdentifier
    )
    let vector = EmbeddingVectorRecord(
      profileID: profile.id,
      sourceKind: .documentChunk,
      sourceID: enabledChunk.id,
      embeddingSpaceIdentifier: space,
      contentFingerprint: EmbeddingVectorCodec.fingerprint(for: enabledChunk.content),
      dimensions: 2,
      vectorData: EmbeddingVectorCodec.encode([1, 0])
    )

    let health = SemanticDocumentIndexer.health(
      documents: [enabledDocument, disabledDocument],
      chunks: [enabledChunk, disabledChunk],
      profiles: [profile],
      providers: [provider],
      vectors: [vector]
    )

    XCTAssertEqual(health.enabledDocumentCount, 1)
    XCTAssertEqual(health.chunkCount, 1)
    XCTAssertEqual(health.profiles.first?.indexedDocumentCount, 1)
    XCTAssertEqual(health.validVectorCount, 1)
    XCTAssertFalse(health.needsAttention)
  }

  @MainActor
  func testUnavailableAndFifthProfilesAreNeverReportedReady() {
    let provider = ProviderConfigurationRecord(
      displayName: "Disabled provider",
      provider: .deepInfra,
      modelIdentifier: "chat",
      isEnabled: false
    )
    let baseDate = Date(timeIntervalSince1970: 1_000)
    let profiles = (0..<5).map { index in
      EmbeddingProfileRecord(
        displayName: "Profile \(index)",
        providerConfigurationID: provider.id,
        modelIdentifier: "embedding",
        updatedAt: baseDate.addingTimeInterval(Double(index))
      )
    }
    let document = ImportedDocumentRecord(
      title: "Notes",
      sourceFilename: "notes.txt",
      mimeType: "text/plain",
      contentFingerprint: "notes",
      characterCount: 5
    )
    let chunk = DocumentChunkRecord(
      documentID: document.id,
      chunkIndex: 0,
      content: "Notes"
    )

    let health = SemanticDocumentIndexer.health(
      documents: [document],
      chunks: [chunk],
      profiles: profiles,
      providers: [provider],
      vectors: []
    )

    XCTAssertEqual(health.profiles.count, 5)
    XCTAssertEqual(health.profiles.filter { $0.availability == .providerUnavailable }.count, 4)
    XCTAssertEqual(health.profiles.filter { $0.availability == .profileLimitExceeded }.count, 1)
    XCTAssertEqual(health.validVectorCount, 0)
    XCTAssertEqual(health.missingVectorCount, 5)
    XCTAssertTrue(health.needsAttention)
  }

  @MainActor
  func testChatOnlyProfileDisplacesOldestDocumentProfileAcrossHelperPaths() {
    let provider = ProviderConfigurationRecord(
      displayName: "DeepInfra",
      provider: .deepInfra,
      modelIdentifier: "chat"
    )
    let baseDate = Date(timeIntervalSince1970: 1_000)
    let documentProfiles = (0..<4).map { index in
      EmbeddingProfileRecord(
        displayName: "Document \(index)",
        providerConfigurationID: provider.id,
        modelIdentifier: "embedding",
        updatedAt: baseDate.addingTimeInterval(Double(index))
      )
    }
    let chatOnly = EmbeddingProfileRecord(
      displayName: "Chat only",
      providerConfigurationID: provider.id,
      modelIdentifier: "embedding",
      indexesDocuments: false,
      updatedAt: baseDate.addingTimeInterval(10)
    )
    let document = ImportedDocumentRecord(
      title: "Notes",
      sourceFilename: "notes.txt",
      mimeType: "text/plain",
      contentFingerprint: "notes",
      characterCount: 5
    )
    let chunk = DocumentChunkRecord(
      documentID: document.id,
      chunkIndex: 0,
      content: "Notes"
    )
    let oldest = documentProfiles[0]
    let newest = documentProfiles[3]
    func vector(for profile: EmbeddingProfileRecord) -> EmbeddingVectorRecord {
      EmbeddingVectorRecord(
        profileID: profile.id,
        sourceKind: .documentChunk,
        sourceID: chunk.id,
        embeddingSpaceIdentifier: "space",
        contentFingerprint: EmbeddingVectorCodec.fingerprint(for: chunk.content),
        dimensions: 2,
        vectorData: EmbeddingVectorCodec.encode([1, 0])
      )
    }
    let oldestVector = vector(for: oldest)
    let newestVector = vector(for: newest)
    let profiles = documentProfiles + [chatOnly]

    let health = SemanticDocumentIndexer.health(
      documents: [document],
      chunks: [chunk],
      profiles: profiles,
      providers: [provider],
      vectors: []
    )
    XCTAssertEqual(
      health.profiles.first { $0.profileID == oldest.id }?.availability,
      .profileLimitExceeded
    )
    XCTAssertEqual(
      health.profiles.first { $0.profileID == newest.id }?.availability,
      .available
    )

    let deletedIDs = SemanticDocumentIndexer.documentVectorIDsToDeleteForRebuild(
      profiles: profiles,
      chunks: [chunk],
      vectors: [oldestVector, newestVector]
    )
    XCTAssertFalse(deletedIDs.contains(oldestVector.id))
    XCTAssertTrue(deletedIDs.contains(newestVector.id))

    let validation = SemanticDocumentIndexer.documentIndexWriteValidationState(
      documents: [document],
      chunks: [chunk],
      profiles: profiles,
      providers: [provider]
    )
    let connection = ProviderConnection(
      id: provider.id,
      displayName: provider.displayName,
      provider: provider.provider,
      baseURL: provider.baseURL,
      modelIdentifier: provider.modelIdentifier
    )
    let space = EmbeddingInputFormatter.spaceIdentifier(
      connection: connection,
      modelIdentifier: newest.modelIdentifier
    )
    let fingerprint = EmbeddingVectorCodec.fingerprint(for: chunk.content)
    XCTAssertFalse(
      validation.accepts(
        profileID: oldest.id,
        providerID: provider.id,
        sourceID: chunk.id,
        documentID: document.id,
        spaceIdentifier: space,
        contentFingerprint: fingerprint
      )
    )
    XCTAssertTrue(
      validation.accepts(
        profileID: newest.id,
        providerID: provider.id,
        sourceID: chunk.id,
        documentID: document.id,
        spaceIdentifier: space,
        contentFingerprint: fingerprint
      )
    )
  }

  @MainActor
  func testDanglingVectorsRequireAMissingProfileOrChunk() {
    let provider = ProviderConfigurationRecord(
      displayName: "Local",
      provider: .ollama,
      modelIdentifier: "chat"
    )
    let activeProfile = EmbeddingProfileRecord(
      displayName: "Active",
      providerConfigurationID: provider.id,
      modelIdentifier: "embedding"
    )
    let disabledProfile = EmbeddingProfileRecord(
      displayName: "Disabled",
      providerConfigurationID: provider.id,
      modelIdentifier: "embedding",
      isEnabled: false
    )
    let document = ImportedDocumentRecord(
      title: "Enabled",
      sourceFilename: "enabled.txt",
      mimeType: "text/plain",
      contentFingerprint: "enabled",
      characterCount: 12
    )
    let disabledDocument = ImportedDocumentRecord(
      title: "Disabled",
      sourceFilename: "disabled.txt",
      mimeType: "text/plain",
      contentFingerprint: "disabled",
      characterCount: 13,
      isEnabled: false
    )
    let chunk = DocumentChunkRecord(
      documentID: document.id,
      chunkIndex: 0,
      content: "Enabled text"
    )
    let disabledChunk = DocumentChunkRecord(
      documentID: disabledDocument.id,
      chunkIndex: 0,
      content: "Disabled text"
    )
    let space = EmbeddingInputFormatter.spaceIdentifier(
      connection: ProviderConnection(
        id: provider.id,
        displayName: provider.displayName,
        provider: provider.provider,
        baseURL: provider.baseURL,
        modelIdentifier: provider.modelIdentifier
      ),
      modelIdentifier: activeProfile.modelIdentifier
    )
    func vector(profileID: UUID, sourceID: UUID) -> EmbeddingVectorRecord {
      EmbeddingVectorRecord(
        profileID: profileID,
        sourceKind: .documentChunk,
        sourceID: sourceID,
        embeddingSpaceIdentifier: space,
        contentFingerprint: EmbeddingVectorCodec.fingerprint(for: chunk.content),
        dimensions: 2,
        vectorData: EmbeddingVectorCodec.encode([1, 0])
      )
    }
    let activeVector = vector(profileID: activeProfile.id, sourceID: chunk.id)
    let retainedDisabledVector = vector(
      profileID: disabledProfile.id,
      sourceID: disabledChunk.id
    )
    let deletedProfileVector = vector(profileID: UUID(), sourceID: chunk.id)
    let deletedChunkVector = vector(profileID: activeProfile.id, sourceID: UUID())
    let conversationVector = EmbeddingVectorRecord(
      profileID: activeProfile.id,
      sourceKind: .conversationMessage,
      sourceID: UUID(),
      embeddingSpaceIdentifier: space,
      contentFingerprint: "conversation",
      dimensions: 2,
      vectorData: EmbeddingVectorCodec.encode([0, 1])
    )

    let health = SemanticDocumentIndexer.health(
      documents: [document, disabledDocument],
      chunks: [chunk, disabledChunk],
      profiles: [activeProfile, disabledProfile],
      providers: [provider],
      vectors: [
        activeVector,
        retainedDisabledVector,
        deletedProfileVector,
        deletedChunkVector,
        conversationVector,
      ]
    )

    XCTAssertEqual(health.storedVectorCount, 4)
    XCTAssertEqual(health.orphanVectorCount, 2)
    XCTAssertEqual(
      SemanticDocumentIndexer.danglingDocumentVectorIDs(
        profiles: [activeProfile, disabledProfile],
        chunks: [chunk, disabledChunk],
        vectors: [
          activeVector,
          retainedDisabledVector,
          deletedProfileVector,
          deletedChunkVector,
          conversationVector,
        ]
      ),
      Set([deletedProfileVector.id, deletedChunkVector.id])
    )
  }

  @MainActor
  func testRebuildDeletesActiveAndDanglingVectorsButRetainsFifthProfileCache() {
    let baseDate = Date(timeIntervalSince1970: 2_000)
    let profiles = (0..<5).map { index in
      EmbeddingProfileRecord(
        displayName: "Profile \(index)",
        providerConfigurationID: UUID(),
        modelIdentifier: "embedding",
        updatedAt: baseDate.addingTimeInterval(Double(index))
      )
    }
    let document = ImportedDocumentRecord(
      title: "Document",
      sourceFilename: "document.txt",
      mimeType: "text/plain",
      contentFingerprint: "document",
      characterCount: 8
    )
    let chunk = DocumentChunkRecord(
      documentID: document.id,
      chunkIndex: 0,
      content: "Document"
    )
    func vector(
      profileID: UUID,
      sourceKind: RetrievalSourceKind = .documentChunk,
      sourceID: UUID
    ) -> EmbeddingVectorRecord {
      EmbeddingVectorRecord(
        profileID: profileID,
        sourceKind: sourceKind,
        sourceID: sourceID,
        embeddingSpaceIdentifier: "space",
        contentFingerprint: "fingerprint",
        dimensions: 2,
        vectorData: EmbeddingVectorCodec.encode([1, 0])
      )
    }
    let activeVector = vector(profileID: profiles[4].id, sourceID: chunk.id)
    let fifthProfileVector = vector(profileID: profiles[0].id, sourceID: chunk.id)
    let fifthProfileDanglingVector = vector(profileID: profiles[0].id, sourceID: UUID())
    let deletedProfileVector = vector(profileID: UUID(), sourceID: chunk.id)
    let conversationVector = vector(
      profileID: profiles[4].id,
      sourceKind: .conversationMessage,
      sourceID: UUID()
    )

    let deletedIDs = SemanticDocumentIndexer.documentVectorIDsToDeleteForRebuild(
      profiles: profiles,
      chunks: [chunk],
      vectors: [
        activeVector,
        fifthProfileVector,
        fifthProfileDanglingVector,
        deletedProfileVector,
        conversationVector,
      ]
    )

    XCTAssertTrue(deletedIDs.contains(activeVector.id))
    XCTAssertTrue(deletedIDs.contains(fifthProfileDanglingVector.id))
    XCTAssertTrue(deletedIDs.contains(deletedProfileVector.id))
    XCTAssertFalse(deletedIDs.contains(fifthProfileVector.id))
    XCTAssertFalse(deletedIDs.contains(conversationVector.id))
  }

  @MainActor
  func testWriteValidationRejectsChangedProfileProviderSpaceAndChunk() {
    let provider = ProviderConfigurationRecord(
      displayName: "DeepInfra",
      provider: .deepInfra,
      modelIdentifier: "chat"
    )
    let profile = EmbeddingProfileRecord(
      displayName: "Qwen",
      providerConfigurationID: provider.id,
      modelIdentifier: "Qwen/Qwen3-Embedding-0.6B"
    )
    let document = ImportedDocumentRecord(
      title: "Guide",
      sourceFilename: "guide.txt",
      mimeType: "text/plain",
      contentFingerprint: "guide",
      characterCount: 12
    )
    let chunk = DocumentChunkRecord(
      documentID: document.id,
      chunkIndex: 0,
      content: "Current text"
    )
    let connection = ProviderConnection(
      id: provider.id,
      displayName: provider.displayName,
      provider: provider.provider,
      baseURL: provider.baseURL,
      modelIdentifier: provider.modelIdentifier
    )
    let space = EmbeddingInputFormatter.spaceIdentifier(
      connection: connection,
      modelIdentifier: profile.modelIdentifier
    )
    let fingerprint = EmbeddingVectorCodec.fingerprint(for: chunk.content)
    let state = SemanticDocumentIndexer.documentIndexWriteValidationState(
      documents: [document],
      chunks: [chunk],
      profiles: [profile],
      providers: [provider]
    )

    XCTAssertTrue(
      state.accepts(
        profileID: profile.id,
        providerID: provider.id,
        sourceID: chunk.id,
        documentID: document.id,
        spaceIdentifier: space,
        contentFingerprint: fingerprint
      )
    )
    XCTAssertFalse(
      state.accepts(
        profileID: profile.id,
        providerID: UUID(),
        sourceID: chunk.id,
        documentID: document.id,
        spaceIdentifier: space,
        contentFingerprint: fingerprint
      )
    )
    XCTAssertFalse(
      state.accepts(
        profileID: profile.id,
        providerID: provider.id,
        sourceID: chunk.id,
        documentID: document.id,
        spaceIdentifier: "changed-space",
        contentFingerprint: fingerprint
      )
    )
    XCTAssertFalse(
      state.accepts(
        profileID: profile.id,
        providerID: provider.id,
        sourceID: chunk.id,
        documentID: UUID(),
        spaceIdentifier: space,
        contentFingerprint: fingerprint
      )
    )
    XCTAssertFalse(
      state.accepts(
        profileID: profile.id,
        providerID: provider.id,
        sourceID: chunk.id,
        documentID: document.id,
        spaceIdentifier: space,
        contentFingerprint: "changed-fingerprint"
      )
    )

    let stateAfterProfileDeletion = SemanticDocumentIndexer.documentIndexWriteValidationState(
      documents: [document],
      chunks: [chunk],
      profiles: [],
      providers: [provider]
    )
    XCTAssertFalse(
      stateAfterProfileDeletion.accepts(
        profileID: profile.id,
        providerID: provider.id,
        sourceID: chunk.id,
        documentID: document.id,
        spaceIdentifier: space,
        contentFingerprint: fingerprint
      )
    )

    let changedChunk = DocumentChunkRecord(
      id: chunk.id,
      documentID: document.id,
      chunkIndex: 0,
      content: "Changed text"
    )
    let stateAfterChunkChange = SemanticDocumentIndexer.documentIndexWriteValidationState(
      documents: [document],
      chunks: [changedChunk],
      profiles: [profile],
      providers: [provider]
    )
    XCTAssertFalse(
      stateAfterChunkChange.accepts(
        profileID: profile.id,
        providerID: provider.id,
        sourceID: chunk.id,
        documentID: document.id,
        spaceIdentifier: space,
        contentFingerprint: fingerprint
      )
    )
  }
}

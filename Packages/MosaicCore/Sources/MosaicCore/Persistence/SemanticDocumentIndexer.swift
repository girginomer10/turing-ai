import Foundation
import SwiftData

public enum SemanticDocumentIndexer {
  private static let batchSize = 32
  private static let maximumProfiles = 4

  /// Describes the rebuildable document-vector cache without treating stale data as ready.
  @MainActor
  static func health(in modelContext: ModelContext) async throws -> SemanticDocumentIndexHealth {
    try await SemanticDocumentIndexPipeline.health(
      sourceContainer: modelContext.container,
      vectorContainer: SemanticIndexStore.shared,
      isTemporary: SemanticIndexStore.didFallBackToMemory
    )
  }

  /// Pure health calculation kept separate from the persistent stores for deterministic tests.
  @MainActor
  static func health(
    documents: [ImportedDocumentRecord],
    chunks: [DocumentChunkRecord],
    profiles: [EmbeddingProfileRecord],
    providers: [ProviderConfigurationRecord],
    vectors: [EmbeddingVectorRecord],
    isTemporary: Bool = false
  ) -> SemanticDocumentIndexHealth {
    health(
      documents: documents.map(SemanticHealthDocumentSnapshot.init),
      chunks: chunks.map(SemanticHealthChunkSnapshot.init),
      profiles: profiles.map(SemanticHealthProfileSnapshot.init),
      providers: providers.map(SemanticHealthProviderSnapshot.init),
      vectorSnapshots: vectors.map(SemanticDocumentVectorHealthSnapshot.init),
      isTemporary: isTemporary
    )
  }

  private static func health(
    documents: [SemanticHealthDocumentSnapshot],
    chunks: [SemanticHealthChunkSnapshot],
    profiles: [SemanticHealthProfileSnapshot],
    providers: [SemanticHealthProviderSnapshot],
    vectorSnapshots: [SemanticDocumentVectorHealthSnapshot],
    isTemporary: Bool
  ) -> SemanticDocumentIndexHealth {
    let enabledDocuments = documents.filter(\.isEnabled)
    let enabledDocumentIDs = Set(enabledDocuments.map(\.id))
    let eligibleChunks = chunks.filter {
      enabledDocumentIDs.contains($0.documentID)
        && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let enabledProfiles =
      profiles
      .filter { $0.isEnabled && $0.indexesDocuments }
      .sorted { lhs, rhs in
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
      }
    let activeProfileIDs = Set(
      profiles
        .filter(\.isEnabled)
        .sorted { lhs, rhs in
          if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
          return lhs.id.uuidString < rhs.id.uuidString
        }
        .prefix(maximumProfiles)
        .filter(\.indexesDocuments)
        .map(\.id)
    )
    let enabledProfileIDs = Set(enabledProfiles.map(\.id))
    let providersByID = Dictionary(
      providers.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let documentVectors = vectorSnapshots.filter { $0.sourceKind == .documentChunk }
    let relevantVectors = documentVectors.filter {
      enabledProfileIDs.contains($0.profileID) && $0.sourceKind == .documentChunk
    }
    let recordsByKey = Dictionary(
      relevantVectors.map { (IndexVectorKey(profileID: $0.profileID, sourceID: $0.sourceID), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var dimensionsBySpace: [SemanticEmbeddingSpaceKey: Set<Int>] = [:]
    for vector in vectorSnapshots {
      dimensionsBySpace[
        SemanticEmbeddingSpaceKey(
          profileID: vector.profileID,
          embeddingSpaceIdentifier: vector.embeddingSpaceIdentifier
        ),
        default: []
      ].insert(vector.dimensions)
    }
    let mixedDimensionSpaces = Set(
      dimensionsBySpace.compactMap { key, dimensions in
        dimensions.count > 1 ? key : nil
      }
    )

    let chunksByDocumentID = Dictionary(grouping: eligibleChunks, by: \.documentID)
    var profileHealth: [SemanticDocumentProfileHealth] = []
    for profile in enabledProfiles {
      let availability: SemanticDocumentProfileAvailability
      let expectedSpaceIdentifier: String?
      if !activeProfileIDs.contains(profile.id) {
        availability = .profileLimitExceeded
        expectedSpaceIdentifier = nil
      } else if let providerID = profile.providerConfigurationID,
        let provider = providersByID[providerID],
        provider.isEnabled,
        provider.provider.supportsEmbeddings
      {
        availability = .available
        let connection = ProviderConnection(
          id: provider.id,
          displayName: provider.displayName,
          provider: provider.provider,
          baseURL: provider.baseURL,
          modelIdentifier: provider.modelIdentifier
        )
        expectedSpaceIdentifier = EmbeddingInputFormatter.spaceIdentifier(
          connection: connection,
          modelIdentifier: profile.modelIdentifier
        )
      } else {
        availability = .providerUnavailable
        expectedSpaceIdentifier = nil
      }

      var validChunkIDs: Set<UUID> = []
      var staleVectorCount = 0
      var missingVectorCount = 0
      let hasMixedVectorDimensions =
        expectedSpaceIdentifier.map {
          mixedDimensionSpaces.contains(
            SemanticEmbeddingSpaceKey(
              profileID: profile.id,
              embeddingSpaceIdentifier: $0
            )
          )
        } ?? false
      for chunk in eligibleChunks {
        let key = IndexVectorKey(profileID: profile.id, sourceID: chunk.id)
        guard let record = recordsByKey[key] else {
          missingVectorCount += 1
          continue
        }
        let fingerprint = EmbeddingVectorCodec.fingerprint(for: chunk.content)
        if availability == .available,
          !hasMixedVectorDimensions,
          record.embeddingSpaceIdentifier == expectedSpaceIdentifier,
          record.contentFingerprint == fingerprint,
          EmbeddingVectorCodec.isValidEncoding(
            byteCount: record.vectorByteCount,
            dimensions: record.dimensions
          )
        {
          validChunkIDs.insert(chunk.id)
        } else {
          staleVectorCount += 1
        }
      }
      let indexedDocumentCount = enabledDocuments.reduce(into: 0) { count, document in
        guard let documentChunks = chunksByDocumentID[document.id], !documentChunks.isEmpty else {
          return
        }
        if documentChunks.allSatisfy({ validChunkIDs.contains($0.id) }) {
          count += 1
        }
      }
      profileHealth.append(
        SemanticDocumentProfileHealth(
          profileID: profile.id,
          displayName: profile.displayName,
          availability: availability,
          indexedDocumentCount: indexedDocumentCount,
          validVectorCount: validChunkIDs.count,
          missingVectorCount: missingVectorCount,
          staleVectorCount: staleVectorCount
        )
      )
    }

    let allProfileIDs = Set(profiles.map(\.id))
    let allChunkIDs = Set(chunks.map(\.id))
    let orphanVectorCount = documentVectors.lazy.filter {
      !allProfileIDs.contains($0.profileID) || !allChunkIDs.contains($0.sourceID)
    }.count
    return SemanticDocumentIndexHealth(
      enabledDocumentCount: enabledDocuments.count,
      chunkCount: eligibleChunks.count,
      storedVectorCount: documentVectors.count,
      orphanVectorCount: orphanVectorCount,
      profiles: profileHealth,
      isTemporary: isTemporary
    )
  }

  /// Clears the rebuildable document-vector partition in bounded pages, then regenerates enabled
  /// profiles. Conversation vectors and source chunks are untouched, so lexical recall remains
  /// usable throughout.
  @MainActor
  static func rebuildAllEnabledDocuments(in modelContext: ModelContext) async throws -> [String] {
    try await SemanticDocumentIndexPipeline.rebuildAllEnabledDocuments(
      sourceContainer: modelContext.container,
      vectorContainer: SemanticIndexStore.shared,
      isTemporary: SemanticIndexStore.didFallBackToMemory
    )
  }

  /// True dangling document vectors have lost either their profile or their source chunk.
  /// Disabled profiles and documents retain their cache so re-enabling them stays cheap.
  @MainActor
  static func danglingDocumentVectorIDs(
    profiles: [EmbeddingProfileRecord],
    chunks: [DocumentChunkRecord],
    vectors: [EmbeddingVectorRecord]
  ) -> Set<UUID> {
    let profileIDs = Set(profiles.map(\.id))
    let chunkIDs = Set(chunks.map(\.id))
    return Set(
      vectors.lazy.compactMap { vector in
        guard vector.sourceKind == .documentChunk,
          !profileIDs.contains(vector.profileID) || !chunkIDs.contains(vector.sourceID)
        else {
          return nil
        }
        return vector.id
      }
    )
  }

  /// Rebuilds only the four active document profiles, while always sweeping true dangling data.
  @MainActor
  static func documentVectorIDsToDeleteForRebuild(
    profiles: [EmbeddingProfileRecord],
    chunks: [DocumentChunkRecord],
    vectors: [EmbeddingVectorRecord]
  ) -> Set<UUID> {
    let activeProfileIDs = Set(
      enabledEmbeddingProfiles(in: profiles)
        .prefix(maximumProfiles)
        .filter(\.indexesDocuments)
        .map(\.id)
    )
    let danglingIDs = danglingDocumentVectorIDs(
      profiles: profiles,
      chunks: chunks,
      vectors: vectors
    )
    return Set(
      vectors.lazy.compactMap { vector in
        guard vector.sourceKind == .documentChunk,
          activeProfileIDs.contains(vector.profileID) || danglingIDs.contains(vector.id)
        else {
          return nil
        }
        return vector.id
      }
    )
  }

  /// Backfills all chunks for newly imported documents. Failure is non-fatal:
  /// lexical recall remains available and missing vectors are retried on demand.
  @MainActor
  public static func index(
    documentIDs: Set<UUID>,
    in modelContext: ModelContext
  ) async -> [String] {
    await SemanticDocumentIndexPipeline.index(
      documentIDs: documentIDs,
      sourceContainer: modelContext.container,
      vectorContainer: SemanticIndexStore.shared,
      isTemporary: SemanticIndexStore.didFallBackToMemory
    )
  }

  /// Backfills every enabled document without materializing the document catalog on the UI actor.
  @MainActor
  static func indexAllEnabledDocuments(in modelContext: ModelContext) async -> [String] {
    await SemanticDocumentIndexPipeline.indexAllEnabledDocuments(
      sourceContainer: modelContext.container,
      vectorContainer: SemanticIndexStore.shared,
      isTemporary: SemanticIndexStore.didFallBackToMemory
    )
  }

  @MainActor
  static func documentIndexWriteValidationState(
    documents: [ImportedDocumentRecord],
    chunks: [DocumentChunkRecord],
    profiles: [EmbeddingProfileRecord],
    providers: [ProviderConfigurationRecord]
  ) -> DocumentIndexWriteValidationState {
    let enabledDocumentIDs = Set(documents.filter(\.isEnabled).map(\.id))
    let providersByID = Dictionary(
      providers.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var providerIDsByProfileID: [UUID: UUID] = [:]
    var spaceIdentifiersByProfileID: [UUID: String] = [:]
    for profile in enabledEmbeddingProfiles(in: profiles).prefix(maximumProfiles)
    where profile.indexesDocuments {
      guard profile.backend == .provider,
        let providerID = profile.providerConfigurationID,
        let provider = providersByID[providerID],
        provider.isEnabled,
        provider.provider.supportsEmbeddings
      else {
        continue
      }
      let connection = ProviderConnection(
        id: provider.id,
        displayName: provider.displayName,
        provider: provider.provider,
        baseURL: provider.baseURL,
        modelIdentifier: provider.modelIdentifier
      )
      providerIDsByProfileID[profile.id] = providerID
      spaceIdentifiersByProfileID[profile.id] = EmbeddingInputFormatter.spaceIdentifier(
        connection: connection,
        modelIdentifier: profile.modelIdentifier
      )
    }

    let chunkPairs: [(UUID, CurrentDocumentChunk)] = chunks.compactMap { chunk in
      guard enabledDocumentIDs.contains(chunk.documentID),
        !chunk.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return nil
      }
      return (
        chunk.id,
        CurrentDocumentChunk(
          documentID: chunk.documentID,
          contentFingerprint: EmbeddingVectorCodec.fingerprint(for: chunk.content)
        )
      )
    }
    let chunksByID = Dictionary(uniqueKeysWithValues: chunkPairs)
    return DocumentIndexWriteValidationState(
      providerIDsByProfileID: providerIDsByProfileID,
      spaceIdentifiersByProfileID: spaceIdentifiersByProfileID,
      chunksByID: chunksByID
    )
  }

  @MainActor
  private static func enabledEmbeddingProfiles(
    in profiles: [EmbeddingProfileRecord]
  ) -> [EmbeddingProfileRecord] {
    profiles
      .filter(\.isEnabled)
      .sorted { lhs, rhs in
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
      }
  }

  private static func run(jobs: [DocumentIndexJob]) async -> [DocumentIndexResult] {
    await withTaskGroup(of: DocumentIndexResult.self, returning: [DocumentIndexResult].self) {
      group in
      for job in jobs {
        group.addTask { await run(job: job) }
      }
      var results: [DocumentIndexResult] = []
      for await result in group { results.append(result) }
      return results
    }
  }

  private static func run(job: DocumentIndexJob) async -> DocumentIndexResult {
    await withTaskGroup(of: DocumentIndexResult.self) { group in
      group.addTask { await perform(job: job) }
      group.addTask {
        do {
          try await Task.sleep(for: .seconds(60))
        } catch {
          return DocumentIndexResult(
            profileID: job.profile.id,
            providerID: job.connection.id,
            vectors: [],
            warning: nil,
            didTimeOut: false
          )
        }
        return DocumentIndexResult(
          profileID: job.profile.id,
          providerID: job.connection.id,
          vectors: [],
          warning: "\(job.profile.displayName) did not finish document indexing in time.",
          didTimeOut: true
        )
      }
      let result =
        await group.next()
        ?? DocumentIndexResult(
          profileID: job.profile.id,
          providerID: job.connection.id,
          vectors: [],
          warning: nil,
          didTimeOut: false
        )
      if result.didTimeOut {
        group.cancelAll()
        if let partial = await group.next(), !partial.didTimeOut {
          return DocumentIndexResult(
            profileID: partial.profileID,
            providerID: partial.providerID,
            vectors: partial.vectors,
            warning: result.warning,
            didTimeOut: true
          )
        }
        return result
      }
      group.cancelAll()
      return result
    }
  }

  private static func perform(job: DocumentIndexJob) async -> DocumentIndexResult {
    var vectors: [DocumentIndexedVector] = []
    do {
      let client = EmbeddingProviderClientFactory.make(connection: job.connection)
      for start in stride(from: 0, to: job.candidates.count, by: batchSize) {
        try Task.checkCancellation()
        let batch = Array(
          job.candidates[start..<min(start + batchSize, job.candidates.count)]
        )
        let embedded = try await client.embed(
          batch.map {
            EmbeddingInputFormatter.document(
              $0.content,
              provider: job.connection.provider,
              modelIdentifier: job.profile.modelIdentifier
            )
          },
          modelIdentifier: job.profile.modelIdentifier,
          purpose: .document
        )
        for (candidate, vector) in zip(batch, embedded) {
          vectors.append(
            DocumentIndexedVector(
              candidate: candidate,
              spaceIdentifier: job.spaceIdentifier,
              fingerprint: EmbeddingVectorCodec.fingerprint(for: candidate.content),
              vector: vector
            )
          )
        }
      }
      return DocumentIndexResult(
        profileID: job.profile.id,
        providerID: job.connection.id,
        vectors: vectors,
        warning: nil,
        didTimeOut: false
      )
    } catch is CancellationError {
      return DocumentIndexResult(
        profileID: job.profile.id,
        providerID: job.connection.id,
        vectors: vectors,
        warning: nil,
        didTimeOut: false
      )
    } catch {
      return DocumentIndexResult(
        profileID: job.profile.id,
        providerID: job.connection.id,
        vectors: vectors,
        warning:
          "\(job.profile.displayName) indexed only part of the document; missing chunks will retry later.",
        didTimeOut: false
      )
    }
  }
}

private struct SemanticHealthDocumentSnapshot: Sendable {
  let id: UUID
  let isEnabled: Bool

  @MainActor
  init(_ record: ImportedDocumentRecord) {
    id = record.id
    isEnabled = record.isEnabled
  }
}

private struct SemanticHealthChunkSnapshot: Sendable {
  let id: UUID
  let documentID: UUID
  let content: String

  @MainActor
  init(_ record: DocumentChunkRecord) {
    id = record.id
    documentID = record.documentID
    content = record.content
  }
}

private struct SemanticHealthProfileSnapshot: Sendable {
  let id: UUID
  let displayName: String
  let providerConfigurationID: UUID?
  let modelIdentifier: String
  let isEnabled: Bool
  let indexesDocuments: Bool
  let updatedAt: Date

  @MainActor
  init(_ record: EmbeddingProfileRecord) {
    id = record.id
    displayName = record.displayName
    providerConfigurationID = record.providerConfigurationID
    modelIdentifier = record.modelIdentifier
    isEnabled = record.isEnabled
    indexesDocuments = record.indexesDocuments
    updatedAt = record.updatedAt
  }
}

private struct SemanticHealthProviderSnapshot: Sendable {
  let id: UUID
  let displayName: String
  let provider: ProviderKind
  let baseURL: URL?
  let modelIdentifier: String
  let isEnabled: Bool

  @MainActor
  init(_ record: ProviderConfigurationRecord) {
    id = record.id
    displayName = record.displayName
    provider = record.provider
    baseURL = record.baseURL
    modelIdentifier = record.modelIdentifier
    isEnabled = record.isEnabled
  }
}

private struct SemanticDocumentVectorHealthSnapshot: Sendable {
  let id: UUID
  let profileID: UUID
  let sourceKind: RetrievalSourceKind
  let sourceID: UUID
  let embeddingSpaceIdentifier: String
  let contentFingerprint: String
  let dimensions: Int
  let vectorByteCount: Int

  init(_ record: EmbeddingVectorRecord) {
    id = record.id
    profileID = record.profileID
    sourceKind = record.sourceKind
    sourceID = record.sourceID
    embeddingSpaceIdentifier = record.embeddingSpaceIdentifier
    contentFingerprint = record.contentFingerprint
    dimensions = record.dimensions
    vectorByteCount = record.vectorData.count
  }
}

enum SemanticDocumentIndexRebuildError: LocalizedError {
  case cacheCouldNotBeCleared

  var errorDescription: String? {
    switch self {
    case .cacheCouldNotBeCleared:
      "Existing document vectors could not be cleared, so the rebuild did not start. Local lexical recall remains available."
    }
  }
}

enum SemanticDocumentProfileAvailability: Equatable, Sendable {
  case available
  case providerUnavailable
  case profileLimitExceeded
}

struct SemanticDocumentProfileHealth: Equatable, Identifiable, Sendable {
  let profileID: UUID
  let displayName: String
  let availability: SemanticDocumentProfileAvailability
  let indexedDocumentCount: Int
  let validVectorCount: Int
  let missingVectorCount: Int
  let staleVectorCount: Int

  var id: UUID { profileID }
  var expectedVectorCount: Int { validVectorCount + missingVectorCount + staleVectorCount }
  var needsAttention: Bool {
    availability != .available || missingVectorCount > 0 || staleVectorCount > 0
  }
}

struct SemanticDocumentIndexHealth: Equatable, Sendable {
  let enabledDocumentCount: Int
  let chunkCount: Int
  let storedVectorCount: Int
  let orphanVectorCount: Int
  let profiles: [SemanticDocumentProfileHealth]
  let isTemporary: Bool

  var validVectorCount: Int { profiles.reduce(0) { $0 + $1.validVectorCount } }
  var expectedVectorCount: Int { profiles.reduce(0) { $0 + $1.expectedVectorCount } }
  var missingVectorCount: Int { profiles.reduce(0) { $0 + $1.missingVectorCount } }
  var staleVectorCount: Int { profiles.reduce(0) { $0 + $1.staleVectorCount } }
  var needsAttention: Bool {
    isTemporary || orphanVectorCount > 0 || profiles.contains(where: \.needsAttention)
  }
}

struct DocumentIndexWriteValidationState: Sendable {
  let providerIDsByProfileID: [UUID: UUID]
  let spaceIdentifiersByProfileID: [UUID: String]
  let chunksByID: [UUID: CurrentDocumentChunk]

  func accepts(
    profileID: UUID,
    providerID: UUID,
    sourceID: UUID,
    documentID: UUID,
    spaceIdentifier: String,
    contentFingerprint: String
  ) -> Bool {
    guard providerIDsByProfileID[profileID] == providerID,
      spaceIdentifiersByProfileID[profileID] == spaceIdentifier,
      let chunk = chunksByID[sourceID],
      chunk.documentID == documentID,
      chunk.contentFingerprint == contentFingerprint
    else {
      return false
    }
    return true
  }
}

struct CurrentDocumentChunk: Equatable, Sendable {
  let documentID: UUID
  let contentFingerprint: String
}

private struct IndexVectorKey: Hashable, Sendable {
  let profileID: UUID
  let sourceID: UUID
}

private struct DocumentIndexJob: Sendable {
  let profile: EmbeddingProfileSnapshot
  let connection: ProviderConnection
  let spaceIdentifier: String
  let candidates: [RetrievalCandidate]
}

private struct DocumentIndexedVector: Sendable {
  let candidate: RetrievalCandidate
  let spaceIdentifier: String
  let fingerprint: String
  let vector: [Float]
}

private struct DocumentIndexResult: Sendable {
  let profileID: UUID
  let providerID: UUID
  let vectors: [DocumentIndexedVector]
  let warning: String?
  let didTimeOut: Bool
}

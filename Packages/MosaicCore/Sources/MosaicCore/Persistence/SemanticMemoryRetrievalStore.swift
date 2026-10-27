import Foundation
import SwiftData

struct SemanticRetrievalSourceSnapshot: Sendable {
  let candidates: [RetrievalCandidate]
  let selectedProfiles: [EmbeddingProfileSnapshot]
  let enabledProfileCount: Int
  let providersByID: [UUID: ProviderConnection]
  let audienceScope: ConversationProjectScope
}

struct SemanticCandidateVersion: Hashable, Sendable {
  let id: UUID
  let source: RetrievalSourceKind
  let containerID: UUID
  let contentFingerprint: String
  let audienceConversationID: UUID?
  let audienceProjectID: UUID?
  let audienceBindingID: UUID?
  let audienceBindingUpdatedAt: Date?

  init(
    id: UUID,
    source: RetrievalSourceKind,
    containerID: UUID,
    contentFingerprint: String,
    audienceConversationID: UUID? = nil,
    audienceProjectID: UUID? = nil,
    audienceBindingID: UUID? = nil,
    audienceBindingUpdatedAt: Date? = nil
  ) {
    self.id = id
    self.source = source
    self.containerID = containerID
    self.contentFingerprint = contentFingerprint
    self.audienceConversationID = audienceConversationID
    self.audienceProjectID = audienceProjectID
    self.audienceBindingID = audienceBindingID
    self.audienceBindingUpdatedAt = audienceBindingUpdatedAt
  }
}

enum SemanticCandidateFingerprint {
  static func make(for candidate: RetrievalCandidate) -> String {
    guard candidate.source == .memoryTopic else {
      return EmbeddingVectorCodec.fingerprint(for: candidate.content)
    }
    let prefix = candidate.title + ": "
    guard candidate.content.hasPrefix(prefix) else {
      return EmbeddingVectorCodec.fingerprint(for: candidate.content)
    }
    return topic(
      title: candidate.title,
      content: String(candidate.content.dropFirst(prefix.count))
    )
  }

  static func topic(title: String, content: String) -> String {
    EmbeddingVectorCodec.fingerprint(
      for: "\(title.utf8.count):\(title)\(content.utf8.count):\(content)"
    )
  }
}

struct SemanticProfileVersion: Hashable, Sendable {
  let profile: EmbeddingProfileSnapshot
  let provider: ProviderConnection
  let embeddingSpaceIdentifier: String
}

struct SemanticStoredVectorSnapshot: Sendable {
  let profileID: UUID
  let sourceKind: RetrievalSourceKind
  let sourceID: UUID
  let embeddingSpaceIdentifier: String
  let contentFingerprint: String
  let dimensions: Int
  let vectorData: Data

  init(_ record: EmbeddingVectorRecord) {
    profileID = record.profileID
    sourceKind = record.sourceKind
    sourceID = record.sourceID
    embeddingSpaceIdentifier = record.embeddingSpaceIdentifier
    contentFingerprint = record.contentFingerprint
    dimensions = record.dimensions
    vectorData = record.vectorData
  }

  init(
    profileID: UUID,
    sourceKind: RetrievalSourceKind,
    sourceID: UUID,
    embeddingSpaceIdentifier: String,
    contentFingerprint: String,
    dimensions: Int,
    vectorData: Data
  ) {
    self.profileID = profileID
    self.sourceKind = sourceKind
    self.sourceID = sourceID
    self.embeddingSpaceIdentifier = embeddingSpaceIdentifier
    self.contentFingerprint = contentFingerprint
    self.dimensions = dimensions
    self.vectorData = vectorData
  }
}

struct SemanticRetrievalSourceReadLimits: Sendable {
  let maximumBindingRecords: Int
  let maximumConversationRecords: Int
  let maximumMessageRecords: Int
  let maximumDocumentRecords: Int
  let maximumDocumentChunkRecords: Int

  static let production = SemanticRetrievalSourceReadLimits(
    maximumBindingRecords: 20_000,
    maximumConversationRecords: 20_000,
    maximumMessageRecords: 20_000,
    maximumDocumentRecords: 20_000,
    maximumDocumentChunkRecords: 20_000
  )
}

private enum SemanticRetrievalSourceError: Error {
  case topicAudienceLimitExceeded
  case bindingAudienceLimitExceeded(ProjectResourceKind)
  case conversationAudienceLimitExceeded
  case messageAudienceLimitExceeded
  case invalidTopicAudience
  case invalidConversationAudience
  case invalidDocumentAudience
}

struct SemanticVectorWrite: Sendable {
  let profileID: UUID
  let sourceKind: RetrievalSourceKind
  let sourceID: UUID
  let embeddingSpaceIdentifier: String
  let contentFingerprint: String
  let dimensions: Int
  let vectorData: Data
}

enum SemanticVectorRepositoryError: Error, Equatable, Sendable {
  case invalidVectorWrite
  case mixedEmbeddingDimensions
}

struct SemanticEmbeddingSpaceKey: Hashable, Sendable {
  let profileID: UUID
  let embeddingSpaceIdentifier: String
}

/// Serializes the read-before-write invariant across the document indexer and on-demand retrieval
/// repositories. Both repositories use their own model actors, so a process-wide lock is required
/// to prevent two empty-space writes with different dimensions from racing past validation.
enum SemanticVectorDimensionInvariant {
  private static let writeLock = NSLock()

  static func withExclusiveWrite<Result>(_ operation: () throws -> Result) rethrows -> Result {
    writeLock.lock()
    defer { writeLock.unlock() }
    return try operation()
  }

  static func validateWrites(
    _ writes: [SemanticVectorWrite],
    in modelContext: ModelContext
  ) throws {
    var dimensionsBySpace: [SemanticEmbeddingSpaceKey: Int] = [:]
    var replacementCacheKeysBySpace: [SemanticEmbeddingSpaceKey: [String]] = [:]
    var incomingCacheKeys: Set<String> = []
    incomingCacheKeys.reserveCapacity(writes.count)

    for write in writes {
      guard
        EmbeddingVectorCodec.isValidEncoding(
          byteCount: write.vectorData.count,
          dimensions: write.dimensions
        ),
        incomingCacheKeys.insert(
          EmbeddingVectorRecord.makeCacheKey(
            profileID: write.profileID,
            sourceID: write.sourceID
          )
        ).inserted
      else {
        throw SemanticVectorRepositoryError.invalidVectorWrite
      }

      let key = SemanticEmbeddingSpaceKey(
        profileID: write.profileID,
        embeddingSpaceIdentifier: write.embeddingSpaceIdentifier
      )
      if let expectedDimension = dimensionsBySpace[key] {
        guard expectedDimension == write.dimensions else {
          throw SemanticVectorRepositoryError.mixedEmbeddingDimensions
        }
      } else {
        dimensionsBySpace[key] = write.dimensions
      }
      replacementCacheKeysBySpace[key, default: []].append(
        EmbeddingVectorRecord.makeCacheKey(
          profileID: write.profileID,
          sourceID: write.sourceID
        )
      )
    }

    for (key, expectedDimension) in dimensionsBySpace {
      let profileID = key.profileID
      let embeddingSpaceIdentifier = key.embeddingSpaceIdentifier
      let dimension = expectedDimension
      let replacementCacheKeys = replacementCacheKeysBySpace[key] ?? []
      var descriptor = FetchDescriptor<EmbeddingVectorRecord>(
        predicate: #Predicate {
          $0.profileID == profileID
            && $0.embeddingSpaceIdentifier == embeddingSpaceIdentifier
            && $0.dimensions != dimension
            && !replacementCacheKeys.contains($0.cacheKey)
        }
      )
      descriptor.fetchLimit = 1
      descriptor.includePendingChanges = false
      guard try modelContext.fetch(descriptor).isEmpty else {
        throw SemanticVectorRepositoryError.mixedEmbeddingDimensions
      }
    }
  }

  static func hasMixedDimensions(
    profileID: UUID,
    embeddingSpaceIdentifier: String,
    in modelContext: ModelContext
  ) throws -> Bool {
    try withExclusiveWrite {
      let validationContext = ModelContext(modelContext.container)
      validationContext.autosaveEnabled = false
      let targetProfileID = profileID
      let targetSpaceIdentifier = embeddingSpaceIdentifier
      var firstDescriptor = FetchDescriptor<EmbeddingVectorRecord>(
        predicate: #Predicate {
          $0.profileID == targetProfileID
            && $0.embeddingSpaceIdentifier == targetSpaceIdentifier
        }
      )
      firstDescriptor.fetchLimit = 1
      firstDescriptor.includePendingChanges = false
      guard
        let firstDimension = try validationContext.fetch(firstDescriptor).first?.dimensions
      else {
        return false
      }

      let canonicalDimension = firstDimension
      var mismatchDescriptor = FetchDescriptor<EmbeddingVectorRecord>(
        predicate: #Predicate {
          $0.profileID == targetProfileID
            && $0.embeddingSpaceIdentifier == targetSpaceIdentifier
            && $0.dimensions != canonicalDimension
        }
      )
      mismatchDescriptor.fetchLimit = 1
      mismatchDescriptor.includePendingChanges = false
      return try !validationContext.fetch(mismatchDescriptor).isEmpty
    }
  }
}

struct SemanticEmbeddedVector: Sendable {
  let candidate: RetrievalCandidate
  let embeddingSpaceIdentifier: String
  let contentFingerprint: String
  let vector: [Float]
}

struct SemanticVectorPageEvaluation: Sendable {
  let scores: [UUID: Double]
  let validVectorIDs: Set<UUID>
}

protocol SemanticRetrievalSourceAccessing: Sendable {
  func snapshot(
    excluding conversationID: UUID,
    maximumCandidatesPerSource: Int,
    maximumProfiles: Int
  ) async throws -> SemanticRetrievalSourceSnapshot

  func isCurrent(profile version: SemanticProfileVersion) async throws -> Bool

  func validCandidateIDs(
    for versions: [SemanticCandidateVersion]
  ) async throws -> Set<UUID>
}

protocol SemanticRetrievalVectorAccessing: Sendable {
  func snapshots(
    profileID: UUID,
    candidateIDs: [UUID]
  ) async throws -> [SemanticStoredVectorSnapshot]

  func upsert(_ writes: [SemanticVectorWrite]) async throws
}

/// Creates SwiftData model actors from a non-main actor so their model contexts cannot inherit the
/// main queue merely because retrieval was requested by a view.
actor SemanticRetrievalActorFactory {
  func sourceReader(
    modelContainer: ModelContainer
  ) -> SemanticRetrievalSourceReader {
    SemanticRetrievalSourceReader(modelContainer: modelContainer)
  }

  func vectorRepository(
    modelContainer: ModelContainer
  ) -> SemanticRetrievalVectorRepository {
    SemanticRetrievalVectorRepository(modelContainer: modelContainer)
  }
}

actor SemanticRetrievalComputeActor {
  private let retriever: HybridMemoryRetriever

  init(retriever: HybridMemoryRetriever = HybridMemoryRetriever()) {
    self.retriever = retriever
  }

  /// A wide candidate list for the reranker (full excerpts are re-read from the candidates).
  func retrieveFirstStage(
    query: String,
    candidates: [RetrievalCandidate],
    semanticScoreSets: [SemanticScoreSet],
    localPreparation: LocalRetrievalPreparation,
    warnings: [String]
  ) throws -> RetrievedContext {
    try retriever.withLimits(
      maximumItems: RecallRerankStage.firstStageDepth,
      maximumCharacters: RecallRerankStage.firstStageDepth
        * RecallRerankStage.documentCharacterLimit,
      maximumItemsPerContainer: RecallRerankStage.firstStageDepth
    ).retrieveCheckingCancellation(
      query: query,
      candidates: candidates,
      semanticScoreSets: semanticScoreSets,
      localScoreSnapshot: localPreparation.scores,
      warnings: warnings
    )
  }

  /// Final selection driven by reranker probabilities, with the normal item/size limits.
  func select(
    rankedBy scores: [UUID: Double],
    from candidates: [RetrievalCandidate],
    warnings: [String]
  ) -> RetrievedContext {
    retriever.select(
      rankedBy: scores, from: candidates, profileNames: ["Reranker"], warnings: warnings)
  }

  func prepare(
    query: String,
    candidates: [RetrievalCandidate],
    maximumCount: Int
  ) throws -> LocalRetrievalPreparation {
    try retriever.prepareCheckingCancellation(
      query: query,
      candidates: candidates,
      maximumCount: maximumCount
    )
  }

  func eligibleCandidates(
    from candidates: [RetrievalCandidate],
    profile: EmbeddingProfileSnapshot
  ) throws -> [RetrievalCandidate] {
    var eligible: [RetrievalCandidate] = []
    eligible.reserveCapacity(candidates.count)
    for (index, candidate) in candidates.enumerated() {
      if index.isMultiple(of: 64) { try Task.checkCancellation() }
      let shouldInclude: Bool
      switch candidate.source {
      case .conversationMessage:
        shouldInclude = profile.indexesConversations
      case .documentChunk:
        shouldInclude = profile.indexesDocuments
      case .memoryTopic:
        shouldInclude = profile.indexesConversations
      }
      if shouldInclude { eligible.append(candidate) }
    }
    return eligible
  }

  func evaluateVectorPage(
    queryVector: [Float],
    profileID: UUID,
    embeddingSpaceIdentifier: String,
    candidates: [RetrievalCandidate],
    records: [SemanticStoredVectorSnapshot]
  ) throws -> SemanticVectorPageEvaluation {
    try Task.checkCancellation()
    let recordsBySourceID = Dictionary(
      records.map { ($0.sourceID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var scores: [UUID: Double] = [:]
    var validVectorIDs: Set<UUID> = []
    for (index, candidate) in candidates.enumerated() {
      if index.isMultiple(of: 16) { try Task.checkCancellation() }
      guard let record = recordsBySourceID[candidate.id],
        record.profileID == profileID,
        record.sourceKind == candidate.source,
        record.embeddingSpaceIdentifier == embeddingSpaceIdentifier,
        record.contentFingerprint == EmbeddingVectorCodec.fingerprint(for: candidate.content),
        let vector = EmbeddingVectorCodec.decode(
          record.vectorData,
          dimensions: record.dimensions
        ),
        vector.count == queryVector.count
      else {
        continue
      }
      scores[candidate.id] = EmbeddingMath.cosineSimilarity(queryVector, vector)
      validVectorIDs.insert(candidate.id)
    }
    return SemanticVectorPageEvaluation(scores: scores, validVectorIDs: validVectorIDs)
  }

  func embeddedVectors(
    candidates: [RetrievalCandidate],
    vectors: [[Float]],
    embeddingSpaceIdentifier: String
  ) throws -> [SemanticEmbeddedVector] {
    var result: [SemanticEmbeddedVector] = []
    result.reserveCapacity(min(candidates.count, vectors.count))
    for (index, pair) in zip(candidates, vectors).enumerated() {
      if index.isMultiple(of: 16) { try Task.checkCancellation() }
      let (candidate, vector) = pair
      result.append(
        SemanticEmbeddedVector(
          candidate: candidate,
          embeddingSpaceIdentifier: embeddingSpaceIdentifier,
          contentFingerprint: EmbeddingVectorCodec.fingerprint(for: candidate.content),
          vector: vector
        )
      )
    }
    return result
  }

  func scores(
    queryVector: [Float],
    embeddedVectors: [SemanticEmbeddedVector]
  ) throws -> [UUID: Double] {
    var scores: [UUID: Double] = [:]
    for (index, embedded) in embeddedVectors.enumerated() {
      if index.isMultiple(of: 16) { try Task.checkCancellation() }
      guard embedded.vector.count == queryVector.count else { continue }
      scores[embedded.candidate.id] = EmbeddingMath.cosineSimilarity(
        queryVector,
        embedded.vector
      )
    }
    return scores
  }

  func versions(
    for candidates: [RetrievalCandidate],
    audienceScope: ConversationProjectScope? = nil
  ) throws -> [SemanticCandidateVersion] {
    var versions: [SemanticCandidateVersion] = []
    versions.reserveCapacity(candidates.count)
    for (index, candidate) in candidates.enumerated() {
      if index.isMultiple(of: 16) { try Task.checkCancellation() }
      versions.append(
        SemanticCandidateVersion(
          id: candidate.id,
          source: candidate.source,
          containerID: candidate.containerID,
          contentFingerprint: SemanticCandidateFingerprint.make(for: candidate),
          audienceConversationID: audienceScope?.conversationID,
          audienceProjectID: audienceScope?.projectID,
          audienceBindingID: audienceScope?.bindingID,
          audienceBindingUpdatedAt: audienceScope?.bindingUpdatedAt
        )
      )
    }
    return versions
  }

  func writes(
    profileID: UUID,
    embeddedVectors: [SemanticEmbeddedVector]
  ) throws -> [SemanticVectorWrite] {
    var writes: [SemanticVectorWrite] = []
    writes.reserveCapacity(embeddedVectors.count)
    for (index, embedded) in embeddedVectors.enumerated() {
      if index.isMultiple(of: 16) { try Task.checkCancellation() }
      writes.append(
        SemanticVectorWrite(
          profileID: profileID,
          sourceKind: embedded.candidate.source,
          sourceID: embedded.candidate.id,
          embeddingSpaceIdentifier: embedded.embeddingSpaceIdentifier,
          contentFingerprint: embedded.contentFingerprint,
          dimensions: embedded.vector.count,
          vectorData: EmbeddingVectorCodec.encode(embedded.vector)
        )
      )
    }
    return writes
  }

  func retrieve(
    query: String,
    candidates: [RetrievalCandidate],
    semanticScoreSets: [SemanticScoreSet],
    localPreparation: LocalRetrievalPreparation,
    warnings: [String]
  ) throws -> RetrievedContext {
    try retriever.retrieveCheckingCancellation(
      query: query,
      candidates: candidates,
      semanticScoreSets: semanticScoreSets,
      localScoreSnapshot: localPreparation.scores,
      warnings: warnings
    )
  }
}

@ModelActor
actor SemanticRetrievalSourceReader: SemanticRetrievalSourceAccessing {
  private static let maximumCandidateUTF8BytesPerSource = 8 * 1_024 * 1_024
  private static let sourcePageSize = 128
  private static let maximumTopicScanCount = 20_000

  func snapshot(
    excluding conversationID: UUID,
    maximumCandidatesPerSource: Int,
    maximumProfiles: Int
  ) throws -> SemanticRetrievalSourceSnapshot {
    try snapshot(
      excluding: conversationID,
      maximumCandidatesPerSource: maximumCandidatesPerSource,
      maximumProfiles: maximumProfiles,
      limits: .production
    )
  }

  func snapshot(
    excluding conversationID: UUID,
    maximumCandidatesPerSource: Int,
    maximumProfiles: Int,
    limits: SemanticRetrievalSourceReadLimits
  ) throws -> SemanticRetrievalSourceSnapshot {
    try Task.checkCancellation()
    let candidateLimit = max(0, maximumCandidatesPerSource)
    let profileLimit = max(0, maximumProfiles)
    let audienceScope = try ProjectBindingStore.conversationScope(
      conversationID: conversationID,
      in: modelContext
    )
    let topics = try accessibleTopics(
      audienceScope: audienceScope,
      maximumCount: candidateLimit
    )
    let messages: [MessageRecord]
    if candidateLimit == 0 {
      messages = []
    } else {
      let audienceConversationIDs = try accessibleConversationIDs(
        audienceScope: audienceScope,
        excluding: conversationID,
        limits: limits
      )
      messages = try accessibleMessages(
        conversationIDs: audienceConversationIDs,
        maximumCount: candidateLimit,
        maximumScannedRecords: max(0, limits.maximumMessageRecords)
      )
    }
    try Task.checkCancellation()

    let conversationIDs = Array(Set(messages.map(\.conversationID)))
    var conversationTitles: [UUID: String] = [:]
    for page in conversationIDs.chunked(maximumCount: 128) {
      try Task.checkCancellation()
      let ids = page
      let descriptor = FetchDescriptor<ConversationRecord>(
        predicate: #Predicate { ids.contains($0.id) }
      )
      for conversation in try modelContext.fetch(descriptor) {
        conversationTitles[conversation.id] = conversation.title
      }
    }

    let chunks: [DocumentChunkRecord]
    let documentTitles: [UUID: String]
    if candidateLimit == 0 {
      chunks = []
      documentTitles = [:]
    } else {
      let documents = try accessibleDocuments(
        audienceScope: audienceScope,
        limits: limits
      )
      (chunks, documentTitles) = try accessibleDocumentChunks(
        documents: documents,
        maximumCount: candidateLimit,
        maximumScannedRecords: max(0, limits.maximumDocumentChunkRecords)
      )
    }

    let enabledProfilePredicate = #Predicate<EmbeddingProfileRecord> { $0.isEnabled }
    var profileDescriptor = FetchDescriptor<EmbeddingProfileRecord>(
      predicate: enabledProfilePredicate,
      sortBy: [
        SortDescriptor(\EmbeddingProfileRecord.updatedAt, order: .reverse),
        SortDescriptor(\EmbeddingProfileRecord.id),
      ]
    )
    let profiles: [EmbeddingProfileRecord]
    if profileLimit == 0 {
      profiles = []
    } else {
      profileDescriptor.fetchLimit = profileLimit
      profiles = try modelContext.fetch(profileDescriptor)
    }
    let enabledProfileCount = try modelContext.fetchCount(
      FetchDescriptor<EmbeddingProfileRecord>(predicate: enabledProfilePredicate)
    )
    let providerIDs = Array(Set(profiles.compactMap(\.providerConfigurationID)))
    let providerDescriptor = FetchDescriptor<ProviderConfigurationRecord>(
      predicate: #Predicate { providerIDs.contains($0.id) }
    )
    let providers = try modelContext.fetch(providerDescriptor)
    let providerSnapshots = Dictionary(
      providers.filter(\.isEnabled).map { ($0.id, Self.providerSnapshot($0)) },
      uniquingKeysWith: { first, _ in first }
    )

    let messageCandidates = messages.map {
      RetrievalCandidate(
        id: $0.id,
        source: .conversationMessage,
        containerID: $0.conversationID,
        title: conversationTitles[$0.conversationID] ?? "Earlier conversation",
        content: $0.content,
        createdAt: $0.createdAt
      )
    }
    let documentCandidates = chunks.map {
      RetrievalCandidate(
        id: $0.id,
        source: .documentChunk,
        containerID: $0.documentID,
        title: documentTitles[$0.documentID] ?? "Imported document",
        content: $0.content,
        pageNumber: $0.pageNumber,
        isOCRDerived: $0.isOCRDerived,
        createdAt: $0.createdAt
      )
    }
    let topicCandidates = topics.map {
      RetrievalCandidate(
        id: $0.id,
        source: .memoryTopic,
        containerID: $0.id,
        title: $0.title,
        content: "\($0.title): \($0.content)",
        memoryConfidence: $0.confidence,
        memoryImportance: $0.importance,
        memoryKind: $0.kind,
        memoryLastConfirmedAt: $0.lastConfirmedAt,
        createdAt: $0.updatedAt
      )
    }
    return SemanticRetrievalSourceSnapshot(
      candidates: topicCandidates + messageCandidates + documentCandidates,
      selectedProfiles: profiles.map(\.snapshot),
      enabledProfileCount: enabledProfileCount,
      providersByID: providerSnapshots,
      audienceScope: audienceScope
    )
  }

  private struct MessageLane {
    let conversationIDs: [UUID]
    var records: [MessageRecord] = []
    var nextIndex = 0
    var cursorDate: Date?
    var cursorID: UUID?
    var isExhausted = false

    var current: MessageRecord? {
      guard nextIndex < records.count else { return nil }
      return records[nextIndex]
    }

    var needsRefill: Bool {
      current == nil && !isExhausted
    }

    mutating func advance() {
      nextIndex += 1
    }
  }

  /// Resolve the audience's conversation containers before touching MessageRecord. This keeps a
  /// busy unrelated project from consuming the raw-message scan budget.
  private func accessibleConversationIDs(
    audienceScope: ConversationProjectScope,
    excluding conversationID: UUID,
    limits: SemanticRetrievalSourceReadLimits
  ) throws -> [UUID] {
    let maximumConversationRecords = max(0, limits.maximumConversationRecords)
    guard maximumConversationRecords > 0 else { return [] }

    if let projectID = audienceScope.projectID {
      let bindingLimit =
        maximumConversationRecords == Int.max
        ? Int.max
        : maximumConversationRecords + 1
      let bindings = try boundedBindings(
        resourceKind: .conversation,
        projectID: projectID,
        maximumCount: bindingLimit
      )
      let resourceIDs = bindings.map(\.resourceID)
      var existingIDs: Set<UUID> = []
      for page in resourceIDs.chunked(maximumCount: Self.sourcePageSize) {
        try Task.checkCancellation()
        let ids = page
        var descriptor = FetchDescriptor<ConversationRecord>(
          predicate: #Predicate { ids.contains($0.id) }
        )
        descriptor.includePendingChanges = false
        for record in try modelContext.fetch(descriptor) {
          guard existingIDs.insert(record.id).inserted else {
            throw SemanticRetrievalSourceError.invalidConversationAudience
          }
        }
      }
      guard existingIDs.count == resourceIDs.count else {
        throw SemanticRetrievalSourceError.invalidConversationAudience
      }
      let result = existingIDs.filter { $0 != conversationID }.sorted()
      guard result.count <= maximumConversationRecords else {
        throw SemanticRetrievalSourceError.conversationAudienceLimitExceeded
      }
      return result
    }

    let bindings = try boundedBindings(
      resourceKind: .conversation,
      projectID: nil,
      maximumCount: max(0, limits.maximumBindingRecords)
    )
    let boundIDs = bindings.map(\.resourceID)
    let descriptor: FetchDescriptor<ConversationRecord>
    if boundIDs.isEmpty {
      descriptor = FetchDescriptor(
        predicate: #Predicate { $0.id != conversationID },
        sortBy: [SortDescriptor(\ConversationRecord.id)]
      )
    } else {
      descriptor = FetchDescriptor(
        predicate: #Predicate {
          $0.id != conversationID && !boundIDs.contains($0.id)
        },
        sortBy: [SortDescriptor(\ConversationRecord.id)]
      )
    }
    var boundedDescriptor = descriptor
    boundedDescriptor.fetchLimit = safeIncrement(maximumConversationRecords)
    boundedDescriptor.includePendingChanges = false
    let records = try modelContext.fetch(boundedDescriptor)
    guard records.count <= maximumConversationRecords else {
      throw SemanticRetrievalSourceError.conversationAudienceLimitExceeded
    }
    return records.map(\.id)
  }

  /// Merge newest-first pages from exact-audience conversation lanes. Chunking container IDs
  /// avoids oversized SQL IN clauses without letting chunk order bias which messages are kept.
  private func accessibleMessages(
    conversationIDs: [UUID],
    maximumCount: Int,
    maximumScannedRecords: Int
  ) throws -> [MessageRecord] {
    guard maximumCount > 0, maximumScannedRecords > 0, !conversationIDs.isEmpty else {
      return []
    }
    var lanes = conversationIDs.chunked(maximumCount: Self.sourcePageSize).map {
      MessageLane(conversationIDs: $0)
    }
    guard lanes.count <= maximumScannedRecords else {
      throw SemanticRetrievalSourceError.messageAudienceLimitExceeded
    }

    var fetchedRecordCount = 0
    for index in lanes.indices {
      fetchedRecordCount += try refillMessageLane(&lanes[index], fetchLimit: 1)
    }

    var selected: [MessageRecord] = []
    selected.reserveCapacity(maximumCount)
    var selectedBytes = 0
    while selected.count < maximumCount
      && selectedBytes < Self.maximumCandidateUTF8BytesPerSource
    {
      try Task.checkCancellation()
      var page: [MessageRecord] = []
      let pageLimit = min(Self.sourcePageSize, maximumCount - selected.count)
      while page.count < pageLimit {
        let emptyLaneIndices = lanes.indices.filter { lanes[$0].needsRefill }
        if !emptyLaneIndices.isEmpty {
          let remainingBudget = maximumScannedRecords - fetchedRecordCount
          guard remainingBudget >= emptyLaneIndices.count else { break }
          let refillLimit = min(
            Self.sourcePageSize,
            max(1, remainingBudget / emptyLaneIndices.count)
          )
          for index in emptyLaneIndices {
            fetchedRecordCount += try refillMessageLane(
              &lanes[index],
              fetchLimit: refillLimit
            )
          }
        }
        guard let nextLaneIndex = Self.nextMessageLaneIndex(in: lanes),
          let message = lanes[nextLaneIndex].current
        else {
          break
        }
        page.append(message)
        lanes[nextLaneIndex].advance()
      }
      guard !page.isEmpty else { break }

      let pageMessageIDs = page.map(\.id)
      var evidenceDescriptor = FetchDescriptor<MemoryEvidenceRecord>(
        predicate: #Predicate { pageMessageIDs.contains($0.sourceMessageID) }
      )
      evidenceDescriptor.includePendingChanges = false
      let consolidatedMessageIDs = Set(
        try modelContext.fetch(evidenceDescriptor).map(\.sourceMessageID)
      )
      for message in page where !consolidatedMessageIDs.contains(message.id) {
        try Task.checkCancellation()
        guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          continue
        }
        let (nextBytes, overflow) = selectedBytes.addingReportingOverflow(
          message.content.utf8.count
        )
        guard !overflow, nextBytes <= Self.maximumCandidateUTF8BytesPerSource else {
          return selected
        }
        selected.append(message)
        selectedBytes = nextBytes
        if selected.count == maximumCount { break }
      }
    }
    return selected
  }

  private func refillMessageLane(
    _ lane: inout MessageLane,
    fetchLimit: Int
  ) throws -> Int {
    precondition(fetchLimit > 0)
    let ids = lane.conversationIDs
    let userRole = MessageRole.user.rawValue
    let completeStatus = MessageStatus.complete.rawValue
    let descriptor: FetchDescriptor<MessageRecord>
    if let cursorDate = lane.cursorDate, let cursorID = lane.cursorID {
      descriptor = FetchDescriptor(
        predicate: #Predicate {
          ids.contains($0.conversationID)
            && $0.roleRawValue == userRole
            && $0.statusRawValue == completeStatus
            && ($0.createdAt < cursorDate
              || ($0.createdAt == cursorDate && $0.id > cursorID))
        },
        sortBy: [
          SortDescriptor(\MessageRecord.createdAt, order: .reverse),
          SortDescriptor(\MessageRecord.id),
        ]
      )
    } else {
      descriptor = FetchDescriptor(
        predicate: #Predicate {
          ids.contains($0.conversationID)
            && $0.roleRawValue == userRole
            && $0.statusRawValue == completeStatus
        },
        sortBy: [
          SortDescriptor(\MessageRecord.createdAt, order: .reverse),
          SortDescriptor(\MessageRecord.id),
        ]
      )
    }
    var pageDescriptor = descriptor
    pageDescriptor.fetchLimit = fetchLimit
    pageDescriptor.includePendingChanges = false
    let page = try modelContext.fetch(pageDescriptor)
    lane.records = page
    lane.nextIndex = 0
    if let last = page.last {
      lane.cursorDate = last.createdAt
      lane.cursorID = last.id
    }
    lane.isExhausted = page.count < fetchLimit
    return page.count
  }

  private static func nextMessageLaneIndex(in lanes: [MessageLane]) -> Int? {
    var selectedIndex: Int?
    for index in lanes.indices where lanes[index].current != nil {
      guard let current = lanes[index].current else { continue }
      guard let existingIndex = selectedIndex,
        let existing = lanes[existingIndex].current
      else {
        selectedIndex = index
        continue
      }
      if current.createdAt > existing.createdAt
        || (current.createdAt == existing.createdAt && current.id < existing.id)
      {
        selectedIndex = index
      }
    }
    return selectedIndex
  }

  /// Partition document containers before reading chunks. Unbound documents are global; bound
  /// documents are included only when their binding matches the current project.
  private func accessibleDocuments(
    audienceScope: ConversationProjectScope,
    limits: SemanticRetrievalSourceReadLimits
  ) throws -> [ImportedDocumentRecord] {
    let maximumDocumentRecords = max(0, limits.maximumDocumentRecords)
    guard maximumDocumentRecords > 0 else { return [] }
    let bindings = try boundedBindings(
      resourceKind: .document,
      projectID: nil,
      maximumCount: max(0, limits.maximumBindingRecords)
    )
    let boundDocumentIDs = bindings.map(\.resourceID)
    let globalDescriptor: FetchDescriptor<ImportedDocumentRecord>
    if boundDocumentIDs.isEmpty {
      globalDescriptor = FetchDescriptor(
        predicate: #Predicate { $0.isEnabled },
        sortBy: [
          SortDescriptor(\ImportedDocumentRecord.updatedAt, order: .reverse),
          SortDescriptor(\ImportedDocumentRecord.id),
        ]
      )
    } else {
      globalDescriptor = FetchDescriptor(
        predicate: #Predicate {
          $0.isEnabled && !boundDocumentIDs.contains($0.id)
        },
        sortBy: [
          SortDescriptor(\ImportedDocumentRecord.updatedAt, order: .reverse),
          SortDescriptor(\ImportedDocumentRecord.id),
        ]
      )
    }
    var boundedGlobalDescriptor = globalDescriptor
    boundedGlobalDescriptor.fetchLimit = maximumDocumentRecords
    boundedGlobalDescriptor.includePendingChanges = false
    let globalDocuments = try modelContext.fetch(boundedGlobalDescriptor)

    var projectDocuments: [ImportedDocumentRecord] = []
    if let projectID = audienceScope.projectID {
      let projectDocumentIDs = bindings.lazy
        .filter { $0.projectID == projectID }
        .map(\.resourceID)
      let projectIDs = Array(projectDocumentIDs)
      var recordsByID: [UUID: ImportedDocumentRecord] = [:]
      for page in projectIDs.chunked(maximumCount: Self.sourcePageSize) {
        try Task.checkCancellation()
        let ids = page
        var descriptor = FetchDescriptor<ImportedDocumentRecord>(
          predicate: #Predicate { ids.contains($0.id) }
        )
        descriptor.includePendingChanges = false
        for document in try modelContext.fetch(descriptor) {
          guard recordsByID.updateValue(document, forKey: document.id) == nil else {
            throw SemanticRetrievalSourceError.invalidDocumentAudience
          }
        }
      }
      guard recordsByID.count == projectIDs.count else {
        throw SemanticRetrievalSourceError.invalidDocumentAudience
      }
      projectDocuments = recordsByID.values.filter(\.isEnabled)
    }

    return (globalDocuments + projectDocuments)
      .sorted {
        if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
        return $0.id < $1.id
      }
      .prefix(maximumDocumentRecords)
      .map { $0 }
  }

  private func accessibleDocumentChunks(
    documents: [ImportedDocumentRecord],
    maximumCount: Int,
    maximumScannedRecords: Int
  ) throws -> ([DocumentChunkRecord], [UUID: String]) {
    guard maximumCount > 0, maximumScannedRecords > 0 else { return ([], [:]) }
    var documentTitles: [UUID: String] = [:]
    var chunks: [DocumentChunkRecord] = []
    var chunkBytes = 0
    var scannedChunkCount = 0
    for document in documents
    where chunks.count < maximumCount
      && chunkBytes < Self.maximumCandidateUTF8BytesPerSource
      && scannedChunkCount < maximumScannedRecords
    {
      try Task.checkCancellation()
      let documentID = document.id
      var chunkCursorIndex: Int?
      var chunkCursorID: UUID?
      while chunks.count < maximumCount
        && chunkBytes < Self.maximumCandidateUTF8BytesPerSource
        && scannedChunkCount < maximumScannedRecords
      {
        let chunkDescriptor: FetchDescriptor<DocumentChunkRecord>
        if let chunkCursorIndex, let chunkCursorID {
          let cursorIndex = chunkCursorIndex
          let cursorID = chunkCursorID
          chunkDescriptor = FetchDescriptor(
            predicate: #Predicate {
              $0.documentID == documentID
                && ($0.chunkIndex > cursorIndex
                  || ($0.chunkIndex == cursorIndex && $0.id > cursorID))
            },
            sortBy: [
              SortDescriptor(\DocumentChunkRecord.chunkIndex),
              SortDescriptor(\DocumentChunkRecord.id),
            ]
          )
        } else {
          chunkDescriptor = FetchDescriptor(
            predicate: #Predicate { $0.documentID == documentID },
            sortBy: [
              SortDescriptor(\DocumentChunkRecord.chunkIndex),
              SortDescriptor(\DocumentChunkRecord.id),
            ]
          )
        }
        var pageDescriptor = chunkDescriptor
        let pageLimit = min(
          Self.sourcePageSize,
          min(maximumCount - chunks.count, maximumScannedRecords - scannedChunkCount)
        )
        pageDescriptor.fetchLimit = pageLimit
        pageDescriptor.includePendingChanges = false
        let page = try modelContext.fetch(pageDescriptor)
        guard let lastChunk = page.last else { break }
        scannedChunkCount += page.count
        for chunk in page {
          try Task.checkCancellation()
          guard !chunk.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            continue
          }
          let (nextBytes, overflow) = chunkBytes.addingReportingOverflow(chunk.content.utf8.count)
          guard !overflow, nextBytes <= Self.maximumCandidateUTF8BytesPerSource else {
            return (chunks, documentTitles)
          }
          documentTitles[document.id] = document.title
          chunks.append(chunk)
          chunkBytes = nextBytes
          if chunks.count == maximumCount { break }
        }
        chunkCursorIndex = lastChunk.chunkIndex
        chunkCursorID = lastChunk.id
        if page.count < pageLimit { break }
      }
    }
    return (chunks, documentTitles)
  }

  private func boundedBindings(
    resourceKind: ProjectResourceKind,
    projectID: UUID?,
    maximumCount: Int
  ) throws -> [ProjectResourceBindingRecord] {
    let maximumCount = max(0, maximumCount)
    let rawKind = resourceKind.rawValue
    let descriptor: FetchDescriptor<ProjectResourceBindingRecord>
    if let projectID {
      descriptor = FetchDescriptor(
        predicate: #Predicate {
          $0.resourceKindRawValue == rawKind && $0.projectID == projectID
        },
        sortBy: [SortDescriptor(\ProjectResourceBindingRecord.id)]
      )
    } else {
      descriptor = FetchDescriptor(
        predicate: #Predicate { $0.resourceKindRawValue == rawKind },
        sortBy: [SortDescriptor(\ProjectResourceBindingRecord.id)]
      )
    }
    var boundedDescriptor = descriptor
    boundedDescriptor.fetchLimit = safeIncrement(maximumCount)
    boundedDescriptor.includePendingChanges = false
    let bindings = try modelContext.fetch(boundedDescriptor)
    guard bindings.count <= maximumCount else {
      throw SemanticRetrievalSourceError.bindingAudienceLimitExceeded(resourceKind)
    }
    var resourceIDs: Set<UUID> = []
    for binding in bindings {
      guard
        binding.bindingKey
          == ProjectResourceBindingRecord.makeBindingKey(
            resourceKind: resourceKind,
            resourceID: binding.resourceID
          ),
        resourceIDs.insert(binding.resourceID).inserted
      else {
        switch resourceKind {
        case .conversation:
          throw SemanticRetrievalSourceError.invalidConversationAudience
        case .document:
          throw SemanticRetrievalSourceError.invalidDocumentAudience
        case .memoryTopic, .memory:
          throw SemanticRetrievalSourceError.invalidTopicAudience
        }
      }
    }
    return bindings
  }

  private func safeIncrement(_ value: Int) -> Int {
    value == Int.max ? Int.max : value + 1
  }

  private func accessibleTopics(
    audienceScope: ConversationProjectScope,
    maximumCount: Int
  ) throws -> [MemoryTopicRecord] {
    guard maximumCount > 0 else { return [] }
    let activeStatus = MemoryTopicStatus.active.rawValue
    let globalScope = MemoryScope.global.rawValue
    var globalDescriptor = FetchDescriptor<MemoryTopicRecord>(
      predicate: #Predicate {
        $0.isEnabled && $0.statusRawValue == activeStatus
          && $0.scopeRawValue == globalScope
      }
    )
    globalDescriptor.fetchLimit = Self.maximumTopicScanCount + 1
    globalDescriptor.includePendingChanges = false
    let globalTopics = try modelContext.fetch(globalDescriptor)
    guard globalTopics.count <= Self.maximumTopicScanCount,
      globalTopics.allSatisfy({ $0.conversationID == nil })
    else {
      throw SemanticRetrievalSourceError.topicAudienceLimitExceeded
    }

    let conversationScope = MemoryScope.conversation.rawValue
    let conversationID = audienceScope.conversationID
    var conversationDescriptor = FetchDescriptor<MemoryTopicRecord>(
      predicate: #Predicate {
        $0.isEnabled && $0.statusRawValue == activeStatus
          && $0.scopeRawValue == conversationScope
          && $0.conversationID == conversationID
      }
    )
    conversationDescriptor.fetchLimit = Self.maximumTopicScanCount + 1
    conversationDescriptor.includePendingChanges = false
    let conversationTopics = try modelContext.fetch(conversationDescriptor)
    guard conversationTopics.count <= Self.maximumTopicScanCount else {
      throw SemanticRetrievalSourceError.topicAudienceLimitExceeded
    }

    let directTopicIDs = (globalTopics + conversationTopics).map(\.id)
    guard
      try ProjectBindingStore.projectIDs(
        resourceKind: .memoryTopic,
        resourceIDs: directTopicIDs,
        in: modelContext
      ).isEmpty
    else {
      throw SemanticRetrievalSourceError.invalidTopicAudience
    }

    var projectTopics: [MemoryTopicRecord] = []
    if let projectID = audienceScope.projectID {
      let topicKind = ProjectResourceKind.memoryTopic.rawValue
      var bindingDescriptor = FetchDescriptor<ProjectResourceBindingRecord>(
        predicate: #Predicate {
          $0.projectID == projectID && $0.resourceKindRawValue == topicKind
        },
        sortBy: [SortDescriptor(\ProjectResourceBindingRecord.id)]
      )
      bindingDescriptor.fetchLimit = Self.maximumTopicScanCount + 1
      bindingDescriptor.includePendingChanges = false
      let bindings = try modelContext.fetch(bindingDescriptor)
      guard bindings.count <= Self.maximumTopicScanCount else {
        throw SemanticRetrievalSourceError.topicAudienceLimitExceeded
      }
      var projectRecordsByID: [UUID: MemoryTopicRecord] = [:]
      for page in bindings.map(\.resourceID).chunked(maximumCount: Self.sourcePageSize) {
        try Task.checkCancellation()
        let ids = page
        let descriptor = FetchDescriptor<MemoryTopicRecord>(
          predicate: #Predicate { ids.contains($0.id) }
        )
        for topic in try modelContext.fetch(descriptor) {
          guard projectRecordsByID.updateValue(topic, forKey: topic.id) == nil else {
            throw SemanticRetrievalSourceError.invalidTopicAudience
          }
        }
      }
      guard projectRecordsByID.count == bindings.count,
        projectRecordsByID.values.allSatisfy({
          $0.scopeRawValue == MemoryScope.project.rawValue && $0.conversationID == nil
        })
      else {
        throw SemanticRetrievalSourceError.invalidTopicAudience
      }
      projectTopics = projectRecordsByID.values.filter {
        $0.isEnabled && $0.statusRawValue == activeStatus
      }
    }

    let ordered = (globalTopics + conversationTopics + projectTopics).sorted {
      if $0.importance != $1.importance { return $0.importance > $1.importance }
      if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
      return $0.id < $1.id
    }
    var selected: [MemoryTopicRecord] = []
    selected.reserveCapacity(min(maximumCount, ordered.count))
    var selectedBytes = 0
    for topic in ordered {
      try Task.checkCancellation()
      guard selected.count < maximumCount else { break }
      let (rowBytes, rowOverflow) = topic.title.utf8.count.addingReportingOverflow(
        topic.content.utf8.count
      )
      let (nextBytes, totalOverflow) = selectedBytes.addingReportingOverflow(rowBytes)
      guard !rowOverflow, !totalOverflow,
        nextBytes <= Self.maximumCandidateUTF8BytesPerSource
      else {
        break
      }
      selected.append(topic)
      selectedBytes = nextBytes
    }
    return selected
  }

  func isCurrent(profile version: SemanticProfileVersion) throws -> Bool {
    try Task.checkCancellation()
    // A fresh context observes commits made by another window while the provider request was in
    // flight instead of trusting objects already registered by the initial snapshot fetch.
    let validationContext = ModelContext(modelContainer)
    let profileID = version.profile.id
    var profileDescriptor = FetchDescriptor<EmbeddingProfileRecord>(
      predicate: #Predicate { $0.id == profileID }
    )
    profileDescriptor.fetchLimit = 1
    guard let profile = try validationContext.fetch(profileDescriptor).first,
      profile.isEnabled,
      profile.snapshot == version.profile,
      let providerID = profile.providerConfigurationID
    else {
      return false
    }

    var providerDescriptor = FetchDescriptor<ProviderConfigurationRecord>(
      predicate: #Predicate { $0.id == providerID }
    )
    providerDescriptor.fetchLimit = 1
    guard let provider = try validationContext.fetch(providerDescriptor).first,
      provider.isEnabled,
      provider.provider.supportsEmbeddings
    else {
      return false
    }
    let providerSnapshot = Self.providerSnapshot(provider)
    guard providerSnapshot == version.provider else { return false }
    return EmbeddingInputFormatter.spaceIdentifier(
      connection: providerSnapshot,
      modelIdentifier: profile.modelIdentifier
    ) == version.embeddingSpaceIdentifier
  }

  func validCandidateIDs(
    for versions: [SemanticCandidateVersion]
  ) throws -> Set<UUID> {
    guard !versions.isEmpty else { return [] }
    let validationContext = ModelContext(modelContainer)
    let audienceScopes = Set(
      versions.compactMap { version -> ConversationProjectScope? in
        guard let conversationID = version.audienceConversationID else { return nil }
        return ConversationProjectScope(
          conversationID: conversationID,
          projectID: version.audienceProjectID,
          bindingID: version.audienceBindingID,
          bindingUpdatedAt: version.audienceBindingUpdatedAt
        )
      }
    )
    guard audienceScopes.count <= 1 else { return [] }
    let audienceScope = audienceScopes.first
    if let audienceScope {
      let currentScope = try ProjectBindingStore.conversationScope(
        conversationID: audienceScope.conversationID,
        in: validationContext
      )
      guard currentScope == audienceScope else { return [] }
    }
    var valid: Set<UUID> = []
    let versionsByID = Dictionary(
      versions.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    let messageIDs = versions.filter { $0.source == .conversationMessage }.map(\.id)
    for page in messageIDs.chunked(maximumCount: 128) {
      try Task.checkCancellation()
      let ids = page
      let evidenceDescriptor = FetchDescriptor<MemoryEvidenceRecord>(
        predicate: #Predicate { ids.contains($0.sourceMessageID) }
      )
      let consolidatedMessageIDs = Set(
        try validationContext.fetch(evidenceDescriptor).map(\.sourceMessageID)
      )
      let descriptor = FetchDescriptor<MessageRecord>(
        predicate: #Predicate { ids.contains($0.id) }
      )
      for record in try validationContext.fetch(descriptor)
      where !consolidatedMessageIDs.contains(record.id) {
        guard let expected = versionsByID[record.id],
          record.conversationID == expected.containerID,
          record.role == .user,
          record.status == .complete,
          EmbeddingVectorCodec.fingerprint(for: record.content) == expected.contentFingerprint
        else {
          continue
        }
        if expected.audienceConversationID != nil {
          let candidateProjectID = try ProjectBindingStore.projectID(
            resourceKind: .conversation,
            resourceID: record.conversationID,
            in: validationContext
          )
          guard candidateProjectID == expected.audienceProjectID else { continue }
        }
        valid.insert(record.id)
      }
    }

    let chunkIDs = versions.filter { $0.source == .documentChunk }.map(\.id)
    var currentChunks: [UUID: DocumentChunkRecord] = [:]
    for page in chunkIDs.chunked(maximumCount: 128) {
      try Task.checkCancellation()
      let ids = page
      let descriptor = FetchDescriptor<DocumentChunkRecord>(
        predicate: #Predicate { ids.contains($0.id) }
      )
      for record in try validationContext.fetch(descriptor) {
        currentChunks[record.id] = record
      }
    }
    let documentIDs = Array(Set(currentChunks.values.map(\.documentID)))
    var enabledDocumentIDs: Set<UUID> = []
    for page in documentIDs.chunked(maximumCount: 128) {
      try Task.checkCancellation()
      let ids = page
      let descriptor = FetchDescriptor<ImportedDocumentRecord>(
        predicate: #Predicate { ids.contains($0.id) && $0.isEnabled }
      )
      enabledDocumentIDs.formUnion(try validationContext.fetch(descriptor).map(\.id))
    }
    for (id, record) in currentChunks {
      guard let expected = versionsByID[id],
        record.documentID == expected.containerID,
        enabledDocumentIDs.contains(record.documentID),
        EmbeddingVectorCodec.fingerprint(for: record.content) == expected.contentFingerprint
      else {
        continue
      }
      if expected.audienceConversationID != nil {
        let documentProjectID = try ProjectBindingStore.projectID(
          resourceKind: .document,
          resourceID: record.documentID,
          in: validationContext
        )
        guard documentProjectID == nil || documentProjectID == expected.audienceProjectID else {
          continue
        }
      }
      valid.insert(id)
    }

    let topicIDs = versions.filter { $0.source == .memoryTopic }.map(\.id)
    let activeStatus = MemoryTopicStatus.active.rawValue
    for page in topicIDs.chunked(maximumCount: 128) {
      try Task.checkCancellation()
      let ids = page
      let descriptor = FetchDescriptor<MemoryTopicRecord>(
        predicate: #Predicate {
          ids.contains($0.id) && $0.isEnabled && $0.statusRawValue == activeStatus
        }
      )
      for record in try validationContext.fetch(descriptor) {
        guard let expected = versionsByID[record.id],
          expected.containerID == record.id,
          SemanticCandidateFingerprint.topic(title: record.title, content: record.content)
            == expected.contentFingerprint
        else {
          continue
        }
        if let audienceConversationID = expected.audienceConversationID {
          let topicProjectID = try ProjectBindingStore.projectID(
            resourceKind: .memoryTopic,
            resourceID: record.id,
            in: validationContext
          )
          switch record.scope {
          case .global:
            guard record.conversationID == nil, topicProjectID == nil else { continue }
          case .project:
            guard topicProjectID != nil, topicProjectID == expected.audienceProjectID else {
              continue
            }
          case .conversation:
            guard record.conversationID == audienceConversationID, topicProjectID == nil else {
              continue
            }
          }
        }
        valid.insert(record.id)
      }
    }
    return valid
  }

  private static func providerSnapshot(_ provider: ProviderConfigurationRecord)
    -> ProviderConnection
  {
    ProviderConnection(
      id: provider.id,
      displayName: provider.displayName,
      provider: provider.provider,
      baseURL: provider.baseURL,
      modelIdentifier: provider.modelIdentifier,
      contextWindowTokens: provider.contextWindowTokens,
      maximumOutputTokens: provider.maximumOutputTokens
    )
  }
}

@ModelActor
actor SemanticRetrievalVectorRepository: SemanticRetrievalVectorAccessing {
  static let maximumPageSize = 256

  func snapshots(
    profileID: UUID,
    candidateIDs: [UUID]
  ) throws -> [SemanticStoredVectorSnapshot] {
    guard !candidateIDs.isEmpty else { return [] }
    precondition(candidateIDs.count <= Self.maximumPageSize)
    try Task.checkCancellation()
    let cacheKeys = candidateIDs.map {
      EmbeddingVectorRecord.makeCacheKey(profileID: profileID, sourceID: $0)
    }
    var descriptor = FetchDescriptor<EmbeddingVectorRecord>(
      predicate: #Predicate { cacheKeys.contains($0.cacheKey) }
    )
    descriptor.fetchLimit = cacheKeys.count
    return try modelContext.fetch(descriptor).map(SemanticStoredVectorSnapshot.init)
  }

  func upsert(_ writes: [SemanticVectorWrite]) throws {
    guard !writes.isEmpty else { return }
    precondition(writes.count <= Self.maximumPageSize)
    try Task.checkCancellation()
    try SemanticVectorDimensionInvariant.withExclusiveWrite {
      // A fresh write context avoids stale model objects after another repository or rebuild
      // commits through its own context.
      let writeContext = ModelContext(modelContainer)
      writeContext.autosaveEnabled = false
      try SemanticVectorDimensionInvariant.validateWrites(writes, in: writeContext)
      let cacheKeys = writes.map {
        EmbeddingVectorRecord.makeCacheKey(profileID: $0.profileID, sourceID: $0.sourceID)
      }
      let descriptor = FetchDescriptor<EmbeddingVectorRecord>(
        predicate: #Predicate { cacheKeys.contains($0.cacheKey) }
      )
      let stored = try writeContext.fetch(descriptor)
      var recordsByCacheKey = Dictionary(
        stored.map { ($0.cacheKey, $0) },
        uniquingKeysWith: { first, _ in first }
      )

      do {
        for (index, write) in writes.enumerated() {
          if index.isMultiple(of: 32) { try Task.checkCancellation() }
          let cacheKey = EmbeddingVectorRecord.makeCacheKey(
            profileID: write.profileID,
            sourceID: write.sourceID
          )
          if let record = recordsByCacheKey[cacheKey] {
            record.sourceKind = write.sourceKind
            record.embeddingSpaceIdentifier = write.embeddingSpaceIdentifier
            record.contentFingerprint = write.contentFingerprint
            record.dimensions = write.dimensions
            record.vectorData = write.vectorData
            record.updatedAt = .now
          } else {
            let record = EmbeddingVectorRecord(
              profileID: write.profileID,
              sourceKind: write.sourceKind,
              sourceID: write.sourceID,
              embeddingSpaceIdentifier: write.embeddingSpaceIdentifier,
              contentFingerprint: write.contentFingerprint,
              dimensions: write.dimensions,
              vectorData: write.vectorData
            )
            writeContext.insert(record)
            recordsByCacheKey[cacheKey] = record
          }
        }
        try Task.checkCancellation()
        try writeContext.save()
      } catch {
        writeContext.rollback()
        throw error
      }
    }
  }
}

extension Array {
  func chunked(maximumCount: Int) -> [[Element]] {
    guard maximumCount > 0, !isEmpty else { return [] }
    var result: [[Element]] = []
    result.reserveCapacity((count + maximumCount - 1) / maximumCount)
    for start in stride(from: 0, to: count, by: maximumCount) {
      result.append(Array(self[start..<Swift.min(start + maximumCount, count)]))
    }
    return result
  }
}

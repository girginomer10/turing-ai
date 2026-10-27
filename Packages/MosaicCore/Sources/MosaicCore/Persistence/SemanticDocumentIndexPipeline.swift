import Foundation
import SwiftData

/// Runtime document indexing is deliberately separate from the pure compatibility helpers in
/// `SemanticDocumentIndexer`. Source payloads and vector blobs are consumed in bounded pages on
/// model actors; only immutable snapshots cross an actor boundary.
enum SemanticDocumentIndexPipeline {
  private static let indexPageSize = 32
  private static let healthPageSize = 128
  private static let documentPageSize = 64
  private static let maximumProfiles = 4

  static func health(
    sourceContainer: ModelContainer,
    vectorContainer: ModelContainer,
    isTemporary: Bool
  ) async throws -> SemanticDocumentIndexHealth {
    let factory = SemanticDocumentIndexActorFactory()
    let source = await factory.sourceRepository(modelContainer: sourceContainer)
    let vectors = await factory.vectorRepository(modelContainer: vectorContainer)
    let configuration = try await source.healthConfiguration()

    let providersByID = configuration.providersByID
    var accumulators = configuration.profiles.map { profile in
      let availability: SemanticDocumentProfileAvailability
      let expectedSpaceIdentifier: String?
      if !configuration.activeProfileIDs.contains(profile.id) {
        availability = .profileLimitExceeded
        expectedSpaceIdentifier = nil
      } else if let providerID = profile.providerConfigurationID,
        let provider = providersByID[providerID],
        provider.isEnabled,
        provider.connection.provider.supportsEmbeddings
      {
        availability = .available
        expectedSpaceIdentifier = EmbeddingInputFormatter.spaceIdentifier(
          connection: provider.connection,
          modelIdentifier: profile.modelIdentifier
        )
      } else {
        availability = .providerUnavailable
        expectedSpaceIdentifier = nil
      }
      return SemanticDocumentHealthAccumulator(
        profile: profile,
        availability: availability,
        expectedSpaceIdentifier: expectedSpaceIdentifier
      )
    }
    for index in accumulators.indices {
      let accumulator = accumulators[index]
      guard accumulator.availability == .available,
        let expectedSpaceIdentifier = accumulator.expectedSpaceIdentifier
      else {
        continue
      }
      accumulators[index].hasMixedVectorDimensions = try await vectors.hasMixedDimensions(
        profileID: accumulator.profile.id,
        embeddingSpaceIdentifier: expectedSpaceIdentifier
      )
    }

    var enabledDocumentCount = 0
    var eligibleChunkCount = 0
    var documentOffset = 0
    while true {
      try Task.checkCancellation()
      let documentIDs = try await source.enabledDocumentIDs(
        offset: documentOffset,
        limit: documentPageSize
      )
      guard !documentIDs.isEmpty else { break }
      enabledDocumentCount += documentIDs.count

      for documentID in documentIDs {
        var cursor: SemanticDocumentChunkCursor?
        var documentHasEligibleChunks = false
        var documentIsFullyIndexed = Array(repeating: true, count: accumulators.count)
        while true {
          let page = try await source.chunkPage(
            documentID: documentID,
            after: cursor,
            limit: healthPageSize
          )
          guard !page.rawRecordsWereEmpty else {
            break
          }
          cursor = page.nextCursor
          let chunks = page.chunks
          if !chunks.isEmpty {
            documentHasEligibleChunks = true
            eligibleChunkCount += chunks.count
          }

          for index in accumulators.indices {
            guard !chunks.isEmpty else { continue }
            var accumulator = accumulators[index]
            if accumulator.availability == .profileLimitExceeded {
              accumulator.missingVectorCount += chunks.count
              documentIsFullyIndexed[index] = false
              accumulators[index] = accumulator
              continue
            }

            let stored = try await vectors.healthSnapshots(
              profileID: accumulator.profile.id,
              sourceIDs: chunks.map(\.id)
            )
            let storedBySourceID = Dictionary(
              stored.map { ($0.sourceID, $0) },
              uniquingKeysWith: { first, _ in first }
            )
            for chunk in chunks {
              guard let record = storedBySourceID[chunk.id] else {
                accumulator.missingVectorCount += 1
                documentIsFullyIndexed[index] = false
                continue
              }
              if accumulator.availability == .available,
                !accumulator.hasMixedVectorDimensions,
                record.sourceKind == .documentChunk,
                record.embeddingSpaceIdentifier == accumulator.expectedSpaceIdentifier,
                record.contentFingerprint == chunk.contentFingerprint,
                EmbeddingVectorCodec.isValidEncoding(
                  byteCount: record.vectorByteCount,
                  dimensions: record.dimensions
                )
              {
                accumulator.validVectorCount += 1
              } else {
                accumulator.staleVectorCount += 1
                documentIsFullyIndexed[index] = false
              }
            }
            accumulators[index] = accumulator
          }

          guard page.hasMore else { break }
        }

        if documentHasEligibleChunks {
          for index in accumulators.indices where documentIsFullyIndexed[index] {
            accumulators[index].indexedDocumentCount += 1
          }
        }
      }

      documentOffset += documentIDs.count
      if documentIDs.count < documentPageSize { break }
    }

    var storedVectorCount = 0
    var orphanVectorCount = 0
    var vectorCursor: UUID?
    while true {
      try Task.checkCancellation()
      let page = try await vectors.documentVectorPage(
        afterID: vectorCursor,
        limit: healthPageSize
      )
      guard !page.records.isEmpty else { break }
      storedVectorCount += page.records.count
      let profileIDs = Array(Set(page.records.map(\.profileID)))
      let sourceIDs = Array(Set(page.records.map(\.sourceID)))
      let existingProfileIDs = try await source.existingProfileIDs(profileIDs)
      let existingChunkIDs = try await source.existingChunkIDs(sourceIDs)
      orphanVectorCount +=
        page.records.lazy.filter {
          !existingProfileIDs.contains($0.profileID) || !existingChunkIDs.contains($0.sourceID)
        }.count
      vectorCursor = page.nextID
      guard page.hasMore else { break }
    }

    return SemanticDocumentIndexHealth(
      enabledDocumentCount: enabledDocumentCount,
      chunkCount: eligibleChunkCount,
      storedVectorCount: storedVectorCount,
      orphanVectorCount: orphanVectorCount,
      profiles: accumulators.map(\.health),
      isTemporary: isTemporary
    )
  }

  static func index(
    documentIDs: Set<UUID>,
    sourceContainer: ModelContainer,
    vectorContainer: ModelContainer,
    isTemporary: Bool
  ) async -> [String] {
    guard !documentIDs.isEmpty else { return [] }
    let factory = SemanticDocumentIndexActorFactory()
    let source = await factory.sourceRepository(modelContainer: sourceContainer)
    let vectors = await factory.vectorRepository(modelContainer: vectorContainer)
    return await index(
      documentIDs: documentIDs.sorted { $0.uuidString < $1.uuidString },
      source: source,
      vectors: vectors,
      isTemporary: isTemporary
    )
  }

  static func indexAllEnabledDocuments(
    sourceContainer: ModelContainer,
    vectorContainer: ModelContainer,
    isTemporary: Bool
  ) async -> [String] {
    let factory = SemanticDocumentIndexActorFactory()
    let source = await factory.sourceRepository(modelContainer: sourceContainer)
    let vectors = await factory.vectorRepository(modelContainer: vectorContainer)
    return await indexAllEnabledDocuments(
      source: source,
      vectors: vectors,
      isTemporary: isTemporary
    )
  }

  static func rebuildAllEnabledDocuments(
    sourceContainer: ModelContainer,
    vectorContainer: ModelContainer,
    isTemporary: Bool
  ) async throws -> [String] {
    let factory = SemanticDocumentIndexActorFactory()
    let source = await factory.sourceRepository(modelContainer: sourceContainer)
    let vectors = await factory.vectorRepository(modelContainer: vectorContainer)
    do {
      let configuration = try await source.indexConfiguration(
        maximumProfiles: maximumProfiles
      )
      let activeProfileIDs = Set(configuration.profiles.map(\.id))
      var cursor: UUID?
      while true {
        try Task.checkCancellation()
        let page = try await vectors.documentVectorPage(
          afterID: cursor,
          limit: healthPageSize
        )
        guard !page.records.isEmpty else { break }
        let existingProfileIDs = try await source.existingProfileIDs(
          Array(Set(page.records.map(\.profileID)))
        )
        let existingChunkIDs = try await source.existingChunkIDs(
          Array(Set(page.records.map(\.sourceID)))
        )
        let keysToDelete = page.records.compactMap { record in
          activeProfileIDs.contains(record.profileID)
            || !existingProfileIDs.contains(record.profileID)
            || !existingChunkIDs.contains(record.sourceID)
            ? record.cacheKey : nil
        }
        try await vectors.delete(cacheKeys: keysToDelete)
        cursor = page.nextID
        guard page.hasMore else { break }
      }
    } catch {
      throw SemanticDocumentIndexRebuildError.cacheCouldNotBeCleared
    }
    return await indexAllEnabledDocuments(
      source: source,
      vectors: vectors,
      isTemporary: isTemporary
    )
  }

  static func deleteVectors(
    profileID: UUID,
    vectorContainer: ModelContainer
  ) async throws {
    let factory = SemanticDocumentIndexActorFactory()
    let vectors = await factory.vectorRepository(modelContainer: vectorContainer)
    try await vectors.deleteVectors(profileID: profileID)
  }

  private static func indexAllEnabledDocuments(
    source: SemanticDocumentIndexSourceRepository,
    vectors: SemanticDocumentIndexVectorRepository,
    isTemporary: Bool
  ) async -> [String] {
    var warnings = SemanticDocumentWarningBag()
    var offset = 0
    while true {
      do {
        try Task.checkCancellation()
        let documentIDs = try await source.enabledDocumentIDs(
          offset: offset,
          limit: documentPageSize
        )
        guard !documentIDs.isEmpty else { break }
        let pageWarnings = await index(
          documentIDs: documentIDs,
          source: source,
          vectors: vectors,
          isTemporary: isTemporary
        )
        warnings.append(contentsOf: pageWarnings)
        offset += documentIDs.count
        if documentIDs.count < documentPageSize { break }
      } catch is CancellationError {
        break
      } catch {
        warnings.append(
          "Document vectors could not be cached; local lexical recall remains available.")
        break
      }
    }
    return warnings.values
  }

  private static func index(
    documentIDs: [UUID],
    source: SemanticDocumentIndexSourceRepository,
    vectors: SemanticDocumentIndexVectorRepository,
    isTemporary: Bool
  ) async -> [String] {
    var warnings = SemanticDocumentWarningBag()
    if isTemporary {
      warnings.append(
        "The persistent vector cache is unavailable; remote vectors will be temporary.")
    }

    do {
      let configuration = try await source.indexConfiguration(maximumProfiles: maximumProfiles)
      if configuration.enabledProfileCount > maximumProfiles {
        warnings.append("Only the four most recently updated embedding profiles were indexed.")
      }
      let activeProfiles = await authenticatedProfiles(
        configuration: configuration,
        warnings: &warnings
      )
      guard !activeProfiles.isEmpty else { return warnings.values }

      var discardedVectorCount = 0
      for documentID in documentIDs {
        try Task.checkCancellation()
        guard let document = try await source.enabledDocument(id: documentID) else { continue }
        var cursor: SemanticDocumentChunkCursor?
        while true {
          let page = try await source.chunkPage(
            documentID: document.id,
            after: cursor,
            limit: indexPageSize
          )
          guard !page.rawRecordsWereEmpty else { break }
          cursor = page.nextCursor
          let candidates = page.chunks.map { $0.candidate(title: document.title) }

          var jobs: [BoundedDocumentIndexJob] = []
          for active in activeProfiles where !candidates.isEmpty {
            let stored = try await vectors.healthSnapshots(
              profileID: active.profile.id,
              sourceIDs: candidates.map(\.id)
            )
            let storedBySourceID = Dictionary(
              stored.map { ($0.sourceID, $0) },
              uniquingKeysWith: { first, _ in first }
            )
            let missing = candidates.filter { candidate in
              guard let record = storedBySourceID[candidate.id] else { return true }
              return record.sourceKind != .documentChunk
                || record.embeddingSpaceIdentifier != active.spaceIdentifier
                || record.contentFingerprint
                  != EmbeddingVectorCodec.fingerprint(for: candidate.content)
                || !EmbeddingVectorCodec.isValidEncoding(
                  byteCount: record.vectorByteCount,
                  dimensions: record.dimensions
                )
            }
            if !missing.isEmpty {
              jobs.append(
                BoundedDocumentIndexJob(
                  profile: active.profile,
                  providerSnapshot: active.providerSnapshot,
                  connection: active.connection,
                  spaceIdentifier: active.spaceIdentifier,
                  candidates: missing
                )
              )
            }
          }

          let results = await run(jobs: jobs)
          for result in results {
            if let warning = result.warning { warnings.append(warning) }
            guard !result.vectors.isEmpty else { continue }
            let profileIsCurrent = try await source.isCurrent(
              profile: result.profile,
              provider: result.providerSnapshot,
              embeddingSpaceIdentifier: result.spaceIdentifier
            )
            guard profileIsCurrent else {
              discardedVectorCount += result.vectors.count
              continue
            }
            let versions = result.vectors.map {
              SemanticCandidateVersion(
                id: $0.candidate.id,
                source: .documentChunk,
                containerID: $0.candidate.containerID,
                contentFingerprint: $0.contentFingerprint
              )
            }
            let validIDs = try await source.validCandidateIDs(for: versions)
            let writes = result.vectors.compactMap { vector -> SemanticVectorWrite? in
              guard validIDs.contains(vector.candidate.id) else {
                discardedVectorCount += 1
                return nil
              }
              return SemanticVectorWrite(
                profileID: result.profile.id,
                sourceKind: .documentChunk,
                sourceID: vector.candidate.id,
                embeddingSpaceIdentifier: result.spaceIdentifier,
                contentFingerprint: vector.contentFingerprint,
                dimensions: vector.vector.count,
                vectorData: EmbeddingVectorCodec.encode(vector.vector)
              )
            }
            if !writes.isEmpty {
              do {
                try await vectors.upsert(writes)
              } catch {
                warnings.append(
                  "New document vectors could not be saved; local lexical recall remains available."
                )
              }
            }
          }

          guard page.hasMore else { break }
        }
      }
      if discardedVectorCount > 0 {
        warnings.append(
          "\(discardedVectorCount) outdated document vectors were discarded because their profile, provider, model, or source changed during indexing."
        )
      }
    } catch is CancellationError {
      // Cancellation is an expected stop. Missing pages remain discoverable and retry later.
    } catch {
      warnings.append(
        "Document vectors could not be cached; local lexical recall remains available.")
    }
    return warnings.values
  }

  private static func authenticatedProfiles(
    configuration: SemanticDocumentIndexConfiguration,
    warnings: inout SemanticDocumentWarningBag
  ) async -> [SemanticAuthenticatedDocumentProfile] {
    var result: [SemanticAuthenticatedDocumentProfile] = []
    for profile in configuration.profiles {
      guard let providerID = profile.providerConfigurationID,
        let provider = configuration.providersByID[providerID],
        provider.isEnabled,
        provider.connection.provider.supportsEmbeddings
      else {
        warnings.append("\(profile.displayName) has no enabled embedding provider.")
        continue
      }
      do {
        let apiKey = try await SecurityKeychain.shared.apiKey(
          for: provider.connection.id,
          expectedBinding: provider.connection.credentialBinding
        )
        let connection = provider.connection.authenticated(with: apiKey)
        result.append(
          SemanticAuthenticatedDocumentProfile(
            profile: profile,
            providerSnapshot: provider.connection,
            connection: connection,
            spaceIdentifier: EmbeddingInputFormatter.spaceIdentifier(
              connection: provider.connection,
              modelIdentifier: profile.modelIdentifier
            )
          )
        )
      } catch {
        warnings.append("\(profile.displayName) could not access its provider credential.")
      }
    }
    return result
  }

  private static func run(jobs: [BoundedDocumentIndexJob]) async
    -> [BoundedDocumentIndexResult]
  {
    await withTaskGroup(of: BoundedDocumentIndexResult.self) { group in
      for job in jobs {
        group.addTask { await run(job: job) }
      }
      var results: [BoundedDocumentIndexResult] = []
      for await result in group { results.append(result) }
      return results
    }
  }

  private static func run(job: BoundedDocumentIndexJob) async -> BoundedDocumentIndexResult {
    await withTaskGroup(of: BoundedDocumentIndexResult.self) { group in
      group.addTask { await perform(job: job) }
      group.addTask {
        do {
          try await Task.sleep(for: .seconds(60))
        } catch {
          return BoundedDocumentIndexResult.empty(for: job)
        }
        return BoundedDocumentIndexResult(
          profile: job.profile,
          providerSnapshot: job.providerSnapshot,
          spaceIdentifier: job.spaceIdentifier,
          vectors: [],
          warning: "\(job.profile.displayName) did not finish document indexing in time.",
          didTimeOut: true
        )
      }
      let first = await group.next() ?? .empty(for: job)
      group.cancelAll()
      if first.didTimeOut, let partial = await group.next(), !partial.didTimeOut {
        return BoundedDocumentIndexResult(
          profile: partial.profile,
          providerSnapshot: partial.providerSnapshot,
          spaceIdentifier: partial.spaceIdentifier,
          vectors: partial.vectors,
          warning: first.warning,
          didTimeOut: true
        )
      }
      return first
    }
  }

  private static func perform(job: BoundedDocumentIndexJob) async -> BoundedDocumentIndexResult {
    var vectors: [BoundedDocumentIndexedVector] = []
    do {
      let client = EmbeddingProviderClientFactory.make(connection: job.connection)
      let embedded = try await client.embed(
        job.candidates.map {
          EmbeddingInputFormatter.document(
            $0.content,
            provider: job.connection.provider,
            modelIdentifier: job.profile.modelIdentifier
          )
        },
        modelIdentifier: job.profile.modelIdentifier,
        purpose: .document
      )
      for (candidate, vector) in zip(job.candidates, embedded) {
        vectors.append(
          BoundedDocumentIndexedVector(
            candidate: candidate,
            contentFingerprint: EmbeddingVectorCodec.fingerprint(for: candidate.content),
            vector: vector
          )
        )
      }
      return BoundedDocumentIndexResult(
        profile: job.profile,
        providerSnapshot: job.providerSnapshot,
        spaceIdentifier: job.spaceIdentifier,
        vectors: vectors,
        warning: nil,
        didTimeOut: false
      )
    } catch is CancellationError {
      return .empty(for: job)
    } catch {
      return BoundedDocumentIndexResult(
        profile: job.profile,
        providerSnapshot: job.providerSnapshot,
        spaceIdentifier: job.spaceIdentifier,
        vectors: vectors,
        warning:
          "\(job.profile.displayName) indexed only part of the document; missing chunks will retry later.",
        didTimeOut: false
      )
    }
  }
}

private actor SemanticDocumentIndexActorFactory {
  func sourceRepository(modelContainer: ModelContainer) -> SemanticDocumentIndexSourceRepository {
    SemanticDocumentIndexSourceRepository(modelContainer: modelContainer)
  }

  func vectorRepository(modelContainer: ModelContainer) -> SemanticDocumentIndexVectorRepository {
    SemanticDocumentIndexVectorRepository(modelContainer: modelContainer)
  }
}

@ModelActor
private actor SemanticDocumentIndexSourceRepository {
  func healthConfiguration() throws -> SemanticDocumentHealthConfiguration {
    try Task.checkCancellation()
    let documentProfiles = try modelContext.fetch(
      FetchDescriptor<EmbeddingProfileRecord>(
        predicate: #Predicate { $0.isEnabled && $0.indexesDocuments },
        sortBy: [
          SortDescriptor(\EmbeddingProfileRecord.updatedAt, order: .reverse),
          SortDescriptor(\EmbeddingProfileRecord.id),
        ]
      )
    ).map(SemanticHealthProfileSnapshot.init)
    var activeDescriptor = FetchDescriptor<EmbeddingProfileRecord>(
      predicate: #Predicate { $0.isEnabled },
      sortBy: [
        SortDescriptor(\EmbeddingProfileRecord.updatedAt, order: .reverse),
        SortDescriptor(\EmbeddingProfileRecord.id),
      ]
    )
    activeDescriptor.fetchLimit = SemanticDocumentIndexPipeline.maximumProfilesForRepository
    let activeProfileIDs = Set(try modelContext.fetch(activeDescriptor).map(\.id))
    let providers = try providerSnapshots(
      ids: Array(Set(documentProfiles.compactMap(\.providerConfigurationID)))
    )
    return SemanticDocumentHealthConfiguration(
      profiles: documentProfiles,
      activeProfileIDs: activeProfileIDs,
      providersByID: providers
    )
  }

  func indexConfiguration(maximumProfiles: Int) throws -> SemanticDocumentIndexConfiguration {
    try Task.checkCancellation()
    let enabledPredicate = #Predicate<EmbeddingProfileRecord> { $0.isEnabled }
    var descriptor = FetchDescriptor<EmbeddingProfileRecord>(
      predicate: enabledPredicate,
      sortBy: [
        SortDescriptor(\EmbeddingProfileRecord.updatedAt, order: .reverse),
        SortDescriptor(\EmbeddingProfileRecord.id),
      ]
    )
    descriptor.fetchLimit = max(0, maximumProfiles)
    let records = try modelContext.fetch(descriptor)
    let profiles = records.filter(\.indexesDocuments).map(\.snapshot)
    let providers = try providerSnapshots(
      ids: Array(Set(profiles.compactMap(\.providerConfigurationID)))
    )
    return SemanticDocumentIndexConfiguration(
      profiles: profiles,
      enabledProfileCount: try modelContext.fetchCount(
        FetchDescriptor<EmbeddingProfileRecord>(predicate: enabledPredicate)
      ),
      providersByID: providers
    )
  }

  func enabledDocumentIDs(offset: Int, limit: Int) throws -> [UUID] {
    precondition(offset >= 0 && limit > 0)
    try Task.checkCancellation()
    var descriptor = FetchDescriptor<ImportedDocumentRecord>(
      predicate: #Predicate { $0.isEnabled },
      sortBy: [
        SortDescriptor(\ImportedDocumentRecord.createdAt),
        SortDescriptor(\ImportedDocumentRecord.id),
      ]
    )
    descriptor.fetchOffset = offset
    descriptor.fetchLimit = limit
    descriptor.includePendingChanges = false
    return try modelContext.fetch(descriptor).map(\.id)
  }

  func enabledDocument(id: UUID) throws -> SemanticDocumentIndexDocument? {
    try Task.checkCancellation()
    let targetID = id
    var descriptor = FetchDescriptor<ImportedDocumentRecord>(
      predicate: #Predicate { $0.id == targetID && $0.isEnabled }
    )
    descriptor.fetchLimit = 1
    descriptor.includePendingChanges = false
    guard let record = try modelContext.fetch(descriptor).first else { return nil }
    return SemanticDocumentIndexDocument(id: record.id, title: record.title)
  }

  func chunkPage(
    documentID: UUID,
    after cursor: SemanticDocumentChunkCursor?,
    limit: Int
  ) throws -> SemanticDocumentChunkPage {
    precondition(limit > 0)
    try Task.checkCancellation()
    let targetID = documentID
    let descriptor: FetchDescriptor<DocumentChunkRecord>
    if let cursor {
      let chunkIndex = cursor.chunkIndex
      let chunkID = cursor.id
      descriptor = FetchDescriptor(
        predicate: #Predicate {
          $0.documentID == targetID
            && ($0.chunkIndex > chunkIndex
              || ($0.chunkIndex == chunkIndex && $0.id > chunkID))
        },
        sortBy: [
          SortDescriptor(\DocumentChunkRecord.chunkIndex),
          SortDescriptor(\DocumentChunkRecord.id),
        ]
      )
    } else {
      descriptor = FetchDescriptor(
        predicate: #Predicate { $0.documentID == targetID },
        sortBy: [
          SortDescriptor(\DocumentChunkRecord.chunkIndex),
          SortDescriptor(\DocumentChunkRecord.id),
        ]
      )
    }
    var pageDescriptor = descriptor
    pageDescriptor.fetchLimit = limit
    pageDescriptor.includePendingChanges = false
    let records = try modelContext.fetch(pageDescriptor)
    let chunks = records.compactMap { record -> SemanticDocumentChunkSnapshot? in
      guard !record.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
      }
      return SemanticDocumentChunkSnapshot(
        id: record.id,
        documentID: record.documentID,
        chunkIndex: record.chunkIndex,
        content: record.content,
        pageNumber: record.pageNumber,
        isOCRDerived: record.isOCRDerived,
        createdAt: record.createdAt
      )
    }
    return SemanticDocumentChunkPage(
      chunks: chunks,
      nextCursor: records.last.map {
        SemanticDocumentChunkCursor(chunkIndex: $0.chunkIndex, id: $0.id)
      },
      rawRecordsWereEmpty: records.isEmpty,
      hasMore: records.count == limit
    )
  }

  func isCurrent(
    profile expectedProfile: EmbeddingProfileSnapshot,
    provider expectedProvider: ProviderConnection,
    embeddingSpaceIdentifier: String
  ) throws -> Bool {
    try Task.checkCancellation()
    let validationContext = ModelContext(modelContainer)
    let profileID = expectedProfile.id
    var profileDescriptor = FetchDescriptor<EmbeddingProfileRecord>(
      predicate: #Predicate { $0.id == profileID }
    )
    profileDescriptor.fetchLimit = 1
    guard let profile = try validationContext.fetch(profileDescriptor).first,
      profile.isEnabled,
      profile.indexesDocuments,
      profile.snapshot == expectedProfile,
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
    let currentProvider = Self.providerSnapshot(provider)
    return currentProvider == expectedProvider
      && EmbeddingInputFormatter.spaceIdentifier(
        connection: currentProvider,
        modelIdentifier: profile.modelIdentifier
      ) == embeddingSpaceIdentifier
  }

  func validCandidateIDs(for versions: [SemanticCandidateVersion]) throws -> Set<UUID> {
    guard !versions.isEmpty else { return [] }
    precondition(versions.count <= SemanticDocumentIndexPipeline.indexPageSizeForRepository)
    try Task.checkCancellation()
    let validationContext = ModelContext(modelContainer)
    let ids = versions.map(\.id)
    let expectedByID = Dictionary(
      versions.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let chunkDescriptor = FetchDescriptor<DocumentChunkRecord>(
      predicate: #Predicate { ids.contains($0.id) }
    )
    let chunks = try validationContext.fetch(chunkDescriptor)
    let documentIDs = Array(Set(chunks.map(\.documentID)))
    let documentDescriptor = FetchDescriptor<ImportedDocumentRecord>(
      predicate: #Predicate { documentIDs.contains($0.id) && $0.isEnabled }
    )
    let enabledDocumentIDs = Set(try validationContext.fetch(documentDescriptor).map(\.id))
    return Set(
      chunks.compactMap { chunk in
        guard let expected = expectedByID[chunk.id],
          expected.source == .documentChunk,
          expected.containerID == chunk.documentID,
          enabledDocumentIDs.contains(chunk.documentID),
          expected.contentFingerprint == EmbeddingVectorCodec.fingerprint(for: chunk.content)
        else {
          return nil
        }
        return chunk.id
      }
    )
  }

  func existingProfileIDs(_ ids: [UUID]) throws -> Set<UUID> {
    guard !ids.isEmpty else { return [] }
    precondition(ids.count <= 128)
    try Task.checkCancellation()
    let descriptor = FetchDescriptor<EmbeddingProfileRecord>(
      predicate: #Predicate { ids.contains($0.id) }
    )
    return Set(try modelContext.fetch(descriptor).map(\.id))
  }

  func existingChunkIDs(_ ids: [UUID]) throws -> Set<UUID> {
    guard !ids.isEmpty else { return [] }
    precondition(ids.count <= 128)
    try Task.checkCancellation()
    let descriptor = FetchDescriptor<DocumentChunkRecord>(
      predicate: #Predicate { ids.contains($0.id) }
    )
    return Set(try modelContext.fetch(descriptor).map(\.id))
  }

  private func providerSnapshots(ids: [UUID]) throws
    -> [UUID: SemanticHealthProviderSnapshot]
  {
    guard !ids.isEmpty else { return [:] }
    var result: [UUID: SemanticHealthProviderSnapshot] = [:]
    for page in ids.chunked(maximumCount: 128) {
      try Task.checkCancellation()
      let pageIDs = page
      let descriptor = FetchDescriptor<ProviderConfigurationRecord>(
        predicate: #Predicate { pageIDs.contains($0.id) }
      )
      for provider in try modelContext.fetch(descriptor) {
        result[provider.id] = SemanticHealthProviderSnapshot(
          id: provider.id,
          connection: Self.providerSnapshot(provider),
          isEnabled: provider.isEnabled
        )
      }
    }
    return result
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
private actor SemanticDocumentIndexVectorRepository {
  func hasMixedDimensions(
    profileID: UUID,
    embeddingSpaceIdentifier: String
  ) throws -> Bool {
    try SemanticVectorDimensionInvariant.hasMixedDimensions(
      profileID: profileID,
      embeddingSpaceIdentifier: embeddingSpaceIdentifier,
      in: modelContext
    )
  }

  func healthSnapshots(profileID: UUID, sourceIDs: [UUID]) throws
    -> [SemanticDocumentVectorHealthSnapshot]
  {
    guard !sourceIDs.isEmpty else { return [] }
    precondition(sourceIDs.count <= 128)
    try Task.checkCancellation()
    let cacheKeys = sourceIDs.map {
      EmbeddingVectorRecord.makeCacheKey(profileID: profileID, sourceID: $0)
    }
    var descriptor = FetchDescriptor<EmbeddingVectorRecord>(
      predicate: #Predicate { cacheKeys.contains($0.cacheKey) }
    )
    descriptor.fetchLimit = cacheKeys.count
    descriptor.includePendingChanges = false
    return try modelContext.fetch(descriptor).map(SemanticDocumentVectorHealthSnapshot.init)
  }

  func upsert(_ writes: [SemanticVectorWrite]) throws {
    guard !writes.isEmpty else { return }
    precondition(writes.count <= 32)
    try Task.checkCancellation()
    try SemanticVectorDimensionInvariant.withExclusiveWrite {
      // Rebuild deletion uses a separate context. Start every write from a fresh store view so
      // deleted rows cannot survive as stale registered model objects in this repository actor.
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
        for write in writes {
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

  func documentVectorPage(afterID: UUID?, limit: Int) throws
    -> SemanticDocumentVectorPage
  {
    precondition(limit > 0)
    try Task.checkCancellation()
    let sourceKind = RetrievalSourceKind.documentChunk.rawValue
    let descriptor: FetchDescriptor<EmbeddingVectorRecord>
    if let afterID {
      let cursor = afterID
      descriptor = FetchDescriptor(
        predicate: #Predicate {
          $0.sourceKindRawValue == sourceKind && $0.id > cursor
        },
        sortBy: [SortDescriptor(\EmbeddingVectorRecord.id)]
      )
    } else {
      descriptor = FetchDescriptor(
        predicate: #Predicate { $0.sourceKindRawValue == sourceKind },
        sortBy: [SortDescriptor(\EmbeddingVectorRecord.id)]
      )
    }
    var pageDescriptor = descriptor
    pageDescriptor.fetchLimit = limit
    pageDescriptor.includePendingChanges = false
    let records = try modelContext.fetch(pageDescriptor)
    return SemanticDocumentVectorPage(
      records: records.map(SemanticDocumentVectorPageRecord.init),
      nextID: records.last?.id,
      hasMore: records.count == limit
    )
  }

  func deleteVectors(profileID: UUID) throws {
    try Task.checkCancellation()
    try SemanticVectorDimensionInvariant.withExclusiveWrite {
      let targetProfileID = profileID
      let deletionContext = ModelContext(modelContainer)
      do {
        try deletionContext.delete(
          model: EmbeddingVectorRecord.self,
          where: #Predicate { $0.profileID == targetProfileID }
        )
        try deletionContext.save()
      } catch {
        deletionContext.rollback()
        throw error
      }
    }
  }

  func delete(cacheKeys: [String]) throws {
    guard !cacheKeys.isEmpty else { return }
    precondition(cacheKeys.count <= 128)
    try Task.checkCancellation()
    // Keep the keyset reader's model context mutation-free. SwiftData can otherwise skip rows
    // when a cursor query follows deletes registered on the same context.
    let deletionContext = ModelContext(modelContainer)
    do {
      try deletionContext.delete(
        model: EmbeddingVectorRecord.self,
        where: #Predicate { cacheKeys.contains($0.cacheKey) }
      )
      try deletionContext.save()
    } catch {
      deletionContext.rollback()
      throw error
    }
  }
}

private struct SemanticDocumentHealthConfiguration: Sendable {
  let profiles: [SemanticHealthProfileSnapshot]
  let activeProfileIDs: Set<UUID>
  let providersByID: [UUID: SemanticHealthProviderSnapshot]
}

private struct SemanticDocumentIndexConfiguration: Sendable {
  let profiles: [EmbeddingProfileSnapshot]
  let enabledProfileCount: Int
  let providersByID: [UUID: SemanticHealthProviderSnapshot]
}

private struct SemanticHealthProfileSnapshot: Sendable {
  let id: UUID
  let displayName: String
  let providerConfigurationID: UUID?
  let modelIdentifier: String

  init(_ record: EmbeddingProfileRecord) {
    id = record.id
    displayName = record.displayName
    providerConfigurationID = record.providerConfigurationID
    modelIdentifier = record.modelIdentifier
  }
}

private struct SemanticHealthProviderSnapshot: Sendable {
  let id: UUID
  let connection: ProviderConnection
  let isEnabled: Bool
}

private struct SemanticDocumentIndexDocument: Sendable {
  let id: UUID
  let title: String
}

private struct SemanticDocumentChunkSnapshot: Sendable {
  let id: UUID
  let documentID: UUID
  let chunkIndex: Int
  let content: String
  let pageNumber: Int?
  let isOCRDerived: Bool
  let createdAt: Date

  var contentFingerprint: String { EmbeddingVectorCodec.fingerprint(for: content) }

  func candidate(title: String) -> RetrievalCandidate {
    RetrievalCandidate(
      id: id,
      source: .documentChunk,
      containerID: documentID,
      title: title,
      content: content,
      pageNumber: pageNumber,
      isOCRDerived: isOCRDerived,
      createdAt: createdAt
    )
  }
}

private struct SemanticDocumentChunkPage: Sendable {
  let chunks: [SemanticDocumentChunkSnapshot]
  let nextCursor: SemanticDocumentChunkCursor?
  let rawRecordsWereEmpty: Bool
  let hasMore: Bool
}

private struct SemanticDocumentChunkCursor: Sendable {
  let chunkIndex: Int
  let id: UUID
}

private struct SemanticDocumentVectorHealthSnapshot: Sendable {
  let profileID: UUID
  let sourceKind: RetrievalSourceKind
  let sourceID: UUID
  let embeddingSpaceIdentifier: String
  let contentFingerprint: String
  let dimensions: Int
  let vectorByteCount: Int

  init(_ record: EmbeddingVectorRecord) {
    profileID = record.profileID
    sourceKind = record.sourceKind
    sourceID = record.sourceID
    embeddingSpaceIdentifier = record.embeddingSpaceIdentifier
    contentFingerprint = record.contentFingerprint
    dimensions = record.dimensions
    vectorByteCount = record.vectorData.count
  }
}

private struct SemanticDocumentVectorPageRecord: Sendable {
  let id: UUID
  let cacheKey: String
  let profileID: UUID
  let sourceID: UUID

  init(_ record: EmbeddingVectorRecord) {
    id = record.id
    cacheKey = record.cacheKey
    profileID = record.profileID
    sourceID = record.sourceID
  }
}

private struct SemanticDocumentVectorPage: Sendable {
  let records: [SemanticDocumentVectorPageRecord]
  let nextID: UUID?
  let hasMore: Bool
}

private struct SemanticDocumentHealthAccumulator: Sendable {
  let profile: SemanticHealthProfileSnapshot
  let availability: SemanticDocumentProfileAvailability
  let expectedSpaceIdentifier: String?
  var hasMixedVectorDimensions = false
  var indexedDocumentCount = 0
  var validVectorCount = 0
  var missingVectorCount = 0
  var staleVectorCount = 0

  var health: SemanticDocumentProfileHealth {
    SemanticDocumentProfileHealth(
      profileID: profile.id,
      displayName: profile.displayName,
      availability: availability,
      indexedDocumentCount: indexedDocumentCount,
      validVectorCount: validVectorCount,
      missingVectorCount: missingVectorCount,
      staleVectorCount: staleVectorCount
    )
  }
}

private struct SemanticAuthenticatedDocumentProfile: Sendable {
  let profile: EmbeddingProfileSnapshot
  let providerSnapshot: ProviderConnection
  let connection: ProviderConnection
  let spaceIdentifier: String
}

private struct BoundedDocumentIndexJob: Sendable {
  let profile: EmbeddingProfileSnapshot
  let providerSnapshot: ProviderConnection
  let connection: ProviderConnection
  let spaceIdentifier: String
  let candidates: [RetrievalCandidate]
}

private struct BoundedDocumentIndexedVector: Sendable {
  let candidate: RetrievalCandidate
  let contentFingerprint: String
  let vector: [Float]
}

private struct BoundedDocumentIndexResult: Sendable {
  let profile: EmbeddingProfileSnapshot
  let providerSnapshot: ProviderConnection
  let spaceIdentifier: String
  let vectors: [BoundedDocumentIndexedVector]
  let warning: String?
  let didTimeOut: Bool

  static func empty(for job: BoundedDocumentIndexJob) -> Self {
    Self(
      profile: job.profile,
      providerSnapshot: job.providerSnapshot,
      spaceIdentifier: job.spaceIdentifier,
      vectors: [],
      warning: nil,
      didTimeOut: false
    )
  }
}

private struct SemanticDocumentWarningBag {
  private(set) var values: [String] = []
  private var seen: Set<String> = []

  mutating func append(_ warning: String) {
    guard seen.insert(warning).inserted else { return }
    values.append(warning)
  }

  mutating func append(contentsOf warnings: [String]) {
    for warning in warnings { append(warning) }
  }
}

extension SemanticDocumentIndexPipeline {
  fileprivate static var indexPageSizeForRepository: Int { indexPageSize }
  fileprivate static var maximumProfilesForRepository: Int { maximumProfiles }
}

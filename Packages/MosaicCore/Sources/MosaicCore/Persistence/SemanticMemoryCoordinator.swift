import Foundation
import SwiftData

public enum SemanticMemoryCoordinator {
  private static let maximumCandidatesPerSource = 5_000
  private static let maximumEmbeddingProfilesPerRequest = 4
  private static let maximumLocalPoolCount = 96
  private static let embeddingBatchSize = 32

  @MainActor
  public static func retrieve(
    query: String,
    excluding conversationID: UUID,
    in modelContext: ModelContext,
    connection: ProviderConnection? = nil
  ) async -> RetrievedContext {
    let actorFactory = SemanticRetrievalActorFactory()
    let sourceReader = await actorFactory.sourceReader(
      modelContainer: modelContext.container
    )
    let rerankSettings = RecallRerankerSettings.load()
    let rerankProvider = rerankSettings.providerID.flatMap { id -> ProviderConnection? in
      guard rerankSettings.isUsable,
        let record = try? modelContext.fetch(
          FetchDescriptor<ProviderConfigurationRecord>(predicate: #Predicate { $0.id == id })
        ).first, record.isEnabled
      else { return nil }
      return ProviderConnection(
        id: record.id, displayName: record.displayName, provider: record.provider,
        baseURL: record.baseURL, modelIdentifier: record.modelIdentifier,
        contextWindowTokens: record.contextWindowTokens,
        maximumOutputTokens: record.maximumOutputTokens)
    }
    return await retrieve(
      query: query,
      excluding: conversationID,
      sourceReader: sourceReader,
      computeActor: SemanticRetrievalComputeActor(),
      makeVectorRepository: {
        await actorFactory.vectorRepository(modelContainer: SemanticIndexStore.shared)
      },
      indexIsTemporary: { SemanticIndexStore.didFallBackToMemory },
      rankingConnection: connection,
      rankingUsage: { id, usage, date in
        guard let connection else { return }
        try ExperienceStore.save(
          ExperienceValue(
            id: id, kind: .usage,
            providerID: connection.id, model: connection.modelIdentifier,
            conversationID: conversationID,
            usageCategory: "Smart memory", inputTokens: usage?.inputTokens,
            outputTokens: usage?.outputTokens, usageDate: date,
            usageProviderKind: connection.provider,
            usageProviderHost: connection.resolvedBaseURL?.host), in: modelContext)
        try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
      },
      rerankSettings: rerankSettings,
      rerankProvider: rerankProvider,
      rerankUsage: { id, provider, model, date in
        try ExperienceStore.save(
          ExperienceValue(
            id: id, kind: .usage,
            providerID: provider.id, model: model,
            conversationID: conversationID,
            usageCategory: "Reranker", inputTokens: nil, outputTokens: nil, usageDate: date,
            usageProviderKind: provider.provider,
            usageProviderHost: provider.resolvedBaseURL?.host), in: modelContext)
        try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
      }
    )
  }

  /// Checks the exact selected excerpts again immediately before the chat stream starts. Recall
  /// can spend time waiting for history compaction, so the validation performed while ranking is
  /// not late enough to protect a source that another window moves or edits meanwhile.
  @MainActor
  static func isCurrent(
    _ context: RetrievedContext,
    audienceScope: ConversationProjectScope,
    in modelContext: ModelContext
  ) async -> Bool {
    guard Set(context.items.map(\.id)).count == context.items.count else { return false }
    guard !context.items.isEmpty else { return true }
    do {
      try Task.checkCancellation()
      let versions = try context.items.map { item in
        guard let sourceFingerprint = item.sourceFingerprint else {
          throw SemanticRequestContextValidationError.missingSourceFingerprint
        }
        return SemanticCandidateVersion(
          id: item.id,
          source: item.source,
          containerID: item.containerID,
          contentFingerprint: sourceFingerprint,
          audienceConversationID: audienceScope.conversationID,
          audienceProjectID: audienceScope.projectID,
          audienceBindingID: audienceScope.bindingID,
          audienceBindingUpdatedAt: audienceScope.bindingUpdatedAt
        )
      }
      let actorFactory = SemanticRetrievalActorFactory()
      let sourceReader = await actorFactory.sourceReader(
        modelContainer: modelContext.container
      )
      let validIDs = try await sourceReader.validCandidateIDs(for: versions)
      return validIDs == Set(context.items.map(\.id))
    } catch {
      return false
    }
  }

  @MainActor
  static func retrieve(
    query: String,
    excluding conversationID: UUID,
    sourceReader: any SemanticRetrievalSourceAccessing,
    computeActor: SemanticRetrievalComputeActor,
    makeVectorRepository: @MainActor () async -> any SemanticRetrievalVectorAccessing,
    indexIsTemporary: () -> Bool = { false },
    rankingConnection: ProviderConnection? = nil,
    rankingUsage: (UUID, TokenUsage?, Date) throws -> Void = { _, _, _ in },
    rerankSettings: RecallRerankerSettings = RecallRerankerSettings(),
    rerankProvider: ProviderConnection? = nil,
    rerankClientFactory: @Sendable (ProviderConnection) -> any RerankProviderClient = {
      RerankProviderClientFactory.make(connection: $0)
    },
    rerankUsage: @escaping @MainActor (UUID, ProviderConnection, String, Date) throws -> Void = {
      _, _, _, _ in
    }
  ) async -> RetrievedContext {
    var sourceSnapshot: SemanticRetrievalSourceSnapshot?
    var localPreparation: LocalRetrievalPreparation?
    var rerankStage: RecallRerankStage?

    do {
      try Task.checkCancellation()
      let snapshot = try await sourceReader.snapshot(
        excluding: conversationID,
        maximumCandidatesPerSource: maximumCandidatesPerSource,
        maximumProfiles: maximumEmbeddingProfilesPerRequest
      )
      sourceSnapshot = snapshot
      guard !snapshot.candidates.isEmpty else { return .empty }

      let prepared = try await computeActor.prepare(
        query: query,
        candidates: snapshot.candidates,
        maximumCount: maximumLocalPoolCount
      )
      localPreparation = prepared
      try Task.checkCancellation()

      var rankingWarnings: [String] = []
      if rerankSettings.isUsable {
        if let provider = rerankProvider, provider.provider.supportsReranking {
          do {
            let key = try await SecurityKeychain.shared.apiKey(
              for: provider.id, expectedBinding: provider.credentialBinding)
            let connection = provider.authenticated(with: key)
            let usageID = UUID()
            let model = rerankSettings.modelIdentifier
            rerankStage = RecallRerankStage(
              client: rerankClientFactory(connection),
              providerName: provider.displayName,
              modelIdentifier: model,
              minimumScore: rerankSettings.minimumScore,
              recordUsage: { date in try rerankUsage(usageID, connection, model, date) }
            )
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            rankingWarnings.append(
              "The reranker could not read its provider key: \(error.localizedDescription)")
          }
        } else {
          rankingWarnings.append(
            "The selected reranker provider is not enabled or does not offer reranking.")
        }
      }
      let smartConnection: ProviderConnection? =
        UserDefaults.standard.object(forKey: "smartMemoryEnabled") as? Bool != false
        ? rankingConnection : nil

      /// Asks the selected chat model which of `pool` help answer the question; nil when nothing in
      /// the pool is affordable. Only exact candidate IDs can leave this stage.
      func smartMemoryContext(
        from pool: [RetrievalCandidate], connection: ProviderConnection
      ) async throws -> RetrievedContext? {
        let key = try await SecurityKeychain.shared.apiKey(
          for: connection.id, expectedBinding: connection.credentialBinding)
        let budget = min(24_000, max(0, (connection.contextWindowTokens ?? 32_000) / 3 - 3_000))
        var remaining = budget
        let affordable = pool.filter { candidate in
          let cost = String(candidate.content.prefix(600)).utf8.count + 80
          guard remaining >= cost else { return false }
          remaining -= cost
          return true
        }
        guard !affordable.isEmpty else { return nil }
        let versions = try await computeActor.versions(
          for: affordable, audienceScope: snapshot.audienceScope)
        let valid = try await sourceReader.validCandidateIDs(for: versions)
        guard valid == Set(affordable.map(\.id)) else {
          throw ConversationCompactionError.staleSource
        }
        let usageID = UUID()
        let usageDate = Date.now
        try rankingUsage(usageID, nil, usageDate)
        let ranked = try await SemanticMemoryReranker.rank(
          query: query, candidates: affordable,
          client: ProviderClientFactory.make(connection: connection.authenticated(with: key)))
        try rankingUsage(usageID, ranked.usage, usageDate)
        let usage =
          ranked.usage.map {
            "Smart memory used \($0.inputTokens.map(String.init) ?? "unreported") input and \($0.outputTokens.map(String.init) ?? "unreported") output tokens with the selected chat model."
          } ?? "Smart memory used the selected chat model; token usage was not reported."
        return try await validatedContext(
          query: query,
          candidates: snapshot.candidates.filter { ranked.scores.scores[$0.id] != nil },
          semanticScoreSets: [ranked.scores], localPreparation: prepared,
          warnings: [usage] + (rerankStage == nil ? [] : [Self.rerankerSkippedWarning]),
          audienceScope: snapshot.audienceScope, sourceReader: sourceReader,
          computeActor: computeActor)
      }
      let smartMemoryFailure =
        "Smart memory was unavailable; used local matching or enabled embeddings. The attempted relevance check may have consumed provider credits."

      // Without embeddings the judge only has the local lexical pool, so it runs before anything else.
      // With embeddings it runs after them on the embedding-ranked candidates (below): on the
      // personal-memory benchmark the lexical top 40 held the answer for 81% of queries, the
      // embedding top 20 for 100%.
      if let connection = smartConnection, snapshot.selectedProfiles.isEmpty {
        do {
          if let context = try await smartMemoryContext(
            from: Array(prepared.candidatePool.prefix(40)), connection: connection)
          {
            return context
          }
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          rankingWarnings.append(smartMemoryFailure)
        }
      }

      // Do not even initialize the rebuildable vector store when semantic recall is disabled.
      guard !snapshot.selectedProfiles.isEmpty else {
        return try await validatedContext(
          query: query,
          candidates: snapshot.candidates,
          semanticScoreSets: [],
          localPreparation: prepared,
          warnings: rankingWarnings,
          audienceScope: snapshot.audienceScope,
          sourceReader: sourceReader,
          computeActor: computeActor,
          rerank: rerankStage
        )
      }

      var warnings: [String] = rankingWarnings
      if snapshot.enabledProfileCount > maximumEmbeddingProfilesPerRequest {
        warnings.append(
          "Only the four most recently updated embedding profiles were used for this request."
        )
      }

      var jobs: [EmbeddingJob] = []
      for profile in snapshot.selectedProfiles {
        try Task.checkCancellation()
        guard profile.backend == .provider,
          let providerID = profile.providerConfigurationID,
          let provider = snapshot.providersByID[providerID]
        else {
          warnings.append("\(profile.displayName) is not connected to an enabled provider.")
          continue
        }
        guard provider.provider.supportsEmbeddings else {
          warnings.append("\(provider.displayName) does not expose a compatible embedding API.")
          continue
        }

        let eligible = try await computeActor.eligibleCandidates(
          from: snapshot.candidates,
          profile: profile
        )
        guard !eligible.isEmpty else { continue }
        let eligiblePool = try await computeActor.eligibleCandidates(
          from: prepared.candidatePool,
          profile: profile
        )

        do {
          let apiKey = try await SecurityKeychain.shared.apiKey(
            for: provider.id,
            expectedBinding: provider.credentialBinding
          )
          let connection = provider.authenticated(with: apiKey)
          jobs.append(
            EmbeddingJob(
              profile: profile,
              providerSnapshot: provider,
              connection: connection,
              client: EmbeddingProviderClientFactory.make(connection: connection),
              spaceIdentifier: EmbeddingInputFormatter.spaceIdentifier(
                connection: connection,
                modelIdentifier: profile.modelIdentifier
              ),
              query: query,
              candidates: eligible,
              candidatePool: eligiblePool,
              audienceScope: snapshot.audienceScope
            )
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          warnings.append(
            "\(profile.displayName) could not read its provider key: \(error.localizedDescription)"
          )
        }
      }

      guard !jobs.isEmpty else {
        return try await validatedContext(
          query: query,
          candidates: snapshot.candidates,
          semanticScoreSets: [],
          localPreparation: prepared,
          warnings: warnings,
          audienceScope: snapshot.audienceScope,
          sourceReader: sourceReader,
          computeActor: computeActor,
          rerank: rerankStage
        )
      }
      if indexIsTemporary() {
        warnings.append(
          "The persistent vector cache was unavailable, so this session is using a temporary index."
        )
      }
      let vectorRepository = await makeVectorRepository()

      let results = try await run(
        jobs: jobs,
        sourceReader: sourceReader,
        vectorRepository: vectorRepository,
        computeActor: computeActor
      )
      try Task.checkCancellation()

      var semanticScoreSets: [SemanticScoreSet] = []
      for result in results {
        if let warning = result.warning { warnings.append(warning) }
        if !result.scores.isEmpty || !result.writes.isEmpty {
          guard try await sourceReader.isCurrent(profile: result.profileVersion) else {
            warnings.append(
              "\(result.profile.displayName) changed before recall completed; its stale result was ignored."
            )
            continue
          }
        }
        if !result.scores.isEmpty {
          semanticScoreSets.append(
            SemanticScoreSet(
              profileName: result.profile.displayName,
              weight: result.profile.weight,
              scores: result.scores
            )
          )
        }
        guard !result.writes.isEmpty else { continue }
        try Task.checkCancellation()
        let validWriteIDs = try await sourceReader.validCandidateIDs(
          for: result.writeVersions
        )
        let currentWrites = result.writes.filter { validWriteIDs.contains($0.sourceID) }
        if currentWrites.count != result.writes.count {
          warnings.append(
            "Some embedding cache entries changed before they could be saved, so Turing AI discarded them."
          )
        }
        for page in currentWrites.chunked(
          maximumCount: SemanticRetrievalVectorRepository.maximumPageSize
        ) {
          try Task.checkCancellation()
          try await vectorRepository.upsert(page)
        }
      }

      if let connection = smartConnection, !semanticScoreSets.isEmpty {
        do {
          let firstStage = try await computeActor.retrieveFirstStage(
            query: query, candidates: snapshot.candidates, semanticScoreSets: semanticScoreSets,
            localPreparation: prepared, warnings: warnings)
          let byID = Dictionary(
            snapshot.candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
          let pool = firstStage.items.compactMap { byID[$0.id] }
          if let context = try await smartMemoryContext(from: pool, connection: connection) {
            return context
          }
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          warnings.append(smartMemoryFailure)
        }
      }

      return try await validatedContext(
        query: query,
        candidates: snapshot.candidates,
        semanticScoreSets: semanticScoreSets,
        localPreparation: prepared,
        warnings: warnings,
        audienceScope: snapshot.audienceScope,
        sourceReader: sourceReader,
        computeActor: computeActor,
        rerank: rerankStage
      )
    } catch is CancellationError {
      // The caller remains cancelled and performs its normal cancellation transition. No cache
      // writes occur after this point.
      return .empty
    } catch {
      let warning = "Automatic recall fell back because the local index could not be read."
      guard let snapshot = sourceSnapshot, let prepared = localPreparation else {
        return RetrievedContext(systemContent: "", items: [], warnings: [warning])
      }
      return
        (try? await validatedContext(
          query: query,
          candidates: snapshot.candidates,
          semanticScoreSets: [],
          localPreparation: prepared,
          warnings: [warning],
          audienceScope: snapshot.audienceScope,
          sourceReader: sourceReader,
          computeActor: computeActor,
          rerank: rerankStage
        )) ?? RetrievedContext(systemContent: "", items: [], warnings: [warning])
    }
  }

  private static let rerankerSkippedWarning =
    "The reranker was not used; Smart memory ranked this request."

  private static func validatedContext(
    query: String,
    candidates: [RetrievalCandidate],
    semanticScoreSets: [SemanticScoreSet],
    localPreparation: LocalRetrievalPreparation,
    warnings: [String],
    audienceScope: ConversationProjectScope,
    sourceReader: any SemanticRetrievalSourceAccessing,
    computeActor: SemanticRetrievalComputeActor,
    rerank: RecallRerankStage? = nil
  ) async throws -> RetrievedContext {
    var currentCandidates = candidates
    var currentWarnings = warnings

    // At most six items can be selected by the retriever. Rechecking after each removal prevents a
    // newly surfaced stale item from replacing a stale top result indefinitely.
    for _ in 0...6 {
      try Task.checkCancellation()
      let context: RetrievedContext
      if let rerank {
        context = try await rerankedContext(
          rerank, query: query, candidates: currentCandidates,
          semanticScoreSets: semanticScoreSets, localPreparation: localPreparation,
          warnings: &currentWarnings, computeActor: computeActor)
      } else {
        context = try await computeActor.retrieve(
          query: query,
          candidates: currentCandidates,
          semanticScoreSets: semanticScoreSets,
          localPreparation: localPreparation,
          warnings: currentWarnings
        )
      }
      guard !context.items.isEmpty else { return context }
      let candidatesByID = Dictionary(
        currentCandidates.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      let selectedCandidates = context.items.compactMap { candidatesByID[$0.id] }
      let versions = try await computeActor.versions(
        for: selectedCandidates,
        audienceScope: audienceScope
      )
      let validIDs = try await sourceReader.validCandidateIDs(for: versions)
      let invalidIDs = Set(selectedCandidates.map(\.id)).subtracting(validIDs)
      guard !invalidIDs.isEmpty else { return context }

      currentCandidates.removeAll { invalidIDs.contains($0.id) }
      if !currentWarnings.contains(where: { $0.contains("changed while recall was running") }) {
        currentWarnings.append(
          "Some recalled sources changed while recall was running, so Turing AI excluded their stale excerpts."
        )
      }
    }

    return RetrievedContext(
      systemContent: "",
      items: [],
      warnings: currentWarnings + [
        "Recall changed repeatedly during this request, so Turing AI omitted retrieved excerpts."
      ]
    )
  }

  /// First stage widened to 20 candidates, then the reranker's probability decides what is injected.
  /// Any reranker failure falls back to the ordinary embedding and local ranking.
  private static func rerankedContext(
    _ stage: RecallRerankStage,
    query: String,
    candidates: [RetrievalCandidate],
    semanticScoreSets: [SemanticScoreSet],
    localPreparation: LocalRetrievalPreparation,
    warnings: inout [String],
    computeActor: SemanticRetrievalComputeActor
  ) async throws -> RetrievedContext {
    let first = try await computeActor.retrieveFirstStage(
      query: query, candidates: candidates, semanticScoreSets: semanticScoreSets,
      localPreparation: localPreparation, warnings: warnings)
    let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let ordered = first.items.compactMap { byID[$0.id] }.filter {
      !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !ordered.isEmpty else { return first }
    do {
      let scores = try await stage.scores(query: query, candidates: ordered)
      return await computeActor.select(
        rankedBy: scores, from: ordered.filter { scores[$0.id] != nil }, warnings: warnings)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let warning =
        "The reranker was unavailable, so Turing AI used embedding and local ranking instead."
      if !warnings.contains(warning) { warnings.append(warning) }
      return try await computeActor.retrieve(
        query: query, candidates: candidates, semanticScoreSets: semanticScoreSets,
        localPreparation: localPreparation, warnings: warnings)
    }
  }

  private static func run(
    jobs: [EmbeddingJob],
    sourceReader: any SemanticRetrievalSourceAccessing,
    vectorRepository: any SemanticRetrievalVectorAccessing,
    computeActor: SemanticRetrievalComputeActor
  ) async throws -> [EmbeddingJobResult] {
    try await withThrowingTaskGroup(
      of: EmbeddingJobResult.self,
      returning: [EmbeddingJobResult].self
    ) { group in
      for job in jobs {
        group.addTask {
          try await run(
            job: job,
            sourceReader: sourceReader,
            vectorRepository: vectorRepository,
            computeActor: computeActor
          )
        }
      }
      var results: [EmbeddingJobResult] = []
      for try await result in group { results.append(result) }
      return results.sorted { $0.profile.id.uuidString < $1.profile.id.uuidString }
    }
  }

  static func run(
    job: EmbeddingJob,
    sourceReader: any SemanticRetrievalSourceAccessing,
    vectorRepository: any SemanticRetrievalVectorAccessing,
    computeActor: SemanticRetrievalComputeActor,
    timeout: Duration = .seconds(15)
  ) async throws -> EmbeddingJobResult {
    let result: EmbeddingJobResult? = await withTaskGroup(
      of: EmbeddingJobRaceResult.self,
      returning: EmbeddingJobResult?.self
    ) { group in
      group.addTask {
        .worker(
          await perform(
            job: job,
            sourceReader: sourceReader,
            vectorRepository: vectorRepository,
            computeActor: computeActor
          )
        )
      }
      group.addTask {
        do {
          try await Task.sleep(for: timeout)
          return .timeout
        } catch {
          return .cancelledTimer
        }
      }

      guard let first = await group.next(), !Task.isCancelled else {
        group.cancelAll()
        return nil
      }
      switch first {
      case .worker(let completed):
        group.cancelAll()
        return completed
      case .timeout:
        group.cancelAll()
        while let next = await group.next() {
          guard !Task.isCancelled else { return nil }
          if case .worker(let partial) = next {
            return EmbeddingJobResult(
              profile: partial.profile,
              profileVersion: partial.profileVersion,
              scores: partial.scores,
              writes: partial.writes,
              writeVersions: partial.writeVersions,
              warning:
                "\(job.profile.displayName) exceeded the recall time limit; local recall was used."
            )
          }
        }
        return EmbeddingJobResult.timedOut(job: job)
      case .cancelledTimer:
        group.cancelAll()
        return nil
      }
    }
    guard let result else { throw CancellationError() }
    return result
  }

  private static func perform(
    job: EmbeddingJob,
    sourceReader: any SemanticRetrievalSourceAccessing,
    vectorRepository: any SemanticRetrievalVectorAccessing,
    computeActor: SemanticRetrievalComputeActor
  ) async -> EmbeddingJobResult {
    let profileVersion = SemanticProfileVersion(
      profile: job.profile,
      provider: job.providerSnapshot,
      embeddingSpaceIdentifier: job.spaceIdentifier
    )
    var scores: [UUID: Double] = [:]
    var writes: [SemanticVectorWrite] = []
    var writeVersions: [SemanticCandidateVersion] = []
    do {
      try Task.checkCancellation()
      let queryVectors = try await job.client.embed(
        [
          EmbeddingInputFormatter.query(
            job.query,
            provider: job.connection.provider,
            modelIdentifier: job.profile.modelIdentifier
          )
        ],
        modelIdentifier: job.profile.modelIdentifier,
        purpose: .query
      )
      try Task.checkCancellation()
      guard let queryVector = queryVectors.first else {
        throw ProviderClientError.invalidResponse
      }

      var validVectorIDs: Set<UUID> = []
      for page in job.candidates.chunked(
        maximumCount: SemanticRetrievalVectorRepository.maximumPageSize
      ) {
        try Task.checkCancellation()
        let records = try await vectorRepository.snapshots(
          profileID: job.profile.id,
          candidateIDs: page.map(\.id)
        )
        let evaluation = try await computeActor.evaluateVectorPage(
          queryVector: queryVector,
          profileID: job.profile.id,
          embeddingSpaceIdentifier: job.spaceIdentifier,
          candidates: page,
          records: records
        )
        scores.merge(evaluation.scores, uniquingKeysWith: { _, latest in latest })
        validVectorIDs.formUnion(evaluation.validVectorIDs)
      }

      let missingCandidates = job.candidatePool.filter { !validVectorIDs.contains($0.id) }
      for batch in missingCandidates.chunked(maximumCount: embeddingBatchSize) {
        try Task.checkCancellation()
        let embedded = try await job.client.embed(
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
        let embeddedVectors = try await computeActor.embeddedVectors(
          candidates: batch,
          vectors: embedded,
          embeddingSpaceIdentifier: job.spaceIdentifier
        )
        try Task.checkCancellation()
        guard try await sourceReader.isCurrent(profile: profileVersion) else {
          return EmbeddingJobResult.stale(job: job)
        }
        let batchVersions = try await computeActor.versions(
          for: embeddedVectors.map(\.candidate),
          audienceScope: job.audienceScope
        )
        let currentIDs = try await sourceReader.validCandidateIDs(for: batchVersions)
        let currentVectors = embeddedVectors.filter {
          currentIDs.contains($0.candidate.id)
        }
        scores.merge(
          try await computeActor.scores(
            queryVector: queryVector,
            embeddedVectors: currentVectors
          ),
          uniquingKeysWith: { _, latest in latest }
        )
        writes.append(
          contentsOf: try await computeActor.writes(
            profileID: job.profile.id,
            embeddedVectors: currentVectors
          )
        )
        writeVersions.append(contentsOf: batchVersions.filter { currentIDs.contains($0.id) })
      }

      try Task.checkCancellation()
      guard try await sourceReader.isCurrent(profile: profileVersion) else {
        return EmbeddingJobResult.stale(job: job)
      }
      return EmbeddingJobResult(
        profile: job.profile,
        profileVersion: profileVersion,
        scores: scores,
        writes: writes,
        writeVersions: writeVersions,
        warning: nil
      )
    } catch is CancellationError {
      return EmbeddingJobResult(
        profile: job.profile,
        profileVersion: profileVersion,
        scores: scores,
        writes: writes,
        writeVersions: writeVersions,
        warning: nil
      )
    } catch {
      return EmbeddingJobResult(
        profile: job.profile,
        profileVersion: profileVersion,
        scores: scores,
        writes: writes,
        writeVersions: writeVersions,
        warning: "\(job.profile.displayName) was unavailable; local recall was used."
      )
    }
  }
}

private enum SemanticRequestContextValidationError: Error {
  case missingSourceFingerprint
}

struct EmbeddingJob: Sendable {
  let profile: EmbeddingProfileSnapshot
  let providerSnapshot: ProviderConnection
  let connection: ProviderConnection
  let client: any EmbeddingProviderClient
  let spaceIdentifier: String
  let query: String
  let candidates: [RetrievalCandidate]
  let candidatePool: [RetrievalCandidate]
  let audienceScope: ConversationProjectScope
}

struct EmbeddingJobResult: Sendable {
  let profile: EmbeddingProfileSnapshot
  let profileVersion: SemanticProfileVersion
  let scores: [UUID: Double]
  let writes: [SemanticVectorWrite]
  let writeVersions: [SemanticCandidateVersion]
  let warning: String?

  fileprivate static func stale(job: EmbeddingJob) -> Self {
    Self(
      profile: job.profile,
      profileVersion: SemanticProfileVersion(
        profile: job.profile,
        provider: job.providerSnapshot,
        embeddingSpaceIdentifier: job.spaceIdentifier
      ),
      scores: [:],
      writes: [],
      writeVersions: [],
      warning:
        "\(job.profile.displayName) changed while recall was running; its stale result was ignored."
    )
  }

  fileprivate static func timedOut(job: EmbeddingJob) -> Self {
    Self(
      profile: job.profile,
      profileVersion: SemanticProfileVersion(
        profile: job.profile,
        provider: job.providerSnapshot,
        embeddingSpaceIdentifier: job.spaceIdentifier
      ),
      scores: [:],
      writes: [],
      writeVersions: [],
      warning: "\(job.profile.displayName) exceeded the recall time limit; local recall was used."
    )
  }
}

private enum EmbeddingJobRaceResult: Sendable {
  case worker(EmbeddingJobResult)
  case timeout
  case cancelledTimer
}

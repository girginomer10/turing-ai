import Foundation

/// Per-request memory of reranker scores, so a recall retry after a stale-source removal never pays
/// for a document it already scored.
actor RecallRerankScoreCache {
  private var scores: [UUID: Double] = [:]
  private var usageRecorded = false

  func missing(from ids: [UUID]) -> [UUID] { ids.filter { scores[$0] == nil } }
  func store(_ newScores: [UUID: Double]) { scores.merge(newScores) { _, new in new } }
  func scores(for ids: [UUID]) -> [UUID: Double] {
    ids.reduce(into: [:]) { result, id in if let score = scores[id] { result[id] = score } }
  }
  /// True the first time only, so one request writes one usage row.
  func claimUsageRecord() -> Bool {
    defer { usageRecorded = true }
    return !usageRecorded
  }
}

/// An optional second recall stage. A cross-encoder reads the question together with each of the
/// first stage's best candidates and its probability decides which ones are injected. On the
/// synthetic personal-memory benchmark this lifts MRR@10 from 0.89 to 0.96 and makes it possible to
/// stay silent when nothing is relevant (benchmarks/memory).
struct RecallRerankStage: Sendable {
  static let firstStageDepth = 20
  static let documentCharacterLimit = 2_000
  static let questionCharacterLimit = 1_200
  static let timeout: Duration = .seconds(12)

  let client: any RerankProviderClient
  let providerName: String
  let modelIdentifier: String
  let minimumScore: Double
  let recordUsage: @MainActor (Date) throws -> Void
  let cache = RecallRerankScoreCache()

  /// Probabilities for `candidates`, in first-stage order, at or above `minimumScore`.
  func scores(query: String, candidates: [RetrievalCandidate]) async throws -> [UUID: Double] {
    let ids = candidates.map(\.id)
    let missing = Set(await cache.missing(from: ids))
    let pending = candidates.filter { missing.contains($0.id) }
    if !pending.isEmpty {
      let documents = pending.map { String($0.content.prefix(Self.documentCharacterLimit)) }
      if await cache.claimUsageRecord() { try await recordUsage(.now) }
      let question = String(query.prefix(Self.questionCharacterLimit))
      let model = modelIdentifier
      let client = client
      let result = try await withThrowingTaskGroup(of: [Double].self) { group in
        group.addTask {
          try await client.rerank(query: question, documents: documents, modelIdentifier: model)
        }
        group.addTask {
          try await Task.sleep(for: Self.timeout)
          throw ChatAttachmentFailure(message: "The reranker timed out.")
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
      }
      guard result.count == pending.count, result.allSatisfy(\.isFinite) else {
        throw ProviderClientError.invalidResponse
      }
      await cache.store(Dictionary(uniqueKeysWithValues: zip(pending.map(\.id), result)))
    }
    return await cache.scores(for: ids).filter { $0.value >= minimumScore }
  }
}

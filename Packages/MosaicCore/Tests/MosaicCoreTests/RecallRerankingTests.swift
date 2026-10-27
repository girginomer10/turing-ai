import Foundation
import SwiftData
import Testing

@testable import MosaicCore

struct RecallRerankingTests {
  // MARK: Wire format

  @Test func cohereUsesItsNativeRerankEndpointAndTheOthersShareTheCompatibleShape() throws {
    let cohere = try ProviderWireProtocol.rerankRequest(
      connection: connection(.cohere), modelIdentifier: "rerank-v3.5", query: "q",
      documents: ["a", "b"])
    #expect(cohere.url?.absoluteString == "https://api.cohere.ai/v2/rerank")
    #expect(cohere.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    let cohereBody = try json(cohere)
    #expect(cohereBody["top_n"] as? Int == 2)
    #expect(cohereBody["documents"] as? [String] == ["a", "b"])

    let jina = try ProviderWireProtocol.rerankRequest(
      connection: connection(.jinaAI), modelIdentifier: "jina-reranker-v2", query: "q",
      documents: ["a"])
    #expect(jina.url?.absoluteString == "https://api.jina.ai/v1/rerank")
    #expect(try json(jina)["return_documents"] as? Bool == false)

    let voyage = try ProviderWireProtocol.rerankRequest(
      connection: connection(.voyageAI), modelIdentifier: "rerank-2.5", query: "q",
      documents: ["a"])
    #expect(voyage.url?.absoluteString == "https://api.voyageai.com/v1/rerank")
    #expect(try json(voyage)["top_k"] as? Int == 1)
    #expect(try json(voyage)["top_n"] == nil)

    let local = try ProviderWireProtocol.rerankRequest(
      connection: connection(.llamaCpp, key: nil), modelIdentifier: "qwen3-reranker", query: "q",
      documents: ["a"])
    #expect(local.url?.absoluteString == "http://127.0.0.1:8080/v1/rerank")
    #expect(local.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test func deepInfraUsesItsNativeInferenceRouteAndFlatScores() throws {
    let request = try ProviderWireProtocol.rerankRequest(
      connection: connection(.deepInfra), modelIdentifier: "Qwen/Qwen3-Reranker-8B", query: "q",
      documents: ["a", "b"])
    #expect(
      request.url?.absoluteString
        == "https://api.deepinfra.com/v1/inference/Qwen/Qwen3-Reranker-8B")
    let body = try json(request)
    #expect(body["queries"] as? [String] == ["q", "q"])
    #expect(body["documents"] as? [String] == ["a", "b"])
    #expect(body["model"] == nil)
    let probabilities = Data(#"{"scores":[0.99,0.0001],"input_tokens":12}"#.utf8)
    #expect(
      try ProviderWireProtocol.decodeRerank(data: probabilities, expectedCount: 2) == [
        0.99, 0.0001,
      ])
    let logits = Data(#"{"scores":[-1.0,-4.0]}"#.utf8)
    let squashed = try ProviderWireProtocol.decodeRerank(data: logits, expectedCount: 2)
    #expect(squashed[0] > squashed[1] && squashed[0] < 0.5)
    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.decodeRerank(data: probabilities, expectedCount: 3)
    }
    #expect(throws: ProviderClientError.missingModelIdentifier) {
      try ProviderWireProtocol.rerankRequest(
        connection: connection(.deepInfra), modelIdentifier: "../x", query: "q", documents: ["a"])
    }
  }

  @Test func providersWithoutARerankEndpointAreRefusedAndInputsAreBounded() {
    #expect(throws: ProviderClientError.unsupportedOperation) {
      try ProviderWireProtocol.rerankRequest(
        connection: connection(.openAI), modelIdentifier: "m", query: "q", documents: ["a"])
    }
    #expect(throws: ProviderClientError.missingModelIdentifier) {
      try ProviderWireProtocol.rerankRequest(
        connection: connection(.cohere), modelIdentifier: " ", query: "q", documents: ["a"])
    }
    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.rerankRequest(
        connection: connection(.cohere), modelIdentifier: "m", query: "q",
        documents: Array(repeating: "a", count: ProviderWireProtocol.rerankMaximumDocuments + 1))
    }
    #expect(throws: ProviderClientError.missingAPIKey) {
      try ProviderWireProtocol.rerankRequest(
        connection: connection(.cohere, key: nil), modelIdentifier: "m", query: "q",
        documents: ["a"])
    }
  }

  @Test func decodesBothResponseShapesAndSquashesLogitsIntoProbabilities() throws {
    let results = Data(
      #"{"results":[{"index":1,"relevance_score":0.25},{"index":0,"relevance_score":0.9}]}"#.utf8)
    #expect(try ProviderWireProtocol.decodeRerank(data: results, expectedCount: 2) == [0.9, 0.25])
    let voyage = Data(#"{"data":[{"index":0,"relevance_score":0.5}]}"#.utf8)
    #expect(try ProviderWireProtocol.decodeRerank(data: voyage, expectedCount: 1) == [0.5])
    let logits = Data(
      #"{"results":[{"index":0,"relevance_score":4.0},{"index":1,"relevance_score":-6.0}]}"#.utf8)
    let squashed = try ProviderWireProtocol.decodeRerank(data: logits, expectedCount: 2)
    #expect(squashed[0] > 0.98 && squashed[1] < 0.01)
  }

  @Test func rejectsIncompleteDuplicateOrNonFiniteResults() {
    let missing = Data(#"{"results":[{"index":0,"relevance_score":0.5}]}"#.utf8)
    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.decodeRerank(data: missing, expectedCount: 2)
    }
    let duplicate = Data(
      #"{"results":[{"index":0,"relevance_score":0.5},{"index":0,"relevance_score":0.6}]}"#.utf8)
    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.decodeRerank(data: duplicate, expectedCount: 2)
    }
    let outOfRange = Data(#"{"results":[{"index":3,"relevance_score":0.5}]}"#.utf8)
    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.decodeRerank(data: outOfRange, expectedCount: 1)
    }
  }

  @Test func rerankDefaultsExistOnlyForProvidersThatServeRerankers() {
    #expect(ProviderKind.voyageAI.defaultRerankModelIdentifier == "rerank-2.5")
    #expect(ProviderKind.deepInfra.defaultRerankModelIdentifier == "Qwen/Qwen3-Reranker-8B")
    #expect(ProviderKind.openAI.defaultRerankModelIdentifier == nil)
    #expect(ProviderKind.deepInfra.supportsReranking && !ProviderKind.openAI.supportsReranking)
  }

  @Test func settingsAreOffByDefaultAndNeedAProviderAndModel() {
    #expect(!RecallRerankerSettings().isUsable)
    let suite = UserDefaults(suiteName: "RecallRerankerSettingsTests-\(UUID())")!
    #expect(!RecallRerankerSettings.load(from: suite).isEnabled)
    let provider = UUID()
    suite.set(true, forKey: RecallRerankerSettings.enabledKey)
    suite.set(provider.uuidString, forKey: RecallRerankerSettings.providerKey)
    suite.set(" qwen3-reranker ", forKey: RecallRerankerSettings.modelKey)
    suite.set(5.0, forKey: RecallRerankerSettings.minimumScoreKey)
    let loaded = RecallRerankerSettings.load(from: suite)
    #expect(loaded.isUsable)
    #expect(loaded.providerID == provider)
    #expect(loaded.modelIdentifier == "qwen3-reranker")
    #expect(loaded.minimumScore == 0.95)
  }

  // MARK: Stage

  @Test func theStageScoresOnlyNewCandidatesAndRecordsUsageOnce() async throws {
    let client = FakeRerankClient { text in text.contains("keep") ? 0.9 : 0.1 }
    let usage = UsageProbe()
    let stage = RecallRerankStage(
      client: client, providerName: "Fake", modelIdentifier: "m", minimumScore: 0.5,
      recordUsage: { _ in usage.count += 1 })
    let a = candidate("keep alpha")
    let b = candidate("drop beta")
    let first = try await stage.scores(query: "q", candidates: [a, b])
    #expect(first.keys.sorted { $0.uuidString < $1.uuidString } == [a.id])
    let c = candidate("keep gamma")
    let second = try await stage.scores(query: "q", candidates: [a, b, c])
    #expect(Set(second.keys) == [a.id, c.id])
    let calls = await client.calls
    #expect(calls.count == 2)
    #expect(calls[1] == ["keep gamma"])
    #expect(await MainActor.run { usage.count } == 1)
  }

  // MARK: Coordinator

  @MainActor
  @Test func theRerankerPicksWhatIsInjectedAndAFailureFallsBackToOrdinaryRanking() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let history = ConversationRecord(title: "Luna", modelIdentifier: "model")
    context.insert(history)
    let food = MessageRecord(
      conversationID: history.id, role: .user, content: "Luna eats chicken food every evening.")
    let sofa = MessageRecord(
      conversationID: history.id, role: .user,
      content: "Luna eats very little and sleeps on the sofa.")
    context.insert(food)
    context.insert(sofa)
    try context.save()
    let provider = connection(.llamaCpp, key: nil)
    let settings = RecallRerankerSettings(
      isEnabled: true, providerID: provider.id, modelIdentifier: "judge", minimumScore: 0.3)

    // The judge prefers the sofa message even though lexical matching prefers the food message.
    let judge = FakeRerankClient { text in text.contains("sofa") ? 0.95 : 0.05 }
    let usage = UsageProbe()
    let reranked = await SemanticMemoryCoordinator.retrieve(
      query: "Luna eats what", excluding: UUID(),
      sourceReader: SemanticRetrievalSourceReader(modelContainer: container),
      computeActor: SemanticRetrievalComputeActor(),
      makeVectorRepository: { VectorRepositoryNeverUsed() },
      rerankSettings: settings, rerankProvider: provider,
      rerankClientFactory: { _ in judge },
      rerankUsage: { _, _, model, _ in
        usage.count += 1
        usage.model = model
      })
    #expect(reranked.items.map(\.id) == [sofa.id])
    #expect(reranked.items.first?.relevance == 0.95)
    #expect(await judge.calls.count == 1)
    #expect(usage.count == 1 && usage.model == "judge")

    // Below the minimum score nothing is injected.
    let unsure = FakeRerankClient { _ in 0.4 }
    let strict = RecallRerankerSettings(
      isEnabled: true, providerID: provider.id, modelIdentifier: "judge", minimumScore: 0.5)
    let silent = await SemanticMemoryCoordinator.retrieve(
      query: "Luna eats what", excluding: UUID(),
      sourceReader: SemanticRetrievalSourceReader(modelContainer: container),
      computeActor: SemanticRetrievalComputeActor(),
      makeVectorRepository: { VectorRepositoryNeverUsed() },
      rerankSettings: strict, rerankProvider: provider,
      rerankClientFactory: { _ in unsure }, rerankUsage: { _, _, _, _ in })
    #expect(silent.items.isEmpty)

    // A failing reranker never blocks recall: ordinary ranking answers and a warning is attached.
    let broken = FakeRerankClient(failure: ProviderClientError.invalidResponse) { _ in 0 }
    let fallback = await SemanticMemoryCoordinator.retrieve(
      query: "Luna eats what", excluding: UUID(),
      sourceReader: SemanticRetrievalSourceReader(modelContainer: container),
      computeActor: SemanticRetrievalComputeActor(),
      makeVectorRepository: { VectorRepositoryNeverUsed() },
      rerankSettings: settings, rerankProvider: provider,
      rerankClientFactory: { _ in broken }, rerankUsage: { _, _, _, _ in })
    #expect(fallback.items.first?.id == food.id)
    #expect(fallback.warnings.contains { $0.contains("reranker was unavailable") })
  }

  // MARK: Helpers

  private func connection(_ provider: ProviderKind, key: String? = "secret") -> ProviderConnection {
    ProviderConnection(
      id: UUID(), displayName: provider.displayName, provider: provider,
      modelIdentifier: "model", apiKey: key)
  }

  private func candidate(_ text: String) -> RetrievalCandidate {
    RetrievalCandidate(
      id: UUID(), source: .conversationMessage, containerID: UUID(), title: "", content: text,
      createdAt: .now)
  }

  private func json(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
  }
}

@MainActor
private final class UsageProbe {
  var count = 0
  var model = ""
}

private actor FakeRerankClient: RerankProviderClient {
  private(set) var calls: [[String]] = []
  private let score: @Sendable (String) -> Double
  private let failure: (any Error)?

  init(failure: (any Error)? = nil, score: @escaping @Sendable (String) -> Double) {
    self.failure = failure
    self.score = score
  }

  func rerank(query _: String, documents: [String], modelIdentifier _: String) async throws
    -> [Double]
  {
    calls.append(documents)
    if let failure { throw failure }
    return documents.map(score)
  }
}

private actor VectorRepositoryNeverUsed: SemanticRetrievalVectorAccessing {
  func snapshots(
    profileID _: UUID, candidateIDs _: [UUID]
  ) async throws -> [SemanticStoredVectorSnapshot] { [] }

  func upsert(_: [SemanticVectorWrite]) async throws {}
}

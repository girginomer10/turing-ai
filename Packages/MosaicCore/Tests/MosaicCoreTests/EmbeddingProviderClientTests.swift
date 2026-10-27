import Foundation
import Testing

@testable import MosaicCore

@Suite
struct EmbeddingProviderClientTests {
  @Test
  func modelSpecificInputFormatsFollowTheModelCards() {
    func query(_ model: String) -> String {
      EmbeddingInputFormatter.query("hello", provider: .ollama, modelIdentifier: model)
    }
    func document(_ model: String) -> String {
      EmbeddingInputFormatter.document("hello", provider: .ollama, modelIdentifier: model)
    }
    #expect(query("embeddinggemma") == "task: search result | query: hello")
    #expect(document("embeddinggemma:300m") == "title: none | text: hello")
    #expect(query("snowflake-arctic-embed2") == "query: hello")
    #expect(document("snowflake-arctic-embed2") == "hello")
    #expect(query("intfloat/e5-large-v2") == "query: hello")
    #expect(document("intfloat/e5-large-v2") == "passage: hello")
    #expect(query("intfloat/multilingual-e5-large-instruct").hasPrefix("Instruct: "))
    #expect(document("intfloat/multilingual-e5-large-instruct") == "hello")
    // Unrelated names are untouched, including ones that merely contain "e5".
    #expect(query("some-site5-model") == "hello")
    #expect(query("bge-m3") == "hello")
    #expect(document("nomic-embed-text") == "search_document: hello")
  }

  @Test
  func formattedModelsGetADistinctVectorSpaceWhileOthersKeepTheirIdentity() {
    func space(_ model: String) -> String {
      EmbeddingInputFormatter.spaceIdentifier(
        connection: configured(.ollama), modelIdentifier: model)
    }
    let legacy = EmbeddingVectorCodec.fingerprint(
      for: [
        "embedding-format-v2", "ollama", configured(.ollama).resolvedBaseURL?.absoluteString ?? "",
        "bge-m3",
      ].joined(separator: "|"))
    #expect(space("bge-m3") == legacy)
    #expect(EmbeddingInputFormatter.formatRevision(modelIdentifier: "embeddinggemma") != nil)
    #expect(space("embeddinggemma") != space("embeddinggemma:300m"))
  }

  @Test
  func qwenOfficialEndpointUsesNativeRetrievalPurposeAndDecoder() throws {
    let connection = configured(.qwen)
    let queryRequest = try ProviderWireProtocol.embeddingRequest(
      connection: connection,
      modelIdentifier: "qwen3.7-text-embedding",
      inputs: ["first", "second"],
      purpose: .query
    )
    let queryBody = try jsonBody(queryRequest)
    let input = try #require(queryBody["input"] as? [String: Any])
    let parameters = try #require(queryBody["parameters"] as? [String: Any])

    #expect(
      queryRequest.url?.absoluteString
        == "https://dashscope-intl.aliyuncs.com/api/v1/services/embeddings/text-embedding/text-embedding"
    )
    #expect(input["texts"] as? [String] == ["first", "second"])
    #expect(parameters["text_type"] as? String == "query")
    #expect(parameters["output_type"] as? String == "dense")
    #expect((parameters["instruct"] as? String)?.isEmpty == false)

    let documentRequest = try ProviderWireProtocol.embeddingRequest(
      connection: connection,
      modelIdentifier: "qwen3.7-text-embedding",
      inputs: ["document"],
      purpose: .document
    )
    let documentParameters = try #require(
      try jsonBody(documentRequest)["parameters"] as? [String: Any]
    )
    #expect(documentParameters["text_type"] as? String == "document")
    #expect(documentParameters["instruct"] == nil)

    let response = Data(
      #"{"output":{"embeddings":[{"text_index":1,"embedding":[0.3,0.4]},{"text_index":0,"embedding":[0.1,0.2]}]}}"#
        .utf8
    )
    #expect(
      try ProviderWireProtocol.decodeEmbeddings(
        data: response,
        expectedCount: 2,
        provider: .qwen
      ) == [[0.1, 0.2], [0.3, 0.4]]
    )
  }

  @Test
  func qwenCustomProxyKeepsCompatibleEmbeddingProtocol() throws {
    let connection = ProviderConnection(
      id: UUID(),
      displayName: "Qwen proxy",
      provider: .qwen,
      baseURL: URL(string: "https://proxy.example/v1"),
      modelIdentifier: "qwen3.8-max",
      apiKey: "test-key"
    )
    let request = try ProviderWireProtocol.embeddingRequest(
      connection: connection,
      modelIdentifier: "text-embedding-v4",
      inputs: ["query"],
      purpose: .query
    )
    let body = try jsonBody(request)

    #expect(request.url?.absoluteString == "https://proxy.example/v1/embeddings")
    #expect(body["input"] as? [String] == ["query"])
    #expect(body["parameters"] == nil)
  }

  @Test
  func qwenFlashAvoidsUnsupportedAdvancedNativeParameters() throws {
    let request = try ProviderWireProtocol.embeddingRequest(
      connection: configured(.qwen),
      modelIdentifier: "qwen3.7-text-embedding-flash",
      inputs: ["query"],
      purpose: .query
    )
    let body = try jsonBody(request)
    let parameters = try #require(body["parameters"] as? [String: Any])

    #expect(parameters["text_type"] as? String == "query")
    #expect(parameters["instruct"] == nil)
    #expect(parameters["output_type"] == nil)
    #expect(
      EmbeddingBatchPolicy.maximumInputCount(
        provider: .qwen,
        modelIdentifier: "qwen3.7-text-embedding-flash"
      ) == 10
    )
  }

  @Test
  func cohereOfficialEndpointUsesNativeSearchPurposeAndDecoder() throws {
    let request = try ProviderWireProtocol.embeddingRequest(
      connection: configured(.cohere),
      modelIdentifier: "embed-v4.0",
      inputs: ["query", "context"],
      purpose: .query
    )
    let body = try jsonBody(request)

    #expect(request.url?.absoluteString == "https://api.cohere.ai/v2/embed")
    #expect(body["texts"] as? [String] == ["query", "context"])
    #expect(body["input_type"] as? String == "search_query")
    #expect(body["embedding_types"] as? [String] == ["float"])
    #expect(body["truncate"] as? String == "NONE")

    let response = Data(
      #"{"embeddings":{"float":[[0.1,0.2],[0.3,0.4]]}}"#.utf8
    )
    #expect(
      try ProviderWireProtocol.decodeEmbeddings(
        data: response,
        expectedCount: 2,
        provider: .cohere
      ) == [[0.1, 0.2], [0.3, 0.4]]
    )
  }

  @Test
  func geminiEmbeddingPurposeUsesTheProtocolSupportedMechanismForEachGeneration() throws {
    let connection = configured(.google)
    let legacyRequest = try ProviderWireProtocol.embeddingRequest(
      connection: connection,
      modelIdentifier: "gemini-embedding-001",
      inputs: ["query"],
      purpose: .query
    )
    let legacyRequests = try #require(try jsonBody(legacyRequest)["requests"] as? [[String: Any]])
    let legacyConfig = try #require(legacyRequests.first?["embedContentConfig"] as? [String: Any])
    #expect(legacyConfig["taskType"] as? String == "RETRIEVAL_QUERY")

    let embedding2Request = try ProviderWireProtocol.embeddingRequest(
      connection: connection,
      modelIdentifier: "gemini-embedding-2",
      inputs: ["task: search result | query: query"],
      purpose: .query
    )
    let embedding2Requests = try #require(
      try jsonBody(embedding2Request)["requests"] as? [[String: Any]]
    )
    #expect(embedding2Requests.first?["embedContentConfig"] == nil)
  }

  @Test
  func nvidiaOmitsInputTypeOnlyForGTEAndGTRModels() throws {
    for model in ["nvidia/gte-qwen2-7b-instruct", "sentence-transformers/gtr-t5-base"] {
      let request = try ProviderWireProtocol.embeddingRequest(
        connection: configured(.nvidiaNIM),
        modelIdentifier: model,
        inputs: ["query"],
        purpose: .query
      )
      let body = try jsonBody(request)
      #expect(body["input_type"] == nil)
      #expect(body["modality"] as? String == "text")
    }

    let nemotronRequest = try ProviderWireProtocol.embeddingRequest(
      connection: configured(.nvidiaNIM),
      modelIdentifier: "nvidia/nemotron-3-embed-1b",
      inputs: ["query"],
      purpose: .query
    )
    #expect(try jsonBody(nemotronRequest)["input_type"] as? String == "query")
  }

  @Test
  func qwenBatchLimitTracksTheSelectedModelFamily() {
    #expect(
      EmbeddingBatchPolicy.maximumInputCount(
        provider: .qwen,
        modelIdentifier: "qwen3.7-text-embedding"
      ) == 20
    )
    #expect(
      EmbeddingBatchPolicy.maximumInputCount(
        provider: .qwen,
        modelIdentifier: "text-embedding-v4"
      ) == 10
    )
  }

  @Test
  func splitBatchesRequireOneStableVectorDimension() throws {
    var accumulator = EmbeddingBatchAccumulator()
    try accumulator.append([[0.1, 0.2], [0.3, 0.4]], expectedCount: 2)

    #expect(throws: ProviderClientError.invalidResponse) {
      try accumulator.append([[0.5]], expectedCount: 1)
    }
  }

  @Test
  func outerQueryAndDocumentCallsShareOneVectorDimension() async throws {
    let guardActor = EmbeddingVectorSpaceDimensionGuard()
    _ = try await guardActor.validate([[0.1, 0.2]], modelIdentifier: "embed-model")
    _ = try await guardActor.validate(
      [[0.3, 0.4], [0.5, 0.6]],
      modelIdentifier: "embed-model"
    )

    await #expect(throws: ProviderClientError.invalidResponse) {
      try await guardActor.validate([[0.7]], modelIdentifier: "embed-model")
    }

    // One client can still be used deliberately with another exact model ID because that is a
    // distinct embedding space.
    _ = try await guardActor.validate([[0.8]], modelIdentifier: "other-model")
  }

  @Test
  func splitBatchesPreserveOrderAndExactCount() throws {
    var accumulator = EmbeddingBatchAccumulator()
    try accumulator.append([[0.1, 0.2]], expectedCount: 1)
    try accumulator.append([[0.3, 0.4], [0.5, 0.6]], expectedCount: 2)

    #expect(
      try accumulator.finalized(expectedCount: 3) == [
        [0.1, 0.2], [0.3, 0.4], [0.5, 0.6],
      ])
    #expect(throws: ProviderClientError.invalidResponse) {
      try accumulator.finalized(expectedCount: 4)
    }
  }

  @Test
  func batchRejectsEmptyVectorsAndCountMismatch() {
    var accumulator = EmbeddingBatchAccumulator()
    #expect(throws: ProviderClientError.invalidResponse) {
      try accumulator.append([[]], expectedCount: 1)
    }
    #expect(throws: ProviderClientError.invalidResponse) {
      try accumulator.append([[0.1]], expectedCount: 2)
    }
  }

  private func configured(_ provider: ProviderKind) -> ProviderConnection {
    ProviderConnection(
      id: UUID(),
      displayName: provider.displayName,
      provider: provider,
      modelIdentifier: provider.defaultModelIdentifier,
      apiKey: "test-key"
    )
  }

  private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}

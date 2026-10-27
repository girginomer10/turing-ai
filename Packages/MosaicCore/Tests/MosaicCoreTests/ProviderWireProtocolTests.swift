import Foundation
import Testing

@testable import MosaicCore

struct ProviderWireProtocolTests {
  @Test
  func openAIUsesResponsesAndDoesNotStoreServerSide() throws {
    let connection = ProviderConnection(
      id: UUID(),
      displayName: "OpenAI",
      provider: .openAI,
      modelIdentifier: "gpt-test",
      apiKey: "secret"
    )

    let request = try ProviderWireProtocol.streamingRequest(
      connection: connection,
      chatRequest: AIChatRequest(
        messages: [AIChatMessage(role: .user, content: "Hello")],
        systemPrompt: "Be concise"
      )
    )
    let bodyData = try #require(request.httpBody)
    let bodyObject = try JSONSerialization.jsonObject(with: bodyData)
    let body = try #require(bodyObject as? [String: Any])

    #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    #expect(request.timeoutInterval == ProviderNetworkTimeoutPolicy.streamingRequestIdle)
    #expect(body["store"] as? Bool == false)
    #expect(body["instructions"] as? String == "Be concise")
  }

  @Test
  func compatibleProviderUsesChatCompletions() throws {
    let connection = ProviderConnection(
      id: UUID(),
      displayName: "Local",
      provider: .custom,
      baseURL: URL(string: "http://192.168.1.8:1234/v1"),
      modelIdentifier: "local-model",
      apiKey: "optional"
    )

    let request = try ProviderWireProtocol.streamingRequest(
      connection: connection,
      chatRequest: AIChatRequest(messages: [AIChatMessage(role: .user, content: "Hi")])
    )
    let bodyData = try #require(request.httpBody)
    let bodyObject = try JSONSerialization.jsonObject(with: bodyData)
    let body = try #require(bodyObject as? [String: Any])

    #expect(request.url?.absoluteString == "http://192.168.1.8:1234/v1/chat/completions")
    #expect(body["max_tokens"] as? Int == 8_192)
  }

  @Test
  func deepInfraUsesOfficialChatAndCatalogEndpoints() throws {
    let connection = ProviderConnection(
      id: UUID(),
      displayName: "DeepInfra",
      provider: .deepInfra,
      modelIdentifier: "deepseek-ai/test",
      apiKey: "deep-secret"
    )

    let chat = try ProviderWireProtocol.streamingRequest(
      connection: connection,
      chatRequest: AIChatRequest(messages: [AIChatMessage(role: .user, content: "Hi")])
    )
    let catalog = try ProviderWireProtocol.modelsRequest(connection: connection)
    let bodyData = try #require(chat.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

    #expect(chat.url?.absoluteString == "https://api.deepinfra.com/v1/openai/chat/completions")
    #expect(catalog.url?.absoluteString == "https://api.deepinfra.com/v1/models")
    #expect(chat.value(forHTTPHeaderField: "Authorization") == "Bearer deep-secret")
    #expect(body["max_tokens"] as? Int == 8_192)
    #expect((body["stream_options"] as? [String: Bool])?["include_usage"] == true)
  }

  @Test
  func deepInfraCustomCatalogStaysUnderItsCredentialBoundBasePath() throws {
    let connection = ProviderConnection(
      id: UUID(),
      displayName: "DeepInfra proxy",
      provider: .deepInfra,
      baseURL: URL(string: "https://gateway.example/team/deepinfra/v1/openai/"),
      modelIdentifier: "chat-model",
      apiKey: "secret"
    )
    let fixture = Data(
      #"{"data":[{"id":"chat-a","metadata":{"tags":["text-generation","openai"]}},{"id":"embed-a","metadata":{"tags":["embeddings","openai"]}},{"id":"image-a","metadata":{"tags":["text-to-image"]}}]}"#
        .utf8
    )

    #expect(
      try ProviderWireProtocol.modelsRequest(connection: connection).url?.absoluteString
        == "https://gateway.example/team/deepinfra/v1/openai/models"
    )
    #expect(
      try ProviderWireProtocol.decodeModels(data: fixture, provider: .deepInfra) == ["chat-a"])
  }

  @Test
  func deepInfraCatalogPreservesPercentEncodedProxySegments() throws {
    let connection = ProviderConnection(
      id: UUID(),
      displayName: "DeepInfra encoded proxy",
      provider: .deepInfra,
      baseURL: URL(string: "https://gateway.example/team%2Fprivate/v1/openai"),
      modelIdentifier: "chat-model",
      apiKey: "secret"
    )

    let request = try ProviderWireProtocol.modelsRequest(connection: connection)

    #expect(
      request.url?.absoluteString
        == "https://gateway.example/team%2Fprivate/v1/openai/models"
    )
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
  }

  @Test
  func tinfoilUsesChatCompletionsAndFiltersNonChatModels() throws {
    let connection = ProviderConnection(
      id: UUID(),
      displayName: "Tinfoil",
      provider: .tinfoil,
      modelIdentifier: "gpt-oss-120b",
      apiKey: "tin-secret"
    )
    let request = try ProviderWireProtocol.streamingRequest(
      connection: connection,
      chatRequest: AIChatRequest(messages: [AIChatMessage(role: .user, content: "Hi")])
    )
    let fixture = Data(
      #"{"data":[{"id":"chat-a","type":"chat","endpoints":["/v1/chat/completions"]},{"id":"embed-a","type":"embedding","endpoints":["/v1/embeddings"]},{"id":"responses-only","type":"chat","endpoints":["/v1/responses"]}]}"#
        .utf8
    )

    #expect(request.url?.absoluteString == "https://inference.tinfoil.sh/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tin-secret")
    #expect(try ProviderWireProtocol.decodeModels(data: fixture, provider: .tinfoil) == ["chat-a"])
  }

  @Test
  func embeddingsUseOpenAIEnvelopeAndPreserveIndexOrder() throws {
    let connection = ProviderConnection(
      id: UUID(),
      displayName: "DeepInfra",
      provider: .deepInfra,
      modelIdentifier: "chat-model",
      apiKey: "secret"
    )
    let request = try ProviderWireProtocol.embeddingRequest(
      connection: connection,
      modelIdentifier: "Qwen/Qwen3-Embedding-8B",
      inputs: ["first", "second"],
      purpose: .document
    )
    let bodyData = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    let response = Data(
      #"{"data":[{"index":1,"embedding":[0.3,0.4]},{"index":0,"embedding":[0.1,0.2]}]}"#.utf8
    )

    #expect(request.url?.absoluteString == "https://api.deepinfra.com/v1/openai/embeddings")
    #expect(body["model"] as? String == "Qwen/Qwen3-Embedding-8B")
    #expect(body["encoding_format"] as? String == "float")
    #expect(
      try ProviderWireProtocol.decodeEmbeddings(
        data: response,
        expectedCount: 2,
        provider: .deepInfra
      ) == [
        [0.1, 0.2], [0.3, 0.4],
      ])
  }

  @Test
  func embeddingDecoderRejectsAmbiguousOrMissingIndices() {
    let duplicate = Data(
      #"{"data":[{"index":0,"embedding":[0.1]},{"index":0,"embedding":[0.2]}]}"#.utf8
    )
    let outOfRange = Data(
      #"{"data":[{"index":0,"embedding":[0.1]},{"index":2,"embedding":[0.2]}]}"#.utf8
    )
    let missingIndex = Data(
      #"{"data":[{"embedding":[0.1]}]}"#.utf8
    )

    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.decodeEmbeddings(
        data: duplicate,
        expectedCount: 2,
        provider: .deepInfra
      )
    }
    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.decodeEmbeddings(
        data: outOfRange,
        expectedCount: 2,
        provider: .deepInfra
      )
    }
    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.decodeEmbeddings(
        data: missingIndex,
        expectedCount: 1,
        provider: .deepInfra
      )
    }
  }

  @Test
  func embeddingDecoderRejectsJSONBooleansInsteadOfCoercingThemToNumbers() {
    let response = Data(
      #"{"data":[{"index":0,"embedding":[true,0.25]}]}"#.utf8
    )

    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.decodeEmbeddings(
        data: response,
        expectedCount: 1,
        provider: .deepInfra
      )
    }
  }

  @Test
  func modelCatalogRequiresItsDocumentedEnvelope() {
    let missingData = Data(#"{"object":"list"}"#.utf8)
    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.decodeModels(data: missingData, provider: .deepInfra)
    }
  }

  @Test
  func embeddingInputFormattingSeparatesQueryAndDocumentPurposes() {
    #expect(
      EmbeddingInputFormatter.query(
        "Luna ne yer?", provider: .google, modelIdentifier: "gemini-embedding-2"
      ) == "task: search result | query: Luna ne yer?"
    )
    #expect(
      EmbeddingInputFormatter.document(
        "Luna somon yer.", provider: .google, modelIdentifier: "gemini-embedding-2"
      ) == "title: none | text: Luna somon yer."
    )
    #expect(
      EmbeddingInputFormatter.query(
        "merhaba", provider: .tinfoil, modelIdentifier: "nomic-embed-text"
      ) == "search_query: merhaba"
    )
    #expect(
      EmbeddingInputFormatter.document(
        "belge", provider: .tinfoil, modelIdentifier: "nomic-embed-text"
      ) == "search_document: belge"
    )
    #expect(
      EmbeddingInputFormatter.query(
        "Luna ne yer?", provider: .deepInfra, modelIdentifier: "Qwen/Qwen3-Embedding-8B"
      ).contains("Instruct:")
    )
  }

  @Test
  func qwenEmbeddingBatchesRespectTheProviderLimitWithoutReordering() {
    let ten = (0..<10).map(String.init)
    let eleven = (0..<11).map(String.init)
    let thirtyTwo = (0..<32).map(String.init)

    #expect(
      EmbeddingBatchPolicy.batches(
        ten,
        provider: .qwen,
        modelIdentifier: "text-embedding-v4"
      ).map(\.count) == [10]
    )
    let elevenBatches = EmbeddingBatchPolicy.batches(
      eleven,
      provider: .qwen,
      modelIdentifier: "text-embedding-v4"
    )
    #expect(elevenBatches.map(\.count) == [10, 1])
    #expect(elevenBatches.flatMap { $0 } == eleven)

    let thirtyTwoBatches = EmbeddingBatchPolicy.batches(
      thirtyTwo,
      provider: .qwen,
      modelIdentifier: "text-embedding-v4"
    )
    #expect(thirtyTwoBatches.map(\.count) == [10, 10, 10, 2])
    #expect(thirtyTwoBatches.flatMap { $0 } == thirtyTwo)
  }

  @Test
  func deepInfraValidationDetailIsReadable() {
    let message = ProviderErrorSanitizer.bodyMessage(
      from: #"{"detail":[{"loc":["body","model"],"msg":"Field required","type":"missing"}]}"#,
      redacting: nil
    )
    #expect(message == "Field required")
  }

  @Test
  func remoteHTTPIsRejected() {
    let connection = ProviderConnection(
      id: UUID(),
      displayName: "Unsafe",
      provider: .custom,
      baseURL: URL(string: "http://example.com/v1"),
      modelIdentifier: "model",
      apiKey: "secret"
    )

    #expect(throws: ProviderClientError.insecureEndpoint) {
      try ProviderWireProtocol.streamingRequest(
        connection: connection,
        chatRequest: AIChatRequest(messages: [])
      )
    }
  }

  @Test(arguments: ["10.attacker.example", "192.168.attacker.example", "172.16.attacker.example"])
  func privatePrefixLookalikeHostsAreRejected(_ host: String) {
    let connection = ProviderConnection(
      id: UUID(),
      displayName: "Unsafe",
      provider: .custom,
      baseURL: URL(string: "http://\(host)/v1"),
      modelIdentifier: "model"
    )

    #expect(throws: ProviderClientError.insecureEndpoint) {
      try ProviderWireProtocol.streamingRequest(
        connection: connection,
        chatRequest: AIChatRequest(messages: [])
      )
    }
  }

  @Test
  func decodesResponsesDelta() throws {
    let event = ServerSentEvent(
      name: nil,
      data: #"{"type":"response.output_text.delta","delta":"Hello"}"#,
      id: nil
    )

    let decoded = try ProviderWireProtocol.decode(event: event, dialect: .openAIResponses)

    #expect(decoded == [.textDelta("Hello")])
  }

  @Test("OpenAI Responses refusal text remains visible")
  func decodesResponsesRefusalDelta() throws {
    let event = ServerSentEvent(
      name: nil,
      data: #"{"type":"response.refusal.delta","delta":"I can’t help with that."}"#,
      id: nil
    )

    let decoded = try ProviderWireProtocol.decode(event: event, dialect: .openAIResponses)

    #expect(decoded == [.textDelta("I can’t help with that.")])
  }

  @Test
  func miniMaxCumulativeStreamContentBecomesTrueDeltas() throws {
    var normalizer = ProviderStreamEventNormalizer(provider: .miniMax)

    #expect(try normalizer.normalize([.textDelta("Hel")]) == [.textDelta("Hel")])
    #expect(try normalizer.normalize([.textDelta("Hello")]) == [.textDelta("lo")])
    #expect(try normalizer.normalize([.textDelta("Hello")]) == [])
    #expect(
      try normalizer.normalize([
        .usage(TokenUsage(inputTokens: 2, outputTokens: 1)),
        .completed(responseID: "response-id"),
      ]) == [
        .usage(TokenUsage(inputTokens: 2, outputTokens: 1)),
        .completed(responseID: "response-id"),
      ])
  }

  @Test
  func miniMaxRejectsNonMonotonicCumulativeContent() throws {
    var normalizer = ProviderStreamEventNormalizer(provider: .miniMax)

    _ = try normalizer.normalize([.textDelta("Hello")])
    #expect(throws: ProviderClientError.invalidResponse) {
      try normalizer.normalize([.textDelta("Hi")])
    }
  }

  @Test
  func miniMaxCumulativeStreamSlicesAtUTF8Boundaries() throws {
    var normalizer = ProviderStreamEventNormalizer(provider: .miniMax)

    #expect(try normalizer.normalize([.textDelta("e")]) == [.textDelta("e")])
    #expect(try normalizer.normalize([.textDelta("e\u{301}")]) == [.textDelta("\u{301}")])
    #expect(
      try normalizer.normalize([.textDelta("e\u{301}🙂")]) == [.textDelta("🙂")]
    )
  }

  @Test
  func normalProvidersKeepTrueDeltasUntouched() throws {
    var normalizer = ProviderStreamEventNormalizer(provider: .openRouter)

    #expect(
      try normalizer.normalize([.textDelta("Hel"), .textDelta("lo")]) == [
        .textDelta("Hel"), .textDelta("lo"),
      ])
  }

  @Test
  func decodesAnthropicDelta() throws {
    let event = ServerSentEvent(
      name: "content_block_delta",
      data: #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#,
      id: nil
    )

    let decoded = try ProviderWireProtocol.decode(event: event, dialect: .anthropicMessages)

    #expect(decoded == [.textDelta("Hi")])
  }

  @Test
  func chatCompletionDoesNotTreatLengthLimitAsSuccess() {
    let event = ServerSentEvent(
      name: nil,
      data: #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#,
      id: nil
    )

    #expect(
      throws: ProviderClientError.provider(
        "The provider stopped before a normal completion (length)."
      )
    ) {
      try ProviderWireProtocol.decode(event: event, dialect: .openAIChatCompletions)
    }
  }

  @Test(arguments: ["stop", "normal"])
  func chatCompletionFinishReasonCompletesWithoutRequiringDoneMarker(_ finishReason: String) throws
  {
    let event = ServerSentEvent(
      name: nil,
      data:
        #"{"id":"chat-1","choices":[{"delta":{"content":"final"},"finish_reason":"\#(finishReason)"}],"usage":{"prompt_tokens":2,"completion_tokens":1}}"#,
      id: nil
    )

    #expect(
      try ProviderWireProtocol.decode(event: event, dialect: .openAIChatCompletions) == [
        .textDelta("final"),
        .usage(TokenUsage(inputTokens: 2, outputTokens: 1)),
        .completed(responseID: "chat-1"),
      ])
  }

  @Test
  func anthropicDoesNotTreatToolUseAsCompletedText() {
    let event = ServerSentEvent(
      name: nil,
      data:
        #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12}}"#,
      id: nil
    )

    #expect(
      throws: ProviderClientError.provider(
        "Anthropic stopped before a normal completion (tool_use)."
      )
    ) {
      try ProviderWireProtocol.decode(event: event, dialect: .anthropicMessages)
    }
  }

  @Test
  func geminiDoesNotTreatSafetyOrLengthStopsAsSuccess() {
    let blockedPrompt = ServerSentEvent(
      name: nil,
      data: #"{"promptFeedback":{"blockReason":"SAFETY"}}"#,
      id: nil
    )
    let truncatedCandidate = ServerSentEvent(
      name: nil,
      data:
        #"{"candidates":[{"content":{"parts":[{"text":"partial"}]},"finishReason":"MAX_TOKENS"}]}"#,
      id: nil
    )

    #expect(throws: ProviderClientError.provider("Gemini blocked the prompt (SAFETY).")) {
      try ProviderWireProtocol.decode(event: blockedPrompt, dialect: .gemini)
    }
    #expect(
      throws: ProviderClientError.provider(
        "Gemini stopped before a normal completion (MAX_TOKENS)."
      )
    ) {
      try ProviderWireProtocol.decode(event: truncatedCandidate, dialect: .gemini)
    }
  }

  @Test
  func providerErrorsAreRedactedBeforeDisplay() {
    let message = ProviderErrorSanitizer.bodyMessage(
      from: #"{"error":{"message":"Token sk-live-secret was rejected"}}"#,
      redacting: "sk-live-secret"
    )

    #expect(message == "Token •••• was rejected")
  }

  @Test
  func providerErrorsRedactPercentEncodedCredentialVariants() {
    let secret = "top secret+/="
    let message = ProviderErrorSanitizer.bodyMessage(
      from: "request failed at https://proxy.example?key=top%20secret%2B%2F%3D",
      redacting: secret
    )

    #expect(!message.contains(secret))
    #expect(!message.contains("top%20secret%2B%2F%3D"))
    #expect(message.contains("key=••••"))
  }

  @Test
  func providerHTMLIsNotShownAsAUserFacingError() {
    let message = ProviderErrorSanitizer.bodyMessage(
      from: "<html><body><script>internal details</script></body></html>",
      redacting: nil
    )

    #expect(message == "The provider returned an error response Turing AI could not read.")
    #expect(!message.contains("internal details"))
  }

  @Test
  func decodesOllamaFlatError() {
    let event = ServerSentEvent(
      name: nil,
      data: #"{"error":"model not found"}"#,
      id: nil
    )

    #expect(throws: ProviderClientError.provider("model not found")) {
      try ProviderWireProtocol.decode(event: event, dialect: .openAIChatCompletions)
    }
  }

  @Test
  func doneMarkerIsTerminal() throws {
    let event = ServerSentEvent(name: nil, data: "[DONE]", id: nil)

    #expect(
      try ProviderWireProtocol.decode(event: event, dialect: .openAIChatCompletions)
        == [.completed(responseID: nil)]
    )
  }

  @Test
  func ollamaHTTPErrorMessageIsReadable() {
    let message = ProviderErrorSanitizer.bodyMessage(
      from: #"{"error":"model not found"}"#,
      redacting: nil
    )

    #expect(message == "model not found")
  }
}

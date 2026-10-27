import Foundation
import Testing

@testable import MosaicCore

struct ProviderCatalogTests {
  @Test
  func catalogProfilesAreCompleteAndCapabilitySafe() {
    #expect(ProviderKind.allCases.count == 50)
    #expect(ProviderKind.allCases.filter(\.supportsChat).count == 48)

    for provider in ProviderKind.allCases {
      #expect(!provider.displayName.isEmpty)
      #expect(!provider.serviceSummary.isEmpty)
      #expect(!provider.logoAssetName.isEmpty)
      #expect(!provider.symbolName.isEmpty)

      if provider.category == .retrieval {
        #expect(provider.supportsEmbeddings)
        #expect(!provider.supportsChat)
      }
      if let defaultEmbeddingModel = provider.defaultEmbeddingModelIdentifier {
        #expect(provider.supportsEmbeddings)
        #expect(!defaultEmbeddingModel.isEmpty)
      }
      if provider.supportsLiveTranscription {
        #expect(provider == .google)
        #expect(provider.defaultLiveTranscriptionModelIdentifier == "gemini-3.5-transcribe-live")
      }
      if provider.requiresAPIKey, let url = provider.defaultBaseURL {
        #expect(url.scheme == "https")
      }
      if !provider.suggestedModelIdentifiers.isEmpty {
        #expect(provider.defaultModelIdentifier == provider.suggestedModelIdentifiers.first)
      }
    }
  }

  @Test
  func providerCategoriesPartitionEveryPresetExactlyOnce() {
    let grouped = ProviderCategory.allCases.flatMap(ProviderKind.cases(in:))

    #expect(grouped.count == ProviderKind.allCases.count)
    #expect(Set(grouped) == Set(ProviderKind.allCases))
  }

  @Test
  func onlyVerifiedLocalPresetReceivesAnEmbeddingDefault() {
    #expect(ProviderKind.ollama.defaultEmbeddingModelIdentifier == "embeddinggemma")
    #expect(ProviderKind.nvidiaNIM.defaultEmbeddingModelIdentifier == "nvidia/nemotron-3-embed-1b")

    for provider in [
      ProviderKind.lmStudio, .localAI, .vLLM, .sglang, .llamaCpp, .jan, .custom,
    ] {
      #expect(provider.supportsEmbeddings)
      #expect(provider.defaultEmbeddingModelIdentifier == nil)
    }
  }

  @Test
  func onlyTypeAwareLocalCatalogSupportsAutomaticDiscovery() throws {
    #expect(ProviderKind.lmStudio.supportsModelDiscovery)
    #expect(
      try ProviderWireProtocol.modelsRequest(connection: configured(.lmStudio)).url?.absoluteString
        == "http://127.0.0.1:1234/api/v1/models"
    )

    for provider in [
      ProviderKind.ollama, .localAI, .vLLM, .sglang, .llamaCpp, .jan, .custom,
    ] {
      #expect(provider.supportsChat)
      #expect(provider.supportsEmbeddings)
      #expect(!provider.supportsModelDiscovery)
      #expect(throws: ProviderClientError.modelCatalogUnavailable) {
        try ProviderWireProtocol.modelsRequest(connection: configured(provider))
      }
    }
  }

  @Test
  func lmStudioNativeCatalogRequiresPositiveLLMType() throws {
    let fixture = Data(
      #"{"models":[{"type":"llm","key":"chat-b"},{"type":"LLM","key":"chat-a"},{"type":"embedding","key":"embed-a"},{"key":"missing-type"},{"type":"llm","key":"   "}]}"#
        .utf8
    )

    #expect(
      try ProviderWireProtocol.decodeModels(data: fixture, provider: .lmStudio) == [
        "chat-a", "chat-b",
      ])

    for malformed in [
      #"{"data":[{"type":"llm","key":"wrong-envelope"}]}"#,
      #"{"models":"not-an-array"}"#,
    ] {
      #expect(throws: ProviderClientError.invalidResponse) {
        try ProviderWireProtocol.decodeModels(data: Data(malformed.utf8), provider: .lmStudio)
      }
    }
  }

  @Test
  func lmStudioCatalogDoesNotGuessNativeRouteFromCustomBasePath() {
    let connection = ProviderConnection(
      id: UUID(),
      displayName: "LM Studio proxy",
      provider: .lmStudio,
      baseURL: URL(string: "https://gateway.example/team/openai/v1"),
      modelIdentifier: "manual-model"
    )

    #expect(throws: ProviderClientError.modelCatalogUnavailable) {
      try ProviderWireProtocol.modelsRequest(connection: connection)
    }
  }

  @Test
  func currentCuratedSuggestionsPreferSupportedFlagships() {
    #expect(
      ProviderKind.meta.suggestedModelIdentifiers == ["muse-spark-1.2", "muse-spark-1.1"])
    #expect(
      Array(ProviderKind.deepSeek.suggestedModelIdentifiers.prefix(2)) == [
        "deepseek-v4-pro", "deepseek-v4-flash",
      ])
    #expect(
      Array(ProviderKind.kimi.suggestedModelIdentifiers.prefix(3)) == [
        "kimi-k3", "kimi-k2.7-code", "kimi-k2.6",
      ])
    #expect(
      Array(ProviderKind.miniMax.suggestedModelIdentifiers.prefix(2)) == [
        "MiniMax-M3", "MiniMax-M2.7",
      ])
    #expect(
      Array(ProviderKind.baseten.suggestedModelIdentifiers.prefix(2)) == [
        "zai-org/GLM-5.3", "deepseek-ai/DeepSeek-V4-Pro-0813",
      ])
    #expect(
      Array(ProviderKind.novitaAI.suggestedModelIdentifiers.prefix(2)) == [
        "zai-org/glm-5.3-flash", "deepseek/deepseek-v4-pro",
      ])
  }

  @Test
  func expandedInferencePresetsUseVerifiedOpenAICompatibleEndpoints() throws {
    let cases: [(ProviderKind, String, String?)] = [
      (.scaleway, "https://api.scaleway.ai/v1", "qwen3-embedding-8b"),
      (.digitalOcean, "https://inference.do-ai.run/v1", "qwen3-embedding-0.6b"),
      (.featherlessAI, "https://api.featherless.ai/v1", nil),
      (.chutes, "https://llm.chutes.ai/v1", nil),
      (.aimlAPI, "https://api.aimlapi.com/v1", "text-embedding-3-small"),
    ]

    for (provider, baseURL, embeddingModel) in cases {
      let connection = configured(provider)
      let chat = try ProviderWireProtocol.streamingRequest(
        connection: connection,
        chatRequest: AIChatRequest(messages: [AIChatMessage(role: .user, content: "Hello")])
      )

      #expect(chat.url?.absoluteString == "\(baseURL)/chat/completions")
      #expect(chat.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

      if let embeddingModel {
        let embedding = try ProviderWireProtocol.embeddingRequest(
          connection: connection,
          modelIdentifier: embeddingModel,
          inputs: ["semantic memory"],
          purpose: .document
        )
        #expect(provider.defaultEmbeddingModelIdentifier == embeddingModel)
        #expect(embedding.url?.absoluteString == "\(baseURL)/embeddings")
      }
    }

    #expect(ProviderKind.scaleway.supportsEmbeddings)
    #expect(
      Array(ProviderKind.scaleway.suggestedModelIdentifiers.prefix(2)) == [
        "deepseek-v4-flash-0731", "glm-5.2",
      ])
    #expect(
      Array(ProviderKind.chutes.suggestedModelIdentifiers.prefix(2)) == [
        "Qwen/Qwen3.5-397B-A17B-TEE", "zai-org/GLM-5.2-TEE",
      ])
    #expect(Array(ProviderKind.digitalOcean.suggestedModelIdentifiers.prefix(1)) == ["glm-5.3"])

    let chutesModels = try ProviderWireProtocol.modelsRequest(connection: configured(.chutes))
    #expect(chutesModels.url?.absoluteString == "https://llm.chutes.ai/v1/models")
  }

  @Test
  func mixedDigitalOceanCatalogFailsClosed() {
    #expect(ProviderKind.digitalOcean.supportsChat)
    #expect(ProviderKind.digitalOcean.supportsEmbeddings)
    #expect(!ProviderKind.digitalOcean.supportsModelDiscovery)
    #expect(throws: ProviderClientError.modelCatalogUnavailable) {
      try ProviderWireProtocol.modelsRequest(connection: configured(.digitalOcean))
    }
  }

  @Test
  func featherlessCatalogRequestsOnlyActiveChatCapableModels() throws {
    let connection = configured(.featherlessAI)
    let request = try ProviderWireProtocol.modelsRequest(connection: connection)
    let components = try #require(
      request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    )
    let nextRequest = try ProviderWireProtocol.modelsRequest(connection: connection, cursor: "2")
    let nextComponents = try #require(
      nextRequest.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    )
    let fixture = Data(
      #"{"data":[{"id":"model-b"},{"id":"model-a"}],"pagination":{"current_page":1,"per_page":1000,"total_items":2,"total_pages":2}}"#
        .utf8
    )
    let page = try ProviderWireProtocol.decodeModelPage(data: fixture, provider: .featherlessAI)

    #expect(components.scheme == "https")
    #expect(components.host == "api.featherless.ai")
    #expect(components.path == "/v1/models")
    #expect(
      components.queryItems == [
        URLQueryItem(name: "conversational", value: "true"),
        URLQueryItem(name: "available_on_current_plan", value: "true"),
        URLQueryItem(name: "page", value: "1"),
        URLQueryItem(name: "per_page", value: "1000"),
      ])
    #expect(
      nextComponents.queryItems == [
        URLQueryItem(name: "conversational", value: "true"),
        URLQueryItem(name: "available_on_current_plan", value: "true"),
        URLQueryItem(name: "page", value: "2"),
        URLQueryItem(name: "per_page", value: "1000"),
      ])
    #expect(
      page
        == ProviderModelCatalogPage(
          modelIdentifiers: ["model-a", "model-b"],
          nextCursor: "2"
        ))
    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.modelsRequest(connection: connection, cursor: "next")
    }
  }

  @Test
  func featherlessCatalogRequiresNumericPaginationMetadata() {
    let malformedFixtures = [
      #"{"data":[]}"#,
      #"{"data":[],"pagination":{"current_page":"1","total_pages":1}}"#,
      #"{"data":[],"pagination":{"current_page":0,"total_pages":1}}"#,
      #"{"data":[],"pagination":{"current_page":2,"total_pages":1}}"#,
    ]

    for fixture in malformedFixtures {
      #expect(throws: ProviderClientError.invalidResponse) {
        try ProviderWireProtocol.decodeModelPage(
          data: Data(fixture.utf8),
          provider: .featherlessAI
        )
      }
    }
  }

  @Test
  func chutesCatalogRequiresPositiveTextOutputModality() throws {
    let request = try ProviderWireProtocol.modelsRequest(connection: configured(.chutes))
    let fixture = Data(
      #"""
      {"data":[
        {"id":"text-a","output_modalities":["text"]},
        {"id":"text-b","output_modalities":["image","TEXT"]},
        {"id":"image-a","output_modalities":["image"]},
        {"id":"missing-modalities"},
        {"id":"malformed-modalities","output_modalities":"text"}
      ]}
      """#.utf8
    )

    #expect(request.url?.absoluteString == "https://llm.chutes.ai/v1/models")
    #expect(
      try ProviderWireProtocol.decodeModels(data: fixture, provider: .chutes) == [
        "text-a", "text-b",
      ])
  }

  @Test
  func openRouterCatalogRequestsAndVerifiesTextOutputModels() throws {
    let request = try ProviderWireProtocol.modelsRequest(connection: configured(.openRouter))
    let components = try #require(
      request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    )
    let fixture = Data(
      #"""
      {"data":[
        {"id":"text-a","architecture":{"output_modalities":["text"]}},
        {"id":"text-b","architecture":{"output_modalities":["image","TEXT"]}},
        {"id":"embedding-a","architecture":{"output_modalities":["embeddings"]}},
        {"id":"missing-architecture"},
        {"id":"malformed-modalities","architecture":{"output_modalities":"text"}}
      ]}
      """#.utf8
    )

    #expect(components.path == "/api/v1/models")
    #expect(components.queryItems == [URLQueryItem(name: "output_modalities", value: "text")])
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(
      try ProviderWireProtocol.decodeModels(data: fixture, provider: .openRouter) == [
        "text-a", "text-b",
      ])
  }

  @Test
  func huggingFaceCatalogRequiresDocumentedChatOutput() throws {
    let request = try ProviderWireProtocol.modelsRequest(connection: configured(.huggingFace))
    let fixture = Data(
      #"""
      {"data":[
        {"id":"chat-a","architecture":{"output_modalities":["text"]}},
        {"id":"image-a","architecture":{"output_modalities":["image"]}},
        {"id":"unknown-a"}
      ]}
      """#.utf8
    )

    #expect(request.url?.absoluteString == "https://router.huggingface.co/v1/models")
    #expect(
      try ProviderWireProtocol.decodeModels(data: fixture, provider: .huggingFace) == ["chat-a"])
  }

  @Test
  func aimlAPICatalogUsesPublicTypedChatListing() throws {
    let connection = ProviderConnection(
      id: UUID(),
      displayName: ProviderKind.aimlAPI.displayName,
      provider: .aimlAPI,
      modelIdentifier: "",
      apiKey: nil
    )
    let request = try ProviderWireProtocol.modelsRequest(connection: connection)
    let fixture = Data(
      #"""
      [
        {"id":"chat-a","type":"chat-completion","endpoints":["/v1/chat/completions"]},
        {"id":"chat-b","type":"CHAT-COMPLETION","endpoints":["https://api.aimlapi.com/v1/chat/completions"]},
        {"id":"embedding-a","type":"embedding","endpoints":["/v1/embeddings"]},
        {"id":"chat-wrong-route","type":"chat-completion","endpoints":["/v1/responses"]},
        {"id":"chat-missing-route","type":"chat-completion"}
      ]
      """#.utf8
    )

    #expect(request.url?.absoluteString == "https://api.aimlapi.com/models")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(
      try ProviderWireProtocol.decodeModels(data: fixture, provider: .aimlAPI) == [
        "chat-a", "chat-b",
      ])

    let customWithoutKey = ProviderConnection(
      id: UUID(),
      displayName: ProviderKind.aimlAPI.displayName,
      provider: .aimlAPI,
      baseURL: URL(string: "https://gateway.example/v1"),
      modelIdentifier: "",
      apiKey: nil
    )
    #expect(throws: ProviderClientError.missingAPIKey) {
      try ProviderWireProtocol.modelsRequest(connection: customWithoutKey)
    }

    let customRequest = try ProviderWireProtocol.modelsRequest(
      connection: configured(
        .aimlAPI,
        baseURL: URL(string: "https://gateway.example/v1")
      ))
    #expect(customRequest.url?.absoluteString == "https://gateway.example/v1/models")
    #expect(customRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
  }

  @Test
  func geminiCatalogRequiresExplicitGenerateContentSupport() throws {
    let fixture = Data(
      #"""
      {"models":[
        {"name":"models/gemini-chat","supportedGenerationMethods":["generateContent"]},
        {"name":"models/gemini-embed","supportedGenerationMethods":["embedContent"]},
        {"name":"models/gemini-missing"},
        {"name":"models/gemini-malformed","supportedGenerationMethods":"generateContent"},
        {"name":"models/gemini-mixed","supportedGenerationMethods":["generateContent",1]}
      ]}
      """#.utf8
    )

    #expect(
      try ProviderWireProtocol.decodeModels(data: fixture, provider: .google) == ["gemini-chat"])
  }

  @Test
  func microsoftFoundryUsesExactAPIKeyHeaderAndManualDeployment() throws {
    let connection = configured(
      .microsoftFoundry,
      modelIdentifier: "my-deployment",
      baseURL: URL(string: "https://example-resource.openai.azure.com/openai/v1")
    )
    let chat = try ProviderWireProtocol.streamingRequest(
      connection: connection,
      chatRequest: AIChatRequest(messages: [AIChatMessage(role: .user, content: "Hello")])
    )
    let embedding = try ProviderWireProtocol.embeddingRequest(
      connection: connection,
      modelIdentifier: "my-embedding-deployment",
      inputs: ["semantic memory"],
      purpose: .document
    )

    #expect(ProviderKind.microsoftFoundry.defaultBaseURL == nil)
    #expect(ProviderKind.microsoftFoundry.defaultModelIdentifier.isEmpty)
    #expect(
      chat.url?.absoluteString
        == "https://example-resource.openai.azure.com/openai/v1/chat/completions")
    #expect(
      embedding.url?.absoluteString
        == "https://example-resource.openai.azure.com/openai/v1/embeddings")
    #expect(chat.value(forHTTPHeaderField: "api-key") == "test-key")
    #expect(chat.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(embedding.value(forHTTPHeaderField: "api-key") == "test-key")
    #expect(embedding.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(throws: ProviderClientError.modelCatalogUnavailable) {
      try ProviderWireProtocol.modelsRequest(connection: connection)
    }
  }

  @Test
  func amazonBedrockUsesRegionalEndpointAndKeepsRuntimeCatalogFailClosed() throws {
    let connection = configured(
      .amazonBedrock,
      baseURL: URL(string: "https://bedrock-runtime.eu-central-1.amazonaws.com/openai/v1")
    )
    let chat = try ProviderWireProtocol.streamingRequest(
      connection: connection,
      chatRequest: AIChatRequest(messages: [AIChatMessage(role: .user, content: "Hello")])
    )
    #expect(ProviderKind.amazonBedrock.defaultBaseURL == nil)
    #expect(ProviderKind.amazonBedrock.defaultModelIdentifier == "openai.gpt-oss-120b")
    #expect(
      chat.url?.absoluteString
        == "https://bedrock-runtime.eu-central-1.amazonaws.com/openai/v1/chat/completions")
    #expect(chat.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(!ProviderKind.amazonBedrock.supportsEmbeddings)
    #expect(!ProviderKind.amazonBedrock.supportsModelDiscovery)
    #expect(throws: ProviderClientError.modelCatalogUnavailable) {
      try ProviderWireProtocol.modelsRequest(connection: connection)
    }
  }

  @Test
  func metaMuseSparkUsesOfficialCompatibleEndpoints() throws {
    let connection = configured(.meta)
    let chat = try ProviderWireProtocol.streamingRequest(
      connection: connection,
      chatRequest: AIChatRequest(messages: [AIChatMessage(role: .user, content: "Hello")])
    )

    #expect(chat.url?.absoluteString == "https://api.meta.ai/v1/chat/completions")
    #expect(chat.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(
      ProviderKind.meta.suggestedModelIdentifiers == ["muse-spark-1.2", "muse-spark-1.1"])
    #expect(!ProviderKind.meta.supportsModelDiscovery)
    #expect(throws: ProviderClientError.modelCatalogUnavailable) {
      try ProviderWireProtocol.modelsRequest(connection: connection)
    }
  }

  @Test
  func anthropicUsesOfficialCursorPagination() throws {
    let firstRequest = try ProviderWireProtocol.modelsRequest(connection: configured(.anthropic))
    let firstComponents = try #require(
      firstRequest.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    )
    let nextRequest = try ProviderWireProtocol.modelsRequest(
      connection: configured(.anthropic),
      cursor: "model_cursor+/="
    )
    let nextComponents = try #require(
      nextRequest.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    )
    let page = try ProviderWireProtocol.decodeModelPage(
      data: Data(
        #"{"data":[{"id":"claude-opus-5","type":"model"},{"id":"ignored","type":"not-a-model"}],"has_more":true,"last_id":"claude-opus-5"}"#
          .utf8
      ),
      provider: .anthropic
    )

    #expect(firstComponents.path == "/v1/models")
    #expect(firstComponents.queryItems == [URLQueryItem(name: "limit", value: "1000")])
    #expect(
      nextComponents.queryItems == [
        URLQueryItem(name: "limit", value: "1000"),
        URLQueryItem(name: "after_id", value: "model_cursor+/="),
      ])
    #expect(firstRequest.value(forHTTPHeaderField: "x-api-key") == "test-key")
    #expect(firstRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(
      page
        == ProviderModelCatalogPage(
          modelIdentifiers: ["claude-opus-5"],
          nextCursor: "claude-opus-5"
        ))
  }

  @Test
  func anthropicCatalogRejectsAmbiguousPaginationMetadata() {
    let missingHasMore = Data(
      #"{"data":[{"id":"claude-opus-5","type":"model"}],"last_id":"claude-opus-5"}"#.utf8
    )
    let missingLastID = Data(
      #"{"data":[{"id":"claude-opus-5","type":"model"}],"has_more":true,"last_id":null}"#.utf8
    )

    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.decodeModelPage(data: missingHasMore, provider: .anthropic)
    }
    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.decodeModelPage(data: missingLastID, provider: .anthropic)
    }
  }

  @Test
  func xAIUsesLanguageModelCatalogEnvelope() throws {
    let request = try ProviderWireProtocol.modelsRequest(connection: configured(.xAI))
    let fixture = Data(
      #"{"models":[{"id":"grok-4.6","output_modalities":["text"]},{"id":"grok-4.6-vision","input_modalities":["text","image"],"output_modalities":["text"]}]}"#
        .utf8
    )

    #expect(request.url?.absoluteString == "https://api.x.ai/v1/language-models")
    #expect(
      try ProviderWireProtocol.decodeModels(data: fixture, provider: .xAI) == [
        "grok-4.6", "grok-4.6-vision",
      ])
    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.decodeModels(
        data: Data(#"{"data":[{"id":"grok-imagine-image"}]}"#.utf8),
        provider: .xAI
      )
    }
  }

  @Test
  func mistralCatalogRequiresChatCompletionCapability() throws {
    let wrapped = Data(
      #"{"data":[{"id":"mistral-large-latest","capabilities":{"completion_chat":true}},{"id":"codestral-latest","capabilities":{"completion_chat":false,"completion_fim":true}},{"id":"mistral-embed","capabilities":{}},{"id":"unknown"}]}"#
        .utf8
    )
    let topLevel = Data(
      #"[{"id":"mistral-small-latest","capabilities":{"completion_chat":true}},{"id":"classifier","capabilities":{"completion_chat":"true"}}]"#
        .utf8
    )

    #expect(
      try ProviderWireProtocol.decodeModels(data: wrapped, provider: .mistral) == [
        "mistral-large-latest"
      ])
    #expect(
      try ProviderWireProtocol.decodeModels(data: topLevel, provider: .mistral) == [
        "mistral-small-latest"
      ])
  }

  @Test
  func expandedGatewayPresetsUseOfficialCompatibleEndpoints() throws {
    let cases: [(ProviderKind, String, String?)] = [
      (.vercelAI, "https://ai-gateway.vercel.sh/v1", "openai/text-embedding-3-small"),
      (.novitaAI, "https://api.novita.ai/openai/v1", "baai/bge-m3"),
      (
        .tencentTokenHub,
        "https://tokenhub-intl.tencentmaas.com/v1",
        "kinfra-text-embedding-0.6b"
      ),
      (.baiduQianfan, "https://qianfan.baidubce.com/v2", "embedding-v1"),
      (.poe, "https://api.poe.com/v1", nil),
    ]

    for (provider, baseURL, embeddingModel) in cases {
      let connection = configured(provider)
      let chat = try ProviderWireProtocol.streamingRequest(
        connection: connection,
        chatRequest: AIChatRequest(messages: [AIChatMessage(role: .user, content: "Hello")])
      )

      #expect(provider.supportsChat)
      #expect(chat.url?.absoluteString == "\(baseURL)/chat/completions")
      #expect(chat.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

      if provider.supportsModelDiscovery {
        let models = try ProviderWireProtocol.modelsRequest(connection: connection)
        #expect(models.url?.absoluteString == "\(baseURL)/models")
      } else {
        #expect(provider == .novitaAI)
        #expect(throws: ProviderClientError.modelCatalogUnavailable) {
          try ProviderWireProtocol.modelsRequest(connection: connection)
        }
      }

      if let embeddingModel {
        let embedding = try ProviderWireProtocol.embeddingRequest(
          connection: connection,
          modelIdentifier: embeddingModel,
          inputs: ["semantic memory"],
          purpose: .document
        )
        #expect(provider.supportsEmbeddings)
        #expect(provider.defaultEmbeddingModelIdentifier == embeddingModel)
        #expect(embedding.url?.absoluteString == "\(baseURL)/embeddings")
      } else {
        #expect(!provider.supportsEmbeddings)
        #expect(provider.defaultEmbeddingModelIdentifier == nil)
      }
    }
  }

  @Test
  func expandedGatewayCatalogsOnlyExposeTextChatModels() throws {
    let vercel = Data(
      #"""
      {"data":[
        {"id":"language-b","type":"language"},
        {"id":"embedding-a","type":"embedding"},
        {"id":"language-a","type":"LANGUAGE"}
      ]}
      """#.utf8
    )
    let tencent = Data(
      #"""
      {"data":[
        {"id":"hy3","object":"model","status":"online"},
        {"id":"deepseek-v4-flash","object":"model","status":"ONLINE"},
        {"id":"glm-5v-turbo","object":"model","status":"online"},
        {"id":"minimax-m2.7","object":"model","status":"online"},
        {"id":"youtu-vita","object":"model","status":"online"},
        {"id":"deepseek-v4-pro","object":"model","status":"offline"},
        {"id":"hy-image-v3","object":"model","status":"online"},
        {"id":"hy-video-v1.5","object":"model","status":"online"},
        {"id":"minimax-video-h3","object":"model","status":"online"},
        {"id":"minimax-music-2.0","object":"model","status":"online"},
        {"id":"hy-audio-v1","object":"model","status":"online"},
        {"id":"kinfra-text-embedding-0.6b","object":"model","status":"online"},
        {"id":"future-unknown-model","object":"model","status":"online"},
        {"id":"kimi-k3","object":"not-a-model","status":"online"}
      ]}
      """#.utf8
    )
    let baidu = Data(
      #"""
      {"data":[
        {"id":"ernie-5.0","type":"multimodal","architecture":{"input_modalities":["text","image","voice","video"],"output_modalities":["text"]}},
        {"id":"deepseek-v4-pro","type":"CHAT"},
        {"id":"qwen3-vl","type":"image2text","architecture":{"output_modalities":["text"]}},
        {"id":"ambiguous-multimodal","type":"multimodal"},
        {"id":"image-output-chat","type":"chat","architecture":{"output_modalities":["image"]}},
        {"id":"malformed-output-chat","type":"chat","architecture":{"output_modalities":"text"}},
        {"id":"malformed-architecture-chat","type":"chat","architecture":"text"},
        {"id":"qwen-image","type":"text2image","architecture":{"output_modalities":["image"]}},
        {"id":"video-generator","type":"text2video","architecture":{"output_modalities":["video"]}},
        {"id":"embedding-v1","type":"embeddings"},
        {"id":"bce-reranker-base","type":"rerank"}
      ]}
      """#.utf8
    )
    let poe = Data(
      #"""
      {"data":[
        {"id":"Claude-Sonnet-4.6","architecture":{"output_modalities":["text"]}},
        {"id":"GPT-5.4","architecture":{"output_modalities":["image","TEXT"]}},
        {"id":"Image-Bot","architecture":{"output_modalities":["image"]}},
        {"id":"Unknown-Bot"}
      ]}
      """#.utf8
    )

    #expect(
      try ProviderWireProtocol.decodeModels(data: vercel, provider: .vercelAI) == [
        "language-a", "language-b",
      ])
    #expect(
      try ProviderWireProtocol.decodeModels(data: tencent, provider: .tencentTokenHub) == [
        "deepseek-v4-flash", "glm-5v-turbo", "hy3", "minimax-m2.7", "youtu-vita",
      ])
    #expect(
      try ProviderWireProtocol.decodeModels(data: baidu, provider: .baiduQianfan) == [
        "deepseek-v4-pro", "ernie-5.0", "qwen3-vl",
      ])
    #expect(
      try ProviderWireProtocol.decodeModels(data: poe, provider: .poe) == [
        "Claude-Sonnet-4.6", "GPT-5.4",
      ])
  }

  @Test
  func baiduEmbeddingBatchPolicyHonorsDocumentedLimits() {
    #expect(
      EmbeddingBatchPolicy.maximumInputCount(
        provider: .baiduQianfan,
        modelIdentifier: "embedding-v1"
      ) == 16
    )
    #expect(
      EmbeddingBatchPolicy.maximumInputCount(
        provider: .baiduQianfan,
        modelIdentifier: " TAO-8K "
      ) == 1
    )
    #expect(
      EmbeddingBatchPolicy.batches(
        Array(repeating: "memory", count: 17),
        provider: .baiduQianfan,
        modelIdentifier: "embedding-v1"
      ).map(\.count) == [16, 1]
    )
  }

  @Test
  func miniMaxUsesCurrentModelAndCompletionTokenField() throws {
    let request = try ProviderWireProtocol.streamingRequest(
      connection: configured(.miniMax),
      chatRequest: AIChatRequest(
        messages: [AIChatMessage(role: .user, content: "Hello")],
        maxOutputTokens: 1_234
      )
    )
    let data = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(ProviderKind.miniMax.defaultModelIdentifier == "MiniMax-M3")
    #expect(body["max_completion_tokens"] as? Int == 1_234)
    #expect(body["max_tokens"] == nil)
  }

  @Test
  func kimiUsesTheDocumentedCompletionLimitFieldForK3Only() throws {
    let k3Request = try ProviderWireProtocol.streamingRequest(
      connection: configured(.kimi, modelIdentifier: "kimi-k3"),
      chatRequest: AIChatRequest(
        messages: [AIChatMessage(role: .user, content: "Hello")],
        maxOutputTokens: 1_234
      )
    )
    let k27Request = try ProviderWireProtocol.streamingRequest(
      connection: configured(.kimi, modelIdentifier: "kimi-k2.7-code"),
      chatRequest: AIChatRequest(
        messages: [AIChatMessage(role: .user, content: "Hello")],
        maxOutputTokens: 1_234
      )
    )
    let k3Data = try #require(k3Request.httpBody)
    let k27Data = try #require(k27Request.httpBody)
    let k3Body = try #require(try JSONSerialization.jsonObject(with: k3Data) as? [String: Any])
    let k27Body = try #require(
      try JSONSerialization.jsonObject(with: k27Data) as? [String: Any]
    )

    #expect(k3Body["max_completion_tokens"] as? Int == 1_234)
    #expect(k3Body["max_tokens"] == nil)
    #expect(k27Body["max_tokens"] as? Int == 1_234)
    #expect(k27Body["max_completion_tokens"] == nil)
  }

  @Test
  func googleUsesNativeBatchEmbeddingProtocol() throws {
    let request = try ProviderWireProtocol.embeddingRequest(
      connection: configured(.google),
      modelIdentifier: "models/gemini-embedding-2",
      inputs: ["first", "second"],
      purpose: .document
    )
    let data = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let requests = try #require(body["requests"] as? [[String: Any]])
    let firstContent = try #require(requests.first?["content"] as? [String: Any])
    let firstParts = try #require(firstContent["parts"] as? [[String: Any]])
    let response = Data(
      #"{"embeddings":[{"values":[0.1,0.2]},{"values":[0.3,0.4]}]}"#.utf8
    )

    #expect(ProviderKind.google.supportsEmbeddings)
    #expect(ProviderKind.google.defaultEmbeddingModelIdentifier == "gemini-embedding-2")
    #expect(
      request.url?.absoluteString
        == "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-2:batchEmbedContents"
    )
    #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(requests.count == 2)
    #expect(requests.first?["model"] as? String == "models/gemini-embedding-2")
    #expect(firstParts.first?["text"] as? String == "first")
    #expect(
      try ProviderWireProtocol.decodeEmbeddings(
        data: response,
        expectedCount: 2,
        provider: .google
      ) == [[0.1, 0.2], [0.3, 0.4]]
    )
  }

  @Test
  func googleEmbeddingDecoderRejectsDimensionMismatch() {
    let response = Data(
      #"{"embeddings":[{"values":[0.1,0.2]},{"values":[0.3]}]}"#.utf8
    )

    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.decodeEmbeddings(
        data: response,
        expectedCount: 2,
        provider: .google
      )
    }
  }

  @Test(
    arguments: [
      (ProviderKind.openRouter, "openai/text-embedding-3-small"),
      (.fireworksAI, "fireworks/qwen3-embedding-8b"),
    ]
  )
  func documentedCompatibleHostsExposeEmbeddings(
    provider: ProviderKind,
    expectedModel: String
  ) throws {
    let request = try ProviderWireProtocol.embeddingRequest(
      connection: configured(provider),
      modelIdentifier: expectedModel,
      inputs: ["semantic memory"],
      purpose: .query
    )

    #expect(provider.supportsEmbeddings)
    #expect(provider.defaultEmbeddingModelIdentifier == expectedModel)
    #expect(request.url?.path.hasSuffix("/v1/embeddings") == true)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    if provider == .fireworksAI {
      let data = try #require(request.httpBody)
      let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(body["encoding_format"] == nil)
    }
  }

  @Test(
    arguments: [
      (ProviderKind.deepSeek, "https://api.deepseek.com/v1/models"),
      (ProviderKind.kimi, "https://api.moonshot.ai/v1/models"),
      (.miniMax, "https://api.minimax.io/v1/models"),
      (.cerebras, "https://api.cerebras.ai/v1/models"),
    ]
  )
  func standardCatalogProvidersUseTheirBoundOrigin(
    provider: ProviderKind,
    expectedURL: String
  ) throws {
    let request = try ProviderWireProtocol.modelsRequest(connection: configured(provider))

    #expect(request.url?.absoluteString == expectedURL)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
  }

  @Test
  func togetherAcceptsDocumentedTopLevelModelArray() throws {
    let fixture = Data(
      #"[{"id":"openai/gpt-oss-120b","type":"chat"},{"id":"model-b","type":"chat"},{"id":"embed-a","type":"embedding"},{"id":"image-a","type":"image"}]"#
        .utf8
    )

    #expect(
      try ProviderWireProtocol.decodeModels(data: fixture, provider: .togetherAI) == [
        "model-b", "openai/gpt-oss-120b",
      ])
  }

  @Test
  func fireworksUsesServerlessManagementCatalogOnOfficialOrigin() throws {
    let request = try ProviderWireProtocol.modelsRequest(connection: configured(.fireworksAI))
    let components = try #require(
      request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    )
    let fixture = Data(
      #"{"models":[{"name":"accounts/fireworks/models/gpt-oss-120b","conversationConfig":{}},{"name":"accounts/fireworks/models/qwen3-embedding-8b"},{"name":"accounts/fireworks/models/image-a","conversationConfig":null}]}"#
        .utf8
    )

    #expect(components.scheme == "https")
    #expect(components.host == "api.fireworks.ai")
    #expect(components.path == "/v1/accounts/fireworks/models")
    #expect(
      components.queryItems == [
        URLQueryItem(name: "filter", value: "supports_serverless=true"),
        URLQueryItem(name: "pageSize", value: "200"),
      ])
    #expect(
      try ProviderWireProtocol.decodeModels(data: fixture, provider: .fireworksAI) == [
        "accounts/fireworks/models/gpt-oss-120b"
      ])
  }

  @Test
  func cohereUsesNativeChatCatalogWithoutChangingCredentialHost() throws {
    let request = try ProviderWireProtocol.modelsRequest(connection: configured(.cohere))
    let components = try #require(
      request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    )
    let fixture = Data(#"{"models":[{"name":"command-a-plus-05-2026"}]}"#.utf8)

    #expect(components.host == "api.cohere.ai")
    #expect(components.path == "/v1/models")
    #expect(
      components.queryItems == [
        URLQueryItem(name: "endpoint", value: "chat"),
        URLQueryItem(name: "page_size", value: "1000"),
      ])
    #expect(
      try ProviderWireProtocol.decodeModels(data: fixture, provider: .cohere) == [
        "command-a-plus-05-2026"
      ])
  }

  @Test
  func paginatedCatalogsPreserveFiltersAndUseDocumentedCursorNames() throws {
    let cases: [(ProviderKind, String, String, String)] = [
      (.anthropic, "limit", "after_id", "1000"),
      (.google, "pageSize", "pageToken", "1000"),
      (.cohere, "page_size", "page_token", "1000"),
      (.fireworksAI, "pageSize", "pageToken", "200"),
    ]

    for (provider, sizeName, tokenName, expectedSize) in cases {
      let request = try ProviderWireProtocol.modelsRequest(
        connection: configured(provider),
        cursor: "opaque+/cursor=="
      )
      let components = try #require(
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
      )
      let query = Dictionary(
        uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
          item.value.map { (item.name, $0) }
        }
      )

      #expect(query[sizeName] == expectedSize)
      #expect(query[tokenName] == "opaque+/cursor==")
      if provider == .cohere {
        #expect(query["endpoint"] == "chat")
      }
      if provider == .fireworksAI {
        #expect(query["filter"] == "supports_serverless=true")
      }
    }
  }

  @Test
  func modelPageDecodersExposeDocumentedNextCursor() throws {
    let anthropic = try ProviderWireProtocol.decodeModelPage(
      data: Data(
        #"{"data":[{"id":"claude-sonnet-5","type":"model"}],"has_more":true,"last_id":"anthropic-next"}"#
          .utf8
      ),
      provider: .anthropic
    )
    let gemini = try ProviderWireProtocol.decodeModelPage(
      data: Data(
        #"{"models":[{"name":"models/gemini-a","supportedGenerationMethods":["generateContent"]}],"nextPageToken":"gemini-next"}"#
          .utf8
      ),
      provider: .google
    )
    let cohere = try ProviderWireProtocol.decodeModelPage(
      data: Data(
        #"{"models":[{"name":"command-a"}],"next_page_token":"cohere-next"}"#.utf8
      ),
      provider: .cohere
    )
    let fireworks = try ProviderWireProtocol.decodeModelPage(
      data: Data(
        #"{"models":[],"nextPageToken":"fireworks-next"}"#.utf8
      ),
      provider: .fireworksAI
    )

    #expect(
      anthropic
        == ProviderModelCatalogPage(
          modelIdentifiers: ["claude-sonnet-5"],
          nextCursor: "anthropic-next"
        ))
    #expect(
      gemini
        == ProviderModelCatalogPage(
          modelIdentifiers: ["gemini-a"],
          nextCursor: "gemini-next"
        ))
    #expect(
      cohere
        == ProviderModelCatalogPage(
          modelIdentifiers: ["command-a"],
          nextCursor: "cohere-next"
        ))
    #expect(
      fireworks
        == ProviderModelCatalogPage(
          modelIdentifiers: [],
          nextCursor: "fireworks-next"
        ))
  }

  @Test
  func modelPageDecoderRejectsNonStringOrOversizedCursors() {
    let nonString = Data(#"{"models":[],"next_page_token":7}"#.utf8)
    let oversized = String(repeating: "x", count: 4_097)
    let oversizedPayload = Data(
      #"{"models":[],"nextPageToken":"\#(oversized)"}"#.utf8
    )

    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.decodeModelPage(data: nonString, provider: .cohere)
    }
    #expect(throws: ProviderClientError.responseTooLarge) {
      try ProviderWireProtocol.decodeModelPage(data: oversizedPayload, provider: .google)
    }
  }

  @Test
  func modelCatalogAccumulatorDeduplicatesPagesAndRejectsCursorCycles() throws {
    var accumulator = ProviderModelCatalogAccumulator(
      maximumPageCount: 3,
      maximumModelCount: 3
    )

    #expect(
      try accumulator.consume(
        ProviderModelCatalogPage(modelIdentifiers: ["model-b", "model-a"], nextCursor: "next")
      ) == "next"
    )
    #expect(
      try accumulator.consume(
        ProviderModelCatalogPage(modelIdentifiers: ["model-c", "model-a"], nextCursor: nil)
      ) == nil
    )
    #expect(accumulator.modelIdentifiers == ["model-a", "model-b", "model-c"])

    var cycling = ProviderModelCatalogAccumulator(
      maximumPageCount: 3,
      maximumModelCount: 3
    )
    _ = try cycling.consume(
      ProviderModelCatalogPage(modelIdentifiers: ["model-a"], nextCursor: "repeat")
    )
    #expect(throws: ProviderClientError.invalidResponse) {
      try cycling.consume(
        ProviderModelCatalogPage(modelIdentifiers: ["model-b"], nextCursor: "repeat")
      )
    }
  }

  @Test
  func modelCatalogAccumulatorFailsInsteadOfReturningPartialResultsAtLimits() throws {
    var tooManyPages = ProviderModelCatalogAccumulator(
      maximumPageCount: 1,
      maximumModelCount: 2
    )
    #expect(throws: ProviderClientError.responseTooLarge) {
      try tooManyPages.consume(
        ProviderModelCatalogPage(modelIdentifiers: ["model-a"], nextCursor: "more")
      )
    }

    var tooManyModels = ProviderModelCatalogAccumulator(
      maximumPageCount: 2,
      maximumModelCount: 1
    )
    #expect(throws: ProviderClientError.responseTooLarge) {
      try tooManyModels.consume(
        ProviderModelCatalogPage(modelIdentifiers: ["model-a", "model-b"], nextCursor: nil)
      )
    }
  }

  @Test
  func siliconFlowFiltersCatalogToChatModels() throws {
    let request = try ProviderWireProtocol.modelsRequest(connection: configured(.siliconFlow))
    let components = try #require(
      request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    )

    #expect(components.path == "/v1/models")
    #expect(components.queryItems == [URLQueryItem(name: "sub_type", value: "chat")])
  }

  @Test(
    arguments: [
      ProviderKind.openAI, .meta, .zAI, .ai21, .groq, .sambaNova, .nvidiaNIM, .nebius,
      .baseten, .hyperbolic, .scaleway, .digitalOcean, .perplexity, .microsoftFoundry,
      .amazonBedrock, .novitaAI, .voyageAI, .jinaAI,
    ]
  )
  func providersWithoutCompatibleCatalogFailExplicitly(_ provider: ProviderKind) {
    #expect(throws: ProviderClientError.modelCatalogUnavailable) {
      try ProviderWireProtocol.modelsRequest(connection: configured(provider))
    }
  }

  @Test(
    arguments: [
      (ProviderKind.openAI, true), (.meta, false), (.sambaNova, false), (.nvidiaNIM, true),
      (.nebius, false), (.baseten, false), (.novitaAI, true),
    ]
  )
  func mixedHostedCatalogsStayManualWithoutRemovingProviderCapabilities(
    provider: ProviderKind,
    supportsEmbeddings: Bool
  ) {
    #expect(provider.supportsChat)
    #expect(provider.supportsEmbeddings == supportsEmbeddings)
    #expect(!provider.supportsModelDiscovery)
  }

  @Test(arguments: [ProviderKind.voyageAI, .jinaAI])
  func retrievalOnlyProvidersCannotBeUsedForChat(_ provider: ProviderKind) {
    #expect(throws: ProviderClientError.chatUnavailable) {
      try ProviderWireProtocol.streamingRequest(
        connection: configured(provider),
        chatRequest: AIChatRequest(messages: [AIChatMessage(role: .user, content: "Hi")])
      )
    }
  }

  @Test(arguments: [ProviderKind.voyageAI, .jinaAI])
  func dedicatedEmbeddingProvidersUseLeanEmbeddingEnvelope(_ provider: ProviderKind) throws {
    let request = try ProviderWireProtocol.embeddingRequest(
      connection: configured(provider),
      modelIdentifier: try #require(provider.defaultEmbeddingModelIdentifier),
      inputs: ["first", "second"],
      purpose: .document
    )
    let data = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(request.url?.path.hasSuffix("/v1/embeddings") == true)
    #expect(body["input"] as? [String] == ["first", "second"])
    #expect(body["encoding_format"] == nil)
    if provider == .voyageAI {
      #expect(body["input_type"] as? String == "document")
    } else {
      #expect(body["task"] as? String == "retrieval.passage")
    }
  }

  @Test(
    arguments: [
      (ProviderKind.voyageAI, "input_type", "query"),
      (.jinaAI, "task", "retrieval.query"),
      (.nvidiaNIM, "input_type", "query"),
    ]
  )
  func embeddingRequestsPreserveQueryPurpose(
    provider: ProviderKind,
    field: String,
    expectedValue: String
  ) throws {
    let request = try ProviderWireProtocol.embeddingRequest(
      connection: configured(provider),
      modelIdentifier: try #require(provider.defaultEmbeddingModelIdentifier),
      inputs: ["Where did we discuss the launch?"],
      purpose: .query
    )
    let data = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(body[field] as? String == expectedValue)
  }

  private func configured(
    _ provider: ProviderKind,
    modelIdentifier: String? = nil,
    baseURL: URL? = nil
  ) -> ProviderConnection {
    ProviderConnection(
      id: UUID(),
      displayName: provider.displayName,
      provider: provider,
      baseURL: baseURL,
      modelIdentifier: modelIdentifier
        ?? (provider.defaultModelIdentifier.isEmpty
          ? (provider.defaultEmbeddingModelIdentifier ?? "test-model")
          : provider.defaultModelIdentifier),
      apiKey: "test-key"
    )
  }
}

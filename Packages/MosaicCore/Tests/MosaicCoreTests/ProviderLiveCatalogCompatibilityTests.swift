import Foundation
import Testing

@testable import MosaicCore

struct ProviderLiveCatalogCompatibilityTests {
  @Test func openRouterBatchRoutesDoNotAppearAsInteractiveChatModels() throws {
    let fixture = Data(
      #"{"data":[{"id":"anthropic/claude-sonnet-5","architecture":{"output_modalities":["text"]}},{"id":"anthropic/claude-sonnet-5:batch","architecture":{"output_modalities":["text"]}}]}"#
        .utf8)
    #expect(
      try ProviderWireProtocol.decodeModels(data: fixture, provider: .openRouter) == [
        "anthropic/claude-sonnet-5"
      ])
  }

  @Test
  func aimlCurrentRegistrySelectsTheChatEndpointInsteadOfPlaygroundTags() throws {
    // Structural fields verified against https://api.aimlapi.com/models on 2026-09-05.
    let fixture = Data(
      #"""
      {"object":"list","data":[
        {"id":"openai/gpt-6-astra","type":"openai/chat-completions","tags":["playground:chat"]},
        {"id":"openai/gpt-6-astra","type":"openai/responses/submit","tags":["playground:chat"]},
        {"id":"responses-only","type":"openai/responses/submit","tags":["playground:chat"]},
        {"id":"anthropic-only","type":"anthropic/messages","tags":["playground:chat"]},
        {"id":"embedding-model","type":"openai/embeddings"},
        {"id":"image-model","type":"openai/image-generations"},
        {"id":"unknown-model","tags":["playground:chat"]},
        {"id":" ","type":"openai/chat-completions"}
      ]}
      """#.utf8
    )

    #expect(
      try ProviderWireProtocol.decodeModels(data: fixture, provider: .aimlAPI)
        == ["openai/gpt-6-astra"])
  }

  @Test
  func aimlLegacyAndCurrentRecordsRemainCompatibleInEitherEnvelope() throws {
    let records: [[String: Any]] = [
      ["id": "current", "type": "openai/chat-completions"],
      ["id": "legacy-path", "type": "chat-completion", "endpoints": ["/v1/chat/completions"]],
      [
        "id": "legacy-url", "type": "CHAT-COMPLETION",
        "endpoints": ["https://api.aimlapi.com/v1/chat/completions"],
      ],
      ["id": "wrong-path", "type": "chat-completion", "endpoints": ["/v1/chat/completions-other"]],
      [
        "id": "wrong-query", "type": "chat-completion", "endpoints": ["/docs?/v1/chat/completions"],
      ],
      ["id": "wrong-route", "type": "chat-completion", "endpoints": ["/v1/responses"]],
      ["id": "no-route", "type": "chat-completion"],
    ]
    let envelopes: [Any] = [records, ["object": "list", "data": records]]
    for envelope in envelopes {
      #expect(
        try ProviderWireProtocol.decodeModels(
          data: JSONSerialization.data(withJSONObject: envelope), provider: .aimlAPI
        ) == ["current", "legacy-path", "legacy-url"])
    }
  }

  @Test(arguments: [#"{"object":"list"}"#, #"{"data":{}}"#, #"{"data":[1]}"#])
  func aimlMalformedRegistryDoesNotBecomeAnEmptySuccess(fixture: String) {
    #expect(throws: ProviderClientError.invalidResponse) {
      try ProviderWireProtocol.decodeModels(data: Data(fixture.utf8), provider: .aimlAPI)
    }
  }

  @Test
  func geminiGenerateContentDoesNotAdmitMediaOrSpecializedAgentModels() throws {
    let textModels = [
      "gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-2.5-pro-preview-03-25",
      "gemini-pro", "gemini-pro-vision", "gemini-exp-1206", "gemini-chat",
      "gemma-3-27b-it", "gemma-3n-e4b-it", "gemma-4-31b-it",
    ]
    let otherModels = [
      "gemini-3.1-flash-image-preview", "gemini-2.5-flash-preview-tts",
      "gemini-2.5-flash-native-audio-preview", "gemini-3.5-transcribe-live",
      "gemini-3.5-transcription-preview", "gemini-robotics-er-1.5-preview",
      "gemini-2.5-computer-use-preview-10-2025", "gemini-omni-1.1-flash",
      "gemini-deep-research-preview", "gemini-embedding-2",
      "imagen-4.0-generate-001", "veo-3.1-generate-preview", "lyria-realtime-exp",
      "nano-banana-pro-preview", "unknown-generate-content-model",
    ]
    var records: [[String: Any]] = (textModels + otherModels).map {
      ["name": "models/\($0)", "supportedGenerationMethods": ["generateContent", "countTokens"]]
    }
    records.append(["name": "gemini-pro", "supportedGenerationMethods": ["generateContent"]])
    records.append([
      "name": "models/gemini-no-content", "supportedGenerationMethods": ["countTokens"],
    ])
    let page = try ProviderWireProtocol.decodeModelPage(
      data: JSONSerialization.data(
        withJSONObject: ["models": records, "nextPageToken": "next-text-page"]
      ),
      provider: .google
    )

    #expect(page.modelIdentifiers == textModels.sorted())
    #expect(page.nextCursor == "next-text-page")
  }

  @Test
  func huggingFaceUsesLiveProvidersWhenTheRegistryAdvertisesAvailability() throws {
    let fixture = Data(
      #"""
      {"data":[
        {"id":"live-chat","architecture":{"output_modalities":["text"]},"providers":[{"status":"staging"},{"status":"live"}]},
        {"id":"legacy-chat","architecture":{"output_modalities":["text"]}},
        {"id":"offline-chat","architecture":{"output_modalities":["text"]},"providers":[{"status":"offline"}]},
        {"id":"empty-providers","architecture":{"output_modalities":["text"]},"providers":[]},
        {"id":"bad-providers","architecture":{"output_modalities":["text"]},"providers":"live"},
        {"id":"image-only","architecture":{"output_modalities":["image"]},"providers":[{"status":"live"}]}
      ]}
      """#.utf8
    )

    #expect(
      try ProviderWireProtocol.decodeModels(data: fixture, provider: .huggingFace)
        == ["legacy-chat", "live-chat"])
  }

  @Test
  func poeRespectsExplicitEndpointRestrictionsAndRetainsOlderPublicBots() throws {
    let fixture = Data(
      #"""
      {"data":[
        {"id":"chat-bot","architecture":{"output_modalities":["text"]},"supported_endpoints":["/v1/responses","/v1/chat/completions"]},
        {"id":"legacy-bot","architecture":{"output_modalities":["text"]}},
        {"id":"kimi-k3","architecture":{"output_modalities":["text"]},"supported_endpoints":[]},
        {"id":"responses-only","architecture":{"output_modalities":["text"]},"supported_endpoints":["/v1/responses"]},
        {"id":"bad-endpoints","architecture":{"output_modalities":["text"]},"supported_endpoints":"/v1/chat/completions"},
        {"id":"image-only","architecture":{"output_modalities":["image"]},"supported_endpoints":["/v1/chat/completions"]}
      ]}
      """#.utf8
    )

    #expect(
      try ProviderWireProtocol.decodeModels(data: fixture, provider: .poe)
        == ["chat-bot", "kimi-k3", "legacy-bot"])
  }

  @Test
  func vercelLanguageModelsMustAgreeWithExplicitOutputModalities() throws {
    let fixture = Data(
      #"""
      {"object":"list","data":[
        {"id":"text-model","type":"language","modalities":{"input":["text","image"],"output":["text"]}},
        {"id":"legacy-model","type":"language"},
        {"id":"contradictory-model","type":"language","modalities":{"output":["audio"]}},
        {"id":"bad-modalities","type":"language","modalities":{"output":"text"}},
        {"id":"image-model","type":"image","modalities":{"output":["image"]}},
        {"id":"embedding-model","type":"embedding"},
        {"id":"unknown-model","modalities":{"output":["text"]}}
      ]}
      """#.utf8
    )

    #expect(
      try ProviderWireProtocol.decodeModels(data: fixture, provider: .vercelAI)
        == ["legacy-model", "text-model"])
  }

  @Test
  func deepInfraAndTinfoilCurrentRegistriesPreserveChatCapabilityChecks() throws {
    let deepInfra = Data(
      #"""
      {"object":"list","data":[
        {"id":"deepseek-ai/DeepSeek-V4-Flash-0731","metadata":{"tags":["chat","prompt_cache","reasoning"]}},
        {"id":"Qwen/Qwen3-Embedding-8B","metadata":{"tags":["embed"]}},
        {"id":"image-model","metadata":{"tags":["image-gen"]}},
        {"id":"unknown-model","metadata":{}}
      ]}
      """#.utf8
    )
    let tinfoil = Data(
      #"""
      {"object":"list","data":[
        {"id":"kimi-k3","type":"chat","endpoints":["/v1/chat/completions","/v1/responses"]},
        {"id":"gpt-oss-safeguard-120b","type":"safety","endpoints":["/v1/chat/completions"]},
        {"id":"nomic-embed-text","type":"embedding","endpoints":["/v1/embeddings"]},
        {"id":"responses-only","type":"chat","endpoints":["/v1/responses"]}
      ]}
      """#.utf8
    )

    #expect(
      try ProviderWireProtocol.decodeModels(data: deepInfra, provider: .deepInfra)
        == ["deepseek-ai/DeepSeek-V4-Flash-0731"])
    #expect(try ProviderWireProtocol.decodeModels(data: tinfoil, provider: .tinfoil) == ["kimi-k3"])
  }
}

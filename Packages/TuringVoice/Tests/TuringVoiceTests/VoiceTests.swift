import Foundation
import Testing

@testable import TuringVoice

private func endpoint(
  _ provider: String = "openai", url: String? = nil, models: [String] = ["chat-model"]
) -> VoiceEndpoint {
  let defaults = [
    "openai": "https://api.openai.com/v1",
    "google": "https://generativelanguage.googleapis.com/v1beta",
    "anthropic": "https://api.anthropic.com/v1",
  ]
  return VoiceEndpoint(
    id: UUID(), provider: provider, name: provider,
    baseURL: URL(string: url ?? defaults[provider] ?? "https://example.com/v1")!,
    apiKey: "synthetic-only", models: models)
}
private func json(_ object: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: object)
}
private func object(_ data: Data) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func credentialSnapshotRoundTripAndDuplicateRejection() throws {
  let entry = endpoint()
  let config = VoiceConfiguration(endpoints: [entry], issuedAt: Date(timeIntervalSince1970: 123))
  let restored = try JSONDecoder().decode(
    VoiceConfiguration.self, from: JSONEncoder().encode(config)
  ).validated()
  #expect(restored.endpoints == [entry])
  #expect(restored.issuedAt == config.issuedAt)
  #expect(throws: VoiceError.self) {
    try VoiceConfiguration(endpoints: [entry, entry]).validated()
  }
}
@Test(arguments: [
  "http://api.openai.com/v1", "https://user:pass@api.openai.com/v1",
  "https://api.openai.com/v1?secret=x", "https://api.openai.com/v1#fragment",
])
func unsafeEndpointsRejected(_ url: String) {
  #expect(throws: VoiceError.self) { try endpoint(url: url).validate() }
}
@Test(arguments: [
  "https://api.openai.com.evil.example/v1", "https://api.openai.com:444/v1",
  "https://api.openai.com/proxy/v1",
])
func liveDoesNotMoveCredentialsToAnotherEndpoint(_ url: String) {
  #expect(endpoint(url: url).liveModels.isEmpty)
  #expect(throws: VoiceError.self) {
    try LiveVoiceWire.setup(endpoint: endpoint(url: url), model: "gpt-realtime-2.1")
  }
}
@Test(arguments: ["openai", "google", "anthropic", "groq"])
func routesChatAndAuthCorrectly(_ provider: String) throws {
  let request = try VoiceWire.request(
    endpoint: endpoint(provider), model: "chat-model", turns: [.init(role: "user", text: "Merhaba")]
  )
  let body = try object(#require(request.httpBody))
  #expect(request.httpMethod == "POST")
  switch provider {
  case "openai":
    #expect(request.url?.path == "/v1/responses")
    #expect(body["store"] as? Bool == false)
  case "google":
    #expect(request.url?.path == "/v1beta/models/chat-model:generateContent")
    #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "synthetic-only")
  case "anthropic":
    #expect(request.url?.path == "/v1/messages")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "synthetic-only")
  default:
    #expect(request.url?.path == "/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-only")
  }
}
@Test func disabledModelsAndOversizedHistoryRejected() {
  #expect(throws: VoiceError.self) {
    try VoiceWire.request(
      endpoint: endpoint(), model: "disabled", turns: [.init(role: "user", text: "hi")])
  }
  #expect(throws: VoiceError.self) {
    try VoiceWire.request(
      endpoint: endpoint(), model: "chat-model", turns: [.init(role: "system", text: "hi")])
  }
  #expect(throws: VoiceError.self) {
    try VoiceWire.request(
      endpoint: endpoint(), model: "chat-model",
      turns: [.init(role: "user", text: String(repeating: "x", count: 16_385))])
  }
  #expect(throws: VoiceError.self) {
    try VoiceWire.request(
      endpoint: endpoint("google", models: ["../escape"]), model: "../escape",
      turns: [.init(role: "user", text: "hi")])
  }
}
@Test func nativeLiveSetupsAndAudioFormats() throws {
  let openAI = try object(LiveVoiceWire.setup(endpoint: endpoint(), model: "gpt-realtime-2.1"))
  let session = try #require(openAI["session"] as? [String: Any])
  #expect(session["output_modalities"] as? [String] == ["audio"])
  let gemini = try object(
    LiveVoiceWire.setup(endpoint: endpoint("google"), model: "gemini-3.1-flash-live-preview"))
  let setup = try #require(gemini["setup"] as? [String: Any])
  #expect(
    (setup["generationConfig"] as? [String: Any])?["responseModalities"] as? [String] == ["AUDIO"])
  #expect(setup["inputAudioTranscription"] != nil)
  #expect(throws: VoiceError.self) { try LiveVoiceWire.audio(Data([1]), openAI: true) }
  #expect(throws: VoiceError.self) {
    try LiveVoiceWire.audio(Data(repeating: 0, count: 32_770), openAI: false)
  }
  let audio = try object(LiveVoiceWire.audio(Data([0, 0]), openAI: false))
  #expect(
    ((audio["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any])?["mimeType"] as? String
      == "audio/pcm;rate=24000")
}
@Test func liveEventsDecodeAudioInterruptionAndTranscripts() throws {
  #expect(try LiveVoiceWire.events(json(["type": "session.updated"]), openAI: true) == [.ready])
  #expect(
    try LiveVoiceWire.events(
      json(["type": "response.done", "response": ["status": "completed"]]), openAI: true
    ).contains(.turnFinished))
  #expect(
    try LiveVoiceWire.events(
      json(["type": "response.done", "response": ["status": "cancelled"]]), openAI: true
    ).contains(.turnFinished))
  #expect(
    try LiveVoiceWire.events(json(["type": "input_audio_buffer.speech_started"]), openAI: true) == [
      .userTurnStarted(itemID: nil), .interrupted,
    ])
  #expect(
    try LiveVoiceWire.events(
      json(["type": "response.output_audio.delta", "delta": "AAA=", "item_id": "item"]),
      openAI: true) == [.audio(Data([0, 0]), itemID: "item")])
  #expect(
    try LiveVoiceWire.events(
      json([
        "serverContent": [
          "interrupted": true, "inputTranscription": ["text": "Merhaba"], "turnComplete": true,
        ]
      ]), openAI: false) == [
        .interrupted, .transcript(role: "user", text: "Merhaba", append: true), .turnFinished,
      ])
}
@Test func malformedAudioAndProviderSecretsNotSurfaced() throws {
  #expect(throws: VoiceError.self) {
    try LiveVoiceWire.events(
      json(["type": "response.output_audio.delta", "delta": "AA=="]), openAI: true)
  }
  do {
    _ = try LiveVoiceWire.events(json(["error": ["message": "secret-api-key"]]), openAI: false)
    Issue.record("Expected sanitized provider error")
  } catch { #expect(!error.localizedDescription.contains("secret-api-key")) }
}
@Test func extractsVisibleTextOnly() throws {
  #expect(
    try VoiceWire.text(
      from: json([
        "candidates": [
          ["content": ["parts": [["text": "hidden", "thought": true], ["text": "visible"]]]]
        ]
      ]), provider: "google") == "visible")
  #expect(
    try VoiceWire.text(
      from: json(["output": [["content": [["type": "output_text", "text": "answer"]]]]]),
      provider: "openai") == "answer")
  #expect(throws: VoiceError.self) {
    try VoiceWire.text(from: json(["output": []]), provider: "openai")
  }
}

@Test func foundryUsesResourceAPIKeyAndGeminiAcceptsCatalogPrefix() throws {
  let foundry = try VoiceWire.request(
    endpoint: endpoint("microsoft_foundry"), model: "chat-model",
    turns: [.init(role: "user", text: "hi")])
  #expect(foundry.value(forHTTPHeaderField: "api-key") == "synthetic-only")
  #expect(foundry.value(forHTTPHeaderField: "Authorization") == nil)
  let gemini = try VoiceWire.request(
    endpoint: endpoint("google", models: ["models/gemini-flash"]), model: "models/gemini-flash",
    turns: [.init(role: "user", text: "hi")])
  #expect(gemini.url?.path == "/v1beta/models/gemini-flash:generateContent")
}
@Test func geminiRejectsUnexpectedAudioRates() throws {
  let wrong = try json([
    "serverContent": [
      "modelTurn": [
        "parts": [["inlineData": ["data": "AAA=", "mimeType": "audio/pcm;rate=16000"]]]
      ]
    ]
  ])
  #expect(throws: VoiceError.self) { try LiveVoiceWire.events(wrong, openAI: false) }
  let right = try json([
    "serverContent": [
      "modelTurn": [
        "parts": [["inlineData": ["data": "AAA=", "mimeType": "audio/pcm;rate=24000"]]]
      ]
    ]
  ])
  #expect(try LiveVoiceWire.events(right, openAI: false) == [.audio(Data([0, 0]), itemID: nil)])
}

@MainActor @Test func watchConnectivityReplyFromBackgroundQueueReachesMainActor() async {
  let expected = Data("synthetic-config".utf8)
  let result = await withCheckedContinuation { continuation in
    let delivery = VoiceCallbackDelivery { result in
      MainActor.assertIsolated()
      continuation.resume(returning: result)
    }
    // A legacy Objective-C framework invokes the callback on its own queue, outside Swift tasks.
    DispatchQueue.global().async { delivery.replyHandler(expected) }
  }
  switch result {
  case .success(let data): #expect(data == expected)
  case .failure: Issue.record("Reply unexpectedly failed")
  }
}

@MainActor @Test func watchConnectivityErrorFromBackgroundQueueIsSafeAndSanitized() async {
  let result = await withCheckedContinuation { continuation in
    let delivery = VoiceCallbackDelivery { result in
      MainActor.assertIsolated()
      continuation.resume(returning: result)
    }
    DispatchQueue.global().async {
      delivery.errorHandler(NSError(domain: "secret-provider-url", code: 1))
    }
  }
  switch result {
  case .success: Issue.record("Expected error")
  case .failure(let error): #expect(!error.localizedDescription.contains("secret-provider-url"))
  }
}

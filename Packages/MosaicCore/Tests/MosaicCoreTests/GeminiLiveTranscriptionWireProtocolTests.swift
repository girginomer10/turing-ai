import Foundation
import Testing

@testable import MosaicCore

struct GeminiLiveTranscriptionWireProtocolTests {
  @Test
  func requestUsesOnlyTheOfficialGeminiLiveDestination() throws {
    let apiKey = "secret+/=? value"
    let request = try GeminiLiveTranscriptionWireProtocol.webSocketRequest(apiKey: apiKey)
    let url = try #require(request.url)
    let components = try #require(
      URLComponents(url: url, resolvingAgainstBaseURL: false)
    )

    #expect(components.scheme == "wss")
    #expect(components.host == "generativelanguage.googleapis.com")
    #expect(
      components.path
        == "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    )
    #expect(components.queryItems == [URLQueryItem(name: "key", value: apiKey)])
    #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
  }

  @Test
  func requestRejectsMissingAndOversizedKeys() {
    #expect(throws: LiveTranscriptionError.missingAPIKey) {
      try GeminiLiveTranscriptionWireProtocol.webSocketRequest(apiKey: "  \n")
    }
    #expect(throws: LiveTranscriptionError.self) {
      try GeminiLiveTranscriptionWireProtocol.webSocketRequest(
        apiKey: String(repeating: "k", count: 4 * 1_024 + 1)
      )
    }
  }

  @Test
  func setupPinsTheTranscriptionModelAndTextModality() throws {
    let configuration = try LiveTranscriptionConfiguration(
      languageCodes: ["tr-TR", "en-US"],
      mode: .smart,
      customVocabulary: ["Mosaic", "Node101"]
    )
    let message = try GeminiLiveTranscriptionWireProtocol.setupMessage(
      configuration: configuration
    )
    let envelope = try jsonObject(message)
    let setup = try #require(envelope["setup"] as? [String: Any])
    let generationConfig = try #require(setup["generationConfig"] as? [String: Any])
    let transcription = try #require(
      setup["inputAudioTranscription"] as? [String: Any]
    )

    #expect(setup["model"] as? String == "models/gemini-3.5-transcribe-live")
    #expect(generationConfig["responseModalities"] as? [String] == ["TEXT"])
    #expect(transcription["languageCodes"] as? [String] == ["tr-TR", "en-US"])
    #expect(transcription["mode"] as? String == "SMART")
    #expect(transcription["customVocabulary"] as? [String] == ["Mosaic", "Node101"])
  }

  @Test
  func pcmChunkUsesTheDocumentedRealtimeFrame() throws {
    let bytes = Data([0x00, 0x80, 0xFF, 0x7F])
    let chunk = try LivePCM16AudioChunk(data: bytes)
    let message = try GeminiLiveTranscriptionWireProtocol.audioMessage(chunk: chunk)
    let envelope = try jsonObject(message)
    let realtimeInput = try #require(envelope["realtimeInput"] as? [String: Any])
    let audio = try #require(realtimeInput["audio"] as? [String: Any])

    #expect(chunk.frameCount == 2)
    #expect(audio["data"] as? String == bytes.base64EncodedString())
    #expect(audio["mimeType"] as? String == "audio/pcm;rate=16000")

    let endEnvelope = try jsonObject(
      GeminiLiveTranscriptionWireProtocol.audioStreamEndMessage()
    )
    let endInput = try #require(endEnvelope["realtimeInput"] as? [String: Any])
    #expect(endInput["audioStreamEnd"] as? Bool == true)
  }

  @Test
  func pcmChunkEnforcesCompleteBoundedFrames() throws {
    #expect(throws: LiveTranscriptionError.self) {
      try LivePCM16AudioChunk(data: Data())
    }
    #expect(throws: LiveTranscriptionError.self) {
      try LivePCM16AudioChunk(data: Data([0x00]))
    }
    #expect(throws: LiveTranscriptionError.self) {
      try LivePCM16AudioChunk(
        data: Data(repeating: 0, count: LivePCM16AudioChunk.maximumFrameCount * 2 + 2)
      )
    }

    let maximum = try LivePCM16AudioChunk(
      data: Data(repeating: 0, count: LivePCM16AudioChunk.maximumFrameCount * 2)
    )
    #expect(maximum.frameCount == LivePCM16AudioChunk.maximumFrameCount)
  }

  @Test
  func configurationAndDecodedConfigurationShareTheSameBounds() throws {
    let tooManyLanguages = Array(
      repeating: "tr-TR",
      count: LiveTranscriptionConfiguration.maximumLanguageCount + 1
    )
    #expect(throws: LiveTranscriptionError.self) {
      try LiveTranscriptionConfiguration(languageCodes: tooManyLanguages)
    }
    #expect(throws: LiveTranscriptionError.self) {
      try LiveTranscriptionConfiguration(languageCodes: ["tr_TR"])
    }

    let invalidJSON =
      #"{"languageCodes":["tr_TR"],"mode":"SMART","customVocabulary":[]}"#
    #expect(throws: LiveTranscriptionError.self) {
      try JSONDecoder().decode(
        LiveTranscriptionConfiguration.self,
        from: Data(invalidJSON.utf8)
      )
    }
  }

  @Test
  func decoderEmitsSetupInterimFinalTurnAndGoAwayEvents() throws {
    let setup = try GeminiLiveTranscriptionWireProtocol.decodeServerMessage(
      .data(Data(#"{"setupComplete":{}}"#.utf8)),
      redacting: nil
    )
    let content = try GeminiLiveTranscriptionWireProtocol.decodeServerMessage(
      .text(
        #"{"serverContent":{"interimInputTranscription":{"text":"Mer","languageCode":"tr-TR"},"inputTranscription":{"text":"Merhaba.","languageCode":"tr-TR"},"turnComplete":true}}"#
      ),
      redacting: nil
    )
    let goAway = try GeminiLiveTranscriptionWireProtocol.decodeServerMessage(
      .text(#"{"goAway":{"timeLeft":"12.5s"}}"#),
      redacting: nil
    )

    #expect(setup == [.setupComplete])
    #expect(
      content == [
        .interimTranscript(text: "Mer", languageCode: "tr-TR"),
        .finalTranscript(text: "Merhaba.", languageCode: "tr-TR"),
        .turnComplete,
      ]
    )
    #expect(goAway == [.goAway(timeLeftSeconds: 12.5)])
  }

  @Test
  func decoderRejectsOversizedMessagesAndTranscripts() {
    #expect(throws: LiveTranscriptionError.responseTooLarge) {
      try GeminiLiveTranscriptionWireProtocol.decodeServerMessage(
        .data(
          Data(
            repeating: 0x61,
            count: GeminiLiveTranscriptionWireProtocol.maximumInboundMessageBytes + 1
          )
        ),
        redacting: nil
      )
    }

    let oversizedText = String(
      repeating: "a",
      count: GeminiLiveTranscriptionWireProtocol.maximumTranscriptEventBytes + 1
    )
    let body = #"{"serverContent":{"inputTranscription":{"text":"\#(oversizedText)"}}}"#
    #expect(throws: LiveTranscriptionError.responseTooLarge) {
      try GeminiLiveTranscriptionWireProtocol.decodeServerMessage(
        .text(body),
        redacting: nil
      )
    }
  }

  @Test
  func providerAndTransportMessagesRedactKeysAndCredentialURLs() {
    let apiKey = "live secret+/="
    let encodedKey = "live%20secret%2B%2F%3D"
    let raw =
      "failed: wss://generativelanguage.googleapis.com/ws?key=\(encodedKey)&next=1 token \(apiKey)"
    let sanitized = LiveTranscriptionRedactor.sanitize(raw, redacting: apiKey)

    #expect(!sanitized.contains(apiKey))
    #expect(!sanitized.contains(encodedKey))
    #expect(sanitized.contains("key=••••"))
    #expect(
      LiveTranscriptionRedactor.sanitize(
        "transport exposed trimmed-key",
        redacting: "  trimmed-key  "
      ) == "transport exposed ••••"
    )

    do {
      _ = try GeminiLiveTranscriptionWireProtocol.decodeServerMessage(
        .text(#"{"error":{"code":401,"message":"bad key: live secret+/="}}"#),
        redacting: apiKey
      )
      Issue.record("Expected a provider error")
    } catch let error as LiveTranscriptionError {
      #expect(error == .provider("bad key: ••••"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func sharedNetworkDelegateRejectsRedirects() async throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let originalURL = try #require(URL(string: "https://example.com/socket"))
    let redirectedURL = try #require(URL(string: "https://attacker.example/socket"))
    let task = session.dataTask(with: originalURL)
    let response = try #require(
      HTTPURLResponse(
        url: originalURL,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: ["Location": redirectedURL.absoluteString]
      )
    )

    let acceptedRequest = await withCheckedContinuation { continuation in
      RejectRedirectDelegate.shared.urlSession(
        session,
        task: task,
        willPerformHTTPRedirection: response,
        newRequest: URLRequest(url: redirectedURL)
      ) { request in
        continuation.resume(returning: request)
      }
    }
    #expect(acceptedRequest == nil)
  }

  private func jsonObject(_ message: String) throws -> [String: Any] {
    try #require(
      JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
    )
  }
}

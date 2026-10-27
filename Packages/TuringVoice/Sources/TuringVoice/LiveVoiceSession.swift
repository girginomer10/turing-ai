import Foundation

public enum LiveVoiceEvent: Sendable, Equatable {
  case ready
  case audio(Data, itemID: String?)
  case transcript(role: String, text: String, append: Bool, itemID: String? = nil)
  case userTurnStarted(itemID: String?)
  case usage(VoiceTokenUsage, id: String?, transcription: Bool)
  case interrupted
  case turnFinished
}

public enum LiveVoiceWire {
  public static func setup(endpoint: VoiceEndpoint, model: String, context: String = "") throws
    -> Data
  {
    try endpoint.validate()
    guard endpoint.liveModels.contains(model) else { throw VoiceError.invalidConfiguration }
    guard context.utf8.count <= 8_000 else { throw VoiceError.invalidConfiguration }
    let instructions =
      "You are Turing AI on Apple Watch. Converse naturally in the user's language. Keep answers brief."
      + "\n" + context
    let object: [String: Any]
    if endpoint.isOpenAI {
      object = [
        "type": "session.update",
        "session": [
          "type": "realtime", "model": model,
          "instructions": instructions, "output_modalities": ["audio"],
          "audio": [
            "input": [
              "format": ["type": "audio/pcm", "rate": 24000],
              "transcription": ["model": "gpt-4o-mini-transcribe"],
              "turn_detection": [
                "type": "server_vad", "create_response": true, "interrupt_response": true,
              ],
            ],
            "output": ["format": ["type": "audio/pcm", "rate": 24000], "voice": "marin"],
          ],
        ],
      ]
    } else {
      object = [
        "setup": [
          "model": "models/\(model)",
          "generationConfig": ["responseModalities": ["AUDIO"]],
          "systemInstruction": ["parts": [["text": instructions]]],
          "inputAudioTranscription": [:], "outputAudioTranscription": [:],
        ]
      ]
    }
    return try JSONSerialization.data(withJSONObject: object)
  }
  public static func history(_ turns: [VoiceTurn], openAI: Bool) throws -> [Data] {
    guard turns.count <= 40,
      turns.allSatisfy({ ["user", "assistant"].contains($0.role) && $0.text.utf8.count <= 16_384 }),
      turns.reduce(0, { $0 + $1.text.utf8.count }) <= 60_000
    else { throw VoiceError.invalidConfiguration }
    if turns.isEmpty { return [] }
    if openAI {
      return try turns.map { turn in
        try JSONSerialization.data(withJSONObject: [
          "type": "conversation.item.create",
          "item": [
            "type": "message", "role": turn.role,
            "content": [
              ["type": turn.role == "user" ? "input_text" : "output_text", "text": turn.text]
            ],
          ],
        ])
      }
    }
    return [
      try JSONSerialization.data(withJSONObject: [
        "clientContent": [
          "turns": turns.map {
            ["role": $0.role == "assistant" ? "model" : "user", "parts": [["text": $0.text]]]
          }, "turnComplete": false,
        ]
      ])
    ]
  }
  public static func audio(_ data: Data, openAI: Bool) throws -> Data {
    guard !data.isEmpty, data.count <= 32_768, data.count.isMultiple(of: 2) else {
      throw VoiceError.invalidConfiguration
    }
    let object: [String: Any] =
      openAI
      ? ["type": "input_audio_buffer.append", "audio": data.base64EncodedString()]
      : [
        "realtimeInput": [
          "audio": ["mimeType": "audio/pcm;rate=24000", "data": data.base64EncodedString()]
        ]
      ]
    return try JSONSerialization.data(withJSONObject: object)
  }
  public static func events(_ data: Data, openAI: Bool) throws -> [LiveVoiceEvent] {
    guard data.count <= 2_097_152,
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw VoiceError.invalidResponse }
    // Provider payloads can echo keys/URLs. Use a fixed error, never surface raw server text.
    if json["error"] != nil {
      throw VoiceError.message(
        "Live model rejected the request. Check model access and your API balance on iPhone.")
    }
    if openAI {
      switch json["type"] as? String {
      case "session.updated": return [.ready]
      case "response.output_audio.delta":
        guard let value = json["delta"] as? String, let bytes = Data(base64Encoded: value),
          bytes.count.isMultiple(of: 2)
        else { throw VoiceError.invalidResponse }
        return [.audio(bytes, itemID: json["item_id"] as? String)]
      case "response.output_audio_transcript.delta":
        return [
          .transcript(
            role: "assistant", text: json["delta"] as? String ?? "", append: true,
            itemID: json["item_id"] as? String)
        ]
      case "conversation.item.input_audio_transcription.completed":
        var events: [LiveVoiceEvent] = [
          .transcript(
            role: "user", text: json["transcript"] as? String ?? "", append: false,
            itemID: json["item_id"] as? String)
        ]
        events.append(
          .usage(
            VoiceUsageWire.parse(json["usage"] as? [String: Any] ?? [:], provider: "openai"),
            id: json["item_id"] as? String, transcription: true))
        return events
      case "input_audio_buffer.speech_started":
        return [.userTurnStarted(itemID: json["item_id"] as? String), .interrupted]
      case "response.done":
        if let response = json["response"] as? [String: Any],
          response["status"] as? String == "failed"
        {
          throw VoiceError.message(
            "The live model could not complete its response. Check your provider account.")
        }
        let response = json["response"] as? [String: Any] ?? [:]
        return [
          .usage(
            VoiceUsageWire.parse(
              response["usage"] as? [String: Any] ?? [:], provider: "openai", live: true),
            id: response["id"] as? String, transcription: false), .turnFinished,
        ]
      default: return []
      }
    }
    if json["setupComplete"] != nil { return [.ready] }
    if json["goAway"] != nil {
      throw VoiceError.message("The live session reached its limit. Start a new conversation.")
    }
    var events: [LiveVoiceEvent] = []
    if let usage = json["usageMetadata"] as? [String: Any] {
      events.append(
        .usage(
          VoiceUsageWire.parse(usage, provider: "google", live: true), id: nil, transcription: false
        ))
    }
    guard let content = json["serverContent"] as? [String: Any] else { return events }
    if content["interrupted"] as? Bool == true { events.append(.interrupted) }
    if let turn = content["modelTurn"] as? [String: Any] {
      for part in turn["parts"] as? [[String: Any]] ?? [] {
        if let inline = part["inlineData"] as? [String: Any], let value = inline["data"] as? String,
          let mime = inline["mimeType"] as? String,
          ["audio/pcm;rate=24000", "audio/pcm; rate=24000"].contains(mime),
          let bytes = Data(base64Encoded: value), bytes.count.isMultiple(of: 2)
        {
          events.append(.audio(bytes, itemID: nil))
        } else if part["inlineData"] != nil {
          throw VoiceError.invalidResponse
        }
      }
    }
    for (key, role) in [("inputTranscription", "user"), ("outputTranscription", "assistant")] {
      if let value = content[key] as? [String: Any], let text = value["text"] as? String {
        events.append(.transcript(role: role, text: text, append: true))
      }
    }
    if content["turnComplete"] as? Bool == true { events.append(.turnFinished) }
    return events
  }
}

public actor LiveVoiceSession {
  private let endpoint: VoiceEndpoint
  private let model: String
  private let context: String
  private let history: [VoiceTurn]
  private var session: URLSession?
  private var socket: URLSessionWebSocketTask?
  private var reader: Task<Void, Never>?
  private var deadline: Task<Void, Never>?
  private var continuation: AsyncThrowingStream<LiveVoiceEvent, Error>.Continuation?
  private var ready = false
  public init(
    endpoint: VoiceEndpoint, model: String, history: [VoiceTurn] = [], context: String = ""
  ) {
    self.endpoint = endpoint
    self.model = model
    self.history = history
    self.context = context
  }
  public func start() throws -> AsyncThrowingStream<LiveVoiceEvent, Error> {
    guard socket == nil else { throw VoiceError.invalidConfiguration }
    let setup = try LiveVoiceWire.setup(endpoint: endpoint, model: model, context: context)
    var components = URLComponents()
    components.scheme = "wss"
    components.host = endpoint.isOpenAI ? "api.openai.com" : "generativelanguage.googleapis.com"
    components.path =
      endpoint.isOpenAI
      ? "/v1/realtime"
      : "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    components.queryItems =
      endpoint.isOpenAI
      ? [URLQueryItem(name: "model", value: model)]
      : [URLQueryItem(name: "key", value: endpoint.apiKey)]
    guard let url = components.url else { throw VoiceError.invalidConfiguration }
    var request = URLRequest(url: url)
    if endpoint.isOpenAI {
      request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.networkServiceType = .responsiveAV
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.urlCache = nil
    config.urlCredentialStorage = nil
    config.httpShouldSetCookies = false
    let session = URLSession(
      configuration: config, delegate: VoiceSessionDelegate(), delegateQueue: nil)
    self.session = session
    let socket = session.webSocketTask(with: request)
    socket.maximumMessageSize = 2_097_152
    self.socket = socket
    let pair = AsyncThrowingStream<LiveVoiceEvent, Error>.makeStream(
      bufferingPolicy: .bufferingOldest(80))
    continuation = pair.continuation
    pair.continuation.onTermination = { [weak self] _ in Task { await self?.stop() } }
    socket.resume()
    reader = Task { await receive(socket: socket, setup: setup) }
    deadline = Task {
      do {
        try await Task.sleep(for: .seconds(25))
        if !ready { stop(error: VoiceError.timeout) }
      } catch {}
    }
    return pair.stream
  }
  private func receive(socket: URLSessionWebSocketTask, setup: Data) async {
    do {
      try await socket.send(.string(String(decoding: setup, as: UTF8.self)))
      while !Task.isCancelled {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .data(let bytes): data = bytes
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw VoiceError.invalidResponse
        }
        for event in try LiveVoiceWire.events(data, openAI: endpoint.isOpenAI) {
          if event == .ready {
            for data in try LiveVoiceWire.history(history, openAI: endpoint.isOpenAI) {
              try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            }
            ready = true
            deadline?.cancel()
            deadline = nil
          }
          if case .dropped = continuation?.yield(event) { throw VoiceError.responseTooLarge }
        }
      }
    } catch {
      if !Task.isCancelled { stop(error: error is VoiceError ? error : VoiceError.disconnected) }
    }
  }
  public func sendAudio(_ data: Data) async throws {
    guard ready, let socket else { return }
    try await socket.send(
      .string(String(decoding: LiveVoiceWire.audio(data, openAI: endpoint.isOpenAI), as: UTF8.self))
    )
  }
  public func truncate(itemID: String, playedMilliseconds: Int) async throws {
    guard endpoint.isOpenAI, let socket else { return }
    let data = try JSONSerialization.data(withJSONObject: [
      "type": "conversation.item.truncate", "item_id": itemID,
      "content_index": 0, "audio_end_ms": max(0, playedMilliseconds),
    ])
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
  }
  public func stop(error: Error? = nil) {
    ready = false
    deadline?.cancel()
    deadline = nil
    reader?.cancel()
    reader = nil
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    session?.invalidateAndCancel()
    session = nil
    continuation?.finish(throwing: error)
    continuation = nil
  }
}

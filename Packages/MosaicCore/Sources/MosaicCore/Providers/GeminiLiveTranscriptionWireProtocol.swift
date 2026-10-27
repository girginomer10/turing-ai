import Foundation

enum GeminiLiveTranscriptionWireProtocol {
  static let modelIdentifier = "gemini-3.5-transcribe-live"
  static let qualifiedModelIdentifier = "models/\(modelIdentifier)"
  static let webSocketHost = "generativelanguage.googleapis.com"
  static let webSocketPath =
    "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
  static let maximumSessionDuration: Duration = .seconds(600)
  static let maximumInboundMessageBytes = 1 * 1_024 * 1_024
  static let maximumTranscriptEventBytes = 256 * 1_024
  static let maximumTotalTranscriptBytes = 4 * 1_024 * 1_024
  static let streamBufferLimit = 256

  private static let maximumAPIKeyBytes = 4 * 1_024
  private static let pcmMIMEType = "audio/pcm;rate=16000"

  static func webSocketRequest(apiKey rawAPIKey: String) throws -> URLRequest {
    let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !apiKey.isEmpty else { throw LiveTranscriptionError.missingAPIKey }
    guard apiKey.utf8.count <= maximumAPIKeyBytes else {
      throw LiveTranscriptionError.invalidConfiguration(
        "The Google API key exceeds Turing AI’s safety limit."
      )
    }

    var components = URLComponents()
    components.scheme = "wss"
    components.host = webSocketHost
    components.path = webSocketPath
    components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
    guard let url = components.url,
      url.scheme == "wss",
      url.host == webSocketHost,
      url.path == webSocketPath
    else {
      throw LiveTranscriptionError.invalidConfiguration(
        "Turing AI could not construct the fixed Gemini Live endpoint."
      )
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }

  static func setupMessage(configuration: LiveTranscriptionConfiguration) throws -> String {
    let transcription = InputAudioTranscription(
      languageCodes: configuration.languageCodes.isEmpty ? nil : configuration.languageCodes,
      mode: configuration.mode.rawValue,
      customVocabulary: configuration.customVocabulary.isEmpty
        ? nil : configuration.customVocabulary
    )
    return try encode(
      SetupEnvelope(
        setup: Setup(
          model: qualifiedModelIdentifier,
          generationConfig: GenerationConfig(responseModalities: ["TEXT"]),
          inputAudioTranscription: transcription
        )
      )
    )
  }

  static func audioMessage(chunk: LivePCM16AudioChunk) throws -> String {
    try encode(
      RealtimeInputEnvelope(
        realtimeInput: RealtimeInput(
          audio: AudioPayload(
            data: chunk.data.base64EncodedString(),
            mimeType: pcmMIMEType
          ),
          audioStreamEnd: nil
        )
      )
    )
  }

  static func audioStreamEndMessage() throws -> String {
    try encode(
      RealtimeInputEnvelope(
        realtimeInput: RealtimeInput(audio: nil, audioStreamEnd: true)
      )
    )
  }

  static func decodeServerMessage(
    _ message: LiveWebSocketMessage,
    redacting apiKey: String?
  ) throws -> [LiveTranscriptionEvent] {
    let data: Data
    switch message {
    case .text(let text):
      guard text.utf8.count <= maximumInboundMessageBytes else {
        throw LiveTranscriptionError.responseTooLarge
      }
      data = Data(text.utf8)
    case .data(let binary):
      guard binary.count <= maximumInboundMessageBytes else {
        throw LiveTranscriptionError.responseTooLarge
      }
      data = binary
    }

    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let envelope = object as? [String: Any]
    else {
      throw LiveTranscriptionError.invalidResponse
    }

    if let errorValue = envelope["error"] {
      guard let providerError = errorValue as? [String: Any] else {
        throw LiveTranscriptionError.invalidResponse
      }
      let message = providerErrorMessage(providerError)
      throw LiveTranscriptionError.provider(
        LiveTranscriptionRedactor.sanitize(message, redacting: apiKey)
      )
    }

    var events: [LiveTranscriptionEvent] = []
    if envelope["setupComplete"] != nil {
      guard envelope["setupComplete"] is [String: Any] else {
        throw LiveTranscriptionError.invalidResponse
      }
      events.append(.setupComplete)
    }

    if let serverContentValue = envelope["serverContent"] {
      guard let serverContent = serverContentValue as? [String: Any] else {
        throw LiveTranscriptionError.invalidResponse
      }
      if let interimValue = serverContent["interimInputTranscription"] {
        events.append(
          try transcriptEvent(
            interimValue,
            makeEvent: LiveTranscriptionEvent.interimTranscript
          )
        )
      }
      if let finalValue = serverContent["inputTranscription"] {
        events.append(
          try transcriptEvent(
            finalValue,
            makeEvent: LiveTranscriptionEvent.finalTranscript
          )
        )
      }
      if let turnComplete = serverContent["turnComplete"] {
        guard let turnComplete = turnComplete as? Bool else {
          throw LiveTranscriptionError.invalidResponse
        }
        if turnComplete { events.append(.turnComplete) }
      }
    }

    if let goAwayValue = envelope["goAway"] {
      guard let goAway = goAwayValue as? [String: Any] else {
        throw LiveTranscriptionError.invalidResponse
      }
      events.append(.goAway(timeLeftSeconds: try timeLeftSeconds(in: goAway)))
    }
    return events
  }

  private static func encode<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let encoded = try? encoder.encode(value),
      let message = String(data: encoded, encoding: .utf8)
    else {
      throw LiveTranscriptionError.invalidConfiguration(
        "Turing AI could not encode the Gemini Live request."
      )
    }
    return message
  }

  private static func transcriptEvent(
    _ rawValue: Any,
    makeEvent: (String, String?) -> LiveTranscriptionEvent
  ) throws -> LiveTranscriptionEvent {
    guard let transcript = rawValue as? [String: Any],
      let text = transcript["text"] as? String
    else {
      throw LiveTranscriptionError.invalidResponse
    }
    guard text.utf8.count <= maximumTranscriptEventBytes else {
      throw LiveTranscriptionError.responseTooLarge
    }

    let languageCode: String?
    if let rawLanguageCode = transcript["languageCode"] {
      guard let value = rawLanguageCode as? String, value.utf8.count <= 63 else {
        throw LiveTranscriptionError.invalidResponse
      }
      languageCode = value
    } else {
      languageCode = nil
    }
    return makeEvent(text, languageCode)
  }

  private static func timeLeftSeconds(in goAway: [String: Any]) throws -> Double? {
    guard let rawValue = goAway["timeLeft"] else { return nil }
    if let duration = rawValue as? String {
      guard duration.hasSuffix("s"),
        let seconds = Double(duration.dropLast()),
        seconds.isFinite,
        seconds >= 0
      else {
        throw LiveTranscriptionError.invalidResponse
      }
      return seconds
    }
    if let duration = rawValue as? [String: Any] {
      guard duration["seconds"] != nil || duration["nanos"] != nil else {
        throw LiveTranscriptionError.invalidResponse
      }
      let seconds = numericDouble(duration["seconds"]) ?? 0
      let nanos = numericDouble(duration["nanos"]) ?? 0
      guard seconds.isFinite, nanos.isFinite, seconds >= 0, nanos >= 0 else {
        throw LiveTranscriptionError.invalidResponse
      }
      return seconds + nanos / 1_000_000_000
    }
    throw LiveTranscriptionError.invalidResponse
  }

  private static func numericDouble(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
  }

  private static func providerErrorMessage(_ error: [String: Any]) -> String {
    if let message = error["message"] as? String, !message.isEmpty { return message }
    if let status = error["status"] as? String, !status.isEmpty { return status }
    if let code = error["code"] as? NSNumber {
      return "Gemini Live returned error \(code.intValue)."
    }
    return "Gemini Live returned an error response Turing AI could not read."
  }

  private struct SetupEnvelope: Encodable {
    let setup: Setup
  }

  private struct Setup: Encodable {
    let model: String
    let generationConfig: GenerationConfig
    let inputAudioTranscription: InputAudioTranscription
  }

  private struct GenerationConfig: Encodable {
    let responseModalities: [String]
  }

  private struct InputAudioTranscription: Encodable {
    let languageCodes: [String]?
    let mode: String
    let customVocabulary: [String]?
  }

  private struct RealtimeInputEnvelope: Encodable {
    let realtimeInput: RealtimeInput
  }

  private struct RealtimeInput: Encodable {
    let audio: AudioPayload?
    let audioStreamEnd: Bool?
  }

  private struct AudioPayload: Encodable {
    let data: String
    let mimeType: String
  }
}

enum LiveTranscriptionRedactor {
  private static let fallbackMessage =
    "Gemini Live returned an error response Turing AI could not read."
  private static let queryNames = ["key", "api_key", "apikey", "access_token"]

  static func sanitize(_ raw: String, redacting secret: String?) -> String {
    var value = raw
    if let secret, !secret.isEmpty {
      let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
      let encodedSecrets = [
        secret,
        trimmedSecret,
        secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
        secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
        trimmedSecret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
        trimmedSecret.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
      ].compactMap { $0 }
      for encodedSecret in Set(encodedSecrets) where !encodedSecret.isEmpty {
        value = value.replacingOccurrences(of: encodedSecret, with: "••••")
      }
    }
    for queryName in queryNames {
      value = redactQueryValue(named: queryName, in: value)
    }
    value = value.components(separatedBy: .controlCharacters).joined(separator: " ")
    value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if value.isEmpty { value = fallbackMessage }
    return String(value.prefix(2_000))
  }

  private static func redactQueryValue(named name: String, in input: String) -> String {
    var output = input
    var searchStart = output.startIndex
    while searchStart < output.endIndex,
      let nameRange = output.range(
        of: name,
        options: [.caseInsensitive],
        range: searchStart..<output.endIndex
      )
    {
      guard nameRange.lowerBound > output.startIndex else {
        searchStart = nameRange.upperBound
        continue
      }
      let markerIndex = output.index(before: nameRange.lowerBound)
      guard output[markerIndex] == "?" || output[markerIndex] == "&" else {
        searchStart = nameRange.upperBound
        continue
      }
      guard nameRange.upperBound < output.endIndex,
        output[nameRange.upperBound] == "="
      else {
        searchStart = nameRange.upperBound
        continue
      }

      let valueStart = output.index(after: nameRange.upperBound)
      let valueEnd =
        output[valueStart...].firstIndex(where: {
          $0 == "&" || $0 == "#" || $0 == "\"" || $0 == "'" || $0.isWhitespace
        }) ?? output.endIndex
      let resumeOffset = output.distance(from: output.startIndex, to: valueStart) + 4
      output.replaceSubrange(valueStart..<valueEnd, with: "••••")
      searchStart = output.index(
        output.startIndex,
        offsetBy: min(resumeOffset, output.count)
      )
    }
    return output
  }
}

import Foundation

final class VoiceSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

public enum VoiceWire {
  public static func request(
    endpoint: VoiceEndpoint, model: String, turns: [VoiceTurn], context: String = ""
  ) throws -> URLRequest {
    try endpoint.validate()
    guard endpoint.models.contains(model), !turns.isEmpty, turns.count <= 40,
      turns.allSatisfy({ ["user", "assistant"].contains($0.role) && $0.text.utf8.count <= 16_384 }),
      turns.reduce(0, { $0 + $1.text.utf8.count }) <= 65_536
    else { throw VoiceError.invalidConfiguration }
    guard context.utf8.count <= 8_000 else { throw VoiceError.invalidConfiguration }
    let instruction =
      "You are Turing AI on Apple Watch. Reply in the user's language. Keep spoken answers concise. Do not use markdown tables."
      + "\n" + context
    var request: URLRequest
    var body: [String: Any]
    switch endpoint.provider {
    case "openai":
      request = URLRequest(url: endpoint.baseURL.appendingPathComponent("responses"))
      body = [
        "model": model, "store": false, "max_output_tokens": 2048, "instructions": instruction,
        "input": turns.map { ["role": $0.role, "content": $0.text] },
      ]
    case "anthropic":
      request = URLRequest(url: endpoint.baseURL.appendingPathComponent("messages"))
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
      body = [
        "model": model, "max_tokens": 1024, "system": instruction,
        "messages": turns.map { ["role": $0.role, "content": $0.text] },
      ]
    case "google":
      let model = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
      guard !model.isEmpty,
        model.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
      else {
        throw VoiceError.invalidConfiguration
      }
      request = URLRequest(
        url: endpoint.baseURL.appendingPathComponent("models/\(model):generateContent"))
      body = [
        "systemInstruction": ["parts": [["text": instruction]]],
        "generationConfig": ["maxOutputTokens": 2048],
        "contents": turns.map {
          ["role": $0.role == "assistant" ? "model" : "user", "parts": [["text": $0.text]]]
        },
      ]
    default:
      request = URLRequest(url: endpoint.baseURL.appendingPathComponent("chat/completions"))
      body = [
        "model": model, "max_tokens": 1024,
        "messages": [["role": "system", "content": instruction]]
          + turns.map { ["role": $0.role, "content": $0.text] },
      ]
    }
    authenticate(&request, endpoint: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }
  static func authenticate(_ request: inout URLRequest, endpoint: VoiceEndpoint) {
    switch endpoint.provider {
    case "microsoft_foundry": request.setValue(endpoint.apiKey, forHTTPHeaderField: "api-key")
    case "google": request.setValue(endpoint.apiKey, forHTTPHeaderField: "x-goog-api-key")
    case "anthropic": request.setValue(endpoint.apiKey, forHTTPHeaderField: "x-api-key")
    default: request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
    }
  }
  public static func text(from data: Data, provider: String) throws -> String {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw VoiceError.invalidResponse
    }
    var result = ""
    switch provider {
    case "openai":
      for output in json["output"] as? [[String: Any]] ?? [] {
        for content in output["content"] as? [[String: Any]] ?? []
        where content["type"] as? String == "output_text" {
          result += content["text"] as? String ?? ""
        }
      }
    case "anthropic":
      result = (json["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        .joined()
    case "google":
      let candidates = json["candidates"] as? [[String: Any]] ?? []
      let content = candidates.first?["content"] as? [String: Any] ?? [:]
      result = (content["parts"] as? [[String: Any]] ?? []).filter {
        $0["thought"] as? Bool != true
      }.compactMap { $0["text"] as? String }.joined()
    default:
      let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
      result = message?["content"] as? String ?? ""
    }
    guard result.utf8.count <= 16_384 else { throw VoiceError.responseTooLarge }
    guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw VoiceError.invalidResponse
    }
    return result
  }
}

public actor VoiceHTTPClient {
  private let session: URLSession
  public init() {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 120
    config.urlCache = nil
    config.urlCredentialStorage = nil
    config.httpShouldSetCookies = false
    session = URLSession(
      configuration: config, delegate: VoiceSessionDelegate(), delegateQueue: nil)
  }
  private func data(for request: URLRequest, limit: Int = 2_097_152) async throws -> Data {
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw VoiceError.invalidResponse }
    guard (200..<300).contains(response.statusCode) else {
      throw VoiceError.provider(response.statusCode)
    }
    guard response.expectedContentLength <= limit else { throw VoiceError.responseTooLarge }
    var result = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard result.count < limit else { throw VoiceError.responseTooLarge }
      result.append(byte)
    }
    return result
  }
  public func answer(endpoint: VoiceEndpoint, model: String, turns: [VoiceTurn]) async throws
    -> String
  {
    let request = try VoiceWire.request(endpoint: endpoint, model: model, turns: turns)
    return try VoiceWire.text(from: await data(for: request), provider: endpoint.provider)
  }
  public func answerWithUsage(
    endpoint: VoiceEndpoint, model: String, turns: [VoiceTurn], context: String = ""
  ) async throws -> VoiceTextResult {
    let request = try VoiceWire.request(
      endpoint: endpoint, model: model, turns: turns, context: context)
    let data = try await data(for: request)
    return VoiceTextResult(
      text: try VoiceWire.text(from: data, provider: endpoint.provider),
      usage: try VoiceUsageWire.response(data, provider: endpoint.provider))
  }
  public func speech(text: String, endpoint: VoiceEndpoint) async throws -> Data {
    try await speechWithUsage(text: text, endpoint: endpoint).audio
  }
  public func speechWithUsage(text: String, endpoint: VoiceEndpoint) async throws
    -> VoiceSpeechResult
  {
    try endpoint.validate()
    guard endpoint.isOpenAI, !text.isEmpty, text.count <= 4096 else {
      throw VoiceError.invalidConfiguration
    }
    var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("audio/speech"))
    request.httpMethod = "POST"
    VoiceWire.authenticate(&request, endpoint: endpoint)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": "gpt-4o-mini-tts", "voice": "marin", "input": text, "response_format": "aac",
      "stream_format": "sse",
    ])
    return try VoiceUsageWire.speechEvents(await data(for: request, limit: 12_582_912))
  }
  public func transcribe(audio: Data, endpoint: VoiceEndpoint) async throws -> String {
    try await transcribeWithUsage(audio: audio, endpoint: endpoint).text
  }
  public func transcribeWithUsage(audio: Data, endpoint: VoiceEndpoint) async throws
    -> VoiceTextResult
  {
    try endpoint.validate()
    guard endpoint.isOpenAI, !audio.isEmpty, audio.count <= 8_388_608 else {
      throw VoiceError.invalidConfiguration
    }
    let boundary = "Turing-\(UUID().uuidString)"
    var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("audio/transcriptions"))
    request.httpMethod = "POST"
    VoiceWire.authenticate(&request, endpoint: endpoint)
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    var body = Data(
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n"
        .utf8)
    body.append(audio)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    request.httpBody = body
    let json = try JSONSerialization.jsonObject(with: await data(for: request)) as? [String: Any]
    guard let text = json?["text"] as? String,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw VoiceError.invalidResponse }
    return VoiceTextResult(
      text: text,
      usage: VoiceUsageWire.parse(json?["usage"] as? [String: Any] ?? [:], provider: "openai"))
  }
}

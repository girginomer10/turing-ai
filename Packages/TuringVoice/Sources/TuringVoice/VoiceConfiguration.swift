import Foundation

/// This entire snapshot contains credentials: persist only in Keychain and transfer only via an
/// interactive paired WatchConnectivity message. Never put it in applicationContext/userInfo/logs.
public struct VoiceConfiguration: Codable, Sendable {
  public let issuedAt: Date
  public let version: Int
  public let endpoints: [VoiceEndpoint]
  public init(endpoints: [VoiceEndpoint], issuedAt: Date = Date()) {
    self.version = 1
    self.endpoints = endpoints
    self.issuedAt = issuedAt
  }
  public func validated() throws -> Self {
    guard version == 1, endpoints.count <= 64,
      Set(endpoints.map(\.id)).count == endpoints.count
    else { throw VoiceError.invalidConfiguration }
    for endpoint in endpoints { try endpoint.validate() }
    return self
  }
}

public struct VoiceEndpoint: Codable, Identifiable, Hashable, Sendable {
  public let id: UUID
  public let provider: String
  public let name: String
  public let baseURL: URL
  public let apiKey: String
  public let models: [String]
  public let enabledLiveModels: [String]?
  public init(
    id: UUID, provider: String, name: String, baseURL: URL, apiKey: String, models: [String],
    enabledLiveModels: [String]? = nil
  ) {
    self.id = id
    self.provider = provider
    self.name = name
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.models = models
    self.enabledLiveModels = enabledLiveModels
  }
  public var isOpenAI: Bool {
    provider == "openai" && baseURL.host?.lowercased() == "api.openai.com"
      && baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "v1"
      && (baseURL.port == nil || baseURL.port == 443)
  }
  public var isGemini: Bool {
    provider == "google" && baseURL.host?.lowercased() == "generativelanguage.googleapis.com"
      && baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "v1beta"
      && (baseURL.port == nil || baseURL.port == 443)
  }
  public var liveModels: [String] {
    supportedLiveModels.filter { enabledLiveModels?.contains($0) ?? true }
  }
  public var supportedLiveModels: [String] {
    if isOpenAI { return ["gpt-realtime-2.1", "gpt-realtime-2.1-mini"] }
    if isGemini { return ["gemini-3.1-flash-live-preview"] }
    return []
  }
  public func validate() throws {
    guard baseURL.scheme?.lowercased() == "https", baseURL.host?.isEmpty == false,
      baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
      !apiKey.isEmpty, apiKey.utf8.count <= 16_384, !apiKey.contains("\r"), !apiKey.contains("\n"),
      !name.isEmpty, name.utf8.count <= 512, provider.utf8.count <= 128,
      models.count <= 512, models.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
      Set(models).count == models.count, (enabledLiveModels?.count ?? 0) <= 16,
      enabledLiveModels?.allSatisfy({ supportedLiveModels.contains($0) }) ?? true
    else { throw VoiceError.invalidConfiguration }
  }
}

public struct VoiceTurn: Codable, Identifiable, Sendable, Equatable {
  public let id: UUID
  public let role: String
  public let text: String
  public init(id: UUID = UUID(), role: String, text: String) {
    self.id = id
    self.role = role
    self.text = text
  }
}

public enum VoiceError: LocalizedError, Sendable {
  case invalidConfiguration, invalidResponse, responseTooLarge, disconnected, timeout,
    audioUnavailable
  case provider(Int)
  case message(String)
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "Sync valid HTTPS providers from Turing AI on your iPhone."
    case .invalidResponse: "The provider returned an unsupported response."
    case .responseTooLarge: "The response exceeded the Watch limit. Try a shorter question."
    case .disconnected: "The voice connection ended. Start again when you have internet access."
    case .timeout: "The provider did not respond in time. Please try again."
    case .audioUnavailable:
      "Microphone or audio output is unavailable. Check permissions and audio routing."
    case .provider(let status):
      "Provider request failed (HTTP \(status)). Check your key, model access and balance on iPhone."
    case .message(let text): text
    }
  }
}

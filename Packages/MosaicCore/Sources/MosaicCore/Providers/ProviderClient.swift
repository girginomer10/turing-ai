import Foundation

/// Non-secret identity of the provider adapter and exact base endpoint authorized to receive a
/// credential. Binding Keychain values to this snapshot prevents a concurrently replaced key from
/// being sent to a stale endpoint.
public struct ProviderCredentialBinding: Hashable, Codable, Sendable {
  public let provider: ProviderKind
  public let endpoint: String

  public init(provider: ProviderKind, baseURL: URL?) {
    self.provider = provider
    guard let baseURL,
      let scheme = baseURL.scheme?.lowercased(),
      let host = baseURL.host?.lowercased()
    else {
      endpoint = "unresolved"
      return
    }
    let port = baseURL.port ?? (scheme == "https" ? 443 : 80)
    // Keep reserved percent-encoded separators distinct. A shared gateway can route `/a%2Fb`
    // differently from `/a/b`, so decoding the path would let two wire destinations share a
    // credential binding.
    var path = baseURL.path(percentEncoded: true)
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    endpoint = "\(scheme)://\(host):\(port)\(path)"
  }
}

public struct ProviderConnection: Identifiable, Hashable, Sendable {
  public let id: UUID
  public let displayName: String
  public let provider: ProviderKind
  public let baseURL: URL?
  public let modelIdentifier: String
  public let contextWindowTokens: Int?
  public let maximumOutputTokens: Int?
  public let apiKey: String?

  public init(
    id: UUID,
    displayName: String,
    provider: ProviderKind,
    baseURL: URL? = nil,
    modelIdentifier: String,
    contextWindowTokens: Int? = nil,
    maximumOutputTokens: Int? = nil,
    apiKey: String? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.provider = provider
    self.baseURL = baseURL
    self.modelIdentifier = modelIdentifier
    self.contextWindowTokens = contextWindowTokens
    self.maximumOutputTokens = maximumOutputTokens
    self.apiKey = apiKey
  }

  @MainActor
  public init(configuration: ProviderConfigurationRecord, apiKey: String? = nil) {
    self.init(
      id: configuration.id,
      displayName: configuration.displayName,
      provider: configuration.provider,
      baseURL: configuration.baseURL,
      modelIdentifier: configuration.modelIdentifier,
      contextWindowTokens: configuration.contextWindowTokens,
      maximumOutputTokens: configuration.maximumOutputTokens,
      apiKey: apiKey
    )
  }

  public var resolvedBaseURL: URL? {
    baseURL ?? provider.defaultBaseURL
  }

  public var credentialBinding: ProviderCredentialBinding {
    ProviderCredentialBinding(provider: provider, baseURL: resolvedBaseURL)
  }

  public func authenticated(with apiKey: String?) -> ProviderConnection {
    ProviderConnection(
      id: id,
      displayName: displayName,
      provider: provider,
      baseURL: baseURL,
      modelIdentifier: modelIdentifier,
      contextWindowTokens: contextWindowTokens,
      maximumOutputTokens: maximumOutputTokens,
      apiKey: apiKey
    )
  }
}

public struct AIChatMessage: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let role: MessageRole
  public let content: String

  public init(id: UUID = UUID(), role: MessageRole, content: String) {
    self.id = id
    self.role = role
    self.content = content
  }
}

public struct AIChatRequest: Hashable, Sendable {
  public let messages: [AIChatMessage]
  public let systemPrompt: String?
  public let maxOutputTokens: Int
  public let webSearch: Bool
  public let images: [UUID: [ChatImageInput]]

  public init(
    messages: [AIChatMessage],
    systemPrompt: String? = nil,
    maxOutputTokens: Int = 8_192,
    images: [UUID: [ChatImageInput]] = [:],
    webSearch: Bool = false
  ) {
    self.messages = messages
    self.systemPrompt = systemPrompt
    self.webSearch = webSearch
    self.images = images
    self.maxOutputTokens = max(1, maxOutputTokens)
  }
}

public struct TokenUsage: Hashable, Codable, Sendable {
  public let inputTokens: Int?
  public let outputTokens: Int?

  public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }
}

public enum AIStreamEvent: Hashable, Sendable {
  case textDelta(String)
  case citations([WebSource])
  case usage(TokenUsage)
  case completed(responseID: String?)
}

public protocol AIProviderClient: Sendable {
  func listModels() async throws -> [String]
  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error>
}

public enum ProviderClientError: Error, Equatable, Sendable {
  case invalidEndpoint
  case insecureEndpoint
  case missingAPIKey
  case missingModelIdentifier
  case invalidResponse
  case responseTooLarge
  case unsupportedOperation
  case chatUnavailable
  case modelCatalogUnavailable
  case httpStatus(Int, String)
  case provider(String)
}

extension ProviderClientError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "The provider endpoint is not a valid URL."
    case .insecureEndpoint:
      "Remote provider endpoints must use HTTPS. HTTP is allowed only on a trusted local network."
    case .missingAPIKey:
      "Add an API key for this provider before sending a message."
    case .missingModelIdentifier:
      "Choose or enter a model ID before sending a message."
    case .invalidResponse:
      "The provider returned a response Turing AI could not read."
    case .responseTooLarge:
      "The provider response exceeded Turing AI’s safety limit."
    case .unsupportedOperation:
      "This provider connection does not support embeddings in Turing AI."
    case .chatUnavailable:
      "This provider connection is for embeddings and cannot send chat messages."
    case .modelCatalogUnavailable:
      "This provider does not publish a compatible model catalog. Enter an exact model ID instead."
    case .httpStatus(let status, let message):
      message.isEmpty ? "The provider returned HTTP \(status)." : message
    case .provider(let message):
      message
    }
  }
}

enum ProviderErrorSanitizer {
  private static let fallbackMessage =
    "The provider returned an error response Turing AI could not read."

  static func bodyMessage(from raw: String, redacting secret: String?) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    let candidate: String
    if let data = trimmed.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      candidate = ProviderWireProtocol.providerErrorMessage(in: object) ?? fallbackMessage
    } else if looksLikeMarkup(trimmed) {
      candidate = fallbackMessage
    } else {
      candidate = trimmed
    }
    return sanitized(candidate, redacting: secret)
  }

  static func description(for error: Error, redacting secret: String?) -> String {
    sanitized(error.localizedDescription, redacting: secret)
  }

  private static func sanitized(_ raw: String, redacting secret: String?) -> String {
    var value = raw
    if let secret, !secret.isEmpty {
      for variant in secretVariants(secret) where !variant.isEmpty {
        value = value.replacingOccurrences(of: variant, with: "••••")
      }
    }
    value = value.components(separatedBy: .controlCharacters).joined(separator: " ")
    value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if value.isEmpty { value = fallbackMessage }
    return String(value.prefix(2_000))
  }

  private static func secretVariants(_ secret: String) -> Set<String> {
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    let values = [secret, trimmed]
    var variants = Set(values)
    for value in values where !value.isEmpty {
      if let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        variants.insert(encoded)
      }
      if let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
        variants.insert(encoded)
      }
    }
    return variants
  }

  private static func looksLikeMarkup(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    return lowercased.hasPrefix("<")
      || lowercased.contains("<!doctype")
      || lowercased.contains("<html")
      || lowercased.contains("<body")
  }
}

enum ProviderNetworkTimeoutPolicy {
  /// URLSession treats the request timeout as an idle-data deadline. Research and reasoning
  /// providers can legitimately remain silent for several minutes before their first token.
  static let streamingRequestIdle: TimeInterval = 15 * 60

  /// Keep one finite upper bound even while permitting long-running provider jobs. Cancellation
  /// still tears the session down immediately when the consumer stops reading.
  static let streamingResource: TimeInterval = 24 * 60 * 60
}

public enum ProviderClientFactory {
  public static func make(connection: ProviderConnection) -> any AIProviderClient {
    URLSessionProviderClient(connection: connection)
  }
}

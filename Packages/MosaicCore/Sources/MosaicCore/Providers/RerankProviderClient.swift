import Foundation

/// Scores how well each document answers a query with a cross-encoder. Scores are probabilities in
/// 0...1, aligned with `documents`.
protocol RerankProviderClient: Sendable {
  func rerank(query: String, documents: [String], modelIdentifier: String) async throws -> [Double]
}

enum RerankProviderClientFactory {
  static func make(connection: ProviderConnection) -> any RerankProviderClient {
    URLSessionRerankProviderClient(connection: connection)
  }
}

final class URLSessionRerankProviderClient: RerankProviderClient, @unchecked Sendable {
  private static let responseLimit = 1_024 * 1_024
  private static let errorBodyLimit = 16 * 1_024

  private let connection: ProviderConnection

  init(connection: ProviderConnection) {
    self.connection = connection
  }

  func rerank(query: String, documents: [String], modelIdentifier: String) async throws -> [Double]
  {
    let request = try ProviderWireProtocol.rerankRequest(
      connection: connection, modelIdentifier: modelIdentifier, query: query, documents: documents)
    let session = makeSession()
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ProviderClientError.invalidResponse
    }
    let succeeded = (200..<300).contains(httpResponse.statusCode)
    var data = Data()
    let limit = succeeded ? Self.responseLimit : Self.errorBodyLimit
    for try await byte in bytes {
      if data.count >= limit {
        if succeeded { throw ProviderClientError.responseTooLarge }
        break
      }
      data.append(byte)
    }
    guard succeeded else {
      throw ProviderClientError.httpStatus(
        httpResponse.statusCode,
        ProviderErrorSanitizer.bodyMessage(
          from: String(data: data, encoding: .utf8) ?? "", redacting: connection.apiKey))
    }
    return try ProviderWireProtocol.decodeRerank(data: data, expectedCount: documents.count)
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 30
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return URLSession(
      configuration: configuration, delegate: RejectRedirectDelegate.shared, delegateQueue: nil)
  }
}

/// The user's optional reranker choice. It is off by default: a reranker sends the question and the
/// candidate memories to the chosen provider (like an embedding profile does).
public struct RecallRerankerSettings: Equatable, Sendable {
  public static let enabledKey = "recallRerankerEnabled"
  public static let providerKey = "recallRerankerProviderID"
  public static let modelKey = "recallRerankerModel"
  public static let minimumScoreKey = "recallRerankerMinimumScore"

  public var isEnabled: Bool
  public var providerID: UUID?
  public var modelIdentifier: String
  /// Candidates scoring below this probability are not injected. Zero keeps every candidate.
  public var minimumScore: Double

  public init(
    isEnabled: Bool = false, providerID: UUID? = nil, modelIdentifier: String = "",
    minimumScore: Double = 0
  ) {
    self.isEnabled = isEnabled
    self.providerID = providerID
    self.modelIdentifier = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    self.minimumScore = min(0.95, max(0, minimumScore))
  }

  public static func load(from defaults: UserDefaults = .standard) -> RecallRerankerSettings {
    RecallRerankerSettings(
      isEnabled: defaults.bool(forKey: enabledKey),
      providerID: defaults.string(forKey: providerKey).flatMap(UUID.init(uuidString:)),
      modelIdentifier: defaults.string(forKey: modelKey) ?? "",
      minimumScore: defaults.double(forKey: minimumScoreKey))
  }

  /// True when recall should call a reranker for this request.
  public var isUsable: Bool { isEnabled && providerID != nil && !modelIdentifier.isEmpty }
}

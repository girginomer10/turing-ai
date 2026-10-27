import Foundation

public enum EmbeddingInputPurpose: Hashable, Sendable {
  case query
  case document
}

public protocol EmbeddingProviderClient: Sendable {
  func embed(
    _ inputs: [String],
    modelIdentifier: String,
    purpose: EmbeddingInputPurpose
  ) async throws -> [[Float]]
}

public enum EmbeddingProviderClientFactory {
  public static func make(connection: ProviderConnection) -> any EmbeddingProviderClient {
    URLSessionEmbeddingProviderClient(connection: connection)
  }
}

enum EmbeddingBatchPolicy {
  static let applicationMaximumInputCount = 64

  static func maximumInputCount(
    provider: ProviderKind,
    modelIdentifier: String
  ) -> Int {
    // Alibaba Model Studio accepts twenty texts for qwen3.7-text-embedding and ten for the older
    // text-embedding-v4 family. Keep unknown manually entered IDs on the conservative bound.
    if provider == .qwen {
      return modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        == "qwen3.7-text-embedding" ? 20 : 10
    }

    // Qianfan accepts up to sixteen texts for its text embedding models, while tao-8k only
    // accepts one text per request.
    if provider == .baiduQianfan {
      return modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        == "tao-8k" ? 1 : 16
    }

    return applicationMaximumInputCount
  }

  static func batches(
    _ inputs: [String],
    provider: ProviderKind,
    modelIdentifier: String
  ) -> [[String]] {
    let limit = maximumInputCount(provider: provider, modelIdentifier: modelIdentifier)
    return stride(from: 0, to: inputs.count, by: limit).map { start in
      Array(inputs[start..<min(start + limit, inputs.count)])
    }
  }
}

/// Keeps split provider requests inside one immutable vector space. A provider must not be able to
/// change output dimensions between pages and leave an index that only fails much later at query
/// time.
struct EmbeddingBatchAccumulator {
  private var vectors: [[Float]] = []
  private var vectorDimension: Int?

  mutating func append(_ batch: [[Float]], expectedCount: Int) throws {
    guard batch.count == expectedCount, let firstDimension = batch.first?.count,
      firstDimension > 0, batch.allSatisfy({ $0.count == firstDimension })
    else {
      throw ProviderClientError.invalidResponse
    }
    if let vectorDimension {
      guard vectorDimension == firstDimension else {
        throw ProviderClientError.invalidResponse
      }
    } else {
      vectorDimension = firstDimension
    }

    let (_, overflow) = vectors.count.addingReportingOverflow(batch.count)
    guard !overflow else { throw ProviderClientError.responseTooLarge }
    vectors.append(contentsOf: batch)
  }

  func finalized(expectedCount: Int) throws -> [[Float]] {
    guard vectors.count == expectedCount, vectorDimension != nil else {
      throw ProviderClientError.invalidResponse
    }
    return vectors
  }
}

/// A client is created once per semantic retrieval or indexing job and may issue several outer
/// requests. Keep every request for the same model in one dimension for that complete job, not
/// merely within the provider's smaller wire batches.
actor EmbeddingVectorSpaceDimensionGuard {
  private var dimensionsByModelIdentifier: [String: Int] = [:]

  func validate(_ vectors: [[Float]], modelIdentifier: String) throws -> [[Float]] {
    guard let dimension = vectors.first?.count,
      dimension > 0,
      vectors.allSatisfy({ $0.count == dimension })
    else {
      throw ProviderClientError.invalidResponse
    }
    if let expectedDimension = dimensionsByModelIdentifier[modelIdentifier] {
      guard expectedDimension == dimension else {
        throw ProviderClientError.invalidResponse
      }
    } else {
      dimensionsByModelIdentifier[modelIdentifier] = dimension
    }
    return vectors
  }
}

enum EmbeddingInputFormatter {
  static func query(_ text: String, provider: ProviderKind, modelIdentifier: String) -> String {
    let model = modelIdentifier.lowercased()
    if provider == .google, model.contains("gemini-embedding-2") {
      return "task: search result | query: \(text)"
    }
    if provider == .tinfoil || model.contains("nomic-embed") {
      return "search_query: \(text)"
    }
    if model.contains("qwen3-embedding") {
      return """
        Instruct: Given a user's current message, retrieve relevant passages from their previous conversations and imported documents
        Query: \(text)
        """
    }
    if model.contains("embeddinggemma") {
      return "task: search result | query: \(text)"
    }
    if model.contains("arctic-embed") {
      return "query: \(text)"
    }
    if isNemotronEmbed(model), provider != .nvidiaNIM {
      return "query: \(text)"
    }
    if isE5(model) {
      if model.contains("instruct") {
        return """
          Instruct: Given a user's question, retrieve relevant passages from their memory
          Query: \(text)
          """
      }
      return "query: \(text)"
    }
    return text
  }

  /// intfloat/e5-*, multilingual-e5-*: matched by name so hosted and local copies both format correctly.
  private static func isE5(_ model: String) -> Bool {
    model.range(of: #"(^|[/:_\-])e5-"#, options: .regularExpression) != nil
      || model.contains("multilingual-e5")
  }

  /// nvidia/nemotron-*-embed-*: benchmarks/memory measured +0.069 MRR@10 with `query:`/`passage:`
  /// text prefixes on an OpenAI-compatible route. NVIDIA NIM carries the same intent in the
  /// `input_type` request field (ProviderWireProtocol), so its text stays raw.
  private static func isNemotronEmbed(_ model: String) -> Bool {
    model.contains("nemotron") && model.contains("embed")
  }

  /// Models whose input formatting was added after "embedding-format-v2". Their identity changes so
  /// vectors embedded from unformatted text rebuild instead of being compared with formatted queries.
  static func formatRevision(modelIdentifier: String, provider: ProviderKind? = nil) -> String? {
    let model = modelIdentifier.lowercased()
    if model.contains("embeddinggemma") || model.contains("arctic-embed") || isE5(model) {
      return "input-format-v3"
    }
    if isNemotronEmbed(model), provider != .nvidiaNIM { return "input-format-v3" }
    return nil
  }

  static func document(
    _ text: String,
    provider: ProviderKind,
    modelIdentifier: String
  ) -> String {
    let model = modelIdentifier.lowercased()
    if provider == .google, model.contains("gemini-embedding-2") {
      return "title: none | text: \(text)"
    }
    if provider == .tinfoil || model.contains("nomic-embed") {
      return "search_document: \(text)"
    }
    if model.contains("embeddinggemma") {
      return "title: none | text: \(text)"
    }
    if isNemotronEmbed(model), provider != .nvidiaNIM {
      return "passage: \(text)"
    }
    if isE5(model), !model.contains("instruct") {
      return "passage: \(text)"
    }
    return text
  }

  static func spaceIdentifier(
    connection: ProviderConnection,
    modelIdentifier: String
  ) -> String {
    var parts = [
      "embedding-format-v2",
      connection.provider.rawValue,
      connection.resolvedBaseURL?.absoluteString ?? "",
      modelIdentifier,
    ]
    if let revision = formatRevision(
      modelIdentifier: modelIdentifier,
      provider: connection.provider
    ) {
      parts.append(revision)
    }
    let value = parts.joined(separator: "|")
    return EmbeddingVectorCodec.fingerprint(for: value)
  }
}

final class URLSessionEmbeddingProviderClient: EmbeddingProviderClient, @unchecked Sendable {
  private static let responseLimit = 32 * 1_024 * 1_024
  private static let errorBodyLimit = 16 * 1_024
  private static let maximumBatchUTF8Bytes = 250_000

  private let connection: ProviderConnection
  private let dimensionGuard = EmbeddingVectorSpaceDimensionGuard()

  init(connection: ProviderConnection) {
    self.connection = connection
  }

  func embed(
    _ inputs: [String],
    modelIdentifier: String,
    purpose: EmbeddingInputPurpose
  ) async throws -> [[Float]] {
    guard !inputs.isEmpty else { throw ProviderClientError.invalidResponse }
    guard inputs.count <= EmbeddingBatchPolicy.applicationMaximumInputCount else {
      throw ProviderClientError.responseTooLarge
    }
    var totalInputUTF8Bytes = 0
    for input in inputs {
      let (nextCount, overflow) = totalInputUTF8Bytes.addingReportingOverflow(input.utf8.count)
      guard !overflow, nextCount <= Self.maximumBatchUTF8Bytes else {
        throw ProviderClientError.responseTooLarge
      }
      totalInputUTF8Bytes = nextCount
    }

    let session = makeSession()
    defer { session.invalidateAndCancel() }
    var accumulator = EmbeddingBatchAccumulator()

    for batch in EmbeddingBatchPolicy.batches(
      inputs,
      provider: connection.provider,
      modelIdentifier: modelIdentifier
    ) {
      try Task.checkCancellation()
      try accumulator.append(
        try await embedBatch(
          batch,
          modelIdentifier: modelIdentifier,
          purpose: purpose,
          session: session
        ),
        expectedCount: batch.count
      )
    }
    return try await dimensionGuard.validate(
      accumulator.finalized(expectedCount: inputs.count),
      modelIdentifier: modelIdentifier
    )
  }

  private func embedBatch(
    _ inputs: [String],
    modelIdentifier: String,
    purpose: EmbeddingInputPurpose,
    session: URLSession
  ) async throws -> [[Float]] {
    let request = try ProviderWireProtocol.embeddingRequest(
      connection: connection,
      modelIdentifier: modelIdentifier,
      inputs: inputs,
      purpose: purpose
    )
    let (bytes, response) = try await session.bytes(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ProviderClientError.invalidResponse
    }
    let succeeded = (200..<300).contains(httpResponse.statusCode)
    let data = try await collect(
      bytes,
      limit: succeeded ? Self.responseLimit : Self.errorBodyLimit,
      truncating: !succeeded
    )
    guard succeeded else {
      throw ProviderClientError.httpStatus(
        httpResponse.statusCode,
        ProviderErrorSanitizer.bodyMessage(
          from: String(data: data, encoding: .utf8) ?? "",
          redacting: connection.apiKey
        )
      )
    }
    return try ProviderWireProtocol.decodeEmbeddings(
      data: data,
      expectedCount: inputs.count,
      provider: connection.provider
    )
  }

  private func collect<Bytes: AsyncSequence>(
    _ bytes: Bytes,
    limit: Int,
    truncating: Bool
  ) async throws -> Data where Bytes.Element == UInt8 {
    var data = Data()
    data.reserveCapacity(min(limit, 64 * 1_024))
    for try await byte in bytes {
      if data.count >= limit {
        if truncating { break }
        throw ProviderClientError.responseTooLarge
      }
      data.append(byte)
    }
    return data
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 120
    configuration.timeoutIntervalForResource = 180
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return URLSession(
      configuration: configuration,
      delegate: RejectRedirectDelegate.shared,
      delegateQueue: nil
    )
  }
}

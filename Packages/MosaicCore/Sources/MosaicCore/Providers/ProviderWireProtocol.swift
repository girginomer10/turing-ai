import CoreFoundation
import Foundation

enum ProviderDialect: Sendable {
  case openAIResponses
  case openAIChatCompletions
  case anthropicMessages
  case gemini
}

struct ProviderModelCatalogPage: Equatable, Sendable {
  let modelIdentifiers: [String]
  let nextCursor: String?
}

enum ProviderWireProtocol {
  static func dialect(for provider: ProviderKind) -> ProviderDialect {
    switch provider {
    case .openAI: .openAIResponses
    case .anthropic: .anthropicMessages
    case .google: .gemini
    default:
      .openAIChatCompletions
    }
  }

  static func streamingRequest(
    connection: ProviderConnection,
    chatRequest: AIChatRequest
  ) throws -> URLRequest {
    guard connection.provider.supportsChat else {
      throw ProviderClientError.chatUnavailable
    }
    guard !connection.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ProviderClientError.missingModelIdentifier
    }
    guard let baseURL = connection.resolvedBaseURL else {
      throw ProviderClientError.invalidEndpoint
    }
    try validate(baseURL: baseURL)
    if connection.provider.requiresAPIKey,
      connection.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    {
      throw ProviderClientError.missingAPIKey
    }

    guard
      chatRequest.images.values.flatMap({ $0 }).allSatisfy({
        $0.mimeType == "image/jpeg" && !$0.data.isEmpty && $0.data.count <= 1_048_576
      }), chatRequest.images.values.reduce(0, { $0 + $1.count }) <= 16,
      Set(chatRequest.images.keys).isSubset(
        of: Set(chatRequest.messages.filter { $0.role == .user }.map(\.id)))
    else { throw ProviderClientError.provider("Invalid or too many photo attachments.") }
    if chatRequest.webSearch, !WebSearchCapability.supports(connection) {
      throw ProviderClientError.provider(
        "Web search is unavailable for this connection and model. Choose a supported OpenAI or Claude model, or turn off Web search."
      )
    }
    let dialect = dialect(for: connection.provider)
    let endpoint: URL
    switch dialect {
    case .openAIResponses:
      endpoint = try appending("responses", to: baseURL)
    case .openAIChatCompletions:
      endpoint = try appending("chat/completions", to: baseURL)
    case .anthropicMessages:
      endpoint = try appending("messages", to: baseURL)
    case .gemini:
      let model = normalizedGeminiModelIdentifier(connection.modelIdentifier)
      let encoded = try encodedPathSegment(model)
      let rawURL = try appending("models/\(encoded):streamGenerateContent", to: baseURL)
      guard var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) else {
        throw ProviderClientError.invalidEndpoint
      }
      components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
      guard let finalURL = components.url else { throw ProviderClientError.invalidEndpoint }
      endpoint = finalURL
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = ProviderNetworkTimeoutPolicy.streamingRequestIdle
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    applyAuthentication(to: &request, connection: connection)
    request.httpBody = try JSONSerialization.data(
      withJSONObject: body(connection: connection, request: chatRequest, dialect: dialect)
    )
    return request
  }

  static func modelsRequest(
    connection: ProviderConnection,
    cursor: String? = nil
  ) throws -> URLRequest {
    guard connection.provider.supportsModelDiscovery else {
      throw ProviderClientError.modelCatalogUnavailable
    }
    guard let baseURL = connection.resolvedBaseURL else {
      throw ProviderClientError.invalidEndpoint
    }
    try validate(baseURL: baseURL)
    let endpoint = try modelCatalogEndpoint(connection: connection, baseURL: baseURL)
    let pageURL = try modelCatalogPageURL(
      endpoint: endpoint,
      provider: connection.provider,
      cursor: cursor
    )
    let isPublicAIMLCatalogRequest =
      connection.provider == .aimlAPI
      && isExactPublicAIMLCatalogRequest(pageURL)
    if connection.provider.requiresAPIKey,
      !isPublicAIMLCatalogRequest,
      connection.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    {
      throw ProviderClientError.missingAPIKey
    }

    var request = URLRequest(url: pageURL)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if !isPublicAIMLCatalogRequest {
      applyAuthentication(to: &request, connection: connection)
    }
    return request
  }

  static func decodeModels(data: Data, provider: ProviderKind) throws -> [String] {
    try decodeModelPage(data: data, provider: provider).modelIdentifiers
  }

  static func decodeModelPage(
    data: Data,
    provider: ProviderKind
  ) throws -> ProviderModelCatalogPage {
    let payload = try JSONSerialization.jsonObject(with: data)
    let ids: [String]
    let nextCursor: String?
    switch provider.modelCatalogKind {
    case .anthropic:
      guard let object = payload as? [String: Any],
        let records = object["data"] as? [[String: Any]],
        let hasMore = object["has_more"] as? Bool
      else {
        throw ProviderClientError.invalidResponse
      }
      ids = records.compactMap { record in
        guard record["type"] as? String == "model" else { return nil }
        return record["id"] as? String
      }
      if hasMore {
        guard let cursor = try paginationCursor(in: object, key: "last_id") else {
          throw ProviderClientError.invalidResponse
        }
        nextCursor = cursor
      } else {
        nextCursor = nil
      }
    case .gemini:
      guard let object = payload as? [String: Any],
        let models = object["models"] as? [[String: Any]]
      else {
        throw ProviderClientError.invalidResponse
      }
      ids = models.compactMap { model in
        guard let name = model["name"] as? String,
          let methods = model["supportedGenerationMethods"] as? [String],
          methods.contains("generateContent"),
          isGeminiTextChatModelIdentifier(normalizedGeminiModelIdentifier(name))
        else { return nil }
        return normalizedGeminiModelIdentifier(name)
      }
      nextCursor = try paginationCursor(in: object, key: "nextPageToken")
    case .xAI:
      guard let object = payload as? [String: Any],
        let records = object["models"] as? [[String: Any]]
      else {
        throw ProviderClientError.invalidResponse
      }
      ids = records.compactMap { $0["id"] as? String }
      nextCursor = nil
    case .mistral:
      let records: [[String: Any]]
      if let array = payload as? [[String: Any]] {
        records = array
      } else if let object = payload as? [String: Any],
        let data = object["data"] as? [[String: Any]]
      {
        records = data
      } else {
        throw ProviderClientError.invalidResponse
      }
      ids = records.compactMap { record in
        guard let capabilities = record["capabilities"] as? [String: Any],
          capabilities["completion_chat"] as? Bool == true
        else { return nil }
        return record["id"] as? String
      }
      nextCursor = nil
    case .topLevelArray:
      let records: [[String: Any]]
      if let array = payload as? [[String: Any]] {
        records = array
      } else if let object = payload as? [String: Any],
        let data = object["data"] as? [[String: Any]]
      {
        records = data
      } else {
        throw ProviderClientError.invalidResponse
      }
      ids = records.compactMap { record in
        guard record["type"] as? String == "chat" else { return nil }
        return record["id"] as? String
      }
      nextCursor = nil
    case .fireworks:
      guard let object = payload as? [String: Any] else {
        throw ProviderClientError.invalidResponse
      }
      let records: [[String: Any]]
      if let models = object["models"] as? [[String: Any]] {
        records = models
      } else if let data = object["data"] as? [[String: Any]] {
        records = data
      } else {
        throw ProviderClientError.invalidResponse
      }
      ids = records.compactMap { record in
        guard record["conversationConfig"] is [String: Any] else { return nil }
        return (record["name"] as? String) ?? (record["id"] as? String)
      }
      nextCursor = try paginationCursor(in: object, key: "nextPageToken")
    case .cohere:
      guard let object = payload as? [String: Any],
        let records = object["models"] as? [[String: Any]]
      else {
        throw ProviderClientError.invalidResponse
      }
      ids = records.compactMap { record in
        (record["name"] as? String) ?? (record["id"] as? String)
      }
      nextCursor = try paginationCursor(in: object, key: "next_page_token")
    case .vercel:
      guard let object = payload as? [String: Any],
        let records = object["data"] as? [[String: Any]]
      else {
        throw ProviderClientError.invalidResponse
      }
      ids = records.compactMap { record in
        guard (record["type"] as? String)?.lowercased() == "language" else { return nil }
        if let rawModalities = record["modalities"] {
          guard let modalities = rawModalities as? [String: Any],
            let output = modalities["output"] as? [String],
            output.contains(where: { $0.lowercased() == "text" })
          else { return nil }
        }
        return record["id"] as? String
      }
      nextCursor = nil
    case .tencentTokenHub:
      guard let object = payload as? [String: Any],
        let records = object["data"] as? [[String: Any]]
      else {
        throw ProviderClientError.invalidResponse
      }
      ids = records.compactMap { record in
        guard (record["status"] as? String)?.lowercased() == "online",
          record["object"] as? String == "model",
          let identifier = record["id"] as? String
        else { return nil }
        return isTencentTextChatModelIdentifier(identifier) ? identifier : nil
      }
      nextCursor = nil
    case .baiduQianfan:
      guard let object = payload as? [String: Any],
        let records = object["data"] as? [[String: Any]]
      else {
        throw ProviderClientError.invalidResponse
      }
      ids = records.compactMap { record in
        guard let identifier = record["id"] as? String,
          !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          isBaiduTextChatModel(record)
        else { return nil }
        return identifier
      }
      nextCursor = nil
    case .architectureTextOutput, .openRouter, .poe:
      guard let object = payload as? [String: Any],
        let records = object["data"] as? [[String: Any]]
      else {
        throw ProviderClientError.invalidResponse
      }
      ids = records.compactMap { record in
        guard let architecture = record["architecture"] as? [String: Any],
          let outputModalities = architecture["output_modalities"] as? [String],
          outputModalities.contains(where: { $0.lowercased() == "text" })
        else { return nil }
        if provider == .huggingFace, let rawProviders = record["providers"] {
          guard let providers = rawProviders as? [[String: Any]],
            providers.contains(where: { ($0["status"] as? String)?.lowercased() == "live" })
          else { return nil }
        }
        if provider == .poe, let rawEndpoints = record["supported_endpoints"] {
          // Public bots also publish an empty array when endpoint metadata is unspecified.
          guard let endpoints = rawEndpoints as? [String],
            endpoints.isEmpty || endpoints.contains("/v1/chat/completions")
          else { return nil }
        }
        if provider == .openRouter, (record["id"] as? String)?.hasSuffix(":batch") == true {
          return nil
        }
        return record["id"] as? String
      }
      nextCursor = nil
    case .topLevelTextOutput:
      guard let object = payload as? [String: Any],
        let records = object["data"] as? [[String: Any]]
      else {
        throw ProviderClientError.invalidResponse
      }
      ids = records.compactMap { record in
        guard let outputModalities = record["output_modalities"] as? [String],
          outputModalities.contains(where: { $0.lowercased() == "text" })
        else { return nil }
        return record["id"] as? String
      }
      nextCursor = nil
    case .aimlAPI:
      let records: [[String: Any]]
      if let array = payload as? [[String: Any]] {
        records = array
      } else if let object = payload as? [String: Any],
        let data = object["data"] as? [[String: Any]]
      {
        records = data
      } else {
        throw ProviderClientError.invalidResponse
      }
      ids = records.compactMap { record in
        guard let type = (record["type"] as? String)?.lowercased(),
          let identifier = record["id"] as? String,
          !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        // The current registry identifies the wire endpoint in `type`; its playground tags also
        // mark Responses and Anthropic-only entries as chat, so those tags are not capabilities.
        if type == "openai/chat-completions" {
          return identifier
        }
        guard type == "chat-completion",
          let endpoints = record["endpoints"] as? [String],
          endpoints.contains(where: { endpoint in
            URLComponents(string: endpoint)?.path.lowercased() == "/v1/chat/completions"
          })
        else { return nil }
        return identifier
      }
      nextCursor = nil
    case .featherless:
      guard let object = payload as? [String: Any],
        let records = object["data"] as? [[String: Any]],
        let pagination = object["pagination"] as? [String: Any],
        let currentPage = pagination["current_page"] as? Int,
        let totalPages = pagination["total_pages"] as? Int,
        currentPage >= 1,
        totalPages >= 0,
        totalPages == 0 ? currentPage == 1 : currentPage <= totalPages
      else {
        throw ProviderClientError.invalidResponse
      }
      ids = records.compactMap { $0["id"] as? String }
      nextCursor = currentPage < totalPages ? String(currentPage + 1) : nil
    case .lmStudio:
      guard let object = payload as? [String: Any],
        let records = object["models"] as? [[String: Any]]
      else {
        throw ProviderClientError.invalidResponse
      }
      ids = records.compactMap { record in
        guard (record["type"] as? String)?.lowercased() == "llm",
          let identifier = record["key"] as? String,
          !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return identifier
      }
      nextCursor = nil
    case .standard, .siliconFlow, .deepInfra, .tinfoil:
      guard let object = payload as? [String: Any],
        let records = object["data"] as? [[String: Any]]
      else {
        throw ProviderClientError.invalidResponse
      }
      if provider.modelCatalogKind == .tinfoil {
        ids = records.compactMap { model in
          guard model["type"] as? String == "chat",
            let endpoints = model["endpoints"] as? [String],
            endpoints.contains("/v1/chat/completions")
          else { return nil }
          return model["id"] as? String
        }
      } else if provider.modelCatalogKind == .deepInfra {
        let chatTags: Set<String> = ["chat", "chat-completions", "text-generation", "llm"]
        ids = records.compactMap { model in
          let metadata = model["metadata"] as? [String: Any]
          let tags = Set((metadata?["tags"] as? [String] ?? []).map { $0.lowercased() })
          guard !tags.isDisjoint(with: chatTags) else { return nil }
          return model["id"] as? String
        }
      } else {
        ids = records.compactMap { $0["id"] as? String }
      }
      nextCursor = nil
    case .unavailable:
      throw ProviderClientError.modelCatalogUnavailable
    }
    return ProviderModelCatalogPage(
      modelIdentifiers: Array(Set(ids)).sorted(),
      nextCursor: nextCursor
    )
  }

  static func embeddingRequest(
    connection: ProviderConnection,
    modelIdentifier: String,
    inputs: [String],
    purpose: EmbeddingInputPurpose
  ) throws -> URLRequest {
    guard connection.provider.supportsEmbeddings else {
      throw ProviderClientError.unsupportedOperation
    }
    guard !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ProviderClientError.missingModelIdentifier
    }
    guard !inputs.isEmpty, inputs.allSatisfy({ !$0.isEmpty }) else {
      throw ProviderClientError.invalidResponse
    }
    guard let baseURL = connection.resolvedBaseURL else {
      throw ProviderClientError.invalidEndpoint
    }
    try validate(baseURL: baseURL)
    if connection.provider.requiresAPIKey,
      connection.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    {
      throw ProviderClientError.missingAPIKey
    }

    let usesNativeQwenEmbedding =
      connection.provider == .qwen && isOfficialQwenCompatibleEndpoint(baseURL)
    let usesNativeCohereEmbedding =
      connection.provider == .cohere
      && isExactOfficialEndpoint(
        baseURL,
        host: "api.cohere.ai",
        percentEncodedPath: "/compatibility/v1"
      )

    let endpoint: URL
    if connection.provider == .google {
      let model = normalizedGeminiModelIdentifier(modelIdentifier)
      let encoded = try encodedPathSegment(model)
      endpoint = try appending("models/\(encoded):batchEmbedContents", to: baseURL)
    } else if usesNativeQwenEmbedding {
      endpoint = try replacingPath(
        of: baseURL,
        with: "/api/v1/services/embeddings/text-embedding/text-embedding"
      )
    } else if usesNativeCohereEmbedding {
      endpoint = try replacingPath(of: baseURL, with: "/v2/embed")
    } else {
      endpoint = try appending("embeddings", to: baseURL)
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    applyAuthentication(to: &request, connection: connection)
    let body: [String: Any]
    if connection.provider == .google {
      let model = normalizedGeminiModelIdentifier(modelIdentifier)
      body = [
        "requests": inputs.map { input -> [String: Any] in
          var embeddingRequest: [String: Any] = [
            "model": "models/\(model)",
            "content": ["parts": [["text": input]]],
          ]
          if model.lowercased() != "gemini-embedding-2" {
            embeddingRequest["embedContentConfig"] = [
              "taskType": purpose == .query ? "RETRIEVAL_QUERY" : "RETRIEVAL_DOCUMENT"
            ]
          }
          return embeddingRequest
        }
      ]
    } else if usesNativeQwenEmbedding {
      var parameters: [String: Any] = [
        "text_type": purpose == .query ? "query" : "document"
      ]
      if supportsQwenDenseOutputType(modelIdentifier) {
        parameters["output_type"] = "dense"
      }
      if purpose == .query, supportsQwenRetrievalInstruction(modelIdentifier) {
        parameters["instruct"] =
          "Given a user's current message, retrieve relevant passages from their previous conversations and imported documents"
      }
      body = [
        "model": modelIdentifier,
        "input": ["texts": inputs],
        "parameters": parameters,
      ]
    } else if usesNativeCohereEmbedding {
      body = [
        "model": modelIdentifier,
        "texts": inputs,
        "input_type": purpose == .query ? "search_query" : "search_document",
        "embedding_types": ["float"],
        "truncate": "NONE",
      ]
    } else {
      var compatibleBody: [String: Any] = [
        "model": modelIdentifier,
        "input": inputs,
      ]
      if connection.provider != .voyageAI,
        connection.provider != .jinaAI,
        connection.provider != .fireworksAI
      {
        compatibleBody["encoding_format"] = "float"
      }
      switch connection.provider {
      case .voyageAI:
        compatibleBody["input_type"] = purpose == .query ? "query" : "document"
      case .jinaAI:
        compatibleBody["task"] = purpose == .query ? "retrieval.query" : "retrieval.passage"
      case .nvidiaNIM:
        if nvidiaModelAcceptsInputType(modelIdentifier) {
          compatibleBody["input_type"] = purpose == .query ? "query" : "passage"
        }
        compatibleBody["modality"] = "text"
      default:
        break
      }
      body = compatibleBody
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  // MARK: Reranking

  static let rerankMaximumDocuments = 30

  /// A cross-encoder rerank request. Cohere uses its native `/v2/rerank`; Jina, Voyage and the
  /// self-hosted runtimes share the `{model, query, documents}` shape under `<base>/rerank`.
  static func rerankRequest(
    connection: ProviderConnection,
    modelIdentifier: String,
    query: String,
    documents: [String]
  ) throws -> URLRequest {
    guard connection.provider.supportsReranking else {
      throw ProviderClientError.unsupportedOperation
    }
    guard !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ProviderClientError.missingModelIdentifier
    }
    guard !query.isEmpty, !documents.isEmpty, documents.count <= rerankMaximumDocuments,
      documents.allSatisfy({ !$0.isEmpty })
    else {
      throw ProviderClientError.invalidResponse
    }
    guard let baseURL = connection.resolvedBaseURL else {
      throw ProviderClientError.invalidEndpoint
    }
    try validate(baseURL: baseURL)
    if connection.provider.requiresAPIKey,
      connection.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    {
      throw ProviderClientError.missingAPIKey
    }

    let endpoint: URL
    switch connection.provider {
    case .cohere: endpoint = try replacingPath(of: baseURL, with: "/v2/rerank")
    case .deepInfra:
      // DeepInfra serves rerankers through its native inference route, one model per path.
      let model = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
      guard model.split(separator: "/").allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." })
      else { throw ProviderClientError.missingModelIdentifier }
      endpoint = try replacingPath(of: baseURL, with: "/v1/inference/\(model)")
    default: endpoint = try appending("rerank", to: baseURL)
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    applyAuthentication(to: &request, connection: connection)
    var body: [String: Any]
    if connection.provider == .deepInfra {
      body = ["queries": Array(repeating: query, count: documents.count), "documents": documents]
    } else {
      body = ["model": modelIdentifier, "query": query, "documents": documents]
      body[connection.provider == .voyageAI ? "top_k" : "top_n"] = documents.count
      if connection.provider == .jinaAI { body["return_documents"] = false }
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  /// One relevance probability per document, in document order. Providers that return raw logits
  /// (llama.cpp with some models) are squashed with a sigmoid so thresholds mean the same thing.
  static func decodeRerank(data: Data, expectedCount: Int) throws -> [Double] {
    guard expectedCount > 0,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw ProviderClientError.invalidResponse
    }
    // DeepInfra answers with {"scores": [...]} aligned with the documents.
    if let flat = object["scores"] as? [NSNumber] {
      let values = flat.map(\.doubleValue)
      guard values.count == expectedCount, values.allSatisfy(\.isFinite) else {
        throw ProviderClientError.invalidResponse
      }
      return values.contains(where: { $0 < 0 || $0 > 1 })
        ? values.map { 1 / (1 + exp(-$0)) } : values
    }
    guard let rows = (object["results"] ?? object["data"]) as? [[String: Any]],
      rows.count == expectedCount
    else {
      throw ProviderClientError.invalidResponse
    }
    var scores = [Double?](repeating: nil, count: expectedCount)
    for row in rows {
      let rawScore = (row["relevance_score"] ?? row["score"]) as? NSNumber
      guard let index = (row["index"] as? NSNumber)?.intValue, (0..<expectedCount).contains(index),
        scores[index] == nil, let score = rawScore?.doubleValue, score.isFinite
      else {
        throw ProviderClientError.invalidResponse
      }
      scores[index] = score
    }
    let values = scores.compactMap { $0 }
    guard values.count == expectedCount else { throw ProviderClientError.invalidResponse }
    if values.contains(where: { $0 < 0 || $0 > 1 }) {
      return values.map { 1 / (1 + exp(-$0)) }
    }
    return values
  }

  static func decodeEmbeddings(
    data: Data,
    expectedCount: Int,
    provider: ProviderKind
  ) throws -> [[Float]] {
    guard expectedCount > 0,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw ProviderClientError.invalidResponse
    }

    if provider == .google {
      guard let records = object["embeddings"] as? [[String: Any]],
        records.count == expectedCount
      else {
        throw ProviderClientError.invalidResponse
      }
      let vectors = try records.map { record -> [Float] in
        guard let rawVector = record["values"] as? [NSNumber] else {
          throw ProviderClientError.invalidResponse
        }
        return try validatedEmbeddingVector(rawVector)
      }
      return try validatedEmbeddingDimensions(vectors)
    }

    if provider == .qwen, let output = object["output"] as? [String: Any] {
      guard let records = output["embeddings"] as? [[String: Any]],
        records.count == expectedCount
      else {
        throw ProviderClientError.invalidResponse
      }
      return try decodeIndexedEmbeddingRecords(
        records,
        indexKey: "text_index",
        expectedCount: expectedCount
      )
    }

    if provider == .cohere, let embeddings = object["embeddings"] as? [String: Any] {
      guard let rawVectors = embeddings["float"] as? [[NSNumber]],
        rawVectors.count == expectedCount
      else {
        throw ProviderClientError.invalidResponse
      }
      return try validatedEmbeddingDimensions(rawVectors.map(validatedEmbeddingVector))
    }

    guard let records = object["data"] as? [[String: Any]],
      records.count == expectedCount
    else {
      throw ProviderClientError.invalidResponse
    }

    return try decodeIndexedEmbeddingRecords(
      records,
      indexKey: "index",
      expectedCount: expectedCount
    )
  }

  static func decode(event: ServerSentEvent, dialect: ProviderDialect) throws -> [AIStreamEvent] {
    if event.data == "[DONE]" { return [.completed(responseID: nil)] }
    guard let data = event.data.data(using: .utf8),
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return []
    }
    if let message = providerErrorMessage(in: object) {
      throw ProviderClientError.provider(message)
    }

    switch dialect {
    case .openAIResponses:
      return try decodeOpenAIResponse(object)
    case .openAIChatCompletions:
      return try decodeChatCompletion(object)
    case .anthropicMessages:
      return try decodeAnthropic(object)
    case .gemini:
      return try decodeGemini(object)
    }
  }

  static func providerErrorMessage(in object: [String: Any]) -> String? {
    if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
      return message
    }
    if let message = object["error"] as? String, !message.isEmpty {
      return message
    }
    if object["type"] as? String == "error" {
      return object["message"] as? String ?? "The provider reported an error."
    }
    if let detail = object["detail"] as? String, !detail.isEmpty {
      return detail
    }
    if let details = object["detail"] as? [[String: Any]],
      let message = details.compactMap({ $0["msg"] as? String }).first
    {
      return message
    }
    return nil
  }

  private static func body(
    connection: ProviderConnection,
    request: AIChatRequest,
    dialect: ProviderDialect
  ) -> [String: Any] {
    switch dialect {
    case .openAIResponses:
      var body: [String: Any] = [
        "model": connection.modelIdentifier,
        "input": request.messages.filter { $0.role != .system }.map {
          [
            "role": wireRole($0.role, dialect: dialect),
            "content": wireContent($0, images: request.images[$0.id] ?? [], dialect: dialect),
          ]
        },
        "max_output_tokens": request.maxOutputTokens,
        "stream": true,
        "store": false,
      ]
      if request.webSearch {
        body["tools"] = [["type": "web_search"]]
        body["tool_choice"] = "required"
      }
      if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
        body["instructions"] = systemPrompt
      }
      return body

    case .openAIChatCompletions:
      var messages = request.messages.map {
        [
          "role": wireRole($0.role, dialect: dialect),
          "content": wireContent($0, images: request.images[$0.id] ?? [], dialect: dialect),
        ]
      }
      if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
        messages.insert(["role": "system", "content": systemPrompt], at: 0)
      }
      var body: [String: Any] = [
        "model": connection.modelIdentifier,
        "messages": messages,
        "stream": true,
      ]
      let normalizedModelIdentifier = connection.modelIdentifier.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).lowercased()
      let maximumOutputTokensKey =
        connection.provider == .miniMax
          || (connection.provider == .kimi && normalizedModelIdentifier == "kimi-k3")
        ? "max_completion_tokens" : "max_tokens"
      body[maximumOutputTokensKey] = request.maxOutputTokens
      if connection.provider.includesStreamingUsage {
        body["stream_options"] = ["include_usage": true]
      }
      return body

    case .anthropicMessages:
      var body: [String: Any] = [
        "model": connection.modelIdentifier,
        "messages": request.messages.filter { $0.role == .user || $0.role == .assistant }.map {
          [
            "role": wireRole($0.role, dialect: dialect),
            "content": wireContent($0, images: request.images[$0.id] ?? [], dialect: dialect),
          ]
        },
        "max_tokens": request.maxOutputTokens,
        "stream": true,
      ]
      if request.webSearch {
        body["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": 3]]
        body["tool_choice"] = ["type": "auto"]
      }
      if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
        body["system"] = systemPrompt
      }
      return body

    case .gemini:
      var body: [String: Any] = [
        "contents": request.messages.filter { $0.role == .user || $0.role == .assistant }.map {
          [
            "role": wireRole($0.role, dialect: dialect),
            "parts": wireContent($0, images: request.images[$0.id] ?? [], dialect: dialect),
          ]
        },
        "generationConfig": ["maxOutputTokens": request.maxOutputTokens],
      ]
      if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
        body["systemInstruction"] = ["parts": [["text": systemPrompt]]]
      }
      return body
    }
  }

  private static func wireContent(
    _ message: AIChatMessage, images: [ChatImageInput], dialect: ProviderDialect
  ) -> Any {
    if images.isEmpty {
      return dialect == .gemini ? [["text": message.content]] : message.content as Any
    }
    switch dialect {
    case .openAIResponses:
      return [["type": "input_text", "text": message.content]]
        + images.map { ["type": "input_image", "image_url": $0.dataURL, "detail": "auto"] }
    case .openAIChatCompletions:
      return [["type": "text", "text": message.content] as [String: Any]]
        + images.map { ["type": "image_url", "image_url": ["url": $0.dataURL, "detail": "auto"]] }
    case .anthropicMessages:
      return [["type": "text", "text": message.content] as [String: Any]]
        + images.map {
          [
            "type": "image",
            "source": [
              "type": "base64", "media_type": $0.mimeType, "data": $0.data.base64EncodedString(),
            ],
          ]
        }
    case .gemini:
      return [["text": message.content] as [String: Any]]
        + images.map {
          ["inlineData": ["mimeType": $0.mimeType, "data": $0.data.base64EncodedString()]]
        }
    }
  }

  private static func applyAuthentication(
    to request: inout URLRequest,
    connection: ProviderConnection
  ) {
    guard let apiKey = connection.apiKey, !apiKey.isEmpty else { return }
    switch connection.provider.authenticationStyle {
    case .apiKeyHeader:
      request.setValue(apiKey, forHTTPHeaderField: "api-key")
    case .anthropic:
      request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    case .google:
      request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    case .bearer:
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      if connection.provider == .openRouter {
        request.setValue("Turing AI", forHTTPHeaderField: "X-Title")
      }
    }
  }

  private static func wireRole(_ role: MessageRole, dialect: ProviderDialect) -> String {
    switch dialect {
    case .gemini:
      role == .assistant ? "model" : "user"
    default:
      switch role {
      case .assistant: "assistant"
      case .system: "system"
      case .tool: "tool"
      case .user: "user"
      }
    }
  }

  private static func decodeOpenAIResponse(_ object: [String: Any]) throws -> [AIStreamEvent] {
    let type = object["type"] as? String
    switch type {
    case "response.output_text.annotation.added":
      guard let annotation = object["annotation"] as? [String: Any],
        let source = WebSearchCapability.source(annotation)
      else { return [] }
      return [.citations([source])]
    case "response.output_text.delta":
      guard let delta = object["delta"] as? String else { return [] }
      return [.textDelta(delta)]
    case "response.refusal.delta":
      // Refusals are visible assistant output in the Responses API. Preserve the provider's
      // explanation instead of completing with an apparently empty answer.
      guard let delta = object["delta"] as? String else { return [] }
      return [.textDelta(delta)]
    case "response.completed":
      let response = object["response"] as? [String: Any]
      let id = response?["id"] as? String
      var events: [AIStreamEvent] = []
      for item in response?["output"] as? [[String: Any]] ?? [] {
        for content in item["content"] as? [[String: Any]] ?? [] {
          let sources = (content["annotations"] as? [[String: Any]] ?? []).compactMap(
            WebSearchCapability.source)
          if !sources.isEmpty { events.append(.citations(sources)) }
        }
      }
      if let usage = response?["usage"] as? [String: Any] {
        events.append(
          .usage(
            TokenUsage(
              inputTokens: usage["input_tokens"] as? Int,
              outputTokens: usage["output_tokens"] as? Int
            )))
      }
      events.append(.completed(responseID: id))
      return events
    case "response.failed", "response.incomplete":
      let response = object["response"] as? [String: Any]
      let error = response?["error"] as? [String: Any]
      let incompleteDetails = response?["incomplete_details"] as? [String: Any]
      let reason = incompleteDetails?["reason"] as? String
      throw ProviderClientError.provider(
        error?["message"] as? String
          ?? reason.map { "OpenAI stopped before completion (\($0))." }
          ?? "OpenAI could not complete the response."
      )
    default:
      return []
    }
  }

  private static func decodeChatCompletion(_ object: [String: Any]) throws -> [AIStreamEvent] {
    var events: [AIStreamEvent] = []
    var completedResponseID: String?
    var didComplete = false
    if let choice = (object["choices"] as? [[String: Any]])?.first {
      if let finishReason = choice["finish_reason"] as? String {
        guard ["stop", "normal"].contains(finishReason.lowercased()) else {
          throw ProviderClientError.provider(
            "The provider stopped before a normal completion (\(finishReason))."
          )
        }
        didComplete = true
        completedResponseID = object["id"] as? String
      }
      if let delta = choice["delta"] as? [String: Any],
        let content = delta["content"] as? String,
        !content.isEmpty
      {
        events.append(.textDelta(content))
      }
    }
    if let usage = object["usage"] as? [String: Any] {
      events.append(
        .usage(
          TokenUsage(
            inputTokens: usage["prompt_tokens"] as? Int,
            outputTokens: usage["completion_tokens"] as? Int
          )))
    }
    if didComplete {
      events.append(.completed(responseID: completedResponseID))
    }
    return events
  }

  private static func decodeAnthropic(_ object: [String: Any]) throws -> [AIStreamEvent] {
    switch object["type"] as? String {
    case "content_block_delta":
      let delta = object["delta"] as? [String: Any]
      if delta?["type"] as? String == "citations_delta",
        let citation = delta?["citation"] as? [String: Any],
        let source = WebSearchCapability.source(citation)
      {
        return [.citations([source])]
      }
      guard delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String else {
        return []
      }
      return [.textDelta(text)]
    case "message_start":
      let message = object["message"] as? [String: Any]
      let usage = message?["usage"] as? [String: Any]
      return [.usage(TokenUsage(inputTokens: usage?["input_tokens"] as? Int))]
    case "message_delta":
      let delta = object["delta"] as? [String: Any]
      if let stopReason = delta?["stop_reason"] as? String,
        !["end_turn", "stop_sequence"].contains(stopReason)
      {
        throw ProviderClientError.provider(
          "Anthropic stopped before a normal completion (\(stopReason))."
        )
      }
      let usage = object["usage"] as? [String: Any]
      return [.usage(TokenUsage(outputTokens: usage?["output_tokens"] as? Int))]
    case "message_stop":
      return [.completed(responseID: nil)]
    case "error":
      throw ProviderClientError.provider(
        providerErrorMessage(in: object) ?? "Anthropic reported an error.")
    default:
      return []
    }
  }

  private static func decodeGemini(_ object: [String: Any]) throws -> [AIStreamEvent] {
    if let feedback = object["promptFeedback"] as? [String: Any],
      let blockReason = feedback["blockReason"] as? String
    {
      throw ProviderClientError.provider(
        "Gemini blocked the prompt (\(blockReason))."
      )
    }
    var events: [AIStreamEvent] = []
    if let candidate = (object["candidates"] as? [[String: Any]])?.first {
      let content = candidate["content"] as? [String: Any]
      let parts = content?["parts"] as? [[String: Any]] ?? []
      for text in parts.compactMap({ $0["text"] as? String }) where !text.isEmpty {
        events.append(.textDelta(text))
      }
      if let finishReason = candidate["finishReason"] as? String {
        guard finishReason == "STOP" else {
          throw ProviderClientError.provider(
            "Gemini stopped before a normal completion (\(finishReason))."
          )
        }
        events.append(.completed(responseID: nil))
      }
    }
    if let usage = object["usageMetadata"] as? [String: Any] {
      events.append(
        .usage(
          TokenUsage(
            inputTokens: usage["promptTokenCount"] as? Int,
            outputTokens: usage["candidatesTokenCount"] as? Int
          )))
    }
    return events
  }

  private static func appending(_ path: String, to baseURL: URL) throws -> URL {
    let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: "\(base)/\(path)") else {
      throw ProviderClientError.invalidEndpoint
    }
    return url
  }

  private static func normalizedGeminiModelIdentifier(_ identifier: String) -> String {
    identifier.hasPrefix("models/") ? String(identifier.dropFirst("models/".count)) : identifier
  }

  /// Gemini's `generateContent` capability also covers media generation and specialized agents.
  /// The chat adapter sends text and expects text; retain text Gemini/Gemma families (including
  /// legacy aliases) while excluding documented families requiring a different request or output.
  private static func isGeminiTextChatModelIdentifier(_ identifier: String) -> Bool {
    let normalized = identifier.lowercased()
    guard normalized.hasPrefix("gemini-") || normalized.hasPrefix("gemma-") else { return false }
    let specializedTokens: Set<String> = [
      "image", "tts", "live", "audio", "transcribe", "transcription", "robotics", "omni",
      "embedding", "embeddings",
    ]
    let tokens = Set(normalized.split(separator: "-").map(String.init))
    guard tokens.isDisjoint(with: specializedTokens) else { return false }
    return !normalized.contains("computer-use") && !normalized.contains("deep-research")
  }

  private static func encodedPathSegment(_ value: String) throws -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#")
    guard !value.isEmpty,
      let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
      !encoded.isEmpty
    else {
      throw ProviderClientError.missingModelIdentifier
    }
    return encoded
  }

  private static func replacingPath(of baseURL: URL, with path: String) throws -> URL {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw ProviderClientError.invalidEndpoint
    }
    components.path = path
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { throw ProviderClientError.invalidEndpoint }
    return url
  }

  private static func decodeIndexedEmbeddingRecords(
    _ records: [[String: Any]],
    indexKey: String,
    expectedCount: Int
  ) throws -> [[Float]] {
    var vectors = [[Float]?](repeating: nil, count: expectedCount)
    for record in records {
      guard let index = record[indexKey] as? Int,
        (0..<expectedCount).contains(index),
        vectors[index] == nil,
        let rawVector = record["embedding"] as? [NSNumber]
      else {
        throw ProviderClientError.invalidResponse
      }
      vectors[index] = try validatedEmbeddingVector(rawVector)
    }
    let decoded = vectors.compactMap { $0 }
    guard decoded.count == expectedCount else {
      throw ProviderClientError.invalidResponse
    }
    return try validatedEmbeddingDimensions(decoded)
  }

  private static func validatedEmbeddingVector(_ rawVector: [NSNumber]) throws -> [Float] {
    guard !rawVector.isEmpty else { throw ProviderClientError.invalidResponse }
    guard rawVector.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() }) else {
      throw ProviderClientError.invalidResponse
    }
    let vector = rawVector.map(\.floatValue)
    guard vector.allSatisfy(\.isFinite) else {
      throw ProviderClientError.invalidResponse
    }
    return vector
  }

  private static func validatedEmbeddingDimensions(_ vectors: [[Float]]) throws -> [[Float]] {
    guard let dimensions = vectors.first?.count,
      dimensions > 0,
      vectors.allSatisfy({ $0.count == dimensions })
    else {
      throw ProviderClientError.invalidResponse
    }
    return vectors
  }

  private static func supportsQwenRetrievalInstruction(_ modelIdentifier: String) -> Bool {
    let model = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return model == "qwen3.7-text-embedding" || model == "text-embedding-v4"
  }

  private static func supportsQwenDenseOutputType(_ modelIdentifier: String) -> Bool {
    let model = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return ["qwen3.7-text-embedding", "text-embedding-v3", "text-embedding-v4"].contains(
      model
    )
  }

  private static func nvidiaModelAcceptsInputType(_ modelIdentifier: String) -> Bool {
    let model = modelIdentifier.lowercased()
    let pathComponent = model.split(separator: "/").last.map(String.init) ?? model
    let tokens = pathComponent.split(whereSeparator: { $0 == "-" || $0 == "_" })
    return !tokens.contains("gte") && !tokens.contains("gtr")
  }

  private static func isOfficialQwenCompatibleEndpoint(_ url: URL) -> Bool {
    var path = url.path(percentEncoded: true)
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    guard url.scheme?.lowercased() == "https",
      let host = url.host?.lowercased(),
      url.port == nil || url.port == 443,
      path == "/compatible-mode/v1"
    else {
      return false
    }

    let sharedDomains: Set<String> = [
      "dashscope.aliyuncs.com",
      "dashscope-intl.aliyuncs.com",
      "dashscope-us.aliyuncs.com",
      "cn-hongkong.dashscope.aliyuncs.com",
    ]
    return sharedDomains.contains(host) || host.hasSuffix(".maas.aliyuncs.com")
  }

  private static func modelCatalogEndpoint(
    connection: ProviderConnection,
    baseURL: URL
  ) throws -> URL {
    switch connection.provider.modelCatalogKind {
    case .xAI:
      return try appending("language-models", to: baseURL)
    case .deepInfra:
      guard
        isExactOfficialEndpoint(
          baseURL,
          host: "api.deepinfra.com",
          percentEncodedPath: "/v1/openai"
        )
      else {
        return try appending("models", to: baseURL)
      }
      guard let url = URL(string: "https://api.deepinfra.com/v1/models") else {
        throw ProviderClientError.invalidEndpoint
      }
      return url
    case .fireworks:
      guard
        isExactOfficialEndpoint(
          baseURL,
          host: "api.fireworks.ai",
          percentEncodedPath: "/inference/v1"
        )
      else {
        return try appending("models", to: baseURL)
      }
      guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
        throw ProviderClientError.invalidEndpoint
      }
      components.path = "/v1/accounts/fireworks/models"
      components.queryItems = [
        URLQueryItem(name: "filter", value: "supports_serverless=true")
      ]
      guard let url = components.url else { throw ProviderClientError.invalidEndpoint }
      return url
    case .cohere:
      guard
        isExactOfficialEndpoint(
          baseURL,
          host: "api.cohere.ai",
          percentEncodedPath: "/compatibility/v1"
        )
      else {
        return try appending("models", to: baseURL)
      }
      guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
        throw ProviderClientError.invalidEndpoint
      }
      components.path = "/v1/models"
      components.queryItems = [URLQueryItem(name: "endpoint", value: "chat")]
      guard let url = components.url else { throw ProviderClientError.invalidEndpoint }
      return url
    case .aimlAPI:
      guard
        isExactOfficialEndpoint(
          baseURL,
          host: "api.aimlapi.com",
          percentEncodedPath: "/v1"
        )
      else {
        return try appending("models", to: baseURL)
      }
      guard let url = URL(string: "https://api.aimlapi.com/models") else {
        throw ProviderClientError.invalidEndpoint
      }
      return url
    case .siliconFlow:
      let rawURL = try appending("models", to: baseURL)
      guard var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) else {
        throw ProviderClientError.invalidEndpoint
      }
      components.queryItems = [URLQueryItem(name: "sub_type", value: "chat")]
      guard let url = components.url else { throw ProviderClientError.invalidEndpoint }
      return url
    case .lmStudio:
      var path = baseURL.path(percentEncoded: true)
      while path.count > 1, path.hasSuffix("/") { path.removeLast() }
      guard path == "/v1" else {
        throw ProviderClientError.modelCatalogUnavailable
      }
      return try replacingPath(of: baseURL, with: "/api/v1/models")
    case .unavailable:
      throw ProviderClientError.modelCatalogUnavailable
    case .standard, .architectureTextOutput, .topLevelTextOutput, .openRouter, .topLevelArray,
      .anthropic, .gemini, .mistral, .tinfoil, .featherless, .vercel, .tencentTokenHub,
      .baiduQianfan, .poe:
      return try appending("models", to: baseURL)
    }
  }

  private static func modelCatalogPageURL(
    endpoint: URL,
    provider: ProviderKind,
    cursor: String?
  ) throws -> URL {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw ProviderClientError.invalidEndpoint
    }

    var queryItems = components.queryItems ?? []
    switch provider.modelCatalogKind {
    case .anthropic:
      queryItems.append(URLQueryItem(name: "limit", value: "1000"))
      if let cursor = try validatedPaginationCursor(cursor) {
        queryItems.append(URLQueryItem(name: "after_id", value: cursor))
      }
    case .gemini:
      queryItems.append(URLQueryItem(name: "pageSize", value: "1000"))
      if let cursor = try validatedPaginationCursor(cursor) {
        queryItems.append(URLQueryItem(name: "pageToken", value: cursor))
      }
    case .fireworks:
      queryItems.append(URLQueryItem(name: "pageSize", value: "200"))
      if let cursor = try validatedPaginationCursor(cursor) {
        queryItems.append(URLQueryItem(name: "pageToken", value: cursor))
      }
    case .cohere:
      queryItems.append(URLQueryItem(name: "page_size", value: "1000"))
      if let cursor = try validatedPaginationCursor(cursor) {
        queryItems.append(URLQueryItem(name: "page_token", value: cursor))
      }
    case .featherless:
      queryItems.append(URLQueryItem(name: "conversational", value: "true"))
      queryItems.append(URLQueryItem(name: "available_on_current_plan", value: "true"))
      queryItems.append(
        URLQueryItem(name: "page", value: String(try validatedPageNumber(cursor))))
      queryItems.append(URLQueryItem(name: "per_page", value: "1000"))
    case .openRouter:
      queryItems.append(URLQueryItem(name: "output_modalities", value: "text"))
      guard cursor == nil else { throw ProviderClientError.invalidResponse }
    case .standard, .architectureTextOutput, .topLevelTextOutput, .topLevelArray, .xAI,
      .mistral, .deepInfra, .tinfoil, .aimlAPI, .siliconFlow, .vercel, .tencentTokenHub,
      .baiduQianfan, .poe, .lmStudio, .unavailable:
      guard cursor == nil else { throw ProviderClientError.invalidResponse }
    }

    components.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = components.url else { throw ProviderClientError.invalidEndpoint }
    return url
  }

  private static func paginationCursor(
    in object: [String: Any],
    key: String
  ) throws -> String? {
    guard let rawCursor = object[key] else { return nil }
    if rawCursor is NSNull { return nil }
    guard let cursor = rawCursor as? String else {
      throw ProviderClientError.invalidResponse
    }
    return try validatedPaginationCursor(cursor)
  }

  private static func validatedPageNumber(_ cursor: String?) throws -> Int {
    guard let cursor = try validatedPaginationCursor(cursor) else { return 1 }
    guard let page = Int(cursor), page >= 1, String(page) == cursor else {
      throw ProviderClientError.invalidResponse
    }
    return page
  }

  /// TokenHub's OpenAI-compatible catalog does not expose a modality field. Keep model discovery
  /// on the documented language and text-output understanding families instead of guessing from
  /// the absence of image/video words, which could expose a non-chat model in the chat picker.
  private static func isTencentTextChatModelIdentifier(_ identifier: String) -> Bool {
    let normalized = identifier.lowercased()
    let exactIdentifiers: Set<String> = [
      "hy3",
      "hy3-preview",
      "hy4-preview",
      "hy-role",
      "hunyuan-role-latest",
      "tc-code-latest",
      "youtu-vita",
    ]
    if exactIdentifiers.contains(normalized) { return true }

    let documentedFamilyPrefixes = [
      "hy3-",
      "hy4-",
      "hy-mt2-",
      "deepseek-",
      "deepseek/",
      "glm-",
      "kimi-",
      "qwen3.5-",
      "hy-vision-",
      "hunyuan-t1-vision-",
      "hunyuan-turbos-vision-video-",
    ]
    if documentedFamilyPrefixes.contains(where: { normalized.hasPrefix($0) }) {
      return true
    }

    // MiniMax language IDs use M followed by a numeric generation (for example M2.7 or M-3-0).
    // Requiring that numeric boundary prevents a future `minimax-music-*` ID from leaking in.
    let miniMaxPrefix = "minimax-m"
    guard normalized.hasPrefix(miniMaxPrefix) else { return false }
    let suffix = normalized.dropFirst(miniMaxPrefix.count)
    if suffix.first?.isNumber == true { return true }
    return suffix.first == "-" && suffix.dropFirst().first?.isNumber == true
  }

  /// Qianfan marks text-output foundation models as `chat`, `multimodal`, or `image2text`.
  /// Ambiguous multimodal records must explicitly advertise text output. If a chat/image2text
  /// record supplies output metadata, a contradictory non-text value is rejected as well.
  private static func isBaiduTextChatModel(_ record: [String: Any]) -> Bool {
    guard let type = (record["type"] as? String)?.lowercased() else { return false }
    var outputModalities: [String]?
    if let rawArchitecture = record["architecture"] {
      guard let architecture = rawArchitecture as? [String: Any] else { return false }
      if let rawOutputModalities = architecture["output_modalities"] {
        guard let decodedOutputModalities = rawOutputModalities as? [String] else { return false }
        outputModalities = decodedOutputModalities
      }
    }
    let explicitlyOutputsText =
      outputModalities?.contains {
        $0.lowercased() == "text"
      } == true

    switch type {
    case "chat", "image2text":
      return outputModalities == nil || explicitlyOutputsText
    case "multimodal":
      return explicitlyOutputsText
    default:
      return false
    }
  }

  private static func validatedPaginationCursor(_ cursor: String?) throws -> String? {
    guard let cursor else { return nil }
    guard !cursor.isEmpty else { return nil }
    guard cursor.utf8.count <= 4_096 else {
      throw ProviderClientError.responseTooLarge
    }
    return cursor
  }

  private static func isExactOfficialEndpoint(
    _ url: URL,
    host: String,
    percentEncodedPath: String
  ) -> Bool {
    var path = url.path(percentEncoded: true)
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return url.scheme?.lowercased() == "https"
      && url.host?.lowercased() == host
      && (url.port == nil || url.port == 443)
      && path == percentEncodedPath
  }

  private static func isExactPublicAIMLCatalogRequest(_ url: URL) -> Bool {
    isExactOfficialEndpoint(
      url,
      host: "api.aimlapi.com",
      percentEncodedPath: "/models"
    )
      && url.user == nil
      && url.password == nil
      && url.query == nil
      && url.fragment == nil
  }

  static func validate(baseURL: URL) throws {
    guard baseURL.user == nil,
      baseURL.password == nil,
      baseURL.query == nil,
      baseURL.fragment == nil,
      let scheme = baseURL.scheme?.lowercased(),
      let host = baseURL.host?.lowercased()
    else {
      throw ProviderClientError.invalidEndpoint
    }
    if scheme == "https" { return }
    guard scheme == "http", isLocalHost(host) else {
      throw ProviderClientError.insecureEndpoint
    }
  }

  static func isLocalHost(_ rawHost: String) -> Bool {
    let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host == "localhost" || host == "::1" || (host != ".local" && host.hasSuffix(".local")) {
      return true
    }

    let components = host.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 4 else { return false }
    let octets = components.compactMap { component -> Int? in
      guard !component.isEmpty,
        component.allSatisfy(\.isNumber),
        let value = Int(component),
        (0...255).contains(value),
        component == Substring(String(value))
      else {
        return nil
      }
      return value
    }
    guard octets.count == 4 else { return false }
    return octets[0] == 10
      || (octets[0] == 172 && (16...31).contains(octets[1]))
      || (octets[0] == 192 && octets[1] == 168)
      || (octets[0] == 127)
  }
}

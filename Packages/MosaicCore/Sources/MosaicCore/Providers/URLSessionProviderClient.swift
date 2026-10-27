import Foundation

struct ProviderModelCatalogAccumulator {
  private static let defaultMaximumIdentifierByteCount = 1_024
  private static let defaultMaximumTotalIdentifierByteCount = 4 * 1_024 * 1_024

  private let maximumPageCount: Int
  private let maximumModelCount: Int
  private let maximumIdentifierByteCount: Int
  private let maximumTotalIdentifierByteCount: Int

  private var pageCount = 0
  private var seenCursors = Set<String>()
  private var identifiers = Set<String>()
  private var totalIdentifierByteCount = 0

  init(
    maximumPageCount: Int,
    maximumModelCount: Int,
    maximumIdentifierByteCount: Int = Self.defaultMaximumIdentifierByteCount,
    maximumTotalIdentifierByteCount: Int = Self.defaultMaximumTotalIdentifierByteCount
  ) {
    self.maximumPageCount = maximumPageCount
    self.maximumModelCount = maximumModelCount
    self.maximumIdentifierByteCount = maximumIdentifierByteCount
    self.maximumTotalIdentifierByteCount = maximumTotalIdentifierByteCount
  }

  var modelIdentifiers: [String] {
    identifiers.sorted()
  }

  mutating func consume(_ page: ProviderModelCatalogPage) throws -> String? {
    let (nextPageCount, overflow) = pageCount.addingReportingOverflow(1)
    guard !overflow, nextPageCount <= maximumPageCount else {
      throw ProviderClientError.responseTooLarge
    }

    var nextIdentifiers = identifiers
    var nextTotalIdentifierByteCount = totalIdentifierByteCount
    for identifier in page.modelIdentifiers {
      guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProviderClientError.invalidResponse
      }
      guard identifier.utf8.count <= maximumIdentifierByteCount else {
        throw ProviderClientError.responseTooLarge
      }
      let containsControlCharacter = identifier.unicodeScalars.contains {
        $0.properties.generalCategory == .control
      }
      guard !containsControlCharacter
      else {
        throw ProviderClientError.invalidResponse
      }
      guard nextIdentifiers.insert(identifier).inserted else { continue }
      guard nextIdentifiers.count <= maximumModelCount else {
        throw ProviderClientError.responseTooLarge
      }
      let (updatedTotal, totalOverflow) =
        nextTotalIdentifierByteCount.addingReportingOverflow(identifier.utf8.count)
      guard !totalOverflow, updatedTotal <= maximumTotalIdentifierByteCount else {
        throw ProviderClientError.responseTooLarge
      }
      nextTotalIdentifierByteCount = updatedTotal
    }

    var nextSeenCursors = seenCursors
    if let nextCursor = page.nextCursor {
      guard nextPageCount < maximumPageCount else {
        throw ProviderClientError.responseTooLarge
      }
      guard nextSeenCursors.insert(nextCursor).inserted else {
        throw ProviderClientError.invalidResponse
      }
    }

    pageCount = nextPageCount
    identifiers = nextIdentifiers
    totalIdentifierByteCount = nextTotalIdentifierByteCount
    seenCursors = nextSeenCursors
    return page.nextCursor
  }
}

struct ProviderStreamEventBuffer {
  typealias Stream = AsyncThrowingStream<AIStreamEvent, Error>

  static func makeStream() -> (
    stream: Stream,
    continuation: Stream.Continuation
  ) {
    Stream.makeStream(bufferingPolicy: .unbounded)
  }
}

/// Bounds the payload retained by an unconsumed stream without imposing a tiny event-count limit.
/// Providers commonly send one SSE event per token, so 256 valid deltas is far below a modern
/// model's output range. Text is instead bounded by Mosaic's persisted message limit, while
/// non-text bookkeeping events have their own defensive cap.
struct ProviderStreamEventBudget {
  private static let maximumControlEventCount = 4_096

  private var textByteCount = 0
  private var controlEventCount = 0

  mutating func validated(_ events: [AIStreamEvent]) throws -> [AIStreamEvent] {
    var accepted: [AIStreamEvent] = []
    accepted.reserveCapacity(events.count)
    for event in events {
      switch event {
      case .textDelta(let text):
        guard !text.isEmpty else { continue }
        let (nextCount, overflow) = textByteCount.addingReportingOverflow(text.utf8.count)
        guard
          !overflow,
          nextCount <= MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes
        else {
          throw ProviderClientError.responseTooLarge
        }
        textByteCount = nextCount
      case .citations(let sources):
        guard sources.count <= 100, sources.allSatisfy(\.isValid) else {
          throw ProviderClientError.responseTooLarge
        }
        controlEventCount += max(1, sources.count)
        guard controlEventCount <= Self.maximumControlEventCount else {
          throw ProviderClientError.responseTooLarge
        }
      case .usage, .completed:
        let (nextCount, overflow) = controlEventCount.addingReportingOverflow(1)
        guard !overflow, nextCount <= Self.maximumControlEventCount else {
          throw ProviderClientError.responseTooLarge
        }
        controlEventCount = nextCount
      }
      accepted.append(event)
    }
    return accepted
  }
}

/// Gemini may attach cumulative usage metadata to every streamed chunk. Holding only the newest
/// counters until completion keeps a valid long response from filling the control-event budget,
/// while still delivering the final accounting before the terminal event.
struct ProviderStreamUsageCoalescer {
  private let coalescesIntermediateUsage: Bool
  private var pendingUsage: TokenUsage?

  init(dialect: ProviderDialect) {
    coalescesIntermediateUsage = dialect == .gemini
  }

  mutating func consume(_ events: [AIStreamEvent]) -> [AIStreamEvent] {
    guard coalescesIntermediateUsage else { return events }

    var output: [AIStreamEvent] = []
    output.reserveCapacity(events.count)
    var receivedCompletion = false
    var completionResponseID: String?
    for event in events {
      switch event {
      case .textDelta, .citations:
        output.append(event)
      case .usage(let usage):
        pendingUsage = TokenUsage(
          inputTokens: usage.inputTokens ?? pendingUsage?.inputTokens,
          outputTokens: usage.outputTokens ?? pendingUsage?.outputTokens
        )
      case .completed(let responseID):
        receivedCompletion = true
        completionResponseID = responseID ?? completionResponseID
      }
    }

    if receivedCompletion {
      if let pendingUsage {
        output.append(.usage(pendingUsage))
      }
      output.append(.completed(responseID: completionResponseID))
      pendingUsage = nil
    }
    return output
  }

  mutating func finishAtEOF() -> [AIStreamEvent] {
    guard coalescesIntermediateUsage, let pendingUsage else { return [] }
    self.pendingUsage = nil
    return [.usage(pendingUsage)]
  }
}

/// Some OpenAI-compatible endpoints omit the `[DONE]` sentinel and signal success only through
/// `finish_reason`. Defer that completion until an explicit sentinel or clean EOF so a trailing
/// usage-only chunk is not lost.
struct ProviderStreamCompletionCoordinator {
  private let dialect: ProviderDialect
  private var hasPendingChatCompletion = false
  private var pendingResponseID: String?

  init(dialect: ProviderDialect) {
    self.dialect = dialect
  }

  mutating func consume(
    _ events: [AIStreamEvent],
    isExplicitEndMarker: Bool
  ) -> [AIStreamEvent] {
    guard dialect == .openAIChatCompletions else { return events }

    var output: [AIStreamEvent] = []
    output.reserveCapacity(events.count)
    var explicitResponseID: String?
    for event in events {
      if case .completed(let responseID) = event {
        if isExplicitEndMarker {
          explicitResponseID = responseID
        } else {
          hasPendingChatCompletion = true
          pendingResponseID = responseID ?? pendingResponseID
        }
      } else {
        output.append(event)
      }
    }

    if isExplicitEndMarker {
      output.append(.completed(responseID: pendingResponseID ?? explicitResponseID))
      hasPendingChatCompletion = false
      pendingResponseID = nil
    }
    return output
  }

  mutating func finishAtEOF() -> [AIStreamEvent] {
    guard dialect == .openAIChatCompletions, hasPendingChatCompletion else { return [] }
    defer {
      hasPendingChatCompletion = false
      pendingResponseID = nil
    }
    return [.completed(responseID: pendingResponseID)]
  }
}

final class URLSessionProviderClient: AIProviderClient, @unchecked Sendable {
  private static let modelCatalogLimit = 4 * 1_024 * 1_024
  private static let modelCatalogPageLimit = 50
  private static let modelCatalogModelLimit = 10_000
  private static let errorBodyLimit = 16 * 1_024
  private let connection: ProviderConnection

  init(connection: ProviderConnection) {
    self.connection = connection
  }

  func listModels() async throws -> [String] {
    let session = makeSession(streaming: false)
    defer { session.invalidateAndCancel() }

    var cursor: String?
    var accumulator = ProviderModelCatalogAccumulator(
      maximumPageCount: Self.modelCatalogPageLimit,
      maximumModelCount: Self.modelCatalogModelLimit
    )

    while true {
      try Task.checkCancellation()
      let request = try ProviderWireProtocol.modelsRequest(
        connection: connection,
        cursor: cursor
      )
      let (bytes, response) = try await session.bytes(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw ProviderClientError.invalidResponse
      }
      let succeeded = (200..<300).contains(httpResponse.statusCode)
      let data = try await collect(
        bytes,
        limit: succeeded ? Self.modelCatalogLimit : Self.errorBodyLimit,
        truncating: !succeeded
      )
      try validate(response: response, data: data)

      let page = try ProviderWireProtocol.decodeModelPage(
        data: data,
        provider: connection.provider
      )
      guard let nextCursor = try accumulator.consume(page) else {
        return accumulator.modelIdentifiers
      }
      cursor = nextCursor
    }
  }

  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    let pair = ProviderStreamEventBuffer.makeStream()
    let task = Task {
      let session = makeSession(streaming: true)
      defer { session.invalidateAndCancel() }
      do {
        let urlRequest = try ProviderWireProtocol.streamingRequest(
          connection: connection,
          chatRequest: request
        )
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
          throw ProviderClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
          let errorData = try await collect(
            bytes,
            limit: Self.errorBodyLimit,
            truncating: true
          )
          let errorBody = String(data: errorData, encoding: .utf8) ?? ""
          throw ProviderClientError.httpStatus(
            httpResponse.statusCode,
            ProviderErrorSanitizer.bodyMessage(
              from: errorBody,
              redacting: connection.apiKey
            )
          )
        }

        var decoder = BoundedSSEStreamDecoder()
        var eventNormalizer = ProviderStreamEventNormalizer(provider: connection.provider)
        let dialect = ProviderWireProtocol.dialect(for: connection.provider)
        var completionCoordinator = ProviderStreamCompletionCoordinator(dialect: dialect)
        var usageCoalescer = ProviderStreamUsageCoalescer(dialect: dialect)
        var eventBudget = ProviderStreamEventBudget()
        for try await byte in bytes {
          try Task.checkCancellation()
          if let event = try decoder.consume(byte: byte) {
            let decoded = try eventNormalizer.normalize(
              ProviderWireProtocol.decode(event: event, dialect: dialect)
            )
            let coordinated = completionCoordinator.consume(
              decoded,
              isExplicitEndMarker: event.data == "[DONE]"
            )
            let coalesced = usageCoalescer.consume(coordinated)
            if try emit(coalesced, budget: &eventBudget, to: pair.continuation) {
              pair.continuation.finish()
              return
            }
          }
        }
        for event in try decoder.finish() {
          let decoded = try eventNormalizer.normalize(
            ProviderWireProtocol.decode(event: event, dialect: dialect)
          )
          let coordinated = completionCoordinator.consume(
            decoded,
            isExplicitEndMarker: event.data == "[DONE]"
          )
          let coalesced = usageCoalescer.consume(coordinated)
          if try emit(coalesced, budget: &eventBudget, to: pair.continuation) {
            pair.continuation.finish()
            return
          }
        }
        let completionAtEOF = usageCoalescer.consume(completionCoordinator.finishAtEOF())
        if try emit(
          completionAtEOF,
          budget: &eventBudget,
          to: pair.continuation
        ) {
          pair.continuation.finish()
          return
        }
        _ = try emit(
          usageCoalescer.finishAtEOF(),
          budget: &eventBudget,
          to: pair.continuation
        )
        pair.continuation.finish()
      } catch is CancellationError {
        pair.continuation.finish()
      } catch {
        pair.continuation.finish(throwing: sanitizedStreamError(error))
      }
    }
    pair.continuation.onTermination = { @Sendable _ in task.cancel() }
    return pair.stream
  }

  private func emit(
    _ events: [AIStreamEvent],
    budget: inout ProviderStreamEventBudget,
    to continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
  ) throws -> Bool {
    var receivedTerminalEvent = false
    for event in try budget.validated(events) {
      switch continuation.yield(event) {
      case .enqueued:
        break
      case .dropped:
        throw ProviderClientError.responseTooLarge
      case .terminated:
        throw CancellationError()
      @unknown default:
        throw ProviderClientError.invalidResponse
      }
      if case .completed = event {
        receivedTerminalEvent = true
      }
    }
    return receivedTerminalEvent
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

  private func sanitizedStreamError(_ error: Error) -> Error {
    guard let providerError = error as? ProviderClientError else { return error }
    switch providerError {
    case .provider(let message):
      return ProviderClientError.provider(
        ProviderErrorSanitizer.bodyMessage(from: message, redacting: connection.apiKey)
      )
    case .httpStatus(let status, let message):
      return ProviderClientError.httpStatus(
        status,
        ProviderErrorSanitizer.bodyMessage(from: message, redacting: connection.apiKey)
      )
    default:
      return providerError
    }
  }

  private func makeSession(streaming: Bool) -> URLSession {
    URLSession(
      configuration: Self.makeSessionConfiguration(streaming: streaming),
      delegate: RejectRedirectDelegate.shared,
      delegateQueue: nil
    )
  }

  static func makeSessionConfiguration(streaming: Bool) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest =
      streaming ? ProviderNetworkTimeoutPolicy.streamingRequestIdle : 120
    configuration.timeoutIntervalForResource =
      streaming ? ProviderNetworkTimeoutPolicy.streamingResource : 300
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return configuration
  }

  private func validate(response: URLResponse, data: Data) throws {
    guard let response = response as? HTTPURLResponse else {
      throw ProviderClientError.invalidResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      let raw = String(data: data.prefix(16_384), encoding: .utf8) ?? ""
      throw ProviderClientError.httpStatus(
        response.statusCode,
        ProviderErrorSanitizer.bodyMessage(from: raw, redacting: connection.apiKey)
      )
    }
  }
}

struct BoundedSSEStreamDecoder {
  private static let lineLimit = 256 * 1_024
  private static let eventLimit = 1_024 * 1_024

  private var parser = SSEParser()
  private var lineBytes: [UInt8] = []
  private var eventByteCount = 0
  private var previousByteWasCarriageReturn = false

  mutating func consume(byte: UInt8) throws -> ServerSentEvent? {
    if byte == 0x0D {
      previousByteWasCarriageReturn = true
      return try consumeBufferedLine()
    }
    if byte == 0x0A {
      if previousByteWasCarriageReturn {
        previousByteWasCarriageReturn = false
        return nil
      }
      return try consumeBufferedLine()
    }
    previousByteWasCarriageReturn = false
    guard lineBytes.count < Self.lineLimit, eventByteCount < Self.eventLimit else {
      throw ProviderClientError.responseTooLarge
    }
    lineBytes.append(byte)
    eventByteCount += 1
    return nil
  }

  mutating func finish() throws -> [ServerSentEvent] {
    previousByteWasCarriageReturn = false
    var events: [ServerSentEvent] = []
    if !lineBytes.isEmpty, let event = try consumeBufferedLine() {
      events.append(event)
    }
    if let event = parser.finish() {
      events.append(event)
    }
    eventByteCount = 0
    return events
  }

  private mutating func consumeBufferedLine() throws -> ServerSentEvent? {
    guard let line = String(bytes: lineBytes, encoding: .utf8) else {
      throw ProviderClientError.invalidResponse
    }
    lineBytes.removeAll(keepingCapacity: true)
    let event = parser.consume(line: line)
    if line.isEmpty {
      eventByteCount = 0
    }
    return event
  }
}

final class RejectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  static let shared = RejectRedirectDelegate()

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

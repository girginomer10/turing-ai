import Foundation

enum LiveWebSocketMessage: Equatable, Sendable {
  case text(String)
  case data(Data)
}

enum LiveWebSocketCloseCode: Equatable, Sendable {
  case normalClosure
  case goingAway
  case policyViolation
  case messageTooBig
}

protocol LiveWebSocketConnection: Sendable {
  func resume() async
  func send(text: String) async throws
  func receive() async throws -> LiveWebSocketMessage
  func cancel(closeCode: LiveWebSocketCloseCode, reason: Data?) async
}

protocol LiveWebSocketConnecting: Sendable {
  func makeConnection(
    request: URLRequest,
    maximumMessageSize: Int
  ) async throws -> any LiveWebSocketConnection
}

/// Gemini's dedicated speech-to-text WebSocket transport. It is separate from
/// `AIProviderClient`, allowing the resulting text to be sent to any configured chat provider.
public final class GeminiLiveTranscriptionClient: LiveTranscriptionClient, @unchecked Sendable {
  private let connector: any LiveWebSocketConnecting
  private let sessionDuration: Duration
  private let finalizationTimeout: Duration
  private let setupTimeout: Duration

  public init() {
    connector = URLSessionLiveWebSocketConnector()
    sessionDuration = GeminiLiveTranscriptionWireProtocol.maximumSessionDuration
    finalizationTimeout = .seconds(12)
    setupTimeout = .seconds(30)
  }

  init(
    connector: any LiveWebSocketConnecting,
    sessionDuration: Duration = GeminiLiveTranscriptionWireProtocol.maximumSessionDuration,
    finalizationTimeout: Duration = .seconds(12),
    setupTimeout: Duration = .seconds(30)
  ) {
    self.connector = connector
    self.sessionDuration = max(
      .milliseconds(1),
      min(sessionDuration, GeminiLiveTranscriptionWireProtocol.maximumSessionDuration)
    )
    self.finalizationTimeout = max(.milliseconds(1), min(finalizationTimeout, .seconds(30)))
    self.setupTimeout = max(.milliseconds(1), min(setupTimeout, .seconds(60)))
  }

  public func connect(
    apiKey: String,
    configuration: LiveTranscriptionConfiguration
  ) async throws -> any LiveTranscriptionSession {
    do {
      let request = try GeminiLiveTranscriptionWireProtocol.webSocketRequest(apiKey: apiKey)
      let setupMessage = try GeminiLiveTranscriptionWireProtocol.setupMessage(
        configuration: configuration
      )
      let connection = try await connector.makeConnection(
        request: request,
        maximumMessageSize: GeminiLiveTranscriptionWireProtocol.maximumInboundMessageBytes
      )
      let session = GeminiLiveTranscriptionSession(
        connection: connection,
        apiKey: apiKey,
        duration: sessionDuration,
        finalizationTimeout: finalizationTimeout,
        setupTimeout: setupTimeout
      )
      try await session.start(setupMessage: setupMessage)
      return session
    } catch {
      throw Self.sanitized(error, apiKey: apiKey)
    }
  }

  fileprivate static func sanitized(_ error: Error, apiKey: String) -> Error {
    if error is CancellationError { return CancellationError() }
    if let liveError = error as? LiveTranscriptionError {
      switch liveError {
      case .invalidConfiguration(let message):
        return LiveTranscriptionError.invalidConfiguration(
          LiveTranscriptionRedactor.sanitize(message, redacting: apiKey)
        )
      case .invalidAudioChunk(let message):
        return LiveTranscriptionError.invalidAudioChunk(
          LiveTranscriptionRedactor.sanitize(message, redacting: apiKey)
        )
      case .provider(let message):
        return LiveTranscriptionError.provider(
          LiveTranscriptionRedactor.sanitize(message, redacting: apiKey)
        )
      case .transport(let message):
        return LiveTranscriptionError.transport(
          LiveTranscriptionRedactor.sanitize(message, redacting: apiKey)
        )
      default:
        return liveError
      }
    }
    return LiveTranscriptionError.transport(
      LiveTranscriptionRedactor.sanitize(error.localizedDescription, redacting: apiKey)
    )
  }
}

private actor GeminiLiveTranscriptionSession: LiveTranscriptionSession {
  private enum State: Equatable {
    case initialized
    case awaitingSetup
    case ready
    case terminal
  }

  private let connection: any LiveWebSocketConnection
  private let apiKey: String
  private let duration: Duration
  private let finalizationTimeout: Duration
  private let setupTimeout: Duration
  private let events: AsyncThrowingStream<LiveTranscriptionEvent, Error>
  private var continuation: AsyncThrowingStream<LiveTranscriptionEvent, Error>.Continuation

  private var state = State.initialized
  private var outboundOperationInFlight = false
  private var transcriptByteCount = 0
  private var receiveTask: Task<Void, Never>?
  private var deadlineTask: Task<Void, Never>?
  private var setupTimeoutTask: Task<Void, Never>?
  private var wrapUpTask: Task<Void, Never>?
  private var didReceiveGoAway = false
  private var finalTranscriptSequence: UInt64 = 0
  private var turnCompletionSequence: UInt64 = 0
  private var hasUnfinalizedInterim = false
  private var finalizationWaiters: [UUID: FinalizationWaiter] = [:]
  private var finalizationTimeoutTasks: [UUID: Task<Void, Never>] = [:]

  private struct FinalizationWaiter {
    let afterFinalTranscriptSequence: UInt64
    let afterTurnCompletionSequence: UInt64
    let continuation: CheckedContinuation<LiveTranscriptionFinalizationResult, Never>
  }

  init(
    connection: any LiveWebSocketConnection,
    apiKey: String,
    duration: Duration,
    finalizationTimeout: Duration,
    setupTimeout: Duration
  ) {
    self.connection = connection
    self.apiKey = apiKey
    self.duration = duration
    self.finalizationTimeout = finalizationTimeout
    self.setupTimeout = setupTimeout
    let pair = AsyncThrowingStream<LiveTranscriptionEvent, Error>.makeStream(
      bufferingPolicy: .bufferingOldest(
        GeminiLiveTranscriptionWireProtocol.streamBufferLimit
      )
    )
    events = pair.stream
    continuation = pair.continuation
    continuation.onTermination = { @Sendable [weak self] _ in
      Task { await self?.cancel() }
    }
  }

  func start(setupMessage: String) async throws {
    guard state == .initialized else { throw LiveTranscriptionError.sessionEnded }
    state = .awaitingSetup
    await connection.resume()
    startDeadline()

    do {
      try await connection.send(text: setupMessage)
      guard state != .terminal else { throw LiveTranscriptionError.sessionEnded }
      startSetupTimeout()
      receiveTask = Task { [weak self] in
        await self?.receiveMessages()
      }
    } catch is CancellationError {
      await terminate(endReason: .cancelled, closeCode: .goingAway)
      throw CancellationError()
    } catch {
      let safeError = GeminiLiveTranscriptionClient.sanitized(error, apiKey: apiKey)
      await terminate(throwing: safeError, closeCode: .goingAway)
      throw safeError
    }
  }

  func eventStream() async -> AsyncThrowingStream<LiveTranscriptionEvent, Error> {
    events
  }

  func send(_ chunk: LivePCM16AudioChunk) async throws {
    try validateReadyForAudio()
    try beginOutboundOperation()
    defer { outboundOperationInFlight = false }

    let message = try GeminiLiveTranscriptionWireProtocol.audioMessage(chunk: chunk)
    do {
      try await connection.send(text: message)
      guard state != .terminal else { throw LiveTranscriptionError.sessionEnded }
    } catch is CancellationError {
      await terminate(endReason: .cancelled, closeCode: .goingAway)
      throw CancellationError()
    } catch {
      let safeError = GeminiLiveTranscriptionClient.sanitized(error, apiKey: apiKey)
      await terminate(throwing: safeError, closeCode: .goingAway)
      throw safeError
    }
  }

  func endAudio() async throws -> LiveTranscriptionFinalizationResult {
    try validateReadyForAudio()
    try beginOutboundOperation()
    defer { outboundOperationInFlight = false }

    let finalTranscriptSequenceBeforeEnd = finalTranscriptSequence
    let turnCompletionSequenceBeforeEnd = turnCompletionSequence
    let message = try GeminiLiveTranscriptionWireProtocol.audioStreamEndMessage()
    do {
      try await connection.send(text: message)
      guard state != .terminal else { throw LiveTranscriptionError.sessionEnded }
      let result = await waitForFinalization(
        afterFinalTranscript: finalTranscriptSequenceBeforeEnd,
        afterTurnCompletion: turnCompletionSequenceBeforeEnd
      )
      try Task.checkCancellation()
      return result
    } catch is CancellationError {
      await terminate(endReason: .cancelled, closeCode: .goingAway)
      throw CancellationError()
    } catch {
      let safeError = GeminiLiveTranscriptionClient.sanitized(error, apiKey: apiKey)
      await terminate(throwing: safeError, closeCode: .goingAway)
      throw safeError
    }
  }

  func cancel() async {
    await terminate(endReason: .cancelled, closeCode: .normalClosure)
  }

  private func validateReadyForAudio() throws {
    switch state {
    case .initialized, .awaitingSetup:
      throw LiveTranscriptionError.setupNotComplete
    case .ready:
      return
    case .terminal:
      throw LiveTranscriptionError.sessionEnded
    }
  }

  private func beginOutboundOperation() throws {
    guard !outboundOperationInFlight else { throw LiveTranscriptionError.backpressure }
    outboundOperationInFlight = true
  }

  private func receiveMessages() async {
    do {
      while state != .terminal {
        try Task.checkCancellation()
        let message: LiveWebSocketMessage
        do {
          message = try await connection.receive()
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          if didReceiveGoAway {
            await terminate(closeCode: .normalClosure)
            return
          }
          throw error
        }
        guard state != .terminal else { return }
        let decoded = try GeminiLiveTranscriptionWireProtocol.decodeServerMessage(
          message,
          redacting: apiKey
        )
        try consume(decoded)
      }
    } catch is CancellationError {
      if state != .terminal {
        await terminate(endReason: .cancelled, closeCode: .goingAway)
      }
    } catch {
      guard state != .terminal else { return }
      let safeError = GeminiLiveTranscriptionClient.sanitized(error, apiKey: apiKey)
      await terminate(throwing: safeError, closeCode: closeCode(for: safeError))
    }
  }

  private func consume(_ decoded: [LiveTranscriptionEvent]) throws {
    for event in decoded {
      switch event {
      case .setupComplete:
        guard state == .awaitingSetup else {
          throw LiveTranscriptionError.invalidResponse
        }
        state = .ready
        setupTimeoutTask?.cancel()
        setupTimeoutTask = nil
      case .interimTranscript(let text, _), .finalTranscript(let text, _):
        guard state == .ready else { throw LiveTranscriptionError.invalidResponse }
        let (nextByteCount, overflow) = transcriptByteCount.addingReportingOverflow(text.utf8.count)
        guard
          !overflow,
          nextByteCount
            <= GeminiLiveTranscriptionWireProtocol.maximumTotalTranscriptBytes
        else {
          throw LiveTranscriptionError.responseTooLarge
        }
        transcriptByteCount = nextByteCount
        if case .interimTranscript = event {
          hasUnfinalizedInterim = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
          hasUnfinalizedInterim = false
          finalTranscriptSequence &+= 1
          resumeSatisfiedFinalizationWaiters()
        }
      case .turnComplete:
        guard state == .ready else { throw LiveTranscriptionError.invalidResponse }
        turnCompletionSequence &+= 1
      case .durationLimitApproaching:
        guard state == .ready else { throw LiveTranscriptionError.invalidResponse }
      case .goAway:
        guard state == .ready else { throw LiveTranscriptionError.invalidResponse }
        didReceiveGoAway = true
      case .ended:
        throw LiveTranscriptionError.invalidResponse
      }
      try emit(event)
    }
  }

  private func emit(_ event: LiveTranscriptionEvent) throws {
    switch continuation.yield(event) {
    case .enqueued:
      return
    case .dropped:
      throw LiveTranscriptionError.backpressure
    case .terminated:
      throw CancellationError()
    @unknown default:
      throw LiveTranscriptionError.invalidResponse
    }
  }

  private func startDeadline() {
    let duration = duration
    if duration > .seconds(15) {
      let warningDelay = duration - .seconds(15)
      wrapUpTask = Task { [weak self] in
        do {
          try await Task.sleep(for: warningDelay)
        } catch {
          return
        }
        await self?.announceDurationLimitApproaching()
      }
    }
    deadlineTask = Task { [weak self] in
      do {
        try await Task.sleep(for: duration)
      } catch {
        return
      }
      await self?.expire()
    }
  }

  private func startSetupTimeout() {
    let timeout = setupTimeout
    setupTimeoutTask = Task { [weak self] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      await self?.expireSetup()
    }
  }

  private func expireSetup() async {
    guard state == .awaitingSetup else { return }
    await terminate(throwing: LiveTranscriptionError.setupTimedOut, closeCode: .goingAway)
  }

  private func announceDurationLimitApproaching() {
    guard state == .ready else { return }
    do {
      try emit(.durationLimitApproaching(timeLeftSeconds: 15))
    } catch {
      Task { await terminate(throwing: error, closeCode: closeCode(for: error)) }
    }
  }

  private func waitForFinalization(
    afterFinalTranscript finalSequence: UInt64,
    afterTurnCompletion turnSequence: UInt64
  ) async -> LiveTranscriptionFinalizationResult {
    if finalTranscriptSequence > finalSequence { return .finalTranscriptReceived }
    let waiterID = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if finalTranscriptSequence > finalSequence {
          continuation.resume(returning: .finalTranscriptReceived)
          return
        }
        guard state != .terminal else {
          continuation.resume(
            returning: finalizationResultAtTimeout(afterTurnCompletion: turnSequence)
          )
          return
        }
        finalizationWaiters[waiterID] = FinalizationWaiter(
          afterFinalTranscriptSequence: finalSequence,
          afterTurnCompletionSequence: turnSequence,
          continuation: continuation
        )
        let timeout = finalizationTimeout
        finalizationTimeoutTasks[waiterID] = Task { [weak self] in
          do {
            try await Task.sleep(for: timeout)
          } catch {
            return
          }
          await self?.completeTimedOutFinalizationWaiter(waiterID)
        }
      }
    } onCancel: {
      Task { [weak self] in
        await self?.completeTimedOutFinalizationWaiter(waiterID)
      }
    }
  }

  private func resumeSatisfiedFinalizationWaiters() {
    let satisfied = finalizationWaiters.compactMap { waiterID, waiter in
      if finalTranscriptSequence > waiter.afterFinalTranscriptSequence {
        return (waiterID, LiveTranscriptionFinalizationResult.finalTranscriptReceived)
      }
      return nil
    }
    for (waiterID, result) in satisfied {
      completeFinalizationWaiter(waiterID, result: result)
    }
  }

  private func completeTimedOutFinalizationWaiter(_ waiterID: UUID) {
    guard let waiter = finalizationWaiters[waiterID] else { return }
    completeFinalizationWaiter(
      waiterID,
      result: finalizationResultAtTimeout(
        afterTurnCompletion: waiter.afterTurnCompletionSequence
      )
    )
  }

  private func finalizationResultAtTimeout(
    afterTurnCompletion turnSequence: UInt64
  ) -> LiveTranscriptionFinalizationResult {
    if hasUnfinalizedInterim { return .timedOut }
    if turnCompletionSequence > turnSequence { return .turnCompleted }
    return .nothingPending
  }

  private func completeFinalizationWaiter(
    _ waiterID: UUID,
    result: LiveTranscriptionFinalizationResult
  ) {
    finalizationTimeoutTasks.removeValue(forKey: waiterID)?.cancel()
    finalizationWaiters.removeValue(forKey: waiterID)?.continuation.resume(returning: result)
  }

  private func expire() async {
    guard state != .terminal else { return }
    await terminate(endReason: .durationLimitReached, closeCode: .normalClosure)
  }

  private func closeCode(for error: Error) -> LiveWebSocketCloseCode {
    guard let liveError = error as? LiveTranscriptionError else { return .goingAway }
    return switch liveError {
    case .responseTooLarge:
      .messageTooBig
    case .invalidResponse, .provider:
      .policyViolation
    default:
      .goingAway
    }
  }

  private func terminate(
    throwing error: Error? = nil,
    endReason: LiveTranscriptionEndReason? = nil,
    closeCode: LiveWebSocketCloseCode
  ) async {
    guard state != .terminal else { return }
    state = .terminal
    receiveTask?.cancel()
    deadlineTask?.cancel()
    setupTimeoutTask?.cancel()
    wrapUpTask?.cancel()
    receiveTask = nil
    deadlineTask = nil
    setupTimeoutTask = nil
    wrapUpTask = nil
    for waiterID in Array(finalizationWaiters.keys) {
      completeTimedOutFinalizationWaiter(waiterID)
    }
    await connection.cancel(
      closeCode: closeCode,
      reason: Data("Turing AI live transcription ended".utf8)
    )
    if let endReason {
      _ = continuation.yield(.ended(reason: endReason))
    }
    if let error {
      continuation.finish(throwing: error)
    } else {
      continuation.finish()
    }
  }
}

private final class URLSessionLiveWebSocketConnector: LiveWebSocketConnecting,
  @unchecked Sendable
{
  func makeConnection(
    request: URLRequest,
    maximumMessageSize: Int
  ) async throws -> any LiveWebSocketConnection {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 610
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    let session = URLSession(
      configuration: configuration,
      delegate: RejectRedirectDelegate.shared,
      delegateQueue: nil
    )
    let task = session.webSocketTask(with: request)
    task.maximumMessageSize = maximumMessageSize
    return URLSessionLiveWebSocketConnection(session: session, task: task)
  }
}

private final class URLSessionLiveWebSocketConnection: LiveWebSocketConnection,
  @unchecked Sendable
{
  private let session: URLSession
  private let task: URLSessionWebSocketTask

  init(session: URLSession, task: URLSessionWebSocketTask) {
    self.session = session
    self.task = task
  }

  deinit {
    task.cancel(with: .goingAway, reason: nil)
    session.invalidateAndCancel()
  }

  func resume() async {
    task.resume()
  }

  func send(text: String) async throws {
    try await task.send(.string(text))
  }

  func receive() async throws -> LiveWebSocketMessage {
    switch try await task.receive() {
    case .string(let text):
      return .text(text)
    case .data(let data):
      return .data(data)
    @unknown default:
      throw LiveTranscriptionError.invalidResponse
    }
  }

  func cancel(closeCode: LiveWebSocketCloseCode, reason: Data?) async {
    let urlSessionCode: URLSessionWebSocketTask.CloseCode
    switch closeCode {
    case .normalClosure:
      urlSessionCode = .normalClosure
    case .goingAway:
      urlSessionCode = .goingAway
    case .policyViolation:
      urlSessionCode = .policyViolation
    case .messageTooBig:
      urlSessionCode = .messageTooBig
    }
    task.cancel(with: urlSessionCode, reason: reason)
    session.invalidateAndCancel()
  }
}

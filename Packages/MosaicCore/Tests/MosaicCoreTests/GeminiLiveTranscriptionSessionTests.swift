import Foundation
import Testing

@testable import MosaicCore

struct GeminiLiveTranscriptionSessionTests {
  @Test
  func setupIsTheFirstFrameAndAudioWaitsForSetupComplete() async throws {
    let harness = makeHarness()
    let session = try await harness.client.connect(
      apiKey: "test-key",
      configuration: LiveTranscriptionConfiguration()
    )
    let stream = await session.eventStream()
    var iterator = stream.makeAsyncIterator()
    let chunk = try LivePCM16AudioChunk(data: Data([0x00, 0x00]))

    let initialMessages = await harness.connection.sentMessages()
    #expect(initialMessages.count == 1)
    #expect(initialMessages.first?.contains("\"setup\"") == true)
    await expectLiveError(.setupNotComplete) {
      try await session.send(chunk)
    }

    await harness.connection.enqueue(.text(#"{"setupComplete":{}}"#))
    #expect(try await iterator.next() == .setupComplete)
    try await session.send(chunk)
    let finalization = Task { try await session.endAudio() }
    await harness.connection.waitUntilSentMessageCount(3)
    await harness.connection.enqueue(
      .text(#"{"serverContent":{"inputTranscription":{"text":"done"}}}"#)
    )
    #expect(try await iterator.next() == .finalTranscript(text: "done", languageCode: nil))
    #expect(try await finalization.value == .finalTranscriptReceived)

    let messages = await harness.connection.sentMessages()
    #expect(messages.count == 3)
    #expect(messages[1].contains("\"audio\"") == true)
    #expect(messages[2].contains("\"audioStreamEnd\":true") == true)
    // Gemini documents that a new audio message reopens a stream after audioStreamEnd.
    try await session.send(chunk)
    #expect(await harness.connection.sentMessages().count == 4)
    await session.cancel()
  }

  @Test
  func endAudioReportsAnUnresolvedInterimAsTimedOutEvenAfterTurnComplete() async throws {
    let harness = makeHarness(finalizationTimeout: .milliseconds(20))
    let session = try await harness.client.connect(
      apiKey: "test-key",
      configuration: LiveTranscriptionConfiguration()
    )
    let stream = await session.eventStream()
    var iterator = stream.makeAsyncIterator()

    await harness.connection.enqueue(.text(#"{"setupComplete":{}}"#))
    #expect(try await iterator.next() == .setupComplete)
    await harness.connection.enqueue(
      .text(#"{"serverContent":{"interimInputTranscription":{"text":"unfinished"}}}"#)
    )
    #expect(
      try await iterator.next()
        == .interimTranscript(text: "unfinished", languageCode: nil)
    )
    let finalization = Task { try await session.endAudio() }
    await harness.connection.waitUntilSentMessageCount(2)
    await harness.connection.enqueue(.text(#"{"serverContent":{"turnComplete":true}}"#))
    #expect(try await iterator.next() == .turnComplete)
    #expect(try await finalization.value == .timedOut)
    await session.cancel()
  }

  @Test
  func endAudioTreatsSilenceAsNothingPendingInsteadOfDataLoss() async throws {
    let harness = makeHarness(finalizationTimeout: .milliseconds(20))
    let session = try await harness.client.connect(
      apiKey: "test-key",
      configuration: LiveTranscriptionConfiguration()
    )
    let stream = await session.eventStream()
    var iterator = stream.makeAsyncIterator()

    await harness.connection.enqueue(.text(#"{"setupComplete":{}}"#))
    #expect(try await iterator.next() == .setupComplete)
    #expect(try await session.endAudio() == .nothingPending)
    await session.cancel()
  }

  @Test
  func endAudioAcceptsTurnCompletionAtTheBoundedDrainDeadline() async throws {
    let harness = makeHarness(finalizationTimeout: .milliseconds(20))
    let session = try await harness.client.connect(
      apiKey: "test-key",
      configuration: LiveTranscriptionConfiguration()
    )
    let stream = await session.eventStream()
    var iterator = stream.makeAsyncIterator()

    await harness.connection.enqueue(.text(#"{"setupComplete":{}}"#))
    #expect(try await iterator.next() == .setupComplete)
    let finalization = Task { try await session.endAudio() }
    await harness.connection.waitUntilSentMessageCount(2)
    await harness.connection.enqueue(.text(#"{"serverContent":{"turnComplete":true}}"#))
    #expect(try await iterator.next() == .turnComplete)
    #expect(try await finalization.value == .turnCompleted)
    await session.cancel()
  }

  @Test
  func turnCompletionBeforeFinalTranscriptKeepsDraining() async throws {
    let harness = makeHarness()
    let session = try await harness.client.connect(
      apiKey: "test-key",
      configuration: LiveTranscriptionConfiguration()
    )
    let stream = await session.eventStream()
    var iterator = stream.makeAsyncIterator()

    await harness.connection.enqueue(.text(#"{"setupComplete":{}}"#))
    #expect(try await iterator.next() == .setupComplete)
    await harness.connection.enqueue(
      .text(#"{"serverContent":{"interimInputTranscription":{"text":"almost done"}}}"#)
    )
    #expect(
      try await iterator.next()
        == .interimTranscript(text: "almost done", languageCode: nil)
    )

    let finalization = Task { try await session.endAudio() }
    await harness.connection.waitUntilSentMessageCount(2)
    await harness.connection.enqueue(.text(#"{"serverContent":{"turnComplete":true}}"#))
    #expect(try await iterator.next() == .turnComplete)
    await harness.connection.enqueue(
      .text(#"{"serverContent":{"inputTranscription":{"text":"all done"}}}"#)
    )
    #expect(
      try await iterator.next()
        == .finalTranscript(text: "all done", languageCode: nil)
    )
    #expect(try await finalization.value == .finalTranscriptReceived)
    await session.cancel()
  }

  @Test
  func sessionPreservesDecodedEventOrder() async throws {
    let harness = makeHarness()
    let session = try await harness.client.connect(
      apiKey: "test-key",
      configuration: LiveTranscriptionConfiguration()
    )
    let stream = await session.eventStream()
    var iterator = stream.makeAsyncIterator()

    await harness.connection.enqueue(.text(#"{"setupComplete":{}}"#))
    await harness.connection.enqueue(
      .text(
        #"{"serverContent":{"interimInputTranscription":{"text":"Mer","languageCode":"tr-TR"},"inputTranscription":{"text":"Merhaba","languageCode":"tr-TR"},"turnComplete":true}}"#
      )
    )
    await harness.connection.enqueue(.text(#"{"goAway":{"timeLeft":"9s"}}"#))

    #expect(try await iterator.next() == .setupComplete)
    #expect(
      try await iterator.next()
        == .interimTranscript(text: "Mer", languageCode: "tr-TR")
    )
    #expect(
      try await iterator.next()
        == .finalTranscript(text: "Merhaba", languageCode: "tr-TR")
    )
    #expect(try await iterator.next() == .turnComplete)
    #expect(try await iterator.next() == .goAway(timeLeftSeconds: 9))
    await session.cancel()
  }

  @Test
  func goAwayFollowedByServerSocketClosureEndsCleanly() async throws {
    let harness = makeHarness()
    let session = try await harness.client.connect(
      apiKey: "test-key",
      configuration: LiveTranscriptionConfiguration()
    )
    let stream = await session.eventStream()
    var iterator = stream.makeAsyncIterator()

    await harness.connection.enqueue(.text(#"{"setupComplete":{}}"#))
    #expect(try await iterator.next() == .setupComplete)
    await harness.connection.enqueue(.text(#"{"goAway":{"timeLeft":"2s"}}"#))
    #expect(try await iterator.next() == .goAway(timeLeftSeconds: 2))
    await harness.connection.fail(message: "The server closed after GoAway")

    #expect(try await iterator.next() == nil)
    #expect(await harness.connection.closeCode() == .normalClosure)
  }

  @Test
  func setupAcknowledgementHasABoundedDeadline() async throws {
    let harness = makeHarness(setupTimeout: .milliseconds(20))
    let session = try await harness.client.connect(
      apiKey: "test-key",
      configuration: LiveTranscriptionConfiguration()
    )
    let stream = await session.eventStream()
    var iterator = stream.makeAsyncIterator()

    await #expect(throws: LiveTranscriptionError.setupTimedOut) {
      try await iterator.next()
    }
    #expect(await harness.connection.closeCode() == .goingAway)
  }

  @Test
  func cancellingFinalizationPropagatesCancellation() async throws {
    let harness = makeHarness(finalizationTimeout: .seconds(10))
    let session = try await harness.client.connect(
      apiKey: "test-key",
      configuration: LiveTranscriptionConfiguration()
    )
    let stream = await session.eventStream()
    var iterator = stream.makeAsyncIterator()

    await harness.connection.enqueue(.text(#"{"setupComplete":{}}"#))
    #expect(try await iterator.next() == .setupComplete)
    let finalization = Task { try await session.endAudio() }
    await harness.connection.waitUntilSentMessageCount(2)
    finalization.cancel()

    await #expect(throws: CancellationError.self) {
      try await finalization.value
    }
    #expect(await harness.connection.closeCode() == .goingAway)
  }

  @Test
  func cancellationClosesTheSocketAndEndsTheStream() async throws {
    let harness = makeHarness()
    let session = try await harness.client.connect(
      apiKey: "test-key",
      configuration: LiveTranscriptionConfiguration()
    )
    let stream = await session.eventStream()
    var iterator = stream.makeAsyncIterator()

    await session.cancel()

    #expect(try await iterator.next() == .ended(reason: .cancelled))
    #expect(try await iterator.next() == nil)
    #expect(await harness.connection.closeCode() == .normalClosure)
  }

  @Test
  func durationLimitClosesAStillActiveSession() async throws {
    #expect(GeminiLiveTranscriptionWireProtocol.maximumSessionDuration == .seconds(600))
    let harness = makeHarness(duration: .milliseconds(20))
    let session = try await harness.client.connect(
      apiKey: "test-key",
      configuration: LiveTranscriptionConfiguration()
    )
    let stream = await session.eventStream()
    var iterator = stream.makeAsyncIterator()

    #expect(try await iterator.next() == .ended(reason: .durationLimitReached))
    #expect(try await iterator.next() == nil)
    #expect(await harness.connection.closeCode() == .normalClosure)
  }

  @Test
  func concurrentAudioWritesFailWithBackpressure() async throws {
    let harness = makeHarness()
    let session = try await harness.client.connect(
      apiKey: "test-key",
      configuration: LiveTranscriptionConfiguration()
    )
    let stream = await session.eventStream()
    var iterator = stream.makeAsyncIterator()
    let chunk = try LivePCM16AudioChunk(data: Data([0x00, 0x00]))

    await harness.connection.enqueue(.text(#"{"setupComplete":{}}"#))
    #expect(try await iterator.next() == .setupComplete)
    await harness.connection.blockOutgoingMessages()
    let firstWrite = Task {
      try await session.send(chunk)
    }
    await harness.connection.waitUntilSentMessageCount(2)

    await expectLiveError(.backpressure) {
      try await session.send(chunk)
    }
    await harness.connection.releaseBlockedMessage()
    try await firstWrite.value
    await session.cancel()
  }

  @Test
  func transportErrorsCannotExposeTheAPIKeyOrCredentialURL() async throws {
    let apiKey = "top secret+/="
    let encodedKey = "top%20secret%2B%2F%3D"
    let harness = makeHarness()
    let session = try await harness.client.connect(
      apiKey: apiKey,
      configuration: LiveTranscriptionConfiguration()
    )
    let stream = await session.eventStream()
    var iterator = stream.makeAsyncIterator()

    await harness.connection.fail(
      message:
        "socket failed at wss://generativelanguage.googleapis.com/ws?key=\(encodedKey) using \(apiKey)"
    )

    do {
      _ = try await iterator.next()
      Issue.record("Expected the stream to fail")
    } catch let error as LiveTranscriptionError {
      let description = error.localizedDescription
      #expect(!description.contains(apiKey))
      #expect(!description.contains(encodedKey))
      #expect(description.contains("key=••••"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  private func makeHarness(
    duration: Duration = .seconds(60),
    finalizationTimeout: Duration = .seconds(1),
    setupTimeout: Duration = .seconds(30)
  ) -> (
    client: GeminiLiveTranscriptionClient,
    connection: FakeLiveWebSocketConnection,
    connector: FakeLiveWebSocketConnector
  ) {
    let connection = FakeLiveWebSocketConnection()
    let connector = FakeLiveWebSocketConnector(connection: connection)
    return (
      GeminiLiveTranscriptionClient(
        connector: connector,
        sessionDuration: duration,
        finalizationTimeout: finalizationTimeout,
        setupTimeout: setupTimeout
      ),
      connection,
      connector
    )
  }

  private func expectLiveError(
    _ expected: LiveTranscriptionError,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      Issue.record("Expected \(expected)")
    } catch let error as LiveTranscriptionError {
      #expect(error == expected)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}

private actor FakeLiveWebSocketConnector: LiveWebSocketConnecting {
  private let connection: FakeLiveWebSocketConnection
  private(set) var request: URLRequest?
  private(set) var maximumMessageSize: Int?

  init(connection: FakeLiveWebSocketConnection) {
    self.connection = connection
  }

  func makeConnection(
    request: URLRequest,
    maximumMessageSize: Int
  ) async throws -> any LiveWebSocketConnection {
    self.request = request
    self.maximumMessageSize = maximumMessageSize
    return connection
  }
}

private actor FakeLiveWebSocketConnection: LiveWebSocketConnection {
  private enum PendingReceive: Sendable {
    case message(LiveWebSocketMessage)
    case failure(FakeSocketError)
  }

  private var resumed = false
  private var cancelled = false
  private var messages: [String] = []
  private var pendingReceives: [PendingReceive] = []
  private var receiveContinuation: CheckedContinuation<LiveWebSocketMessage, Error>?
  private var blockedSendContinuation: CheckedContinuation<Void, Error>?
  private var shouldBlockOutgoingMessages = false
  private var sentCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var recordedCloseCode: LiveWebSocketCloseCode?

  func resume() async {
    resumed = true
  }

  func send(text: String) async throws {
    guard resumed, !cancelled else { throw CancellationError() }
    messages.append(text)
    resumeSatisfiedSentCountWaiters()
    if shouldBlockOutgoingMessages {
      shouldBlockOutgoingMessages = false
      try await withCheckedThrowingContinuation { continuation in
        blockedSendContinuation = continuation
      }
    }
  }

  func receive() async throws -> LiveWebSocketMessage {
    guard resumed, !cancelled else { throw CancellationError() }
    if !pendingReceives.isEmpty {
      return try resolve(pendingReceives.removeFirst())
    }
    return try await withCheckedThrowingContinuation { continuation in
      receiveContinuation = continuation
    }
  }

  func cancel(closeCode: LiveWebSocketCloseCode, reason: Data?) async {
    guard !cancelled else { return }
    cancelled = true
    recordedCloseCode = closeCode
    receiveContinuation?.resume(throwing: CancellationError())
    receiveContinuation = nil
    blockedSendContinuation?.resume(throwing: CancellationError())
    blockedSendContinuation = nil
  }

  func enqueue(_ message: LiveWebSocketMessage) {
    if let continuation = receiveContinuation {
      receiveContinuation = nil
      continuation.resume(returning: message)
    } else {
      pendingReceives.append(.message(message))
    }
  }

  func fail(message: String) {
    let error = FakeSocketError(message: message)
    if let continuation = receiveContinuation {
      receiveContinuation = nil
      continuation.resume(throwing: error)
    } else {
      pendingReceives.append(.failure(error))
    }
  }

  func sentMessages() -> [String] {
    messages
  }

  func closeCode() -> LiveWebSocketCloseCode? {
    recordedCloseCode
  }

  func blockOutgoingMessages() {
    shouldBlockOutgoingMessages = true
  }

  func releaseBlockedMessage() {
    blockedSendContinuation?.resume()
    blockedSendContinuation = nil
  }

  func waitUntilSentMessageCount(_ count: Int) async {
    if messages.count >= count { return }
    await withCheckedContinuation { continuation in
      sentCountWaiters.append((count, continuation))
    }
  }

  private func resolve(_ pending: PendingReceive) throws -> LiveWebSocketMessage {
    switch pending {
    case .message(let message):
      return message
    case .failure(let error):
      throw error
    }
  }

  private func resumeSatisfiedSentCountWaiters() {
    var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    for waiter in sentCountWaiters {
      if messages.count >= waiter.count {
        waiter.continuation.resume()
      } else {
        remaining.append(waiter)
      }
    }
    sentCountWaiters = remaining
  }
}

private struct FakeSocketError: LocalizedError, Sendable {
  let message: String

  var errorDescription: String? { message }
}

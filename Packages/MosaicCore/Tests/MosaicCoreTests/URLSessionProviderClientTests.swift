import Foundation
import Testing

@testable import MosaicCore

struct URLSessionProviderClientTests {
  @Test
  func streamBufferKeepsMoreThanTheOld256EventLimit() async throws {
    let pair = ProviderStreamEventBuffer.makeStream()
    for _ in 0..<300 {
      _ = pair.continuation.yield(.textDelta("x"))
    }
    pair.continuation.finish()

    var receivedCount = 0
    for try await event in pair.stream {
      #expect(event == .textDelta("x"))
      receivedCount += 1
    }
    #expect(receivedCount == 300)
  }

  @Test
  func streamBudgetUsesPersistedMessageSizeInsteadOfAValidTokenEventCount() throws {
    var budget = ProviderStreamEventBudget()
    for _ in 0..<300 {
      #expect(try budget.validated([.textDelta("x")]) == [.textDelta("x")])
    }

    let remaining = MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes - 300
    #expect(
      try budget.validated([.textDelta(String(repeating: "y", count: remaining))]).count == 1
    )
    #expect(throws: ProviderClientError.responseTooLarge) {
      try budget.validated([.textDelta("overflow")])
    }
  }

  @Test
  func geminiCoalescesMoreThan4096IntermediateUsageEventsAndRetainsTheFinalCounters() throws {
    var coalescer = ProviderStreamUsageCoalescer(dialect: .gemini)
    var budget = ProviderStreamEventBudget()
    var textEventCount = 0
    var controlEvents: [AIStreamEvent] = []

    for count in 1...5_000 {
      let events = coalescer.consume([
        .textDelta("x"),
        .usage(TokenUsage(inputTokens: 10, outputTokens: count)),
      ])
      for event in try budget.validated(events) {
        if case .textDelta = event { textEventCount += 1 } else { controlEvents.append(event) }
      }
    }
    let terminal = coalescer.consume([
      .completed(responseID: nil),
      .usage(TokenUsage(inputTokens: 12, outputTokens: 5_001)),
    ])
    controlEvents.append(contentsOf: try budget.validated(terminal))

    #expect(textEventCount == 5_000)
    #expect(
      controlEvents == [
        .usage(TokenUsage(inputTokens: 12, outputTokens: 5_001)),
        .completed(responseID: nil),
      ]
    )
  }

  @Test
  func geminiUsageCoalescerFlushesLatestPartialCountersAtCleanEOF() {
    var coalescer = ProviderStreamUsageCoalescer(dialect: .gemini)

    #expect(
      coalescer.consume([.usage(TokenUsage(inputTokens: 9))]).isEmpty
    )
    #expect(
      coalescer.consume([.usage(TokenUsage(outputTokens: 4))]).isEmpty
    )
    #expect(
      coalescer.finishAtEOF() == [.usage(TokenUsage(inputTokens: 9, outputTokens: 4))]
    )
    #expect(coalescer.finishAtEOF().isEmpty)
  }

  @Test
  func chatCompletionDefersTerminalEventUntilDoneAndPreservesTrailingUsage() {
    var coordinator = ProviderStreamCompletionCoordinator(dialect: .openAIChatCompletions)

    #expect(
      coordinator.consume(
        [.textDelta("answer"), .completed(responseID: "chat-1")],
        isExplicitEndMarker: false
      ) == [.textDelta("answer")]
    )
    #expect(
      coordinator.consume(
        [.usage(TokenUsage(inputTokens: 4, outputTokens: 2))],
        isExplicitEndMarker: false
      ) == [.usage(TokenUsage(inputTokens: 4, outputTokens: 2))]
    )
    #expect(
      coordinator.consume(
        [.completed(responseID: nil)],
        isExplicitEndMarker: true
      ) == [.completed(responseID: "chat-1")]
    )
    #expect(coordinator.finishAtEOF().isEmpty)
  }

  @Test
  func chatCompletionTreatsCleanEOFAfterFinishReasonAsSuccess() {
    var coordinator = ProviderStreamCompletionCoordinator(dialect: .openAIChatCompletions)
    #expect(
      coordinator.consume(
        [.completed(responseID: "chat-2")],
        isExplicitEndMarker: false
      ).isEmpty
    )
    #expect(coordinator.finishAtEOF() == [.completed(responseID: "chat-2")])
    #expect(coordinator.finishAtEOF().isEmpty)
  }

  @Test
  func providerSessionAllowsLongRunningStreamingButRemainsBounded() {
    let configuration = URLSessionProviderClient.makeSessionConfiguration(streaming: true)

    #expect(
      configuration.timeoutIntervalForRequest
        == ProviderNetworkTimeoutPolicy.streamingRequestIdle
    )
    #expect(
      configuration.timeoutIntervalForResource
        == ProviderNetworkTimeoutPolicy.streamingResource
    )
    #expect(configuration.timeoutIntervalForResource.isFinite)

    let catalogConfiguration = URLSessionProviderClient.makeSessionConfiguration(streaming: false)
    #expect(catalogConfiguration.timeoutIntervalForRequest == 120)
    #expect(catalogConfiguration.timeoutIntervalForResource == 300)
  }
}

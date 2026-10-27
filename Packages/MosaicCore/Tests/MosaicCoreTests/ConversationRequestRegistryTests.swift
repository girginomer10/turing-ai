import Foundation
import Testing

@testable import MosaicCore

@Suite("Conversation request registry")
@MainActor
struct ConversationRequestRegistryTests {
  @Test("transferring a request preserves one active entry and replaces cancellation")
  func transferReplacesCancellationWithoutDroppingActivity() {
    let registry = ConversationRequestRegistry()
    let conversationID = UUID()
    let requestID = UUID()
    let firstProbe = CancellationProbe()
    let secondProbe = CancellationProbe()

    #expect(
      registry.register(conversationID: conversationID, requestID: requestID) {
        firstProbe.callCount += 1
      }
    )
    #expect(registry.isActive(conversationID: conversationID))
    #expect(
      registry.transfer(conversationID: conversationID, requestID: requestID) {
        secondProbe.callCount += 1
      }
    )

    registry.cancel(conversationID: conversationID)

    #expect(firstProbe.callCount == 0)
    #expect(secondProbe.callCount == 1)
    #expect(registry.isActive(conversationID: conversationID))
  }

  @Test("a stale request cannot finish the current request")
  func staleFinishCannotRemoveCurrentEntry() {
    let registry = ConversationRequestRegistry()
    let conversationID = UUID()
    let requestID = UUID()

    #expect(registry.register(conversationID: conversationID, requestID: requestID) {})
    registry.finish(conversationID: conversationID, requestID: UUID())
    #expect(registry.isActive(conversationID: conversationID))

    registry.finish(conversationID: conversationID, requestID: requestID)
    #expect(!registry.isActive(conversationID: conversationID))
  }
}

@MainActor
private final class CancellationProbe {
  var callCount = 0
}

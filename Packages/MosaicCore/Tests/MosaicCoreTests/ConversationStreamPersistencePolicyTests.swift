import Foundation
import Testing

@testable import MosaicCore

@Suite("Conversation stream persistence policy")
struct ConversationStreamPersistencePolicyTests {
  @Test("small rapid deltas stay batched until the byte threshold")
  func byteThreshold() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var policy = ConversationStreamPersistencePolicy(
      maximumUnpersistedUTF8Bytes: 10,
      maximumUnpersistedInterval: 5,
      lastPersistedAt: start
    )

    let firstDecision = policy.shouldPersist(afterAppendingUTF8Bytes: 4, now: start)
    let secondDecision = policy.shouldPersist(afterAppendingUTF8Bytes: 5, now: start)
    let thresholdDecision = policy.shouldPersist(afterAppendingUTF8Bytes: 1, now: start)
    #expect(!firstDecision)
    #expect(!secondDecision)
    #expect(thresholdDecision)
  }

  @Test("elapsed time flushes a small delta and a successful save resets the batch")
  func elapsedThresholdAndReset() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let flushDate = start.addingTimeInterval(0.25)
    var policy = ConversationStreamPersistencePolicy(
      maximumUnpersistedUTF8Bytes: 100,
      maximumUnpersistedInterval: 0.25,
      lastPersistedAt: start
    )

    let elapsedDecision = policy.shouldPersist(afterAppendingUTF8Bytes: 1, now: flushDate)
    #expect(elapsedDecision)
    policy.didPersist(at: flushDate)
    #expect(policy.unpersistedUTF8Bytes == 0)
    let resetDecision = policy.shouldPersist(afterAppendingUTF8Bytes: 1, now: flushDate)
    #expect(!resetDecision)
  }
}

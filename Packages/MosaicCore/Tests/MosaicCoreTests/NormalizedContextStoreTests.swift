import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import MosaicCore

struct NormalizedContextStoreTests {
  private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000.123_456)

  @MainActor
  @Test
  func generatedReusedFailedAndCancelledEventsRoundTripLosslessly() throws {
    let harness = try makeHarness()
    let conversationID = id(900)
    let messages = history(count: 5, conversationSeed: 1)
    let snapshot = makeSnapshot(
      id: id(901),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 2,
      mode: .initial,
      chainDepth: 1
    )

    for (offset, status) in [
      ConversationCompactionAttemptStatus.generated,
      .reused,
      .failed,
    ].enumerated() {
      let receipt = makeRequestReceipt(
        messages: messages,
        snapshot: snapshot,
        status: status,
        attemptID: id(910 + offset)
      )
      let assistantID = id(920 + offset)
      let disposition = try harness.store.appendRequestEvent(
        assistantMessageID: assistantID,
        conversationID: conversationID,
        sourceThroughMessageID: try #require(messages.last?.id),
        eventSequence: 0,
        receipt: receipt,
        canonicalMessages: messages,
        activeCompactionSnapshot: offset == 0 ? snapshot : nil,
        createdAt: fixedDate
      )
      #expect(disposition == .inserted)
      #expect(
        try harness.store.requestReceipt(
          assistantMessageID: assistantID,
          canonicalMessages: messages
        ) == receipt
      )
    }

    let cancelled = makeRequestReceipt(
      messages: messages,
      snapshot: nil,
      status: .cancelled,
      attemptID: id(930)
    )
    let cancelledAssistantID = id(931)
    try harness.store.appendRequestEvent(
      assistantMessageID: cancelledAssistantID,
      conversationID: conversationID,
      sourceThroughMessageID: try #require(messages.last?.id),
      eventSequence: 0,
      receipt: cancelled,
      canonicalMessages: messages,
      createdAt: fixedDate
    )
    #expect(
      try harness.store.requestReceipt(
        assistantMessageID: cancelledAssistantID,
        canonicalMessages: messages
      ) == cancelled
    )

    #expect(
      try harness.context.fetchCount(FetchDescriptor<RequestContextEventRecord>()) == 4
    )
    #expect(
      try harness.context.fetchCount(FetchDescriptor<CompactionArtifactRecord>()) == 1
    )
  }

  @MainActor
  @Test
  func deltaChainReconstructsSnapshotsAndAdvancesHeadIncludingDetachedLegacyRoot() throws {
    let harness = try makeHarness()
    let conversationID = id(1_000)
    let messages = history(count: 7, conversationSeed: 2)
    let initial = makeSnapshot(
      id: id(1_001),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 2,
      mode: .initial,
      chainDepth: 1
    )
    let extended = makeSnapshot(
      id: id(1_002),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 4,
      previous: initial.id,
      mode: .extend,
      chainDepth: 2
    )
    let rebuilt = makeSnapshot(
      id: id(1_003),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 6,
      previous: extended.id,
      mode: .rebuild,
      chainDepth: 1
    )

    try harness.store.activateCompactionSnapshot(
      initial,
      conversationID: conversationID,
      expectedCurrentArtifactID: nil,
      canonicalMessages: messages
    )
    try harness.store.activateCompactionSnapshot(
      extended,
      conversationID: conversationID,
      expectedCurrentArtifactID: initial.id,
      canonicalMessages: messages
    )
    try harness.store.activateCompactionSnapshot(
      rebuilt,
      conversationID: conversationID,
      expectedCurrentArtifactID: extended.id,
      canonicalMessages: messages
    )

    let artifacts = try harness.context.fetch(
      FetchDescriptor<CompactionArtifactRecord>(
        sortBy: [SortDescriptor(\CompactionArtifactRecord.coveredMessageCount)]
      )
    )
    #expect(artifacts.count == 3)
    #expect(
      try artifacts.map { try JSONDecoder().decode([UUID].self, from: $0.coverageDeltaData) }
        .map(\.count) == [2, 2, 2]
    )
    #expect(
      try harness.store.projectCompactionSnapshot(
        artifactID: rebuilt.id,
        canonicalMessages: messages
      ) == rebuilt
    )

    #expect(
      try harness.store.activeCompactionArtifactID(conversationID: conversationID) == rebuilt.id
    )
    #expect(
      try harness.store.activeCompactionSnapshot(
        conversationID: conversationID,
        canonicalMessages: messages
      ) == rebuilt
    )

    let detachedConversationID = id(1_010)
    let detachedMessages = history(count: 3, conversationSeed: 3)
    let detached = makeSnapshot(
      id: id(1_011),
      conversationID: detachedConversationID,
      messages: detachedMessages,
      coveredCount: 2,
      previous: id(1_099),
      mode: .rebuild,
      chainDepth: 1
    )
    #expect(
      try harness.store.adoptLegacyCompactionSnapshot(
        detached,
        conversationID: detachedConversationID,
        expectedCurrentArtifactID: nil,
        canonicalMessages: detachedMessages
      ) == .inserted
    )
    #expect(
      try harness.store.activeCompactionSnapshot(
        conversationID: detachedConversationID,
        canonicalMessages: detachedMessages
      ) == detached
    )

    let detachedReceipt = makeRequestReceipt(
      messages: detachedMessages,
      snapshot: detached,
      status: .reused,
      attemptID: id(1_012)
    )
    #expect(
      try harness.store.appendRequestEvent(
        assistantMessageID: id(1_013),
        conversationID: detachedConversationID,
        sourceThroughMessageID: #require(detachedMessages.last?.id),
        eventSequence: 0,
        receipt: detachedReceipt,
        canonicalMessages: detachedMessages,
        activeCompactionSnapshot: detached,
        createdAt: fixedDate
      ) == .inserted
    )
    #expect(
      try harness.store.requestReceipt(
        assistantMessageID: id(1_013),
        canonicalMessages: detachedMessages
      ) == detachedReceipt
    )
  }

  @MainActor
  @Test
  func corruptCycleCountAndPrefixChainsFailClosed() throws {
    try assertCorruptChain(
      expected: .compactionArtifactCycle(id(1_101))
    ) { harness, conversationID, messages, receipt in
      let firstID = id(1_101)
      let secondID = id(1_102)
      harness.context.insert(
        try NormalizedContextStoreTestSupport.artifact(
          id: firstID,
          conversationID: conversationID,
          coverageParentArtifactID: secondID,
          coverageDelta: [messages[0].id],
          coveredMessageCount: 1,
          renderedSummary: "Summary",
          providerConfigurationID: id(80)
        )
      )
      harness.context.insert(
        try NormalizedContextStoreTestSupport.artifact(
          id: secondID,
          conversationID: conversationID,
          coverageParentArtifactID: firstID,
          coverageDelta: [messages[0].id],
          coveredMessageCount: 1,
          renderedSummary: "Other",
          providerConfigurationID: id(80)
        )
      )
      try harness.context.save()
      return receipt(firstID, [messages[0].id], "Summary")
    }

    try assertCorruptChain(
      expected: .compactionCountMismatch(id(1_111))
    ) { harness, conversationID, messages, receipt in
      let artifactID = id(1_111)
      harness.context.insert(
        try NormalizedContextStoreTestSupport.artifact(
          id: artifactID,
          conversationID: conversationID,
          coverageParentArtifactID: nil,
          coverageDelta: [messages[0].id],
          coveredMessageCount: 2,
          renderedSummary: "Summary",
          providerConfigurationID: id(80)
        )
      )
      try harness.context.save()
      return receipt(artifactID, [messages[0].id], "Summary")
    }

    try assertCorruptChain(
      expected: .compactionPrefixMismatch(id(1_121))
    ) { harness, conversationID, _, receipt in
      let artifactID = id(1_121)
      let foreignID = id(9_999)
      harness.context.insert(
        try NormalizedContextStoreTestSupport.artifact(
          id: artifactID,
          conversationID: conversationID,
          coverageParentArtifactID: nil,
          coverageDelta: [foreignID],
          coveredMessageCount: 1,
          renderedSummary: "Summary",
          providerConfigurationID: id(80)
        )
      )
      try harness.context.save()
      return receipt(artifactID, [foreignID], "Summary")
    }
  }

  @MainActor
  @Test
  func legacyBackfillIsDeterministicIdempotentAndRetainsCorruptBytes() throws {
    let harness = try makeHarness()
    let conversationID = id(1_200)
    let messages = history(count: 5, conversationSeed: 4)
    let snapshot = makeSnapshot(
      id: id(1_201),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 2,
      mode: .initial,
      chainDepth: 1
    )
    let receipt = makeRequestReceipt(
      messages: messages,
      snapshot: snapshot,
      status: .generated,
      attemptID: id(1_202)
    )
    let legacyReceiptData = try JSONEncoder().encode(receipt)
    let legacySnapshotData = try JSONEncoder().encode(snapshot)
    let assistantID = id(1_203)
    let item = LegacyRequestContextBackfillItem(
      assistantMessageID: assistantID,
      conversationID: conversationID,
      sourceThroughMessageID: try #require(messages.last?.id),
      canonicalMessages: messages,
      legacyReceiptData: legacyReceiptData,
      legacyCompactionSnapshotData: legacySnapshotData,
      createdAt: fixedDate
    )

    let first = try harness.store.backfillLegacyReceipts(
      [item],
      migrationKey: "normalized-context-tests"
    )
    #expect(first.processedCount == 1)
    #expect(first.insertedEventCount == 1)
    #expect(first.retainedLegacyCount == 0)
    #expect(first.isComplete)
    #expect(item.legacyReceiptData == legacyReceiptData)
    #expect(
      try harness.store.requestReceipt(
        assistantMessageID: assistantID,
        canonicalMessages: messages,
        legacyReceiptData: legacyReceiptData
      ) == receipt
    )

    let second = try harness.store.backfillLegacyReceipts(
      [item],
      migrationKey: "normalized-context-tests"
    )
    #expect(second.processedCount == 0)
    #expect(second.insertedEventCount == 0)
    #expect(second.isComplete)
    #expect(
      try harness.context.fetchCount(FetchDescriptor<RequestContextEventRecord>()) == 1
    )
    #expect(
      try harness.context.fetchCount(FetchDescriptor<CompactionArtifactRecord>()) == 1
    )

    let corruptBytes = Data([0xFF, 0x00, 0x7B])
    let corrupt = LegacyRequestContextBackfillItem(
      assistantMessageID: id(1_204),
      conversationID: conversationID,
      sourceThroughMessageID: try #require(messages.last?.id),
      canonicalMessages: messages,
      legacyReceiptData: corruptBytes,
      createdAt: fixedDate
    )
    let corruptResult = try harness.store.backfillLegacyReceipts(
      [corrupt],
      migrationKey: "normalized-context-corrupt-tests"
    )
    #expect(corruptResult.processedCount == 1)
    #expect(corruptResult.retainedLegacyCount == 1)
    #expect(corruptResult.failedEventKeys.count == 1)
    #expect(corrupt.legacyReceiptData == corruptBytes)
    #expect(
      try harness.context.fetchCount(FetchDescriptor<RequestContextEventRecord>()) == 1
    )
  }

  @MainActor
  @Test
  func requestPayloadRemainsBoundedAsConversationGrows() throws {
    let harness = try makeHarness()
    let smallMessages = history(count: 101, conversationSeed: 5)
    let largeMessages = history(count: 5_001, conversationSeed: 6)
    let smallReceipt = makeRecentOnlyReceipt(messages: smallMessages, rawCount: 5)
    let largeReceipt = makeRecentOnlyReceipt(messages: largeMessages, rawCount: 5)

    try harness.store.appendRequestEvent(
      assistantMessageID: id(1_301),
      conversationID: id(1_302),
      sourceThroughMessageID: try #require(smallMessages.last?.id),
      eventSequence: 0,
      receipt: smallReceipt,
      canonicalMessages: smallMessages,
      createdAt: fixedDate
    )
    try harness.store.appendRequestEvent(
      assistantMessageID: id(1_303),
      conversationID: id(1_304),
      sourceThroughMessageID: try #require(largeMessages.last?.id),
      eventSequence: 0,
      receipt: largeReceipt,
      canonicalMessages: largeMessages,
      createdAt: fixedDate
    )

    let events = try harness.context.fetch(
      FetchDescriptor<RequestContextEventRecord>(
        sortBy: [SortDescriptor(\RequestContextEventRecord.sourceMessageCount)]
      )
    )
    let smallEvent = try #require(events.first)
    let largeEvent = try #require(events.last)
    #expect(smallEvent.sourceMessageCount == 101)
    #expect(largeEvent.sourceMessageCount == 5_001)
    #expect(smallEvent.payloadData.count == largeEvent.payloadData.count)
    #expect(largeEvent.payloadData.count < 4_096)
    #expect(try JSONEncoder().encode(largeReceipt).count > largeEvent.payloadData.count * 20)
    #expect(
      try harness.store.requestReceipt(
        assistantMessageID: largeEvent.assistantMessageID,
        canonicalMessages: largeMessages
      ) == largeReceipt
    )
  }

  @MainActor
  @Test
  func malformedConversationTokenBudgetFailsClosedWithoutOverflow() throws {
    let harness = try makeHarness()
    let messages = history(count: 3, conversationSeed: 61)
    let base = makeRecentOnlyReceipt(messages: messages, rawCount: 3)
    let original = try #require(base.conversationContext)
    let malformed = RequestContextReceipt(
      curatedContext: base.curatedContext,
      retrievedContext: base.retrievedContext,
      conversationContext: ConversationContextReceipt(
        strategy: original.strategy,
        originalMessageCount: original.originalMessageCount,
        includedMessageIDs: original.includedMessageIDs,
        omittedMessageIDs: original.omittedMessageIDs,
        summarizedMessageIDs: original.summarizedMessageIDs,
        recalledMessageIDs: original.recalledMessageIDs,
        estimatedInputTokens: original.estimatedInputTokens,
        contextWindowTokens: .min,
        maximumOutputTokens: 1,
        safetyMarginTokens: 0,
        warnings: original.warnings
      ),
      createdAt: fixedDate
    )

    do {
      _ = try harness.store.appendRequestEvent(
        assistantMessageID: id(1_320),
        conversationID: id(1_321),
        sourceThroughMessageID: #require(messages.last?.id),
        eventSequence: 0,
        receipt: malformed,
        canonicalMessages: messages,
        createdAt: fixedDate
      )
      Issue.record("Expected malformed token arithmetic to fail closed")
    } catch let error as NormalizedContextStoreError {
      #expect(error == .corruptPayload("invalid conversation token budget"))
    }
  }

  @MainActor
  @Test
  func activationAndFinalEventRollbackTogetherWhenPayloadIsRejected() throws {
    let harness = try makeHarness()
    let conversationID = id(1_330)
    let messages = history(count: 5, conversationSeed: 62)
    let snapshot = makeSnapshot(
      id: id(1_331),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 2,
      mode: .initial,
      chainDepth: 1
    )
    let base = makeRequestReceipt(
      messages: messages,
      snapshot: snapshot,
      status: .generated,
      attemptID: id(1_332)
    )
    let oversized = RequestContextReceipt(
      curatedContext: base.curatedContext,
      retrievedContext: RetrievedContext(
        systemContent: String(repeating: "x", count: 600_000),
        items: []
      ),
      conversationContext: base.conversationContext,
      sameConversationRecall: base.sameConversationRecall,
      conversationCompaction: base.conversationCompaction,
      createdAt: base.createdAt
    )

    do {
      _ = try harness.store.appendRequestEventAtomically(
        assistantMessageID: id(1_333),
        conversationID: conversationID,
        sourceThroughMessageID: #require(messages.last?.id),
        eventSequence: 0,
        receipt: oversized,
        canonicalMessages: messages,
        activeCompactionSnapshot: snapshot,
        compactionActivations: [
          NormalizedCompactionActivation(
            snapshot: snapshot,
            expectedCurrentArtifactID: nil,
            allowVerifiedDetachedTakeover: false
          )
        ],
        createdAt: fixedDate
      )
      Issue.record("Expected the oversized event payload to reject the whole transaction")
    } catch let error as NormalizedContextStoreError {
      guard case .payloadTooLarge = error else {
        Issue.record("Expected payloadTooLarge, received \(error)")
        return
      }
    }

    #expect(
      try harness.store.activeCompactionArtifactID(conversationID: conversationID) == nil
    )
    #expect(try harness.context.fetchCount(FetchDescriptor<CompactionArtifactRecord>()) == 0)
    #expect(try harness.context.fetchCount(FetchDescriptor<RequestContextEventRecord>()) == 0)
  }

  @MainActor
  @Test
  func compactionAuditRejectsNegativeOrStatusInconsistentCounters() throws {
    let harness = try makeHarness()
    let conversationID = id(1_340)
    let messages = history(count: 5, conversationSeed: 63)
    let snapshot = makeSnapshot(
      id: id(1_341),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 2,
      mode: .initial,
      chainDepth: 1
    )
    let base = makeRequestReceipt(
      messages: messages,
      snapshot: snapshot,
      status: .generated,
      attemptID: id(1_342)
    )
    let compaction = try #require(base.conversationCompaction)
    let malformedCompaction = ConversationCompactionReceipt(
      attemptID: compaction.attemptID,
      status: compaction.status,
      compactionID: compaction.compactionID,
      summaryText: compaction.summaryText,
      coveredMessageIDs: compaction.coveredMessageIDs,
      attemptedMessageIDs: compaction.attemptedMessageIDs,
      activeSummaryProviderConfigurationID: compaction.activeSummaryProviderConfigurationID,
      activeSummaryProviderKind: compaction.activeSummaryProviderKind,
      activeSummaryProviderDisplayName: compaction.activeSummaryProviderDisplayName,
      activeSummaryProviderEndpoint: compaction.activeSummaryProviderEndpoint,
      activeSummaryModelIdentifier: compaction.activeSummaryModelIdentifier,
      activeSummaryCreatedAt: compaction.activeSummaryCreatedAt,
      providerConfigurationID: compaction.providerConfigurationID,
      providerKind: compaction.providerKind,
      providerDisplayName: compaction.providerDisplayName,
      providerEndpoint: compaction.providerEndpoint,
      modelIdentifier: compaction.modelIdentifier,
      providerMessageID: compaction.providerMessageID,
      inputTokenCount: compaction.inputTokenCount,
      outputTokenCount: compaction.outputTokenCount,
      estimatedInputTokensBefore: compaction.estimatedInputTokensBefore,
      estimatedInputTokensAfter: compaction.estimatedInputTokensAfter,
      extraRequestCount: -1,
      errorDescription: compaction.errorDescription,
      warnings: compaction.warnings,
      createdAt: compaction.createdAt
    )
    let malformed = RequestContextReceipt(
      curatedContext: base.curatedContext,
      retrievedContext: base.retrievedContext,
      conversationContext: base.conversationContext,
      sameConversationRecall: base.sameConversationRecall,
      conversationCompaction: malformedCompaction,
      createdAt: base.createdAt
    )

    do {
      _ = try harness.store.appendRequestEvent(
        assistantMessageID: id(1_343),
        conversationID: conversationID,
        sourceThroughMessageID: #require(messages.last?.id),
        eventSequence: 0,
        receipt: malformed,
        canonicalMessages: messages,
        activeCompactionSnapshot: snapshot,
        createdAt: fixedDate
      )
      Issue.record("Expected malformed compaction audit counters to fail closed")
    } catch let error as NormalizedContextStoreError {
      #expect(error == .corruptPayload("invalid compaction audit counters"))
    }
  }

  @MainActor
  @Test
  func exactEventReplayDoesNotReapplyHistoricalHeadCAS() throws {
    let harness = try makeHarness()
    let conversationID = id(1_350)
    let messages = history(count: 7, conversationSeed: 64)
    let initial = makeSnapshot(
      id: id(1_351),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 2,
      mode: .initial,
      chainDepth: 1
    )
    let extended = makeSnapshot(
      id: id(1_352),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 4,
      previous: initial.id,
      mode: .extend,
      chainDepth: 2
    )
    let initialReceipt = makeRequestReceipt(
      messages: messages,
      snapshot: initial,
      status: .generated,
      attemptID: id(1_353)
    )
    let extendedReceipt = makeRequestReceipt(
      messages: messages,
      snapshot: extended,
      status: .generated,
      attemptID: id(1_354)
    )
    let initialActivation = NormalizedCompactionActivation(
      snapshot: initial,
      expectedCurrentArtifactID: nil,
      allowVerifiedDetachedTakeover: false
    )

    #expect(
      try harness.store.appendRequestEventAtomically(
        assistantMessageID: id(1_355),
        conversationID: conversationID,
        sourceThroughMessageID: #require(messages.last?.id),
        eventSequence: 0,
        receipt: initialReceipt,
        canonicalMessages: messages,
        activeCompactionSnapshot: initial,
        compactionActivations: [initialActivation],
        createdAt: fixedDate
      ) == .inserted
    )
    #expect(
      try harness.store.appendRequestEventAtomically(
        assistantMessageID: id(1_356),
        conversationID: conversationID,
        sourceThroughMessageID: #require(messages.last?.id),
        eventSequence: 0,
        receipt: extendedReceipt,
        canonicalMessages: messages,
        activeCompactionSnapshot: extended,
        compactionActivations: [
          NormalizedCompactionActivation(
            snapshot: extended,
            expectedCurrentArtifactID: initial.id,
            allowVerifiedDetachedTakeover: false
          )
        ],
        createdAt: fixedDate.addingTimeInterval(1)
      ) == .inserted
    )

    #expect(
      try harness.store.appendRequestEventAtomically(
        assistantMessageID: id(1_355),
        conversationID: conversationID,
        sourceThroughMessageID: #require(messages.last?.id),
        eventSequence: 0,
        receipt: initialReceipt,
        canonicalMessages: messages,
        activeCompactionSnapshot: initial,
        compactionActivations: [initialActivation],
        createdAt: fixedDate
      ) == .alreadyPresent
    )
    #expect(
      try harness.store.activeCompactionArtifactID(conversationID: conversationID) == extended.id
    )
  }

  @MainActor
  @Test
  func runtimeActivationRejectsInvalidModeDepthBeforeAdvancingHead() throws {
    let harness = try makeHarness()
    let conversationID = id(1_360)
    let messages = history(count: 3, conversationSeed: 65)
    let malformed = makeSnapshot(
      id: id(1_361),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 2,
      mode: .initial,
      chainDepth: 9
    )

    do {
      _ = try harness.store.activateCompactionSnapshot(
        malformed,
        conversationID: conversationID,
        expectedCurrentArtifactID: nil,
        canonicalMessages: messages
      )
      Issue.record("Expected invalid runtime lineage metadata to fail before activation")
    } catch let error as NormalizedContextStoreError {
      #expect(error == .corruptPayload("invalid initial compaction lineage"))
    }
    #expect(
      try harness.store.activeCompactionArtifactID(conversationID: conversationID) == nil
    )
    #expect(try harness.context.fetchCount(FetchDescriptor<CompactionArtifactRecord>()) == 0)
  }

  @MainActor
  @Test
  func dualReadChoosesFurtherValidCoverageAndRejectsAnExactTieConflict() throws {
    let harness = try makeHarness()
    let conversationID = id(1_400)
    let messages = history(count: 7, conversationSeed: 7)
    let initial = makeSnapshot(
      id: id(1_401),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 2,
      mode: .initial,
      chainDepth: 1
    )
    let legacyAhead = makeSnapshot(
      id: id(1_402),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 4,
      previous: initial.id,
      mode: .extend,
      chainDepth: 2,
      createdAt: fixedDate.addingTimeInterval(10)
    )
    try harness.store.persistCompactionArtifact(snapshot: initial, canonicalMessages: messages)
    try harness.store.advanceCompactionHead(
      conversationID: conversationID,
      to: initial.id,
      expectedCurrentArtifactID: nil,
      canonicalMessages: messages
    )

    #expect(
      try harness.store.activeCompactionSnapshot(
        conversationID: conversationID,
        canonicalMessages: messages,
        legacySnapshotData: JSONEncoder().encode(legacyAhead)
      ) == legacyAhead
    )
    #expect(
      try harness.store.adoptLegacyCompactionSnapshot(
        legacyAhead,
        conversationID: conversationID,
        expectedCurrentArtifactID: initial.id,
        canonicalMessages: messages
      ) == .inserted
    )
    #expect(
      try harness.store.activeCompactionArtifactID(conversationID: conversationID)
        == legacyAhead.id
    )

    do {
      _ = try harness.store.adoptLegacyCompactionSnapshot(
        initial,
        conversationID: conversationID,
        expectedCurrentArtifactID: legacyAhead.id,
        canonicalMessages: messages
      )
      Issue.record("Expected a shorter rollback snapshot to be rejected")
    } catch let error as NormalizedContextStoreError {
      #expect(
        error == .legacySnapshotNotNewer(current: legacyAhead.id, candidate: initial.id)
      )
    }

    let conflictingTie = makeSnapshot(
      id: id(1_403),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 4,
      previous: initial.id,
      mode: .rebuild,
      chainDepth: 1,
      createdAt: legacyAhead.createdAt,
      overview: "Different summary at the exact same arbitration point"
    )
    do {
      _ = try harness.store.activeCompactionSnapshot(
        conversationID: conversationID,
        canonicalMessages: messages,
        legacySnapshotData: JSONEncoder().encode(conflictingTie)
      )
      Issue.record("Expected equal coverage and timestamp with different content to fail closed")
    } catch let error as NormalizedContextStoreError {
      #expect(
        error == .dualReadConflict(normalized: legacyAhead.id, legacy: conflictingTie.id)
      )
    }
  }

  @MainActor
  @Test
  func detachedTakeoverRequiresExplicitFlagAndNonRegressingCoverage() throws {
    let harness = try makeHarness()
    let conversationID = id(1_450)
    let messages = history(count: 7, conversationSeed: 70)
    let initial = makeSnapshot(
      id: id(1_451),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 2,
      mode: .initial,
      chainDepth: 1
    )
    let detachedAhead = makeSnapshot(
      id: id(1_452),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 4,
      previous: id(1_499),
      mode: .rebuild,
      chainDepth: 1,
      createdAt: fixedDate.addingTimeInterval(20)
    )
    try harness.store.activateCompactionSnapshot(
      initial,
      conversationID: conversationID,
      expectedCurrentArtifactID: nil,
      canonicalMessages: messages
    )

    do {
      _ = try harness.store.activateCompactionSnapshot(
        detachedAhead,
        conversationID: conversationID,
        expectedCurrentArtifactID: initial.id,
        canonicalMessages: messages
      )
      Issue.record("Expected ordinary activation to reject a detached lineage")
    } catch let error as NormalizedContextStoreError {
      #expect(
        error == .legacySnapshotNotNewer(current: initial.id, candidate: detachedAhead.id)
      )
    }

    #expect(
      try harness.store.activateCompactionSnapshot(
        detachedAhead,
        conversationID: conversationID,
        expectedCurrentArtifactID: initial.id,
        canonicalMessages: messages,
        allowVerifiedDetachedTakeover: true
      ) == .inserted
    )
    #expect(
      try harness.store.activeCompactionArtifactID(conversationID: conversationID)
        == detachedAhead.id
    )
    #expect(
      try harness.store.activateCompactionSnapshot(
        detachedAhead,
        conversationID: conversationID,
        expectedCurrentArtifactID: initial.id,
        canonicalMessages: messages,
        allowVerifiedDetachedTakeover: true
      ) == .alreadyPresent
    )
  }

  @MainActor
  @Test
  func corruptNormalizedEventNeverSilentlyFallsBackToLegacy() throws {
    let harness = try makeHarness()
    let messages = history(count: 3, conversationSeed: 8)
    let receipt = makeRecentOnlyReceipt(messages: messages, rawCount: 3)
    let assistantID = id(1_500)
    let eventKey = NormalizedContextStore.eventKey(
      assistantMessageID: assistantID,
      eventSequence: 0
    )
    harness.context.insert(
      RequestContextEventRecord(
        id: id(1_501),
        eventKey: eventKey,
        assistantMessageID: assistantID,
        conversationID: id(1_502),
        sourceThroughMessageID: try #require(messages.last?.id),
        sourceMessageCount: messages.count,
        eventSequence: 0,
        payloadData: Data("not-json".utf8),
        payloadFingerprint: "wrong",
        legacyReceiptFingerprint: nil,
        createdAt: fixedDate
      )
    )
    try harness.context.save()

    do {
      _ = try harness.store.requestReceipt(
        assistantMessageID: assistantID,
        canonicalMessages: messages,
        legacyReceiptData: JSONEncoder().encode(receipt)
      )
      Issue.record("Expected corrupt normalized data to fail closed")
    } catch let error as NormalizedContextStoreError {
      #expect(error == .corruptPayload("request payload fingerprint mismatch"))
    }
  }

  @MainActor
  @Test
  func legacyFallbackRejectsOverflowingReceiptAndInvalidSnapshotLineage() throws {
    let harness = try makeHarness()
    let conversationID = id(1_510)
    let source = history(count: 1, conversationSeed: 80)
    let assistant = AIChatMessage(
      id: id(1_511),
      role: .assistant,
      content: "answer"
    )
    let malformedReceipt = RequestContextReceipt(
      curatedContext: .empty,
      retrievedContext: .empty,
      conversationContext: ConversationContextReceipt(
        strategy: .full,
        originalMessageCount: source.count,
        includedMessageIDs: source.map(\.id),
        omittedMessageIDs: [],
        estimatedInputTokens: 0,
        contextWindowTokens: .min,
        maximumOutputTokens: 1,
        safetyMarginTokens: 0
      ),
      createdAt: fixedDate
    )
    do {
      _ = try harness.store.requestReceipt(
        assistantMessageID: assistant.id,
        conversationID: conversationID,
        canonicalMessages: source + [assistant],
        legacyReceiptData: JSONEncoder().encode(malformedReceipt)
      )
      Issue.record("Expected the legacy token budget to fail closed")
    } catch let error as NormalizedContextStoreError {
      #expect(error == .corruptPayload("invalid conversation token budget"))
    }

    let messages = history(count: 3, conversationSeed: 81)
    let malformedSnapshot = makeSnapshot(
      id: id(1_512),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 2,
      previous: id(1_599),
      mode: .extend,
      chainDepth: .max
    )
    do {
      _ = try harness.store.activeCompactionSnapshot(
        conversationID: conversationID,
        canonicalMessages: messages,
        legacySnapshotData: JSONEncoder().encode(malformedSnapshot)
      )
      Issue.record("Expected the legacy chain depth to fail closed")
    } catch let error as NormalizedContextStoreError {
      #expect(error == .compactionPrefixMismatch(malformedSnapshot.id))
    }
  }

  @MainActor
  @Test
  func summarizedRecallRoundTripsAndRestoreAcceptsIntentionalSummaryOverlap() throws {
    let harness = try makeHarness()
    let conversationID = id(1_515)
    let messages = history(count: 7, conversationSeed: 815)
    let snapshot = makeSnapshot(
      id: id(1_516),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 2,
      mode: .initial,
      chainDepth: 1
    )
    let recalledID = messages[0].id
    let base = makeRequestReceipt(
      messages: messages,
      snapshot: snapshot,
      status: .generated,
      attemptID: id(1_517)
    )

    func makeReceipt(origin: SameConversationRecallOrigin) -> RequestContextReceipt {
      let recall = SameConversationRecallReceipt(
        conversationID: conversationID,
        items: [
          SameConversationRecallItem(
            id: recalledID,
            origin: origin,
            title: "Earlier preference",
            content: messages[0].content,
            createdAt: fixedDate,
            relevance: 0.95,
            isTruncated: false
          )
        ],
        eligibleCandidateCount: 1,
        injectedInputTokens: 12
      )
      let rawIDs = [messages.last!.id]
      let represented = Set(snapshot.coveredMessageIDs + rawIDs + [recalledID])
      return RequestContextReceipt(
        curatedContext: base.curatedContext,
        retrievedContext: base.retrievedContext,
        projectContext: base.projectContext,
        conversationContext: ConversationContextReceipt(
          strategy: .summaryAndRecent,
          originalMessageCount: messages.count,
          includedMessageIDs: rawIDs,
          omittedMessageIDs: messages.map(\.id).filter { !represented.contains($0) },
          summarizedMessageIDs: snapshot.coveredMessageIDs,
          recalledMessageIDs: [recalledID],
          estimatedInputTokens: 500,
          contextWindowTokens: 8_192,
          maximumOutputTokens: 1_024,
          safetyMarginTokens: 256
        ),
        sameConversationRecall: recall,
        conversationCompaction: base.conversationCompaction,
        createdAt: fixedDate
      )
    }

    let receipt = makeReceipt(origin: .summarized)
    let assistantID = id(1_518)
    _ = try harness.store.appendRequestEvent(
      assistantMessageID: assistantID,
      conversationID: conversationID,
      sourceThroughMessageID: #require(messages.last?.id),
      eventSequence: 0,
      receipt: receipt,
      canonicalMessages: messages,
      activeCompactionSnapshot: snapshot,
      createdAt: fixedDate
    )

    #expect(
      try harness.store.requestReceipt(
        assistantMessageID: assistantID,
        canonicalMessages: messages
      ) == receipt
    )
    try harness.store.validateRequestEventForRestore(
      assistantMessageID: assistantID,
      eventSequence: 0,
      canonicalMessageIndices: Dictionary(
        uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) }
      )
    )
    try harness.store.validateLegacyRequestReceipt(
      receipt,
      conversationID: conversationID,
      canonicalMessages: messages,
      legacyCompactionSnapshot: snapshot
    )

    let misclassified = makeReceipt(origin: .omitted)
    do {
      _ = try harness.store.appendRequestEvent(
        assistantMessageID: id(1_519),
        conversationID: conversationID,
        sourceThroughMessageID: #require(messages.last?.id),
        eventSequence: 0,
        receipt: misclassified,
        canonicalMessages: messages,
        createdAt: fixedDate
      )
      Issue.record("Expected a misclassified summary recall to fail live validation")
    } catch let error as NormalizedContextStoreError {
      #expect(
        error
          == .receiptPartitionMismatch(
            "same-chat recall origin disagrees with summary membership"
          )
      )
    }
    do {
      try harness.store.validateLegacyRequestReceipt(
        misclassified,
        conversationID: conversationID,
        canonicalMessages: messages,
        legacyCompactionSnapshot: snapshot
      )
      Issue.record("Expected a misclassified legacy summary recall to fail validation")
    } catch let error as NormalizedContextStoreError {
      #expect(error == .corruptPayload("invalid legacy same-chat recall origin"))
    }

    let storedEvent = try #require(
      harness.context.fetch(FetchDescriptor<RequestContextEventRecord>()).first
    )
    var payload = try #require(
      JSONSerialization.jsonObject(with: storedEvent.payloadData) as? [String: Any]
    )
    var recallPayload = try #require(payload["sameConversationRecall"] as? [String: Any])
    var recallItems = try #require(recallPayload["items"] as? [[String: Any]])
    var recalledItem = try #require(recallItems.first)
    recalledItem["origin"] = SameConversationRecallOrigin.omitted.rawValue
    recallItems[0] = recalledItem
    recallPayload["items"] = recallItems
    payload["sameConversationRecall"] = recallPayload
    let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let fingerprint = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
    let storedEventID = storedEvent.id
    let storedEventKey = storedEvent.eventKey
    let storedAssistantMessageID = storedEvent.assistantMessageID
    let storedConversationID = storedEvent.conversationID
    let storedSourceThroughMessageID = storedEvent.sourceThroughMessageID
    let storedSourceMessageCount = storedEvent.sourceMessageCount
    let storedEventSequence = storedEvent.eventSequence
    let storedLegacyReceiptFingerprint = storedEvent.legacyReceiptFingerprint
    let storedCreatedAt = storedEvent.createdAt
    harness.context.delete(storedEvent)
    try harness.context.save()
    harness.context.insert(
      RequestContextEventRecord(
        id: storedEventID,
        eventKey: storedEventKey,
        assistantMessageID: storedAssistantMessageID,
        conversationID: storedConversationID,
        sourceThroughMessageID: storedSourceThroughMessageID,
        sourceMessageCount: storedSourceMessageCount,
        eventSequence: storedEventSequence,
        payloadData: payloadData,
        payloadFingerprint: fingerprint,
        legacyReceiptFingerprint: storedLegacyReceiptFingerprint,
        createdAt: storedCreatedAt
      )
    )
    try harness.context.save()
    do {
      try harness.store.validateRequestEventForRestore(
        assistantMessageID: assistantID,
        eventSequence: 0,
        canonicalMessageIndices: Dictionary(
          uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) }
        )
      )
      Issue.record("Expected restore to reject a misclassified summary recall")
    } catch let error as NormalizedContextStoreError {
      #expect(error == .corruptPayload("invalid same-chat recall audit"))
    }
  }

  @MainActor
  @Test
  func restoreFastPathRequiresExactRecallOrder() throws {
    let harness = try makeHarness()
    let conversationID = id(1_520)
    let messages = history(count: 7, conversationSeed: 82)
    let snapshot = makeSnapshot(
      id: id(1_521),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 2,
      mode: .initial,
      chainDepth: 1
    )
    let recalledIDs = [messages[2].id, messages[4].id]
    let recall = SameConversationRecallReceipt(
      conversationID: conversationID,
      items: [
        SameConversationRecallItem(
          id: recalledIDs[0],
          origin: .omitted,
          title: "Earlier A",
          content: messages[2].content,
          createdAt: fixedDate,
          relevance: 0.9,
          isTruncated: false
        ),
        SameConversationRecallItem(
          id: recalledIDs[1],
          origin: .omitted,
          title: "Earlier B",
          content: messages[4].content,
          createdAt: fixedDate.addingTimeInterval(1),
          relevance: 0.8,
          isTruncated: false
        ),
      ],
      eligibleCandidateCount: 2,
      injectedInputTokens: 20
    )
    let base = makeRequestReceipt(
      messages: messages,
      snapshot: snapshot,
      status: .generated,
      attemptID: id(1_522)
    )
    let represented = Set(snapshot.coveredMessageIDs + recalledIDs + [messages.last!.id])
    let receipt = RequestContextReceipt(
      curatedContext: base.curatedContext,
      retrievedContext: base.retrievedContext,
      conversationContext: ConversationContextReceipt(
        strategy: .summaryAndRecent,
        originalMessageCount: messages.count,
        includedMessageIDs: [messages.last!.id],
        omittedMessageIDs: messages.map(\.id).filter { !represented.contains($0) },
        summarizedMessageIDs: snapshot.coveredMessageIDs,
        recalledMessageIDs: recalledIDs,
        estimatedInputTokens: 500,
        contextWindowTokens: 8_192,
        maximumOutputTokens: 1_024,
        safetyMarginTokens: 256
      ),
      sameConversationRecall: recall,
      conversationCompaction: base.conversationCompaction,
      createdAt: fixedDate
    )
    let assistantID = id(1_523)
    _ = try harness.store.appendRequestEvent(
      assistantMessageID: assistantID,
      conversationID: conversationID,
      sourceThroughMessageID: #require(messages.last?.id),
      eventSequence: 0,
      receipt: receipt,
      canonicalMessages: messages,
      activeCompactionSnapshot: snapshot,
      createdAt: fixedDate
    )
    let original = try #require(
      harness.context.fetch(FetchDescriptor<RequestContextEventRecord>()).first
    )
    var payload = try #require(
      JSONSerialization.jsonObject(with: original.payloadData) as? [String: Any]
    )
    var recallPayload = try #require(payload["sameConversationRecall"] as? [String: Any])
    let items = try #require(recallPayload["items"] as? [Any])
    recallPayload["items"] = Array(items.reversed())
    payload["sameConversationRecall"] = recallPayload
    let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let fingerprint = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
    harness.context.delete(original)
    try harness.context.save()
    harness.context.insert(
      RequestContextEventRecord(
        id: NormalizedContextStore.eventID(
          assistantMessageID: assistantID,
          eventSequence: 0
        ),
        eventKey: NormalizedContextStore.eventKey(
          assistantMessageID: assistantID,
          eventSequence: 0
        ),
        assistantMessageID: assistantID,
        conversationID: conversationID,
        sourceThroughMessageID: messages.last!.id,
        sourceMessageCount: messages.count,
        eventSequence: 0,
        payloadData: payloadData,
        payloadFingerprint: fingerprint,
        legacyReceiptFingerprint: nil,
        createdAt: fixedDate
      )
    )
    try harness.context.save()

    do {
      try harness.store.validateRequestEventForRestore(
        assistantMessageID: assistantID,
        eventSequence: 0,
        canonicalMessageIndices: Dictionary(
          uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) }
        )
      )
      Issue.record("Expected reordered recall provenance to fail closed")
    } catch let error as NormalizedContextStoreError {
      #expect(error == .corruptPayload("invalid same-chat recall audit"))
    }
  }

  @MainActor
  @Test
  func restoreFastPathRejectsIncompleteActiveProvenance() throws {
    let harness = try makeHarness()
    let conversationID = id(1_530)
    let messages = history(count: 3, conversationSeed: 83)
    let snapshot = makeSnapshot(
      id: id(1_531),
      conversationID: conversationID,
      messages: messages,
      coveredCount: 2,
      mode: .initial,
      chainDepth: 1
    )
    let receipt = makeRequestReceipt(
      messages: messages,
      snapshot: snapshot,
      status: .generated,
      attemptID: id(1_532)
    )
    let assistantID = id(1_533)
    _ = try harness.store.appendRequestEvent(
      assistantMessageID: assistantID,
      conversationID: conversationID,
      sourceThroughMessageID: #require(messages.last?.id),
      eventSequence: 0,
      receipt: receipt,
      canonicalMessages: messages,
      activeCompactionSnapshot: snapshot,
      createdAt: fixedDate
    )
    let completeArtifact = try #require(
      harness.context.fetch(FetchDescriptor<CompactionArtifactRecord>()).first
    )
    harness.context.delete(completeArtifact)
    try harness.context.save()
    harness.context.insert(
      try NormalizedContextStoreTestSupport.artifact(
        id: snapshot.id,
        conversationID: conversationID,
        coverageParentArtifactID: nil,
        coverageDelta: snapshot.coveredMessageIDs,
        coveredMessageCount: snapshot.coveredMessageIDs.count,
        renderedSummary: snapshot.renderedSummary,
        providerConfigurationID: snapshot.providerConfigurationID,
        modelIdentifier: nil,
        createdAt: snapshot.createdAt
      )
    )
    try harness.context.save()

    do {
      try harness.store.validateRequestEventForRestore(
        assistantMessageID: assistantID,
        eventSequence: 0,
        canonicalMessageIndices: Dictionary(
          uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) }
        )
      )
      Issue.record("Expected incomplete active provenance to fail closed")
    } catch let error as NormalizedContextStoreError {
      #expect(error == .corruptPayload("active summary provenance is incomplete"))
    }
  }

  @MainActor
  @Test
  func interruptedGeneratingAuditReconcilesOnceToABoundedTerminalEvent() throws {
    let harness = try makeHarness()
    let conversationID = id(1_540)
    let messages = history(count: 3, conversationSeed: 84)
    let assistantID = id(1_541)
    let generating = ConversationCompactionReceipt(
      attemptID: id(1_542),
      status: .generating,
      attemptedMessageIDs: Array(messages.prefix(2)).map(\.id),
      providerConfigurationID: id(1_543),
      providerKind: .anthropic,
      providerDisplayName: "Anthropic",
      providerEndpoint: "https://api.anthropic.com:443/v1",
      modelIdentifier: "claude-test",
      providerMessageID: nil,
      inputTokenCount: nil,
      outputTokenCount: nil,
      estimatedInputTokensBefore: 800,
      estimatedInputTokensAfter: nil,
      extraRequestCount: 1,
      warnings: ["Request opening was recorded before streaming."],
      createdAt: fixedDate
    )
    let receipt = RequestContextReceipt(
      curatedContext: .empty,
      retrievedContext: .empty,
      conversationCompaction: generating,
      createdAt: fixedDate
    )
    _ = try harness.store.appendRequestEvent(
      assistantMessageID: assistantID,
      conversationID: conversationID,
      sourceThroughMessageID: #require(messages.last?.id),
      eventSequence: 0,
      receipt: receipt,
      canonicalMessages: messages,
      createdAt: fixedDate
    )

    #expect(
      try harness.store.reconcileInterruptedGeneratingEvents(
        conversationID: conversationID,
        canonicalMessages: messages,
        at: fixedDate.addingTimeInterval(10)
      ) == 1
    )
    let reconciled = try #require(
      try harness.store.requestReceipt(
        assistantMessageID: assistantID,
        canonicalMessages: messages
      )
    )
    #expect(reconciled.conversationCompaction?.status == .failed)
    #expect(reconciled.curatedContext.isEmpty)
    #expect(reconciled.retrievedContext.isEmpty)
    #expect(
      try harness.store.reconcileInterruptedGeneratingEvents(
        conversationID: conversationID,
        canonicalMessages: messages,
        at: fixedDate.addingTimeInterval(20)
      ) == 0
    )
  }

  @MainActor
  private func assertCorruptChain(
    expected: NormalizedContextStoreError,
    prepare: (
      Harness,
      UUID,
      [AIChatMessage],
      (UUID, [UUID], String) -> RequestContextReceipt
    ) throws -> RequestContextReceipt
  ) throws {
    let harness = try makeHarness()
    let conversationID = id(1_700)
    let messages = history(count: 3, conversationSeed: 17)
    let receipt = try prepare(
      harness,
      conversationID,
      messages,
      { artifactID, coverage, summary in
        corruptArtifactReceipt(
          messages: messages,
          artifactID: artifactID,
          coverage: coverage,
          summary: summary
        )
      }
    )
    do {
      _ = try harness.store.appendRequestEvent(
        assistantMessageID: UUID(),
        conversationID: conversationID,
        sourceThroughMessageID: try #require(messages.last?.id),
        eventSequence: 0,
        receipt: receipt,
        canonicalMessages: messages,
        createdAt: fixedDate
      )
      Issue.record("Expected corrupt normalized compaction data to fail closed")
    } catch let error as NormalizedContextStoreError {
      #expect(error == expected)
    }
  }

  @MainActor
  private func makeHarness() throws -> Harness {
    let schema = Schema([
      RequestContextEventRecord.self,
      CompactionArtifactRecord.self,
      ConversationCompactionHeadRecord.self,
      NormalizedContextBackfillProgressRecord.self,
    ])
    let configuration = ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: true,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)
    return Harness(
      container: container,
      context: context,
      store: NormalizedContextStore(modelContext: context)
    )
  }

  private func history(count: Int, conversationSeed: Int) -> [AIChatMessage] {
    (0..<count).map { index in
      AIChatMessage(
        id: deterministicMessageID(seed: conversationSeed, index: index),
        role: index.isMultiple(of: 2) ? .user : .assistant,
        content: "message-\(conversationSeed)-\(index)"
      )
    }
  }

  private func makeSnapshot(
    id snapshotID: UUID,
    conversationID: UUID,
    messages: [AIChatMessage],
    coveredCount: Int,
    previous: UUID? = nil,
    mode: ConversationCompactionMode,
    chainDepth: Int,
    createdAt: Date? = nil,
    overview: String? = nil
  ) -> ConversationCompactionSnapshot {
    let covered = Array(messages.prefix(coveredCount))
    return ConversationCompactionSnapshot(
      id: snapshotID,
      conversationID: conversationID,
      previousCompactionID: previous,
      mode: mode,
      content: ConversationCompactionContent(
        overview: overview ?? "Summary through \(coveredCount)",
        items: [ConversationCompactionItem(kind: .fact, text: "Fact \(coveredCount)")]
      ),
      coveredMessageIDs: covered.map(\.id),
      sourceFingerprint: ConversationCompactionPlanner.sourceFingerprint(for: covered),
      providerConfigurationID: self.id(80),
      providerKind: .openAI,
      providerDisplayName: "OpenAI",
      providerEndpoint: "https://api.openai.com:443/v1",
      modelIdentifier: "gpt-test",
      providerMessageID: "summary-\(coveredCount)",
      inputTokenCount: 100,
      outputTokenCount: 20,
      estimatedSourceTokens: 120,
      estimatedSummaryTokens: 30,
      chainDepth: chainDepth,
      warnings: ["snapshot-warning"],
      createdAt: createdAt ?? fixedDate.addingTimeInterval(Double(coveredCount))
    )
  }

  private func makeRequestReceipt(
    messages: [AIChatMessage],
    snapshot: ConversationCompactionSnapshot?,
    status: ConversationCompactionAttemptStatus,
    attemptID: UUID
  ) -> RequestContextReceipt {
    let rawCount = min(1, messages.count)
    let rawIDs = Array(messages.suffix(rawCount)).map(\.id)
    let summaryIDs = snapshot?.coveredMessageIDs ?? []
    let represented = Set(rawIDs + summaryIDs)
    let omitted = messages.map(\.id).filter { !represented.contains($0) }
    let conversation = ConversationContextReceipt(
      strategy: snapshot == nil ? .recentOnly : .summaryAndRecent,
      originalMessageCount: messages.count,
      includedMessageIDs: rawIDs,
      omittedMessageIDs: omitted,
      summarizedMessageIDs: snapshot == nil ? nil : summaryIDs,
      recalledMessageIDs: nil,
      estimatedInputTokens: 500,
      contextWindowTokens: 8_192,
      maximumOutputTokens: 1_024,
      safetyMarginTokens: 256,
      warnings: ["context-warning"]
    )
    let compaction = ConversationCompactionReceipt(
      attemptID: attemptID,
      status: status,
      compactionID: snapshot?.id,
      summaryText: snapshot?.renderedSummary,
      coveredMessageIDs: summaryIDs,
      attemptedMessageIDs: status == .reused ? nil : Array(messages.prefix(2)).map(\.id),
      activeSummaryProviderConfigurationID: snapshot?.providerConfigurationID,
      activeSummaryProviderKind: snapshot?.providerKind,
      activeSummaryProviderDisplayName: snapshot?.providerDisplayName,
      activeSummaryProviderEndpoint: snapshot?.providerEndpoint,
      activeSummaryModelIdentifier: snapshot?.modelIdentifier,
      activeSummaryCreatedAt: snapshot?.createdAt,
      providerConfigurationID: id(81),
      providerKind: status == .failed ? .deepInfra : .openAI,
      providerDisplayName: status == .failed ? "DeepInfra" : "OpenAI",
      providerEndpoint: status == .failed
        ? "https://api.deepinfra.com:443/v1/openai"
        : "https://api.openai.com:443/v1",
      modelIdentifier: "attempt-model",
      providerMessageID: status == .reused ? snapshot?.providerMessageID : "attempt-response",
      inputTokenCount: 44,
      outputTokenCount: 8,
      estimatedInputTokensBefore: 1_000,
      estimatedInputTokensAfter: status == .cancelled ? nil : 500,
      extraRequestCount: status == .reused ? 0 : 1,
      errorDescription: status == .failed ? "Invalid summary" : nil,
      warnings: ["attempt-warning"],
      createdAt: fixedDate.addingTimeInterval(50)
    )
    return RequestContextReceipt(
      curatedContext: .empty,
      retrievedContext: .empty,
      projectContext: ProjectContextReceipt(
        projectID: id(82),
        name: "Memory Project",
        instructions: "Keep answers grounded in this project's sources."
      ),
      conversationContext: conversation,
      conversationCompaction: compaction,
      createdAt: fixedDate.addingTimeInterval(100)
    )
  }

  private func makeRecentOnlyReceipt(
    messages: [AIChatMessage],
    rawCount: Int
  ) -> RequestContextReceipt {
    let included = Array(messages.suffix(rawCount)).map(\.id)
    let includedSet = Set(included)
    return RequestContextReceipt(
      curatedContext: .empty,
      retrievedContext: .empty,
      conversationContext: ConversationContextReceipt(
        strategy: included.count == messages.count ? .full : .recentOnly,
        originalMessageCount: messages.count,
        includedMessageIDs: included,
        omittedMessageIDs: messages.map(\.id).filter { !includedSet.contains($0) },
        estimatedInputTokens: 400,
        contextWindowTokens: 8_192,
        maximumOutputTokens: 1_024,
        safetyMarginTokens: 256,
        warnings: []
      ),
      createdAt: fixedDate
    )
  }

  private func corruptArtifactReceipt(
    messages: [AIChatMessage],
    artifactID: UUID,
    coverage: [UUID],
    summary: String
  ) -> RequestContextReceipt {
    let rawID = messages.last!.id
    let represented = Set(coverage + [rawID])
    let conversation = ConversationContextReceipt(
      strategy: .summaryAndRecent,
      originalMessageCount: messages.count,
      includedMessageIDs: [rawID],
      omittedMessageIDs: messages.map(\.id).filter { !represented.contains($0) },
      summarizedMessageIDs: coverage,
      estimatedInputTokens: 100,
      contextWindowTokens: 4_096,
      maximumOutputTokens: 512,
      safetyMarginTokens: 128
    )
    let compaction = ConversationCompactionReceipt(
      attemptID: id(1_600),
      status: .reused,
      compactionID: artifactID,
      summaryText: summary,
      coveredMessageIDs: coverage,
      activeSummaryProviderConfigurationID: id(80),
      activeSummaryProviderKind: .openAI,
      activeSummaryProviderDisplayName: "OpenAI",
      activeSummaryProviderEndpoint: "https://api.openai.com:443/v1",
      activeSummaryModelIdentifier: "test-model",
      activeSummaryCreatedAt: fixedDate,
      providerConfigurationID: id(80),
      providerKind: .openAI,
      providerDisplayName: "OpenAI",
      providerEndpoint: "https://api.openai.com:443/v1",
      modelIdentifier: "test-model",
      estimatedInputTokensBefore: 200,
      estimatedInputTokensAfter: 100,
      extraRequestCount: 0,
      createdAt: fixedDate
    )
    return RequestContextReceipt(
      curatedContext: .empty,
      retrievedContext: .empty,
      conversationContext: conversation,
      conversationCompaction: compaction,
      createdAt: fixedDate
    )
  }

  private func id(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
  }

  private func deterministicMessageID(seed: Int, index: Int) -> UUID {
    let value = UInt64(seed) * 1_000_000 + UInt64(index + 1)
    return UUID(uuidString: String(format: "10000000-0000-0000-0000-%012llx", value))!
  }
}

@MainActor
private struct Harness {
  let container: ModelContainer
  let context: ModelContext
  let store: NormalizedContextStore
}

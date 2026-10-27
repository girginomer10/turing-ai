import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite("Automatic memory store", .serialized)
@MainActor
struct AutomaticMemoryStoreTests {
  private let baseDate = Date(timeIntervalSince1970: 1_750_000_000)

  @Test("creates a topic with exact evidence, revision history, and a completed idempotent job")
  func createAndReplayAreAtomicAndIdempotent() async throws {
    let harness = try makeHarness(
      userContent: "Yanıtlarını Türkçe vermeni tercih ediyorum."
    )
    let store = AutomaticMemoryStore(modelContainer: harness.container)
    let enqueuedJobID = try await store.enqueue(
      conversationID: harness.conversationID,
      throughUserMessageID: harness.userMessageID,
      assistantMessageID: harness.assistantMessageID,
      provider: harness.provider,
      now: baseDate
    )
    let jobID = try #require(enqueuedJobID)
    let prepared = try await store.prepare(
      jobID: jobID,
      provider: harness.provider,
      now: baseDate.addingTimeInterval(1)
    )
    let preparation = try #require(prepared)
    let result = generationResult(
      preparation: preparation,
      provider: harness.provider,
      operation: operation(
        canonicalKey: "preference.response_language",
        title: "Yanıt dili",
        content: "Kullanıcı yanıtların Türkçe olmasını tercih ediyor.",
        evidenceMessageID: harness.userMessageID
      )
    )

    let applied = try await store.apply(result, now: baseDate.addingTimeInterval(2))
    #expect(applied == AutomaticMemoryFormationResult(createdCount: 1))

    let topics = try harness.context.fetch(FetchDescriptor<MemoryTopicRecord>())
    let topic = try #require(topics.first)
    #expect(topics.count == 1)
    #expect(topic.canonicalKey == "global:preference:response_language")
    #expect(topic.content == "Kullanıcı yanıtların Türkçe olmasını tercih ediyor.")
    #expect(topic.status == .active)
    #expect(topic.origin == .automatic)
    #expect(topic.evidenceCount == 1)
    #expect(topic.revision == 1)

    let evidence = try #require(
      harness.context.fetch(FetchDescriptor<MemoryEvidenceRecord>()).first
    )
    #expect(evidence.topicID == topic.id)
    #expect(evidence.conversationID == harness.conversationID)
    #expect(evidence.sourceMessageID == harness.userMessageID)
    #expect(evidence.assistantMessageID == harness.assistantMessageID)
    #expect(evidence.excerpt == "Yanıtlarını Türkçe vermeni tercih ediyorum.")
    #expect(evidence.sourceFingerprint == preparation.sourceFingerprint)
    #expect(evidence.providerConfigurationID == harness.provider.id)
    #expect(evidence.providerKindRawValue == ProviderKind.openAI.rawValue)
    #expect(evidence.modelIdentifier == harness.provider.modelIdentifier)

    let revision = try #require(
      harness.context.fetch(FetchDescriptor<MemoryRevisionRecord>()).first
    )
    #expect(revision.topicID == topic.id)
    #expect(revision.sequence == 1)
    #expect(revision.kindRawValue == MemoryRevisionKind.created.rawValue)
    #expect(revision.previousTitle == nil)
    #expect(revision.previousContent == nil)
    #expect(revision.sourceEvidenceID == evidence.id)

    let job = try #require(
      harness.context.fetch(FetchDescriptor<MemoryFormationJobRecord>()).first
    )
    #expect(job.id == jobID)
    #expect(job.status == .complete)
    #expect(job.attemptCount == 1)
    #expect(job.outputFingerprint != nil)
    #expect(job.completedAt == baseDate.addingTimeInterval(2))

    let audit = try #require(
      harness.context.fetch(FetchDescriptor<MemoryFormationAuditRecord>()).first
    )
    #expect(audit.jobID == jobID)
    #expect(audit.jobKey == job.jobKey)
    #expect(audit.outcome == .complete)
    #expect(audit.attemptCount == 1)
    #expect(audit.providerMessageID == "provider-memory-response")
    #expect(audit.inputTokenCount == 120)
    #expect(audit.outputTokenCount == 45)
    #expect(audit.providerRequestCount == 1)
    #expect(audit.cumulativeInputTokenCount == 120)
    #expect(audit.cumulativeOutputTokenCount == 45)
    #expect(audit.snapshot.totalTokenCount == 165)
    #expect(audit.snapshot.cumulativeTotalTokenCount == 165)
    #expect(audit.startedAt == baseDate.addingTimeInterval(1))
    #expect(audit.finishedAt == baseDate.addingTimeInterval(2))
    #expect(audit.errorDescription == nil)

    let replay = try await store.apply(result, now: baseDate.addingTimeInterval(3))
    #expect(replay == AutomaticMemoryFormationResult())
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryTopicRecord>()) == 1)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryEvidenceRecord>()) == 1)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryRevisionRecord>()) == 1)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryFormationAuditRecord>()) == 1)
    #expect(
      try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(4)
      ) == nil
    )
  }

  @Test("failed attempts persist bounded telemetry and cumulative retry usage")
  func failedAttemptsPersistBoundedTelemetryAndCumulativeRetryUsage() async throws {
    let harness = try makeHarness(userContent: "Kalıcı tercihim kısa yanıtlar.")
    let store = AutomaticMemoryStore(modelContainer: harness.container)
    let jobID = try #require(
      try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider,
        now: baseDate
      )
    )
    _ = try #require(
      try await store.prepare(
        jobID: jobID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(1)
      )
    )
    let oversizedMessageID = String(
      repeating: "x",
      count: MosaicSourceFieldLimits.maximumMemoryProvenanceUTF8Bytes + 1
    )
    try await store.markFailed(
      jobID: jobID,
      error: AutomaticMemoryExtractionError.invalidOutput,
      telemetry: AutomaticMemoryExtractionAttemptTelemetry(
        requestStarted: true,
        providerMessageID: oversizedMessageID,
        inputTokenCount: -1,
        outputTokenCount: 77
      ),
      now: baseDate.addingTimeInterval(2)
    )

    var audit = try #require(
      harness.context.fetch(FetchDescriptor<MemoryFormationAuditRecord>()).first
    )
    let auditID = audit.id
    #expect(audit.outcome == .failed)
    #expect(audit.attemptCount == 1)
    #expect(audit.requestStarted)
    #expect(audit.providerMessageID == nil)
    #expect(audit.inputTokenCount == nil)
    #expect(audit.outputTokenCount == 77)
    #expect(audit.providerRequestCount == 1)
    #expect(audit.cumulativeInputTokenCount == 0)
    #expect(audit.cumulativeOutputTokenCount == 77)
    #expect(audit.didDiscardInvalidTelemetry)
    #expect(audit.errorDescription != nil)

    // A duplicate outer catch must not erase the richer receipt written by the coordinator.
    try await store.markFailed(
      jobID: jobID,
      error: AutomaticMemoryExtractionError.emptyResponse,
      now: baseDate.addingTimeInterval(3)
    )
    audit = try #require(
      harness.context.fetch(FetchDescriptor<MemoryFormationAuditRecord>()).first
    )
    #expect(audit.updatedAt == baseDate.addingTimeInterval(2))
    #expect(audit.outputTokenCount == 77)

    _ = try #require(
      try await store.prepare(
        jobID: jobID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(4)
      )
    )
    try await store.markFailed(
      jobID: jobID,
      error: AutomaticMemoryExtractionError.incompleteResponse,
      telemetry: AutomaticMemoryExtractionAttemptTelemetry(
        requestStarted: true,
        providerMessageID: "retry-response",
        inputTokenCount: 20,
        outputTokenCount: 10
      ),
      now: baseDate.addingTimeInterval(5)
    )
    audit = try #require(
      harness.context.fetch(FetchDescriptor<MemoryFormationAuditRecord>()).first
    )
    #expect(audit.id == auditID)
    #expect(audit.attemptCount == 2)
    #expect(audit.providerMessageID == "retry-response")
    #expect(audit.inputTokenCount == 20)
    #expect(audit.outputTokenCount == 10)
    #expect(audit.providerRequestCount == 2)
    #expect(audit.cumulativeInputTokenCount == 20)
    #expect(audit.cumulativeOutputTokenCount == 87)
    #expect(audit.didDiscardInvalidTelemetry)
  }

  @Test("durable request receipts stop crash recovery resends and count one explicit retry")
  func durableRequestReceiptReconcilesCrashWithoutAutomaticResend() async throws {
    let harness = try makeHarness(userContent: "Kalıcı tercihim kısa yanıtlar.")
    let store = AutomaticMemoryStore(modelContainer: harness.container)
    let jobID = try #require(
      try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider,
        now: baseDate
      )
    )
    _ = try #require(
      try await store.prepare(
        jobID: jobID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(1)
      )
    )
    try await store.markRequestStarted(
      jobID: jobID,
      provider: harness.provider,
      expectedProjectID: nil,
      now: baseDate.addingTimeInterval(2)
    )
    let firstUsage = AutomaticMemoryExtractionAttemptTelemetry(
      requestStarted: true,
      providerMessageID: "first-attempt",
      inputTokenCount: 19,
      outputTokenCount: 7
    )
    try await store.recordAttemptTelemetry(
      jobID: jobID,
      provider: harness.provider,
      telemetry: firstUsage,
      now: baseDate.addingTimeInterval(2.25)
    )
    try await store.recordAttemptTelemetry(
      jobID: jobID,
      provider: harness.provider,
      telemetry: firstUsage,
      now: baseDate.addingTimeInterval(2.5)
    )

    var job = try #require(
      harness.context.fetch(FetchDescriptor<MemoryFormationJobRecord>()).first
    )
    var audit = try #require(
      harness.context.fetch(FetchDescriptor<MemoryFormationAuditRecord>()).first
    )
    #expect(job.status == .generating)
    #expect(job.startedAt == baseDate.addingTimeInterval(2))
    #expect(audit.outcome == .generating)
    #expect(audit.providerRequestCount == 1)
    #expect(audit.cumulativeInputTokenCount == 19)
    #expect(audit.cumulativeOutputTokenCount == 7)

    let relaunchedStore = AutomaticMemoryStore(modelContainer: harness.container)
    let automaticallyRetryable = try await relaunchedStore.pendingJobs(
      now: baseDate.addingTimeInterval(3)
    )
    #expect(automaticallyRetryable.isEmpty)
    job = try #require(
      harness.context.fetch(FetchDescriptor<MemoryFormationJobRecord>()).first
    )
    audit = try #require(
      harness.context.fetch(FetchDescriptor<MemoryFormationAuditRecord>()).first
    )
    #expect(job.status == .failed)
    #expect(audit.outcome == .failed)
    #expect(audit.attemptCount == 1)
    #expect(audit.providerRequestCount == 1)
    #expect(audit.cumulativeInputTokenCount == 19)
    #expect(audit.cumulativeOutputTokenCount == 7)
    #expect(audit.errorDescription?.contains("not retried automatically") == true)

    _ = try #require(
      try await relaunchedStore.prepare(
        jobID: jobID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(4)
      )
    )
    try await relaunchedStore.markRequestStarted(
      jobID: jobID,
      provider: harness.provider,
      expectedProjectID: nil,
      now: baseDate.addingTimeInterval(5)
    )
    await #expect(throws: AutomaticMemoryStoreError.interruptedRequestRequiresExplicitRetry) {
      try await relaunchedStore.markRequestStarted(
        jobID: jobID,
        provider: harness.provider,
        expectedProjectID: nil,
        now: baseDate.addingTimeInterval(5.25)
      )
    }
    let retryUsage = AutomaticMemoryExtractionAttemptTelemetry(
      requestStarted: true,
      providerMessageID: "second-attempt",
      inputTokenCount: 23,
      outputTokenCount: 11
    )
    try await relaunchedStore.recordAttemptTelemetry(
      jobID: jobID,
      provider: harness.provider,
      telemetry: retryUsage,
      now: baseDate.addingTimeInterval(6)
    )
    try await relaunchedStore.recordAttemptTelemetry(
      jobID: jobID,
      provider: harness.provider,
      telemetry: retryUsage,
      now: baseDate.addingTimeInterval(6.25)
    )
    try await relaunchedStore.markFailed(
      jobID: jobID,
      error: AutomaticMemoryExtractionError.incompleteResponse,
      now: baseDate.addingTimeInterval(7)
    )

    audit = try #require(
      harness.context.fetch(FetchDescriptor<MemoryFormationAuditRecord>()).first
    )
    #expect(audit.outcome == .failed)
    #expect(audit.attemptCount == 2)
    #expect(audit.providerRequestCount == 2)
    #expect(audit.providerMessageID == "second-attempt")
    #expect(audit.inputTokenCount == 23)
    #expect(audit.outputTokenCount == 11)
    #expect(audit.cumulativeInputTokenCount == 42)
    #expect(audit.cumulativeOutputTokenCount == 18)
  }

  @Test("coordinator preserves retryability when a fresh generation could fix invalid output")
  func coordinatorPersistsProviderUsageWhenExtractionOutputIsRejected() async throws {
    let harness = try makeHarness(userContent: "Bunu uzun süre hatırla.")
    let client = MemoryFormationTelemetryStubClient(events: [
      .usage(TokenUsage(inputTokens: 33)),
      .textDelta("{}"),
      .usage(TokenUsage(outputTokens: 11)),
      .completed(responseID: "rejected-memory-response"),
    ])

    await #expect(throws: AutomaticMemoryExtractionError.invalidOutput) {
      try await AutomaticMemoryFormationCoordinator().formMemory(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider,
        client: client,
        modelContainer: harness.container
      )
    }

    let audit = try #require(
      harness.context.fetch(FetchDescriptor<MemoryFormationAuditRecord>()).first
    )
    #expect(audit.outcome == .failed)
    #expect(audit.requestStarted)
    #expect(audit.providerMessageID == "rejected-memory-response")
    #expect(audit.inputTokenCount == 33)
    #expect(audit.outputTokenCount == 11)
    #expect(audit.providerRequestCount == 1)
    #expect(audit.cumulativeInputTokenCount == 33)
    #expect(audit.cumulativeOutputTokenCount == 11)
    #expect(audit.errorDescription?.contains("could not validate") == true)

    let job = try #require(
      harness.context.fetch(FetchDescriptor<MemoryFormationJobRecord>()).first
    )
    #expect(job.status == .failed)
    #expect(
      try await AutomaticMemoryStore(modelContainer: harness.container).enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider
      ) == job.id
    )
  }

  @Test("only immutable local source failures become non-retryable")
  func nonRetryableFailureClassificationIsConservative() {
    #expect(
      !AutomaticMemoryFormationCoordinator.isNonRetryableLocalFailure(
        AutomaticMemoryExtractionError.invalidPreparation
      )
    )
    #expect(
      AutomaticMemoryFormationCoordinator.isNonRetryableLocalFailure(
        AutomaticMemoryStoreError.sourceUnavailable
      )
    )
    #expect(
      AutomaticMemoryFormationCoordinator.isNonRetryableLocalFailure(
        AutomaticMemoryStoreError.counterOverflow
      )
    )
    #expect(
      !AutomaticMemoryFormationCoordinator.isNonRetryableLocalFailure(
        AutomaticMemoryExtractionError.responseTooLarge
      )
    )
    #expect(
      !AutomaticMemoryFormationCoordinator.isNonRetryableLocalFailure(
        AutomaticMemoryExtractionError.invalidOutput
      )
    )
    #expect(
      !AutomaticMemoryFormationCoordinator.isNonRetryableLocalFailure(
        AutomaticMemoryExtractionError.invalidEvidence(UUID())
      )
    )
    #expect(
      !AutomaticMemoryFormationCoordinator.isNonRetryableLocalFailure(
        AutomaticMemoryExtractionError.invalidTarget(UUID())
      )
    )
    #expect(
      !AutomaticMemoryFormationCoordinator.isNonRetryableLocalFailure(
        AutomaticMemoryStoreError.invalidOperation
      )
    )
  }

  @Test("a rejected local source failure remains terminal without reopening a request")
  func rejectedLocalFailureIsTerminal() async throws {
    let harness = try makeHarness(userContent: "Remember this immutable source.")
    let store = AutomaticMemoryStore(modelContainer: harness.container)
    let jobID = try #require(
      try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider,
        now: baseDate
      )
    )

    try await store.markRejected(
      jobID: jobID,
      error: AutomaticMemoryStoreError.counterOverflow,
      now: baseDate.addingTimeInterval(1)
    )
    try await store.markFailed(
      jobID: jobID,
      error: AutomaticMemoryExtractionError.invalidOutput,
      now: baseDate.addingTimeInterval(2)
    )

    let context = ModelContext(harness.container)
    let job = try #require(
      context.fetch(
        FetchDescriptor<MemoryFormationJobRecord>(predicate: #Predicate { $0.id == jobID })
      ).first
    )
    let audit = try #require(
      context.fetch(
        FetchDescriptor<MemoryFormationAuditRecord>(predicate: #Predicate { $0.jobID == jobID })
      ).first
    )
    #expect(job.status == .rejected)
    #expect(audit.outcome == .rejected)
    #expect(!audit.requestStarted)
    #expect(audit.providerRequestCount == 0)
    #expect(try await store.prepare(jobID: jobID, provider: harness.provider) == nil)
    #expect(
      try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider
      ) == nil
    )
  }

  @Test("reinforces, corrects, and forgets one canonical topic without losing provenance")
  func reinforcementUpdateAndForgetBuildAnOrderedHistory() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversationID = UUID()
    context.insert(ConversationRecord(id: conversationID, title: "Memory lifecycle"))
    try context.save()
    let store = AutomaticMemoryStore(modelContainer: container)
    let provider = makeProvider()

    let created = try await applyTurn(
      store: store,
      context: context,
      conversationID: conversationID,
      provider: provider,
      userContent: "Favori editörüm Xcode.",
      operation: { messageID, _ in
        operation(
          canonicalKey: "preference.editor",
          title: "Favori editör",
          content: "Kullanıcının favori editörü Xcode.",
          confidence: 0.75,
          importance: 0.55,
          stability: .evolving,
          evidenceMessageID: messageID
        )
      },
      at: baseDate
    )
    #expect(created == AutomaticMemoryFormationResult(createdCount: 1))
    let topicID = try #require(
      context.fetch(FetchDescriptor<MemoryTopicRecord>()).first?.id
    )

    let reinforced = try await applyTurn(
      store: store,
      context: context,
      conversationID: conversationID,
      provider: provider,
      userContent: "Evet, favori editörüm hâlâ Xcode.",
      operation: { messageID, _ in
        operation(
          targetID: topicID,
          canonicalKey: "preference.editor",
          title: "Favori editör",
          content: "Kullanıcının favori editörü Xcode.",
          confidence: 0.80,
          importance: 0.70,
          stability: .stable,
          evidenceMessageID: messageID
        )
      },
      at: baseDate.addingTimeInterval(10)
    )
    #expect(reinforced == AutomaticMemoryFormationResult(reinforcedCount: 1))

    let updated = try await applyTurn(
      store: store,
      context: context,
      conversationID: conversationID,
      provider: provider,
      userContent: "Artık favori editörüm Zed.",
      operation: { messageID, _ in
        operation(
          targetID: topicID,
          canonicalKey: "preference.editor",
          title: "Favori editör",
          content: "Kullanıcının favori editörü Zed.",
          confidence: 0.96,
          importance: 0.75,
          stability: .stable,
          evidenceMessageID: messageID
        )
      },
      at: baseDate.addingTimeInterval(20)
    )
    #expect(updated == AutomaticMemoryFormationResult(updatedCount: 1))

    let forgotten = try await applyTurn(
      store: store,
      context: context,
      conversationID: conversationID,
      provider: provider,
      userContent: "Favori editörümü unut.",
      operation: { messageID, _ in
        operation(
          action: .forget,
          targetID: topicID,
          canonicalKey: "preference.editor",
          title: "Favori editör",
          content: "Kullanıcının favori editörü Zed.",
          confidence: 1,
          importance: 0.75,
          stability: .stable,
          evidenceMessageID: messageID
        )
      },
      at: baseDate.addingTimeInterval(30)
    )
    #expect(forgotten == AutomaticMemoryFormationResult(forgottenCount: 1))

    let topic = try #require(
      context.fetch(
        FetchDescriptor<MemoryTopicRecord>(
          predicate: #Predicate { $0.id == topicID }
        )
      ).first
    )
    #expect(topic.content == "Kullanıcının favori editörü Zed.")
    #expect(topic.status == .forgotten)
    #expect(!topic.isEnabled)
    #expect(topic.evidenceCount == 4)
    #expect(topic.revision == 4)
    #expect(topic.importance == 0.75)
    #expect(topic.stability == .stable)
    #expect(topic.confidence == 0.96)

    let revisions = try context.fetch(
      FetchDescriptor<MemoryRevisionRecord>(
        sortBy: [SortDescriptor(\MemoryRevisionRecord.sequence)]
      )
    )
    #expect(revisions.map(\.sequence) == [1, 2, 3, 4])
    #expect(
      revisions.map(\.kindRawValue)
        == [
          MemoryRevisionKind.created.rawValue,
          MemoryRevisionKind.reinforced.rawValue,
          MemoryRevisionKind.updated.rawValue,
          MemoryRevisionKind.forgotten.rawValue,
        ]
    )
    #expect(revisions[2].previousContent == "Kullanıcının favori editörü Xcode.")
    #expect(revisions[2].content == "Kullanıcının favori editörü Zed.")
    #expect(try context.fetchCount(FetchDescriptor<MemoryEvidenceRecord>()) == 4)
    #expect(try context.fetchCount(FetchDescriptor<MemoryFormationJobRecord>()) == 4)
  }

  @Test("discards a result if its exact user source changed after provider work began")
  func staleSourceIsRejectedWithoutPartialMemoryWrites() async throws {
    let harness = try makeHarness(userContent: "Kalıcı tercihim koyu tema.")
    let store = AutomaticMemoryStore(modelContainer: harness.container)
    let enqueuedJobID = try await store.enqueue(
      conversationID: harness.conversationID,
      throughUserMessageID: harness.userMessageID,
      assistantMessageID: harness.assistantMessageID,
      provider: harness.provider,
      now: baseDate
    )
    let jobID = try #require(enqueuedJobID)
    let prepared = try await store.prepare(jobID: jobID, provider: harness.provider)
    let preparation = try #require(prepared)
    let result = generationResult(
      preparation: preparation,
      provider: harness.provider,
      operation: operation(
        canonicalKey: "preference.appearance",
        title: "Görünüm",
        content: "Kullanıcı koyu tema tercih ediyor.",
        evidenceMessageID: harness.userMessageID
      )
    )

    let userMessageID = harness.userMessageID
    let user = try #require(
      harness.context.fetch(
        FetchDescriptor<MessageRecord>(
          predicate: #Predicate { $0.id == userMessageID }
        )
      ).first
    )
    user.content = "Bu mesaj sağlayıcı çalışırken değişti."
    try harness.context.save()

    await #expect(throws: AutomaticMemoryStoreError.staleSource) {
      try await store.apply(result, now: baseDate.addingTimeInterval(2))
    }
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryTopicRecord>()) == 0)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryEvidenceRecord>()) == 0)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryRevisionRecord>()) == 0)
  }

  @Test("rejects mismatched provider provenance before making any memory mutation")
  func providerProvenanceMismatchIsAtomic() async throws {
    let harness = try makeHarness(userContent: "Kalıcı tercihim kısa yanıtlar.")
    let store = AutomaticMemoryStore(modelContainer: harness.container)
    let enqueuedJobID = try await store.enqueue(
      conversationID: harness.conversationID,
      throughUserMessageID: harness.userMessageID,
      assistantMessageID: harness.assistantMessageID,
      provider: harness.provider,
      now: baseDate
    )
    let jobID = try #require(enqueuedJobID)
    let otherProvider = ProviderConnection(
      id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
      displayName: "Other provider",
      provider: .anthropic,
      modelIdentifier: "other-memory-model"
    )
    await #expect(throws: AutomaticMemoryStoreError.providerUnavailable) {
      try await store.prepare(jobID: jobID, provider: otherProvider)
    }
    let pendingJob = try #require(
      harness.context.fetch(FetchDescriptor<MemoryFormationJobRecord>()).first
    )
    #expect(pendingJob.status == .pending)
    #expect(pendingJob.attemptCount == 0)

    let prepared = try await store.prepare(jobID: jobID, provider: harness.provider)
    let preparation = try #require(prepared)
    let result = generationResult(
      preparation: preparation,
      provider: otherProvider,
      operation: operation(
        canonicalKey: "preference.response_length",
        title: "Yanıt uzunluğu",
        content: "Kullanıcı kısa yanıtları tercih ediyor.",
        evidenceMessageID: harness.userMessageID
      )
    )

    await #expect(throws: AutomaticMemoryStoreError.staleSource) {
      try await store.apply(result, now: baseDate.addingTimeInterval(2))
    }
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryTopicRecord>()) == 0)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryEvidenceRecord>()) == 0)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryRevisionRecord>()) == 0)
    let job = try #require(
      harness.context.fetch(FetchDescriptor<MemoryFormationJobRecord>()).first
    )
    #expect(job.status == .generating)
    #expect(job.outputFingerprint == nil)
  }

  @Test("direct apply revalidates confidence and exact user evidence")
  func directApplyRejectsLowConfidenceAndWrongEvidenceAtomically() async throws {
    for invalidCase in [0, 1] {
      let harness = try makeHarness(userContent: "Her zaman Türkçe cevap ver.")
      let store = AutomaticMemoryStore(modelContainer: harness.container)
      let enqueuedJobID = try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider,
        now: baseDate
      )
      let jobID = try #require(enqueuedJobID)
      let prepared = try await store.prepare(jobID: jobID, provider: harness.provider)
      let preparation = try #require(prepared)
      let result = generationResult(
        preparation: preparation,
        provider: harness.provider,
        operation: operation(
          canonicalKey: "preference.response_language",
          title: "Yanıt dili",
          content: "Kullanıcı Türkçe yanıtları tercih ediyor.",
          confidence: invalidCase == 0
            ? AutomaticMemoryExtractor.minimumUpsertConfidence - 0.01 : 0.95,
          evidenceMessageID: invalidCase == 0 ? harness.userMessageID : UUID()
        )
      )

      await #expect(throws: AutomaticMemoryStoreError.invalidOperation) {
        try await store.apply(result, now: baseDate.addingTimeInterval(2))
      }
      #expect(try harness.context.fetchCount(FetchDescriptor<MemoryTopicRecord>()) == 0)
      #expect(try harness.context.fetchCount(FetchDescriptor<MemoryEvidenceRecord>()) == 0)
      #expect(try harness.context.fetchCount(FetchDescriptor<MemoryRevisionRecord>()) == 0)
      let job = try #require(
        harness.context.fetch(FetchDescriptor<MemoryFormationJobRecord>()).first
      )
      #expect(job.status == .generating)
      #expect(job.outputFingerprint == nil)
    }
  }

  @Test("automatic formation never exposes or mutates a paused topic")
  func pausedTopicIsExcludedFromFormation() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversationID = UUID()
    let provider = makeProvider()
    context.insert(ConversationRecord(id: conversationID, title: "Paused memory"))
    try context.save()

    _ = try await applyTurn(
      store: AutomaticMemoryStore(modelContainer: container),
      context: context,
      conversationID: conversationID,
      provider: provider,
      userContent: "Favori temam koyu tema.",
      operation: { messageID, _ in
        operation(
          canonicalKey: "preference.theme",
          title: "Tema tercihi",
          content: "Kullanıcı koyu temayı tercih ediyor.",
          evidenceMessageID: messageID
        )
      },
      at: baseDate
    )
    let topic = try #require(context.fetch(FetchDescriptor<MemoryTopicRecord>()).first)
    let topicID = topic.id
    topic.setEnabled(false, revision: 2, at: baseDate.addingTimeInterval(5))
    context.insert(
      MemoryRevisionRecord(
        revisionKey: "\(topic.id.uuidString.lowercased())/2",
        topicID: topic.id,
        sequence: 2,
        kind: .userDisabled,
        previousTitle: topic.title,
        previousContent: topic.content,
        title: topic.title,
        content: topic.content,
        sourceEvidenceID: nil,
        createdAt: baseDate.addingTimeInterval(5)
      )
    )
    try context.save()

    let userMessageID = UUID()
    let assistantMessageID = UUID()
    context.insert(
      MessageRecord(
        id: userMessageID,
        conversationID: conversationID,
        role: .user,
        content: "Favori temam hâlâ koyu tema.",
        status: .complete,
        createdAt: baseDate.addingTimeInterval(10)
      )
    )
    context.insert(
      MessageRecord(
        id: assistantMessageID,
        conversationID: conversationID,
        role: .assistant,
        content: "Anladım.",
        status: .complete,
        createdAt: baseDate.addingTimeInterval(11)
      )
    )
    try context.save()
    let store = AutomaticMemoryStore(modelContainer: container)
    let jobID = try #require(
      try await store.enqueue(
        conversationID: conversationID,
        throughUserMessageID: userMessageID,
        assistantMessageID: assistantMessageID,
        provider: provider,
        now: baseDate.addingTimeInterval(12)
      )
    )
    let preparation = try #require(
      try await store.prepare(
        jobID: jobID,
        provider: provider,
        now: baseDate.addingTimeInterval(13)
      )
    )
    #expect(!preparation.existingTopics.contains { $0.id == topicID })
    let result = generationResult(
      preparation: preparation,
      provider: provider,
      operations: []
    )
    #expect(
      try await store.apply(result, now: baseDate.addingTimeInterval(14))
        == AutomaticMemoryFormationResult()
    )

    let afterFormation = try #require(
      ModelContext(container).fetch(
        FetchDescriptor<MemoryTopicRecord>(predicate: #Predicate { $0.id == topicID })
      ).first
    )
    #expect(!afterFormation.isEnabled)
    #expect(afterFormation.status == .active)
    #expect(afterFormation.content == "Kullanıcı koyu temayı tercih ediyor.")
    #expect(afterFormation.revision == 2)
    #expect(afterFormation.evidenceCount == 1)
  }

  @Test("user edits remain authoritative until a strong targeted correction arrives")
  func userEditedTopicRequiresStrongTargetedCorrection() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversationID = UUID()
    let provider = makeProvider()
    context.insert(ConversationRecord(id: conversationID, title: "User authority"))
    try context.save()

    _ = try await applyTurn(
      store: AutomaticMemoryStore(modelContainer: container),
      context: context,
      conversationID: conversationID,
      provider: provider,
      userContent: "Favori editörüm Xcode.",
      operation: { messageID, _ in
        operation(
          canonicalKey: "preference.editor",
          title: "Favori editör",
          content: "Kullanıcının favori editörü Xcode.",
          evidenceMessageID: messageID
        )
      },
      at: baseDate
    )
    let topic = try #require(context.fetch(FetchDescriptor<MemoryTopicRecord>()).first)
    let topicID = topic.id
    let automaticTitle = topic.title
    let automaticContent = topic.content
    topic.apply(
      title: "Benim editör tercihim",
      content: "Kullanıcının favori editörü Zed.",
      confidence: 1,
      importance: topic.importance,
      stability: topic.stability,
      status: .active,
      isEnabled: true,
      evidenceCount: topic.evidenceCount,
      revision: 2,
      at: baseDate.addingTimeInterval(5)
    )
    topic.setOrigin(.manual)
    context.insert(
      MemoryRevisionRecord(
        revisionKey: "\(topicID.uuidString.lowercased())/2",
        topicID: topicID,
        sequence: 2,
        kind: .userEdited,
        previousTitle: automaticTitle,
        previousContent: automaticContent,
        title: topic.title,
        content: topic.content,
        sourceEvidenceID: nil,
        createdAt: baseDate.addingTimeInterval(5)
      )
    )
    try context.save()

    let untargetedStore = AutomaticMemoryStore(modelContainer: container)
    let untargeted = try await prepareTurnResult(
      store: untargetedStore,
      context: context,
      conversationID: conversationID,
      provider: provider,
      userContent: "Favori editörüm Nova.",
      operation: { messageID, _ in
        operation(
          canonicalKey: "preference.editor",
          title: "Favori editör",
          content: "Kullanıcının favori editörü Nova.",
          confidence: 0.99,
          evidenceMessageID: messageID
        )
      },
      at: baseDate.addingTimeInterval(10)
    )
    await #expect(throws: AutomaticMemoryStoreError.invalidOperation) {
      try await untargetedStore.apply(untargeted, now: baseDate.addingTimeInterval(14))
    }

    let weakTargetedStore = AutomaticMemoryStore(modelContainer: container)
    let weakTargeted = try await prepareTurnResult(
      store: weakTargetedStore,
      context: context,
      conversationID: conversationID,
      provider: provider,
      userContent: "Favori editörüm Nova olabilir.",
      operation: { messageID, _ in
        operation(
          targetID: topicID,
          canonicalKey: "preference.editor",
          title: "Favori editör",
          content: "Kullanıcının favori editörü Nova.",
          confidence: 0.89,
          evidenceMessageID: messageID
        )
      },
      at: baseDate.addingTimeInterval(20)
    )
    await #expect(throws: AutomaticMemoryStoreError.invalidOperation) {
      try await weakTargetedStore.apply(weakTargeted, now: baseDate.addingTimeInterval(24))
    }

    let reinforcementStore = AutomaticMemoryStore(modelContainer: container)
    let reinforcement = try await prepareTurnResult(
      store: reinforcementStore,
      context: context,
      conversationID: conversationID,
      provider: provider,
      userContent: "Evet, favori editörüm Zed.",
      operation: { messageID, _ in
        operation(
          canonicalKey: "preference.editor",
          title: "Model tarafından yeniden yazılmış başlık",
          content: "Kullanıcının favori editörü Zed.",
          confidence: 0.95,
          evidenceMessageID: messageID
        )
      },
      at: baseDate.addingTimeInterval(30)
    )
    #expect(
      try await reinforcementStore.apply(
        reinforcement,
        now: baseDate.addingTimeInterval(34)
      ) == AutomaticMemoryFormationResult(reinforcedCount: 1)
    )
    let afterReinforcement = try #require(
      ModelContext(container).fetch(
        FetchDescriptor<MemoryTopicRecord>(predicate: #Predicate { $0.id == topicID })
      ).first
    )
    #expect(afterReinforcement.title == "Benim editör tercihim")
    #expect(afterReinforcement.content == "Kullanıcının favori editörü Zed.")
    #expect(afterReinforcement.confidence == 1)
    #expect(afterReinforcement.revision == 3)

    let correctionStore = AutomaticMemoryStore(modelContainer: container)
    let correction = try await prepareTurnResult(
      store: correctionStore,
      context: context,
      conversationID: conversationID,
      provider: provider,
      userContent: "Artık favori editörüm kesinlikle Nova.",
      operation: { messageID, _ in
        operation(
          targetID: topicID,
          canonicalKey: "preference.editor",
          title: "Favori editör",
          content: "Kullanıcının favori editörü Nova.",
          confidence: 0.95,
          evidenceMessageID: messageID
        )
      },
      at: baseDate.addingTimeInterval(40)
    )
    #expect(
      try await correctionStore.apply(
        correction,
        now: baseDate.addingTimeInterval(44)
      ) == AutomaticMemoryFormationResult(updatedCount: 1)
    )
    let afterCorrection = try #require(
      ModelContext(container).fetch(
        FetchDescriptor<MemoryTopicRecord>(predicate: #Predicate { $0.id == topicID })
      ).first
    )
    #expect(afterCorrection.title == "Favori editör")
    #expect(afterCorrection.content == "Kullanıcının favori editörü Nova.")
    #expect(afterCorrection.confidence == 0.95)
    #expect(afterCorrection.revision == 4)

    let revisions = try ModelContext(container).fetch(
      FetchDescriptor<MemoryRevisionRecord>(
        predicate: #Predicate { $0.topicID == topicID },
        sortBy: [SortDescriptor(\MemoryRevisionRecord.sequence)]
      )
    )
    #expect(revisions.map(\.sequence) == [1, 2, 3, 4])
    #expect(
      revisions.map(\.kindRawValue)
        == [
          MemoryRevisionKind.created.rawValue,
          MemoryRevisionKind.userEdited.rawValue,
          MemoryRevisionKind.reinforced.rawValue,
          MemoryRevisionKind.updated.rawValue,
        ]
    )
  }

  @Test("conversation deletion reconciles scoped and global automatic memory")
  func conversationDeletionPreservesValidGlobalHeadsAndForgetsUnsupportedOnes() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let deletedConversationID = UUID()
    let retainedConversationID = UUID()
    let provider = makeProvider()
    context.insert(ConversationRecord(id: deletedConversationID, title: "Delete me"))
    context.insert(ConversationRecord(id: retainedConversationID, title: "Keep me"))
    try context.save()

    _ = try await applyTurn(
      store: AutomaticMemoryStore(modelContainer: container),
      context: context,
      conversationID: deletedConversationID,
      provider: provider,
      userContent: "Sadece bu sohbette kod adım Orion.",
      operation: { messageID, _ in
        operation(
          canonicalKey: "identity.local_code_name",
          title: "Yerel kod adı",
          content: "Bu sohbet için kullanıcının kod adı Orion.",
          scope: .conversation,
          evidenceMessageID: messageID
        )
      },
      at: baseDate
    )
    let conversationTopicID = try #require(
      context.fetch(FetchDescriptor<MemoryTopicRecord>()).first {
        $0.scope == .conversation
      }?.id
    )

    _ = try await applyTurn(
      store: AutomaticMemoryStore(modelContainer: container),
      context: context,
      conversationID: deletedConversationID,
      provider: provider,
      userContent: "Kalıcı olarak Türkçe yanıtları tercih ediyorum.",
      operation: { messageID, _ in
        operation(
          canonicalKey: "preference.response_language",
          title: "Yanıt dili",
          content: "Kullanıcı Türkçe yanıtları tercih ediyor.",
          evidenceMessageID: messageID
        )
      },
      at: baseDate.addingTimeInterval(10)
    )
    let supportedGlobalTopicID = try #require(
      context.fetch(FetchDescriptor<MemoryTopicRecord>()).first {
        $0.canonicalKey == "global:preference:response_language"
      }?.id
    )
    _ = try await applyTurn(
      store: AutomaticMemoryStore(modelContainer: container),
      context: context,
      conversationID: retainedConversationID,
      provider: provider,
      userContent: "Evet, Türkçe yanıt tercihim devam ediyor.",
      operation: { messageID, _ in
        operation(
          targetID: supportedGlobalTopicID,
          canonicalKey: "preference.response_language",
          title: "Yanıt dili",
          content: "Kullanıcı Türkçe yanıtları tercih ediyor.",
          evidenceMessageID: messageID
        )
      },
      at: baseDate.addingTimeInterval(20)
    )

    _ = try await applyTurn(
      store: AutomaticMemoryStore(modelContainer: container),
      context: context,
      conversationID: deletedConversationID,
      provider: provider,
      userContent: "Kalıcı olarak satır numarası göster.",
      operation: { messageID, _ in
        operation(
          canonicalKey: "preference.show_line_numbers",
          title: "Satır numaraları",
          content: "Kullanıcı satır numaralarının gösterilmesini tercih ediyor.",
          evidenceMessageID: messageID
        )
      },
      at: baseDate.addingTimeInterval(30)
    )
    let unsupportedGlobalTopicID = try #require(
      context.fetch(FetchDescriptor<MemoryTopicRecord>()).first {
        $0.canonicalKey == "global:preference:show_line_numbers"
      }?.id
    )

    _ = try await applyTurn(
      store: AutomaticMemoryStore(modelContainer: container),
      context: context,
      conversationID: deletedConversationID,
      provider: provider,
      userContent: "Kalıcı çalışma alanım Mosaic.",
      operation: { messageID, _ in
        operation(
          canonicalKey: "workspace",
          title: "Çalışma alanı",
          content: "Kullanıcının kalıcı çalışma alanı Mosaic.",
          evidenceMessageID: messageID
        )
      },
      at: baseDate.addingTimeInterval(34)
    )
    let manuallyCorrected = try #require(
      context.fetch(FetchDescriptor<MemoryTopicRecord>()).first {
        $0.canonicalKey == "global:preference:workspace"
      }
    )
    let manuallyCorrectedTopicID = manuallyCorrected.id
    let previousTitle = manuallyCorrected.title
    let previousContent = manuallyCorrected.content
    let manualCorrectionDate = baseDate.addingTimeInterval(39)
    manuallyCorrected.apply(
      title: "Ana çalışma alanım",
      content: "Kullanıcının ana çalışma alanı Mosaic uygulamasıdır.",
      confidence: 1,
      importance: manuallyCorrected.importance,
      stability: manuallyCorrected.stability,
      status: .active,
      isEnabled: true,
      evidenceCount: manuallyCorrected.evidenceCount,
      revision: 2,
      at: manualCorrectionDate
    )
    manuallyCorrected.setOrigin(.manual)
    context.insert(
      MemoryRevisionRecord(
        revisionKey: "\(manuallyCorrectedTopicID.uuidString.lowercased())/2",
        topicID: manuallyCorrectedTopicID,
        sequence: 2,
        kind: .userEdited,
        previousTitle: previousTitle,
        previousContent: previousContent,
        title: manuallyCorrected.title,
        content: manuallyCorrected.content,
        sourceEvidenceID: nil,
        createdAt: manualCorrectionDate
      )
    )
    try context.save()

    let outcome = try await MosaicConversationDeletionPipeline.delete(
      conversationID: deletedConversationID,
      sourceRepository: MosaicConversationSourceDeletionRepository(modelContainer: container),
      vectorRepository: MosaicConversationVectorDeletionRepository(modelContainer: container)
    )
    #expect(outcome.didDeleteConversation)

    let verification = ModelContext(container)
    #expect(
      try verification.fetch(
        FetchDescriptor<MemoryTopicRecord>(
          predicate: #Predicate { $0.id == conversationTopicID }
        )
      ).isEmpty
    )

    let retainedManual = try #require(
      verification.fetch(
        FetchDescriptor<MemoryTopicRecord>(
          predicate: #Predicate { $0.id == manuallyCorrectedTopicID }
        )
      ).first
    )
    #expect(retainedManual.status == .active)
    #expect(retainedManual.isEnabled)
    #expect(retainedManual.origin == .manual)
    #expect(retainedManual.evidenceCount == 0)
    #expect(retainedManual.revision == 2)
    #expect(retainedManual.lastConfirmedAt == manualCorrectionDate)
    #expect(retainedManual.content == "Kullanıcının ana çalışma alanı Mosaic uygulamasıdır.")
    #expect(
      try verification.fetch(
        FetchDescriptor<MemoryEvidenceRecord>(
          predicate: #Predicate { $0.topicID == conversationTopicID }
        )
      ).isEmpty
    )
    #expect(
      try verification.fetch(
        FetchDescriptor<MemoryRevisionRecord>(
          predicate: #Predicate { $0.topicID == conversationTopicID }
        )
      ).isEmpty
    )

    let supported = try #require(
      verification.fetch(
        FetchDescriptor<MemoryTopicRecord>(
          predicate: #Predicate { $0.id == supportedGlobalTopicID }
        )
      ).first
    )
    #expect(supported.status == .active)
    #expect(supported.isEnabled)
    #expect(supported.evidenceCount == 1)
    #expect(supported.revision == 2)
    let supportedEvidence = try verification.fetch(
      FetchDescriptor<MemoryEvidenceRecord>(
        predicate: #Predicate { $0.topicID == supportedGlobalTopicID }
      )
    )
    #expect(supportedEvidence.map(\.conversationID) == [retainedConversationID])
    let supportedRevisions = try verification.fetch(
      FetchDescriptor<MemoryRevisionRecord>(
        predicate: #Predicate { $0.topicID == supportedGlobalTopicID },
        sortBy: [SortDescriptor(\MemoryRevisionRecord.sequence)]
      )
    )
    #expect(supportedRevisions.map(\.sequence) == [1, 2])
    #expect(supportedRevisions[0].sourceEvidenceID == nil)
    #expect(supportedRevisions[1].sourceEvidenceID == supportedEvidence.first?.id)

    let unsupported = try #require(
      verification.fetch(
        FetchDescriptor<MemoryTopicRecord>(
          predicate: #Predicate { $0.id == unsupportedGlobalTopicID }
        )
      ).first
    )
    #expect(unsupported.status == .forgotten)
    #expect(!unsupported.isEnabled)
    #expect(unsupported.evidenceCount == 0)
    #expect(unsupported.revision == 2)
    let unsupportedRevisions = try verification.fetch(
      FetchDescriptor<MemoryRevisionRecord>(
        predicate: #Predicate { $0.topicID == unsupportedGlobalTopicID },
        sortBy: [SortDescriptor(\MemoryRevisionRecord.sequence)]
      )
    )
    #expect(unsupportedRevisions.map(\.sequence) == [1, 2])
    #expect(
      unsupportedRevisions.map(\.kindRawValue)
        == [MemoryRevisionKind.created.rawValue, MemoryRevisionKind.forgotten.rawValue]
    )
    #expect(unsupportedRevisions.allSatisfy { $0.sourceEvidenceID == nil })
    #expect(
      try verification.fetch(
        FetchDescriptor<MemoryEvidenceRecord>(
          predicate: #Predicate { $0.topicID == unsupportedGlobalTopicID }
        )
      ).isEmpty
    )

    let remainingJobs = try verification.fetch(FetchDescriptor<MemoryFormationJobRecord>())
    #expect(remainingJobs.count == 1)
    #expect(remainingJobs.allSatisfy { $0.conversationID == retainedConversationID })
    let remainingAudits = try verification.fetch(FetchDescriptor<MemoryFormationAuditRecord>())
    #expect(remainingAudits.count == 1)
    #expect(remainingAudits.first?.jobID == remainingJobs.first?.id)

    let remainingEvidenceIDs = Set(
      try verification.fetch(FetchDescriptor<MemoryEvidenceRecord>()).map(\.id)
    )
    let remainingRevisionEvidenceIDs = try verification.fetch(
      FetchDescriptor<MemoryRevisionRecord>()
    ).compactMap(\.sourceEvidenceID)
    #expect(remainingRevisionEvidenceIDs.allSatisfy(remainingEvidenceIDs.contains))

    let portableArchive = try MosaicPortableBackup.export(from: verification)
    _ = try MosaicPortableBackup.decode(portableArchive)
  }

  @Test("a memory edit during provider work wins the topic compare-and-swap")
  func concurrentUserEditMakesGeneratedTopicMutationStale() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversationID = UUID()
    let provider = makeProvider()
    context.insert(ConversationRecord(id: conversationID, title: "Concurrent edit"))
    try context.save()

    _ = try await applyTurn(
      store: AutomaticMemoryStore(modelContainer: container),
      context: context,
      conversationID: conversationID,
      provider: provider,
      userContent: "Favori editörüm Xcode.",
      operation: { messageID, _ in
        operation(
          canonicalKey: "editor",
          title: "Favori editör",
          content: "Kullanıcının favori editörü Xcode.",
          evidenceMessageID: messageID
        )
      },
      at: baseDate
    )
    let topic = try #require(context.fetch(FetchDescriptor<MemoryTopicRecord>()).first)
    let topicID = topic.id
    let generated = try await prepareTurnResult(
      store: AutomaticMemoryStore(modelContainer: container),
      context: context,
      conversationID: conversationID,
      provider: provider,
      userContent: "Favori editörüm artık Nova.",
      operation: { messageID, _ in
        operation(
          targetID: topicID,
          canonicalKey: "global:preference:editor",
          title: "Favori editör",
          content: "Kullanıcının favori editörü Nova.",
          confidence: 0.99,
          evidenceMessageID: messageID
        )
      },
      at: baseDate.addingTimeInterval(10)
    )

    let previousTitle = topic.title
    let previousContent = topic.content
    topic.apply(
      title: "Benim editör tercihim",
      content: "Kullanıcının favori editörü Zed.",
      confidence: 1,
      importance: topic.importance,
      stability: topic.stability,
      status: .active,
      isEnabled: true,
      evidenceCount: topic.evidenceCount,
      revision: 2,
      at: baseDate.addingTimeInterval(12)
    )
    topic.setOrigin(.manual)
    context.insert(
      MemoryRevisionRecord(
        revisionKey: "\(topicID.uuidString.lowercased())/2",
        topicID: topicID,
        sequence: 2,
        kind: .userEdited,
        previousTitle: previousTitle,
        previousContent: previousContent,
        title: topic.title,
        content: topic.content,
        sourceEvidenceID: nil,
        createdAt: baseDate.addingTimeInterval(12)
      )
    )
    try context.save()

    await #expect(throws: AutomaticMemoryStoreError.staleSource) {
      try await AutomaticMemoryStore(modelContainer: container).apply(
        generated,
        now: baseDate.addingTimeInterval(14)
      )
    }
    let current = try #require(
      ModelContext(container).fetch(
        FetchDescriptor<MemoryTopicRecord>(predicate: #Predicate { $0.id == topicID })
      ).first
    )
    #expect(current.content == "Kullanıcının favori editörü Zed.")
    #expect(current.origin == .manual)
    #expect(current.revision == 2)
    #expect(current.evidenceCount == 1)
  }

  @Test("prepare exposes only global, same-project, and same-conversation topics")
  func prepareIsolatesProjectTopicVisibility() async throws {
    let harness = try makeHarness(userContent: "Bu projedeki tercihlerimi hatırla.")
    let sameProject = ProjectRecord(name: "Mosaic")
    let otherProject = ProjectRecord(name: "Unrelated")
    let globalTopic = MemoryTopicRecord(
      canonicalKey: "global:preference:response_language",
      title: "Response language",
      content: "Reply in Turkish.",
      kind: .preference,
      scope: .global,
      conversationID: nil,
      confidence: 0.95,
      importance: 0.9,
      stability: .stable,
      createdAt: baseDate,
      updatedAt: baseDate
    )
    let sameProjectTopic = MemoryTopicRecord(
      canonicalKey:
        "project:\(sameProject.id.uuidString.lowercased()):preference:vocabulary",
      title: "Project vocabulary",
      content: "Use Mosaic terminology.",
      kind: .preference,
      scope: .project,
      conversationID: nil,
      confidence: 0.94,
      importance: 0.8,
      stability: .stable,
      createdAt: baseDate,
      updatedAt: baseDate.addingTimeInterval(2)
    )
    let otherProjectTopic = MemoryTopicRecord(
      canonicalKey:
        "project:\(otherProject.id.uuidString.lowercased()):preference:vocabulary",
      title: "Other vocabulary",
      content: "Use unrelated terminology.",
      kind: .preference,
      scope: .project,
      conversationID: nil,
      confidence: 0.93,
      importance: 0.8,
      stability: .stable,
      createdAt: baseDate,
      updatedAt: baseDate.addingTimeInterval(3)
    )
    let conversationTopic = MemoryTopicRecord(
      canonicalKey:
        "conversation:\(harness.conversationID.uuidString.lowercased()):preference:detail",
      title: "Conversation detail",
      content: "Only use this detail in this conversation.",
      kind: .preference,
      scope: .conversation,
      conversationID: harness.conversationID,
      confidence: 0.92,
      importance: 0.7,
      stability: .evolving,
      createdAt: baseDate,
      updatedAt: baseDate.addingTimeInterval(1)
    )
    let pausedGlobalTopic = MemoryTopicRecord(
      canonicalKey: "global:preference:paused_detail",
      title: "Paused detail",
      content: "Never send this paused value.",
      kind: .preference,
      scope: .global,
      conversationID: nil,
      confidence: 0.9,
      importance: 0.5,
      stability: .stable,
      isEnabled: false,
      createdAt: baseDate,
      updatedAt: baseDate.addingTimeInterval(4)
    )
    let forgottenConversationTopic = MemoryTopicRecord(
      canonicalKey:
        "conversation:\(harness.conversationID.uuidString.lowercased()):preference:forgotten_detail",
      title: "Forgotten detail",
      content: "Never send this forgotten value.",
      kind: .preference,
      scope: .conversation,
      conversationID: harness.conversationID,
      status: .forgotten,
      confidence: 0.9,
      importance: 0.5,
      stability: .stable,
      isEnabled: false,
      createdAt: baseDate,
      updatedAt: baseDate.addingTimeInterval(5)
    )
    let disabledProjectTopic = MemoryTopicRecord(
      canonicalKey:
        "project:\(sameProject.id.uuidString.lowercased()):preference:disabled_detail",
      title: "Disabled project detail",
      content: "Never send this disabled project value.",
      kind: .preference,
      scope: .project,
      conversationID: nil,
      confidence: 0.9,
      importance: 0.5,
      stability: .stable,
      isEnabled: false,
      createdAt: baseDate,
      updatedAt: baseDate.addingTimeInterval(6)
    )
    harness.context.insert(sameProject)
    harness.context.insert(otherProject)
    harness.context.insert(globalTopic)
    harness.context.insert(sameProjectTopic)
    harness.context.insert(otherProjectTopic)
    harness.context.insert(conversationTopic)
    harness.context.insert(pausedGlobalTopic)
    harness.context.insert(forgottenConversationTopic)
    harness.context.insert(disabledProjectTopic)
    try harness.context.save()
    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: harness.conversationID,
      to: sameProject.id,
      in: harness.context,
      now: baseDate
    )
    _ = try ProjectBindingStore.assign(
      resourceKind: .memoryTopic,
      resourceID: sameProjectTopic.id,
      to: sameProject.id,
      in: harness.context,
      now: baseDate
    )
    _ = try ProjectBindingStore.assign(
      resourceKind: .memoryTopic,
      resourceID: otherProjectTopic.id,
      to: otherProject.id,
      in: harness.context,
      now: baseDate
    )
    _ = try ProjectBindingStore.assign(
      resourceKind: .memoryTopic,
      resourceID: disabledProjectTopic.id,
      to: sameProject.id,
      in: harness.context,
      now: baseDate
    )
    try harness.context.save()

    let store = AutomaticMemoryStore(modelContainer: harness.container)
    let jobID = try #require(
      try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(4)
      )
    )
    let preparation = try #require(
      try await store.prepare(
        jobID: jobID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(5)
      )
    )

    #expect(preparation.projectID == sameProject.id)
    #expect(preparation.projectName == sameProject.name)
    let visibleIDs = Set(preparation.existingTopics.map(\.id))
    #expect(visibleIDs == Set([globalTopic.id, sameProjectTopic.id, conversationTopic.id]))
    let visibleProjectTopic = try #require(
      preparation.existingTopics.first { $0.id == sameProjectTopic.id }
    )
    #expect(visibleProjectTopic.scope == .project)
    #expect(visibleProjectTopic.projectID == sameProject.id)
    #expect(!visibleIDs.contains(otherProjectTopic.id))
    #expect(!visibleIDs.contains(pausedGlobalTopic.id))
    #expect(!visibleIDs.contains(forgottenConversationTopic.id))
    #expect(!visibleIDs.contains(disabledProjectTopic.id))
  }

  @Test("another project's large topic library cannot starve the active project")
  func projectTopicSelectionPartitionsAudienceBeforeItsScanLimit() async throws {
    let harness = try makeHarness(userContent: "Bu projenin eski kararını hatırla.")
    let activeProject = ProjectRecord(name: "Active")
    let noisyProject = ProjectRecord(name: "Noisy")
    harness.context.insert(activeProject)
    harness.context.insert(noisyProject)
    try harness.context.save()
    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: harness.conversationID,
      to: activeProject.id,
      in: harness.context,
      now: baseDate
    )

    let target = MemoryTopicRecord(
      canonicalKey:
        "project:\(activeProject.id.uuidString.lowercased()):fact:durable_decision",
      title: "Durable decision",
      content: "Keep the original project decision visible.",
      kind: .fact,
      scope: .project,
      conversationID: nil,
      origin: .manual,
      confidence: 1,
      importance: 1,
      stability: .stable,
      lastConfirmedAt: baseDate,
      createdAt: baseDate,
      updatedAt: baseDate
    )
    harness.context.insert(target)
    harness.context.insert(
      ProjectResourceBindingRecord(
        resourceKind: .memoryTopic,
        resourceID: target.id,
        projectID: activeProject.id,
        createdAt: baseDate,
        updatedAt: baseDate
      )
    )

    for index in 0..<5_000 {
      let date = baseDate.addingTimeInterval(TimeInterval(index + 1))
      let topic = MemoryTopicRecord(
        canonicalKey:
          "project:\(noisyProject.id.uuidString.lowercased()):fact:noise_\(index)",
        title: "Noise \(index)",
        content: "Unrelated project topic \(index).",
        kind: .fact,
        scope: .project,
        conversationID: nil,
        origin: .manual,
        confidence: 1,
        importance: 0,
        stability: .stable,
        lastConfirmedAt: date,
        createdAt: date,
        updatedAt: date
      )
      harness.context.insert(topic)
      harness.context.insert(
        ProjectResourceBindingRecord(
          resourceKind: .memoryTopic,
          resourceID: topic.id,
          projectID: noisyProject.id,
          createdAt: date,
          updatedAt: date
        )
      )
    }
    try harness.context.save()

    let store = AutomaticMemoryStore(modelContainer: harness.container)
    let jobID = try #require(
      try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(6_000)
      )
    )
    let preparation = try #require(
      try await store.prepare(
        jobID: jobID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(6_001)
      )
    )

    #expect(preparation.existingTopics.map(\.id) == [target.id])
  }

  @Test("project upserts get a canonical project prefix and an atomic sidecar binding")
  func projectUpsertCreatesTopicAndBindingTogether() async throws {
    let harness = try makeHarness(userContent: "Bu projede kısa yanıtları tercih ediyorum.")
    let project = ProjectRecord(name: "Mosaic")
    harness.context.insert(project)
    try harness.context.save()
    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: harness.conversationID,
      to: project.id,
      in: harness.context,
      now: baseDate
    )
    try harness.context.save()

    let store = AutomaticMemoryStore(modelContainer: harness.container)
    let jobID = try #require(
      try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(1)
      )
    )
    let preparation = try #require(
      try await store.prepare(
        jobID: jobID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(2)
      )
    )
    let generated = generationResult(
      preparation: preparation,
      provider: harness.provider,
      operation: operation(
        canonicalKey: "response_length",
        title: "Project response length",
        content: "Use concise responses in this project.",
        scope: .project,
        evidenceMessageID: harness.userMessageID
      )
    )

    let applied = try await store.apply(generated, now: baseDate.addingTimeInterval(3))
    #expect(applied == AutomaticMemoryFormationResult(createdCount: 1))
    let topic = try #require(
      harness.context.fetch(FetchDescriptor<MemoryTopicRecord>()).first
    )
    #expect(
      topic.canonicalKey
        == "project:\(project.id.uuidString.lowercased()):preference:response_length"
    )
    #expect(topic.scope == .project)
    #expect(topic.conversationID == nil)
    #expect(
      try ProjectBindingStore.projectID(
        resourceKind: .memoryTopic,
        resourceID: topic.id,
        in: harness.context
      ) == project.id
    )
    let topicBindings = try harness.context.fetch(
      FetchDescriptor<ProjectResourceBindingRecord>()
    ).filter { $0.resourceKind == .memoryTopic && $0.resourceID == topic.id }
    #expect(topicBindings.count == 1)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryEvidenceRecord>()) == 1)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryRevisionRecord>()) == 1)
  }

  @Test("a forged target bound to another project is rejected without mutations")
  func otherProjectTargetIsRejectedAtomically() async throws {
    let harness = try makeHarness(userContent: "Bu projedeki editör tercihim Nova.")
    let activeProject = ProjectRecord(name: "Active")
    let otherProject = ProjectRecord(name: "Other")
    harness.context.insert(activeProject)
    harness.context.insert(otherProject)
    try harness.context.save()
    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: harness.conversationID,
      to: activeProject.id,
      in: harness.context,
      now: baseDate
    )
    let forgedTarget = MemoryTopicRecord(
      canonicalKey:
        "project:\(activeProject.id.uuidString.lowercased()):preference:editor",
      title: "Other project editor",
      content: "Use Xcode in the other project.",
      kind: .preference,
      scope: .project,
      conversationID: nil,
      confidence: 0.9,
      importance: 0.8,
      stability: .stable,
      createdAt: baseDate,
      updatedAt: baseDate
    )
    harness.context.insert(forgedTarget)
    try harness.context.save()
    _ = try ProjectBindingStore.assign(
      resourceKind: .memoryTopic,
      resourceID: forgedTarget.id,
      to: otherProject.id,
      in: harness.context,
      now: baseDate
    )
    try harness.context.save()

    let store = AutomaticMemoryStore(modelContainer: harness.container)
    let jobID = try #require(
      try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(1)
      )
    )
    let preparation = try #require(
      try await store.prepare(
        jobID: jobID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(2)
      )
    )
    #expect(!preparation.existingTopics.contains { $0.id == forgedTarget.id })
    let generated = generationResult(
      preparation: preparation,
      provider: harness.provider,
      operation: operation(
        targetID: forgedTarget.id,
        canonicalKey: forgedTarget.canonicalKey,
        title: "Active project editor",
        content: "Use Nova in the active project.",
        scope: .project,
        evidenceMessageID: harness.userMessageID
      )
    )
    let originalRevision = forgedTarget.revision

    await #expect(throws: AutomaticMemoryStoreError.invalidOperation) {
      try await store.apply(generated, now: baseDate.addingTimeInterval(3))
    }
    #expect(forgedTarget.content == "Use Xcode in the other project.")
    #expect(forgedTarget.revision == originalRevision)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryTopicRecord>()) == 1)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryEvidenceRecord>()) == 0)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryRevisionRecord>()) == 0)
  }

  @Test("moving a conversation after prepare makes the project result stale")
  func projectChangeBetweenPrepareAndApplyIsStale() async throws {
    let harness = try makeHarness(userContent: "Bu projede kısa yanıtları tercih ediyorum.")
    let originalProject = ProjectRecord(name: "Original")
    let replacementProject = ProjectRecord(name: "Replacement")
    harness.context.insert(originalProject)
    harness.context.insert(replacementProject)
    try harness.context.save()
    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: harness.conversationID,
      to: originalProject.id,
      in: harness.context,
      now: baseDate
    )
    try harness.context.save()

    let store = AutomaticMemoryStore(modelContainer: harness.container)
    let jobID = try #require(
      try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(1)
      )
    )
    let preparation = try #require(
      try await store.prepare(
        jobID: jobID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(2)
      )
    )
    #expect(preparation.projectID == originalProject.id)
    let generated = generationResult(
      preparation: preparation,
      provider: harness.provider,
      operation: operation(
        canonicalKey: "response_length",
        title: "Project response length",
        content: "Use concise responses in this project.",
        scope: .project,
        evidenceMessageID: harness.userMessageID
      )
    )
    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: harness.conversationID,
      to: replacementProject.id,
      in: harness.context,
      now: baseDate.addingTimeInterval(3)
    )
    try harness.context.save()

    await #expect(throws: AutomaticMemoryStoreError.staleSource) {
      try await store.apply(generated, now: baseDate.addingTimeInterval(4))
    }
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryTopicRecord>()) == 0)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryEvidenceRecord>()) == 0)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryRevisionRecord>()) == 0)
  }

  @Test("project conversations can explicitly correct an existing global memory")
  func projectSourceCanCorrectTargetedManualGlobalMemory() async throws {
    let harness = try makeHarness(userContent: "Bu projede kısa yanıt ver.")
    let project = ProjectRecord(name: "Mosaic")
    let manualGlobal = MemoryTopicRecord(
      canonicalKey: "global:preference:response_language",
      title: "Response language",
      content: "Reply in Turkish.",
      kind: .preference,
      scope: .global,
      conversationID: nil,
      origin: .manual,
      confidence: 1,
      importance: 0.9,
      stability: .stable,
      createdAt: baseDate,
      updatedAt: baseDate
    )
    harness.context.insert(project)
    harness.context.insert(manualGlobal)
    try harness.context.save()
    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: harness.conversationID,
      to: project.id,
      in: harness.context,
      now: baseDate
    )
    try harness.context.save()

    let store = AutomaticMemoryStore(modelContainer: harness.container)
    let jobID = try #require(
      try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(1)
      )
    )
    let preparation = try #require(
      try await store.prepare(
        jobID: jobID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(2)
      )
    )
    #expect(preparation.existingTopics.contains { $0.id == manualGlobal.id })
    let generated = generationResult(
      preparation: preparation,
      provider: harness.provider,
      operation: operation(
        targetID: manualGlobal.id,
        canonicalKey: manualGlobal.canonicalKey,
        title: "Response language",
        content: "Reply in English.",
        confidence: 0.99,
        scope: .global,
        evidenceMessageID: harness.userMessageID
      )
    )

    let result = try await store.apply(generated, now: baseDate.addingTimeInterval(3))
    #expect(result == AutomaticMemoryFormationResult(updatedCount: 1))
    let manualGlobalID = manualGlobal.id
    let correctedGlobal = try #require(
      ModelContext(harness.container).fetch(
        FetchDescriptor<MemoryTopicRecord>(
          predicate: #Predicate { $0.id == manualGlobalID }
        )
      ).first
    )
    #expect(correctedGlobal.content == "Reply in English.")
    #expect(correctedGlobal.origin == .automatic)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryTopicRecord>()) == 1)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryEvidenceRecord>()) == 1)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryRevisionRecord>()) == 1)
  }

  @Test("project conversations still cannot create an untargeted global memory")
  func projectSourceRejectsANewGlobalMemory() async throws {
    let harness = try makeHarness(userContent: "Bu projede kısa yanıt ver.")
    let project = ProjectRecord(name: "Mosaic")
    harness.context.insert(project)
    try harness.context.save()
    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: harness.conversationID,
      to: project.id,
      in: harness.context,
      now: baseDate
    )
    try harness.context.save()

    let store = AutomaticMemoryStore(modelContainer: harness.container)
    let jobID = try #require(
      try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(1)
      )
    )
    let preparation = try #require(
      try await store.prepare(
        jobID: jobID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(2)
      )
    )
    let generated = generationResult(
      preparation: preparation,
      provider: harness.provider,
      operation: operation(
        canonicalKey: "new_global_preference",
        title: "New global preference",
        content: "Always use concise responses.",
        scope: .global,
        evidenceMessageID: harness.userMessageID
      )
    )

    await #expect(throws: AutomaticMemoryStoreError.invalidOperation) {
      try await store.apply(generated, now: baseDate.addingTimeInterval(3))
    }
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryTopicRecord>()) == 0)
  }

  @Test("archiving the captured project makes an in-flight result stale")
  func archivedProjectRejectsInFlightAutomaticMemory() async throws {
    let harness = try makeHarness(userContent: "Bu projede kısa yanıt ver.")
    let project = ProjectRecord(name: "Mosaic")
    harness.context.insert(project)
    try harness.context.save()
    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: harness.conversationID,
      to: project.id,
      in: harness.context,
      now: baseDate
    )
    try harness.context.save()

    let store = AutomaticMemoryStore(modelContainer: harness.container)
    let jobID = try #require(
      try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(1)
      )
    )
    let preparation = try #require(
      try await store.prepare(
        jobID: jobID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(2)
      )
    )
    let generated = generationResult(
      preparation: preparation,
      provider: harness.provider,
      operation: operation(
        canonicalKey: "response_length",
        title: "Project response length",
        content: "Use concise responses in this project.",
        scope: .project,
        evidenceMessageID: harness.userMessageID
      )
    )
    project.isArchived = true
    project.updatedAt = baseDate.addingTimeInterval(3)
    try harness.context.save()

    await #expect(throws: AutomaticMemoryStoreError.staleSource) {
      try await store.apply(generated, now: baseDate.addingTimeInterval(4))
    }
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryTopicRecord>()) == 0)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryEvidenceRecord>()) == 0)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryRevisionRecord>()) == 0)
    let topicBindingKind = ProjectResourceKind.memoryTopic.rawValue
    #expect(
      try harness.context.fetchCount(
        FetchDescriptor<ProjectResourceBindingRecord>(
          predicate: #Predicate { $0.resourceKindRawValue == topicBindingKind }
        )
      ) == 0
    )
  }

  @Test("failed and cancelled assistant turns cannot become automatic memory sources")
  func incompleteAssistantBoundariesAreRejected() async throws {
    for status in [MessageStatus.failed, .cancelled] {
      let harness = try makeHarness(
        userContent: "Beni hatırla.",
        assistantStatus: status
      )
      let store = AutomaticMemoryStore(modelContainer: harness.container)
      await #expect(throws: AutomaticMemoryStoreError.sourceUnavailable) {
        try await store.enqueue(
          conversationID: harness.conversationID,
          throughUserMessageID: harness.userMessageID,
          assistantMessageID: harness.assistantMessageID,
          provider: harness.provider,
          now: baseDate
        )
      }
      #expect(
        try harness.context.fetchCount(FetchDescriptor<MemoryFormationJobRecord>()) == 0
      )
    }
  }

  @Test("archived project conversations do not accumulate formation jobs")
  func archivedProjectConversationDoesNotEnqueueAJob() async throws {
    let harness = try makeHarness(userContent: "Remember this project preference.")
    let project = ProjectRecord(name: "Archived")
    harness.context.insert(project)
    try harness.context.save()
    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: harness.conversationID,
      to: project.id,
      in: harness.context,
      now: baseDate
    )
    try harness.context.save()
    project.isArchived = true
    project.updatedAt = baseDate.addingTimeInterval(1)
    try harness.context.save()

    let jobID = try await AutomaticMemoryStore(modelContainer: harness.container).enqueue(
      conversationID: harness.conversationID,
      throughUserMessageID: harness.userMessageID,
      assistantMessageID: harness.assistantMessageID,
      provider: harness.provider,
      now: baseDate.addingTimeInterval(2)
    )

    #expect(jobID == nil)
    #expect(try harness.context.fetchCount(FetchDescriptor<MemoryFormationJobRecord>()) == 0)
  }

  @Test("provider deletion abandons dormant jobs without losing request telemetry")
  @MainActor
  func providerDeletionAbandonsDormantJobsInTheCallersTransaction() async throws {
    let harness = try makeHarness(userContent: "Remember this preference.")
    let store = AutomaticMemoryStore(modelContainer: harness.container)
    let jobID = try #require(
      try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID,
        assistantMessageID: harness.assistantMessageID,
        provider: harness.provider,
        now: baseDate
      )
    )
    let preparation = try #require(
      try await store.prepare(
        jobID: jobID,
        provider: harness.provider,
        now: baseDate.addingTimeInterval(1)
      )
    )
    try await store.markRequestStarted(
      jobID: jobID,
      provider: harness.provider,
      expectedProjectID: preparation.projectID,
      now: baseDate.addingTimeInterval(2)
    )
    try await store.recordAttemptTelemetry(
      jobID: jobID,
      provider: harness.provider,
      telemetry: AutomaticMemoryExtractionAttemptTelemetry(
        requestStarted: true,
        providerMessageID: "formation-1",
        inputTokenCount: 12,
        outputTokenCount: 3
      ),
      now: baseDate.addingTimeInterval(3)
    )
    try await store.markFailed(
      jobID: jobID,
      error: AutomaticMemoryExtractionError.invalidOutput,
      now: baseDate.addingTimeInterval(4)
    )

    let abandoned = try AutomaticMemoryStore.abandonRetryableJobsForProviderDeletion(
      providerConfigurationID: harness.provider.id,
      in: harness.context,
      now: baseDate.addingTimeInterval(5)
    )
    #expect(abandoned == 1)
    #expect(harness.context.hasChanges)
    let beforeCommit = try #require(
      ModelContext(harness.container).fetch(
        FetchDescriptor<MemoryFormationJobRecord>(predicate: #Predicate { $0.id == jobID })
      ).first
    )
    #expect(beforeCommit.status == .failed)
    try harness.context.save()

    let verification = ModelContext(harness.container)
    let job = try #require(
      verification.fetch(
        FetchDescriptor<MemoryFormationJobRecord>(predicate: #Predicate { $0.id == jobID })
      ).first
    )
    let audit = try #require(
      verification.fetch(
        FetchDescriptor<MemoryFormationAuditRecord>(predicate: #Predicate { $0.jobID == jobID })
      ).first
    )
    #expect(job.status == .rejected)
    #expect(audit.outcome == .rejected)
    #expect(audit.providerMessageID == "formation-1")
    #expect(audit.providerRequestCount == 1)
    #expect(audit.cumulativeInputTokenCount == 12)
    #expect(audit.cumulativeOutputTokenCount == 3)
    #expect(try await store.prepare(jobID: jobID, provider: harness.provider) == nil)
  }

  private func makeHarness(
    userContent: String,
    assistantStatus: MessageStatus = .complete
  ) throws -> Harness {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversationID = UUID()
    let userMessageID = UUID()
    let assistantMessageID = UUID()
    context.insert(ConversationRecord(id: conversationID, title: "Automatic memory"))
    context.insert(
      MessageRecord(
        id: userMessageID,
        conversationID: conversationID,
        role: .user,
        content: userContent,
        status: .complete,
        createdAt: baseDate
      )
    )
    context.insert(
      MessageRecord(
        id: assistantMessageID,
        conversationID: conversationID,
        role: .assistant,
        content: "Anladım.",
        status: assistantStatus,
        createdAt: baseDate.addingTimeInterval(1)
      )
    )
    try context.save()
    return Harness(
      container: container,
      context: context,
      conversationID: conversationID,
      userMessageID: userMessageID,
      assistantMessageID: assistantMessageID,
      provider: makeProvider()
    )
  }

  private func applyTurn(
    store: AutomaticMemoryStore,
    context: ModelContext,
    conversationID: UUID,
    provider: ProviderConnection,
    userContent: String,
    operation makeOperation: (UUID, AutomaticMemoryFormationPreparation) ->
      AutomaticMemoryExtractionOperation,
    at date: Date
  ) async throws -> AutomaticMemoryFormationResult {
    let result = try await prepareTurnResult(
      store: store,
      context: context,
      conversationID: conversationID,
      provider: provider,
      userContent: userContent,
      operation: makeOperation,
      at: date
    )
    return try await store.apply(result, now: date.addingTimeInterval(4))
  }

  private func prepareTurnResult(
    store: AutomaticMemoryStore,
    context: ModelContext,
    conversationID: UUID,
    provider: ProviderConnection,
    userContent: String,
    operation makeOperation: (UUID, AutomaticMemoryFormationPreparation) ->
      AutomaticMemoryExtractionOperation,
    at date: Date
  ) async throws -> AutomaticMemoryExtractionGenerationResult {
    let userMessageID = UUID()
    let assistantMessageID = UUID()
    context.insert(
      MessageRecord(
        id: userMessageID,
        conversationID: conversationID,
        role: .user,
        content: userContent,
        status: .complete,
        createdAt: date
      )
    )
    context.insert(
      MessageRecord(
        id: assistantMessageID,
        conversationID: conversationID,
        role: .assistant,
        content: "Kaydettim.",
        status: .complete,
        createdAt: date.addingTimeInterval(1)
      )
    )
    try context.save()
    let enqueuedJobID = try await store.enqueue(
      conversationID: conversationID,
      throughUserMessageID: userMessageID,
      assistantMessageID: assistantMessageID,
      provider: provider,
      now: date.addingTimeInterval(2)
    )
    let jobID = try #require(enqueuedJobID)
    let prepared = try await store.prepare(
      jobID: jobID,
      provider: provider,
      now: date.addingTimeInterval(3)
    )
    let preparation = try #require(prepared)
    return generationResult(
      preparation: preparation,
      provider: provider,
      operation: makeOperation(userMessageID, preparation)
    )
  }

  private func operation(
    action: AutomaticMemoryExtractionAction = .upsert,
    targetID: UUID? = nil,
    canonicalKey: String,
    title: String,
    content: String,
    confidence: Double = 0.92,
    importance: Double = 0.8,
    stability: MemoryStability = .stable,
    scope: MemoryScope = .global,
    evidenceMessageID: UUID
  ) -> AutomaticMemoryExtractionOperation {
    AutomaticMemoryExtractionOperation(
      action: action,
      targetID: targetID,
      canonicalKey: canonicalKey,
      kind: .preference,
      title: title,
      content: content,
      scope: scope,
      confidence: confidence,
      importance: importance,
      stability: stability,
      evidenceMessageIDs: [evidenceMessageID]
    )
  }

  private func generationResult(
    preparation: AutomaticMemoryFormationPreparation,
    provider: ProviderConnection,
    operation: AutomaticMemoryExtractionOperation
  ) -> AutomaticMemoryExtractionGenerationResult {
    generationResult(
      preparation: preparation,
      provider: provider,
      operations: [operation]
    )
  }

  private func generationResult(
    preparation: AutomaticMemoryFormationPreparation,
    provider: ProviderConnection,
    operations: [AutomaticMemoryExtractionOperation]
  ) -> AutomaticMemoryExtractionGenerationResult {
    AutomaticMemoryExtractionGenerationResult(
      jobID: preparation.jobID,
      sourceFingerprint: preparation.sourceFingerprint,
      envelope: AutomaticMemoryExtractionEnvelope(operations: operations),
      existingTopics: preparation.existingTopics,
      providerConfigurationID: provider.id,
      providerKind: provider.provider,
      providerDisplayName: provider.displayName,
      providerEndpoint: provider.credentialBinding.endpoint,
      modelIdentifier: provider.modelIdentifier,
      providerMessageID: "provider-memory-response",
      inputTokenCount: 120,
      outputTokenCount: 45,
      projectID: preparation.projectID
    )
  }

  private func makeProvider() -> ProviderConnection {
    ProviderConnection(
      id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
      displayName: "OpenAI test",
      provider: .openAI,
      modelIdentifier: "memory-test-model",
      apiKey: "test-only"
    )
  }
}

@MainActor
private struct Harness {
  let container: ModelContainer
  let context: ModelContext
  let conversationID: UUID
  let userMessageID: UUID
  let assistantMessageID: UUID
  let provider: ProviderConnection
}

private struct MemoryFormationTelemetryStubClient: AIProviderClient {
  let events: [AIStreamEvent]

  func listModels() async throws -> [String] { [] }

  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }
}

extension AutomaticMemoryStoreTests {
  @Test(arguments: [false, true]) func removingLatestCorrectionCannotLeaveUnsupportedHeadActive(
    reinforceCorrection: Bool
  ) async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let originalConversation = UUID()
    let correctionConversation = UUID()
    let provider = makeProvider()
    context.insert(ConversationRecord(id: originalConversation, title: "Original"))
    context.insert(ConversationRecord(id: correctionConversation, title: "Correction"))
    try context.save()
    _ = try await applyTurn(
      store: AutomaticMemoryStore(modelContainer: container), context: context,
      conversationID: originalConversation, provider: provider,
      userContent: "I prefer Turkish replies.",
      operation: { messageID, _ in
        operation(
          canonicalKey: "language", title: "Reply language",
          content: "The user prefers Turkish replies.", evidenceMessageID: messageID)
      },
      at: baseDate)
    let topicID = try #require(
      ModelContext(container).fetch(FetchDescriptor<MemoryTopicRecord>()).first?.id)
    _ = try await applyTurn(
      store: AutomaticMemoryStore(modelContainer: container), context: context,
      conversationID: correctionConversation, provider: provider,
      userContent: "I now prefer English replies.",
      operation: { messageID, _ in
        operation(
          targetID: topicID, canonicalKey: "language",
          title: "Reply language", content: "The user now prefers English replies.",
          evidenceMessageID: messageID)
      },
      at: baseDate.addingTimeInterval(20))
    if reinforceCorrection {
      let supportingConversation = UUID()
      context.insert(ConversationRecord(id: supportingConversation, title: "Support"))
      try context.save()
      _ = try await applyTurn(
        store: AutomaticMemoryStore(modelContainer: container), context: context,
        conversationID: supportingConversation, provider: provider,
        userContent: "English replies are still my preference.",
        operation: { messageID, _ in
          operation(
            targetID: topicID, canonicalKey: "language",
            title: "Reply language", content: "The user now prefers English replies.",
            evidenceMessageID: messageID)
        },
        at: baseDate.addingTimeInterval(40))
    }
    let outcome = try await MosaicConversationDeletionPipeline.delete(
      conversationID: correctionConversation,
      sourceRepository: MosaicConversationSourceDeletionRepository(modelContainer: container),
      vectorRepository: MosaicConversationVectorDeletionRepository(modelContainer: container))
    #expect(outcome.didDeleteConversation)
    let fresh = ModelContext(container)
    let topic = try #require(fresh.fetch(FetchDescriptor<MemoryTopicRecord>()).first)
    let evidence = try fresh.fetch(FetchDescriptor<MemoryEvidenceRecord>())
    #expect(evidence.count == (reinforceCorrection ? 2 : 1))
    #expect(topic.status == (reinforceCorrection ? .active : .forgotten))
    #expect(topic.isEnabled == reinforceCorrection)
    #expect(topic.evidenceCount == evidence.count)
    let backup = try MosaicPortableBackup.export(from: fresh)
    _ = try await MosaicPortableBackup.prepareRestoreAsync(from: backup)
  }
}

extension AutomaticMemoryStoreTests {
  @Test func delayedEventFormationKeepsTheSourceDateAndOlderReportsCannotUndoResolution()
    async throws
  {
    let harness = try makeHarness(userContent: "Sokakta yavru kediler buldum.")
    let store = AutomaticMemoryStore(modelContainer: harness.container)
    func event(_ id: UUID, _ content: String, target: UUID? = nil)
      -> AutomaticMemoryExtractionOperation
    {
      AutomaticMemoryExtractionOperation(
        action: .upsert, targetID: target, canonicalKey: "found_kittens",
        kind: .event, title: "Found kittens", content: content, scope: .global,
        confidence: 0.95, importance: 0.7, stability: .evolving, evidenceMessageIDs: [id])
    }
    let jobID = try #require(
      try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID, assistantMessageID: harness.assistantMessageID,
        provider: harness.provider, now: baseDate.addingTimeInterval(86_400)))
    let preparation = try #require(
      try await store.prepare(
        jobID: jobID, provider: harness.provider,
        now: baseDate.addingTimeInterval(86_401)))
    _ = try await store.apply(
      generationResult(
        preparation: preparation, provider: harness.provider,
        operation: event(harness.userMessageID, "Found kittens on the street.")),
      now: baseDate.addingTimeInterval(86_402))
    let topic = try #require(harness.context.fetch(FetchDescriptor<MemoryTopicRecord>()).first)
    #expect(topic.lastConfirmedAt == baseDate)
    _ = try await applyTurn(
      store: store, context: harness.context, conversationID: harness.conversationID,
      provider: harness.provider, userContent: "Kedileri sahiplendirdim.",
      operation: { id, _ in
        event(id, "The kittens were rehomed.", target: topic.id)
      }, at: baseDate.addingTimeInterval(172_800))
    let older = try await applyTurn(
      store: store, context: harness.context, conversationID: harness.conversationID,
      provider: harness.provider, userContent: "Sokakta yavru kediler buldum.",
      operation: { id, _ in
        event(id, "Found kittens on the street.", target: topic.id)
      }, at: baseDate.addingTimeInterval(86_400))
    #expect(older.changedCount == 0)
    let current = try #require(
      ModelContext(harness.container).fetch(FetchDescriptor<MemoryTopicRecord>()).first)
    #expect(current.content == "The kittens were rehomed.")
    #expect(current.lastConfirmedAt == baseDate.addingTimeInterval(172_800))
  }

  @Test func promptUpgradeRetiresTheOldPendingJobWithoutRepeatedRequests() async throws {
    let harness = try makeHarness(userContent: "Sokakta yavru kediler buldum.")
    let store = AutomaticMemoryStore(modelContainer: harness.container)
    let oldID = try #require(
      try await store.enqueue(
        conversationID: harness.conversationID,
        throughUserMessageID: harness.userMessageID, assistantMessageID: harness.assistantMessageID,
        provider: harness.provider, promptVersion: "mosaic-automatic-memory-extraction-v3"))
    let client = MemoryFormationTelemetryStubClient(events: [
      .textDelta("{\"schema_version\":1,\"operations\":[]}"), .completed(responseID: "local-test"),
    ])
    _ = try await AutomaticMemoryFormationCoordinator().formMemory(
      conversationID: harness.conversationID,
      throughUserMessageID: harness.userMessageID, assistantMessageID: harness.assistantMessageID,
      provider: harness.provider, client: client, modelContainer: harness.container,
      resumingJobID: oldID)
    #expect(try await store.pendingJobs().isEmpty)
    let jobs = try harness.context.fetch(FetchDescriptor<MemoryFormationJobRecord>())
    #expect(jobs.count == 2)
    #expect(jobs.first { $0.id == oldID }?.status == .rejected)
    #expect(jobs.first { $0.id != oldID }?.status == .complete)
  }
}

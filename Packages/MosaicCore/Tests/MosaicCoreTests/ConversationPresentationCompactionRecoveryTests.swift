import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite("Conversation presentation compaction recovery")
@MainActor
struct ConversationPresentationCompactionRecoveryTests {
  @Test("opening a chat with no interrupted audit skips canonical history")
  func presentationRecoveryUsesAuditPreflight() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let missingConversationID = UUID()
    let operationCoordinator = MosaicOperationCoordinator()
    let recovery = ConversationPresentationCompactionRecovery(
      executionGate: ConversationCompactionExecutionGate(),
      operationCoordinator: operationCoordinator
    )

    #expect(
      try await recovery.reconcile(
        conversationID: missingConversationID,
        modelContainer: container
      ) == 0
    )
    #expect(operationCoordinator.activeOperations.isEmpty)
  }

  @Test("opening a chat waits for live compaction and reconciles an interrupted audit once")
  func presentationRecoveryIsExcludedFromLiveCompactionAndIdempotent() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversationID = UUID()
    let sourceMessageID = UUID()
    let assistantMessageID = UUID()
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    let canonicalMessages = [
      AIChatMessage(id: sourceMessageID, role: .user, content: "Keep this context.")
    ]

    context.insert(
      ConversationRecord(
        id: conversationID,
        title: "Recovery test",
        modelIdentifier: "test-model",
        createdAt: fixedDate,
        updatedAt: fixedDate
      )
    )
    context.insert(
      MessageRecord(
        id: sourceMessageID,
        conversationID: conversationID,
        role: .user,
        content: "Keep this context.",
        createdAt: fixedDate,
        updatedAt: fixedDate
      )
    )
    context.insert(
      MessageRecord(
        id: assistantMessageID,
        conversationID: conversationID,
        role: .assistant,
        content: "",
        status: .streaming,
        createdAt: fixedDate.addingTimeInterval(1),
        updatedAt: fixedDate.addingTimeInterval(1)
      )
    )
    try context.save()

    let generating = ConversationCompactionReceipt(
      attemptID: UUID(),
      status: .generating,
      attemptedMessageIDs: [sourceMessageID],
      providerConfigurationID: UUID(),
      providerKind: .anthropic,
      providerDisplayName: "Anthropic",
      providerEndpoint: "https://api.anthropic.com:443/v1",
      modelIdentifier: "claude-test",
      estimatedInputTokensBefore: 800,
      extraRequestCount: 1,
      warnings: ["Request opening was recorded before streaming."],
      createdAt: fixedDate.addingTimeInterval(2)
    )
    try NormalizedContextStore(modelContext: context).appendRequestEvent(
      assistantMessageID: assistantMessageID,
      conversationID: conversationID,
      sourceThroughMessageID: sourceMessageID,
      eventSequence: 0,
      receipt: RequestContextReceipt(
        curatedContext: .empty,
        retrievedContext: .empty,
        conversationCompaction: generating,
        createdAt: fixedDate.addingTimeInterval(2)
      ),
      canonicalMessages: canonicalMessages,
      createdAt: fixedDate.addingTimeInterval(2)
    )

    let gate = ConversationCompactionExecutionGate()
    let operationCoordinator = MosaicOperationCoordinator()
    let recovery = ConversationPresentationCompactionRecovery(
      executionGate: gate,
      operationCoordinator: operationCoordinator
    )

    #expect(operationCoordinator.beginExclusiveMaintenance())
    #expect(
      try await recovery.reconcile(
        conversationID: conversationID,
        modelContainer: container
      ) == 0
    )
    #expect(
      try latestReceipt(
        container: container,
        assistantMessageID: assistantMessageID,
        canonicalMessages: canonicalMessages
      ).conversationCompaction?.status == .generating
    )
    operationCoordinator.endExclusiveMaintenance()

    #expect(await gate.acquire(conversationID: conversationID))
    #expect(
      try await recovery.reconcile(
        conversationID: conversationID,
        modelContainer: container
      ) == 0
    )
    #expect(
      try latestReceipt(
        container: container,
        assistantMessageID: assistantMessageID,
        canonicalMessages: canonicalMessages
      ).conversationCompaction?.status == .generating
    )
    #expect(operationCoordinator.activeOperations.isEmpty)
    await gate.release(conversationID: conversationID)

    #expect(
      try await recovery.reconcile(
        conversationID: conversationID,
        modelContainer: container
      ) == 1
    )
    #expect(
      try latestReceipt(
        container: container,
        assistantMessageID: assistantMessageID,
        canonicalMessages: canonicalMessages
      ).conversationCompaction?.status == .failed
    )
    #expect(
      try await recovery.reconcile(
        conversationID: conversationID,
        modelContainer: container
      ) == 0
    )
    #expect(operationCoordinator.activeOperations.isEmpty)

    let verificationContext = ModelContext(container)
    let conversationIDForPredicate = conversationID
    let eventCount = try verificationContext.fetchCount(
      FetchDescriptor<RequestContextEventRecord>(
        predicate: #Predicate { $0.conversationID == conversationIDForPredicate }
      )
    )
    #expect(eventCount == 2)
  }

  private func latestReceipt(
    container: ModelContainer,
    assistantMessageID: UUID,
    canonicalMessages: [AIChatMessage]
  ) throws -> RequestContextReceipt {
    let context = ModelContext(container)
    return try #require(
      try NormalizedContextStore(modelContext: context).requestReceipt(
        assistantMessageID: assistantMessageID,
        canonicalMessages: canonicalMessages
      )
    )
  }
}

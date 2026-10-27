import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite("Interrupted conversation response recovery")
@MainActor
struct ConversationInterruptedResponseRecoveryTests {
  @Test("streaming assistant rows become retryable failures once per store generation")
  func marksOnlyInterruptedAssistantRows() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let coordinator = MosaicOperationCoordinator()
    let recovery = ConversationInterruptedResponseRecovery()
    let conversationID = UUID()
    let streamingEmpty = MessageRecord(
      conversationID: conversationID,
      role: .assistant,
      content: "",
      status: .streaming
    )
    let streamingPartial = MessageRecord(
      conversationID: conversationID,
      role: .assistant,
      content: "Partial reply",
      status: .streaming
    )
    let completedAssistant = MessageRecord(
      conversationID: conversationID,
      role: .assistant,
      content: "Complete reply"
    )
    let streamingUser = MessageRecord(
      conversationID: conversationID,
      role: .user,
      content: "Unusual imported state",
      status: .streaming
    )
    context.insert(ConversationRecord(id: conversationID))
    for message in [streamingEmpty, streamingPartial, completedAssistant, streamingUser] {
      context.insert(message)
    }
    try coordinator.saveSourceChanges(in: context)

    #expect(
      try recovery.reconcile(
        in: context,
        sourceGeneration: 4,
        operationCoordinator: coordinator
      ) == 2
    )
    #expect(streamingEmpty.status == .failed)
    #expect(streamingPartial.status == .failed)
    #expect(streamingEmpty.errorDescription?.contains("try") == true)
    #expect(completedAssistant.status == .complete)
    #expect(streamingUser.status == .streaming)
    #expect(
      try recovery.reconcile(
        in: context,
        sourceGeneration: 4,
        operationCoordinator: coordinator
      ) == 0
    )
  }

  @Test("live provider work prevents false crash recovery")
  func skipsWhileAnOperationIsActive() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let coordinator = MosaicOperationCoordinator()
    let recovery = ConversationInterruptedResponseRecovery()
    let conversationID = UUID()
    let message = MessageRecord(
      conversationID: conversationID,
      role: .assistant,
      content: "In flight",
      status: .streaming
    )
    context.insert(ConversationRecord(id: conversationID))
    context.insert(message)
    try coordinator.saveSourceChanges(in: context)

    let operationID = MosaicOperationID.conversationRequest(conversationID)
    #expect(coordinator.begin(operationID))
    #expect(
      try recovery.reconcile(
        in: context,
        sourceGeneration: 0,
        operationCoordinator: coordinator
      ) == 0
    )
    #expect(message.status == .streaming)

    coordinator.end(operationID)
    #expect(
      try recovery.reconcile(
        in: context,
        sourceGeneration: 0,
        operationCoordinator: coordinator
      ) == 1
    )
    #expect(message.status == .failed)
  }

  @Test("operation-drain scans can repair rows created after the generation scan")
  func rescansAfterOperationsDrain() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let coordinator = MosaicOperationCoordinator()
    let recovery = ConversationInterruptedResponseRecovery()
    let conversationID = UUID()
    context.insert(ConversationRecord(id: conversationID))
    try coordinator.saveSourceChanges(in: context)

    #expect(
      try recovery.reconcile(
        in: context,
        sourceGeneration: 7,
        reason: .generationOpened,
        operationCoordinator: coordinator
      ) == 0
    )

    let operationID = MosaicOperationID.conversationRequest(conversationID)
    #expect(coordinator.begin(operationID))
    let terminalSaveOrphan = MessageRecord(
      conversationID: conversationID,
      role: .assistant,
      content: "Persisted partial response",
      status: .streaming
    )
    context.insert(terminalSaveOrphan)
    try coordinator.saveSourceChanges(in: context)
    coordinator.end(operationID)

    // Repeating the launch trigger stays bounded, but releasing the owning operation is a new
    // recovery opportunity for a terminal save that did not commit its final status.
    #expect(
      try recovery.reconcile(
        in: context,
        sourceGeneration: 7,
        reason: .generationOpened,
        operationCoordinator: coordinator
      ) == 0
    )
    #expect(terminalSaveOrphan.status == .streaming)
    #expect(
      try recovery.reconcile(
        in: context,
        sourceGeneration: 7,
        reason: .operationsDrained,
        operationCoordinator: coordinator
      ) == 1
    )
    #expect(terminalSaveOrphan.status == .failed)
    #expect(
      try recovery.reconcile(
        in: context,
        sourceGeneration: 7,
        reason: .operationsDrained,
        operationCoordinator: coordinator
      ) == 0
    )
  }
}

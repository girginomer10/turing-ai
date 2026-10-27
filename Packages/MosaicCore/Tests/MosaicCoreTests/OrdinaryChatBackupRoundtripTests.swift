import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite("Ordinary chat backup roundtrip") @MainActor
struct OrdinaryChatBackupRoundtripTests {
  @Test(arguments: [false, true]) func fullHistoryBackupRoundTrip(explicitEmptySummary: Bool)
    async throws
  {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversation = ConversationRecord(title: "Minimal ordinary chat")
    let date = Date(timeIntervalSince1970: 1_750_000_000)
    let user = MessageRecord(
      conversationID: conversation.id, role: .user, content: "Hello", status: .complete,
      createdAt: date)
    let assistant = MessageRecord(
      conversationID: conversation.id, role: .assistant, content: "Hello back", status: .complete,
      createdAt: date.addingTimeInterval(1))
    context.insert(conversation)
    context.insert(user)
    context.insert(assistant)
    try context.save()
    let receipt = RequestContextReceipt(
      curatedContext: .empty, retrievedContext: .empty,
      conversationContext: ConversationContextReceipt(
        strategy: .full, originalMessageCount: 1,
        includedMessageIDs: [user.id], omittedMessageIDs: [],
        summarizedMessageIDs: explicitEmptySummary ? [] : nil,
        recalledMessageIDs: [], estimatedInputTokens: 16, contextWindowTokens: 8192,
        maximumOutputTokens: 2048, safetyMarginTokens: 1024), createdAt: date)
    _ = try NormalizedContextStore(modelContext: context).appendRequestEvent(
      assistantMessageID: assistant.id,
      conversationID: conversation.id, sourceThroughMessageID: user.id, eventSequence: 0,
      receipt: receipt,
      canonicalMessages: [AIChatMessage(id: user.id, role: .user, content: user.content)],
      createdAt: date)
    let backup = try MosaicPortableBackup.export(from: context)
    _ = try await MosaicPortableBackup.prepareRestoreAsync(from: backup)
  }
}

extension OrdinaryChatBackupRoundtripTests {
  @Test func restorePreviewCountsOnlyLearnedTopics() {
    let records = [
      (AutomaticMemoryPortableArchive.namespace, "topic"),
      (AutomaticMemoryPortableArchive.namespace, "topic"),
      (AutomaticMemoryPortableArchive.namespace, "revision"),
      (AutomaticMemoryPortableArchive.namespace, "evidence"),
      ("different.namespace", "topic"),
    ].map { namespace, type in
      MosaicPortableExtensionRecord(
        namespace: namespace, recordType: type, recordVersion: 1,
        id: UUID(), payload: Data())
    }
    #expect(AutomaticMemoryPortableArchive.topicCount(in: records) == 2)
    #expect(AutomaticMemoryPortableArchive.topicCount(in: []) == 0)
  }
}

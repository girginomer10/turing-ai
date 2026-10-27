import Foundation
import SwiftData
import XCTest

@testable import MosaicCore

final class MemoryContextBuilderTests: XCTestCase {
  func testIncludesOnlyEnabledAndUserApprovedMemories() {
    let approvedID = UUID()
    let memories = [
      snapshot(
        id: approvedID,
        title: "Language",
        content: "The user prefers Turkish.",
        isEnabled: true,
        isUserApproved: true
      ),
      snapshot(
        title: "Disabled",
        content: "Do not include this.",
        isEnabled: false,
        isUserApproved: true
      ),
      snapshot(
        title: "Pending approval",
        content: "Do not include this either.",
        isEnabled: true,
        isUserApproved: false
      ),
    ]

    let context = MemoryContextBuilder().build(from: memories)

    XCTAssertEqual(context.includedMemories.map(\.id), [approvedID])
    XCTAssertTrue(context.systemContent.contains("manually curated"))
    XCTAssertTrue(context.systemContent.contains("The user prefers Turkish."))
    XCTAssertTrue(context.systemContent.contains(approvedID.uuidString))
    XCTAssertFalse(context.systemContent.contains("Do not include this"))
  }

  func testConversationMemoryDoesNotLeakAcrossConversations() {
    let activeConversationID = UUID()
    let otherConversationID = UUID()
    let memories = [
      snapshot(
        title: "Global",
        content: "Visible everywhere.",
        scope: .global,
        isUserApproved: true
      ),
      snapshot(
        title: "Active conversation",
        content: "Visible here.",
        scope: .conversation,
        conversationID: activeConversationID,
        isUserApproved: true
      ),
      snapshot(
        title: "Other conversation",
        content: "Must stay isolated.",
        scope: .conversation,
        conversationID: otherConversationID,
        isUserApproved: true
      ),
    ]

    let context = MemoryContextBuilder().build(
      from: memories,
      for: activeConversationID
    )

    XCTAssertEqual(context.includedMemories.count, 2)
    XCTAssertTrue(context.systemContent.contains("Visible everywhere."))
    XCTAssertTrue(context.systemContent.contains("Visible here."))
    XCTAssertFalse(context.systemContent.contains("Must stay isolated."))
  }

  func testBuildWithoutConversationIDUsesOnlyGlobalMemories() {
    let context = MemoryContextBuilder().build(
      from: [
        snapshot(
          title: "Conversation only",
          content: "Scoped content.",
          scope: .conversation,
          conversationID: UUID(),
          isUserApproved: true
        )
      ]
    )

    XCTAssertTrue(context.isEmpty)
    XCTAssertEqual(context.systemContent, "")
  }

  func testRespectsContentBudgetAndOrdersNewestFirst() {
    let olderDate = Date(timeIntervalSince1970: 100)
    let newerDate = Date(timeIntervalSince1970: 200)
    let memories = [
      snapshot(
        title: "Older",
        content: "older",
        isUserApproved: true,
        updatedAt: olderDate
      ),
      snapshot(
        title: "Newer",
        content: "abcdefghij",
        isUserApproved: true,
        updatedAt: newerDate
      ),
    ]

    let context = MemoryContextBuilder(
      maximumMemories: 2,
      maximumContentCharacters: 6
    ).build(from: memories)

    XCTAssertEqual(context.includedMemories.count, 1)
    XCTAssertEqual(context.includedMemories[0].title, "Newer")
    XCTAssertEqual(context.includedMemories[0].content, "abcde…")
  }

  func testBoundsTitlesAndFinalEscapedUTF8Payload() throws {
    let context = MemoryContextBuilder(
      maximumMemories: 1,
      maximumContentCharacters: 12_000,
      maximumTitleCharacters: 24,
      maximumContextUTF8Bytes: 1_024
    ).build(
      from: [
        snapshot(
          title: String(repeating: "&", count: 10_000),
          content: String(repeating: "<&>", count: 10_000),
          isUserApproved: true
        )
      ]
    )

    let included = try XCTUnwrap(context.includedMemories.first)
    XCTAssertLessThanOrEqual(included.title.count, 24)
    XCTAssertLessThan(included.content.count, 30_000)
    XCTAssertLessThanOrEqual(context.systemContent.utf8.count, 1_024)
    XCTAssertTrue(context.systemContent.contains("&amp;"))
  }

  func testRecordOverloadUsesThePersistedApprovalFlags() {
    let record = MemoryRecord(
      title: "Preference",
      content: "Use concise answers.",
      isEnabled: true,
      isUserApproved: true
    )

    let context = MemoryContextBuilder().build(from: [record])

    XCTAssertEqual(context.includedMemories.map(\.id), [record.id])
  }

  @MainActor
  func testSchemaCanPersistAllPublicRecordTypes() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversationID = UUID()
    let compactedSource = [
      AIChatMessage(role: .user, content: "Earlier question"),
      AIChatMessage(role: .assistant, content: "Earlier answer"),
    ]
    let compaction = ConversationCompactionSnapshot(
      conversationID: conversationID,
      mode: .initial,
      content: ConversationCompactionContent(
        overview: "Earlier continuity",
        items: [ConversationCompactionItem(kind: .openLoop, text: "Finish the task")]
      ),
      coveredMessageIDs: compactedSource.map(\.id),
      sourceFingerprint: ConversationCompactionPlanner.sourceFingerprint(for: compactedSource),
      providerConfigurationID: UUID(),
      providerKind: .deepInfra,
      providerDisplayName: "DeepInfra",
      providerEndpoint: "https://api.deepinfra.com:443/v1/openai",
      modelIdentifier: "summary-model",
      estimatedSourceTokens: 400,
      estimatedSummaryTokens: 40,
      chainDepth: 1
    )
    let conversation = ConversationRecord(
      id: conversationID,
      title: "Test",
      compactionSnapshot: compaction
    )
    let provider = ProviderConfigurationRecord(
      displayName: "Custom",
      provider: .custom,
      modelIdentifier: "model",
      contextWindowTokens: 16_384,
      maximumOutputTokens: 1_024
    )
    let receipt = RequestContextReceipt(
      curatedContext: MemoryContext(
        systemContent: "Pinned context",
        includedMemories: [
          IncludedMemory(
            id: UUID(),
            title: "Preference",
            content: "Concise answers",
            scope: .global
          )
        ]
      ),
      retrievedContext: .empty
    )
    let message = MessageRecord(
      conversationID: conversation.id,
      role: .user,
      content: "Hello",
      contextReceipt: receipt
    )

    context.insert(conversation)
    context.insert(message)
    context.insert(
      MemoryRecord(
        title: "Preference",
        content: "Concise answers",
        isUserApproved: true
      )
    )
    context.insert(
      ScheduledTaskRecord(
        title: "Daily brief",
        prompt: "Summarize my day",
        recurrence: .daily,
        scheduledAt: .now
      )
    )
    context.insert(provider)
    let profile = EmbeddingProfileRecord(
      displayName: "Local Qwen",
      providerConfigurationID: provider.id,
      modelIdentifier: "qwen3-embedding:0.6b"
    )
    let document = ImportedDocumentRecord(
      title: "Notes",
      sourceFilename: "notes.txt",
      mimeType: "text/plain",
      contentFingerprint: "document-hash",
      characterCount: 12,
      ocrPageCount: 2
    )
    let chunk = DocumentChunkRecord(
      documentID: document.id,
      chunkIndex: 0,
      content: "Example text",
      isOCRDerived: true
    )
    context.insert(profile)
    context.insert(document)
    context.insert(chunk)
    try context.save()

    XCTAssertEqual(try context.fetchCount(FetchDescriptor<ConversationRecord>()), 1)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<MessageRecord>()), 1)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemoryRecord>()), 1)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScheduledTaskRecord>()), 1)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProviderConfigurationRecord>()), 1)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<EmbeddingProfileRecord>()), 1)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<ImportedDocumentRecord>()), 1)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<DocumentChunkRecord>()), 1)
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<ImportedDocumentRecord>()).first?.ocrPageCount,
      2
    )
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<DocumentChunkRecord>()).first?.isOCRDerived,
      true
    )
    let savedProvider = try context.fetch(FetchDescriptor<ProviderConfigurationRecord>()).first
    XCTAssertEqual(savedProvider?.contextWindowTokens, 16_384)
    XCTAssertEqual(savedProvider?.maximumOutputTokens, 1_024)
    XCTAssertEqual(message.contextReceipt, receipt)
    let savedConversation = try context.fetch(FetchDescriptor<ConversationRecord>()).first
    XCTAssertEqual(savedConversation?.compactionSnapshot, compaction)
  }

  func testMessagePersistsProviderKindSnapshot() {
    let message = MessageRecord(
      conversationID: UUID(),
      role: .assistant,
      content: "Hello",
      providerConfigurationID: UUID(),
      providerKind: .openAI
    )

    XCTAssertEqual(message.providerKindRawValue, ProviderKind.openAI.rawValue)
    XCTAssertEqual(message.providerKindSnapshot, .openAI)

    message.providerKindSnapshot = .anthropic

    XCTAssertEqual(message.providerKindRawValue, ProviderKind.anthropic.rawValue)
    XCTAssertEqual(message.providerKindSnapshot, .anthropic)
  }

  @MainActor
  func testSemanticVectorIndexUsesASeparateRebuildableStore() throws {
    let container = try SemanticIndexStore.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let profileID = UUID()
    let sourceID = UUID()
    let vector = EmbeddingVectorRecord(
      profileID: profileID,
      sourceKind: .documentChunk,
      sourceID: sourceID,
      embeddingSpaceIdentifier: "space",
      contentFingerprint: "chunk-hash",
      dimensions: 2,
      vectorData: EmbeddingVectorCodec.encode([0.5, 0.5])
    )
    context.insert(vector)
    try context.save()
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<EmbeddingVectorRecord>()), 1)
    XCTAssertEqual(
      vector.cacheKey,
      EmbeddingVectorRecord.makeCacheKey(profileID: profileID, sourceID: sourceID)
    )
  }

  private func snapshot(
    id: UUID = UUID(),
    title: String,
    content: String,
    scope: MemoryScope = .global,
    conversationID: UUID? = nil,
    isEnabled: Bool = true,
    isUserApproved: Bool = false,
    updatedAt: Date = .now
  ) -> MemorySnapshot {
    MemorySnapshot(
      id: id,
      title: title,
      content: content,
      scope: scope,
      conversationID: conversationID,
      isEnabled: isEnabled,
      isUserApproved: isUserApproved,
      updatedAt: updatedAt
    )
  }
}

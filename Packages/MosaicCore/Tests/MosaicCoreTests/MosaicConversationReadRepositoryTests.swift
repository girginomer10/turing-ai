import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite("Mosaic conversation read repository")
@MainActor
struct MosaicConversationReadRepositoryTests {
  private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

  @Test("513 messages page deterministically with a mutation-stable keyset")
  func transcriptPaginationIsBoundedAndDeterministic() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversation = ConversationRecord(title: "Large transcript", modelIdentifier: "model")
    context.insert(conversation)

    let receiptData = Data([0x01, 0x02, 0x03])
    var expectedIDs: [UUID] = []
    for index in 0..<513 {
      let messageID = id(index + 1)
      expectedIDs.append(messageID)
      let message = MessageRecord(
        id: messageID,
        conversationID: conversation.id,
        role: index.isMultiple(of: 2) ? .user : .assistant,
        content: "message-\(index)",
        status: index == 512 ? .failed : .complete,
        providerConfigurationID: index == 512 ? id(10_000) : nil,
        providerKind: index == 512 ? .anthropic : nil,
        providerDisplayName: index == 512 ? "Anthropic" : nil,
        providerHost: index == 512 ? "api.anthropic.com" : nil,
        providerMessageID: index == 512 ? "provider-message" : nil,
        modelIdentifier: index == 512 ? "claude-test" : nil,
        inputTokenCount: index == 512 ? 120 : nil,
        outputTokenCount: index == 512 ? 45 : nil,
        errorDescription: index == 512 ? "Synthetic failure" : nil,
        createdAt: baseDate.addingTimeInterval(Double(index)),
        updatedAt: baseDate.addingTimeInterval(Double(index) + 0.5)
      )
      if index == 512 { message.contextReceiptData = receiptData }
      context.insert(message)
    }
    try context.save()

    let repository = MosaicConversationReadRepository(modelContainer: container)
    let first = try await repository.transcriptPage(
      conversationID: conversation.id,
      pageSize: 64
    )
    #expect(first.messages.count == 16)
    #expect(first.messages.map(\.id) == Array(expectedIDs[497...512]))
    #expect(first.hasMore)
    #expect(
      first.nextCursor
        == MosaicTranscriptCursor(
          createdAt: baseDate.addingTimeInterval(497),
          id: expectedIDs[497]
        )
    )
    let latest = try #require(first.messages.last)
    #expect(latest.providerConfigurationID == id(10_000))
    #expect(latest.providerKind == .anthropic)
    #expect(latest.providerDisplayName == "Anthropic")
    #expect(latest.providerHost == "api.anthropic.com")
    #expect(latest.providerMessageID == "provider-message")
    #expect(latest.modelIdentifier == "claude-test")
    #expect(latest.inputTokenCount == 120)
    #expect(latest.outputTokenCount == 45)
    #expect(latest.errorDescription == "Synthetic failure")
    #expect(latest.contextReceiptData == receiptData)

    let appendedID = id(20_000)
    context.insert(
      MessageRecord(
        id: appendedID,
        conversationID: conversation.id,
        role: .user,
        content: "new after snapshot",
        createdAt: baseDate.addingTimeInterval(1_000)
      )
    )
    try context.save()

    let deletedID = expectedIDs[300]
    let deletedDescriptor = FetchDescriptor<MessageRecord>(
      predicate: #Predicate { $0.id == deletedID }
    )
    context.delete(try #require(context.fetch(deletedDescriptor).first))
    let backdatedID = id(20_001)
    context.insert(
      MessageRecord(
        id: backdatedID,
        conversationID: conversation.id,
        role: .assistant,
        content: "concurrently backdated",
        createdAt: baseDate.addingTimeInterval(300.5)
      )
    )
    try context.save()

    var pages = [first]
    while pages.last?.hasMore == true {
      let cursor = try #require(pages.last?.nextCursor)
      let page = try await repository.transcriptPage(
        conversationID: conversation.id,
        before: cursor,
        pageSize: 64
      )
      #expect(page.messages.count <= 16)
      pages.append(page)
    }

    let pagedIDs = pages.reversed().flatMap { $0.messages.map(\.id) }
    var expectedPagedIDs = expectedIDs
    expectedPagedIDs.remove(at: 300)
    expectedPagedIDs.insert(backdatedID, at: 300)
    #expect(pagedIDs == expectedPagedIDs)
    #expect(Set(pagedIDs).count == 513)
    #expect(!pagedIDs.contains(appendedID))
    #expect(!pagedIDs.contains(deletedID))
    #expect(pages.count == 33)
    #expect(pages.last?.messages.count == 1)
    #expect(pages.last?.hasMore == false)
  }

  @Test("blank curated memories do not hide older valid memories")
  func curatedMemoryPagingSkipsBlankRows() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversationID = id(30_000)
    let otherConversationID = id(30_001)

    for index in 0..<121 {
      context.insert(
        MemoryRecord(
          id: id(31_000 + index),
          title: "Blank \(index)",
          content: index.isMultiple(of: 2) ? "   " : "\n\t",
          scope: .global,
          isEnabled: true,
          isUserApproved: true,
          createdAt: baseDate.addingTimeInterval(Double(2_000 - index)),
          updatedAt: baseDate.addingTimeInterval(Double(2_000 - index))
        )
      )
    }

    let matchingConversationID = id(32_000)
    context.insert(
      MemoryRecord(
        id: matchingConversationID,
        title: "Conversation fact",
        content: "Use the current conversation preference.",
        scope: .conversation,
        conversationID: conversationID,
        isEnabled: true,
        isUserApproved: true,
        createdAt: baseDate.addingTimeInterval(1_000),
        updatedAt: baseDate.addingTimeInterval(1_000)
      )
    )
    context.insert(
      MemoryRecord(
        id: id(32_001),
        title: "Other conversation",
        content: "Must not be included.",
        scope: .conversation,
        conversationID: otherConversationID,
        isEnabled: true,
        isUserApproved: true,
        createdAt: baseDate.addingTimeInterval(999),
        updatedAt: baseDate.addingTimeInterval(999)
      )
    )

    var expectedGlobalIDs: [UUID] = []
    for index in 0..<25 {
      let memoryID = id(33_000 + index)
      expectedGlobalIDs.append(memoryID)
      context.insert(
        MemoryRecord(
          id: memoryID,
          title: "Valid \(index)",
          content: "valid-content-\(index)",
          scope: .global,
          isEnabled: true,
          isUserApproved: true,
          createdAt: baseDate.addingTimeInterval(Double(900 - index)),
          updatedAt: baseDate.addingTimeInterval(Double(900 - index))
        )
      )
    }
    try context.save()

    let result = try await MosaicConversationReadRepository(
      modelContainer: container
    ).curatedMemoryContext(
      conversationID: conversationID,
      pageSize: 32
    )

    #expect(result.includedMemories.count == 20)
    #expect(result.includedMemories.first?.id == matchingConversationID)
    #expect(
      result.includedMemories.dropFirst().map(\.id)
        == Array(expectedGlobalIDs.prefix(19))
    )
    #expect(!result.includedMemories.contains { $0.id == id(32_001) })
    #expect(result.includedMemories.allSatisfy { !$0.content.isEmpty })
    #expect(result.includedMemories.map(\.content.count).reduce(0, +) <= 12_000)
  }

  @Test("another project's large memory library cannot starve the current audience")
  func unrelatedProjectMemoriesDoNotConsumeTheAudienceScanBudget() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let targetProject = ProjectRecord(name: "Target")
    let noisyProject = ProjectRecord(name: "Noisy")
    let conversation = ConversationRecord(title: "Target chat")
    context.insert(targetProject)
    context.insert(noisyProject)
    context.insert(conversation)

    for index in 0..<4_096 {
      let memory = MemoryRecord(
        title: "Noisy \(index)",
        content: "This belongs to another project.",
        scope: .project,
        isEnabled: true,
        isUserApproved: true,
        createdAt: baseDate.addingTimeInterval(Double(20_000 - index)),
        updatedAt: baseDate.addingTimeInterval(Double(20_000 - index))
      )
      context.insert(memory)
      context.insert(
        ProjectResourceBindingRecord(
          resourceKind: .memory,
          resourceID: memory.id,
          projectID: noisyProject.id
        )
      )
    }
    let targetMemory = MemoryRecord(
      title: "Target fact",
      content: "This exact project fact must remain visible.",
      scope: .project,
      isEnabled: true,
      isUserApproved: true,
      createdAt: baseDate,
      updatedAt: baseDate
    )
    let globalMemory = MemoryRecord(
      title: "Global fact",
      content: "This global fact must remain visible.",
      scope: .global,
      isEnabled: true,
      isUserApproved: true,
      createdAt: baseDate.addingTimeInterval(-1),
      updatedAt: baseDate.addingTimeInterval(-1)
    )
    context.insert(targetMemory)
    context.insert(globalMemory)
    context.insert(
      ProjectResourceBindingRecord(
        resourceKind: .memory,
        resourceID: targetMemory.id,
        projectID: targetProject.id
      )
    )
    context.insert(
      ProjectResourceBindingRecord(
        resourceKind: .conversation,
        resourceID: conversation.id,
        projectID: targetProject.id
      )
    )
    try context.save()

    let result = try await MosaicConversationReadRepository(
      modelContainer: container
    ).curatedMemoryContext(conversationID: conversation.id)

    #expect(Set(result.includedMemories.map(\.id)) == Set([targetMemory.id, globalMemory.id]))
    #expect(!result.systemContent.contains("This belongs to another project."))
  }

  @Test("curated memory paging is stable across concurrent updated-at mutations")
  func curatedMemoryPagingIgnoresUpdatedAtMutations() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    var expectedIDs: [UUID] = []
    for index in 0..<11 {
      let memoryID = id(34_000 + index)
      expectedIDs.append(memoryID)
      context.insert(
        MemoryRecord(
          id: memoryID,
          title: "Memory \(index)",
          content: "memory-content-\(index)",
          scope: .global,
          isEnabled: true,
          isUserApproved: true,
          createdAt: baseDate.addingTimeInterval(Double(index / 2)),
          updatedAt: baseDate.addingTimeInterval(Double(index))
        )
      )
    }
    try context.save()

    let repository = MosaicConversationReadRepository(modelContainer: container)
    let first = try await repository.curatedMemoryPage(
      conversationID: nil,
      pageSize: 4
    )
    #expect(first.memories.map(\.id) == Array(expectedIDs[7...10].reversed()))
    #expect(first.hasMore)

    let mutationContext = ModelContext(container)
    let newestFetchedID = expectedIDs[10]
    let oldestUnfetchedID = expectedIDs[0]
    let mutationTargets = [newestFetchedID, oldestUnfetchedID]
    let mutationDescriptor = FetchDescriptor<MemoryRecord>(
      predicate: #Predicate { mutationTargets.contains($0.id) }
    )
    let mutationRecords = try mutationContext.fetch(mutationDescriptor)
    try #require(mutationRecords.count == 2)
    for record in mutationRecords {
      record.updatedAt =
        record.id == newestFetchedID
        ? baseDate.addingTimeInterval(-10_000)
        : baseDate.addingTimeInterval(10_000)
    }
    try mutationContext.save()

    var pages = [first]
    while pages.last?.hasMore == true {
      let cursor = try #require(pages.last?.nextCursor)
      pages.append(
        try await repository.curatedMemoryPage(
          conversationID: nil,
          before: cursor,
          pageSize: 4
        )
      )
    }

    let pagedIDs = pages.flatMap { $0.memories.map(\.id) }
    #expect(pagedIDs == expectedIDs.reversed())
    #expect(Set(pagedIDs).count == expectedIDs.count)
    #expect(pages.map(\.memories.count) == [4, 4, 3])
  }

  @Test("curated memory bounds pathological titles, content, and rendered bytes")
  func curatedMemoryBoundsRetainedAndRenderedText() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let memoryID = id(35_000)
    context.insert(
      MemoryRecord(
        id: memoryID,
        title: String(repeating: "<&>", count: 100_000),
        content: String(repeating: "memory & fact ", count: 100_000),
        scope: .global,
        isEnabled: true,
        isUserApproved: true,
        updatedAt: baseDate
      )
    )
    try context.save()

    let result = try await MosaicConversationReadRepository(
      modelContainer: container
    ).curatedMemoryContext(conversationID: nil)

    let included = try #require(result.includedMemories.first)
    #expect(included.id == memoryID)
    #expect(included.title.count <= 160)
    #expect(included.content.count <= 12_000)
    #expect(result.systemContent.utf8.count <= 64 * 1_024)
  }

  @Test("canonical state is complete, deterministic, and resolves normalized plus legacy state")
  func canonicalStateBuildsProviderHistoryAndRecallCandidates() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversationID = id(40_000)
    let tiedDate = baseDate.addingTimeInterval(10)
    let userID = id(40_003)
    let assistantID = id(40_002)
    let blankUserID = id(40_004)
    let failedUserID = id(40_005)
    let finalUserID = id(40_008)
    let canonicalMessages = [
      AIChatMessage(id: userID, role: .user, content: "First user"),
      AIChatMessage(id: assistantID, role: .assistant, content: "First assistant"),
      AIChatMessage(id: blankUserID, role: .user, content: "  \n"),
      AIChatMessage(id: finalUserID, role: .user, content: "Final user"),
    ]
    let snapshot = ConversationCompactionSnapshot(
      id: id(40_100),
      conversationID: conversationID,
      mode: .initial,
      content: ConversationCompactionContent(
        overview: "Verified summary",
        items: [.init(kind: .fact, text: "A durable fact")]
      ),
      coveredMessageIDs: [userID, assistantID],
      sourceFingerprint: ConversationCompactionPlanner.sourceFingerprint(
        for: Array(canonicalMessages.prefix(2))
      ),
      providerConfigurationID: id(40_101),
      providerKind: .openAI,
      providerDisplayName: "OpenAI",
      providerEndpoint: "https://api.openai.com:443/v1",
      modelIdentifier: "gpt-test",
      estimatedSourceTokens: 100,
      estimatedSummaryTokens: 25,
      chainDepth: 1,
      createdAt: baseDate.addingTimeInterval(20)
    )
    let conversation = ConversationRecord(
      id: conversationID,
      title: "Canonical title",
      modelIdentifier: "model",
      compactionSnapshot: snapshot
    )
    context.insert(conversation)
    context.insert(
      MessageRecord(
        id: assistantID,
        conversationID: conversationID,
        role: .assistant,
        content: "First assistant",
        createdAt: tiedDate
      )
    )
    context.insert(
      MessageRecord(
        id: userID,
        conversationID: conversationID,
        role: .user,
        content: "First user",
        createdAt: tiedDate
      )
    )
    context.insert(
      MessageRecord(
        id: blankUserID,
        conversationID: conversationID,
        role: .user,
        content: "  \n",
        createdAt: tiedDate.addingTimeInterval(1)
      )
    )
    context.insert(
      MessageRecord(
        id: failedUserID,
        conversationID: conversationID,
        role: .user,
        content: "Failed user",
        status: .failed,
        createdAt: tiedDate.addingTimeInterval(2)
      )
    )
    context.insert(
      MessageRecord(
        id: id(40_006),
        conversationID: conversationID,
        role: .tool,
        content: "Tool output",
        createdAt: tiedDate.addingTimeInterval(3)
      )
    )
    context.insert(
      MessageRecord(
        id: id(40_007),
        conversationID: conversationID,
        role: .assistant,
        content: "Streaming",
        status: .streaming,
        createdAt: tiedDate.addingTimeInterval(4)
      )
    )
    context.insert(
      MessageRecord(
        id: finalUserID,
        conversationID: conversationID,
        role: .user,
        content: "Final user",
        createdAt: tiedDate.addingTimeInterval(5)
      )
    )
    try context.save()
    try NormalizedContextStore(modelContext: context).activateCompactionSnapshot(
      snapshot,
      conversationID: conversationID,
      expectedCurrentArtifactID: nil,
      canonicalMessages: canonicalMessages
    )

    let state = try await MosaicConversationReadRepository(
      modelContainer: container
    ).canonicalState(conversationID: conversationID)

    #expect(state.messages == canonicalMessages)
    #expect(state.recallCandidates.map(\.id) == [userID, finalUserID])
    #expect(state.recallCandidates.allSatisfy { $0.title == "Canonical title" })
    #expect(state.activeCompactionSnapshot == snapshot)
    #expect(state.normalizedCompactionArtifactID == snapshot.id)
    #expect(state.activeCompactionSource == .normalized)

    let retryPrefix = try await MosaicConversationReadRepository(
      modelContainer: container
    ).completedMessages(
      conversationID: conversationID,
      before: failedUserID
    )
    #expect(retryPrefix == Array(canonicalMessages.prefix(3)))
  }

  @Test("canonical history fails closed at the aggregate UTF-8 limit")
  func canonicalHistoryRejectsAggregateByteOverflow() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversation = ConversationRecord(
      id: id(50_000),
      title: "Bounded canonical history",
      modelIdentifier: "model"
    )
    context.insert(conversation)
    let messageContent = String(
      repeating: "x",
      count: MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes
    )
    for index in 0..<33 {
      context.insert(
        MessageRecord(
          id: id(50_100 + index),
          conversationID: conversation.id,
          role: index.isMultiple(of: 2) ? .user : .assistant,
          content: messageContent,
          createdAt: baseDate.addingTimeInterval(Double(index))
        )
      )
    }
    try context.save()

    do {
      _ = try await MosaicConversationReadRepository(
        modelContainer: container
      ).canonicalState(conversationID: conversation.id)
      Issue.record("Expected canonical history byte overflow")
    } catch let error as MosaicConversationReadError {
      #expect(
        error
          == .canonicalHistoryLimitExceeded(
            maximumRecords: 20_000,
            maximumUTF8Bytes: 16 * 1_024 * 1_024
          )
      )
    }
  }

  private func id(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
  }
}

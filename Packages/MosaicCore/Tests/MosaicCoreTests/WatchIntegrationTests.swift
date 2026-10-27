import Foundation
import SwiftData
import Testing
import TuringVoice

@testable import MosaicCore

@Suite(.serialized) struct WatchIntegrationTests {
  private func choice(_ id: UUID = UUID()) -> WatchModel {
    WatchModel(
      endpoint: VoiceEndpoint(
        id: id, provider: "openai", name: "Fixture",
        baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "synthetic", models: ["gpt-5.4"]
      ), model: "gpt-realtime-2.1")
  }
  @MainActor @Test func sharedChatImportIsIdempotentAndPhoneEditsSurvive() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let provider = ProviderConfigurationRecord(
      displayName: "Fixture", provider: .openAI, modelIdentifier: "gpt-5.4")
    context.insert(provider)
    try context.save()
    let model = choice(provider.id)
    let chat = WatchChat(providerID: provider.id, model: model.model)
    let user = WatchMessage(role: "user", text: "Question", choice: model)
    let transfer = WatchTransfer(chat: chat, message: user)
    let phone = WatchPhoneLibrary(container: container)
    #expect(try phone.upload(transfer).acknowledged == transfer.id)
    #expect(try phone.upload(transfer).acknowledged == transfer.id)
    let read = ModelContext(container)
    #expect(try read.fetchCount(FetchDescriptor<MessageRecord>()) == 1)
    let saved = try #require(read.fetch(FetchDescriptor<ConversationRecord>()).first)
    #expect(!saved.modelIdentifier.contains("realtime"))
    saved.title = "Renamed on phone"
    saved.draftText = "Keep phone draft"
    saved.updatedAt = .now.addingTimeInterval(60)
    try read.save()
    let answer = WatchMessage(role: "assistant", text: "Answer", choice: model, replyTo: user.id)
    _ = try WatchPhoneLibrary(container: container).upload(
      WatchTransfer(chat: chat, message: answer))
    let current = try #require(
      ModelContext(container).fetch(FetchDescriptor<ConversationRecord>()).first)
    #expect(current.title == "Renamed on phone")
    #expect(current.draftText == "Keep phone draft")
    let page = try await WatchPhoneLibrary(container: container).detail(id: chat.id)
    #expect(page.chats.first?.messages.map(\.text) == ["Question", "Answer"])
    let portable = try MosaicPortableBackup.export(from: ModelContext(container))
    let plan = try MosaicPortableBackup.prepareRestore(from: portable)
    #expect(plan.snapshot.messages.count == 2)
  }
  @MainActor @Test func lostAcknowledgementCannotResurrectDeletedPhoneChatButUsageStillImports()
    throws
  {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let chat = WatchChat()
    let model = choice()
    let transfer = WatchTransfer(
      chat: chat, message: WatchMessage(role: "user", text: "Sent before deletion", choice: model))
    _ = try WatchPhoneLibrary(container: container).upload(transfer)
    let edit = ModelContext(container)
    for message in try edit.fetch(FetchDescriptor<MessageRecord>()) { edit.delete(message) }
    for row in try edit.fetch(FetchDescriptor<ConversationRecord>()) { edit.delete(row) }
    try edit.save()
    let reply = try WatchPhoneLibrary(container: container).upload(transfer)
    #expect(reply.status == "deleted")
    #expect(reply.acknowledged == transfer.id)
    #expect(try ModelContext(container).fetchCount(FetchDescriptor<ConversationRecord>()) == 0)
    var usage = VoiceUsageEntry(choice: model, category: "Watch live")
    usage.revision = 1
    usage.finished = true
    let cost = try WatchPhoneLibrary(container: container).upload(
      WatchTransfer(chat: chat, usage: usage))
    #expect(cost.status == "deleted")
    #expect(
      try ModelContext(container).fetchCount(
        FetchDescriptor<ExperienceRecord>(predicate: #Predicate { $0.category == "usage" })) == 1)
  }
  @MainActor @Test func usageRevisionsCountOnceAndPortableRestoreRemapsNestedProvider() async throws
  {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let provider = ProviderConfigurationRecord(
      displayName: "Fixture", provider: .openAI, modelIdentifier: "gpt-5.4")
    container.mainContext.insert(provider)
    try container.mainContext.save()
    let chat = WatchChat()
    let model = choice(provider.id)
    var usage = VoiceUsageEntry(
      choice: model, category: "Watch live", date: Date(timeIntervalSince1970: 1_788_652_800))
    let initial = WatchTransfer(chat: chat, usage: usage)
    let phone = WatchPhoneLibrary(container: container)
    _ = try phone.upload(initial)
    usage.revision = 2
    usage.finished = true
    usage.tokens = VoiceTokenUsage(
      input: 1000, output: 500, inputText: 200, inputAudio: 800, outputText: 100, outputAudio: 400,
      cachedText: 100, cachedAudio: 200)
    let final = WatchTransfer(chat: chat, usage: usage)
    _ = try phone.upload(final)
    _ = try phone.upload(initial)
    _ = try phone.upload(final)
    let lines = try await UsageReportReader(modelContainer: container).report(
      start: .distantPast, end: .distantFuture, pricingDate: usage.date)
    let line = try #require(lines.first)
    #expect(lines.count == 1)
    #expect(line.requests == 1)
    #expect(line.input == 1000)
    #expect(line.pendingRequests == 0)
    #expect(abs(try #require(line.automaticCost) - 0.04772) < 0.00000001)
    let plan = try MosaicPortableBackup.prepareRestore(
      from: MosaicPortableBackup.export(from: ModelContext(container)))
    let values = try plan.snapshot.extensionRecords.filter(ExperiencePortableArchive.isOwned).map(
      ExperiencePortableArchive.decode)
    let restored = try #require(values.first { $0.watchUsage != nil })
    #expect(restored.watchUsage?.providerID == plan.providerIDMap[provider.id])
    #expect(restored.providerID == restored.watchUsage?.providerID)
    var changed = usage
    changed.model = "different"
    changed.revision = 3
    #expect(throws: (any Error).self) {
      try phone.upload(WatchTransfer(chat: chat, usage: changed))
    }
  }
  @MainActor @Test func archivedChatStaysArchivedWhileOfflineUsageAndMessagesAreRecorded() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let row = ConversationRecord(title: "Archived")
    row.isArchived = true
    container.mainContext.insert(row)
    try container.mainContext.save()
    let chat = WatchChat(id: row.id, knownToPhone: true)
    let reply = try WatchPhoneLibrary(container: container).upload(
      WatchTransfer(chat: chat, message: WatchMessage(role: "user", text: "Sent while offline")))
    #expect(reply.status == "ok")
    let read = ModelContext(container)
    #expect(try read.fetch(FetchDescriptor<ConversationRecord>()).first?.isArchived == true)
    #expect(try WatchPhoneLibrary(container: container).list(before: nil).chats.isEmpty)
  }
}

extension WatchIntegrationTests {
  @MainActor @Test func paginationDoesNotSkipMessagesOrChatsWithIdenticalDates() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let date = Date(timeIntervalSince1970: 100)
    let chat = ConversationRecord(title: "Many turns", createdAt: date, updatedAt: date)
    context.insert(chat)
    for index in 0..<45 {
      context.insert(
        MessageRecord(
          conversationID: chat.id, role: .user, content: "Message \(index)", createdAt: date,
          updatedAt: date))
    }
    for index in 0..<35 {
      let other = ConversationRecord(title: "Chat \(index)", createdAt: date, updatedAt: date)
      context.insert(other)
      context.insert(
        MessageRecord(conversationID: other.id, role: .user, content: "Hello", createdAt: date))
    }
    try context.save()
    let phone = WatchPhoneLibrary(container: container)
    var messages = Set<UUID>()
    var before: Date?
    var beforeID: UUID?
    for _ in 0..<4 {
      let page = try await phone.detail(id: chat.id, before: before, beforeID: beforeID)
      messages.formUnion(page.chats.flatMap(\.messages).map(\.id))
      before = page.nextPage
      beforeID = page.nextPageID
      if before == nil { break }
    }
    #expect(messages.count == 45)
    let first = try phone.list(before: nil)
    let second = try phone.list(before: first.nextPage, beforeID: first.nextPageID)
    #expect(Set((first.chats + second.chats).map(\.id)).count == 36)
  }
}

extension WatchIntegrationTests {
  @MainActor @Test func watchUsageCommitPublishesRevisionForOpenReportAndSidebar() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let coordinator = MosaicOperationCoordinator()
    #expect(coordinator.beginVerifiedSourceSnapshotMaintenance())
    defer { coordinator.endExclusiveMaintenance() }
    let revision = coordinator.sourceActivityRevision
    let catalog = coordinator.conversationCatalogRevision
    let usage = VoiceUsageEntry(choice: choice(UUID()), category: "Watch live")
    let transfer = WatchTransfer(chat: WatchChat(), usage: usage)
    let reply = try WatchPhoneLibrary(container: container).upload(
      transfer, commit: coordinator.flushSourceChangesForVerifiedSnapshot)
    #expect(reply.acknowledged == transfer.id)
    #expect(coordinator.sourceActivityRevision > revision)
    #expect(coordinator.conversationCatalogRevision > catalog)
  }
}

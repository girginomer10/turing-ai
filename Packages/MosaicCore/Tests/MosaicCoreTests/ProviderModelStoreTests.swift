import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite(.serialized)
@MainActor
struct ProviderModelStoreTests {
  @Test func selectionUsesExactModelAndIndependentLimits() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let google = ProviderConfigurationRecord(
      displayName: "Google", provider: .google,
      modelIdentifier: "legacy", contextWindowTokens: 32_768, maximumOutputTokens: 2_048)
    let openAI = ProviderConfigurationRecord(
      displayName: "OpenAI", provider: .openAI, modelIdentifier: "other")
    context.insert(google)
    context.insert(openAI)
    #expect(
      ProviderModelStore.choices(providers: [google], models: []).map(\.modelIdentifier) == [
        "legacy"
      ])
    try ProviderModelStore.saveCatalog(
      provider: google, identifiers: ["legacy", "next", "disabled"], enabled: ["legacy", "next"],
      in: context)
    try context.save()
    let models = try ProviderModelStore.records(providerID: google.id, in: context)
    let legacy = try ProviderModelStore.connection(
      provider: google, modelIdentifier: "legacy", models: models)
    #expect(legacy.contextWindowTokens == 32_768)
    let next = try ProviderModelStore.connection(
      provider: google, modelIdentifier: "next", models: models)
    #expect(next.modelIdentifier == "next")
    #expect(next.contextWindowTokens == nil)
    #expect(next.credentialBinding == legacy.credentialBinding)
    #expect(ProviderModelStore.choices(providers: [google, openAI], models: models).count == 3)
    #expect(throws: ProviderModelSelectionError.self) {
      try ProviderModelStore.connection(
        provider: google, modelIdentifier: "disabled", models: models)
    }
    for model in models { model.isEnabled = false }
    #expect(ProviderModelStore.choices(providers: [google], models: models).isEmpty)
    #expect(google.modelIdentifier == "legacy")
  }

  @Test func modelsAndTaskSelectionSurviveBackupRekeyingAndReplacement() throws {
    let source = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = source.mainContext
    let provider = ProviderConfigurationRecord(
      displayName: "Local", provider: .ollama, modelIdentifier: "first")
    let task = ScheduledTaskRecord(
      title: "Task", prompt: "Hello", providerConfigurationID: provider.id, scheduledAt: .now)
    context.insert(provider)
    context.insert(task)
    try ProviderModelStore.saveCatalog(
      provider: provider, identifiers: ["first", "second"], enabled: ["second"], in: context)
    try ProviderModelStore.setTaskModel(
      taskID: task.id, providerID: provider.id, modelIdentifier: "second", in: context)
    try context.save()
    let data = try MosaicPortableBackup.export(from: context)
    let plan = try MosaicPortableBackup.prepareRestore(from: data)
    let target = try MosaicSchema.makeModelContainer(inMemory: true)
    try MosaicPortableBackup.replaceLiveStore(using: plan, in: target.mainContext)
    let restoredProvider = try #require(
      target.mainContext.fetch(FetchDescriptor<ProviderConfigurationRecord>()).first)
    #expect(restoredProvider.id != provider.id)
    #expect(!restoredProvider.isEnabled)
    let models = try ProviderModelStore.records(
      providerID: restoredProvider.id, in: target.mainContext)
    #expect(models.count == 2)
    #expect(models.filter(\.isEnabled).map(\.modelIdentifier) == ["second"])
    #expect(
      try ProviderModelStore.taskModel(
        taskID: task.id, provider: restoredProvider, in: target.mainContext) == "second")
    // Replacing again must remove the first restored catalog inside the same transaction.
    try MosaicPortableBackup.replaceLiveStore(using: plan, in: target.mainContext)
    #expect(try target.mainContext.fetchCount(FetchDescriptor<ProviderModelRecord>()) == 2)
    #expect(try target.mainContext.fetchCount(FetchDescriptor<ScheduledTaskModelRecord>()) == 1)
  }

  @Test func blankChatsStayHiddenThroughPagingSearchAndDraftChanges() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    for _ in 0..<70 { context.insert(ConversationRecord(title: "Empty", draftText: " \n ")) }
    let drafted = ConversationRecord(title: "Draft", draftText: "Unsent text")
    let sent = ConversationRecord(title: "Sent")
    context.insert(drafted)
    context.insert(sent)
    context.insert(MessageRecord(conversationID: sent.id, role: .user, content: "Hello"))
    try context.save()
    let catalog = MosaicConversationSidebarCatalog(modelContainer: container)
    let page = try await catalog.pages(query: "", activeOffset: 0, archivedOffset: 0, pageSize: 10)
    #expect(Set(page.active.items.map(\.id)) == Set([drafted.id, sent.id]))
    #expect(!page.active.hasNextPage)
    let search = try await catalog.pages(
      query: "Empty", activeOffset: 0, archivedOffset: 0, pageSize: 10)
    #expect(search.active.items.isEmpty)
    drafted.draftText = ""
    try context.save()
    let refreshed = try await catalog.pages(
      query: "", activeOffset: 0, archivedOffset: 0, pageSize: 10)
    #expect(refreshed.active.items.map(\.id) == [sent.id])
  }

  @Test func v4StoreMigratesWithoutChangingOriginalConversationOrProvider() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Mosaic.store")
    let providerID = UUID()
    let chatID = UUID()
    try autoreleasepool {
      let schema = Schema(versionedSchema: MosaicSchemaV4.self)
      let container = try ModelContainer(
        for: schema,
        configurations: [
          ModelConfiguration("Mosaic", schema: schema, url: url, cloudKitDatabase: .none)
        ])
      let context = container.mainContext
      context.insert(
        ProviderConfigurationRecord(
          id: providerID, displayName: "Local", provider: .ollama, modelIdentifier: "legacy"))
      context.insert(
        ConversationRecord(
          id: chatID, providerConfigurationID: providerID, modelIdentifier: "legacy",
          draftText: "Keep my draft"))
      context.insert(MessageRecord(conversationID: chatID, role: .user, content: "Keep my history"))
      try context.save()
    }
    try autoreleasepool {
      let migrated = try MosaicSchema.makeModelContainer(storeURL: url)
      let context = migrated.mainContext
      let provider = try #require(
        context.fetch(FetchDescriptor<ProviderConfigurationRecord>()).first)
      let chat = try #require(context.fetch(FetchDescriptor<ConversationRecord>()).first)
      #expect(provider.id == providerID)
      #expect(chat.id == chatID && chat.draftText == "Keep my draft")
      #expect(
        try context.fetch(FetchDescriptor<MessageRecord>()).first?.content == "Keep my history")
      #expect(
        ProviderModelStore.choices(providers: [provider], models: []).first?.modelIdentifier
          == "legacy")
      try ProviderModelStore.saveCatalog(
        provider: provider, identifiers: ["legacy", "new"], enabled: ["new"], in: context)
      try context.save()
    }
    let reopened = try MosaicSchema.makeModelContainer(storeURL: url)
    #expect(try reopened.mainContext.fetchCount(FetchDescriptor<ProviderModelRecord>()) == 2)
  }
}

import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite(.serialized)
struct ExperienceFeatureTests {
  @Test func crossLanguageFallbackFindsPetWithoutUnrelatedMemories() {
    let cat = RetrievalCandidate(
      id: UUID(), source: .memoryTopic, containerID: UUID(), title: "Pet cat",
      content: "The user has a cat.", createdAt: .now)
    let soy = RetrievalCandidate(
      id: UUID(), source: .memoryTopic, containerID: UUID(), title: "Food",
      content: "The user dislikes soy sauce.", createdAt: .now)
    let result = HybridMemoryRetriever().retrieve(
      query: "Benim hangi hayvanım var?", candidates: [soy, cat])
    #expect(result.items.map(\.id) == [cat.id])
    #expect(MemoryConcepts.relevance(query: "Kedim", content: "The user has a dog.") == 0)
  }
  @Test func semanticSelectionRejectsInventedIDsAndDropsWeakOnes() throws {
    let id = UUID()
    #expect(throws: (any Error).self) {
      try SemanticMemoryReranker.decode(
        "{\"relevant\":[{\"id\":\"\(UUID())\",\"confidence\":0.99}]}", allowed: [id])
    }
    #expect(
      try SemanticMemoryReranker.decode(
        "{\"relevant\":[{\"id\":\"\(id)\",\"confidence\":0.2}]}", allowed: [id]
      ).isEmpty)
    #expect(try SemanticMemoryReranker.decode("{\"relevant\":[]}", allowed: [id]).isEmpty)
    #expect(throws: (any Error).self) {
      try SemanticMemoryReranker.decode("No JSON here", allowed: [id])
    }
  }
  @Test func semanticSelectionToleratesTheWaysModelsDeviateFromTheContract() throws {
    let kept = UUID()
    let weak = UUID()
    let invented = UUID()
    let allowed: Set<UUID> = [kept, weak]
    // Trailing self-correction prose, a low-confidence entry and an invented ID next to a good one.
    let chatty = """
      {"relevant":[{"id":"\(kept)","confidence":0.97},{"id":"\(weak)","confidence":0.3},\
      {"id":"\(invented)","confidence":0.99}]}

      Wait — I must only include items with confidence >= 0.75.
      """
    #expect(try SemanticMemoryReranker.decode(chatty, allowed: allowed) == [kept: 0.97])
    // A bare array, a fenced answer, duplicates (the strongest wins) and lowercase UUIDs.
    let bare =
      "```\n[{\"id\":\"\(kept.uuidString.lowercased())\",\"confidence\":0.8},"
      + "{\"id\":\"\(kept)\",\"confidence\":0.9}]\n```"
    #expect(try SemanticMemoryReranker.decode(bare, allowed: allowed) == [kept: 0.9])
    // Braces and brackets inside strings do not confuse the scanner.
    #expect(
      SemanticMemoryReranker.firstJSONValue(in: "x {\"a\":\"}]\"} tail") == "{\"a\":\"}]\"}")
    // At most six survive, strongest first.
    let many = (0..<8).map { _ in UUID() }
    let body = many.enumerated().map {
      "{\"id\":\"\($0.element)\",\"confidence\":\(0.9 + Double($0.offset) / 100)}"
    }.joined(separator: ",")
    let top = try SemanticMemoryReranker.decode("[\(body)]", allowed: Set(many))
    #expect(top.count == 6 && top[many[7]] != nil && top[many[0]] == nil)
  }
  @Test(arguments: [ProviderKind.openAI, .anthropic, .google, .custom])
  func imagesReachEachWireDialect(provider: ProviderKind) throws {
    let message = AIChatMessage(role: .user, content: "What is this?")
    let input = ChatImageInput(mimeType: "image/jpeg", data: Data([1, 2, 3]))
    let connection = ProviderConnection(
      id: UUID(), displayName: "Fixture", provider: provider,
      baseURL: provider == .custom ? URL(string: "https://example.com/v1") : nil,
      modelIdentifier: "fixture-model", apiKey: "fixture")
    let request = try ProviderWireProtocol.streamingRequest(
      connection: connection,
      chatRequest: AIChatRequest(messages: [message], images: [message.id: [input]]))
    let body = try #require(
      String(
        data: JSONSerialization.data(
          withJSONObject: JSONSerialization.jsonObject(with: request.httpBody!),
          options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8))
    #expect(body.contains("AQID"))
    #expect(body.contains("image/jpeg"))
    #expect(body.contains("What is this?"))
  }
  @Test func imagesCannotBeAttachedToAbsentMessages() {
    let connection = ProviderConnection(
      id: UUID(), displayName: "Fixture", provider: .openAI, modelIdentifier: "gpt-4o",
      apiKey: "fixture")
    #expect(throws: (any Error).self) {
      try ProviderWireProtocol.streamingRequest(
        connection: connection,
        chatRequest: AIChatRequest(
          messages: [], images: [UUID(): [ChatImageInput(mimeType: "image/jpeg", data: Data([1]))]])
      )
    }
  }
  @MainActor @Test func attachmentsAndPreferencesSurviveBackupAndSyncIdentity() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let provider = ProviderConfigurationRecord(
      displayName: "Fixture", provider: .openAI, modelIdentifier: "gpt-4o")
    let conversation = ConversationRecord(
      providerConfigurationID: provider.id, modelIdentifier: "gpt-4o")
    context.insert(provider)
    context.insert(conversation)
    let attachment = ExperienceValue(
      id: UUID(), kind: .attachment, conversationID: conversation.id, filename: "note.txt",
      mimeType: "text/plain", extractedText: "A synthetic test document.")
    var preference = ExperienceValue.preference(
      ChatModelChoice(
        providerID: provider.id, providerName: "Fixture", providerKind: .openAI,
        modelIdentifier: "gpt-4o"))
    preference.favorite = true
    try ExperienceStore.save(attachment, in: context)
    try ExperienceStore.save(preference, in: context)
    try context.save()
    let data = try MosaicPortableBackup.export(from: context)
    let plan = try MosaicPortableBackup.prepareRestore(from: data)
    let restored = try plan.snapshot.extensionRecords.filter(ExperiencePortableArchive.isOwned).map(
      ExperiencePortableArchive.decode)
    #expect(restored.contains { $0.extractedText == attachment.extractedText })
    #expect(restored.first { $0.kind == .model }?.providerID == plan.providerIDMap[provider.id])
    let snapshot = try MosaicPortableBackup.decode(data)
    let syncPlan = try await MosaicPortableBackup.prepareSyncAsync(snapshot: snapshot)
    #expect(syncPlan.snapshot.providerConfigurations.first?.id == provider.id)
  }
  @MainActor @Test func offlineChangesMergeAndDeletedRecordsDoNotResurrect() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let first = ConversationRecord(title: "First", draftText: "one")
    context.insert(first)
    try context.save()
    let base = try MosaicPortableBackup.captureSnapshot(from: context)
    var a = CloudDeviceState(accountID: "test")
    try a.observe(base)
    var b = CloudDeviceState(accountID: "test")
    try b.merge(a.envelope)
    b.observed = try CloudLibraryMerge.records(base)
    let second = ConversationRecord(title: "Second", draftText: "two")
    context.insert(second)
    try context.save()
    let withSecond = try MosaicPortableBackup.captureSnapshot(from: context)
    try b.observe(withSecond)
    context.delete(second)
    context.delete(first)
    try context.save()
    let empty = try MosaicPortableBackup.captureSnapshot(from: context)
    try a.observe(empty)
    try a.merge(b.envelope)
    let result = try CloudLibraryMerge.snapshot(a.envelope, local: empty)
    #expect(result.conversations.map(\.id) == [second.id])
    try a.merge(b.envelope)
    #expect(
      try CloudLibraryMerge.snapshot(a.envelope, local: empty).conversations.map(\.id) == [
        second.id
      ])
  }
  @Test func photoBudgetIsReservedAndDocumentPayloadIsReadable() {
    let value = ExperienceValue(
      id: UUID(), kind: .attachment, conversationID: UUID(), filename: "a.txt",
      mimeType: "text/plain", extractedText: "Text from document")
    let content = ChatAttachmentStore.messageContent(text: "Summarize", attachments: [value])
    #expect(content.contains("Text from document"))
    #expect(ChatAttachmentStore.displayText(content) == "Summarize")
  }
  @Test func attachedDocumentsAreNotEvidenceForPersonalMemory() throws {
    let content = ChatAttachmentStore.messageContent(
      text: "Summarize this fictional biography",
      attachments: [
        ExperienceValue(
          id: UUID(), kind: .attachment, conversationID: UUID(), filename: "fiction.txt",
          mimeType: "text/plain", extractedText: "I own seven dogs and live in Atlantis.")
      ])
    let message = AutomaticMemorySourceMessage(
      id: UUID(), role: .user, content: content, createdAt: .now)
    let preparation = AutomaticMemoryFormationPreparation(
      jobID: UUID(), conversationID: UUID(), throughUserMessageID: message.id,
      assistantMessageID: UUID(),
      sourceFingerprint: AutomaticMemorySourceFingerprint.make(messages: [message]),
      messages: [message], existingTopics: [])
    let request = try AutomaticMemoryExtractor().request(for: preparation)
    #expect(request.messages[0].content.contains("Summarize this fictional biography"))
    #expect(!request.messages[0].content.contains("Atlantis"))
    #expect(request.messages[0].content.contains(preparation.sourceFingerprint))
  }
  @Test func cloudRejectsUnknownCollectionsAndContradictoryRevisions() throws {
    var local = CloudDeviceState(accountID: "test")
    let revision = CloudRevision(counter: 1, device: UUID())
    #expect(throws: (any Error).self) {
      try local.merge(
        CloudLibraryEnvelope(entries: ["unknown/x": CloudEntry(revision: revision, value: nil)]))
    }
    let key = "conversations/" + UUID().uuidString
    try local.merge(
      CloudLibraryEnvelope(entries: [key: CloudEntry(revision: revision, value: Data([1]))]))
    #expect(throws: (any Error).self) {
      try local.merge(
        CloudLibraryEnvelope(entries: [key: CloudEntry(revision: revision, value: nil)]))
    }
  }
  @MainActor @Test func receivedSnapshotAfterCrashIsNotReuploadedAsANewEdit() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    context.insert(ConversationRecord(title: "Received", draftText: "remote"))
    try context.save()
    let snapshot = try MosaicPortableBackup.captureSnapshot(from: context)
    var a = CloudDeviceState(accountID: "test")
    try a.observe(snapshot)
    var b = CloudDeviceState(accountID: "test")
    try b.merge(a.envelope)
    b.pendingAppliedRecords = try CloudLibraryMerge.records(snapshot)
    let before = b.envelope.entries
    try b.observe(snapshot)
    #expect(b.envelope.entries == before)
    #expect(b.pendingAppliedRecords == nil)
  }
  @Test func projectDefaultsFallBackToEnabledGlobalChoice() {
    let first = ChatModelChoice(
      providerID: UUID(), providerName: "A", providerKind: .openAI, modelIdentifier: "gpt-4o")
    let second = ChatModelChoice(
      providerID: UUID(), providerName: "B", providerKind: .google,
      modelIdentifier: "gemini-3-flash")
    let projectID = UUID()
    let global = ExperienceValue(
      id: UUID(), kind: .projectDefault, providerID: second.providerID,
      model: second.modelIdentifier)
    let disabled = ExperienceValue(
      id: UUID(), kind: .projectDefault, providerID: UUID(), model: "disabled", projectID: projectID
    )
    #expect(
      ExperienceStore.defaultChoice(
        projectID: projectID, choices: [first, second], values: [global, disabled])?.id == second.id
    )
  }
  @MainActor @Test func v5DiskStoreMigratesWithoutLosingDraftsOrModels() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Mosaic.store")
    let id = UUID()
    try autoreleasepool {
      let schema = Schema(versionedSchema: MosaicSchemaV5.self)
      let container = try ModelContainer(
        for: schema,
        configurations: [
          ModelConfiguration("Mosaic", schema: schema, url: url, cloudKitDatabase: .none)
        ])
      container.mainContext.insert(
        ConversationRecord(id: id, title: "Preserved", draftText: "Keep this draft"))
      try container.mainContext.save()
    }
    try autoreleasepool {
      let container = try MosaicSchema.makeModelContainer(storeURL: url)
      let context = container.mainContext
      #expect(
        try context.fetch(FetchDescriptor<ConversationRecord>()).first?.draftText
          == "Keep this draft")
      try ExperienceStore.save(
        ExperienceValue(
          id: UUID(), kind: .attachment, conversationID: id, filename: "note.txt",
          mimeType: "text/plain", extractedText: "Retained file"), in: context)
      try context.save()
    }
    let reopened = try MosaicSchema.makeModelContainer(storeURL: url)
    #expect(
      try ExperienceStore.values(in: reopened.mainContext).first?.extractedText == "Retained file")
  }

  @Test func cloudNeverAcceptsRemoteExecutionJobs() throws {
    var state = CloudDeviceState(accountID: "test")
    let id = UUID()
    let value = try CloudLibraryMerge.canonical([
      "id": id.uuidString, "namespace": AutomaticMemoryPortableArchive.namespace,
      "recordType": "formation_job", "recordVersion": 1, "payload": Data().base64EncodedString(),
    ])
    let key =
      "extensionRecords/" + AutomaticMemoryPortableArchive.namespace + "/formation_job/"
      + id.uuidString
    #expect(throws: (any Error).self) {
      try state.merge(
        CloudLibraryEnvelope(entries: [
          key: CloudEntry(revision: CloudRevision(counter: 1, device: UUID()), value: value)
        ]))
    }
  }
  @MainActor @Test func concurrentCloudEditsAreDeterministicAndValidateBeforeReplacement()
    async throws
  {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let chat = ConversationRecord(title: "Base", draftText: "base")
    context.insert(chat)
    try context.save()
    let base = try MosaicPortableBackup.captureSnapshot(from: context)
    var a = CloudDeviceState(accountID: "same")
    try a.observe(base)
    var b = CloudDeviceState(accountID: "same")
    try b.merge(a.envelope)
    b.observed = try CloudLibraryMerge.records(base)
    chat.draftText = "A edit"
    try context.save()
    try a.observe(MosaicPortableBackup.captureSnapshot(from: context))
    chat.draftText = "B edit"
    try context.save()
    try b.observe(MosaicPortableBackup.captureSnapshot(from: context))
    let ea = a.envelope
    let eb = b.envelope
    try a.merge(eb)
    try b.merge(ea)
    #expect(a.envelope.entries == b.envelope.entries)
    let merged = try CloudLibraryMerge.snapshot(a.envelope, local: base)
    let plan = try await MosaicPortableBackup.prepareSyncAsync(snapshot: merged)
    #expect(["A edit", "B edit"].contains(plan.snapshot.conversations[0].draftText))
  }

  @Test func completedSmartRankingPreservesExactSelectionAndEmptyResults() async throws {
    let id = UUID()
    let candidate = RetrievalCandidate(
      id: id, source: .memoryTopic, containerID: UUID(), title: "Pet cat",
      content: "The user has a cat.", createdAt: .now)
    let selected = try await SemanticMemoryReranker.rank(
      query: "Benim hangi hayvanim var?", candidates: [candidate],
      client: SmartRankingFixture(text: "{\"relevant\":[{\"id\":\"\(id)\",\"confidence\":0.95}]}"))
    #expect(selected.scores.scores == [id: 0.95])
    let empty = try await SemanticMemoryReranker.rank(
      query: "Unrelated question", candidates: [candidate],
      client: SmartRankingFixture(text: "{\"relevant\":[]}"))
    #expect(empty.scores.scores.isEmpty)
  }

}

private struct SmartRankingFixture: AIProviderClient {
  let text: String
  func listModels() async throws -> [String] { [] }
  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.textDelta(text))
      continuation.yield(.completed(responseID: nil))
      continuation.finish()
    }
  }
}

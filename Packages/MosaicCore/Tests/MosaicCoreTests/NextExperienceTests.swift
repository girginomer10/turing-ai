import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite(.serialized)
struct NextExperienceTests {
  @MainActor @Test func branchPreservesOriginalAndMovesOnlyPrefixAndAnchorAttachments() async throws
  {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let chat = ConversationRecord(title: "Original", draftText: "Original draft")
    context.insert(chat)
    let first = MessageRecord(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      conversationID: chat.id, role: .user, content: "First",
      createdAt: Date(timeIntervalSince1970: 1))
    let answer = MessageRecord(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      conversationID: chat.id, role: .assistant, content: "First answer", inputTokenCount: 20,
      outputTokenCount: 5, createdAt: Date(timeIntervalSince1970: 1))
    let edited = MessageRecord(
      conversationID: chat.id, role: .user, content: "Old question",
      createdAt: Date(timeIntervalSince1970: 3))
    let later = MessageRecord(
      conversationID: chat.id, role: .assistant, content: "Later answer",
      createdAt: Date(timeIntervalSince1970: 4))
    for row in [first, answer, edited, later] { context.insert(row) }
    let project = ProjectRecord(name: "Test project")
    context.insert(project)
    context.insert(
      ProjectResourceBindingRecord(
        resourceKind: .conversation, resourceID: chat.id, projectID: project.id))
    try ExperienceStore.save(
      ExperienceValue(
        id: UUID(), kind: .attachment, conversationID: chat.id, messageID: edited.id,
        filename: "test.txt", mimeType: "text/plain", extractedText: "A document fact"), in: context
    )
    try context.save()
    let id = try await ConversationBranchStore(modelContainer: container).create(
      sourceID: chat.id, userMessageID: edited.id, draft: "Edited question")
    let read = ModelContext(container)
    let branch = try #require(
      read.fetch(FetchDescriptor<ConversationRecord>(predicate: #Predicate { $0.id == id })).first)
    #expect(branch.draftText == "Edited question")
    let messages = try read.fetch(
      FetchDescriptor<MessageRecord>(
        predicate: #Predicate { $0.conversationID == id }, sortBy: [SortDescriptor(\.createdAt)]))
    #expect(messages.map(\.content) == ["First", "First answer"])
    #expect(messages.allSatisfy { $0.inputTokenCount == nil && $0.contextReceiptData == nil })
    #expect(chat.draftText == "Original draft")
    #expect(edited.content == "Old question")
    let attachment = try read.fetch(
      FetchDescriptor<ExperienceRecord>(
        predicate: #Predicate { $0.ownerID == id && $0.category == "attachment" }))
    #expect(attachment.count == 1 && attachment[0].messageID == nil)
    #expect(
      try read.fetch(
        FetchDescriptor<ProjectResourceBindingRecord>(predicate: #Predicate { $0.resourceID == id })
      ).first?.projectID == project.id)
    let snapshot = try MosaicPortableBackup.captureSnapshot(from: ModelContext(container))
    _ = try await MosaicPortableBackup.prepareSyncAsync(snapshot: snapshot)
  }
  @MainActor @Test func missingBranchAnchorDoesNotCreatePartialChat() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let chat = ConversationRecord()
    context.insert(chat)
    try context.save()
    await #expect(throws: (any Error).self) {
      try await ConversationBranchStore(modelContainer: container).create(
        sourceID: chat.id, userMessageID: UUID(), draft: "Edit")
    }
    #expect(try ModelContext(container).fetchCount(FetchDescriptor<ConversationRecord>()) == 1)
  }
  @Test func manifestsTransferOnlyChangedContentAndRejectCorruption() throws {
    let device = UUID()
    let revision = CloudRevision(counter: 1, device: device)
    let a = Data("first".utf8)
    let b = Data("second".utf8)
    var envelope = CloudLibraryEnvelope(entries: [
      "messages/a": CloudEntry(revision: revision, value: a),
      "messages/b": CloudEntry(revision: revision, value: b),
      "messages/deleted": CloudEntry(revision: revision, value: nil),
    ])
    let original = try CloudLibraryManifest(envelope)
    #expect(
      try original.envelope(values: [
        CloudLibraryManifest.hash(a): a, CloudLibraryManifest.hash(b): b,
      ]).entries == envelope.entries)
    envelope.entries["messages/a"] = CloudEntry(
      revision: .init(counter: 2, device: device), value: Data("changed".utf8))
    let next = try CloudLibraryManifest(envelope)
    let hashes = Set(original.items.values.compactMap(\.hash))
    #expect(next.items.values.compactMap(\.hash).filter { !hashes.contains($0) }.count == 1)
    #expect(throws: (any Error).self) {
      try original.envelope(values: [CloudLibraryManifest.hash(a): b])
    }
    let data = try JSONEncoder().encode(original)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(CloudLibraryEnvelope.self, from: data)
    }
  }
  @Test func conflictsRequireBothSidesToChangeAndResolutionsBeatRemoteRevision() throws {
    var state = CloudDeviceState(accountID: "synthetic")
    let key = "messages/test"
    let baseline = CloudRevision(counter: 1, device: state.deviceID)
    state.acknowledged = [key: baseline]
    let local = CloudEntry(
      revision: .init(counter: 2, device: state.deviceID), value: Data("local".utf8))
    let remote = CloudEntry(revision: .init(counter: 3, device: UUID()), value: Data("remote".utf8))
    state.envelope.entries[key] = local
    let cloud = CloudLibraryEnvelope(entries: [key: remote])
    #expect(state.conflicts(with: cloud).count == 1)
    state.resolutions = [key: .init(local: local, remote: remote, useLocal: true)]
    #expect(state.conflicts(with: cloud).isEmpty)
    try state.applyResolutions(for: cloud)
    try state.merge(cloud)
    #expect(state.envelope.entries[key]?.value == local.value)
    #expect(state.envelope.entries[key]!.revision > remote.revision)
    state.envelope.entries[key] = CloudEntry(revision: baseline, value: Data("old".utf8))
    #expect(state.conflicts(with: cloud).isEmpty)
  }
  @Test func staleConflictChoiceRequiresReviewAgain() {
    var state = CloudDeviceState(accountID: "test")
    let local = CloudEntry(revision: .init(counter: 1, device: state.deviceID), value: Data([1]))
    let remote = CloudEntry(revision: .init(counter: 2, device: UUID()), value: Data([2]))
    state.envelope.entries["messages/test"] = local
    state.resolutions = ["messages/test": .init(local: local, remote: remote, useLocal: true)]
    var newer = remote
    newer.revision.counter = 3
    newer.value = Data([3])
    #expect(
      state.conflicts(with: CloudLibraryEnvelope(entries: ["messages/test": newer])).count == 1)
  }
  @Test func nativeWebSearchIsExplicitAndCannotLeakToolsToGateways() throws {
    let provider = ProviderConnection(
      id: UUID(), displayName: "OpenAI", provider: .openAI, modelIdentifier: "gpt-5.4",
      apiKey: "fixture")
    let input = AIChatRequest(
      messages: [AIChatMessage(role: .user, content: "Today's weather")], webSearch: true)
    let request = try ProviderWireProtocol.streamingRequest(
      connection: provider, chatRequest: input)
    let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    #expect(body["store"] as? Bool == false)
    #expect(body["tool_choice"] as? String == "required")
    #expect((body["tools"] as? [[String: String]])?.first?["type"] == "web_search")
    let gateway = ProviderConnection(
      id: UUID(), displayName: "Gateway", provider: .openAI,
      baseURL: URL(string: "https://example.com/v1"), modelIdentifier: "gpt-5.4", apiKey: "fixture")
    #expect(throws: (any Error).self) {
      try ProviderWireProtocol.streamingRequest(connection: gateway, chatRequest: input)
    }
  }
  @Test func citationsAreClickableAndUnsafeURLsAreRejected() throws {
    #expect(WebSearchCapability.source(["url": "file:///etc/passwd"]) == nil)
    #expect(WebSearchCapability.source(["url": "https://user:password@example.com"]) == nil)
    let source = try #require(
      WebSearchCapability.source([
        "url": "https://example.com/page", "title": "Source", "start_index": 0, "end_index": 5,
      ]))
    #expect(
      WebSearchCapability.annotated("Hello world", sources: [source]).contains(
        "Hello [1](<https://example.com/page>) world"))
    let events = try ProviderWireProtocol.decode(
      event: ServerSentEvent(
        name: nil,
        data:
          "{\"type\":\"response.output_text.annotation.added\",\"annotation\":{\"type\":\"url_citation\",\"url\":\"https://example.com\",\"title\":\"Source\"}}",
        id: nil), dialect: .openAIResponses)
    #expect(events.count == 1)
    if case .citations(let sources) = events[0] {
      #expect(sources[0].url == "https://example.com")
    } else {
      Issue.record("Missing sources")
    }
  }
  @Test func usageNeverPricesUnknownRatesAsFree() {
    var line = UsageLine(providerID: UUID(), providerName: "Test", model: "Test", category: "Chat")
    line.input = 1_000_000
    line.output = 500_000
    #expect(line.cost(inputRate: nil, outputRate: 10) == nil)
    #expect(line.cost(inputRate: 2, outputRate: 10) == 7)
    #expect(line.cost(inputRate: .infinity, outputRate: 10) == nil)
  }
  @Test func sharedInboxRejectsPathTraversalAndIgnoresPartialWrites() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pending = directory.appendingPathComponent("partial.pending")
    try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
    #expect(try SharedInbox.items(in: directory).isEmpty)
    let id = UUID()
    let itemDirectory = directory.appendingPathComponent(id.uuidString)
    try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
    let item = SharedInboxItem(
      id: id, createdAt: .now, prompt: "Question",
      files: [.init(storedName: "../private.txt", displayName: "File")])
    try JSONEncoder().encode(item).write(to: itemDirectory.appendingPathComponent("item.json"))
    #expect(throws: (any Error).self) { try SharedInbox.items(in: directory) }
  }
}

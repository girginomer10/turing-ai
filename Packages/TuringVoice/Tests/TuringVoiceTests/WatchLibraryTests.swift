import Foundation
import Testing

@testable import TuringVoice

private var fixtureChoice: WatchModel {
  WatchModel(
    endpoint: VoiceEndpoint(
      id: UUID(), provider: "openai", name: "Fixture",
      baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "synthetic", models: ["gpt-5.4"]),
    model: "gpt-realtime-2.1")
}
@MainActor @Test func watchOutboxSurvivesRelaunchAndAcknowledgementIsIdempotent() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: folder) }
  let url = folder.appendingPathComponent("watch.json")
  let library = try WatchLibrary(url: url)
  var chat = WatchChat()
  chat.model = "gpt-5.4"
  try library.saveDraft(chat)
  #expect(library.chats.isEmpty)
  chat.draft = "Unsent draft"
  try library.saveDraft(chat)
  let user = WatchMessage(role: "user", text: "A test question", choice: fixtureChoice)
  try library.record(user, chat: chat)
  try library.record(user, chat: chat)
  #expect(library.pending.count == 1)
  let reopened = try WatchLibrary(url: url)
  #expect(reopened.chats.first?.messages == [user])
  #expect(reopened.chats.first?.draft == "")
  let transfer = try #require(reopened.pending.first)
  let decoded = try WatchSyncWire.request(
    WatchSyncWire.encode(WatchSyncRequest(operation: "upload", transfer: transfer)))
  #expect(decoded.transfer == transfer)
  try reopened.acknowledge(transfer.id)
  try reopened.acknowledge(transfer.id)
  #expect(reopened.pending.isEmpty)
  #expect(try WatchLibrary(url: url).chats.first?.knownToPhone == true)
}
@MainActor @Test func failedLocalWriteDoesNotDiscardSavedMessagesOrOutbox() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: folder) }
  let library = try WatchLibrary(url: folder.appendingPathComponent("watch.json"))
  let chat = WatchChat()
  let user = WatchMessage(role: "user", text: "Keep me")
  try library.record(user, chat: chat)
  try FileManager.default.removeItem(at: folder)
  try Data([1]).write(to: folder)  // Parent is a file, preventing the atomic write.
  #expect(throws: (any Error).self) { try library.acknowledge(library.pending[0].id) }
  #expect(library.pending.count == 1)
  #expect(library.chats.first?.messages == [user])
}
@MainActor @Test func boundedHistoryMergeKeepsOldTurnsAndDraftAndDeletionStopsResurrection() throws
{
  let library = try WatchLibrary()
  var chat = WatchChat(draft: "Unsent")
  let user = WatchMessage(role: "user", text: "Old", date: Date(timeIntervalSince1970: 1))
  chat.messages = [user]
  try library.saveDraft(chat)
  var remote = WatchChat(id: chat.id, title: "Renamed on phone", knownToPhone: true)
  remote.messages = [
    WatchMessage(role: "assistant", text: "Latest", date: Date(timeIntervalSince1970: 2))
  ]
  try library.merge(remote)
  #expect(library.chats.first?.messages.count == 2)
  #expect(library.chats.first?.draft == "Unsent")
  try library.record(WatchMessage(role: "user", text: "Offline message"), chat: chat)
  try library.acknowledge(library.pending[0].id, deleted: true)
  #expect(library.chats.isEmpty)
  #expect(throws: (any Error).self) {
    try library.record(WatchMessage(role: "user", text: "No resurrection"), chat: chat)
  }
}
@Test func audioPricingUsesModalitiesCacheDurationAndRejectsMissingOrStaleRates() throws {
  var entry = VoiceUsageEntry(choice: fixtureChoice, category: "Watch live")
  let now = Date(timeIntervalSince1970: 1_788_652_800)  // Within this catalog's validity.
  entry.tokens = VoiceTokenUsage(
    input: 1000, output: 500, inputText: 200, inputAudio: 800, outputText: 100, outputAudio: 400,
    cachedText: 100, cachedAudio: 200)
  #expect(abs(try #require(VoiceAudioPrices.estimate(entry, now: now)) - 0.04772) < 0.00000001)
  entry.tokens.inputAudio = nil
  #expect(VoiceAudioPrices.estimate(entry, now: now) == nil)
  entry.model = "gpt-transcribe"
  entry.tokens = VoiceTokenUsage(seconds: 60)
  #expect(VoiceAudioPrices.estimate(entry, now: now) == 0.0045)
  entry.host = "proxy.example"
  #expect(VoiceAudioPrices.estimate(entry, now: now) == nil)
  entry.host = "api.openai.com"
  #expect(VoiceAudioPrices.estimate(entry, now: VoiceAudioPrices.validUntil) == nil)
}
@Test func speechSSECollectsAudioAndActualUsageWithoutGuessingMissingCounters() throws {
  let data = Data(
    "data: {\"type\":\"speech.audio.delta\",\"audio\":\"AQID\"}\n\ndata: {\"type\":\"speech.audio.done\",\"usage\":{\"input_tokens\":10,\"output_tokens\":20}}\n\n"
      .utf8)
  let result = try VoiceUsageWire.speechEvents(data)
  #expect(result.audio == Data([1, 2, 3]))
  #expect(result.usage.input == 10)
  #expect(result.usage.output == 20)
  #expect(
    VoiceUsageWire.parse(["input_tokens": true, "output_tokens": 2.5], provider: "openai").input
      == nil)
  #expect(
    VoiceUsageWire.parse(["input_tokens": true, "output_tokens": 2.5], provider: "openai").output
      == nil)
  #expect(throws: (any Error).self) {
    try VoiceUsageWire.speechEvents(Data("data: {\"type\":\"speech.audio.done\"}".utf8))
  }
}
@MainActor @Test func usageAcknowledgementDoesNotClaimUnsyncedChatExistsOnPhone() throws {
  let library = try WatchLibrary()
  let chat = WatchChat()
  let usage = VoiceUsageEntry(choice: fixtureChoice, category: "Watch live")
  try library.record(usage, chat: chat)
  let transfer = try #require(library.pending.first)
  try library.record(WatchMessage(role: "user", text: "First question"), chat: chat)
  try library.acknowledge(transfer.id)
  #expect(library.chat(chat.id)?.knownToPhone == false)
  #expect(library.pending.count == 1)
}

@Test func backgroundUsageAcceptsOnlyUsageAndKeepsLatestRevisionPerRequest() throws {
  let chat = WatchChat()
  var usage = VoiceUsageEntry(choice: fixtureChoice, category: "Watch live")
  let first = WatchTransfer(chat: chat, usage: usage)
  usage.revision = 2
  usage.finished = true
  let latest = WatchTransfer(chat: chat, usage: usage)
  let message = WatchTransfer(
    chat: chat, message: WatchMessage(role: "user", text: "Private message"))
  let pending = [latest, message, first]
  #expect(WatchUsageDelivery.candidates(pending) == [latest])
  #expect(
    try WatchUsageDelivery.decode(
      WatchSyncWire.encode(WatchSyncRequest(operation: "upload", transfer: latest))) == latest)
  #expect(throws: (any Error).self) {
    try WatchUsageDelivery.decode(
      WatchSyncWire.encode(WatchSyncRequest(operation: "upload", transfer: message)))
  }
}

import Foundation
import Testing

@testable import TuringVoice

@MainActor private final class TestAudio: VoiceAudioDevice {
  var queuedMilliseconds = 0
  var playedMilliseconds = 0
  var nextPlaybackMilliseconds: Int { playedMilliseconds + queuedMilliseconds }
  var onPlaybackDrained: (@MainActor () -> Void)?
  var microphone: AsyncThrowingStream<Data, Error>.Continuation?
  var playing = false
  func live() async throws -> AsyncThrowingStream<Data, Error> {
    let pair = AsyncThrowingStream<Data, Error>.makeStream()
    microphone = pair.continuation
    return pair.stream
  }
  func playPCM(_ data: Data) {
    queuedMilliseconds += data.count / 48
    playing = true
  }
  func drain() {
    playedMilliseconds += queuedMilliseconds
    queuedMilliseconds = 0
    onPlaybackDrained?()
  }
  func clearPlayback() {
    queuedMilliseconds = 0
    playedMilliseconds = 0
    playing = false
  }
  func record() {}
  func finishRecording() -> Data { Data() }
  func playFile(_ data: Data, completion: @escaping () -> Void) {}
  func stop() {
    microphone?.finish()
    microphone = nil
    clearPlayback()
  }
}

private actor TestLive: LiveVoiceTransport {
  let pair = AsyncThrowingStream<LiveVoiceEvent, Error>.makeStream()
  var starts = 0
  var stops = 0
  var inputPackets = 0
  var truncations: [(String, Int)] = []
  func start() -> AsyncThrowingStream<LiveVoiceEvent, Error> {
    starts += 1
    pair.continuation.yield(.ready)
    return pair.stream
  }
  func sendAudio(_ data: Data) { inputPackets += 1 }
  func truncate(itemID: String, playedMilliseconds: Int) {
    truncations.append((itemID, playedMilliseconds))
  }
  func stop() {
    stops += 1
    pair.continuation.finish()
  }
  func emit(_ events: [LiveVoiceEvent]) { for event in events { pair.continuation.yield(event) } }
}

@MainActor private func eventually(_ predicate: @MainActor () async -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while !(await predicate()) {
    guard ContinuousClock.now < deadline else { throw VoiceError.timeout }
    try await Task.sleep(for: .milliseconds(5))
  }
}
private var liveChoice: WatchModel {
  WatchModel(
    endpoint: VoiceEndpoint(
      id: UUID(), provider: "openai", name: "Synthetic",
      baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "synthetic-only", models: []),
    model: "gpt-realtime-2.1")
}

@MainActor @Test func livePlaysCompleteAnswerAndAcceptsSecondTurnWithoutRestart() async throws {
  let audio = TestAudio()
  let transport = TestLive()
  let conversation = WatchConversation(audio: audio, makeLive: { _, _, _, _ in transport })
  conversation.startLive(liveChoice)
  defer { conversation.stop() }
  try await eventually { conversation.phase == .live }
  await transport.emit([
    .transcript(role: "user", text: "First question", append: false),
    .audio(Data(repeating: 0, count: 48_000), itemID: "first"),
    .transcript(role: "assistant", text: "First answer", append: true), .turnFinished,
  ])
  try await eventually { conversation.answer == "First answer" }
  #expect(conversation.phase == .live)
  #expect(audio.queuedMilliseconds == 1000)  // response.done must not clear scheduled sound.
  #expect(audio.playing)
  audio.drain()
  #expect(conversation.status == "Listening · speak naturally")
  audio.microphone?.yield(Data([0, 0]))
  await transport.emit([
    .interrupted,
    .transcript(role: "user", text: "Second question", append: false),
    .audio(Data(repeating: 0, count: 48_000), itemID: "second"),
    .transcript(role: "assistant", text: "Second answer", append: true), .turnFinished,
  ])
  try await eventually {
    let packets = await transport.inputPackets
    return conversation.answer == "Second answer" && packets == 1
  }
  #expect(conversation.heard == "Second question")
  #expect(conversation.phase == .live)
  #expect(await transport.starts == 1)
  #expect(await transport.stops == 0)
  #expect(await transport.truncations.isEmpty)  // Fully heard first answer is not truncated.
}

@MainActor @Test func wristDownAndEndInterruptionDoNotEndLiveButBackgroundAndBeganDo() async throws
{
  let audio = TestAudio()
  let transport = TestLive()
  let conversation = WatchConversation(audio: audio, makeLive: { _, _, _, _ in transport })
  conversation.startLive(liveChoice)
  try await eventually { conversation.phase == .live }
  conversation.sceneChanged(isBackground: false)
  conversation.audioInterrupted(began: false)
  #expect(conversation.phase == .live)
  #expect(audio.microphone != nil)
  conversation.audioInterrupted(began: true)
  #expect(conversation.phase == .idle)
  #expect(audio.microphone == nil)
  #expect(conversation.status.contains("Audio interrupted"))
  try await eventually { await transport.stops == 1 }

  let second = TestLive()
  let next = WatchConversation(audio: audio, makeLive: { _, _, _, _ in second })
  next.startLive(liveChoice)
  try await eventually { next.phase == .live }
  next.sceneChanged(isBackground: true)
  #expect(next.phase == .idle)
  #expect(audio.microphone == nil)
  try await eventually { await second.stops == 1 }
}

@MainActor @Test func interruptUnplayedAnswerKeepsLiveConnectionAndTruncatesOnlyHeardAudio()
  async throws
{
  let audio = TestAudio()
  let transport = TestLive()
  let conversation = WatchConversation(audio: audio, makeLive: { _, _, _, _ in transport })
  conversation.startLive(liveChoice)
  defer { conversation.stop() }
  try await eventually { conversation.phase == .live }
  await transport.emit([.audio(Data(repeating: 0, count: 96_000), itemID: "answer")])
  try await eventually { audio.queuedMilliseconds == 2000 }
  audio.playedMilliseconds = 750
  audio.queuedMilliseconds = 1250
  await transport.emit([.interrupted])
  try await eventually { await transport.truncations.count == 1 }
  #expect(await transport.truncations.first?.0 == "answer")
  #expect(await transport.truncations.first?.1 == 750)
  #expect(conversation.phase == .live)
  #expect(audio.queuedMilliseconds == 0)
  #expect(await transport.stops == 0)
}

@Test func playbackAcceptsThirtySecondBurstAndStillEnforcesMemoryBound() throws {
  var queue = VoicePlaybackQueue()
  for _ in 0..<60 { try queue.schedule(frames: 12_000, renderedFrames: 0) }
  #expect(queue.pendingFrames == 720_000)
  #expect(queue.tailFrame == 720_000)
  #expect(throws: VoiceError.self) {
    try queue.schedule(frames: VoicePlaybackQueue.maximumFrames, renderedFrames: 0)
  }
  #expect(queue.pendingFrames == 720_000)
  queue.completed(frames: 12_000)
  #expect(queue.pendingFrames == 708_000)
  queue.reset()
  #expect(queue.pendingFrames == 0)
  #expect(queue.tailFrame == 0)
}

@Test func playbackTailDoesNotDoubleCountPartiallyPlayedBuffersAndHandlesSilence() throws {
  var queue = VoicePlaybackQueue()
  try queue.schedule(frames: 24_000, renderedFrames: 0)
  try queue.schedule(frames: 24_000, renderedFrames: 12_000)
  #expect(queue.tailFrame == 48_000)  // not 60_000 (rendered + whole pending buffers).
  queue.completed(frames: 48_000)
  try queue.schedule(frames: 24_000, renderedFrames: 240_000)
  #expect(queue.tailFrame == 264_000)
}

@MainActor @Test func livePersistsTwoGeminiTurnsAndCommitsLatestUsageSnapshotOnce() async throws {
  let audio = TestAudio()
  let transport = TestLive()
  let library = try WatchLibrary()
  let conversation = WatchConversation(audio: audio, makeLive: { _, _, _, _ in transport })
  conversation.saveMessage = { try library.record($0, chat: $1) }
  conversation.saveUsage = { try library.record($0, chat: $1) }
  conversation.startLive(liveChoice)
  defer { conversation.stop() }
  try await eventually { conversation.phase == .live }
  for index in 1...2 {
    await transport.emit([
      .transcript(role: "user", text: "Question \(index)", append: true),
      .transcript(role: "assistant", text: "Answer \(index)", append: true),
      .usage(VoiceTokenUsage(input: 5, output: 2), id: nil, transcription: false),
      .usage(VoiceTokenUsage(input: 10, output: 4), id: nil, transcription: false), .turnFinished,
    ])
    try await eventually { conversation.chat.messages.count == index * 2 }
  }
  #expect(
    conversation.chat.messages.map(\.text) == ["Question 1", "Answer 1", "Question 2", "Answer 2"])
  conversation.stop()
  let usage = try #require(library.pending.compactMap(\.usage).last)
  #expect(usage.tokens.input == 20)
  #expect(usage.tokens.output == 8)
  #expect(usage.finished)
}
@MainActor @Test func lateUserTranscriptKeepsItsReplyPairAndDoesNotOverwriteNextTurn() async throws
{
  let audio = TestAudio()
  let transport = TestLive()
  let conversation = WatchConversation(audio: audio, makeLive: { _, _, _, _ in transport })
  conversation.startLive(liveChoice)
  defer { conversation.stop() }
  try await eventually { conversation.phase == .live }
  await transport.emit([
    .userTurnStarted(itemID: "u1"), .interrupted,
    .transcript(role: "assistant", text: "Answer 1", append: true, itemID: "a1"), .turnFinished,
    .userTurnStarted(itemID: "u2"), .interrupted,
    .transcript(role: "user", text: "Question 1", append: false, itemID: "u1"),
    .transcript(role: "user", text: "Question 2", append: false, itemID: "u2"),
    .transcript(role: "assistant", text: "Answer 2", append: true, itemID: "a2"), .turnFinished,
  ])
  try await eventually { conversation.chat.messages.count == 4 }
  let a1 = try #require(conversation.chat.messages.first { $0.text == "Answer 1" })
  let u1 = try #require(conversation.chat.messages.first { $0.text == "Question 1" })
  let a2 = try #require(conversation.chat.messages.first { $0.text == "Answer 2" })
  let u2 = try #require(conversation.chat.messages.first { $0.text == "Question 2" })
  #expect(a1.replyTo == u1.id)
  #expect(a2.replyTo == u2.id)
  #expect(conversation.heard == "Question 2")
}
@MainActor @Test func preparingPhoneContextPreservesNewWatchModelAndSeedsHistory() async throws {
  let transport = TestLive()
  let choice = liveChoice
  var chat = WatchChat(
    model: "old-model", messages: [WatchMessage(role: "user", text: "Remember this")],
    draft: "Keep draft")
  chat.providerID = UUID()
  let expected = chat.messages.map(\.turn)
  let conversation = WatchConversation(
    audio: TestAudio(), chat: chat,
    makeLive: { _, _, history, context in
      #expect(history == expected)
      #expect(context == "Saved context")
      return transport
    })
  let phone = chat
  conversation.prepareContext = { _, _ in (phone, WatchContext(instructions: "Saved context")) }
  conversation.startLive(choice)
  defer { conversation.stop() }
  try await eventually { conversation.phase == .live }
  #expect(conversation.chat.model == choice.model)
  #expect(conversation.chat.providerID == choice.endpoint.id)
  conversation.changeModel()
  #expect(conversation.chat.messages.count == 1)
  #expect(conversation.draft == "Keep draft")
}

@MainActor @Test func liveTranscriptionKeepsAttemptIdentityAndInterruptedUsageRemainsIncomplete()
  async throws
{
  let transport = TestLive()
  let conversation = WatchConversation(audio: TestAudio(), makeLive: { _, _, _, _ in transport })
  var records: [VoiceUsageEntry] = []
  conversation.saveUsage = { entry, _ in records.append(entry) }
  conversation.startLive(liveChoice)
  try await eventually { conversation.phase == .live }
  await transport.emit([
    .userTurnStarted(itemID: "u1"), .interrupted,
    .transcript(role: "user", text: "A question", append: false, itemID: "u1"),
    .usage(
      VoiceTokenUsage(input: 20, output: 4, inputText: 0, inputAudio: 20), id: "u1",
      transcription: true),
    .usage(
      VoiceTokenUsage(input: 20, output: 4, inputText: 0, inputAudio: 20), id: "u1",
      transcription: true),
    .transcript(role: "assistant", text: "Partial answer", append: true, itemID: "a1"),
  ])
  try await eventually { conversation.answer == "Partial answer" }
  conversation.stop()
  let transcriptions = records.filter { $0.category == "Watch live transcription" }
  #expect(transcriptions.count == 2)
  #expect(transcriptions.first?.id == transcriptions.last?.id)
  #expect(transcriptions.first?.date == transcriptions.last?.date)
  #expect(transcriptions.first?.revision == 0 && transcriptions.last?.revision == 1)
  #expect(records.last(where: { $0.category == "Watch live" })?.finished == false)
  #expect(conversation.chat.messages.last?.complete == false)
}

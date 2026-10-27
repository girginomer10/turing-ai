import Foundation
import Observation

public struct WatchModel: Identifiable, Hashable {
  public let endpoint: VoiceEndpoint
  public let model: String
  public init(endpoint: VoiceEndpoint, model: String) {
    self.endpoint = endpoint
    self.model = model
  }
  public var id: String { endpoint.id.uuidString + ":" + model }
}

@MainActor @Observable
public final class WatchConversation {
  public enum Phase {
    case idle, connecting, live, recording, transcribing, review, answering, speaking
  }
  public var phase: Phase = .idle
  public var draft = ""
  public var answer = ""
  public var heard = ""
  public var status = ""
  public var seconds = 0
  public var chat: WatchChat
  public var contextStatus = ""
  public var prepareContext: ((WatchChat, String) async throws -> (WatchChat, WatchContext))?
  public var saveMessage: ((WatchMessage, WatchChat) throws -> Void)?
  public var saveUsage: ((VoiceUsageEntry, WatchChat) throws -> Void)?
  public var saveDraft: ((WatchChat) throws -> Void)?
  private var requestContext = WatchContext()
  private var liveChoice: WatchModel?
  private var liveUser: WatchMessage?
  private var liveAssistant: WatchMessage?
  private var liveUsers: [UUID: WatchMessage] = [:]
  private var pendingTurnUsage: VoiceTokenUsage?
  private var liveResponsePending = false
  private var savedMessageIDs: Set<UUID> = []
  private var liveUsage: VoiceUsageEntry?
  private var liveUsageIDs: Set<String> = []
  private var hasLiveUsage = false
  private var transcriptionUsageIDs: Set<String> = []
  private var transcriptionRequests: [String: VoiceUsageEntry] = [:]
  private let audio: any VoiceAudioDevice
  private let client = VoiceHTTPClient()
  private var task: Task<Void, Never>?
  private var inputTask: Task<Void, Never>?
  private var timer: Task<Void, Never>?
  private var live: (any LiveVoiceTransport)?
  private let makeLive:
    @Sendable (VoiceEndpoint, String, [VoiceTurn], String) -> any LiveVoiceTransport
  private var generation = UUID()
  private var turns: [VoiceTurn] = []
  private var chunks: [String] = []
  private var speechEndpoint: VoiceEndpoint?
  private var activeItem: String?
  private var itemStart = 0
  private var receivedMilliseconds = 0
  private var nextAudio = true
  private var nextAssistant = true
  private var nextUser = true
  public var active: Bool { phase != .idle && phase != .review }

  public init(
    audio: any VoiceAudioDevice, chat: WatchChat = WatchChat(),
    makeLive:
      @escaping @Sendable (VoiceEndpoint, String, [VoiceTurn], String) -> any LiveVoiceTransport = {
        LiveVoiceSession(endpoint: $0, model: $1, history: $2, context: $3)
      }
  ) {
    self.audio = audio
    self.makeLive = makeLive
    self.chat = chat
    self.draft = chat.draft
    self.turns = chat.messages.map(\.turn)
    self.savedMessageIDs = Set(chat.messages.map(\.id))
    audio.onPlaybackDrained = { [weak self] in
      guard let self, self.phase == .live else { return }
      self.status = "Listening · speak naturally"
    }
  }

  /// Inactive includes wrist-down/Always On and the system audio-route picker.
  /// Only an actual background transition ends this foreground voice session.
  public func sceneChanged(isBackground: Bool) {
    guard isBackground else { return }
    stop()
    status = "Session ended · app left the foreground"
  }
  public func audioInterrupted(began: Bool) {
    guard began, active else { return }
    stop()
    status = "Audio interrupted · start again when ready"
  }

  public func stop(clear: Bool = false) {
    if liveChoice != nil {
      do {
        try commitTurnUsage()
        try finishLiveTurn(complete: false)
      } catch { contextStatus = "Could not save Watch history. Keep the app open and retry sync." }
      liveChoice = nil
      liveUser = nil
      liveAssistant = nil
    }
    if var usage = liveUsage {
      usage.revision += 1
      usage.finished = !liveResponsePending
      do { try saveUsage?(usage, chat) } catch { contextStatus = "Could not save voice usage." }
      liveUsage = nil
    }
    generation = UUID()
    task?.cancel()
    task = nil
    inputTask?.cancel()
    inputTask = nil
    timer?.cancel()
    timer = nil
    if let live { Task { await live.stop() } }
    live = nil
    audio.stop()
    chunks = []
    activeItem = nil
    phase = .idle
    status = "Stopped"
    if clear {
      draft = ""
      answer = ""
      heard = ""
      status = ""
      turns = []
      speechEndpoint = nil
    }
  }
  public func changeModel() {
    stop()
    if !draft.isEmpty {
      phase = .review
      status = "Review your words before sending"
    }
  }
  public func select(_ choice: WatchModel) {
    chat.providerID = choice.endpoint.id
    chat.model = choice.model
    do { try persistDraft() } catch { contextStatus = "Draft could not be saved." }
  }
  public func setSpeechEndpoint(_ endpoint: VoiceEndpoint?) { speechEndpoint = endpoint }
  public func persistDraft() throws {
    chat.draft = VoiceIdentity.bounded(draft, bytes: 16_384)
    try saveDraft?(chat)
  }
  private func prepare(_ query: String) async throws {
    requestContext = WatchContext()
    if let prepareContext {
      let selectedProvider = chat.providerID
      let selectedModel = chat.model
      let (updated, context) = try await prepareContext(chat, query)
      try Task.checkCancellation()
      chat = updated
      chat.providerID = selectedProvider
      chat.model = selectedModel
      requestContext = context
      turns = chat.messages.map(\.turn)
      savedMessageIDs.formUnion(chat.messages.map(\.id))
      contextStatus =
        context.offline
        ? "Offline · saved chat only, iPhone memory unavailable"
        : context.memoryIDs.isEmpty
          ? "Saved conversation context" : "\(context.memoryIDs.count) memories included"
    }
  }
  private func history() -> [VoiceTurn] {
    var result = Array(turns.suffix(18))
    while result.reduce(0, { $0 + $1.text.utf8.count }) > 40_000 { result.removeFirst() }
    return result
  }
  private func retain(_ message: WatchMessage) throws {
    guard !savedMessageIDs.contains(message.id), !message.text.isEmpty else { return }
    try saveMessage?(message, chat)
    savedMessageIDs.insert(message.id)
    chat.messages.append(message)
    chat.messages.sort { $0.date < $1.date }
    chat.updatedAt = max(chat.updatedAt, message.date)
    if chat.title == "New conversation", message.role == "user" {
      chat.title = VoiceIdentity.bounded(message.text, bytes: 120)
    }
    turns = chat.messages.map(\.turn)
  }
  private func finishLiveTurn(complete: Bool) throws {
    if let user = liveUser, !user.text.isEmpty { try retain(user) }
    if var assistant = liveAssistant, !assistant.text.isEmpty {
      assistant.complete = complete
      try retain(assistant)
    }
    liveAssistant = nil
  }
  private func commitTurnUsage() throws {
    guard let tokens = pendingTurnUsage, var usage = liveUsage else { return }
    pendingTurnUsage = nil
    if hasLiveUsage {
      usage.tokens.add(tokens)
    } else {
      usage.tokens = tokens
      hasLiveUsage = true
    }
    usage.revision += 1
    liveUsage = usage
    try saveUsage?(usage, chat)
  }
  private func finishUsage(_ usage: VoiceUsageEntry) {
    do { try saveUsage?(usage, chat) } catch {
      contextStatus = "Usage could not be saved. The answer is retained; do not resend it."
    }
  }
  private func fail(_ error: Error, generation token: UUID) {
    guard token == generation else { return }
    stop()
    status =
      (error as? VoiceError)?.localizedDescription
      ?? "The connection or audio session failed. Check your internet connection and try again."
  }
  public func startLive(_ choice: WatchModel) {
    stop()
    answer = ""
    heard = ""
    nextAudio = true
    nextAssistant = true
    nextUser = true
    phase = .connecting
    status = "Connecting…"
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--watch-ui-preview") {
        phase = .live
        status = "Preview · microphone off"
        heard = "Bugün neler yapabilirim?"
        answer = "Önce kısa bir yürüyüş yapabilir, ardından günün planını hazırlayabilirsin."
        return
      }
    #endif
    let token = generation
    task = Task {
      do {
        select(choice)
        try await prepare("")
        try Task.checkCancellation()
        guard token == generation else { return }
        liveChoice = choice
        liveUser = nil
        liveAssistant = nil
        liveUsers = [:]
        pendingTurnUsage = nil
        liveResponsePending = false
        liveUsageIDs = []
        transcriptionUsageIDs = []
        transcriptionRequests = [:]
        hasLiveUsage = false
        let usage = VoiceUsageEntry(choice: choice, category: "Watch live")
        try saveUsage?(usage, chat)
        liveUsage = usage
        let microphone = try await audio.live()
        try Task.checkCancellation()
        guard token == generation else { return }
        let session = makeLive(
          choice.endpoint, choice.model, history(), requestContext.instructions)
        live = session
        let events = try await session.start()
        inputTask = Task {
          do {
            for try await bytes in microphone {
              try Task.checkCancellation()
              try await session.sendAudio(bytes)
            }
          } catch { fail(error, generation: token) }
        }
        timer = Task {
          do {
            try await Task.sleep(for: .seconds(300))
            guard token == generation else { return }
            stop()
            status = "Five-minute session ended. Start again to continue."
          } catch {}
        }
        for try await event in events {
          try Task.checkCancellation()
          guard token == generation else { return }
          switch event {
          case .ready:
            phase = .live
            status = "Listening · speak naturally"
          case .audio(let bytes, let item):
            liveResponsePending = true
            if nextAudio || item != activeItem {
              activeItem = item
              itemStart = audio.nextPlaybackMilliseconds
              receivedMilliseconds = 0
            }
            nextAudio = false
            status = "Speaking · you can interrupt"
            receivedMilliseconds += bytes.count / 48
            try audio.playPCM(bytes)
          case .interrupted:
            try finishLiveTurn(complete: false)
            let played = min(receivedMilliseconds, max(0, audio.playedMilliseconds - itemStart))
            let hadUnplayedAudio = audio.queuedMilliseconds > 0
            audio.clearPlayback()
            if hadUnplayedAudio, let item = activeItem {
              try await session.truncate(itemID: item, playedMilliseconds: played)
            }
            activeItem = nil
            receivedMilliseconds = 0
            nextAudio = true
            nextUser = true
            nextAssistant = true
            status = "Listening · speak naturally"
          case .userTurnStarted(let itemID):
            liveResponsePending = true
            liveUser = WatchMessage(
              id: itemID.map { VoiceIdentity.id(chat.id.uuidString + ":" + $0) } ?? UUID(),
              role: "user", text: "", choice: choice)
            if let user = liveUser { liveUsers[user.id] = user }
            if choice.endpoint.isOpenAI, let itemID {
              let usage = VoiceUsageEntry(
                id: VoiceIdentity.id(chat.id.uuidString + ":transcription:" + itemID),
                choice: WatchModel(endpoint: choice.endpoint, model: "gpt-4o-mini-transcribe"),
                category: "Watch live transcription")
              transcriptionRequests[itemID] = usage
              try saveUsage?(usage, chat)
            }
          case .usage(let tokens, let eventID, let transcription):
            if transcription {
              let key = eventID ?? liveUser?.id.uuidString ?? UUID().uuidString
              if transcriptionUsageIDs.insert(key).inserted {
                var usage =
                  transcriptionRequests[key]
                  ?? VoiceUsageEntry(
                    id: VoiceIdentity.id(chat.id.uuidString + ":transcription:" + key),
                    choice: WatchModel(endpoint: choice.endpoint, model: "gpt-4o-mini-transcribe"),
                    category: "Watch live transcription")
                usage.tokens = tokens
                usage.finished = true
                usage.revision = 1
                try saveUsage?(usage, chat)
              }
            } else if eventID == nil {
              // Gemini can revise its usage snapshot before turnComplete. Commit once per turn.
              pendingTurnUsage = tokens
            } else if eventID.map({ liveUsageIDs.insert($0).inserted }) ?? false,
              var usage = liveUsage
            {
              if hasLiveUsage {
                usage.tokens.add(tokens)
              } else {
                usage.tokens = tokens
                hasLiveUsage = true
              }
              usage.revision += 1
              liveUsage = usage
              try saveUsage?(usage, chat)
            }
          case .transcript(let role, let text, let append, let itemID):
            liveResponsePending = true
            if role == "user" {
              let beginsTurn = nextUser
              heard = append && !nextUser ? heard + text : text
              nextUser = false
              guard heard.utf8.count <= 16_384 else { throw VoiceError.responseTooLarge }
              let id = itemID.map { VoiceIdentity.id(chat.id.uuidString + ":" + $0) }
              if let id, let earlier = liveUsers[id], liveUser?.id != id {
                var user = earlier
                user.text = text
                try retain(user)
                liveUsers[id] = user
                continue  // Late transcription must not replace the current speaker turn.
              }
              if liveUser == nil || (id != nil && liveUser?.id != id)
                || (id == nil && beginsTurn
                  && liveUser.map { savedMessageIDs.contains($0.id) } == true)
              {
                liveUser = WatchMessage(
                  id: id ?? UUID(), role: "user", text: "",
                  date: liveAssistant?.date.addingTimeInterval(-0.001) ?? .now, choice: choice)
              }
              liveUser?.text = heard
              if let user = liveUser { liveUsers[user.id] = user }
              if !append, let user = liveUser { try retain(user) }
            } else {
              answer = append && !nextAssistant ? answer + text : text
              nextAssistant = false
              guard answer.utf8.count <= 16_384 else { throw VoiceError.responseTooLarge }
              if liveAssistant == nil {
                if liveUser == nil
                  || (nextUser && liveUser.map { savedMessageIDs.contains($0.id) } == true)
                {
                  liveUser = WatchMessage(role: "user", text: "", choice: choice)
                }
                liveAssistant = WatchMessage(
                  id: itemID.map { VoiceIdentity.id(chat.id.uuidString + ":" + $0) } ?? UUID(),
                  role: "assistant", text: "", choice: choice, replyTo: liveUser?.id,
                  memoryIDs: requestContext.memoryIDs)
              }
              liveAssistant?.text = answer
            }
          case .turnFinished:
            try commitTurnUsage()
            try finishLiveTurn(complete: true)
            liveResponsePending = false
            // Provider generation finishing is not playback finishing or a session end.
            // Keep microphone + WebSocket open while queued audio drains and for the next turn.
            nextAudio = true
            nextAssistant = true
            nextUser = true
            if audio.queuedMilliseconds == 0 { status = "Listening · speak naturally" }
          }
        }
        if token == generation {
          stop()
          status = "Session ended"
        }
      } catch { fail(error, generation: token) }
    }
  }
  public func record(using endpoint: VoiceEndpoint) {
    stop()
    draft = ""
    status = "Starting microphone…"
    phase = .connecting
    speechEndpoint = endpoint
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--watch-ui-preview") {
        phase = .review
        draft = "Bugün yapacaklarımı birlikte planlayalım. Önce kısa bir yürüyüş yapmak istiyorum."
        status = "Preview · review transcript"
        return
      }
    #endif
    let token = generation
    task = Task {
      do {
        try await audio.record()
        try Task.checkCancellation()
        guard token == generation else { return }
        phase = .recording
        seconds = 0
        status = "Recording · up to 60 seconds"
        timer = Task {
          do {
            for second in 1...60 {
              try await Task.sleep(for: .seconds(1))
              guard token == generation else { return }
              seconds = second
            }
            transcribe()
          } catch {}
        }
      } catch { fail(error, generation: token) }
    }
  }
  public func transcribe() {
    guard phase == .recording, let endpoint = speechEndpoint else { return }
    timer?.cancel()
    timer = nil
    phase = .transcribing
    status = "Transcribing…"
    let token = generation
    task = Task {
      do {
        let bytes = try audio.finishRecording()
        audio.stop()
        var usage = VoiceUsageEntry(
          choice: WatchModel(endpoint: endpoint, model: "gpt-transcribe"),
          category: "Watch transcription")
        try saveUsage?(usage, chat)
        let result = try await client.transcribeWithUsage(audio: bytes, endpoint: endpoint)
        usage.tokens = result.usage
        usage.finished = true
        usage.revision = 1
        finishUsage(usage)
        let text = result.text
        try Task.checkCancellation()
        guard token == generation else { return }
        guard text.utf8.count <= 16_384 else { throw VoiceError.responseTooLarge }
        draft = text
        try persistDraft()
        phase = .review
        status = "Review your words before sending"
      } catch { fail(error, generation: token) }
    }
  }
  public func send(_ choice: WatchModel) {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.utf8.count <= 16_384, !active else { return }
    stop()
    phase = .answering
    status = "Thinking…"
    answer = ""
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--watch-ui-preview") {
        phase = .idle
        answer =
          "Önce kısa bir yürüyüş yapalım. Sonra en önemli işini seçip ona yarım saat ayırabilirsin."
        heard = draft
        draft = ""
        status = "Preview · no request sent"
        return
      }
    #endif
    let token = generation
    task = Task {
      do {
        select(choice)
        try await prepare(text)
        try Task.checkCancellation()
        guard token == generation else { return }
        var history = history()
        while history.reduce(0, { $0 + $1.text.utf8.count }) + text.utf8.count > 60_000 {
          history.removeFirst()
        }
        let user = WatchMessage(role: "user", text: text, choice: choice)
        try retain(user)
        history.append(user.turn)
        var usage = VoiceUsageEntry(choice: choice, category: "Watch chat")
        try saveUsage?(usage, chat)
        let response = try await client.answerWithUsage(
          endpoint: choice.endpoint, model: choice.model, turns: history,
          context: requestContext.instructions)
        usage.tokens = response.usage
        usage.finished = true
        usage.revision = 1
        finishUsage(usage)
        let result = response.text
        try retain(
          WatchMessage(
            role: "assistant", text: result, choice: choice, replyTo: user.id,
            memoryIDs: requestContext.memoryIDs))
        try Task.checkCancellation()
        guard token == generation else { return }
        answer = result
        heard = text
        draft = ""
        try persistDraft()
        phase = .idle
        status = "Answer ready"
        speak()
      } catch { fail(error, generation: token) }
    }
  }
  public func speak() {
    guard !answer.isEmpty, let endpoint = speechEndpoint, !active else { return }
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--watch-ui-preview") {
        status = "Preview · speaker off"
        return
      }
    #endif
    stop()
    phase = .speaking
    status = "AI voice"
    // Chunk on Character boundaries. Never truncate a long answer or resend its chat request.
    var chunk = ""
    for character in answer {
      let value = String(character)
      if !chunk.isEmpty && chunk.utf8.count + value.utf8.count > 1800 {
        chunks.append(chunk)
        chunk = ""
      }
      chunk += value
    }
    if !chunk.isEmpty { chunks.append(chunk) }
    playNext(endpoint, token: generation)
  }
  private func playNext(_ endpoint: VoiceEndpoint, token: UUID) {
    guard token == generation else { return }
    guard !chunks.isEmpty else {
      audio.stop()
      phase = .idle
      status = "Answer ready"
      return
    }
    let chunk = chunks.removeFirst()
    task = Task {
      do {
        var usage = VoiceUsageEntry(
          choice: WatchModel(endpoint: endpoint, model: "gpt-4o-mini-tts"), category: "Watch speech"
        )
        try saveUsage?(usage, chat)
        let result = try await client.speechWithUsage(text: chunk, endpoint: endpoint)
        usage.tokens = result.usage
        usage.finished = true
        usage.revision = 1
        finishUsage(usage)
        let data = result.audio
        try Task.checkCancellation()
        guard token == generation else { return }
        try await audio.playFile(data) { [weak self] in self?.playNext(endpoint, token: token) }
      } catch { fail(error, generation: token) }
    }
  }
}

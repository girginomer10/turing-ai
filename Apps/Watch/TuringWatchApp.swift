import AVFAudio
import SwiftUI
import TuringVoice

@main
struct TuringWatchApp: App {
  @State private var connection = WatchConnection()
  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--watch-live-layout"),
          let configuration = connection.configuration
        {
          NavigationStack {
            WatchTalk(configuration: configuration, liveMode: true, connection: connection)
          }
        } else {
          WatchHome(connection: connection)
        }
      #else
        WatchHome(connection: connection)
      #endif
    }
  }
}

struct WatchHome: View {
  @Bindable var connection: WatchConnection
  @Environment(\.scenePhase) private var scenePhase
  var body: some View {
    NavigationStack {
      List {
        if let config = connection.configuration, !config.endpoints.isEmpty,
          connection.library != nil
        {
          NavigationLink {
            WatchTalk(configuration: config, liveMode: true, connection: connection)
          } label: {
            Label("Live conversation", systemImage: "waveform")
          }
          NavigationLink {
            WatchTalk(configuration: config, liveMode: false, connection: connection)
          } label: {
            Label("Record & send", systemImage: "mic")
          }
        } else {
          Text("Set up on iPhone").font(.headline)
          Text(
            "Open Turing AI → Settings → Apple Watch. Enable voice access, then sync with both apps open."
          ).font(.footnote)
        }
        if let library = connection.library, let configuration = connection.configuration {
          Section("Chats") {
            ForEach(library.chats) { chat in
              NavigationLink {
                WatchChatHistory(
                  connection: connection, configuration: configuration, chatID: chat.id)
              } label: {
                VStack(alignment: .leading) {
                  Text(chat.title).lineLimit(2)
                  if !chat.knownToPhone {
                    Text("Waiting for iPhone").font(.caption2).foregroundStyle(.secondary)
                  }
                }
              }
            }
            Button("Refresh chats", systemImage: "arrow.clockwise") {
              Task { await connection.refreshChats() }
            }
            if connection.nextChatPage != nil {
              Button("Earlier chats") { Task { await connection.refreshChats(more: true) } }
            }
          }
        }
        Section {
          Button("Sync with iPhone", systemImage: "arrow.triangle.2.circlepath") {
            connection.sync()
          }.disabled(connection.syncing)
          if connection.syncing { ProgressView() }
          Text(connection.status).font(.footnote).foregroundStyle(.secondary)
          if !connection.libraryStatus.isEmpty {
            Text(connection.libraryStatus).font(.caption2).foregroundStyle(.secondary)
          }
          if connection.configuration != nil {
            Button("Remove access", role: .destructive) { connection.disconnect() }
          }
        }
      }.navigationTitle("Turing AI")
        .task { await connection.refreshChats() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { connection.flushLibrary() } }
    }
  }
}

struct WatchTalk: View {
  let configuration: VoiceConfiguration
  let liveMode: Bool
  let connection: WatchConnection
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dismiss) private var dismiss
  @State private var conversation: WatchConversation
  init(
    configuration: VoiceConfiguration, liveMode: Bool, connection: WatchConnection,
    chat: WatchChat = WatchChat()
  ) {
    self.configuration = configuration
    self.liveMode = liveMode
    self.connection = connection
    _conversation = State(initialValue: WatchConversation(audio: WatchAudio(), chat: chat))
  }
  @State private var selected = ""
  private var choices: [WatchModel] {
    configuration.endpoints.flatMap { endpoint in
      (liveMode ? endpoint.liveModels : endpoint.models).map {
        WatchModel(endpoint: endpoint, model: $0)
      }
    }
  }
  private var choice: WatchModel? { choices.first { $0.id == selected } ?? choices.first }
  private var speech: VoiceEndpoint? { configuration.endpoints.first { $0.isOpenAI } }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if choices.isEmpty || (!liveMode && speech == nil) {
          Text(
            liveMode
              ? "Sync an OpenAI or Gemini connection from iPhone to use live voice."
              : "Sync an OpenAI connection for transcription and speech, plus an enabled chat model."
          )
        } else {
          if !conversation.active {
            NavigationLink {
              WatchModelSelection(choices: choices, selected: $selected)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text("Model").font(.caption2).foregroundStyle(.secondary)
                WatchModelLabel(
                  model: choice?.model ?? "Choose model", provider: choice?.endpoint.name ?? "")
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
          }
          if conversation.active {
            if conversation.phase == .recording {
              Text("\(conversation.seconds)s / 60s").monospacedDigit()
              Button("Review recording", systemImage: "checkmark") { conversation.transcribe() }
                .buttonStyle(.borderedProminent)
            } else if conversation.phase == .connecting || conversation.phase == .transcribing
              || conversation.phase == .answering
            {
              ProgressView()
            } else if conversation.phase == .live {
              Image(systemName: "waveform").font(.largeTitle).frame(maxWidth: .infinity)
                .foregroundStyle(.tint).accessibilityLabel("Microphone active")
            }
            Button("Stop", systemImage: "stop.fill", role: .destructive) { conversation.stop() }
          } else if liveMode {
            Button("Start live", systemImage: "waveform") {
              if let choice { conversation.startLive(choice) }
            }.buttonStyle(.borderedProminent)
          } else {
            if !conversation.draft.isEmpty || conversation.phase == .review {
              Text(conversation.draft).frame(maxWidth: .infinity, alignment: .leading)
              Text("Edit transcript").font(.caption).foregroundStyle(.secondary)
              TextField("Edit transcript", text: $conversation.draft)
              Button("Send", systemImage: "arrow.up") {
                if let choice { conversation.send(choice) }
              }
              .disabled(
                conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || conversation.draft.utf8.count > 16_384
              )
              .buttonStyle(.borderedProminent)
            }
            Button("Record", systemImage: "mic.fill") {
              if let speech { conversation.record(using: speech) }
            }
            if !conversation.answer.isEmpty {
              Button("Read aloud", systemImage: "speaker.wave.2") { conversation.speak() }
            }
          }
          if !conversation.contextStatus.isEmpty {
            Text(conversation.contextStatus).font(.caption2).foregroundStyle(.secondary)
          }
          if conversation.active, conversation.phase == .live {
            Button("Change model", systemImage: "slider.horizontal.3") {
              conversation.changeModel()
            }
          }
          if !conversation.status.isEmpty {
            Text(conversation.status).font(.footnote).foregroundStyle(.secondary)
          }
          if !conversation.heard.isEmpty {
            Text(conversation.heard).font(.footnote).foregroundStyle(.secondary)
          }
          if !conversation.answer.isEmpty {
            Text(conversation.answer).frame(maxWidth: .infinity, alignment: .leading)
          }
          Text(
            liveMode
              ? "AI-generated voice · 5-minute sessions"
              : "AI-generated voice · review before sending"
          ).font(.caption2).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
    }
    .navigationTitle(liveMode ? "Live" : "Record & send")
    .onAppear {
      conversation.setSpeechEndpoint(speech)
      conversation.saveMessage = { message, chat in
        guard let library = connection.library else { throw VoiceError.invalidConfiguration }
        try library.record(message, chat: chat)
      }
      conversation.saveUsage = { usage, chat in
        guard let library = connection.library else { throw VoiceError.invalidConfiguration }
        try library.record(usage, chat: chat)
      }
      conversation.saveDraft = { chat in try connection.library?.saveDraft(chat) }
      conversation.prepareContext = { chat, query in
        try await connection.prepareChat(chat, query: query)
      }
      selected =
        choices.first(where: {
          $0.endpoint.id == conversation.chat.providerID && $0.model == conversation.chat.model
        })?.id ?? choice?.id ?? ""
      #if DEBUG
        if let argument = ProcessInfo.processInfo.arguments.first(where: {
          $0.hasPrefix("--preview-model=")
        }),
          let model = choices.first(where: {
            $0.model == String(argument.dropFirst("--preview-model=".count))
          })
        {
          selected = model.id
        }
      #endif
      connection.didReplaceConfiguration = {
        conversation.stop()
        dismiss()
      }
    }
    .onChange(of: selected) { _, _ in
      conversation.changeModel()
      if let choice { conversation.select(choice) }
    }
    .onChange(of: conversation.draft) { _, _ in
      do { try conversation.persistDraft() } catch {
        conversation.contextStatus = "Draft could not be saved."
      }
    }
    .onChange(of: scenePhase) { _, phase in
      conversation.sceneChanged(isBackground: phase == .background)
    }
    .onReceive(
      NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(
        on: DispatchQueue.main)
    ) { notification in
      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      conversation.audioInterrupted(began: raw == AVAudioSession.InterruptionType.began.rawValue)
    }
    .onDisappear {
      conversation.stop()
      connection.didReplaceConfiguration = nil
    }
  }
}

struct WatchChatHistory: View {
  let connection: WatchConnection
  let configuration: VoiceConfiguration
  let chatID: UUID
  @State private var error: String?
  private var chat: WatchChat? { connection.library?.chat(chatID) }
  var body: some View {
    List {
      if let chat {
        Section {
          NavigationLink("Live conversation") {
            WatchTalk(
              configuration: configuration, liveMode: true, connection: connection, chat: chat)
          }
          NavigationLink("Record & send") {
            WatchTalk(
              configuration: configuration, liveMode: false, connection: connection, chat: chat)
          }
        }
        Button("Load earlier messages") { Task { await connection.loadOlder(chat) } }
        ForEach(chat.messages) { message in
          VStack(alignment: .leading, spacing: 4) {
            Text(message.role == "user" ? "You" : (message.model ?? "Assistant")).font(.caption2)
              .foregroundStyle(.secondary)
            Text(message.text).font(.body).fixedSize(horizontal: false, vertical: true)
            if !message.complete { Text("Interrupted").font(.caption2).foregroundStyle(.secondary) }
          }
        }
        if !chat.draft.isEmpty { Text("Draft: " + chat.draft).font(.footnote) }
      }
      if let error { Text(error).font(.footnote) }
    }.navigationTitle(chat?.title ?? "Conversation")
      .task {
        guard let chat else { return }
        do { _ = try await connection.prepareChat(chat, query: "") } catch {
          self.error = error.localizedDescription
        }
      }
  }
}

/// Separate scalable lines avoid navigation-link Picker's single combined value/capsule layout.
private struct WatchModelLabel: View {
  let model: String
  let provider: String
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(model.replacingOccurrences(of: "-", with: " ")).font(.body.weight(.semibold))
        .accessibilityLabel(model)
      Text(provider).font(.caption2).foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.leading)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

private struct WatchModelSelection: View {
  let choices: [WatchModel]
  @Binding var selected: String
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    List(choices) { item in
      Button {
        selected = item.id
        dismiss()
      } label: {
        HStack(alignment: .top, spacing: 6) {
          WatchModelLabel(model: item.model, provider: item.endpoint.name)
          if item.id == selected {
            Image(systemName: "checkmark").font(.caption).accessibilityLabel("Selected")
          }
        }
      }
      .listRowBackground(Color.secondary.opacity(0.15))
    }
    .navigationTitle("Models")
  }
}

import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Intentionally has no persistence context and never inserts source records, formation jobs,
/// request receipts or preferences. Closing/backgrounding destroys the entire session.
struct TemporaryChatView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Query private var providers: [ProviderConfigurationRecord]
  @Query private var models: [ProviderModelRecord]
  @State private var choice: ChatModelChoice?
  @State private var draft = ""
  @State private var turns: [AIChatMessage] = []
  @State private var images: [UUID: [ChatImageInput]] = [:]
  @State private var response = ""
  @State private var attachments: [ExperienceValue] = []
  @State private var generation: Task<Void, Never>?
  @State private var importTask: Task<Void, Never>?
  @State private var error: String?
  @State private var choosingModel = false
  @State private var choosingFile = false
  @State private var choosingPhoto = false
  @State private var photo: PhotosPickerItem?
  private var choices: [ChatModelChoice] {
    ProviderModelStore.choices(providers: providers, models: models)
  }
  private var busy: Bool { generation != nil || importTask != nil }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Button {
          choosingModel = true
        } label: {
          Label(choice?.modelIdentifier ?? "Choose a model", systemImage: "chevron.down")
            .font(.subheadline).frame(minHeight: 44)
        }.disabled(busy)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 20) {
            Label("Temporary chat", systemImage: "eye.slash").font(.headline)
            Text(
              "No saved history, memory or iCloud sync. This chat clears when you close it or put the app in the background. Your provider’s data retention policy still applies."
            )
            .font(.subheadline).foregroundStyle(.secondary)
            ForEach(turns) { turn in
              VStack(alignment: .leading, spacing: 6) {
                Text(turn.role == .user ? "You" : "Assistant").font(.caption).foregroundStyle(
                  .secondary)
                MosaicMarkdownView(source: ChatAttachmentStore.displayText(turn.content))
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if generation != nil {
              if response.isEmpty {
                ProgressView("Generating…")
              } else {
                MosaicMarkdownView(source: response)
              }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
          }.padding()
        }
        Divider()
        VStack(spacing: 8) {
          ForEach(attachments, id: \.id) { item in
            HStack {
              Label(item.filename ?? "Attachment", systemImage: item.isImage ? "photo" : "doc.text")
                .font(.caption).lineLimit(2)
              Spacer()
              Button {
                attachments.removeAll { $0.id == item.id }
              } label: {
                Image(systemName: "xmark.circle")
              }.frame(minWidth: 44, minHeight: 44).disabled(busy)
            }
          }
          TextField("Message", text: $draft, axis: .vertical).lineLimit(1...8)
            .textFieldStyle(.plain).padding(10).background(
              .quaternary, in: RoundedRectangle(cornerRadius: 12)
            )
            .disabled(busy)
          HStack {
            Menu {
              Button("Photo", systemImage: "photo") { choosingPhoto = true }
              Button("File", systemImage: "doc") { choosingFile = true }
            } label: {
              Image(systemName: "plus").frame(width: 44, height: 44)
            }.disabled(busy || attachments.count >= 4)
            Spacer()
            if generation != nil {
              Button("Stop") { generation?.cancel() }.frame(minHeight: 44)
            } else {
              Button("Send", systemImage: "arrow.up") { send() }.frame(minHeight: 44).disabled(
                busy || choice == nil
                  || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && attachments.isEmpty)
              )
            }
          }
        }.padding()
      }.navigationTitle("Temporary chat")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") {
              clear()
              dismiss()
            }
          }
        }
        .sheet(isPresented: $choosingModel) {
          ChatModelSelectionView(choices: choices, selectedID: choice?.id, privateMode: true) {
            choice = $0
          }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, value in
          guard let value, !busy else { return }
          importTask = Task { @MainActor in
            defer {
              importTask = nil
              photo = nil
            }
            do {
              guard let data = try await value.loadTransferable(type: Data.self) else {
                throw ProviderClientError.invalidResponse
              }
              let item = try await Task.detached {
                try ChatAttachmentStore.photo(data, filename: "Photo.jpg", conversationID: UUID())
              }.value
              try Task.checkCancellation()
              attachments.append(item)
            } catch { self.error = error.localizedDescription }
          }
        }
        .fileImporter(
          isPresented: $choosingFile,
          allowedContentTypes: [
            .image, .pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText,
          ]
        ) { result in
          guard !busy else { return }
          importTask = Task { @MainActor in
            defer { importTask = nil }
            do {
              let url = try result.get()
              let item = try await Task.detached {
                try ChatAttachmentStore.importFile(url, conversationID: UUID())
              }.value
              try Task.checkCancellation()
              attachments.append(item)
            } catch { self.error = error.localizedDescription }
          }
        }
        .onChange(of: scenePhase) { _, phase in
          if phase == .background {
            clear()
            dismiss()
          }
        }
        .onDisappear { clear() }
        .overlay {
          if scenePhase != .active {
            Color.clear.background(.regularMaterial).overlay(
              Image(systemName: "eye.slash").font(.largeTitle))
          }
        }
    }
    #if os(macOS)
      .frame(minWidth: 480, minHeight: 560)
    #endif
  }
  private func clear() {
    generation?.cancel()
    importTask?.cancel()
    turns.removeAll()
    images.removeAll()
    attachments.removeAll()
    draft = ""
    response = ""
    error = nil
  }
  private func send() {
    guard !busy, let choice, let config = providers.first(where: { $0.id == choice.providerID }),
      let provider = try? ProviderModelStore.connection(
        provider: config, modelIdentifier: choice.modelIdentifier, models: models)
    else { return }
    let message = AIChatMessage(
      role: .user,
      content: ChatAttachmentStore.messageContent(text: draft, attachments: attachments))
    let pending = attachments
    let priorImages = images
    let priorDraft = draft
    let priorTurns = turns
    generation = Task { @MainActor in
      defer { generation = nil }
      var key: String?
      do {
        error = nil
        let input = turns + [message]
        var requestImages = images
        let photos = pending.compactMap { item -> ChatImageInput? in
          guard item.isImage, let bytes = item.bytes else { return nil }
          return ChatImageInput(mimeType: "image/jpeg", data: bytes)
        }
        if !photos.isEmpty { requestImages[message.id] = photos }
        if !requestImages.isEmpty, !ModelImageCapability.supports(choice, preference: nil) {
          throw ChatAttachmentFailure(
            message: "Choose a photo-capable model for this temporary chat.")
        }
        let limits = ProviderConversationContextLimits(configuration: provider)
        // No summaries or recall: fail explicitly when the whole temporary chat no longer fits.
        let estimated = input.reduce(0) { $0 + ConservativeTokenEstimator().estimate(message: $1) }
        guard
          estimated + requestImages.values.reduce(0, { $0 + $1.count * 4096 })
            <= limits.policy.availableInputTokens
        else {
          throw ChatAttachmentFailure(
            message:
              "This temporary chat reached the model's limit. Start a new temporary chat or choose a model with a larger context."
          )
        }
        key = try await SecurityKeychain.shared.apiKey(
          for: provider.id, expectedBinding: provider.credentialBinding)
        try Task.checkCancellation()
        let client = ProviderClientFactory.make(connection: provider.authenticated(with: key))
        turns.append(message)
        images = requestImages
        attachments = []
        draft = ""
        response = ""
        var complete = false
        for try await event in client.stream(
          AIChatRequest(
            messages: input, maxOutputTokens: limits.policy.maximumOutputTokens,
            images: requestImages))
        {
          try Task.checkCancellation()
          switch event {
          case .textDelta(let text):
            guard
              response.utf8.count + text.utf8.count
                <= MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes
            else { throw ProviderClientError.responseTooLarge }
            response += text
          case .completed: complete = true
          default: break
          }
        }
        try Task.checkCancellation()
        guard complete, !response.isEmpty else { throw ProviderClientError.invalidResponse }
        turns.append(AIChatMessage(role: .assistant, content: response))
        response = ""
      } catch is CancellationError {
        response = ""
      } catch {
        turns = priorTurns
        images = priorImages
        attachments = pending
        draft = priorDraft
        response = ""
        self.error = ProviderErrorSanitizer.description(for: error, redacting: key)
      }
    }
  }
}

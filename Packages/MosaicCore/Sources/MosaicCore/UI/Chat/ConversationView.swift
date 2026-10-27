import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

private actor SameConversationRecallExecutor {
  static let shared = SameConversationRecallExecutor()

  func plan(
    query: String,
    currentConversationID: UUID,
    candidates: [RetrievalCandidate],
    basePlan: ConversationContextPlan,
    originalMessages: [AIChatMessage],
    policy: ConversationContextPolicy,
    estimator: ConservativeTokenEstimator
  ) throws -> SameConversationRecallPlan {
    try Task.checkCancellation()
    let result = SameConversationRecallPlanner(estimator: estimator).plan(
      query: query,
      currentConversationID: currentConversationID,
      candidates: candidates,
      basePlan: basePlan,
      originalMessages: originalMessages,
      policy: policy
    )
    try Task.checkCancellation()
    return result
  }
}

/// Serializes presentation-time audit repair with paid compaction work for the same chat.
/// `NormalizedContextStore` owns the bounded, append-only reconciliation; this coordinator owns
/// the cross-window exclusion and always reads canonical history from a fresh model actor before
/// asking the main-actor store to write a terminal event.
@MainActor
final class ConversationPresentationCompactionRecovery {
  static let shared = ConversationPresentationCompactionRecovery()

  private let executionGate: ConversationCompactionExecutionGate
  private let operationCoordinator: MosaicOperationCoordinator

  init(
    executionGate: ConversationCompactionExecutionGate = .shared,
    operationCoordinator: MosaicOperationCoordinator = .shared
  ) {
    self.executionGate = executionGate
    self.operationCoordinator = operationCoordinator
  }

  @discardableResult
  func reconcile(
    conversationID: UUID,
    modelContainer: ModelContainer
  ) async throws -> Int {
    let operationID = MosaicOperationID.conversationCompactionRecovery(conversationID)
    guard operationCoordinator.begin(operationID) else { return 0 }
    guard await executionGate.acquire(conversationID: conversationID) else {
      operationCoordinator.end(operationID)
      return 0
    }

    do {
      let recoveryContext = ModelContext(modelContainer)
      let contextStore = NormalizedContextStore(modelContext: recoveryContext)
      guard try contextStore.hasInterruptedGeneratingEvents(conversationID: conversationID) else {
        await executionGate.release(conversationID: conversationID)
        operationCoordinator.end(operationID)
        return 0
      }
      let repository = MosaicConversationReadRepository(modelContainer: modelContainer)
      let canonicalMessages = try await repository.canonicalState(
        conversationID: conversationID
      ).messages
      try Task.checkCancellation()
      let count = try contextStore.reconcileInterruptedGeneratingEvents(
        conversationID: conversationID,
        canonicalMessages: canonicalMessages
      )
      await executionGate.release(conversationID: conversationID)
      operationCoordinator.end(operationID)
      return count
    } catch {
      await executionGate.release(conversationID: conversationID)
      operationCoordinator.end(operationID)
      throw error
    }
  }
}

private struct ConversationPresentationRequest: Hashable {
  let conversationID: UUID
  let sourceStoreGenerationRevision: UInt64
  let projectCatalogRevision: UInt64
}

enum ConversationLiveTranscriptionState: Equatable {
  case idle
  case requestingPermission
  case connecting
  case listening
  case finishing

  var isActive: Bool { self != .idle }

  func lifecycleAction(
    for trigger: ConversationLiveTranscriptionLifecycleTrigger
  ) -> ConversationLiveTranscriptionLifecycleAction {
    switch (self, trigger) {
    case (.requestingPermission, .sceneBecameInactive):
      // The system permission alert temporarily makes the scene inactive. Keep waiting for the
      // user's choice instead of treating that alert as a request to cancel.
      .none
    case (.requestingPermission, .sceneEnteredBackground),
      (.requestingPermission, .viewDisappeared):
      .cancelPermissionRequest
    case (.connecting, _):
      .cancelSession
    case (.listening, _):
      .finishRecording
    case (.finishing, .sceneBecameInactive), (.finishing, .sceneEnteredBackground):
      .protectFinalization
    case (.finishing, .viewDisappeared), (.idle, _):
      .none
    }
  }
}

enum ConversationLiveTranscriptionLifecycleTrigger: Equatable {
  case sceneBecameInactive
  case sceneEnteredBackground
  case viewDisappeared
}

enum ConversationLiveTranscriptionLifecycleAction: Equatable {
  case none
  case cancelPermissionRequest
  case cancelSession
  case finishRecording
  case protectFinalization
}

enum ConversationLiveTranscriptionSetupValidation {
  static func validate(didCompleteSetup: Bool) throws {
    // Some AsyncStream transports terminate with `nil` when cancelled instead of throwing. Check
    // cancellation before classifying a missing setup event as a malformed provider response.
    try Task.checkCancellation()
    guard didCompleteSetup else { throw LiveTranscriptionError.invalidResponse }
  }
}

private actor LiveTranscriptionFailureStore {
  private var error: Error?

  func record(_ error: Error) {
    if self.error == nil { self.error = error }
  }

  func recordedError() -> Error? { error }
}

struct ConversationView: View {
  @AppStorage(InterfacePreferences.advancedControlsKey) private var advancedControls = false
  @Environment(\.modelContext) private var modelContext
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Query private var experienceRecords: [ExperienceRecord]
  private let openConversation: (UUID) -> Void
  @State private var editingMessage: MosaicTranscriptMessage?
  @State private var showAlternatives = false
  @State private var showGoogleConnections = false
  @AppStorage private var connectorSelectionRaw: String
  @AppStorage("turing.connections.defaults") private var defaultConnectorSelection = ""
  @State private var connectorApproval = ConnectorApprovalCoordinator()
  private var connectorSelection: ConnectorSelection {
    .init(
      raw: connectorSelectionRaw == "__default__"
        ? defaultConnectorSelection : connectorSelectionRaw)
  }
  @AppStorage private var googleServicesRaw: String
  @AppStorage private var googleSubjectRaw: String
  @AppStorage("turing.google.defaultServices") private var defaultGoogleServices = ""
  @AppStorage("turing.google.defaultSubject") private var defaultGoogleSubject = ""
  private var googleServices: Set<GoogleService> {
    let raw = googleServicesRaw == "__default__" ? defaultGoogleServices : googleServicesRaw
    return Set(
      raw.split(separator: ",").compactMap { GoogleService(rawValue: String($0)) }.filter {
        $0 == .gmail || $0 == .drive
      })
  }
  private var googleSubject: String {
    googleServicesRaw == "__default__" ? defaultGoogleSubject : googleSubjectRaw
  }
  @State private var searchActivity: MessageSearchActivity?
  @State private var googleResearchContinuation:
    (conversationID: UUID, revision: UInt64, checkpoint: GmailResearchCheckpoint)?
  @State private var webSearch = false
  @State private var branching = false
  @State private var importingAttachment = false
  @State private var choosingPhoto = false
  @State private var attachmentImportBusy = false
  @State private var pickedPhoto: PhotosPickerItem?
  private var attachments: [ExperienceValue] {
    experienceRecords.compactMap {
      try? JSONDecoder().decode(ExperienceValue.self, from: $0.payload)
    }.filter { $0.kind == .attachment && $0.conversationID == conversation.id }
  }
  private var draftAttachments: [ExperienceValue] { attachments.filter { $0.messageID == nil } }

  @ScaledMetric(relativeTo: .body) private var composerLineHeight = 22.0
  @FocusState private var isComposerFocused: Bool
  @AppStorage(AutomaticMemorySettings.enabledKey)
  private var automaticMemoryEnabled = true
  @Query(sort: \ProviderConfigurationRecord.createdAt)
  private var providers: [ProviderConfigurationRecord]
  @Query private var providerModels: [ProviderModelRecord]
  @State private var showModelSelection = false
  @Query(sort: \EmbeddingProfileRecord.updatedAt, order: .reverse)
  private var embeddingProfiles: [EmbeddingProfileRecord]
  @Query(sort: \ProjectRecord.name)
  private var projects: [ProjectRecord]
  @Query private var projectBindings: [ProjectResourceBindingRecord]
  @Query private var recentMessageRecords: [MessageRecord]

  @Bindable private var conversation: ConversationRecord

  @State private var operationCoordinator = MosaicOperationCoordinator.shared
  @State private var requestRegistry = ConversationRequestRegistry.shared
  @State private var generationTask: Task<Void, Never>?
  @State private var showMemoryContext = false
  @State private var showDeliveryDetails = false
  @State private var followsLatestMessage = true
  @State private var isAtLatestMessage = true
  @State private var isUserScrollingTranscript = false
  @State private var earlierMessageAnchor: UUID?
  private let transcriptBottomID = "transcript-bottom"
  @State private var lastContextReceipt: RequestContextReceipt?
  @State private var storedContextReceipt: RequestContextReceipt?
  @State private var receiptAssistantMessageID: UUID?
  @State private var storedContextReceiptTask: Task<Void, Never>?
  @State private var storedContextReceiptTaskID: UUID?
  @State private var isLoadingStoredContextReceipt = false
  @State private var isRecallingContext = false
  @State private var isCompactingContext = false
  @State private var transientNotice: String?
  @State private var transientNoticeClearTask: Task<Void, Never>?
  @State private var persistenceError: String?
  @State private var draftPersistenceTask: Task<Void, Never>?
  @State private var requestPreparationTask: Task<Void, Never>?
  @State private var memoryRefreshTask: Task<Void, Never>?
  @State private var curatedMemoryRequestID: UUID?
  @State private var transcriptSnapshotTask: Task<Void, Never>?
  @State private var transcriptSnapshotRequestID: UUID?
  @State private var transcriptPagingTask: Task<Void, Never>?
  @State private var transcriptPagingID: UUID?
  @State private var transcriptHeadPage: [MosaicTranscriptMessage] = []
  @State private var olderTranscriptMessages: [MosaicTranscriptMessage] = []
  @State private var transcriptCursor: MosaicTranscriptCursor?
  @State private var transcriptHasMore = false
  @State private var loadedTranscriptSourceGeneration: UInt64?
  @State private var allowsLiveTranscriptOverlay = false
  @State private var isLoadingTranscript = false
  @State private var curatedMemoryContext: MemoryContext = .empty
  @State private var liveTranscriptionBackgroundDrainLease =
    LiveTranscriptionBackgroundDrainLease()
  @State private var liveTranscriptionPermissionTask: Task<Void, Never>?
  @State private var liveTranscriptionPermissionRequestID: UUID?
  @State private var liveTranscriptionTask: Task<Void, Never>?
  @State private var liveTranscriptionRequestID: UUID?
  @State private var liveTranscriptionSession: (any LiveTranscriptionSession)?
  @State private var liveMicrophoneSource: LiveMicrophoneAudioSource?
  @State private var liveTranscriptionState = ConversationLiveTranscriptionState.idle
  @State private var liveTranscriptionProviderName = ""
  @State private var liveInterimTranscript = ""
  @State private var liveTranscriptionLanguageCode: String?
  @State private var liveTranscriptionError: String?

  private static let transcriptPageSize = 16

  init(conversation: ConversationRecord, openConversation: @escaping (UUID) -> Void = { _ in }) {
    self.openConversation = openConversation
    self.conversation = conversation
    let conversationID = conversation.id
    _connectorSelectionRaw = AppStorage(
      wrappedValue: "__default__", "turing.connections.chat." + conversationID.uuidString)
    _googleServicesRaw = AppStorage(
      wrappedValue: "__default__", "turing.google.services." + conversationID.uuidString)
    _googleSubjectRaw = AppStorage(
      wrappedValue: "", "turing.google.subject." + conversationID.uuidString)
    _experienceRecords = Query(
      filter: #Predicate<ExperienceRecord> {
        $0.category == "model" || ($0.ownerID == conversationID && $0.messageID == nil)
      })
    var descriptor = FetchDescriptor<MessageRecord>(
      predicate: #Predicate<MessageRecord> { $0.conversationID == conversationID },
      sortBy: [
        SortDescriptor(\MessageRecord.createdAt, order: .reverse),
        SortDescriptor(\MessageRecord.id, order: .reverse),
      ]
    )
    descriptor.fetchLimit = Self.transcriptPageSize
    descriptor.includePendingChanges = true
    _recentMessageRecords = Query(descriptor)
    let bindingKey = ProjectResourceBindingRecord.makeBindingKey(
      resourceKind: .conversation,
      resourceID: conversationID
    )
    var projectDescriptor = FetchDescriptor<ProjectResourceBindingRecord>(
      predicate: #Predicate { $0.bindingKey == bindingKey }
    )
    projectDescriptor.fetchLimit = 1
    _projectBindings = Query(projectDescriptor)
  }

  private var conversationLayout: some View {
    GeometryReader { geometry in
      let expanded = geometry.size.height > 520 && !dynamicTypeSize.isAccessibilitySize
      VStack(spacing: 0) {
        #if os(macOS)
          if expanded {
            requestReceipt
            Divider()
          }
        #endif
        messageList
          .layoutPriority(1)
        Divider()
        composer(
          maximumTextHeight: max(composerLineHeight + 16, min(240, geometry.size.height * 0.55))
        )
        .layoutPriority(2)
      }
    }
    .modifier(NativeSourceLinks())
    .onChange(of: isComposerBusy) { _, busy in
      if busy { isComposerFocused = false }
    }
    .navigationTitle(recentMessageRecords.isEmpty ? "Turing AI" : conversation.title)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
    #endif
    .toolbar {
      #if os(iOS)
        ToolbarItem(id: "conversation-title-model", placement: .principal) {
          navigationModelButton
        }
      #endif
      ToolbarItem(placement: .secondaryAction) {
        Button("Alternatives", systemImage: "arrow.triangle.branch") { showAlternatives = true }
          .disabled(isComposerBusy || branching)
      }
      ToolbarItem(placement: .secondaryAction) {
        Toggle("Web search", systemImage: "globe", isOn: $webSearch)
          .disabled(
            isComposerBusy
              || activeModelConnection.map { !WebSearchCapability.supports($0) } ?? true)
      }
      projectMenu
      providerMenu
      ToolbarItem(id: "conversation-context", placement: .secondaryAction) {
        Button("Memory & context", systemImage: "brain.head.profile") {
          presentMemoryContext()
        }
      }
    }
  }

  var body: some View {
    conversationLayout
      .sheet(item: $editingMessage) { message in
        MessageEditView(text: ChatAttachmentStore.displayText(message.content)) { text in
          createAlternative(userMessageID: message.id, text: text)
        }
      }
      .sheet(isPresented: $showAlternatives) {
        ConversationAlternativesView(conversationID: conversation.id, open: openConversation)
      }
      .fileImporter(
        isPresented: $importingAttachment,
        allowedContentTypes: [
          .image, .pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText,
        ]
      ) { result in
        switch result {
        case .success(let url): importAttachment(url)
        case .failure(let error): persistenceError = error.localizedDescription
        }
      }
      .photosPicker(isPresented: $choosingPhoto, selection: $pickedPhoto, matching: .images)
      .onChange(of: pickedPhoto) { _, item in
        guard let item else { return }
        importPhoto(item)
      }
      .sheet(isPresented: $showGoogleConnections) {
        GoogleChatConnectionsView(
          otherSelection: Binding(
            get: { connectorSelection }, set: { connectorSelectionRaw = $0.raw }),
          selection: Binding(
            get: { googleServices },
            set: {
              googleServicesRaw = $0.map(\.rawValue).sorted().joined(separator: ",")
            }), selectedSubject: Binding(get: { googleSubject }, set: { googleSubjectRaw = $0 }),
          providerName: activeModelConnection?.displayName ?? "the selected AI provider")
      }
      .sheet(
        item: Binding(
          get: { connectorApproval.pending },
          set: { if $0 == nil { connectorApproval.finish(false) } })
      ) { pending in
        ConnectorApprovalView(pending: pending) { connectorApproval.finish($0) }
          .onDisappear { connectorApproval.finish(false) }
      }
      .sheet(isPresented: $showModelSelection) {
        ChatModelSelectionView(
          choices: ProviderModelStore.choices(providers: providers, models: providerModels),
          selectedID: conversation.providerConfigurationID.map {
            ProviderModelRecord.key(providerID: $0, model: conversation.modelIdentifier)
          }
        ) { choice in
          guard !isComposerBusy, !operationCoordinator.isSourceAccessBlocked else { return }
          conversation.providerConfigurationID = choice.providerID
          conversation.modelIdentifier = choice.modelIdentifier
          conversation.updatedAt = .now
          _ = saveOrReport()
        }
      }
      .sheet(isPresented: $showDeliveryDetails) {
        ConversationDeliveryDetails(
          disclosure: activeProvider.map { deliveryDisclosure(for: $0) }
            ?? "Choose an enabled provider before sending."
        )
      }
      .sheet(isPresented: $showMemoryContext) {
        MemoryContextSheet(
          curatedContext: displayedContextReceipt.curatedContext,
          retrievedContext: displayedContextReceipt.retrievedContext,
          projectContext: displayedContextReceipt.projectContext,
          conversationContext: displayedContextReceipt.conversationContext,
          sameConversationRecall: displayedContextReceipt.sameConversationRecall,
          conversationCompaction: displayedContextReceipt.conversationCompaction,
          conversationMessages: displayedTranscriptMessages,
          isRecalling: isRecallingContext || isLoadingStoredContextReceipt,
          isCompacting: isCompactingContext
        )
      }
      .alert(
        "Turing AI couldn’t continue this conversation", isPresented: persistenceErrorIsPresented
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(persistenceError ?? "Please try again.")
      }
      .alert("Live transcription unavailable", isPresented: liveTranscriptionErrorIsPresented) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(liveTranscriptionError ?? "Please try again.")
      }
      .task(id: presentationRequest) {
        await loadConversationPresentation()
      }
      .onChange(of: recentMessageIDs) { oldIDs, newIDs in
        guard oldIDs != newIDs else { return }
        if generationTask == nil {
          invalidateCachedContextReceipt()
          if showMemoryContext { presentMemoryContext() }
        }
        scheduleTranscriptSnapshotReset()
      }
      .onChange(of: operationCoordinator.contextReceiptRevision) { _, _ in
        if generationTask == nil {
          invalidateCachedContextReceipt()
          if showMemoryContext { presentMemoryContext() }
        }
      }
      .onChange(of: conversation.draftText) { _, _ in
        scheduleDraftPersistence()
      }
      .onChange(of: liveTranscriptionState) { oldState, newState in
        guard oldState != newState else { return }
        announceLiveTranscriptionState(newState, previousState: oldState)
      }
      .onChange(of: scenePhase) { _, newPhase in
        guard newPhase != .active else { return }
        handleLiveTranscriptionLifecycle(
          newPhase == .background ? .sceneEnteredBackground : .sceneBecameInactive
        )
        flushDraftPersistenceImmediately()
      }
      .onDisappear {
        memoryRefreshTask?.cancel()
        transientNoticeClearTask?.cancel()
        curatedMemoryRequestID = nil
        storedContextReceiptTask?.cancel()
        storedContextReceiptTaskID = nil
        transcriptSnapshotTask?.cancel()
        transcriptSnapshotRequestID = nil
        transcriptPagingTask?.cancel()
        transcriptPagingID = nil
        handleLiveTranscriptionLifecycle(.viewDisappeared)
        flushDraftPersistenceImmediately()
      }
  }

  private var messageList: some View {
    GeometryReader { viewport in
      ScrollViewReader { proxy in
        VStack(spacing: 0) {
          ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 18) {
              if transcriptHasMore {
                Button {
                  followsLatestMessage = false
                  earlierMessageAnchor = displayedTranscriptMessages.first?.id
                  loadEarlierTranscriptPage()
                } label: {
                  if isLoadingTranscript {
                    ProgressView().controlSize(.small)
                  } else {
                    Label("Load earlier messages", systemImage: "arrow.up.circle")
                  }
                }
                .buttonStyle(.borderless)
                .mosaicControlTarget()
                .disabled(isLoadingTranscript)
                .accessibilityHint("Loads one earlier page and keeps your place")
              }

              if displayedTranscriptMessages.isEmpty, !isLoadingTranscript {
                ConversationStarter(
                  showsSuggestions: !isComposerFocused && viewport.size.height > 340
                    && conversation.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                      .isEmpty
                ) { suggestion in
                  if !isComposerBusy { conversation.draftText = suggestion }
                }
                .disabled(isComposerBusy)
              }

              ForEach(displayedTranscriptMessages) { message in
                messageRow(message).id(message.id)
              }

              if let transientNotice {
                Label(transientNotice, systemImage: "checkmark.circle.fill")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .transition(.opacity)
              }
              Color.clear.frame(height: 1).id(transcriptBottomID)
            }
            .frame(maxWidth: 820)
            .frame(
              minHeight: displayedTranscriptMessages.isEmpty ? max(0, viewport.size.height - 32) : 0
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background {
              GeometryReader { content in
                Color.clear.preference(
                  key: TranscriptGeometryKey.self,
                  value: TranscriptGeometry(
                    height: content.size.height,
                    bottom: content.frame(in: .named("transcript-scroll")).maxY
                  )
                )
              }
            }
          }
          .coordinateSpace(name: "transcript-scroll")
          .defaultScrollAnchor(.bottom)
          .scrollDismissesKeyboard(.interactively)
          .accessibilityIdentifier("chat-transcript")
          .modifier(
            TranscriptScrollObserver(
              viewportHeight: viewport.size.height
            ) { atBottom in
              // Geometry is observation only. Scrolling from this callback feeds changed lazy
              // row estimates straight back into layout (the device watchdog killed build 21).
              if isAtLatestMessage != atBottom { isAtLatestMessage = atBottom }
              if atBottom, !isUserScrollingTranscript, !followsLatestMessage {
                followsLatestMessage = true
              }
            } interactionChanged: { isInteracting in
              if isInteracting {
                isUserScrollingTranscript = true
                followsLatestMessage = false
              } else if isUserScrollingTranscript {
                isUserScrollingTranscript = false
                followsLatestMessage = isAtLatestMessage
              }
            }
          )
          .onChange(of: displayedTranscriptMessages.last) { _, _ in
            if followsLatestMessage { proxy.scrollTo(transcriptBottomID, anchor: .bottom) }
          }
          .onChange(of: displayedTranscriptMessages.first?.id) { _, _ in
            if let anchor = earlierMessageAnchor {
              proxy.scrollTo(anchor, anchor: .top)
              earlierMessageAnchor = nil
            }
          }
        }
        .overlay(alignment: .bottomTrailing) {
          if !isAtLatestMessage, !displayedTranscriptMessages.isEmpty,
            viewport.size.height >= 160
          {
            Button {
              followsLatestMessage = true
              proxy.scrollTo(transcriptBottomID, anchor: .bottom)
            } label: {
              HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                  .font(.system(size: 18, weight: .semibold))
                if !dynamicTypeSize.isAccessibilitySize {
                  Text("Latest").font(.caption.weight(.semibold))
                }
              }
              .padding(.horizontal, 12)
              .mosaicControlTarget()
              .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Latest")
            .accessibilityHint("Scrolls to the newest message")
            .padding(8)
          }
        }
        .toolbar {
          if viewport.size.height < 160, !isAtLatestMessage,
            !displayedTranscriptMessages.isEmpty
          {
            ToolbarItem(id: "conversation-latest", placement: .primaryAction) {
              Button {
                followsLatestMessage = true
                proxy.scrollTo(transcriptBottomID, anchor: .bottom)
              } label: {
                Image(systemName: "arrow.down")
                  .font(.system(size: 18, weight: .semibold))
              }
              .mosaicControlTarget()
              .accessibilityLabel("Latest")
              .accessibilityHint("Scrolls to the newest message")
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func messageRow(_ message: MosaicTranscriptMessage) -> some View {
    if message.status == .failed,
      displayedTranscriptMessages.last(where: { $0.role == .assistant })?.id == message.id
    {
      MessageBubble(
        message: message,
        providerKind: message.providerKind,
        projectName: currentProject?.name,
        remember: { remember(message, scope: $0) },
        retry: { retry(message) },
        searchProgress: searchActivity?.messageID == message.id ? searchActivity?.progress : nil
      )
    } else {
      MessageBubble(
        message: message,
        providerKind: message.providerKind,
        projectName: currentProject?.name,
        remember: { remember(message, scope: $0) },
        retry: nil,
        edit: message.role == .user ? { editingMessage = message } : nil,
        alternative: message.role == .assistant ? { alternativeFor(message) } : nil,
        actionsDisabled: isComposerBusy || branching,
        searchProgress: searchActivity?.messageID == message.id ? searchActivity?.progress : nil
      )
    }
  }

  private func alternativeFor(_ message: MosaicTranscriptMessage) {
    guard !isComposerBusy, !branching else { return }
    Task { @MainActor in
      do {
        let repository = MosaicConversationReadRepository(modelContainer: modelContext.container)
        let previous = try await repository.completedMessages(
          conversationID: conversation.id, before: message.id)
        guard let user = previous.last, user.role == .user else { return }
        createAlternative(
          userMessageID: user.id, text: ChatAttachmentStore.displayText(user.content))
      } catch { persistenceError = error.localizedDescription }
    }
  }

  private func createAlternative(userMessageID: UUID, text: String) {
    guard !isComposerBusy, !branching else { return }
    guard operationCoordinator.beginVerifiedSourceSnapshotMaintenance() else { return }
    branching = true
    Task { @MainActor in
      defer {
        branching = false
        operationCoordinator.endExclusiveMaintenance()
      }
      do {
        try operationCoordinator.flushSourceChangesForVerifiedSnapshot(in: modelContext)
        let id = try await ConversationBranchStore(modelContainer: modelContext.container).create(
          sourceID: conversation.id, userMessageID: userMessageID, draft: text)
        operationCoordinator.markSourceStoreReplaced()
        openConversation(id)
      } catch { persistenceError = error.localizedDescription }
    }
  }

  private func composer(maximumTextHeight: CGFloat) -> some View {
    VStack(spacing: 8) {
      VStack(spacing: 6) {
        if !draftAttachments.isEmpty {
          ScrollView(.horizontal) {
            HStack {
              ForEach(draftAttachments, id: \.id) { attachment in
                HStack {
                  Label(
                    attachment.filename ?? "Attachment",
                    systemImage: attachment.isImage ? "photo" : "doc.text"
                  ).lineLimit(1)
                  Button {
                    removeAttachment(attachment.id)
                  } label: {
                    Image(systemName: "xmark.circle.fill")
                  }.accessibilityLabel("Remove \(attachment.filename ?? "attachment")").frame(
                    minWidth: 44, minHeight: 44)
                }.font(.caption).padding(.leading, 10).background(
                  .quaternary, in: RoundedRectangle(cornerRadius: 12))
              }
            }
          }.frame(maxHeight: 60)
        }
        if webSearch {
          Text("Web search on · provider search fees may apply").font(.caption).foregroundStyle(
            .secondary)
        }
        if attachmentImportBusy { ProgressView("Preparing attachment…") }
        // The hidden text supplies the natural wrapped height. The editor is an
        // overlay so it cannot request all available space. Once capped, its
        // native text view scrolls vertically, even in a short keyboard viewport.
        Text(composerText.wrappedValue + "\u{200B}")
          .font(.body)
          .padding(.horizontal, 5)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxHeight: maximumTextHeight, alignment: .top)
          .fixedSize(horizontal: false, vertical: true)
          .hidden()
          .accessibilityHidden(true)
          .overlay(alignment: .topLeading) {
            TextEditor(text: composerText)
              .font(.body)
              .scrollContentBackground(.hidden)
              .focused($isComposerFocused)
              .disabled(isComposerBusy)
              .accessibilityLabel("Message")
              .overlay(alignment: .topLeading) {
                if composerText.wrappedValue.isEmpty {
                  Text("Message Turing AI")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
              }
          }

        HStack(alignment: .center, spacing: 10) {
          Menu {
            Button("Photo Library", systemImage: "photo") { choosingPhoto = true }
            Button("Choose File", systemImage: "doc.badge.plus") { importingAttachment = true }
            Button(
              googleServices.isEmpty && connectorSelection.bindings.isEmpty
                ? "Connections" : "Connections · On", systemImage: "link"
            ) { showGoogleConnections = true }
          } label: {
            Image(systemName: "plus").frame(minWidth: 44, minHeight: 44)
          }
          .accessibilityLabel("Attachments and connections")
          .disabled(isComposerBusy || attachmentImportBusy || draftAttachments.count >= 4)

          if isComposerFocused {
            Button {
              isComposerFocused = false
            } label: {
              Image(systemName: "keyboard.chevron.compact.down")
            }
            .buttonStyle(.plain)
            .mosaicControlTarget()
            .accessibilityLabel("Dismiss keyboard")
          }
          Spacer(minLength: 0)

          if isRequestActive {
            Button(action: stopGeneration) {
              Image(systemName: "stop.fill")
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .mosaicControlTarget()
            .accessibilityLabel("Stop response")
          } else if liveTranscriptionState.isActive {
            Button(action: stopLiveTranscription) {
              if liveTranscriptionState == .connecting
                || liveTranscriptionState == .finishing
              {
                ProgressView()
                  .controlSize(.small)
                  .frame(width: 32, height: 32)
              } else {
                Image(systemName: "stop.fill")
                  .frame(width: 32, height: 32)
              }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .mosaicControlTarget()
            .id("live-transcription-control")
            .accessibilityLabel(liveTranscriptionStopAccessibilityLabel)
            .accessibilityHint("Keeps finalized words in the draft")
          } else {
            Button(action: startLiveTranscription) {
              Image(systemName: "mic.fill")
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .mosaicControlTarget()
            .id("live-transcription-control")
            .accessibilityLabel("Start live transcription")
            .accessibilityHint(
              "Uses an enabled Google Gemini connection and keeps text in the draft")

            Button(action: sendDraft) {
              Image(systemName: "arrow.up")
                .font(.body.bold())
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .mosaicControlTarget()
            .disabled(
              (conversation.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && draftAttachments.isEmpty) || attachmentImportBusy
                || activeModelConnection == nil
            )
            .accessibilityLabel("Send message")
            .keyboardShortcut(.return, modifiers: .command)
          }
        }
      }
      .padding(10)
      .background(
        .secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 24, style: .continuous)
      )

      if activeModelConnection == nil, !isComposerBusy {
        Button("Choose an enabled model") { showModelSelection = true }
          .font(.footnote).mosaicControlTarget()
      }
      if liveTranscriptionState.isActive {
        HStack(spacing: 7) {
          if liveTranscriptionState == .listening {
            Image(systemName: "waveform")
              .foregroundStyle(.red)
              .accessibilityHidden(true)
          }
          Text(liveTranscriptionStatusText)
          if let liveTranscriptionLanguageCode {
            Text(liveTranscriptionLanguageCode)
              .foregroundStyle(.tertiary)
              .accessibilityLabel("Detected language \(liveTranscriptionLanguageCode)")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: 860)
    .frame(maxWidth: .infinity)
  }

  private var requestReceipt: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        activeProviderPill
        projectPill
        Spacer(minLength: 12)
        memoryContextButton
      }

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          activeProviderPill
          projectPill
        }
        memoryContextButton
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
  }

  private var isRequestActive: Bool {
    requestPreparationTask != nil || generationTask != nil
      || requestRegistry.isActive(conversationID: conversation.id)
  }

  private var isComposerBusy: Bool {
    isRequestActive || liveTranscriptionState.isActive || attachmentImportBusy
  }

  private var composerText: Binding<String> {
    Binding(
      get: {
        joinedDraftText(conversation.draftText, liveInterimTranscript)
      },
      set: { newValue in
        guard !isComposerBusy else { return }
        conversation.draftText = newValue
      }
    )
  }

  private var liveTranscriptionProvider: ProviderConfigurationRecord? {
    let eligibleProviders = providers.filter(isEligibleLiveTranscriptionProvider)
    if let activeProvider,
      eligibleProviders.contains(where: { $0.id == activeProvider.id })
    {
      return activeProvider
    }
    return eligibleProviders.first
  }

  private var liveTranscriptionStopAccessibilityLabel: String {
    switch liveTranscriptionState {
    case .requestingPermission:
      "Cancel microphone permission request"
    case .connecting:
      "Cancel live transcription"
    case .listening:
      "Finish live transcription"
    case .finishing:
      "Cancel finishing transcription"
    case .idle:
      "Stop live transcription"
    }
  }

  private var liveTranscriptionStatusText: String {
    let providerName =
      liveTranscriptionProviderName.isEmpty
      ? ProviderKind.google.displayName : liveTranscriptionProviderName
    return switch liveTranscriptionState {
    case .idle:
      ""
    case .requestingPermission:
      "Waiting for microphone permission…"
    case .connecting:
      "Connecting to \(providerName)…"
    case .listening:
      "Listening with \(providerName). Text stays in the draft until you send it."
    case .finishing:
      "Finishing transcription with \(providerName)…"
    }
  }

  private var navigationModelButton: some View {
    Button {
      showModelSelection = true
    } label: {
      HStack(spacing: 5) {
        Text(conversation.modelIdentifier.isEmpty ? "Choose model" : conversation.modelIdentifier)
          .font(.headline)
          .lineLimit(1)
          .truncationMode(.middle)
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: 160)
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isComposerBusy || operationCoordinator.isSourceAccessBlocked)
    .accessibilityLabel("Choose model")
    .accessibilityValue(
      [activeProvider?.displayName, conversation.modelIdentifier].compactMap { $0 }.joined(
        separator: ", ")
    )
    .accessibilityHint("Choose any enabled model across your providers for the next message")
  }

  private var activeProviderPill: some View {
    Button {
      showModelSelection = true
    } label: {
      HStack(spacing: 5) {
        if let provider = activeProvider {
          ProviderPill(provider: provider.provider, model: conversation.modelIdentifier)
        } else {
          Text("Choose Model").font(.caption.weight(.medium))
        }
        Image(systemName: "chevron.down").font(.caption2)
      }
    }
    .buttonStyle(.plain)
    .mosaicControlTarget()
    .disabled(isComposerBusy || operationCoordinator.isSourceAccessBlocked)
    .accessibilityLabel("Choose model, \(conversation.modelIdentifier)")
  }

  @ViewBuilder
  private var projectPill: some View {
    if let currentProject {
      Label(currentProject.name, systemImage: "folder.fill")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityLabel("Project \(currentProject.name)")
    }
  }

  private var memoryContextButton: some View {
    Button {
      presentMemoryContext()
    } label: {
      if isCompactingContext {
        Label("Compressing history", systemImage: "rectangle.compress.vertical")
      } else if isRecallingContext || isLoadingStoredContextReceipt {
        Label("Searching memory", systemImage: "sparkle.magnifyingglass")
      } else {
        Label(
          advancedControls ? "\(contextItemCount) context items" : "Memory",
          systemImage: "brain.head.profile")
      }
    }
    .buttonStyle(.plain)
    .font(.caption)
    .foregroundStyle(Color.primary)
    .mosaicControlTarget()
    .accessibilityHint("Shows the exact saved and retrieved context used for the last request")
  }

  @ToolbarContentBuilder
  private var providerMenu: some ToolbarContent {
    ToolbarItem(id: "conversation-model", placement: .secondaryAction) {
      Button {
        showModelSelection = true
      } label: {
        Label("Choose Model", systemImage: "square.stack").labelStyle(.iconOnly)
      }
      .disabled(isComposerBusy || operationCoordinator.isSourceAccessBlocked)
      .mosaicControlTarget()
      .accessibilityHint("Choose any enabled model across your providers for the next message")
    }
    ToolbarItem(id: "conversation-delivery", placement: .secondaryAction) {
      Button("About this chat", systemImage: "info.circle") { showDeliveryDetails = true }
    }
  }

  @ToolbarContentBuilder
  private var projectMenu: some ToolbarContent {
    ToolbarItem(id: "conversation-project", placement: .secondaryAction) {
      Menu {
        ForEach(activeProjects) { project in
          Button {
            assignConversation(to: project.id)
          } label: {
            if currentProjectID == project.id {
              Label(project.name, systemImage: "checkmark")
            } else {
              Text(project.name)
            }
          }
        }
        if currentProjectID != nil {
          Divider()
          Button("Remove from Project", systemImage: "folder.badge.minus") {
            assignConversation(to: nil)
          }
        }
      } label: {
        Label(currentProject?.name ?? "Add to Project", systemImage: "folder")
      }
      .disabled(isComposerBusy || operationCoordinator.isSourceAccessBlocked)
      .mosaicControlTarget()
      .accessibilityHint("Changes which chats and documents this conversation can recall")
    }
  }

  private var activeProjects: [ProjectRecord] {
    projects.filter { !$0.isArchived }
  }

  private var currentProjectID: UUID? {
    projectBindings.first?.projectID
  }

  private var currentProject: ProjectRecord? {
    guard let currentProjectID else { return nil }
    return projects.first { $0.id == currentProjectID }
  }

  private var activeProvider: ProviderConfigurationRecord? {
    guard let providerID = conversation.providerConfigurationID else { return nil }
    return providers.first {
      $0.id == providerID && $0.isEnabled && $0.provider.supportsChat
    }
  }

  private var activeModelConnection: ProviderConnection? {
    guard let provider = activeProvider else { return nil }
    return try? ProviderModelStore.connection(
      provider: provider,
      modelIdentifier: conversation.modelIdentifier, models: providerModels)
  }

  private var recentMessageIDs: [UUID] {
    recentMessageRecords.map(\.id)
  }

  private var presentationRequest: ConversationPresentationRequest {
    ConversationPresentationRequest(
      conversationID: conversation.id,
      sourceStoreGenerationRevision: operationCoordinator.sourceStoreGenerationRevision,
      projectCatalogRevision: operationCoordinator.projectCatalogRevision
    )
  }

  private var displayedTranscriptMessages: [MosaicTranscriptMessage] {
    guard
      loadedTranscriptSourceGeneration == operationCoordinator.sourceStoreGenerationRevision
    else {
      return []
    }
    var headByID = Dictionary(
      transcriptHeadPage.map { ($0.id, $0) },
      uniquingKeysWith: { _, latest in latest }
    )
    if allowsLiveTranscriptOverlay {
      for record in recentMessageRecords where headByID[record.id] != nil {
        headByID[record.id] = MosaicTranscriptMessage(record)
      }
    }
    let boundedHead = Array(
      headByID.values.sorted(by: transcriptPrecedes).suffix(Self.transcriptPageSize))

    var allByID = Dictionary(
      olderTranscriptMessages.map { ($0.id, $0) },
      uniquingKeysWith: { _, latest in latest }
    )
    for message in boundedHead { allByID[message.id] = message }
    return allByID.values.sorted(by: transcriptPrecedes)
  }

  private func transcriptPrecedes(
    _ lhs: MosaicTranscriptMessage,
    _ rhs: MosaicTranscriptMessage
  ) -> Bool {
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    let lhsRoleRank = lhs.role == .user ? 0 : 1
    let rhsRoleRank = rhs.role == .user ? 0 : 1
    if lhsRoleRank != rhsRoleRank { return lhsRoleRank < rhsRoleRank }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private func loadConversationPresentation() async {
    guard !Task.isCancelled else { return }
    await reconcileInterruptedCompactionAudits()
    guard !Task.isCancelled else { return }
    let sourceStoreGeneration = operationCoordinator.sourceStoreGenerationRevision
    if loadedTranscriptSourceGeneration != sourceStoreGeneration {
      loadedTranscriptSourceGeneration = nil
      allowsLiveTranscriptOverlay = false
      transcriptHeadPage = []
      olderTranscriptMessages = []
      transcriptCursor = nil
      transcriptHasMore = false
      followsLatestMessage = true
    }
    curatedMemoryContext = .empty
    memoryRefreshTask?.cancel()
    memoryRefreshTask = nil
    let curatedRequestID = UUID()
    curatedMemoryRequestID = curatedRequestID
    invalidateCachedContextReceipt()
    let snapshotRequestID = beginTranscriptSnapshotRequest()
    await resetTranscriptSnapshot(
      requestID: snapshotRequestID,
      sourceStoreGeneration: sourceStoreGeneration,
      enableLiveOverlayOnApply: true
    )
    finishTranscriptSnapshotRequest(snapshotRequestID)
    do {
      let repository = MosaicConversationReadRepository(modelContainer: modelContext.container)
      let context = try await repository.curatedMemoryContext(
        conversationID: conversation.id
      )
      try Task.checkCancellation()
      guard curatedMemoryRequestID == curatedRequestID else { return }
      curatedMemoryContext = context
      curatedMemoryRequestID = nil
      if showMemoryContext { presentMemoryContext() }
    } catch is CancellationError {
      if curatedMemoryRequestID == curatedRequestID {
        curatedMemoryRequestID = nil
      }
      return
    } catch {
      guard curatedMemoryRequestID == curatedRequestID else { return }
      curatedMemoryRequestID = nil
      persistenceError = error.localizedDescription
    }
  }

  private func scheduleTranscriptSnapshotReset() {
    let requestID = beginTranscriptSnapshotRequest()
    let sourceStoreGeneration = operationCoordinator.sourceStoreGenerationRevision
    transcriptSnapshotTask = Task { @MainActor in
      defer {
        if transcriptSnapshotRequestID == requestID {
          transcriptSnapshotTask = nil
          finishTranscriptSnapshotRequest(requestID)
        }
      }
      await resetTranscriptSnapshot(
        requestID: requestID,
        sourceStoreGeneration: sourceStoreGeneration,
        enableLiveOverlayOnApply: true
      )
    }
  }

  private func beginTranscriptSnapshotRequest() -> UUID {
    transcriptSnapshotTask?.cancel()
    transcriptSnapshotTask = nil
    transcriptPagingTask?.cancel()
    transcriptPagingTask = nil
    transcriptPagingID = nil
    let requestID = UUID()
    transcriptSnapshotRequestID = requestID
    isLoadingTranscript = true
    return requestID
  }

  private func finishTranscriptSnapshotRequest(_ requestID: UUID) {
    guard transcriptSnapshotRequestID == requestID else { return }
    transcriptSnapshotRequestID = nil
    isLoadingTranscript = false
  }

  private func resetTranscriptSnapshot(
    requestID: UUID,
    sourceStoreGeneration: UInt64,
    enableLiveOverlayOnApply: Bool
  ) async {
    do {
      let repository = MosaicConversationReadRepository(modelContainer: modelContext.container)
      let page = try await repository.transcriptPage(
        conversationID: conversation.id,
        pageSize: Self.transcriptPageSize
      )
      try Task.checkCancellation()
      guard transcriptSnapshotRequestID == requestID,
        operationCoordinator.sourceStoreGenerationRevision == sourceStoreGeneration
      else {
        return
      }
      if loadedTranscriptSourceGeneration == sourceStoreGeneration {
        // New messages refresh the head, but must not discard pages the reader opened.
        let refreshedIDs = Set(page.messages.map(\.id))
        olderTranscriptMessages = (olderTranscriptMessages + transcriptHeadPage)
          .filter { !refreshedIDs.contains($0.id) }
      } else {
        olderTranscriptMessages = []
        transcriptCursor = page.nextCursor
        transcriptHasMore = page.hasMore
      }
      transcriptHeadPage = page.messages
      loadedTranscriptSourceGeneration = sourceStoreGeneration
      allowsLiveTranscriptOverlay = enableLiveOverlayOnApply
    } catch is CancellationError {
      return
    } catch {
      guard transcriptSnapshotRequestID == requestID,
        operationCoordinator.sourceStoreGenerationRevision == sourceStoreGeneration
      else {
        return
      }
      persistenceError = error.localizedDescription
    }
  }

  private func loadEarlierTranscriptPage() {
    guard transcriptSnapshotRequestID == nil,
      transcriptPagingTask == nil,
      transcriptHasMore,
      let transcriptCursor
    else {
      return
    }
    let pagingID = UUID()
    transcriptPagingID = pagingID
    isLoadingTranscript = true
    transcriptPagingTask = Task { @MainActor in
      defer {
        if transcriptPagingID == pagingID {
          isLoadingTranscript = false
          transcriptPagingTask = nil
          transcriptPagingID = nil
        }
      }
      do {
        let repository = MosaicConversationReadRepository(modelContainer: modelContext.container)
        let page = try await repository.transcriptPage(
          conversationID: conversation.id,
          before: transcriptCursor,
          pageSize: Self.transcriptPageSize
        )
        try Task.checkCancellation()
        guard transcriptPagingID == pagingID else { return }
        let existingIDs = Set(displayedTranscriptMessages.map(\.id))
        olderTranscriptMessages =
          page.messages.filter { !existingIDs.contains($0.id) } + olderTranscriptMessages
        self.transcriptCursor = page.nextCursor
        transcriptHasMore = page.hasMore
      } catch is CancellationError {
        return
      } catch {
        guard transcriptPagingID == pagingID else { return }
        persistenceError = error.localizedDescription
      }
    }
  }

  private var contextItemCount: Int {
    displayedContextReceipt.curatedContext.includedMemories.count
      + displayedContextReceipt.retrievedContext.items.count
      + (displayedContextReceipt.projectContext == nil ? 0 : 1)
      + (displayedContextReceipt.conversationContext == nil ? 0 : 1)
      + (displayedContextReceipt.sameConversationRecall == nil ? 0 : 1)
      + (displayedContextReceipt.conversationCompaction == nil ? 0 : 1)
  }

  private var displayedContextReceipt: RequestContextReceipt {
    if receiptAssistantMessageID == newestAssistantMessageID {
      if let lastContextReceipt { return lastContextReceipt }
      if let storedContextReceipt { return storedContextReceipt }
    }
    return RequestContextReceipt(
      curatedContext: curatedMemoryContext,
      retrievedContext: .empty,
      projectContext: currentProjectReceipt
    )
  }

  private var newestAssistantMessageID: UUID? {
    displayedTranscriptMessages.last(where: { $0.role == .assistant })?.id
  }

  private func invalidateCachedContextReceipt() {
    storedContextReceiptTask?.cancel()
    storedContextReceiptTask = nil
    storedContextReceiptTaskID = nil
    storedContextReceipt = nil
    lastContextReceipt = nil
    receiptAssistantMessageID = nil
    isLoadingStoredContextReceipt = false
  }

  private func presentMemoryContext() {
    showMemoryContext = true
    guard storedContextReceiptTask == nil,
      let assistant = displayedTranscriptMessages.last(where: { $0.role == .assistant })
    else {
      return
    }
    if receiptAssistantMessageID == assistant.id,
      lastContextReceipt != nil || storedContextReceipt != nil
    {
      return
    }
    invalidateCachedContextReceipt()
    let taskID = UUID()
    let sourceStoreGeneration = operationCoordinator.sourceStoreGenerationRevision
    let contextReceiptRevision = operationCoordinator.contextReceiptRevision
    storedContextReceiptTaskID = taskID
    isLoadingStoredContextReceipt = true
    storedContextReceiptTask = Task { @MainActor in
      defer {
        if storedContextReceiptTaskID == taskID {
          isLoadingStoredContextReceipt = false
          storedContextReceiptTask = nil
          storedContextReceiptTaskID = nil
        }
      }
      do {
        let repository = MosaicConversationReadRepository(modelContainer: modelContext.container)
        let state = try await repository.canonicalState(conversationID: conversation.id)
        try Task.checkCancellation()
        guard operationCoordinator.sourceStoreGenerationRevision == sourceStoreGeneration,
          operationCoordinator.contextReceiptRevision == contextReceiptRevision,
          storedContextReceiptTaskID == taskID,
          newestAssistantMessageID == assistant.id
        else {
          return
        }
        let contextStore = NormalizedContextStore(modelContext: modelContext)
        storedContextReceipt = try contextStore.requestReceipt(
          assistantMessageID: assistant.id,
          conversationID: conversation.id,
          canonicalMessages: state.messages,
          legacyReceiptData: assistant.contextReceiptData,
          legacyCompactionSnapshotData: conversation.compactionSnapshotData
        )
        if storedContextReceipt == nil {
          storedContextReceipt = RequestContextReceipt(
            curatedContext: curatedMemoryContext,
            retrievedContext: RetrievedContext(
              systemContent: "",
              items: [],
              warnings: [
                "The latest assistant attempt has no verified context receipt. Turing AI did not substitute an older request’s receipt."
              ]
            )
          )
        }
        receiptAssistantMessageID = assistant.id
      } catch is CancellationError {
        return
      } catch {
        guard operationCoordinator.sourceStoreGenerationRevision == sourceStoreGeneration,
          operationCoordinator.contextReceiptRevision == contextReceiptRevision,
          storedContextReceiptTaskID == taskID,
          newestAssistantMessageID == assistant.id
        else {
          return
        }
        storedContextReceipt = RequestContextReceipt(
          curatedContext: curatedMemoryContext,
          retrievedContext: RetrievedContext(
            systemContent: "",
            items: [],
            warnings: [
              "Turing AI could not verify the latest context receipt, so it was not used."
            ]
          )
        )
        receiptAssistantMessageID = assistant.id
      }
    }
  }

  private func deliveryDisclosure(for chatProvider: ProviderConfigurationRecord) -> String {
    let chatHost = resolvedHost(for: chatProvider) ?? chatProvider.displayName
    let destinations =
      embeddingProfiles
      .filter(\.isEnabled)
      .prefix(4)
      .compactMap { profile -> String? in
        guard let providerID = profile.providerConfigurationID,
          let provider = providers.first(where: { $0.id == providerID && $0.isEnabled })
        else { return nil }
        let host = resolvedHost(for: provider) ?? provider.displayName
        return "\(profile.displayName) at \(host)"
      }
    if destinations.isEmpty {
      return
        "Chat goes directly to \(chatHost). When a chat gets long, Turing AI may first use the selected model for one extra history-summary request. AI output can contain mistakes."
    }
    let uniqueDestinations = Array(Set(destinations)).sorted().joined(separator: ", ")
    return
      "Chat goes to \(chatHost). Long chats may use that selected model for one extra history-summary request. Automatic recall also sends the query and selected excerpts to \(uniqueDestinations). AI output can contain mistakes."
  }

  private func isEligibleLiveTranscriptionProvider(
    _ provider: ProviderConfigurationRecord
  ) -> Bool {
    guard provider.isEnabled,
      provider.provider == .google,
      provider.provider.supportsLiveTranscription,
      let destination = provider.baseURL ?? provider.provider.defaultBaseURL,
      destination.scheme?.lowercased() == "https",
      destination.host?.lowercased() == "generativelanguage.googleapis.com"
    else {
      return false
    }
    return destination.port == nil || destination.port == 443
  }

  private func startLiveTranscription() {
    guard !isComposerBusy else { return }
    liveTranscriptionError = nil
    guard let providerRecord = liveTranscriptionProvider else {
      liveTranscriptionError =
        "Add and enable a Google Gemini connection with its official API endpoint before using live transcription."
      return
    }

    let permissionRequestID = UUID()
    let providerID = providerRecord.id
    liveTranscriptionPermissionRequestID = permissionRequestID
    liveTranscriptionProviderName = providerRecord.displayName
    liveTranscriptionState = .requestingPermission
    liveTranscriptionPermissionTask = Task { @MainActor in
      defer {
        if liveTranscriptionPermissionRequestID == permissionRequestID {
          liveTranscriptionPermissionTask = nil
          liveTranscriptionPermissionRequestID = nil
          if liveTranscriptionState == .requestingPermission {
            liveTranscriptionState = .idle
            liveTranscriptionProviderName = ""
          }
        }
      }

      do {
        try await LiveMicrophoneAudioSource.requestPermission()
        try Task.checkCancellation()
        guard liveTranscriptionPermissionRequestID == permissionRequestID else {
          throw CancellationError()
        }
        guard
          let refreshedProvider = providers.first(where: { $0.id == providerID }),
          isEligibleLiveTranscriptionProvider(refreshedProvider)
        else {
          liveTranscriptionError =
            "The Google Gemini connection changed while Turing AI was waiting for microphone permission. Review the connection and try again."
          return
        }
        beginAuthorizedLiveTranscription(with: refreshedProvider)
      } catch is CancellationError {
        return
      } catch {
        guard liveTranscriptionPermissionRequestID == permissionRequestID else { return }
        liveTranscriptionError = ProviderErrorSanitizer.description(for: error, redacting: nil)
      }
    }
  }

  private func beginAuthorizedLiveTranscription(
    with providerRecord: ProviderConfigurationRecord
  ) {
    let operationID = MosaicOperationID.liveTranscription(conversation.id)
    guard MosaicOperationCoordinator.shared.begin(operationID) else {
      liveTranscriptionError = requestOperationUnavailableDescription
      return
    }

    let requestID = UUID()
    let provider = ProviderConnection(configuration: providerRecord)
    liveTranscriptionRequestID = requestID
    liveTranscriptionProviderName =
      "\(provider.displayName) at \(provider.resolvedBaseURL?.host ?? "Google")"
    liveTranscriptionLanguageCode = nil
    liveInterimTranscript = ""
    liveTranscriptionState = .connecting

    liveTranscriptionTask = Task { @MainActor in
      defer {
        MosaicOperationCoordinator.shared.end(operationID)
        if liveTranscriptionRequestID == requestID {
          liveTranscriptionTask = nil
          liveTranscriptionRequestID = nil
          liveTranscriptionSession = nil
          liveMicrophoneSource = nil
          liveTranscriptionState = .idle
          liveTranscriptionProviderName = ""
          liveInterimTranscript = ""
          liveTranscriptionLanguageCode = nil
          flushDraftPersistenceImmediately()
        }
        liveTranscriptionBackgroundDrainLease.end()
      }
      await runLiveTranscription(provider: provider, requestID: requestID)
    }
  }

  private func runLiveTranscription(
    provider: ProviderConnection,
    requestID: UUID
  ) async {
    var apiKeyForRedaction: String?
    var session: (any LiveTranscriptionSession)?
    var microphoneSource: LiveMicrophoneAudioSource?
    var audioSender: Task<Void, Never>?
    var reachedDurationLimit = false
    var providerRequestedClose = false

    do {
      let apiKey = try await SecurityKeychain.shared.apiKey(
        for: provider.id,
        expectedBinding: provider.credentialBinding
      )
      apiKeyForRedaction = apiKey
      try Task.checkCancellation()
      guard liveTranscriptionRequestID == requestID else { throw CancellationError() }

      let configuration = try LiveTranscriptionConfiguration(mode: .smart)
      let connectedSession = try await GeminiLiveTranscriptionClient().connect(
        apiKey: apiKey ?? "",
        configuration: configuration
      )
      session = connectedSession
      try Task.checkCancellation()
      guard liveTranscriptionRequestID == requestID else { throw CancellationError() }
      liveTranscriptionSession = connectedSession

      let events = await connectedSession.eventStream()
      var eventIterator = events.makeAsyncIterator()
      var didCompleteSetup = false
      while let event = try await eventIterator.next() {
        try Task.checkCancellation()
        guard liveTranscriptionRequestID == requestID else { throw CancellationError() }
        if case .setupComplete = event {
          didCompleteSetup = true
          break
        }
      }
      try ConversationLiveTranscriptionSetupValidation.validate(
        didCompleteSetup: didCompleteSetup
      )

      let source = LiveMicrophoneAudioSource()
      microphoneSource = source
      liveMicrophoneSource = source
      let audioStream = try await source.start()
      try Task.checkCancellation()
      guard liveTranscriptionRequestID == requestID else { throw CancellationError() }
      liveTranscriptionState = .listening

      let failureStore = LiveTranscriptionFailureStore()
      audioSender = Task {
        do {
          for try await chunk in audioStream {
            try Task.checkCancellation()
            try await connectedSession.send(chunk)
          }
          try Task.checkCancellation()
          let finalization = try await connectedSession.endAudio()
          if finalization.mayHaveUnconfirmedWords {
            await failureStore.record(LiveTranscriptionError.finalizationTimedOut)
          }
          await connectedSession.cancel()
        } catch is CancellationError {
          await connectedSession.cancel()
        } catch {
          await failureStore.record(error)
          await connectedSession.cancel()
        }
      }

      let baseDraft = conversation.draftText
      var lastAppliedDraft = baseDraft
      var assembler = LiveTranscriptAssembler()
      while let event = try await eventIterator.next() {
        try Task.checkCancellation()
        guard liveTranscriptionRequestID == requestID else { throw CancellationError() }
        let snapshot = try assembler.consume(event)
        try applyLiveTranscriptSnapshot(
          snapshot,
          baseDraft: baseDraft,
          lastAppliedDraft: &lastAppliedDraft
        )

        switch event {
        case .durationLimitApproaching:
          reachedDurationLimit = true
          if liveTranscriptionState == .listening {
            protectLiveTranscriptionFinalizationIfNeeded()
            liveTranscriptionState = .finishing
            await microphoneSource?.stop()
          }
        case .goAway:
          providerRequestedClose = true
          if liveTranscriptionState == .listening {
            protectLiveTranscriptionFinalizationIfNeeded()
            liveTranscriptionState = .finishing
            await microphoneSource?.stop()
          }
        case .ended(reason: .durationLimitReached):
          reachedDurationLimit = true
        default:
          break
        }
      }

      if let senderError = await failureStore.recordedError() {
        throw senderError
      }
      if reachedDurationLimit {
        liveTranscriptionError =
          "Turing AI ended this recording before Gemini Live’s 10-minute session limit. Finalized text remains in your draft; start the microphone again to continue."
      } else if providerRequestedClose {
        liveTranscriptionError =
          "Gemini Live asked to close this connection. Finalized text remains in your draft; start the microphone again to continue."
      }
    } catch is CancellationError {
      // Explicit cancellation keeps finalized text and intentionally discards speculative text.
    } catch {
      liveTranscriptionError = ProviderErrorSanitizer.description(
        for: error,
        redacting: apiKeyForRedaction
      )
    }

    audioSender?.cancel()
    await microphoneSource?.stop()
    await session?.cancel()
  }

  private func applyLiveTranscriptSnapshot(
    _ snapshot: LiveTranscriptSnapshot,
    baseDraft: String,
    lastAppliedDraft: inout String
  ) throws {
    guard conversation.draftText == lastAppliedDraft else {
      throw LiveTranscriptionError.transport(
        "The draft changed in another window, so live transcription stopped without overwriting it."
      )
    }
    let finalizedDraft = joinedDraftText(baseDraft, snapshot.finalizedText)
    let displayedDraft = joinedDraftText(finalizedDraft, snapshot.interimText ?? "")
    let displayedBytes = displayedDraft.utf8.count
    guard displayedBytes <= MosaicSourceFieldLimits.maximumConversationDraftUTF8Bytes else {
      throw MosaicSourceFieldLimitError.conversationDraft(
        actual: displayedBytes,
        maximum: MosaicSourceFieldLimits.maximumConversationDraftUTF8Bytes
      )
    }
    if conversation.draftText != finalizedDraft {
      conversation.draftText = finalizedDraft
      lastAppliedDraft = finalizedDraft
    }
    liveInterimTranscript = snapshot.interimText ?? ""
    liveTranscriptionLanguageCode = snapshot.languageCode
  }

  private func stopLiveTranscription() {
    switch liveTranscriptionState {
    case .requestingPermission:
      cancelLiveTranscriptionPermissionRequest()
    case .listening:
      protectLiveTranscriptionFinalizationIfNeeded()
      liveTranscriptionState = .finishing
      let source = liveMicrophoneSource
      Task { await source?.stop() }
    case .connecting, .finishing:
      cancelLiveTranscription()
    case .idle:
      break
    }
  }

  private func handleLiveTranscriptionLifecycle(
    _ trigger: ConversationLiveTranscriptionLifecycleTrigger
  ) {
    switch liveTranscriptionState.lifecycleAction(for: trigger) {
    case .finishRecording:
      protectLiveTranscriptionFinalizationIfNeeded()
      liveTranscriptionState = .finishing
      let source = liveMicrophoneSource
      Task { await source?.stop() }
    case .protectFinalization:
      protectLiveTranscriptionFinalizationIfNeeded()
    case .cancelSession:
      cancelLiveTranscription()
    case .cancelPermissionRequest:
      cancelLiveTranscriptionPermissionRequest()
    case .none:
      break
    }
  }

  private func protectLiveTranscriptionFinalizationIfNeeded() {
    #if os(iOS)
      guard let requestID = liveTranscriptionRequestID else { return }
      let acquired = liveTranscriptionBackgroundDrainLease.begin { @MainActor in
        guard liveTranscriptionRequestID == requestID else { return }
        liveTranscriptionError =
          LiveTranscriptionError.backgroundFinalizationExpired.localizedDescription
        cancelLiveTranscription()
        flushDraftPersistenceImmediately()
      }
      if !acquired, scenePhase == .background,
        liveTranscriptionRequestID == requestID
      {
        liveTranscriptionError =
          LiveTranscriptionError.backgroundFinalizationExpired.localizedDescription
        cancelLiveTranscription()
        flushDraftPersistenceImmediately()
      }
    #endif
  }

  private func cancelLiveTranscriptionPermissionRequest() {
    guard liveTranscriptionPermissionTask != nil || liveTranscriptionPermissionRequestID != nil
    else { return }
    liveTranscriptionPermissionRequestID = nil
    liveTranscriptionPermissionTask?.cancel()
    liveTranscriptionPermissionTask = nil
    if liveTranscriptionState == .requestingPermission {
      liveTranscriptionState = .idle
      liveTranscriptionProviderName = ""
    }
  }

  private func cancelLiveTranscription() {
    if liveTranscriptionState == .requestingPermission {
      cancelLiveTranscriptionPermissionRequest()
      return
    }
    guard liveTranscriptionState.isActive || liveTranscriptionTask != nil else { return }
    liveTranscriptionState = .finishing
    liveInterimTranscript = ""
    liveTranscriptionTask?.cancel()
    let source = liveMicrophoneSource
    let session = liveTranscriptionSession
    Task {
      await source?.stop()
      await session?.cancel()
    }
  }

  private func joinedDraftText(_ existing: String, _ addition: String) -> String {
    guard !existing.isEmpty else { return addition }
    guard !addition.isEmpty else { return existing }
    guard existing.last?.isWhitespace != true else { return existing + addition }

    let punctuationWithoutLeadingSpace = CharacterSet(charactersIn: ",.;:!?%…)]}")
    if let firstScalar = addition.unicodeScalars.first,
      punctuationWithoutLeadingSpace.contains(firstScalar)
    {
      return existing + addition
    }
    return existing + " " + addition
  }

  private func announceLiveTranscriptionState(
    _ state: ConversationLiveTranscriptionState,
    previousState: ConversationLiveTranscriptionState
  ) {
    let announcement: String
    switch state {
    case .requestingPermission:
      announcement = "Waiting for microphone permission."
    case .connecting:
      announcement = "Connecting live transcription."
    case .listening:
      announcement = "Live transcription started. Microphone is listening."
    case .finishing:
      announcement = "Finishing live transcription."
    case .idle:
      guard previousState != .idle else { return }
      announcement = "Live transcription stopped."
    }
    AccessibilityNotification.Announcement(announcement).post()
  }

  private var selectedModelSupportsImages: Bool {
    guard let provider = activeProvider else { return false }
    let choice = ChatModelChoice(
      providerID: provider.id, providerName: provider.displayName, providerKind: provider.provider,
      modelIdentifier: conversation.modelIdentifier)
    let preference = experienceRecords.compactMap {
      try? JSONDecoder().decode(ExperienceValue.self, from: $0.payload)
    }.first { $0.kind == .model && $0.selectionKey == choice.id }
    return ModelImageCapability.supports(choice, preference: preference)
  }
  private func imagesForRequest(_ messages: [AIChatMessage]) throws -> [UUID: [ChatImageInput]] {
    let ids = messages.map { Optional($0.id) }
    var descriptor = FetchDescriptor<ExperienceRecord>(
      predicate: #Predicate { $0.category == "attachment" && ids.contains($0.messageID) })
    descriptor.fetchLimit = 65
    let rows = try modelContext.fetch(descriptor)
    guard rows.count <= 64 else {
      throw ChatAttachmentFailure(
        message:
          "Too many attachments in the active context. Start a new chat or shorten the context.")
    }
    let attachments = try rows.map {
      try JSONDecoder().decode(ExperienceValue.self, from: $0.payload)
    }
    var result: [UUID: [ChatImageInput]] = [:]
    for attachment in attachments where attachment.isImage {
      guard let messageID = attachment.messageID, ids.contains(messageID),
        let bytes = attachment.bytes
      else { continue }
      guard selectedModelSupportsImages else {
        throw ChatAttachmentFailure(
          message: "This chat contains photos. Choose a photo-capable model before continuing.")
      }
      result[messageID, default: []].append(ChatImageInput(mimeType: "image/jpeg", data: bytes))
    }
    return result
  }
  private func removeAttachment(_ id: UUID) {
    guard !isComposerBusy else { return }
    do {
      try ExperienceStore.remove(id, in: modelContext)
      _ = saveOrReport()
    } catch { persistenceError = error.localizedDescription }
  }
  private func saveAttachment(_ value: ExperienceValue) throws {
    guard draftAttachments.count < 4, !operationCoordinator.isSourceAccessBlocked else {
      throw ChatAttachmentFailure(
        message:
          "Wait for the current operation, or remove an attachment. A message can contain four attachments."
      )
    }
    do {
      try ExperienceStore.save(value, in: modelContext)
      conversation.updatedAt = .now
      try operationCoordinator.saveSourceChanges(in: modelContext)
    } catch {
      modelContext.rollback()
      throw error
    }
  }
  private func importAttachment(_ url: URL) {
    guard !attachmentImportBusy, !isComposerBusy else { return }
    let lease = MosaicOperationID.chatAttachmentImport(conversation.id)
    guard operationCoordinator.begin(lease) else { return }
    attachmentImportBusy = true
    let id = conversation.id
    let generation = operationCoordinator.sourceStoreGenerationRevision
    Task { @MainActor in
      defer {
        attachmentImportBusy = false
        operationCoordinator.end(lease)
      }
      do {
        let value = try await Task.detached {
          try ChatAttachmentStore.importFile(url, conversationID: id)
        }.value
        guard generation == operationCoordinator.sourceStoreGenerationRevision else {
          throw ConversationCompactionError.staleSource
        }
        try saveAttachment(value)
      } catch { persistenceError = error.localizedDescription }
    }
  }
  private func importPhoto(_ item: PhotosPickerItem) {
    guard !attachmentImportBusy, !isComposerBusy else { return }
    let lease = MosaicOperationID.chatAttachmentImport(conversation.id)
    guard operationCoordinator.begin(lease) else { return }
    attachmentImportBusy = true
    let id = conversation.id
    let generation = operationCoordinator.sourceStoreGenerationRevision
    Task { @MainActor in
      defer {
        attachmentImportBusy = false
        pickedPhoto = nil
        operationCoordinator.end(lease)
      }
      do {
        guard let data = try await item.loadTransferable(type: Data.self) else {
          throw ChatAttachmentFailure(message: "The photo could not be opened.")
        }
        let value = try await Task.detached {
          try ChatAttachmentStore.photo(data, filename: "Photo.jpg", conversationID: id)
        }.value
        guard generation == operationCoordinator.sourceStoreGenerationRevision else {
          throw ConversationCompactionError.staleSource
        }
        try saveAttachment(value)
      } catch { persistenceError = error.localizedDescription }
    }
  }

  private func sendDraft() {
    guard !isComposerBusy, activeProvider != nil else { return }
    isComposerFocused = false
    if webSearch, activeModelConnection.map({ !WebSearchCapability.supports($0) }) ?? true {
      persistenceError = "Turn off Web search or choose a supported OpenAI or Claude model."
      return
    }
    let originalDraft = conversation.draftText
    let pendingAttachments = draftAttachments
    let text = ChatAttachmentStore.messageContent(
      text: originalDraft.trimmingCharacters(in: .whitespacesAndNewlines),
      attachments: pendingAttachments)
    guard !text.isEmpty, !attachmentImportBusy else { return }
    if pendingAttachments.contains(where: \.isImage), !selectedModelSupportsImages {
      persistenceError =
        "Choose a model that supports photos, or mark its photo capability in the model picker."
      return
    }
    do {
      try MosaicSourceFieldLimits.validateMessageContent(text)
    } catch {
      persistenceError = error.localizedDescription
      return
    }
    let operationID = MosaicOperationID.conversationRequest(conversation.id)
    guard MosaicOperationCoordinator.shared.begin(operationID) else {
      persistenceError = requestOperationUnavailableDescription
      return
    }
    followsLatestMessage = true
    let requestID = UUID()
    let preparationTask = Task { @MainActor in
      var transferredOperationLease = false
      defer {
        requestPreparationTask = nil
        if !transferredOperationLease {
          requestRegistry.finish(conversationID: conversation.id, requestID: requestID)
          MosaicOperationCoordinator.shared.end(operationID)
        }
      }
      do {
        let repository = MosaicConversationReadRepository(modelContainer: modelContext.container)
        let state = try await repository.canonicalState(conversationID: conversation.id)
        try Task.checkCancellation()
        guard conversation.draftText == originalDraft else { return }
        conversation.draftText = ""
        if send(
          text,
          previousMessages: state.messages,
          operationID: operationID,
          requestID: requestID
        ) {
          transferredOperationLease = true
        } else {
          conversation.draftText = originalDraft
        }
      } catch is CancellationError {
        return
      } catch {
        persistenceError = error.localizedDescription
      }
    }
    requestPreparationTask = preparationTask
    if !requestRegistry.register(
      conversationID: conversation.id,
      requestID: requestID,
      cancel: { preparationTask.cancel() }
    ) {
      preparationTask.cancel()
      persistenceError = requestOperationUnavailableDescription
    }
  }

  @discardableResult
  private func send(
    _ text: String,
    previousMessages: [AIChatMessage],
    operationID: MosaicOperationID,
    requestID: UUID
  ) -> Bool {
    guard generationTask == nil, let provider = activeModelConnection else { return false }

    let userMessage = MessageRecord(
      conversationID: conversation.id,
      role: .user,
      content: text,
      providerConfigurationID: provider.id,
      providerKind: provider.provider,
      providerDisplayName: provider.displayName,
      providerHost: provider.resolvedBaseURL?.host,
      modelIdentifier: provider.modelIdentifier
    )
    let assistantMessage = MessageRecord(
      conversationID: conversation.id,
      role: .assistant,
      content: "",
      status: .streaming,
      providerConfigurationID: provider.id,
      providerKind: provider.provider,
      providerDisplayName: provider.displayName,
      providerHost: provider.resolvedBaseURL?.host,
      modelIdentifier: provider.modelIdentifier
    )
    do {
      let choice = ChatModelChoice(
        providerID: provider.id, providerName: provider.displayName,
        providerKind: provider.provider, modelIdentifier: provider.modelIdentifier)
      var preference =
        try ExperienceStore.preferences(in: modelContext).first {
          $0.kind == .model && $0.selectionKey == choice.id
        } ?? .preference(choice)
      preference.lastUsed = .now
      preference.updatedAt = .now
      try ExperienceStore.save(preference, in: modelContext)
      for var attachment in draftAttachments {
        attachment.messageID = userMessage.id
        attachment.updatedAt = .now
        try ExperienceStore.save(attachment, in: modelContext)
      }
    } catch {
      modelContext.rollback()
      persistenceError = error.localizedDescription
      return false
    }
    modelContext.insert(userMessage)
    modelContext.insert(assistantMessage)
    conversation.providerConfigurationID = provider.id
    conversation.modelIdentifier = provider.modelIdentifier
    conversation.updatedAt = .now
    if previousMessages.isEmpty || conversation.title == "New conversation" {
      conversation.title = compactTitle(
        ChatAttachmentStore.displayText(text).isEmpty
          ? (draftAttachments.first?.filename ?? "Attachment")
          : ChatAttachmentStore.displayText(text))
    }
    guard saveOrReport() else { return false }

    let requestMessages =
      previousMessages + [
        AIChatMessage(id: userMessage.id, role: .user, content: userMessage.content)
      ]

    startGeneration(
      provider: provider,
      assistantMessage: assistantMessage,
      requestMessages: requestMessages,
      recallQuery: text,
      operationID: operationID,
      requestID: requestID
    )
    return true
  }

  private func retry(_ assistantMessage: MosaicTranscriptMessage) {
    guard !isComposerBusy,
      assistantMessage.role == .assistant,
      assistantMessage.status == .failed,
      activeProvider != nil
    else {
      return
    }
    let operationID = MosaicOperationID.conversationRequest(conversation.id)
    guard MosaicOperationCoordinator.shared.begin(operationID) else {
      persistenceError = requestOperationUnavailableDescription
      return
    }
    let requestID = UUID()
    let preparationTask = Task { @MainActor in
      var transferredOperationLease = false
      defer {
        requestPreparationTask = nil
        if !transferredOperationLease {
          requestRegistry.finish(conversationID: conversation.id, requestID: requestID)
          MosaicOperationCoordinator.shared.end(operationID)
        }
      }
      do {
        let repository = MosaicConversationReadRepository(modelContainer: modelContext.container)
        let requestMessages = try await repository.completedMessages(
          conversationID: conversation.id,
          before: assistantMessage.id
        )
        try Task.checkCancellation()
        guard requestMessages.last?.role == .user, let provider = activeModelConnection else {
          return
        }
        let retryMessage = MessageRecord(
          conversationID: conversation.id,
          role: .assistant,
          content: "",
          status: .streaming,
          providerConfigurationID: provider.id,
          providerKind: provider.provider,
          providerDisplayName: provider.displayName,
          providerHost: provider.resolvedBaseURL?.host,
          modelIdentifier: provider.modelIdentifier
        )
        modelContext.insert(retryMessage)
        conversation.providerConfigurationID = provider.id
        conversation.modelIdentifier = provider.modelIdentifier
        conversation.updatedAt = .now
        guard saveOrReport() else { return }

        startGeneration(
          provider: provider,
          assistantMessage: retryMessage,
          requestMessages: requestMessages,
          recallQuery: requestMessages.last?.content ?? "",
          allowNewCompaction: false,
          operationID: operationID,
          requestID: requestID
        )
        transferredOperationLease = true
      } catch is CancellationError {
        return
      } catch {
        persistenceError = error.localizedDescription
      }
    }
    requestPreparationTask = preparationTask
    if !requestRegistry.register(
      conversationID: conversation.id,
      requestID: requestID,
      cancel: { preparationTask.cancel() }
    ) {
      preparationTask.cancel()
      persistenceError = requestOperationUnavailableDescription
    }
  }

  private func startGeneration(
    provider: ProviderConnection,
    assistantMessage: MessageRecord,
    requestMessages: [AIChatMessage],
    recallQuery: String,
    allowNewCompaction: Bool = true,
    operationID: MosaicOperationID,
    requestID: UUID
  ) {
    let task = Task { @MainActor in
      lastContextReceipt = nil
      storedContextReceipt = nil
      receiptAssistantMessageID = nil
      isRecallingContext = true
      defer {
        MosaicOperationCoordinator.shared.end(operationID)
        requestRegistry.finish(conversationID: conversation.id, requestID: requestID)
        generationTask = nil
        isRecallingContext = false
        isCompactingContext = false
      }
      var apiKeyForRedaction: String?
      let requestedGoogleServices = googleServices
      let requestedConnectors = connectorSelection
      let connectorExecutor = ConnectorExecutor(selection: requestedConnectors)
      var connectedGoogleContext = GoogleChatContext.empty
      var connectionActions: [ConnectionActionReceipt] = []
      var googleLease: GoogleConnectionLease?
      let requestedGoogleSubject = googleSubject
      defer {
        searchActivity = nil
        connectorApproval.finish(false)
      }
      var holdsCompactionGate = false
      var contextEventSequence = 0
      var pendingCompactionPlan: ConversationCompactionGenerationPlan?
      var pendingCompactionProvider: ProviderConnection?
      var pendingCompactionContext: RequestContextReceipt?
      var pendingCompactionTelemetry: ConversationCompactionTelemetryCollector?
      var usedMemoryTopicIDs: Set<UUID> = []
      do {
        let readRepository = MosaicConversationReadRepository(
          modelContainer: modelContext.container
        )
        let requestProjectContext = try await readRepository.projectContextSnapshot(
          conversationID: conversation.id
        )
        let currentMemoryContext = try await readRepository.curatedMemoryContext(
          conversationID: conversation.id
        )
        try Task.checkCancellation()
        guard
          try await readRepository.projectContextSnapshot(conversationID: conversation.id)
            == requestProjectContext
        else {
          throw ConversationCompactionError.staleSource
        }
        let retrievedContext = await SemanticMemoryCoordinator.retrieve(
          query: MemoryRecallQuery.make(current: recallQuery, messages: requestMessages),
          excluding: conversation.id,
          in: modelContext,
          connection: provider
        )
        guard
          try await readRepository.projectContextSnapshot(conversationID: conversation.id)
            == requestProjectContext
        else {
          throw ConversationCompactionError.staleSource
        }
        usedMemoryTopicIDs = Set(
          retrievedContext.items.compactMap { item in
            item.source == .memoryTopic ? item.id : nil
          }
        )
        try Task.checkCancellation()
        let contextReceipt = RequestContextReceipt(
          curatedContext: currentMemoryContext,
          retrievedContext: retrievedContext,
          projectContext: requestProjectContext.receipt
        )
        var systemPrompt = composedSystemPrompt(receipt: contextReceipt)
        let providerLimits = ProviderConversationContextLimits(configuration: provider)
        let contextPlanner = ConversationContextPlanner(
          policy: providerLimits.policy,
          warnings: providerLimits.warnings
        )
        let compactionPlanner = ConversationCompactionPlanner(
          contextPolicy: providerLimits.policy
        )

        let key = try await SecurityKeychain.shared.apiKey(
          for: provider.id,
          expectedBinding: provider.credentialBinding
        )
        apiKeyForRedaction = key
        let connection = provider.authenticated(with: key)
        let client = ProviderClientFactory.make(connection: connection)
        if !requestedGoogleServices.isEmpty {
          let lease = try await GoogleConnectionStore.shared.lease()
          let account = lease.account
          guard account.subject == requestedGoogleSubject else {
            throw GoogleConnectionError.accountChanged
          }
          googleLease = lease
          var searchUsage = ExperienceValue(
            id: ExperienceValue.modelID("google-search:" + requestID.uuidString), kind: .usage,
            providerID: provider.id, model: provider.modelIdentifier,
            conversationID: conversation.id,
            messageID: assistantMessage.id, usageCategory: "Connected search",
            usageDate: .now, usageProviderKind: provider.provider,
            usageProviderHost: provider.resolvedBaseURL?.host)
          connectedGoogleContext = try await GoogleChatSearch.retrieve(
            question: recallQuery, services: requestedGoogleServices, account: account,
            client: client,
            maximumBytes: min(12_000, contextPlanner.policy.availableInputTokens / 3),
            planningInputBudget: contextPlanner.policy.availableInputTokens,
            onStart: {
              // Every planner/selection/summary stream has independent usage, including unknown usage.
              searchUsage.id = UUID()
              searchUsage.inputTokens = nil
              searchUsage.outputTokens = nil
              searchUsage.usageDate = .now
              searchUsage.updatedAt = .now
              try ExperienceStore.save(searchUsage, in: modelContext)
              guard saveOrReport() else { throw ConversationViewError.persistenceFailure }
            },
            onProgress: { progress in
              searchActivity = MessageSearchActivity(
                messageID: assistantMessage.id, progress: progress)
            },
            continuation: googleResearchContinuation.flatMap {
              $0.conversationID == conversation.id && $0.revision == lease.revision
                ? $0.checkpoint : nil
            },
            validate: {
              try await GoogleConnectionStore.shared.validate(lease)
              guard googleServices == requestedGoogleServices,
                googleSubject == requestedGoogleSubject
              else { throw GoogleConnectionError.accountChanged }
            },
            onUsage: { usage in
              searchUsage.inputTokens = usage.inputTokens
              searchUsage.outputTokens = usage.outputTokens
              searchUsage.updatedAt = .now
              try ExperienceStore.save(searchUsage, in: modelContext)
              guard saveOrReport() else { throw ConversationViewError.persistenceFailure }
            })
          googleResearchContinuation = connectedGoogleContext.continuation.map {
            (conversation.id, lease.revision, $0)
          }
          searchActivity = nil
          try await GoogleConnectionStore.shared.validate(lease)
          if !connectedGoogleContext.prompt.isEmpty {
            systemPrompt = (systemPrompt ?? "") + "\n" + connectedGoogleContext.prompt
          }
        }
        if !requestedConnectors.bindings.isEmpty {
          var usage = ExperienceValue(
            id: UUID(), kind: .usage, providerID: provider.id,
            model: provider.modelIdentifier, conversationID: conversation.id,
            messageID: assistantMessage.id,
            usageCategory: "Connected tools", usageDate: .now, usageProviderKind: provider.provider,
            usageProviderHost: provider.resolvedBaseURL?.host)
          let extra = try await ConnectorResearch.run(
            question: recallQuery, selection: requestedConnectors,
            client: client,
            maximumBytes: min(8_000, contextPlanner.policy.availableInputTokens / 4),
            inputBudget: contextPlanner.policy.availableInputTokens,
            validate: {
              guard connectorSelection == requestedConnectors else { throw ConnectorError.changed }
            },
            onStart: {
              usage.id = UUID()
              usage.inputTokens = nil
              usage.outputTokens = nil
              usage.usageDate = .now
              usage.updatedAt = .now
              try ExperienceStore.save(usage, in: modelContext)
              guard saveOrReport() else { throw ConversationViewError.persistenceFailure }
            },
            onUsage: { tokens in
              usage.inputTokens = tokens.inputTokens
              usage.outputTokens = tokens.outputTokens
              usage.updatedAt = .now
              try ExperienceStore.save(usage, in: modelContext)
              guard saveOrReport() else { throw ConversationViewError.persistenceFailure }
            },
            onProgress: { title in
              searchActivity = MessageSearchActivity(
                messageID: assistantMessage.id, progress: .connection(title))
            },
            approve: { tool, call in
              await connectorApproval.request(tool, call: call)
            },
            onAction: { action in
              if let index = connectionActions.firstIndex(where: { $0.id == action.id }) {
                connectionActions[index] = action
              } else {
                connectionActions.append(action)
              }
              try ExperienceStore.save(
                ExperienceValue(
                  id: ExperienceValue.modelID("web:" + assistantMessage.id.uuidString),
                  kind: .webSources,
                  conversationID: conversation.id, messageID: assistantMessage.id,
                  sources: connectedGoogleContext.sources,
                  searchNotice: "Connection action details",
                  connectionActions: connectionActions), in: modelContext)
              guard saveOrReport() else { throw ConversationViewError.persistenceFailure }
            }, executor: connectorExecutor)
          if !extra.prompt.isEmpty { systemPrompt = (systemPrompt ?? "") + "\n" + extra.prompt }
          let notice = [connectedGoogleContext.searchNotice, extra.notice].compactMap { $0 }.joined(
            separator: " ")
          connectedGoogleContext = GoogleChatContext(
            prompt: connectedGoogleContext.prompt,
            sources: Array((connectedGoogleContext.sources + extra.sources).prefix(100)),
            searchedServices: connectedGoogleContext.searchedServices,
            searchNotice: notice.isEmpty ? nil : GoogleWire.bounded(notice, bytes: 1500),
            continuation: connectedGoogleContext.continuation)
          searchActivity = nil
        }
        await reconcileInterruptedCompactionAudits()
        try Task.checkCancellation()
        let freshState = try await readRepository.canonicalState(
          conversationID: conversation.id
        )
        guard freshState.messages.starts(with: requestMessages) else {
          throw ConversationCompactionError.staleSource
        }
        let storedCompaction: ConversationCompactionSnapshot? =
          freshState.activeCompactionSnapshot.flatMap {
            snapshot -> ConversationCompactionSnapshot? in
            guard snapshot.coveredMessageIDs.count <= requestMessages.count,
              compactionPlanner.isValid(
                snapshot: snapshot,
                conversationID: conversation.id,
                messages: freshState.messages
              ),
              compactionPlanner.isValid(
                snapshot: snapshot,
                conversationID: conversation.id,
                messages: requestMessages
              )
            else {
              return nil
            }
            return snapshot
          }

        let decision: ConversationCompactionDecision
        if allowNewCompaction {
          decision = compactionPlanner.decision(
            conversationID: conversation.id,
            messages: requestMessages,
            systemPrompt: systemPrompt,
            existingSnapshot: storedCompaction
          )
        } else {
          decision = compactionPlanner.retryDecision(
            conversationID: conversation.id,
            messages: requestMessages,
            existingSnapshot: storedCompaction
          )
        }
        var contextPlan: ConversationContextPlan?
        var compactionReceipt: ConversationCompactionReceipt?
        var sameConversationRecall: SameConversationRecallReceipt?
        var activeCompactionSnapshot: ConversationCompactionSnapshot?
        var compactionActivationIntents: [NormalizedCompactionActivation] = []

        switch decision {
        case .notNeeded:
          contextPlan = try contextPlanner.plan(
            messages: requestMessages,
            systemPrompt: systemPrompt
          )

        case .reuse(let snapshot):
          do {
            contextPlan = try contextPlanner.plan(
              messages: requestMessages,
              systemPrompt: systemPrompt,
              conversationID: conversation.id,
              compaction: snapshot
            )
            compactionReceipt = reusedCompactionReceipt(
              snapshot: snapshot,
              requestMessages: requestMessages,
              systemPrompt: systemPrompt,
              estimatedAfter: contextPlan?.receipt.estimatedInputTokens ?? 0
            )
            activeCompactionSnapshot = snapshot
            if let intent = dualReadActivationIntent(
              snapshot: snapshot,
              normalizedHeadID: freshState.normalizedCompactionArtifactID
            ) {
              compactionActivationIntents.append(intent)
            }
          } catch {
            contextPlan = addingConversationWarning(
              "The stored summary did not fit the selected model's smaller safe input budget, so Turing AI used recent raw history for this request.",
              to: try contextPlanner.plan(
                messages: requestMessages,
                systemPrompt: systemPrompt
              )
            )
          }

        case .unavailable(let warning):
          contextPlan = addingConversationWarning(
            warning,
            to: try contextPlanner.plan(
              messages: requestMessages,
              systemPrompt: systemPrompt
            )
          )

        case .generate(let generationPlan):
          try Task.checkCancellation()
          let acquiredGate = await ConversationCompactionExecutionGate.shared.acquire(
            conversationID: conversation.id
          )
          if !acquiredGate {
            let fallback = try compactionFallbackPlan(
              previousSnapshot: generationPlan.previousSnapshot,
              planner: contextPlanner,
              messages: requestMessages,
              systemPrompt: systemPrompt,
              warning:
                "Another window is already compressing this chat, so Turing AI avoided a duplicate provider request."
            )
            contextPlan = fallback.plan
            activeCompactionSnapshot = fallback.usedPreviousSnapshot
            compactionReceipt = generatedCompactionReceipt(
              plan: generationPlan,
              provider: connection,
              status: .failed,
              snapshot: fallback.usedPreviousSnapshot,
              extraRequestCount: 0,
              errorDescription: "A duplicate history-compression request was prevented."
            )
          } else {
            holdsCompactionGate = true
            let gateState = try await readRepository.canonicalState(
              conversationID: conversation.id
            )
            guard gateState.messages.starts(with: requestMessages) else {
              throw ConversationCompactionError.staleSource
            }
            let canonicalActiveSnapshot: ConversationCompactionSnapshot? =
              gateState.activeCompactionSnapshot.flatMap {
                snapshot -> ConversationCompactionSnapshot? in
                compactionPlanner.isValid(
                  snapshot: snapshot,
                  conversationID: conversation.id,
                  messages: gateState.messages
                ) ? snapshot : nil
              }
            let canonicalSnapshotForRequest: ConversationCompactionSnapshot? =
              canonicalActiveSnapshot.flatMap { snapshot -> ConversationCompactionSnapshot? in
                guard snapshot.coveredMessageIDs.count <= requestMessages.count,
                  compactionPlanner.isValid(
                    snapshot: snapshot,
                    conversationID: conversation.id,
                    messages: requestMessages
                  )
                else {
                  return nil
                }
                return snapshot
              }
            let generationPlanIsCurrent =
              canonicalActiveSnapshot?.id == generationPlan.previousSnapshot?.id
              && (canonicalActiveSnapshot == nil || canonicalSnapshotForRequest != nil)

            if !generationPlanIsCurrent {
              let fallback = try compactionFallbackPlan(
                previousSnapshot: canonicalSnapshotForRequest,
                planner: contextPlanner,
                messages: requestMessages,
                systemPrompt: systemPrompt,
                warning:
                  "A newer app-owned summary became active before this request started, so Turing AI avoided a duplicate provider request."
              )
              contextPlan = fallback.plan
              if let usedSnapshot = fallback.usedPreviousSnapshot {
                activeCompactionSnapshot = usedSnapshot
                if let intent = dualReadActivationIntent(
                  snapshot: usedSnapshot,
                  normalizedHeadID: gateState.normalizedCompactionArtifactID
                ) {
                  compactionActivationIntents.append(intent)
                }
                compactionReceipt = reusedCompactionReceipt(
                  snapshot: usedSnapshot,
                  requestMessages: requestMessages,
                  systemPrompt: systemPrompt,
                  estimatedAfter: fallback.plan.receipt.estimatedInputTokens
                )
              } else {
                compactionReceipt = generatedCompactionReceipt(
                  plan: generationPlan,
                  provider: connection,
                  status: .failed,
                  extraRequestCount: 0,
                  errorDescription: "A stale duplicate history-compression request was prevented."
                )
              }
            } else {
              guard
                try await readRepository.projectContextSnapshot(conversationID: conversation.id)
                  == requestProjectContext
              else {
                throw ConversationCompactionError.staleSource
              }
              let telemetry = ConversationCompactionTelemetryCollector()
              let pendingReceipt = generatedCompactionReceipt(
                plan: generationPlan,
                provider: connection,
                status: .generating,
                extraRequestCount: 1,
                warnings: [
                  "Turing AI records the possible extra request before opening the provider stream so an interrupted app cannot hide provider usage."
                ]
              )
              let pendingContextReceipt = RequestContextReceipt(
                curatedContext: contextReceipt.curatedContext,
                retrievedContext: contextReceipt.retrievedContext,
                projectContext: contextReceipt.projectContext,
                conversationCompaction: pendingReceipt
              )
              try persistContextReceipt(
                pendingContextReceipt,
                assistantMessageID: assistantMessage.id,
                requestMessages: requestMessages,
                eventSequence: &contextEventSequence
              )
              pendingCompactionPlan = generationPlan
              pendingCompactionProvider = provider
              pendingCompactionContext = contextReceipt
              pendingCompactionTelemetry = telemetry

              isRecallingContext = false
              isCompactingContext = true
              let generatedResult: ConversationCompactionGenerationResult?
              var generationError: Error?
              do {
                try Task.checkCancellation()
                generatedResult = try await ConversationCompactor().generate(
                  plan: generationPlan,
                  provider: connection,
                  client: client,
                  telemetry: telemetry
                )
                generationError = nil
              } catch is CancellationError {
                throw CancellationError()
              } catch {
                generatedResult = nil
                generationError = error
              }
              isCompactingContext = false

              if let generationError {
                let sanitizedError = ProviderErrorSanitizer.description(
                  for: generationError,
                  redacting: apiKeyForRedaction
                )
                let fallback = try compactionFallbackPlan(
                  previousSnapshot: generationPlan.previousSnapshot,
                  planner: contextPlanner,
                  messages: requestMessages,
                  systemPrompt: systemPrompt,
                  warning:
                    "The new compression attempt failed, so Turing AI kept using the last valid summary when it fit."
                )
                let failedReceipt = generatedCompactionReceipt(
                  plan: generationPlan,
                  provider: connection,
                  status: .failed,
                  snapshot: fallback.usedPreviousSnapshot,
                  telemetry: telemetry.snapshot,
                  errorDescription: sanitizedError,
                  warnings: [
                    "No partial or unvalidated summary was saved."
                  ]
                )
                compactionReceipt = failedReceipt
                contextPlan = fallback.plan
                activeCompactionSnapshot = fallback.usedPreviousSnapshot
                if let usedSnapshot = fallback.usedPreviousSnapshot,
                  let intent = dualReadActivationIntent(
                    snapshot: usedSnapshot,
                    normalizedHeadID: gateState.normalizedCompactionArtifactID
                  )
                {
                  compactionActivationIntents.append(intent)
                }
              } else if let generatedResult {
                // A fresh context reads committed rows instead of trusting a possibly delayed
                // cross-window @Query update.
                let liveMessages = try await readRepository.canonicalState(
                  conversationID: conversation.id
                ).messages
                guard liveMessages.starts(with: requestMessages),
                  compactionPlanner.isValid(
                    snapshot: generatedResult.snapshot,
                    conversationID: conversation.id,
                    messages: liveMessages
                  )
                else {
                  throw ConversationCompactionError.staleSource
                }

                do {
                  guard
                    generatedResult.snapshot.previousCompactionID
                      == canonicalActiveSnapshot?.id
                  else {
                    throw ConversationCompactionError.staleSource
                  }
                  let generatedPlan = try contextPlanner.plan(
                    messages: requestMessages,
                    systemPrompt: systemPrompt,
                    conversationID: conversation.id,
                    compaction: generatedResult.snapshot
                  )
                  guard
                    compactionPlanner.createsMinimumSavings(
                      compactedPlan: generatedPlan,
                      generatedSnapshot: generatedResult.snapshot,
                      generationPlan: generationPlan
                    )
                  else {
                    throw ConversationCompactionError.insufficientSavings
                  }
                  contextPlan = generatedPlan
                  activeCompactionSnapshot = generatedResult.snapshot
                  if let canonicalActiveSnapshot,
                    let intent = dualReadActivationIntent(
                      snapshot: canonicalActiveSnapshot,
                      normalizedHeadID: gateState.normalizedCompactionArtifactID
                    )
                  {
                    compactionActivationIntents.append(intent)
                  }
                  compactionActivationIntents.append(
                    NormalizedCompactionActivation(
                      snapshot: generatedResult.snapshot,
                      expectedCurrentArtifactID: canonicalActiveSnapshot?.id,
                      allowVerifiedDetachedTakeover: false
                    )
                  )
                  compactionReceipt = generatedCompactionReceipt(
                    plan: generationPlan,
                    provider: connection,
                    status: .generated,
                    snapshot: generatedResult.snapshot,
                    telemetry: telemetry.snapshot,
                    estimatedAfter: generatedPlan.receipt.estimatedInputTokens
                  )
                } catch {
                  let sanitizedError = ProviderErrorSanitizer.description(
                    for: error,
                    redacting: apiKeyForRedaction
                  )
                  let fallback = try compactionFallbackPlan(
                    previousSnapshot: generationPlan.previousSnapshot,
                    planner: contextPlanner,
                    messages: requestMessages,
                    systemPrompt: systemPrompt,
                    warning:
                      "The new summary did not fit or create enough safe room, so Turing AI kept using the last valid summary when it fit."
                  )
                  compactionReceipt = generatedCompactionReceipt(
                    plan: generationPlan,
                    provider: connection,
                    status: .failed,
                    snapshot: fallback.usedPreviousSnapshot,
                    telemetry: telemetry.snapshot,
                    errorDescription: sanitizedError,
                    warnings: [
                      "The generated summary was validated but not activated because it did not fit with the protected recent turns or reduce the request enough."
                    ]
                  )
                  contextPlan = fallback.plan
                  activeCompactionSnapshot = fallback.usedPreviousSnapshot
                  if let usedSnapshot = fallback.usedPreviousSnapshot,
                    let intent = dualReadActivationIntent(
                      snapshot: usedSnapshot,
                      normalizedHeadID: gateState.normalizedCompactionArtifactID
                    )
                  {
                    compactionActivationIntents.append(intent)
                  }
                }
              } else {
                throw ConversationCompactionError.invalidOutput
              }
            }
          }
        }

        guard let plannedContext = contextPlan else {
          throw ConversationContextPlannerError.missingCurrentUserMessage
        }
        let recallState = try await readRepository.canonicalState(
          conversationID: conversation.id
        )
        guard recallState.messages.starts(with: requestMessages) else {
          throw ConversationCompactionError.staleSource
        }
        let recallConversationID = conversation.id
        let recallCandidates = recallState.recallCandidates
        let recallPolicy = contextPlanner.policy
        let recallEstimator = contextPlanner.estimator
        let sameConversationPlan = try await SameConversationRecallExecutor.shared.plan(
          query: recallQuery,
          currentConversationID: recallConversationID,
          candidates: recallCandidates,
          basePlan: plannedContext,
          originalMessages: requestMessages,
          policy: recallPolicy,
          estimator: recallEstimator
        )
        let originalReceipt = plannedContext.receipt
        contextPlan = ConversationContextPlan(
          messages: sameConversationPlan.messages,
          receipt: ConversationContextReceipt(
            strategy: originalReceipt.strategy,
            originalMessageCount: originalReceipt.originalMessageCount,
            includedMessageIDs: sameConversationPlan.finalRawIncludedMessageIDs,
            omittedMessageIDs: sameConversationPlan.finalOmittedMessageIDs,
            summarizedMessageIDs: sameConversationPlan.summarizedMessageIDs,
            recalledMessageIDs: sameConversationPlan.recalledMessageIDs,
            estimatedInputTokens: sameConversationPlan.estimatedInputTokens,
            contextWindowTokens: originalReceipt.contextWindowTokens,
            maximumOutputTokens: originalReceipt.maximumOutputTokens,
            safetyMarginTokens: originalReceipt.safetyMarginTokens,
            warnings: originalReceipt.warnings
          )
        )
        if sameConversationPlan.receipt.eligibleCandidateCount > 0 {
          sameConversationRecall = sameConversationPlan.receipt
        }
        if compactionReceipt?.estimatedInputTokensAfter != nil {
          compactionReceipt = compactionReceipt?.updatingEstimatedInputTokensAfter(
            sameConversationPlan.estimatedInputTokens
          )
        }
        guard let contextPlan else {
          throw ConversationContextPlannerError.missingCurrentUserMessage
        }
        guard
          try await readRepository.curatedMemoryContextIsCurrent(
            contextReceipt.curatedContext,
            conversationID: conversation.id,
            projectID: requestProjectContext.receipt?.projectID
          ),
          await SemanticMemoryCoordinator.isCurrent(
            contextReceipt.retrievedContext,
            audienceScope: requestProjectContext.audienceScope,
            in: modelContext
          ),
          try await readRepository.projectContextSnapshot(conversationID: conversation.id)
            == requestProjectContext
        else {
          throw ConversationCompactionError.staleSource
        }
        let receipt = RequestContextReceipt(
          curatedContext: contextReceipt.curatedContext,
          retrievedContext: contextReceipt.retrievedContext,
          projectContext: contextReceipt.projectContext,
          conversationContext: contextPlan.receipt,
          sameConversationRecall: sameConversationRecall,
          conversationCompaction: compactionReceipt
        )
        try persistContextReceipt(
          receipt,
          assistantMessageID: assistantMessage.id,
          requestMessages: requestMessages,
          eventSequence: &contextEventSequence,
          activeCompactionSnapshot: activeCompactionSnapshot,
          compactionActivations: compactionActivationIntents
        )
        pendingCompactionPlan = nil
        pendingCompactionProvider = nil
        pendingCompactionContext = nil
        pendingCompactionTelemetry = nil
        if holdsCompactionGate {
          await ConversationCompactionExecutionGate.shared.release(
            conversationID: conversation.id
          )
          holdsCompactionGate = false
        }
        isRecallingContext = false
        try Task.checkCancellation()
        guard
          try await readRepository.canonicalState(conversationID: conversation.id).messages
            .starts(with: requestMessages),
          try await readRepository.curatedMemoryContextIsCurrent(
            contextReceipt.curatedContext,
            conversationID: conversation.id,
            projectID: requestProjectContext.receipt?.projectID
          ),
          await SemanticMemoryCoordinator.isCurrent(
            contextReceipt.retrievedContext,
            audienceScope: requestProjectContext.audienceScope,
            in: modelContext
          ),
          try await readRepository.projectContextSnapshot(conversationID: conversation.id)
            == requestProjectContext
        else {
          throw ConversationCompactionError.staleSource
        }
        if let googleLease {
          try await GoogleConnectionStore.shared.validate(googleLease)
        }
        try await connectorExecutor.validate()
        guard connectorSelection == requestedConnectors else { throw ConnectorError.changed }
        if webSearch || !connectedGoogleContext.sources.isEmpty
          || !connectedGoogleContext.searchedServices.isEmpty
          || connectedGoogleContext.searchNotice != nil
        {
          try ExperienceStore.save(
            ExperienceValue(
              id: ExperienceValue.modelID("web:" + assistantMessage.id.uuidString),
              kind: .webSources, conversationID: conversation.id, messageID: assistantMessage.id,
              sources: connectedGoogleContext.sources,
              searchedServices: connectedGoogleContext.searchedServices,
              searchNotice: connectedGoogleContext.searchNotice,
              connectionActions: connectionActions), in: modelContext)
        }
        var webSources: [WebSource] = connectedGoogleContext.sources
        var didComplete = false
        var assistantContentUTF8Bytes = assistantMessage.content.utf8.count
        var streamPersistence = ConversationStreamPersistencePolicy()
        let requestImages = try imagesForRequest(contextPlan.messages)
        for try await event in client.stream(
          AIChatRequest(
            messages: contextPlan.messages,
            systemPrompt: systemPrompt,
            maxOutputTokens: contextPlanner.policy.maximumOutputTokens,
            images: requestImages, webSearch: webSearch
          )
        ) {
          switch event {
          case .textDelta(let delta):
            let (nextByteCount, overflow) = assistantContentUTF8Bytes.addingReportingOverflow(
              delta.utf8.count
            )
            guard !overflow,
              nextByteCount <= MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes
            else {
              throw MosaicSourceFieldLimitError.messageContent(
                actual: overflow ? .max : nextByteCount,
                maximum: MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes
              )
            }
            assistantMessage.content += delta
            assistantContentUTF8Bytes = nextByteCount
            assistantMessage.updatedAt = .now
            if streamPersistence.shouldPersist(
              afterAppendingUTF8Bytes: delta.utf8.count,
              now: assistantMessage.updatedAt
            ) {
              guard saveOrReport() else {
                throw ConversationViewError.persistenceFailure
              }
              streamPersistence.didPersist(at: assistantMessage.updatedAt)
            }
          case .citations(let incoming):
            for incomingSource in incoming {
              var source = incomingSource
              if source.end == nil { source.end = assistantMessage.content.unicodeScalars.count }
              guard !webSources.contains(source) else { continue }
              guard webSources.count < 100 else { throw ProviderClientError.responseTooLarge }
              webSources.append(source)
            }
            try ExperienceStore.save(
              ExperienceValue(
                id: ExperienceValue.modelID("web:" + assistantMessage.id.uuidString),
                kind: .webSources,
                conversationID: conversation.id, messageID: assistantMessage.id,
                sources: webSources,
                searchedServices: connectedGoogleContext.searchedServices,
                searchNotice: connectedGoogleContext.searchNotice,
                connectionActions: connectionActions
              ), in: modelContext)
          case .usage(let usage):
            if let input = usage.inputTokens { assistantMessage.inputTokenCount = input }
            if let output = usage.outputTokens { assistantMessage.outputTokenCount = output }
          case .completed(let responseID):
            assistantMessage.providerMessageID = responseID
            didComplete = true
          }
        }

        if Task.isCancelled {
          assistantMessage.status = .cancelled
        } else if didComplete, !assistantMessage.content.isEmpty {
          assistantMessage.status = .complete
          assistantMessage.updatedAt = .now
          conversation.updatedAt = .now
          guard saveOrReport() else {
            throw ConversationViewError.persistenceFailure
          }
          if !usedMemoryTopicIDs.isEmpty {
            do {
              try await AutomaticMemoryStore(modelContainer: modelContext.container).recordUse(
                topicIDs: usedMemoryTopicIDs
              )
              MosaicOperationCoordinator.shared.markMemoryLibraryChanged()
            } catch {
              // Usage bookkeeping must not turn a completed paid request into a failed reply.
            }
          }
          if automaticMemoryEnabled, let sourceUserMessageID = requestMessages.last?.id {
            scheduleAutomaticMemoryFormation(
              provider: connection,
              client: client,
              sourceUserMessageID: sourceUserMessageID,
              assistantMessageID: assistantMessage.id
            )
          }
        } else {
          assistantMessage.status = .failed
          assistantMessage.errorDescription =
            assistantMessage.content.isEmpty
            ? "The provider completed without visible text."
            : "The connection ended before the provider confirmed completion."
        }
      } catch is CancellationError {
        var terminalAuditFailed = false
        if let pendingCompactionPlan,
          let pendingCompactionProvider,
          let pendingCompactionContext,
          let pendingCompactionTelemetry
        {
          do {
            try persistTerminalCompactionEventReliably(
              plan: pendingCompactionPlan,
              provider: pendingCompactionProvider,
              baseContext: pendingCompactionContext,
              telemetry: pendingCompactionTelemetry.snapshot,
              status: .cancelled,
              errorDescription: "History compression was stopped before completion.",
              assistantMessageID: assistantMessage.id,
              requestMessages: requestMessages,
              eventSequence: &contextEventSequence
            )
          } catch {
            terminalAuditFailed = true
          }
        }
        if holdsCompactionGate {
          await ConversationCompactionExecutionGate.shared.release(
            conversationID: conversation.id
          )
          holdsCompactionGate = false
        }
        assistantMessage.status = .cancelled
        if terminalAuditFailed {
          assistantMessage.errorDescription =
            "Turing AI stopped the reply but could not finalize its local history-compression audit. The earlier generating event was kept for recovery."
          persistenceError =
            "Turing AI stopped the reply but could not finalize its local history-compression audit. The audit will be recovered the next time this chat opens."
        }
      } catch {
        let sanitizedError = ProviderErrorSanitizer.description(
          for: error,
          redacting: apiKeyForRedaction
        )
        var terminalAuditFailed = false
        if let pendingCompactionPlan,
          let pendingCompactionProvider,
          let pendingCompactionContext,
          let pendingCompactionTelemetry
        {
          do {
            try persistTerminalCompactionEventReliably(
              plan: pendingCompactionPlan,
              provider: pendingCompactionProvider,
              baseContext: pendingCompactionContext,
              telemetry: pendingCompactionTelemetry.snapshot,
              status: .failed,
              errorDescription: sanitizedError,
              assistantMessageID: assistantMessage.id,
              requestMessages: requestMessages,
              eventSequence: &contextEventSequence
            )
          } catch {
            terminalAuditFailed = true
          }
        }
        if holdsCompactionGate {
          await ConversationCompactionExecutionGate.shared.release(
            conversationID: conversation.id
          )
          holdsCompactionGate = false
        }
        assistantMessage.status = .failed
        assistantMessage.errorDescription =
          terminalAuditFailed
          ? sanitizedError
            + " Turing AI could not finalize its local history-compression audit; the earlier generating event was kept for recovery."
          : sanitizedError
        if terminalAuditFailed {
          persistenceError =
            "Turing AI could not finalize its local history-compression audit. The audit will be recovered the next time this chat opens."
        }
      }
      assistantMessage.updatedAt = .now
      conversation.updatedAt = .now
      _ = saveOrReport()
    }
    generationTask = task
    if !requestRegistry.transfer(
      conversationID: conversation.id,
      requestID: requestID,
      cancel: { task.cancel() }
    ) {
      task.cancel()
    }
  }

  private var requestOperationUnavailableDescription: String {
    MosaicOperationCoordinator.shared.isExclusiveMaintenanceActive
      || MosaicOperationCoordinator.shared.isSourceStoreUnavailable
      ? "Turing AI is replacing or recovering its local library. Try again after recovery finishes."
      : "Another reply or data operation is already running. Wait for it to finish, then try again."
  }

  private func scheduleAutomaticMemoryFormation(
    provider: ProviderConnection,
    client: any AIProviderClient,
    sourceUserMessageID: UUID,
    assistantMessageID: UUID
  ) {
    let conversationID = conversation.id
    let container = modelContext.container
    let operationID = MosaicOperationID.memoryFormation(sourceUserMessageID)
    Task { @MainActor in
      let operationCoordinator = MosaicOperationCoordinator.shared
      guard operationCoordinator.begin(operationID) else { return }
      defer { operationCoordinator.end(operationID) }
      do {
        let result = try await AutomaticMemoryFormationCoordinator.shared.formMemory(
          conversationID: conversationID,
          throughUserMessageID: sourceUserMessageID,
          assistantMessageID: assistantMessageID,
          provider: provider,
          client: client,
          modelContainer: container
        )
        if result.changedCount > 0 {
          operationCoordinator.markMemoryLibraryChanged()
          showTransientNotice(
            result.changedCount == 1 ? "Memory updated" : "Memories updated"
          )
        }
      } catch {
        // Memory formation is intentionally isolated from the successful chat reply. The durable
        // job retains a bounded error for inspection and a later retry.
      }
    }
  }

  private func showTransientNotice(_ notice: String) {
    transientNoticeClearTask?.cancel()
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
      transientNotice = notice
    }
    AccessibilityNotification.Announcement(notice).post()
    transientNoticeClearTask = Task { @MainActor in
      do {
        try await Task.sleep(for: .seconds(2))
        try Task.checkCancellation()
        guard transientNotice == notice else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
          transientNotice = nil
        }
      } catch {
        return
      }
    }
  }

  private func generatedCompactionReceipt(
    plan: ConversationCompactionGenerationPlan,
    provider: ProviderConnection,
    status: ConversationCompactionAttemptStatus,
    snapshot: ConversationCompactionSnapshot? = nil,
    telemetry: ConversationCompactionAttemptTelemetry? = nil,
    estimatedAfter: Int? = nil,
    extraRequestCount: Int? = nil,
    errorDescription: String? = nil,
    warnings: [String] = []
  ) -> ConversationCompactionReceipt {
    let resolvedExtraRequestCount =
      extraRequestCount ?? (telemetry?.requestStarted == false ? 0 : 1)
    var receiptWarnings = plan.warnings + warnings
    if telemetry?.discardedInvalidUsage == true {
      receiptWarnings.append(
        "The provider emitted invalid usage counters, so Turing AI omitted those untrusted values."
      )
    }
    if status == .failed, resolvedExtraRequestCount > 0, let snapshot {
      receiptWarnings.append(
        "Turing AI reused the last valid summary from \(snapshot.providerDisplayName) · \(snapshot.modelIdentifier) after this attempt failed."
      )
    }
    return ConversationCompactionReceipt(
      attemptID: plan.attemptID,
      status: status,
      compactionID: snapshot?.id,
      summaryText: snapshot?.renderedSummary,
      coveredMessageIDs: snapshot?.coveredMessageIDs ?? [],
      attemptedMessageIDs: resolvedExtraRequestCount > 0 ? plan.inputMessages.map(\.id) : nil,
      activeSummaryProviderConfigurationID: snapshot?.providerConfigurationID,
      activeSummaryProviderKind: snapshot?.providerKind,
      activeSummaryProviderDisplayName: snapshot?.providerDisplayName,
      activeSummaryProviderEndpoint: snapshot?.providerEndpoint,
      activeSummaryModelIdentifier: snapshot?.modelIdentifier,
      activeSummaryCreatedAt: snapshot?.createdAt,
      providerConfigurationID: provider.id,
      providerKind: provider.provider,
      providerDisplayName: provider.displayName,
      providerEndpoint: provider.credentialBinding.endpoint,
      modelIdentifier: provider.modelIdentifier,
      providerMessageID: telemetry?.providerMessageID,
      inputTokenCount: telemetry?.inputTokenCount,
      outputTokenCount: telemetry?.outputTokenCount,
      estimatedInputTokensBefore: plan.estimatedInputTokensBefore,
      estimatedInputTokensAfter: estimatedAfter,
      extraRequestCount: resolvedExtraRequestCount,
      errorDescription: errorDescription,
      warnings: receiptWarnings,
      createdAt: .now
    )
  }

  private func persistTerminalCompactionEvent(
    plan: ConversationCompactionGenerationPlan,
    provider: ProviderConnection,
    baseContext: RequestContextReceipt,
    telemetry: ConversationCompactionAttemptTelemetry,
    status: ConversationCompactionAttemptStatus,
    errorDescription: String,
    assistantMessageID: UUID,
    requestMessages: [AIChatMessage],
    eventSequence: inout Int
  ) throws {
    try persistContextReceipt(
      terminalCompactionContextReceipt(
        plan: plan,
        provider: provider,
        baseContext: baseContext,
        telemetry: telemetry,
        status: status,
        errorDescription: errorDescription
      ),
      assistantMessageID: assistantMessageID,
      requestMessages: requestMessages,
      eventSequence: &eventSequence
    )
  }

  private func terminalCompactionContextReceipt(
    plan: ConversationCompactionGenerationPlan,
    provider: ProviderConnection,
    baseContext: RequestContextReceipt,
    telemetry: ConversationCompactionAttemptTelemetry,
    status: ConversationCompactionAttemptStatus,
    errorDescription: String,
    minimal: Bool = false
  ) -> RequestContextReceipt {
    let compactionReceipt = generatedCompactionReceipt(
      plan: plan,
      provider: provider,
      status: status,
      telemetry: telemetry,
      errorDescription: errorDescription,
      warnings: ["No partial or unvalidated summary was activated."]
    )
    return RequestContextReceipt(
      curatedContext: minimal ? .empty : baseContext.curatedContext,
      retrievedContext: minimal ? .empty : baseContext.retrievedContext,
      projectContext: baseContext.projectContext,
      conversationCompaction: compactionReceipt
    )
  }

  /// Retries terminal audit persistence through an independent context. If the live UI context
  /// rolled back or became stale after the generating event, exact event replay makes this retry
  /// idempotent instead of leaving a silently orphaned paid-request audit.
  private func persistTerminalCompactionEventReliably(
    plan: ConversationCompactionGenerationPlan,
    provider: ProviderConnection,
    baseContext: RequestContextReceipt,
    telemetry: ConversationCompactionAttemptTelemetry,
    status: ConversationCompactionAttemptStatus,
    errorDescription: String,
    assistantMessageID: UUID,
    requestMessages: [AIChatMessage],
    eventSequence: inout Int
  ) throws {
    do {
      try persistTerminalCompactionEvent(
        plan: plan,
        provider: provider,
        baseContext: baseContext,
        telemetry: telemetry,
        status: status,
        errorDescription: errorDescription,
        assistantMessageID: assistantMessageID,
        requestMessages: requestMessages,
        eventSequence: &eventSequence
      )
    } catch {
      guard let sourceThroughMessageID = requestMessages.last?.id else {
        throw ConversationContextPlannerError.missingCurrentUserMessage
      }
      let receipt = terminalCompactionContextReceipt(
        plan: plan,
        provider: provider,
        baseContext: baseContext,
        telemetry: telemetry,
        status: status,
        errorDescription: String(errorDescription.prefix(1_024)),
        minimal: true
      )
      let recoveryContext = ModelContext(modelContext.container)
      try NormalizedContextStore(modelContext: recoveryContext).appendRequestEventAtomically(
        assistantMessageID: assistantMessageID,
        conversationID: conversation.id,
        sourceThroughMessageID: sourceThroughMessageID,
        eventSequence: eventSequence,
        receipt: receipt,
        canonicalMessages: requestMessages,
        compactionActivations: []
      )
      eventSequence += 1
      lastContextReceipt = receipt
      receiptAssistantMessageID = assistantMessageID
    }
  }

  private func reconcileInterruptedCompactionAudits() async {
    do {
      let count = try await ConversationPresentationCompactionRecovery.shared.reconcile(
        conversationID: conversation.id,
        modelContainer: modelContext.container
      )
      try Task.checkCancellation()
      if count > 0 {
        transientNotice =
          count == 1
          ? "Recovered an interrupted history-compression audit."
          : "Recovered \(count) interrupted history-compression audits."
      }
    } catch is CancellationError {
      return
    } catch {
      persistenceError =
        "Turing AI found an interrupted history-compression audit but could not finalize it. Your messages were not changed."
    }
  }

  private func reusedCompactionReceipt(
    snapshot: ConversationCompactionSnapshot,
    requestMessages: [AIChatMessage],
    systemPrompt: String?,
    estimatedAfter: Int
  ) -> ConversationCompactionReceipt {
    let estimator = ConservativeTokenEstimator()
    let estimatedBefore =
      estimator.estimate(systemPrompt: systemPrompt)
      + requestMessages.reduce(0) { $0 + estimator.estimate(message: $1) }
    return ConversationCompactionReceipt(
      attemptID: UUID(),
      status: .reused,
      compactionID: snapshot.id,
      summaryText: snapshot.renderedSummary,
      coveredMessageIDs: snapshot.coveredMessageIDs,
      activeSummaryProviderConfigurationID: snapshot.providerConfigurationID,
      activeSummaryProviderKind: snapshot.providerKind,
      activeSummaryProviderDisplayName: snapshot.providerDisplayName,
      activeSummaryProviderEndpoint: snapshot.providerEndpoint,
      activeSummaryModelIdentifier: snapshot.modelIdentifier,
      activeSummaryCreatedAt: snapshot.createdAt,
      providerConfigurationID: snapshot.providerConfigurationID,
      providerKind: snapshot.providerKind,
      providerDisplayName: snapshot.providerDisplayName,
      providerEndpoint: snapshot.providerEndpoint,
      modelIdentifier: snapshot.modelIdentifier,
      providerMessageID: snapshot.providerMessageID,
      inputTokenCount: snapshot.inputTokenCount,
      outputTokenCount: snapshot.outputTokenCount,
      estimatedInputTokensBefore: estimatedBefore,
      estimatedInputTokensAfter: estimatedAfter,
      extraRequestCount: 0,
      warnings: snapshot.warnings,
      createdAt: .now
    )
  }

  private func persistContextReceipt(
    _ receipt: RequestContextReceipt,
    assistantMessageID: UUID,
    requestMessages: [AIChatMessage],
    eventSequence: inout Int,
    activeCompactionSnapshot: ConversationCompactionSnapshot? = nil,
    compactionActivations: [NormalizedCompactionActivation] = []
  ) throws {
    guard let sourceThroughMessageID = requestMessages.last?.id else {
      throw ConversationContextPlannerError.missingCurrentUserMessage
    }
    try NormalizedContextStore(modelContext: modelContext).appendRequestEventAtomically(
      assistantMessageID: assistantMessageID,
      conversationID: conversation.id,
      sourceThroughMessageID: sourceThroughMessageID,
      eventSequence: eventSequence,
      receipt: receipt,
      canonicalMessages: requestMessages,
      activeCompactionSnapshot: activeCompactionSnapshot,
      compactionActivations: compactionActivations
    )
    eventSequence += 1
    lastContextReceipt = receipt
    receiptAssistantMessageID = assistantMessageID
  }

  private func dualReadActivationIntent(
    snapshot: ConversationCompactionSnapshot,
    normalizedHeadID: UUID?
  ) -> NormalizedCompactionActivation? {
    guard normalizedHeadID != snapshot.id else { return nil }
    return NormalizedCompactionActivation(
      snapshot: snapshot,
      expectedCurrentArtifactID: normalizedHeadID,
      allowVerifiedDetachedTakeover: true
    )
  }

  private func compactionFallbackPlan(
    previousSnapshot: ConversationCompactionSnapshot?,
    planner: ConversationContextPlanner,
    messages: [AIChatMessage],
    systemPrompt: String?,
    warning: String
  ) throws -> (plan: ConversationContextPlan, usedPreviousSnapshot: ConversationCompactionSnapshot?)
  {
    let fallback = try planner.planAfterCompactionFailure(
      messages: messages,
      systemPrompt: systemPrompt,
      conversationID: conversation.id,
      previousSnapshot: previousSnapshot
    )
    if fallback.reusedPreviousSummary {
      return (addingConversationWarning(warning, to: fallback.plan), previousSnapshot)
    }
    return (
      addingConversationWarning(
        "\(warning) No prior summary fit, so Turing AI used recent raw history.",
        to: fallback.plan
      ),
      nil
    )
  }

  private func addingConversationWarning(
    _ warning: String,
    to plan: ConversationContextPlan
  ) -> ConversationContextPlan {
    let receipt = plan.receipt
    return ConversationContextPlan(
      messages: plan.messages,
      receipt: ConversationContextReceipt(
        strategy: receipt.strategy,
        originalMessageCount: receipt.originalMessageCount,
        includedMessageIDs: receipt.includedMessageIDs,
        omittedMessageIDs: receipt.omittedMessageIDs,
        summarizedMessageIDs: receipt.summarizedMessageIDs,
        recalledMessageIDs: receipt.recalledMessageIDs,
        estimatedInputTokens: receipt.estimatedInputTokens,
        contextWindowTokens: receipt.contextWindowTokens,
        maximumOutputTokens: receipt.maximumOutputTokens,
        safetyMarginTokens: receipt.safetyMarginTokens,
        warnings: receipt.warnings + [warning]
      )
    )
  }

  private func composedSystemPrompt(receipt: RequestContextReceipt) -> String? {
    let components = [
      conversation.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
      projectInstructionContext(for: receipt.projectContext),
      receipt.curatedContext.systemContent,
      receipt.retrievedContext.systemContent,
    ].compactMap { value -> String? in
      guard let value, !value.isEmpty else { return nil }
      return value
    }
    return components.isEmpty ? nil : components.joined(separator: "\n\n")
  }

  private var currentProjectReceipt: ProjectContextReceipt? {
    guard let project = currentProject else { return nil }
    return ProjectContextReceipt(
      projectID: project.id,
      name: project.name,
      instructions: project.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  private func projectInstructionContext(for project: ProjectContextReceipt?) -> String? {
    guard let project else { return nil }
    let instructions = project.instructions
    guard !instructions.isEmpty else { return nil }
    return """
      <mosaic_project_context id="\(project.projectID.uuidString)" name="\(xmlEscaped(project.name))">
      These are user-authored instructions for the current Turing AI project:
      \(xmlEscaped(instructions))
      </mosaic_project_context>
      """
  }

  private func xmlEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  private func assignConversation(to projectID: UUID?) {
    guard !isComposerBusy, !operationCoordinator.isSourceAccessBlocked,
      operationCoordinator.activeOperations.isEmpty
    else { return }
    do {
      let visibleBinding = projectBindings.first
      _ = try ProjectBindingStore.assignConversation(
        conversationID: conversation.id,
        to: projectID,
        expected: ConversationProjectScope(
          conversationID: conversation.id,
          projectID: visibleBinding?.projectID,
          bindingID: visibleBinding?.id,
          bindingUpdatedAt: visibleBinding?.updatedAt
        ),
        in: modelContext
      )
      try operationCoordinator.saveSourceChanges(in: modelContext)
      invalidateCachedContextReceipt()
      transientNotice =
        projectID.flatMap { targetID in
          projects.first(where: { $0.id == targetID })?.name
        }.map { "Moved to \($0)" } ?? "Removed from project"
    } catch {
      modelContext.rollback()
      persistenceError = error.localizedDescription
    }
  }

  private func resolvedHost(for provider: ProviderConfigurationRecord) -> String? {
    provider.baseURL?.host ?? provider.provider.defaultBaseURL?.host
  }

  private func stopGeneration() {
    requestRegistry.cancel(conversationID: conversation.id)
    requestPreparationTask?.cancel()
    generationTask?.cancel()
  }

  private func remember(_ message: MosaicTranscriptMessage, scope: MemoryScope) {
    let title = compactTitle(message.content)
    do {
      try MosaicSourceFieldLimits.validateMemory(title: title, content: message.content)
    } catch {
      persistenceError = error.localizedDescription
      return
    }
    let memory = MemoryRecord(
      title: title,
      content: message.content,
      scope: scope,
      conversationID: scope == .conversation ? conversation.id : nil,
      isEnabled: true,
      isUserApproved: true
    )
    modelContext.insert(memory)
    do {
      if scope == .project {
        guard let projectID = currentProjectID else {
          throw ProjectBindingError.invalidResource
        }
        _ = try ProjectBindingStore.assign(
          resourceKind: .memory,
          resourceID: memory.id,
          to: projectID,
          in: modelContext
        )
      }
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
    } catch {
      modelContext.rollback()
      persistenceError = error.localizedDescription
      return
    }
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
      transientNotice =
        switch scope {
        case .global: "Saved to Everywhere memory"
        case .project: "Saved to \(currentProject?.name ?? "project") memory"
        case .conversation: "Saved to this chat's memory"
        }
    }
    memoryRefreshTask?.cancel()
    let refreshID = UUID()
    let conversationID = conversation.id
    let sourceStoreGeneration = operationCoordinator.sourceStoreGenerationRevision
    curatedMemoryRequestID = refreshID
    memoryRefreshTask = Task { @MainActor in
      defer {
        if curatedMemoryRequestID == refreshID {
          memoryRefreshTask = nil
          curatedMemoryRequestID = nil
        }
      }
      do {
        let refreshed = try await MosaicConversationReadRepository(
          modelContainer: modelContext.container
        ).curatedMemoryContext(conversationID: conversationID)
        try Task.checkCancellation()
        guard curatedMemoryRequestID == refreshID,
          operationCoordinator.sourceStoreGenerationRevision == sourceStoreGeneration,
          conversation.id == conversationID
        else {
          return
        }
        curatedMemoryContext = refreshed
        try await Task.sleep(for: .seconds(2))
        try Task.checkCancellation()
        guard curatedMemoryRequestID == refreshID,
          operationCoordinator.sourceStoreGenerationRevision == sourceStoreGeneration,
          conversation.id == conversationID
        else {
          return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
          transientNotice = nil
        }
      } catch {
        return
      }
    }
  }

  private func compactTitle(_ content: String) -> String {
    let normalized = content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return normalized.count <= 52 ? normalized : String(normalized.prefix(51)) + "…"
  }

  private func scheduleDraftPersistence() {
    draftPersistenceTask?.cancel()
    draftPersistenceTask = Task { @MainActor in
      do {
        try await Task.sleep(for: .milliseconds(900))
        try Task.checkCancellation()
      } catch {
        return
      }
      draftPersistenceTask = nil
      _ = flushDraftPersistence()
    }
  }

  private func flushDraftPersistenceImmediately() {
    draftPersistenceTask?.cancel()
    draftPersistenceTask = nil
    _ = flushDraftPersistence()
  }

  @discardableResult
  private func flushDraftPersistence() -> Bool {
    do {
      switch try ConversationDraftPersistence.flush(
        in: modelContext,
        coordinator: MosaicOperationCoordinator.shared
      ) {
      case .noChanges, .saved:
        return true
      case .suppressedDuringMaintenance:
        return false
      }
    } catch {
      persistenceError = error.localizedDescription
      return false
    }
  }

  private var persistenceErrorIsPresented: Binding<Bool> {
    Binding(
      get: { persistenceError != nil },
      set: { if !$0 { persistenceError = nil } }
    )
  }

  private var liveTranscriptionErrorIsPresented: Binding<Bool> {
    Binding(
      get: { liveTranscriptionError != nil },
      set: { if !$0 { liveTranscriptionError = nil } }
    )
  }

  @discardableResult
  private func saveOrReport() -> Bool {
    do {
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
      return true
    } catch {
      modelContext.rollback()
      persistenceError = error.localizedDescription
      return false
    }
  }

}

enum ConversationDraftPersistenceResult: Equatable {
  case noChanges
  case saved
  case suppressedDuringMaintenance
}

@MainActor
enum ConversationDraftPersistence {
  static func flush(
    in modelContext: ModelContext,
    coordinator: MosaicOperationCoordinator
  ) throws -> ConversationDraftPersistenceResult {
    guard modelContext.hasChanges else { return .noChanges }
    do {
      try coordinator.saveSourceChanges(in: modelContext)
      return .saved
    } catch MosaicOperationCoordinatorError.maintenanceActive {
      // The coordinator already rolled back the pending edit. A restore/export lease is expected,
      // so draft autosave must stay silent instead of presenting a misleading persistence alert.
      return .suppressedDuringMaintenance
    } catch MosaicOperationCoordinatorError.sourceStoreUnavailable {
      // The durable recovery latch already owns the user-facing failure state and has rolled back
      // this edit. Do not layer a draft alert over the recovery screen.
      return .suppressedDuringMaintenance
    } catch {
      modelContext.rollback()
      throw error
    }
  }
}

private enum ConversationViewError: LocalizedError {
  case persistenceFailure

  var errorDescription: String? {
    "Turing AI could not persist the latest response update."
  }
}

private struct MessageBubble: View {
  @AppStorage(InterfacePreferences.advancedControlsKey) private var advancedControls = false
  @Environment(\.modelContext) private var modelContext
  @Query private var sourceRecords: [ExperienceRecord]
  @State private var presentedSources: MessageSourcesSnapshot?
  private var sourceReceipt: ExperienceValue? {
    sourceRecords.first.flatMap {
      try? JSONDecoder().decode(ExperienceValue.self, from: $0.payload)
    }
  }
  private var hasAttachments: Bool {
    let id = message.id
    var descriptor = FetchDescriptor<ExperienceRecord>(
      predicate: #Predicate { $0.messageID == id && $0.category == "attachment" })
    descriptor.fetchLimit = 1
    return (try? modelContext.fetchCount(descriptor)) ?? 0 > 0
  }
  let message: MosaicTranscriptMessage
  let providerKind: ProviderKind?
  let projectName: String?
  let remember: (MemoryScope) -> Void
  let retry: (() -> Void)?
  var edit: (() -> Void)? = nil
  var alternative: (() -> Void)? = nil
  var actionsDisabled = false

  var searchProgress: GoogleSearchProgress? = nil

  init(
    message: MosaicTranscriptMessage, providerKind: ProviderKind?, projectName: String?,
    remember: @escaping (MemoryScope) -> Void, retry: (() -> Void)?, edit: (() -> Void)? = nil,
    alternative: (() -> Void)? = nil, actionsDisabled: Bool = false,
    searchProgress: GoogleSearchProgress? = nil
  ) {
    self.message = message
    self.providerKind = providerKind
    self.projectName = projectName
    self.remember = remember
    self.retry = retry
    self.edit = edit
    self.alternative = alternative
    self.actionsDisabled = actionsDisabled
    self.searchProgress = searchProgress
    let id = message.id
    var descriptor = FetchDescriptor<ExperienceRecord>(
      predicate: #Predicate { $0.messageID == id && $0.category == "webSources" })
    descriptor.fetchLimit = 1
    _sourceRecords = Query(descriptor)
  }

  var body: some View {
    let receipt = sourceReceipt
    let snapshot = MessageSourcesSnapshot(
      id: message.id, sources: receipt?.sources ?? [],
      services: receipt?.searchedServices ?? [], searchNotice: receipt?.searchNotice,
      actions: receipt?.connectionActions ?? [])

    HStack {
      if message.role == .user { Spacer(minLength: 44) }
      VStack(alignment: .leading, spacing: 8) {
        if let searchProgress {
          MessageSearchActivityView(progress: searchProgress)
        } else if !snapshot.sources.isEmpty || !snapshot.services.isEmpty
          || snapshot.searchNotice != nil || !snapshot.actions.isEmpty
        {
          MessageSourcesButton(snapshot: snapshot) { presentedSources = snapshot }
        }
        ChatAttachmentStrip(messageID: message.id)
        if message.content.isEmpty, message.status == .streaming, searchProgress == nil {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Generating response")
        } else if !message.content.isEmpty {
          MosaicMarkdownView(
            source: message.role == .user && hasAttachments
              ? ChatAttachmentStore.displayText(message.content)
              : WebSearchCapability.annotated(message.content, sources: snapshot.sources)
          )
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        if message.status == .cancelled {
          Label("Stopped", systemImage: "stop.circle")
            .font(.caption)
            .foregroundStyle(Color.primary)
        }
        if let error = message.errorDescription, message.status == .failed {
          VStack(alignment: .leading, spacing: 6) {
            Label(error, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.red)
            if let retry {
              Button("Try again", action: retry)
                .font(.caption.weight(.semibold))
                .mosaicControlTarget()
            }
          }
        }
        if message.role == .assistant
          && (provenanceDescription != nil || message.inputTokenCount != nil
            || message.outputTokenCount != nil)
        {
          if advancedControls {
            responseDetails
          } else {
            DisclosureGroup("Response details") { responseDetails }
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .padding(.horizontal, message.role == .user ? 14 : 0)
      .padding(.vertical, message.role == .user ? 10 : 0)
      .background(
        message.role == .user
          ? AnyShapeStyle(Color.accentColor.opacity(0.14))
          : AnyShapeStyle(Color.clear),
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
      .frame(maxWidth: message.role == .user ? 620 : .infinity, alignment: .leading)
      .sheet(item: $presentedSources) { snapshot in
        MessageSourcesView(snapshot: snapshot)
      }
      .contextMenu {
        Button("Copy", systemImage: "doc.on.doc") {
          MosaicClipboard.copy(message.content)
        }
        if let edit {
          Button("Edit and continue", systemImage: "pencil", action: edit).disabled(actionsDisabled)
        }
        if let alternative {
          Button("Ask another model", systemImage: "arrow.triangle.branch", action: alternative)
            .disabled(actionsDisabled)
        }
        Menu("Remember", systemImage: "brain.head.profile") {
          Button("This Chat", systemImage: "bubble.left.and.bubble.right") {
            remember(.conversation)
          }
          if let projectName {
            Button(projectName, systemImage: "folder") {
              remember(.project)
            }
          }
          Button("Everywhere", systemImage: "globe") {
            remember(.global)
          }
        }
        .disabled(message.content.isEmpty)
      }
      .accessibilityAction(named: "Remember in this chat") {
        remember(.conversation)
      }
      .accessibilityActions {
        if let edit {
          Button("Edit and continue", action: edit).disabled(actionsDisabled)
        }
        if let alternative {
          Button("Ask another model", action: alternative).disabled(actionsDisabled)
        }
      }
      if message.role != .user { Spacer(minLength: 10) }
    }
  }

  private var responseDetails: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let input = message.inputTokenCount, let output = message.outputTokenCount {
        Text("\(input) input · \(output) output tokens")
          .font(.caption2)
          .foregroundStyle(Color.primary)
      }
      if let provenance = provenanceDescription {
        HStack(spacing: 6) {
          if let providerKind {
            ProviderLogoTile(provider: providerKind, size: 20)
              .accessibilityHidden(true)
          } else {
            Image(systemName: "server.rack")
              .accessibilityHidden(true)
          }
          Text(provenance)
        }
        .font(.caption)
        .foregroundStyle(Color.primary)
        .accessibilityLabel("Generated by \(provenance)")
      }
    }
  }

  private var provenanceDescription: String? {
    guard message.role == .assistant else { return nil }
    let values = [message.providerDisplayName, message.modelIdentifier, message.providerHost]
      .compactMap { value -> String? in
        guard let value, !value.isEmpty else { return nil }
        return value
      }
    return values.isEmpty ? nil : values.joined(separator: " · ")
  }
}

private struct ConversationStarter: View {
  let showsSuggestions: Bool
  let select: (String) -> Void

  private let suggestions: [(symbol: String, text: String)] = [
    ("calendar", "Help me plan this week"),
    ("text.alignleft", "Summarize an idea clearly"),
    ("arrow.triangle.branch", "Compare two approaches"),
  ]

  var body: some View {
    VStack(spacing: 28) {
      Text("How can I help?")
        .font(.largeTitle.bold())
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      if showsSuggestions {
        VStack(spacing: 10) {
          ForEach(suggestions, id: \.text) { suggestion in
            Button {
              select(suggestion.text)
            } label: {
              Label(suggestion.text, systemImage: suggestion.symbol)
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 16)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Adds this prompt to your draft")
          }
        }
        .frame(maxWidth: 340)
      }
    }
    .padding(.vertical, 24)
    .frame(maxWidth: .infinity)
  }
}

private struct ProviderMenuLabel: View {
  let provider: ProviderConfigurationRecord

  var body: some View {
    HStack(spacing: 7) {
      ProviderLogoTile(provider: provider.provider, size: 24)
        .accessibilityHidden(true)
      #if os(macOS)
        Text(provider.modelIdentifier)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: 200)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      #endif
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(provider.displayName), model \(provider.modelIdentifier)")
  }
}

private struct MemoryContextSheet: View {
  @Environment(\.dismiss) private var dismiss
  let curatedContext: MemoryContext
  let retrievedContext: RetrievedContext
  let projectContext: ProjectContextReceipt?
  let conversationContext: ConversationContextReceipt?
  let sameConversationRecall: SameConversationRecallReceipt?
  let conversationCompaction: ConversationCompactionReceipt?
  let conversationMessages: [MosaicTranscriptMessage]
  let isRecalling: Bool
  let isCompacting: Bool

  var body: some View {
    NavigationStack {
      Group {
        if isCompacting {
          VStack(spacing: 14) {
            ProgressView()
            Text("Compressing older conversation turns…")
              .foregroundStyle(.secondary)
          }
        } else if isRecalling {
          VStack(spacing: 14) {
            ProgressView()
            Text("Searching memory and earlier chat details…")
              .foregroundStyle(.secondary)
          }
        } else if curatedContext.includedMemories.isEmpty && retrievedContext.items.isEmpty
          && projectContext == nil && conversationContext == nil && sameConversationRecall == nil
          && conversationCompaction == nil
        {
          MosaicEmptyState(
            symbol: "brain.head.profile",
            title: "No context matched",
            message:
              "Turing AI searched locally but found no earlier message or document useful for the last request."
          ) {}
        } else {
          List {
            if let projectContext {
              Section("Project context") {
                LabeledContent("Project") {
                  Label(projectContext.name, systemImage: "folder.fill")
                }
                if !projectContext.instructions.isEmpty {
                  VStack(alignment: .leading, spacing: 6) {
                    Text("Instructions sent")
                      .font(.caption.weight(.semibold))
                      .foregroundStyle(.secondary)
                    Text(projectContext.instructions)
                      .textSelection(.enabled)
                  }
                }
              }
            }
            if let conversationCompaction {
              Section("Automatic history compression") {
                LabeledContent("Status") {
                  Text(compactionStatusLabel(conversationCompaction))
                }
                LabeledContent("Extra model requests") {
                  Text(conversationCompaction.extraRequestCount.formatted())
                }
                LabeledContent(
                  conversationCompaction.status == .reused ? "Summary model" : "Attempt model"
                ) {
                  Text(
                    "\(conversationCompaction.providerDisplayName) · \(conversationCompaction.modelIdentifier)"
                  )
                  .multilineTextAlignment(.trailing)
                }
                LabeledContent("Destination") {
                  Text(conversationCompaction.providerEndpoint)
                    .multilineTextAlignment(.trailing)
                }

                if conversationCompaction.status == .failed,
                  let activeProvider = conversationCompaction.activeSummaryProviderDisplayName,
                  let activeModel = conversationCompaction.activeSummaryModelIdentifier
                {
                  LabeledContent("Retained summary model") {
                    Text("\(activeProvider) · \(activeModel)")
                      .multilineTextAlignment(.trailing)
                  }
                  if let endpoint = conversationCompaction.activeSummaryProviderEndpoint {
                    LabeledContent("Retained summary destination") {
                      Text(endpoint)
                        .multilineTextAlignment(.trailing)
                    }
                  }
                }

                if let estimatedAfter = conversationCompaction.estimatedInputTokensAfter {
                  LabeledContent("Estimated reduction") {
                    Text(
                      "\(conversationCompaction.estimatedInputTokensBefore.formatted()) → \(estimatedAfter.formatted()) tokens"
                    )
                  }
                }

                if conversationCompaction.inputTokenCount != nil
                  || conversationCompaction.outputTokenCount != nil
                {
                  let inputLabel = conversationCompaction.inputTokenCount.map { "\($0)" } ?? "—"
                  let outputLabel =
                    conversationCompaction.outputTokenCount.map { "\($0)" } ?? "—"
                  LabeledContent(
                    conversationCompaction.status == .reused
                      ? "Original summary usage" : "Attempt usage"
                  ) {
                    Text("\(inputLabel) input · \(outputLabel) output")
                  }
                } else if conversationCompaction.extraRequestCount > 0 {
                  Label(
                    "The provider did not report token usage for the extra request. It may still incur provider charges.",
                    systemImage: "info.circle"
                  )
                  .font(.caption)
                  .foregroundStyle(.secondary)
                }

                if let summary = conversationCompaction.summaryText, !summary.isEmpty {
                  DisclosureGroup("Readable summary") {
                    Text(summary)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .textSelection(.enabled)
                  }
                }

                if !conversationCompaction.coveredMessageIDs.isEmpty {
                  DisclosureGroup(
                    "Summarized source messages (\(conversationCompaction.coveredMessageIDs.count))"
                  ) {
                    ForEach(
                      resolvedMessages(for: conversationCompaction.coveredMessageIDs),
                      id: \.id
                    ) { message in
                      conversationMessageRow(message)
                    }
                  }
                }

                if let attemptedIDs = conversationCompaction.attemptedMessageIDs,
                  attemptedIDs != conversationCompaction.coveredMessageIDs,
                  !attemptedIDs.isEmpty
                {
                  DisclosureGroup("Attempted raw source messages (\(attemptedIDs.count))") {
                    ForEach(resolvedMessages(for: attemptedIDs), id: \.id) { message in
                      conversationMessageRow(message)
                    }
                  }
                }

                if let error = conversationCompaction.errorDescription {
                  Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                ForEach(conversationCompaction.warnings, id: \.self) { warning in
                  Label(warning, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }

            if let conversationContext {
              Section("Conversation history") {
                LabeledContent("Included") {
                  Text(
                    "\(conversationContext.includedMessageCount) raw of \(conversationContext.originalMessageCount) messages"
                  )
                }
                if conversationContext.summarizedMessageCount > 0 {
                  LabeledContent("Represented by summary") {
                    Text(conversationContext.summarizedMessageCount.formatted())
                  }
                }
                if conversationContext.recalledMessageCount > 0 {
                  LabeledContent("Recalled exactly") {
                    Text(conversationContext.recalledMessageCount.formatted())
                  }
                }
                LabeledContent("Estimated input") {
                  Text(
                    "\(conversationContext.estimatedInputTokens.formatted()) of \(safeInputCapacity(for: conversationContext).formatted()) tokens"
                  )
                }

                if conversationContext.strategy == .summaryAndRecent {
                  Label(
                    "\(conversationContext.summarizedMessageCount) older messages were represented by the readable summary; \(conversationContext.omittedMessageCount) remained unsummarized for this request.",
                    systemImage: "rectangle.compress.vertical"
                  )
                  .foregroundStyle(.secondary)
                } else if conversationContext.strategy == .recentOnly {
                  Label(
                    "\(conversationContext.omittedMessageCount) older messages stayed in this chat but were not sent or summarized for this request.",
                    systemImage: "text.badge.minus"
                  )
                  .foregroundStyle(.secondary)
                } else {
                  Label(
                    "The complete chat history fit this request.", systemImage: "checkmark.circle"
                  )
                  .foregroundStyle(.secondary)
                }

                if let summarizedIDs = conversationContext.summarizedMessageIDs,
                  !summarizedIDs.isEmpty
                {
                  DisclosureGroup(
                    "Summarized older messages (\(summarizedIDs.count))"
                  ) {
                    ForEach(resolvedMessages(for: summarizedIDs), id: \.id) { message in
                      conversationMessageRow(message)
                    }
                  }
                }

                if let recalledIDs = conversationContext.recalledMessageIDs,
                  !recalledIDs.isEmpty
                {
                  DisclosureGroup(
                    "Exactly recalled older messages (\(recalledIDs.count))"
                  ) {
                    ForEach(resolvedMessages(for: recalledIDs), id: \.id) { message in
                      conversationMessageRow(message)
                    }
                  }
                }

                DisclosureGroup(
                  "Included messages (\(conversationContext.includedMessageCount))"
                ) {
                  ForEach(
                    resolvedMessages(for: conversationContext.includedMessageIDs),
                    id: \.id
                  ) { message in
                    conversationMessageRow(message)
                  }
                }

                if conversationContext.omittedMessageCount > 0 {
                  DisclosureGroup(
                    "Omitted older messages (\(conversationContext.omittedMessageCount))"
                  ) {
                    ForEach(
                      resolvedMessages(for: conversationContext.omittedMessageIDs),
                      id: \.id
                    ) { message in
                      conversationMessageRow(message)
                    }
                  }
                }

                ForEach(conversationContext.warnings, id: \.self) { warning in
                  Label(warning, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }

            if let sameConversationRecall {
              Section("Recalled from this chat") {
                LabeledContent("Eligible older user messages") {
                  Text(sameConversationRecall.eligibleCandidateCount.formatted())
                }
                if !sameConversationRecall.items.isEmpty {
                  LabeledContent("Attached input") {
                    Text("≈\(sameConversationRecall.injectedInputTokens.formatted()) tokens")
                  }
                }
                if sameConversationRecall.items.isEmpty {
                  Label(
                    "No exact older excerpt was attached to this request.",
                    systemImage: "text.magnifyingglass"
                  )
                  .foregroundStyle(.secondary)
                } else {
                  ForEach(sameConversationRecall.items) { item in
                    VStack(alignment: .leading, spacing: 5) {
                      Label(item.title, systemImage: "bubble.left.and.text.bubble.right")
                        .font(.headline)
                      HStack(spacing: 8) {
                        Text(item.origin == .summarized ? "Summary source" : "Omitted source")
                          .font(.caption)
                          .foregroundStyle(.secondary)
                        if item.isTruncated {
                          Text("Excerpt")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Truncated exact excerpt")
                        }
                      }
                      Text(item.content)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                      Text(item.createdAt, format: .dateTime.year().month().day())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                  }
                }
                ForEach(sameConversationRecall.warnings, id: \.self) { warning in
                  Label(warning, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }

            if !curatedContext.includedMemories.isEmpty {
              Section("Curated facts") {
                ForEach(curatedContext.includedMemories) { memory in
                  VStack(alignment: .leading, spacing: 5) {
                    HStack {
                      Text(memory.title)
                        .font(.headline)
                      Spacer()
                      Text(
                        memory.scope == .global
                          ? "Global" : (memory.scope == .project ? "Project" : "This chat")
                      )
                      .font(.caption)
                      .foregroundStyle(.secondary)
                    }
                    Text(memory.content)
                      .foregroundStyle(.secondary)
                  }
                  .padding(.vertical, 4)
                }
              }
            }

            if !retrievedContext.items.isEmpty {
              Section("Automatically recalled") {
                ForEach(retrievedContext.items) { item in
                  VStack(alignment: .leading, spacing: 5) {
                    HStack {
                      Label(
                        item.title,
                        systemImage: item.source == .conversationMessage
                          ? "bubble.left.and.bubble.right"
                          : (item.source == .memoryTopic ? "brain.head.profile" : "doc.text")
                      )
                      .font(.headline)
                      Spacer()
                      if item.source == .memoryTopic {
                        Text("Learned memory")
                          .font(.caption.weight(.semibold))
                          .foregroundStyle(.secondary)
                      }
                      if let page = item.pageNumber {
                        Text("Page \(page)")
                          .font(.caption)
                          .foregroundStyle(.secondary)
                      }
                      if item.isOCRDerived == true {
                        Text("OCR")
                          .font(.caption.weight(.semibold))
                          .foregroundStyle(.secondary)
                          .accessibilityLabel("Extracted with on-device OCR")
                      }
                    }
                    Text(item.content)
                      .foregroundStyle(.secondary)
                    Text(item.createdAt, format: .dateTime.year().month().day())
                      .font(.caption2)
                      .foregroundStyle(.tertiary)
                  }
                  .padding(.vertical, 4)
                }
              }
            }

            if !retrievedContext.embeddingProfilesUsed.isEmpty {
              Section("Retrieval engines") {
                Label("Local hybrid", systemImage: "internaldrive")
                ForEach(retrievedContext.embeddingProfilesUsed, id: \.self) { name in
                  Label(name, systemImage: "point.3.connected.trianglepath.dotted")
                }
              }
            }

            if !retrievedContext.warnings.isEmpty {
              Section("Fallbacks") {
                ForEach(retrievedContext.warnings, id: \.self) { warning in
                  Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                }
              }
            }

            if unresolvedReferencedMessageCount > 0 {
              Section("Source message display") {
                Label(
                  "\(unresolvedReferencedMessageCount.formatted()) older referenced messages are not in the currently loaded transcript pages. Their receipt counts remain exact; load earlier messages in the chat to inspect more rows.",
                  systemImage: "rectangle.stack.badge.plus"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .navigationTitle("Context receipt")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 420, minHeight: 360)
    #endif
  }

  private func safeInputCapacity(for receipt: ConversationContextReceipt) -> Int {
    let (afterOutput, outputOverflow) = receipt.contextWindowTokens.subtractingReportingOverflow(
      receipt.maximumOutputTokens
    )
    guard !outputOverflow else { return 1 }
    let (afterSafetyMargin, safetyOverflow) = afterOutput.subtractingReportingOverflow(
      receipt.safetyMarginTokens
    )
    guard !safetyOverflow else { return 1 }
    return max(1, afterSafetyMargin)
  }

  private func resolvedMessages(for ids: [UUID]) -> [MosaicTranscriptMessage] {
    let index = Dictionary(
      conversationMessages.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    return ids.compactMap { index[$0] }
  }

  private var unresolvedReferencedMessageCount: Int {
    var referencedIDs: Set<UUID> = []
    if let conversationCompaction {
      referencedIDs.formUnion(conversationCompaction.coveredMessageIDs)
      referencedIDs.formUnion(conversationCompaction.attemptedMessageIDs ?? [])
    }
    if let conversationContext {
      referencedIDs.formUnion(conversationContext.includedMessageIDs)
      referencedIDs.formUnion(conversationContext.omittedMessageIDs)
      referencedIDs.formUnion(conversationContext.summarizedMessageIDs ?? [])
      referencedIDs.formUnion(conversationContext.recalledMessageIDs ?? [])
    }
    let loadedIDs = Set(conversationMessages.map(\.id))
    return referencedIDs.subtracting(loadedIDs).count
  }

  private func compactionStatusLabel(_ receipt: ConversationCompactionReceipt) -> String {
    switch receipt.status {
    case .generating: "Started; completion not yet confirmed"
    case .generated: "Generated and used"
    case .reused: "Reused; no extra request"
    case .failed:
      receipt.activeSummaryProviderConfigurationID == nil
        ? "Failed; raw-history fallback used" : "Failed; previous summary reused"
    case .cancelled: "Stopped"
    }
  }

  private func conversationMessageRow(_ message: MosaicTranscriptMessage) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(message.role == .user ? "You" : "Assistant")
          .font(.caption.weight(.semibold))
        Spacer()
        Text(message.createdAt, style: .time)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Text(message.content)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
    }
    .accessibilityElement(children: .combine)
  }
}

enum MosaicClipboard {
  @MainActor
  static func copy(_ value: String) {
    #if os(iOS)
      UIPasteboard.general.string = value
    #elseif os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(value, forType: .string)
    #endif
  }
}

private struct TranscriptGeometry: Equatable {
  var height: CGFloat
  var bottom: CGFloat
  static let zero = TranscriptGeometry(height: 0, bottom: 0)
}

private struct TranscriptGeometryKey: PreferenceKey {
  static let defaultValue = TranscriptGeometry.zero
  static func reduce(value: inout TranscriptGeometry, nextValue: () -> TranscriptGeometry) {
    value = nextValue()
  }
}

private struct ConversationDeliveryDetails: View {
  @Environment(\.dismiss) private var dismiss
  let disclosure: String

  var body: some View {
    NavigationStack {
      Form {
        Text(disclosure).fixedSize(horizontal: false, vertical: true)
      }
      .navigationTitle("About this chat")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
    .frame(minWidth: 300, minHeight: 240)
  }
}

private struct TranscriptScrollObserver: ViewModifier {
  let viewportHeight: CGFloat
  let changed: (Bool) -> Void
  let interactionChanged: (Bool) -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 18, macOS 15, *) {
      content
        .onScrollGeometryChange(for: Bool.self) { geometry in
          geometry.contentSize.height - geometry.visibleRect.maxY <= 36
        } action: { _, geometry in
          changed(geometry)
        }
        .onScrollPhaseChange { _, phase in
          if phase == .tracking || phase == .interacting { interactionChanged(true) }
          if phase == .idle { interactionChanged(false) }
        }
    } else {
      content
        .onPreferenceChange(TranscriptGeometryKey.self) { geometry in
          changed(geometry.bottom - viewportHeight <= 36)
        }
        .simultaneousGesture(
          DragGesture().onChanged { _ in interactionChanged(true) }
            .onEnded { _ in interactionChanged(false) }
        )
    }
  }
}

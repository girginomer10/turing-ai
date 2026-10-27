import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private struct MosaicMemoryLibraryRequest: Hashable {
  let query: String
  let topicCursor: MosaicMemoryLibraryTopicCursor?
  let memoryCursor: MosaicMemoryLibraryMemoryCursor?
  let documentCursor: MosaicMemoryLibraryDocumentCursor?
  let sourceStoreGenerationRevision: UInt64
  let memoryLibraryRevision: UInt64
  let conversationCatalogRevision: UInt64
  let reloadRevision: UInt64
  let sourceAccessIsBlocked: Bool
}

private struct MosaicMemoryConversationRequest: Hashable {
  let query: String
  let cursor: MosaicMemoryLibraryConversationCursor?
  let selectedID: UUID?
  let sourceStoreGenerationRevision: UInt64
  let conversationCatalogRevision: UInt64
  let sourceAccessIsBlocked: Bool
}

private struct PendingMemoryDeletion: Identifiable {
  let item: MosaicMemoryLibraryItem
  let sourceGeneration: UInt64
  let libraryRevision: UInt64

  var id: UUID { item.id }
}

private struct PendingDocumentDeletion: Identifiable {
  let item: MosaicMemoryLibraryDocumentItem
  let sourceGeneration: UInt64
  let libraryRevision: UInt64

  var id: UUID { item.id }
}

private struct PendingTopicForget: Identifiable {
  let item: MosaicMemoryLibraryTopicItem
  let sourceGeneration: UInt64
  let libraryRevision: UInt64

  var id: UUID { item.id }
}

private enum MemoryLibraryMutationError: LocalizedError {
  case recordChanged
  case recordMissing
  case conversationMissing
  case projectMissing

  var errorDescription: String? {
    switch self {
    case .recordChanged:
      "This item changed in another window. Review the latest version and try again."
    case .recordMissing:
      "This item is no longer available."
    case .conversationMissing:
      "The selected conversation is no longer available. Choose another conversation."
    case .projectMissing:
      "The selected project is no longer available. Choose another project."
    }
  }
}

/// Curated facts, automatic past-chat recall, and imported knowledge sources.
@MainActor
public struct MemoryLibraryView: View {
  @AppStorage(InterfacePreferences.advancedControlsKey) private var advancedControls = false
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \ProviderConfigurationRecord.createdAt)
  private var providers: [ProviderConfigurationRecord]
  @Query(sort: \ProjectRecord.name)
  private var projects: [ProjectRecord]
  @AppStorage(AutomaticMemorySettings.enabledKey)
  private var automaticMemoryEnabled = true

  @State private var operationCoordinator = MosaicOperationCoordinator.shared
  @State private var snapshot = MosaicMemoryLibrarySnapshot.empty
  @State private var loadedRequest: MosaicMemoryLibraryRequest?
  @State private var memoryCursorHistory: [MosaicMemoryLibraryMemoryCursor] = []
  @State private var topicCursorHistory: [MosaicMemoryLibraryTopicCursor] = []
  @State private var documentCursorHistory: [MosaicMemoryLibraryDocumentCursor] = []
  @State private var reloadRevision: UInt64 = 0
  @State private var isLoading = false
  @State private var searchText = ""
  @State private var isAddingMemory = false
  @State private var addingMemorySourceGeneration: UInt64?
  @State private var editingMemory: MosaicMemoryLibraryItem?
  @State private var editingMemorySourceGeneration: UInt64?
  @State private var selectedTopic: MosaicMemoryLibraryTopicItem?
  @State private var editingTopic: MosaicMemoryLibraryTopicItem?
  @State private var editingTopicSourceGeneration: UInt64?
  @State private var pendingTopicForget: PendingTopicForget?
  @State private var showRetryFailedMemoryConfirmation = false
  @State private var isRetryingFailedMemory = false
  @State private var failedMemoryRetryTask: Task<Void, Never>?
  @State private var failedMemoryRetryStatus: String?
  @State private var pendingDeletion: PendingMemoryDeletion?
  @State private var pendingDocumentDeletion: PendingDocumentDeletion?
  @State private var showEmbeddingProfiles = false
  @State private var showDocumentImporter = false
  @State private var documentImportProjectID: UUID?
  @State private var isImportingDocuments = false
  @State private var isCancellingDocumentImport = false
  @State private var importTask: Task<Void, Never>?
  @State private var importTaskID: UUID?
  @State private var importStatusMessage: String?
  @State private var deletingDocument: MosaicMemoryLibraryDocumentItem?
  @State private var documentDeletionTask: Task<Void, Never>?
  @State private var documentDeletionTaskID: UUID?
  @State private var documentDeletionCommitStarted = false
  @State private var isCancellingDocumentDeletion = false
  @State private var errorMessage: String?

  private static let pageSize = 16

  public init() {}

  private var activeProjects: [ProjectRecord] {
    projects.filter { !$0.isArchived }
  }

  public var body: some View {
    memoryLifecycleView
  }

  private var memoryList: some View {
    List {
      #if os(macOS)
        memorySearchSection
      #endif

      memoryControlIntroSection

      automaticMemorySection

      if advancedControls { formationActivitySection }

      knowledgeIndexSection

      learnedTopicsSection

      importedDocumentsSection

      savedMemoriesSection

      if advancedControls { provenanceSection }
    }
    .navigationTitle("Memory")
    #if os(iOS)
      .searchable(text: $searchText, prompt: "Search memories")
    #endif
    // Keep the pre-commit Cancel control in the later overlay hittable while the list itself is
    // frozen against a second mutation.
    .allowsHitTesting(deletingDocument == nil)
    .toolbar {
      memoryToolbar
    }
    .overlay {
      if let deletingDocument {
        VStack(spacing: 12) {
          ProgressView(
            documentDeletionCommitStarted
              ? "Finishing deletion…"
              : (isCancellingDocumentDeletion ? "Stopping deletion…" : "Deleting document…")
          )
          Text(deletingDocument.title)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if !documentDeletionCommitStarted {
            Button("Cancel", role: .cancel) {
              isCancellingDocumentDeletion = true
              documentDeletionTask?.cancel()
            }
            .disabled(isCancellingDocumentDeletion)
          }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
      }
    }
  }

  private var memoryPresentedView: some View {
    memoryList
      .sheet(isPresented: $isAddingMemory) {
        MemoryEditorView(
          memory: nil,
          sourceGeneration: addingMemorySourceGeneration
            ?? operationCoordinator.sourceStoreGenerationRevision
        )
      }
      .sheet(item: $editingMemory) { memory in
        MemoryEditorView(
          memory: memory,
          sourceGeneration: editingMemorySourceGeneration
            ?? operationCoordinator.sourceStoreGenerationRevision
        )
      }
      .sheet(item: $selectedTopic) { topic in
        AutomaticMemoryTopicDetailView(topic: topic)
      }
      .sheet(item: $editingTopic) { topic in
        AutomaticMemoryTopicEditorView(
          topic: topic,
          sourceGeneration: editingTopicSourceGeneration
            ?? operationCoordinator.sourceStoreGenerationRevision
        )
      }
      .sheet(isPresented: $showEmbeddingProfiles) {
        EmbeddingProfilesView()
      }
      .fileImporter(
        isPresented: $showDocumentImporter,
        allowedContentTypes: [.pdf, .plainText, .utf8PlainText, .text],
        allowsMultipleSelection: true,
        onCompletion: importDocuments
      )
  }

  private var memoryConfirmedView: some View {
    memoryPresentedView
      .confirmationDialog(
        "Retry failed memory updates?",
        isPresented: $showRetryFailedMemoryConfirmation,
        titleVisibility: .visible
      ) {
        Button("Retry \(snapshot.failedFormationJobCount) Updates") {
          retryFailedMemoryUpdates()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "Turing AI will contact the provider originally used for each chat. This may use provider API credits."
        )
      }
      .confirmationDialog(
        "Forget this learned topic?",
        isPresented: topicForgetDialogIsPresented,
        titleVisibility: .visible,
        presenting: pendingTopicForget
      ) { pending in
        Button("Forget Topic", role: .destructive) {
          forget(pending)
        }
        Button("Cancel", role: .cancel) {}
      } message: { pending in
        Text(
          "“\(pending.item.title)” will stop being recalled as a learned topic in new chats. Its sources and change history stay available for review; the original text can still be part of its original chat."
        )
      }
      .confirmationDialog(
        "Delete this memory?",
        isPresented: deletionDialogIsPresented,
        titleVisibility: .visible,
        presenting: pendingDeletion
      ) { pending in
        Button("Delete Memory", role: .destructive) {
          delete(pending)
        }
        Button("Cancel", role: .cancel) {}
      } message: { pending in
        Text(
          "“\(displayTitle(for: pending.item))” will no longer be available to any conversation.")
      }
      .confirmationDialog(
        "Delete this document?",
        isPresented: documentDeletionDialogIsPresented,
        titleVisibility: .visible,
        presenting: pendingDocumentDeletion
      ) { pending in
        Button("Delete Document", role: .destructive) { delete(pending) }
        Button("Cancel", role: .cancel) {}
      } message: { pending in
        Text("“\(pending.item.title)” and its local search index will be removed.")
      }
      .alert("Memory couldn’t be updated", isPresented: errorIsPresented) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "Please try again.")
      }
  }

  private var memoryLifecycleView: some View {
    memoryConfirmedView
      .onChange(of: searchText) { previous, current in
        guard Self.normalizedQuery(previous) != Self.normalizedQuery(current) else { return }
        memoryCursorHistory = []
        topicCursorHistory = []
      }
      .onChange(of: operationCoordinator.memoryLibraryRevision) { _, _ in
        pendingTopicForget = nil
        pendingDeletion = nil
        pendingDocumentDeletion = nil
        memoryCursorHistory = []
        topicCursorHistory = []
        documentCursorHistory = []
      }
      .onChange(of: operationCoordinator.conversationCatalogRevision) { _, _ in
        memoryCursorHistory = []
      }
      .onChange(of: operationCoordinator.sourceStoreGenerationRevision) { _, _ in
        clearForSourceReplacement()
      }
      .onChange(of: operationCoordinator.isSourceAccessBlocked) { _, isBlocked in
        if isBlocked {
          pendingTopicForget = nil
          pendingDeletion = nil
          pendingDocumentDeletion = nil
        }
      }
      .task(id: libraryRequest) {
        await loadLibrary(for: libraryRequest)
      }
      .onDisappear(perform: handleDisappear)
  }

  @AppStorage("smartMemoryEnabled") private var smartMemoryEnabled = true

  private var automaticMemorySection: some View {
    Section {
      if advancedControls {
        Toggle("Smart memory", isOn: $smartMemoryEnabled)
        Text(
          "Checks a limited set of eligible memories with your selected chat model, including across languages. It may still add a few memories when nothing applies. This uses an additional API request. When enabled it takes precedence over the optional reranker. Turn off to use local matching and your embedding profiles only."
        ).font(.footnote).foregroundStyle(.secondary)
      }
      Toggle(isOn: $automaticMemoryEnabled) {
        Label("Learn from new chats", systemImage: "brain.filled.head.profile")
      }
      .accessibilityHint(
        "After a successful reply, the selected chat model can consolidate durable user facts in the background"
      )

      LabeledContent("Topics on this page") {
        Text(snapshot.topics.items.count.formatted())
          .foregroundStyle(.secondary)
      }

      if snapshot.failedFormationJobCount > 0 {
        Button {
          showRetryFailedMemoryConfirmation = true
        } label: {
          if isRetryingFailedMemory {
            Label("Retrying Memory Updates…", systemImage: "arrow.clockwise.circle")
          } else {
            Label(failedFormationJobDescription, systemImage: "arrow.clockwise.circle")
          }
        }
        .disabled(isRetryingFailedMemory || operationCoordinator.isSourceAccessBlocked)
        .accessibilityHint(
          "Retries failed background memory work with each chat’s configured provider"
        )
      }

      if let failedMemoryRetryStatus {
        Text(failedMemoryRetryStatus)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Automatic memory")
    } footer: {
      Text(
        "Runs after the answer is saved and never delays or changes the reply. Learned topics are consolidated instead of copying whole chats. Each run may use an additional request and API credits from that chat’s provider."
      )
      .lineLimit(nil)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private var formationActivitySection: some View {
    if !snapshot.recentFormationAudits.isEmpty {
      Section {
        LabeledContent("Provider requests") {
          Text(clampedAuditSum(\.providerRequestCount).formatted())
            .foregroundStyle(.secondary)
        }
        LabeledContent("Recorded tokens") {
          Text(clampedRecordedTokenTotal.formatted())
            .foregroundStyle(.secondary)
        }

        DisclosureGroup("Recent runs") {
          ForEach(snapshot.recentFormationAudits.prefix(8)) { audit in
            VStack(alignment: .leading, spacing: 5) {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(
                  formationAuditStatusLabel(audit.outcome),
                  systemImage: formationAuditStatusSymbol(audit.outcome)
                )
                .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(audit.finishedAt, format: .relative(presentation: .named))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              Text(auditProviderDescription(audit))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

              HStack(spacing: 12) {
                Label(
                  "\((audit.cumulativeTotalTokenCount ?? 0).formatted()) tokens",
                  systemImage: "number"
                )
                Label(
                  "\(audit.providerRequestCount.formatted()) requests",
                  systemImage: "arrow.up.right"
                )
              }
              .font(.caption2)
              .foregroundStyle(.secondary)

              if audit.didDiscardInvalidTelemetry {
                Label(
                  "Some provider telemetry was invalid and omitted",
                  systemImage: "shield.lefthalf.filled"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
              }
              if let error = audit.errorDescription, !error.isEmpty {
                Text(error)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
            }
            .padding(.vertical, 4)
          }
        }
      } header: {
        Text("Memory activity")
      } footer: {
        Text(
          "A durable local receipt records provider requests and reported token usage for automatic memory formation, including retries."
        )
      }
    }
  }

  private var clampedRecordedTokenTotal: Int {
    clampedAuditSum { $0.cumulativeTotalTokenCount ?? 0 }
  }

  private func clampedAuditSum(
    _ value: (AutomaticMemoryFormationAuditSnapshot) -> Int
  ) -> Int {
    snapshot.recentFormationAudits.reduce(into: 0) { total, audit in
      let (next, overflow) = total.addingReportingOverflow(max(0, value(audit)))
      total = overflow ? Int.max : next
    }
  }

  private func auditProviderDescription(
    _ audit: AutomaticMemoryFormationAuditSnapshot
  ) -> String {
    let values: [String] = [audit.providerDisplayName, audit.modelIdentifier].compactMap { value in
      guard let value, !value.isEmpty else { return nil }
      return value
    }
    return values.isEmpty
      ? "No provider request was opened"
      : values.joined(separator: " · ")
  }

  private func formationAuditStatusLabel(_ status: MemoryFormationJobStatus) -> String {
    switch status {
    case .pending: "Waiting"
    case .generating: "In progress"
    case .complete: "Completed"
    case .failed: "Failed"
    case .rejected: "Not applied"
    }
  }

  private func formationAuditStatusSymbol(_ status: MemoryFormationJobStatus) -> String {
    switch status {
    case .pending: "clock"
    case .generating: "hourglass"
    case .complete: "checkmark.circle"
    case .failed: "exclamationmark.triangle"
    case .rejected: "xmark.shield"
    }
  }

  @ToolbarContentBuilder
  private var memoryToolbar: some ToolbarContent {
    #if os(iOS)
      ToolbarItem(id: "memory-edit", placement: .secondaryAction) {
        EditButton()
      }
    #endif
    ToolbarItem(id: "memory-add", placement: .primaryAction) {
      Button(action: presentAddMemory) {
        Label("Add Memory", systemImage: "plus")
      }
      .disabled(!libraryIsCurrent)
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .accessibilityHint("Opens the memory editor")
    }
  }

  private var knowledgeIndexSection: some View {
    Section {
      if advancedControls {
        LabeledContent {
          Text(embeddingSummary)
            .foregroundStyle(.secondary)
        } label: {
          Label("Automatic recall", systemImage: "sparkle.magnifyingglass")
        }

        Button {
          showEmbeddingProfiles = true
        } label: {
          Label("Embedding Models", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .disabled(operationCoordinator.isSourceAccessBlocked)
      }

      if isImportingDocuments {
        HStack {
          Label(
            isCancellingDocumentImport ? "Stopping import…" : "Importing…",
            systemImage: "hourglass"
          )
          .foregroundStyle(.secondary)
          Spacer()
          Button("Stop", role: .cancel) {
            isCancellingDocumentImport = true
            importTask?.cancel()
          }
          .disabled(isCancellingDocumentImport)
        }
      } else {
        Menu {
          Button {
            presentDocumentImporter(projectID: nil)
          } label: {
            Label("Everywhere", systemImage: "globe")
          }

          if !activeProjects.isEmpty {
            Section("Projects") {
              ForEach(activeProjects) { project in
                Button {
                  presentDocumentImporter(projectID: project.id)
                } label: {
                  Label(project.name, systemImage: "folder")
                }
              }
            }
          }
        } label: {
          Label("Import PDF or Text", systemImage: "doc.badge.plus")
        }
        .accessibilityHint(
          "Choose whether the imported documents are available everywhere or only in one project"
        )
        .disabled(operationCoordinator.isSourceAccessBlocked)
      }

      if let importStatusMessage {
        Label(importStatusMessage, systemImage: "info.circle")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text(advancedControls ? "Knowledge index" : "Documents")
    } footer: {
      Text(
        advancedControls
          ? "Recall runs without an approval step. A local Turkish-aware fallback is always active; enabled embedding models add semantic matching."
          : "Relevant memories and document excerpts can be included in your chats automatically. Smart matching may use an extra request to your selected AI service. You can review what was used from the Memory button in a chat."
      )
      .lineLimit(nil)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func handleDisappear() {
    if !documentDeletionCommitStarted { documentDeletionTask?.cancel() }
  }

  private var memorySearchSection: some View {
    Section {
      TextField("Search memories", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Search memories")
    }
  }

  private var memoryControlIntroSection: some View {
    Section {
      Label {
        VStack(alignment: .leading, spacing: 4) {
          Text("You control what Turing AI remembers")
            .font(.headline)
          Text(
            "Turing AI learns durable facts from completed chats, keeps their source history, and recalls the right ones later. You can still pin exact facts manually."
          )
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
        }
      } icon: {
        Image(systemName: "person.crop.circle.badge.checkmark")
          .foregroundStyle(.tint)
      }
      .accessibilityElement(children: .combine)
    }
  }

  @ViewBuilder
  private var learnedTopicsSection: some View {
    if !snapshot.topics.items.isEmpty {
      ForEach([true, false], id: \.self) { events in
        let topics = snapshot.topics.items.filter { ($0.kind == .event) == events }
        if !topics.isEmpty {
          Section {
            ForEach(topics) { topic in
              AutomaticMemoryTopicRow(
                topic: topic,
                onOpen: { selectedTopic = topic },
                onEdit: { presentTopicEditor(for: topic) },
                onForget: { requestTopicForget(topic) },
                onEnabledChange: { setTopicEnabled($0, for: topic) }
              )
              .swipeActions(edge: .trailing) {
                Button("Forget", systemImage: "trash", role: .destructive) {
                  requestTopicForget(topic)
                }
                .accessibilityHint(
                  "Stops this learned topic from being recalled in new chats and records the change"
                )
              }
            }
          } header: {
            Text(events ? "Events" : "Lasting information")
          } footer: {
            if events {
              Text(
                "Personal events keep their dates and updates. Their relevance fades over time; they do not become permanent facts."
              )
            }
          }
        }
      }
      Section {
        paginationControls(
          pageNumber: topicCursorHistory.count + 1,
          hasPrevious: !topicCursorHistory.isEmpty,
          nextCursor: snapshot.topics.nextCursor,
          previous: { topicCursorHistory.removeLast() },
          next: { cursor in topicCursorHistory.append(cursor) }
        )
      }
    }
  }

  private var provenanceSection: some View {
    Section("Provenance") {
      Label("Inspectable and correctable", systemImage: "list.bullet.clipboard")
      Text(
        "Open a learned topic to see its exact source messages and change history. Current topics outrank older raw chat excerpts when values change."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .lineLimit(nil)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private var importedDocumentsSection: some View {
    if !snapshot.documents.items.isEmpty {
      Section("Imported documents") {
        ForEach(snapshot.documents.items) { document in
          HStack(spacing: 12) {
            Image(
              systemName: document.mimeType == "application/pdf" ? "doc.richtext" : "doc.text"
            )
            .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
              Text(document.title)
                .font(.headline)
              Text(documentDescription(document))
                .font(.caption)
                .foregroundStyle(.secondary)

              Menu {
                documentProjectActions(for: document)
              } label: {
                Label(
                  documentScopeDescription(document),
                  systemImage: document.projectID == nil ? "globe" : "folder"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .mosaicControlTarget()
              .disabled(!libraryIsCurrent)
              .accessibilityHint("Changes where this document can be recalled")
            }
            Spacer()
            Toggle(
              "Use \(document.title)",
              isOn: Binding(
                get: { document.isEnabled },
                set: { setDocumentEnabled($0, for: document) }
              )
            )
            .labelsHidden()
          }
          .contextMenu {
            Menu("Availability", systemImage: "folder") {
              documentProjectActions(for: document)
            }
            Divider()
            Button("Delete Document", systemImage: "trash", role: .destructive) {
              requestDocumentDeletion(document)
            }
          }
          .swipeActions {
            Button("Delete", role: .destructive) {
              requestDocumentDeletion(document)
            }
          }
        }
        paginationControls(
          pageNumber: documentCursorHistory.count + 1,
          hasPrevious: !documentCursorHistory.isEmpty,
          nextCursor: snapshot.documents.nextCursor,
          previous: { documentCursorHistory.removeLast() },
          next: { cursor in documentCursorHistory.append(cursor) }
        )
      }
    }
  }

  @ViewBuilder
  private var savedMemoriesSection: some View {
    if snapshot.memories.items.isEmpty && snapshot.topics.items.isEmpty {
      Section {
        if isLoading {
          ProgressView("Loading memories…")
        } else {
          ContentUnavailableView {
            Label(
              emptyTitle,
              systemImage: normalizedSearchText.isEmpty
                ? "brain.head.profile" : "magnifyingglass"
            )
          } description: {
            Text(emptyDescription)
          } actions: {
            if normalizedSearchText.isEmpty {
              Button("Add Memory", action: presentAddMemory)
                .buttonStyle(.borderedProminent)
                .disabled(!libraryIsCurrent)
            }
          }
        }
      }
    } else if !snapshot.memories.items.isEmpty {
      Section("Saved memories") {
        ForEach(snapshot.memories.items) { memory in
          MemoryLibraryRow(
            memory: memory,
            onEdit: { presentEditor(for: memory) },
            onDelete: { requestMemoryDeletion(memory) },
            onEnabledChange: { setEnabled($0, for: memory) }
          )
          .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) {
              requestMemoryDeletion(memory)
            }
            .accessibilityHint("Deletes this saved memory")
          }
        }
        .onDelete(perform: deleteMemories)
        paginationControls(
          pageNumber: memoryCursorHistory.count + 1,
          hasPrevious: !memoryCursorHistory.isEmpty,
          nextCursor: snapshot.memories.nextCursor,
          previous: { memoryCursorHistory.removeLast() },
          next: { cursor in memoryCursorHistory.append(cursor) }
        )
      }
    }
  }

  private var normalizedSearchText: String {
    Self.normalizedQuery(searchText)
  }

  private var libraryRequest: MosaicMemoryLibraryRequest {
    MosaicMemoryLibraryRequest(
      query: normalizedSearchText,
      topicCursor: topicCursorHistory.last,
      memoryCursor: memoryCursorHistory.last,
      documentCursor: documentCursorHistory.last,
      sourceStoreGenerationRevision: operationCoordinator.sourceStoreGenerationRevision,
      memoryLibraryRevision: operationCoordinator.memoryLibraryRevision,
      conversationCatalogRevision: operationCoordinator.conversationCatalogRevision,
      reloadRevision: reloadRevision,
      sourceAccessIsBlocked: operationCoordinator.isSourceAccessBlocked
    )
  }

  private var libraryIsCurrent: Bool {
    loadedRequest == libraryRequest && !operationCoordinator.isSourceAccessBlocked
  }

  private var embeddingSummary: String {
    let enabled = snapshot.enabledEmbeddingProfileCount
    return enabled == 0
      ? "Local hybrid"
      : "Local hybrid + \(enabled) embedding \(enabled == 1 ? "model" : "models")"
  }

  private var failedFormationJobDescription: String {
    let count = snapshot.failedFormationJobCount
    return count == 1 ? "Retry 1 Failed Memory Update" : "Retry \(count) Failed Memory Updates"
  }

  private func documentDescription(_ document: MosaicMemoryLibraryDocumentItem) -> String {
    var values = ["\(document.chunkCount) chunks"]
    if let pages = document.pageCount { values.append("\(pages) pages") }
    if document.ocrPageCount > 0 { values.append("\(document.ocrPageCount) OCR pages") }
    if document.ocrFallbackPageCount > 0 {
      values.append("\(document.ocrFallbackPageCount) embedded-text fallbacks")
    }
    values.append("\(document.characterCount.formatted()) characters")
    return values.joined(separator: " · ")
  }

  private func documentScopeDescription(_ document: MosaicMemoryLibraryDocumentItem) -> String {
    guard document.projectID != nil else { return "Everywhere" }
    return document.projectName ?? "Unavailable project"
  }

  @ViewBuilder
  private func documentProjectActions(for document: MosaicMemoryLibraryDocumentItem) -> some View {
    Button {
      setDocumentProject(nil, for: document)
    } label: {
      Label(
        "Everywhere",
        systemImage: document.projectID == nil ? "checkmark" : "globe"
      )
    }

    if !activeProjects.isEmpty {
      Section("Projects") {
        ForEach(activeProjects) { project in
          Button {
            setDocumentProject(project.id, for: document)
          } label: {
            Label(
              project.name,
              systemImage: document.projectID == project.id ? "checkmark" : "folder"
            )
          }
        }
      }
    }
  }

  private var emptyTitle: String {
    normalizedSearchText.isEmpty ? "No memories yet" : "No matching memories"
  }

  private var emptyDescription: String {
    normalizedSearchText.isEmpty
      ? "Save a preference or fact you want to reuse across conversations."
      : "Try a different title or phrase."
  }

  private var deletionDialogIsPresented: Binding<Bool> {
    Binding(
      get: { pendingDeletion != nil },
      set: { if !$0 { pendingDeletion = nil } }
    )
  }

  private var documentDeletionDialogIsPresented: Binding<Bool> {
    Binding(
      get: { pendingDocumentDeletion != nil },
      set: { if !$0 { pendingDocumentDeletion = nil } }
    )
  }

  private var topicForgetDialogIsPresented: Binding<Bool> {
    Binding(
      get: { pendingTopicForget != nil },
      set: { if !$0 { pendingTopicForget = nil } }
    )
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  @ViewBuilder
  private func paginationControls<Cursor: Sendable>(
    pageNumber: Int,
    hasPrevious: Bool,
    nextCursor: Cursor?,
    previous: @escaping () -> Void,
    next: @escaping (Cursor) -> Void
  ) -> some View {
    if hasPrevious || nextCursor != nil {
      HStack(spacing: 8) {
        Button("Newer", systemImage: "chevron.up", action: previous)
          .disabled(!hasPrevious || isLoading)
        Spacer(minLength: 4)
        Text("Page \(pageNumber.formatted())")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 4)
        Button("Older", systemImage: "chevron.down") {
          if let nextCursor { next(nextCursor) }
        }
        .disabled(nextCursor == nil || isLoading)
      }
      .buttonStyle(.borderless)
    }
  }

  private func loadLibrary(for request: MosaicMemoryLibraryRequest) async {
    guard request == libraryRequest, !request.sourceAccessIsBlocked else { return }
    if loadedRequest?.sourceStoreGenerationRevision != request.sourceStoreGenerationRevision {
      snapshot = .empty
      loadedRequest = nil
    }
    isLoading = true
    defer {
      if libraryRequest == request { isLoading = false }
    }
    do {
      if !request.query.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
      try Task.checkCancellation()
      let repository = MosaicMemoryLibraryRepository(modelContainer: modelContext.container)
      let loaded = try await repository.snapshot(
        query: request.query,
        memoryAfter: request.memoryCursor,
        documentAfter: request.documentCursor,
        topicAfter: request.topicCursor,
        pageSize: Self.pageSize
      )
      try Task.checkCancellation()
      guard libraryRequest == request else { return }
      snapshot = loaded
      loadedRequest = request
    } catch is CancellationError {
      return
    } catch {
      guard libraryRequest == request else { return }
      errorMessage = error.localizedDescription
    }
  }

  private func presentAddMemory() {
    guard libraryIsCurrent else { return }
    addingMemorySourceGeneration = operationCoordinator.sourceStoreGenerationRevision
    isAddingMemory = true
  }

  private func presentDocumentImporter(projectID: UUID?) {
    guard libraryIsCurrent, !isImportingDocuments else { return }
    if let projectID,
      !activeProjects.contains(where: { $0.id == projectID })
    {
      errorMessage = MemoryLibraryMutationError.projectMissing.localizedDescription
      return
    }
    documentImportProjectID = projectID
    showDocumentImporter = true
  }

  private func presentEditor(for memory: MosaicMemoryLibraryItem) {
    guard libraryIsCurrent else { return }
    editingMemorySourceGeneration = operationCoordinator.sourceStoreGenerationRevision
    editingMemory = memory
  }

  private func presentTopicEditor(for topic: MosaicMemoryLibraryTopicItem) {
    guard libraryIsCurrent else { return }
    editingTopicSourceGeneration = operationCoordinator.sourceStoreGenerationRevision
    editingTopic = topic
  }

  private func requestTopicForget(_ topic: MosaicMemoryLibraryTopicItem) {
    guard libraryIsCurrent, topic.status == .active else { return }
    pendingTopicForget = PendingTopicForget(
      item: topic,
      sourceGeneration: operationCoordinator.sourceStoreGenerationRevision,
      libraryRevision: operationCoordinator.memoryLibraryRevision
    )
  }

  private func requestMemoryDeletion(_ memory: MosaicMemoryLibraryItem) {
    guard libraryIsCurrent else { return }
    pendingDeletion = PendingMemoryDeletion(
      item: memory,
      sourceGeneration: operationCoordinator.sourceStoreGenerationRevision,
      libraryRevision: operationCoordinator.memoryLibraryRevision
    )
  }

  private func requestDocumentDeletion(_ document: MosaicMemoryLibraryDocumentItem) {
    guard libraryIsCurrent else { return }
    pendingDocumentDeletion = PendingDocumentDeletion(
      item: document,
      sourceGeneration: operationCoordinator.sourceStoreGenerationRevision,
      libraryRevision: operationCoordinator.memoryLibraryRevision
    )
  }

  private func retryFailedMemoryUpdates() {
    guard failedMemoryRetryTask == nil,
      snapshot.failedFormationJobCount > 0,
      !operationCoordinator.isSourceAccessBlocked
    else {
      return
    }

    let sourceGeneration = operationCoordinator.sourceStoreGenerationRevision
    isRetryingFailedMemory = true
    failedMemoryRetryStatus = nil
    failedMemoryRetryTask = Task { @MainActor in
      var didAttemptMemoryUpdate = false
      defer {
        if didAttemptMemoryUpdate { operationCoordinator.markMemoryLibraryChanged() }
        isRetryingFailedMemory = false
        failedMemoryRetryTask = nil
      }
      do {
        let repository = MosaicMemoryLibraryRepository(modelContainer: modelContext.container)
        guard let boundary = try await repository.failedFormationJobRetryBoundary() else {
          failedMemoryRetryStatus = "No failed memory updates remain."
          return
        }
        var completedCount = 0
        var remainingCount = 0
        var cursor: MosaicMemoryFormationJobCursor?
        var attemptedJobIDs: Set<UUID> = []

        retryPages: while true {
          let jobs = try await repository.failedFormationJobs(
            after: cursor,
            through: boundary
          )
          guard !jobs.isEmpty else { break }
          cursor = jobs.last.map {
            MosaicMemoryFormationJobCursor(updatedAt: $0.updatedAt, id: $0.id)
          }

          for job in jobs where attemptedJobIDs.insert(job.id).inserted {
            try Task.checkCancellation()
            guard sourceGeneration == operationCoordinator.sourceStoreGenerationRevision,
              !operationCoordinator.isSourceAccessBlocked
            else { break retryPages }
            guard let providerID = job.providerConfigurationID,
              let record = providers.first(where: { $0.id == providerID }),
              let identifier = job.modelIdentifier,
              let models = try? ProviderModelStore.records(
                providerID: providerID, in: modelContext),
              let provider = try? ProviderModelStore.connection(
                provider: record,
                modelIdentifier: identifier, models: models)
            else {
              remainingCount += 1
              continue
            }

            let operationID = MosaicOperationID.memoryFormation(job.throughUserMessageID)
            guard operationCoordinator.begin(operationID) else {
              remainingCount += 1
              continue
            }
            didAttemptMemoryUpdate = true
            do {
              let apiKey = try await SecurityKeychain.shared.apiKey(
                for: provider.id,
                expectedBinding: provider.credentialBinding
              )
              let connection = provider.authenticated(with: apiKey)
              _ = try await AutomaticMemoryFormationCoordinator.shared.formMemory(
                conversationID: job.conversationID,
                throughUserMessageID: job.throughUserMessageID,
                assistantMessageID: job.assistantMessageID,
                provider: connection,
                client: ProviderClientFactory.make(connection: connection),
                modelContainer: modelContext.container,
                resumingJobID: job.id
              )
              completedCount += 1
            } catch is CancellationError {
              operationCoordinator.end(operationID)
              throw CancellationError()
            } catch {
              remainingCount += 1
            }
            operationCoordinator.end(operationID)
          }
        }

        try Task.checkCancellation()
        failedMemoryRetryStatus = retryStatusDescription(
          completedCount: completedCount,
          remainingCount: remainingCount
        )
      } catch is CancellationError {
        return
      } catch {
        failedMemoryRetryStatus = "Turing AI couldn’t load the failed memory updates. Try again."
      }
    }
  }

  private func retryStatusDescription(completedCount: Int, remainingCount: Int) -> String {
    if completedCount == 0, remainingCount == 0 {
      return "No failed memory updates remain."
    }
    var parts: [String] = []
    if completedCount > 0 {
      parts.append("Completed \(completedCount.formatted()).")
    }
    if remainingCount > 0 {
      parts.append("\(remainingCount.formatted()) still need attention.")
    }
    return parts.joined(separator: " ")
  }

  private func displayTitle(for memory: MosaicMemoryLibraryItem) -> String {
    let title = memory.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Untitled memory" : title
  }

  private func setEnabled(_ isEnabled: Bool, for memory: MosaicMemoryLibraryItem) {
    guard libraryIsCurrent else { return }
    do {
      let record = try memoryRecord(id: memory.id)
      guard let record else { throw MemoryLibraryMutationError.recordMissing }
      guard record.updatedAt == memory.updatedAt else {
        throw MemoryLibraryMutationError.recordChanged
      }
      record.isEnabled = isEnabled
      record.updatedAt = .now
      try operationCoordinator.saveSourceChanges(in: modelContext)
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
      reloadRevision &+= 1
    }
  }

  private func setTopicEnabled(_ isEnabled: Bool, for topic: MosaicMemoryLibraryTopicItem) {
    guard libraryIsCurrent else { return }
    do {
      guard let record = try topicRecord(id: topic.id) else {
        throw MemoryLibraryMutationError.recordMissing
      }
      guard record.updatedAt == topic.updatedAt,
        record.revision == topic.revision,
        record.revision < Int.max
      else {
        throw MemoryLibraryMutationError.recordChanged
      }
      if record.status == .active, record.isEnabled == isEnabled { return }
      let now = Date.now
      let nextRevision = record.revision + 1
      let revisionKind: MemoryRevisionKind
      if isEnabled, record.status == .forgotten {
        record.apply(
          title: record.title,
          content: record.content,
          confidence: record.confidence,
          importance: record.importance,
          stability: record.stability,
          status: .active,
          isEnabled: true,
          evidenceCount: record.evidenceCount,
          revision: nextRevision,
          at: now
        )
        record.setOrigin(.manual)
        revisionKind = .reactivated
      } else {
        record.setEnabled(isEnabled, revision: nextRevision, at: now)
        revisionKind = isEnabled ? .userEnabled : .userDisabled
      }
      let revision = MemoryRevisionRecord(
        revisionKey: "\(record.id.uuidString.lowercased())/\(nextRevision)",
        topicID: record.id,
        sequence: nextRevision,
        kind: revisionKind,
        previousTitle: record.title,
        previousContent: record.content,
        title: record.title,
        content: record.content,
        sourceEvidenceID: nil,
        createdAt: now
      )
      try MosaicSourceFieldLimits.validateMemoryTopic(record)
      try MosaicSourceFieldLimits.validateMemoryRevision(revision)
      modelContext.insert(revision)
      try operationCoordinator.saveSourceChanges(in: modelContext)
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
      reloadRevision &+= 1
    }
  }

  private func forget(_ pending: PendingTopicForget) {
    defer { pendingTopicForget = nil }
    guard pending.sourceGeneration == operationCoordinator.sourceStoreGenerationRevision,
      pending.libraryRevision == operationCoordinator.memoryLibraryRevision,
      libraryIsCurrent
    else {
      return
    }
    do {
      guard let record = try topicRecord(id: pending.id) else {
        throw MemoryLibraryMutationError.recordMissing
      }
      guard record.updatedAt == pending.item.updatedAt,
        record.revision == pending.item.revision,
        record.status == .active,
        record.revision < Int.max
      else {
        throw MemoryLibraryMutationError.recordChanged
      }
      let now = Date.now
      let nextRevision = record.revision + 1
      record.apply(
        title: record.title,
        content: record.content,
        confidence: record.confidence,
        importance: record.importance,
        stability: record.stability,
        status: .forgotten,
        isEnabled: false,
        evidenceCount: record.evidenceCount,
        revision: nextRevision,
        at: now
      )
      record.setOrigin(.manual)
      let revision = MemoryRevisionRecord(
        revisionKey: "\(record.id.uuidString.lowercased())/\(nextRevision)",
        topicID: record.id,
        sequence: nextRevision,
        kind: .forgotten,
        previousTitle: record.title,
        previousContent: record.content,
        title: record.title,
        content: record.content,
        sourceEvidenceID: nil,
        createdAt: now
      )
      try MosaicSourceFieldLimits.validateMemoryTopic(record)
      try MosaicSourceFieldLimits.validateMemoryRevision(revision)
      modelContext.insert(revision)
      try operationCoordinator.saveSourceChanges(in: modelContext)
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
      reloadRevision &+= 1
    }
  }

  private func setDocumentEnabled(
    _ isEnabled: Bool,
    for document: MosaicMemoryLibraryDocumentItem
  ) {
    guard libraryIsCurrent else { return }
    do {
      let record = try documentRecord(id: document.id)
      guard let record else { throw MemoryLibraryMutationError.recordMissing }
      guard record.updatedAt == document.updatedAt else {
        throw MemoryLibraryMutationError.recordChanged
      }
      record.isEnabled = isEnabled
      record.updatedAt = .now
      try operationCoordinator.saveSourceChanges(in: modelContext)
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
      reloadRevision &+= 1
    }
  }

  private func setDocumentProject(
    _ projectID: UUID?,
    for document: MosaicMemoryLibraryDocumentItem
  ) {
    guard libraryIsCurrent, document.projectID != projectID else { return }
    guard operationCoordinator.activeOperations.isEmpty else {
      errorMessage = "Finish active requests and data operations before changing availability."
      return
    }
    do {
      guard let record = try documentRecord(id: document.id) else {
        throw MemoryLibraryMutationError.recordMissing
      }
      guard record.updatedAt == document.updatedAt else {
        throw MemoryLibraryMutationError.recordChanged
      }
      try ProjectBindingStore.assign(
        resourceKind: .document,
        resourceID: record.id,
        to: projectID,
        in: modelContext
      )
      record.updatedAt = .now
      try operationCoordinator.saveSourceChanges(in: modelContext)
      importStatusMessage =
        projectID == nil
        ? "\(document.title) is now available everywhere."
        : "\(document.title) is now available only in \(projectName(id: projectID) ?? "the selected project")."
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
      reloadRevision &+= 1
    }
  }

  private func deleteMemories(at offsets: IndexSet) {
    guard libraryIsCurrent else { return }
    guard let offset = offsets.first,
      snapshot.memories.items.indices.contains(offset)
    else { return }
    requestMemoryDeletion(snapshot.memories.items[offset])
  }

  private func delete(_ pending: PendingMemoryDeletion) {
    defer { pendingDeletion = nil }
    guard pending.sourceGeneration == operationCoordinator.sourceStoreGenerationRevision,
      pending.libraryRevision == operationCoordinator.memoryLibraryRevision,
      libraryIsCurrent
    else {
      return
    }
    do {
      guard let record = try memoryRecord(id: pending.id) else {
        throw MemoryLibraryMutationError.recordMissing
      }
      try deleteProjectBinding(resourceKind: .memory, resourceID: record.id)
      modelContext.delete(record)
      try operationCoordinator.saveSourceChanges(in: modelContext)
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
      reloadRevision &+= 1
    }
  }

  private func delete(_ pending: PendingDocumentDeletion) {
    pendingDocumentDeletion = nil
    guard documentDeletionTask == nil,
      pending.sourceGeneration == operationCoordinator.sourceStoreGenerationRevision,
      pending.libraryRevision == operationCoordinator.memoryLibraryRevision,
      libraryIsCurrent
    else {
      return
    }
    let operationID = MosaicOperationID.documentDeletion(pending.id)
    do {
      guard
        try operationCoordinator.beginDocumentDeletion(
          documentID: pending.id,
          flushing: modelContext
        )
      else {
        errorMessage =
          "Finish active requests, imports, and indexing before deleting this document."
        return
      }
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
      return
    }

    let taskID = UUID()
    deletingDocument = pending.item
    documentDeletionTaskID = taskID
    documentDeletionCommitStarted = false
    isCancellingDocumentDeletion = false
    let sourceRepository = MosaicDocumentSourceDeletionRepository(
      modelContainer: modelContext.container
    )
    let vectorRepository = MosaicDocumentVectorDeletionRepository(
      modelContainer: SemanticIndexStore.shared
    )
    documentDeletionTask = Task { @MainActor in
      defer {
        operationCoordinator.end(operationID)
        if documentDeletionTaskID == taskID {
          deletingDocument = nil
          documentDeletionTask = nil
          documentDeletionTaskID = nil
          documentDeletionCommitStarted = false
          isCancellingDocumentDeletion = false
        }
      }
      do {
        let outcome = try await MosaicDocumentDeletionPipeline.delete(
          documentID: pending.id,
          sourceRepository: sourceRepository,
          vectorRepository: vectorRepository
        ) {
          try Task.checkCancellation()
          guard documentDeletionTaskID == taskID,
            pending.sourceGeneration == operationCoordinator.sourceStoreGenerationRevision
          else {
            throw CancellationError()
          }
          documentDeletionCommitStarted = true
        }
        operationCoordinator.markMemoryLibraryChanged()
        if outcome.didDeleteDocument, !outcome.vectorCleanupSucceeded {
          importStatusMessage =
            "Document deleted. Its rebuildable semantic cache will be repaired during the next index refresh."
        }
        if !outcome.didDeleteDocument { reloadRevision &+= 1 }
      } catch is CancellationError {
        return
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func importDocuments(_ result: Result<[URL], Error>) {
    let targetProjectID = documentImportProjectID
    documentImportProjectID = nil
    guard case .success(let urls) = result else {
      if case .failure(let error) = result { errorMessage = error.localizedDescription }
      return
    }
    guard !urls.isEmpty, importTask == nil else { return }
    let sourceGeneration = operationCoordinator.sourceStoreGenerationRevision
    let operationID = MosaicOperationID.documentImport(UUID())
    guard operationCoordinator.begin(operationID) else {
      errorMessage = "Finish the current data operation before importing documents."
      return
    }
    let taskID = UUID()
    importTaskID = taskID
    isImportingDocuments = true
    isCancellingDocumentImport = false
    importStatusMessage = "Checking selected documents…"
    importTask = Task { @MainActor in
      var insertedCount = 0
      var duplicateCount = 0
      var insertedOCRPageCount = 0
      var insertedOCRFallbackPageCount = 0
      defer {
        operationCoordinator.end(operationID)
        if importTaskID == taskID {
          importTask = nil
          importTaskID = nil
          isImportingDocuments = false
          isCancellingDocumentImport = false
        }
      }
      do {
        let validatedURLs = try await validatedDocumentImportURLs(urls)
        try Task.checkCancellation()
        guard sourceGeneration == operationCoordinator.sourceStoreGenerationRevision,
          importTaskID == taskID
        else {
          throw CancellationError()
        }

        var failures: [String] = []
        var insertedDocumentIDs: Set<UUID> = []
        var payloadFingerprints: Set<String> = []
        for (index, url) in validatedURLs.enumerated() {
          try Task.checkCancellation()
          guard sourceGeneration == operationCoordinator.sourceStoreGenerationRevision,
            importTaskID == taskID
          else {
            throw CancellationError()
          }
          importStatusMessage = "Reading document \(index + 1) of \(validatedURLs.count)…"

          let payload: ImportedDocumentPayload
          do {
            payload = try await extractDocumentPayload(at: url)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            continue
          }
          try Task.checkCancellation()
          guard payloadFingerprints.insert(payload.contentFingerprint).inserted,
            try !documentExists(fingerprint: payload.contentFingerprint)
          else {
            duplicateCount += 1
            continue
          }
          let document = ImportedDocumentRecord(
            title: payload.title,
            sourceFilename: payload.sourceFilename,
            mimeType: payload.mimeType,
            contentFingerprint: payload.contentFingerprint,
            characterCount: payload.characterCount,
            pageCount: payload.pageCount,
            ocrPageCount: payload.ocrPageCount,
            ocrFallbackPageCount: payload.ocrFallbackPageCount
          )
          modelContext.insert(document)
          try ProjectBindingStore.assign(
            resourceKind: .document,
            resourceID: document.id,
            to: targetProjectID,
            in: modelContext
          )
          for chunk in payload.chunks {
            try Task.checkCancellation()
            modelContext.insert(
              DocumentChunkRecord(
                documentID: document.id,
                chunkIndex: chunk.index,
                content: chunk.content,
                pageNumber: chunk.pageNumber,
                isOCRDerived: chunk.isOCRDerived
              )
            )
          }
          try Task.checkCancellation()
          try operationCoordinator.saveSourceChanges(in: modelContext)
          insertedCount += 1
          insertedOCRPageCount += payload.ocrPageCount
          insertedOCRFallbackPageCount += payload.ocrFallbackPageCount
          insertedDocumentIDs.insert(document.id)
        }

        var indexingWarnings: [String] = []
        if insertedCount > 0 {
          try Task.checkCancellation()
          importStatusMessage = "Building the local recall index…"
          indexingWarnings = await SemanticDocumentIndexer.index(
            documentIDs: insertedDocumentIDs,
            in: modelContext
          )
          try Task.checkCancellation()
        }
        guard importTaskID == taskID,
          sourceGeneration == operationCoordinator.sourceStoreGenerationRevision
        else {
          return
        }
        var summary: [String] = []
        if insertedCount > 0 {
          summary.append(
            "Imported \(insertedCount) \(insertedCount == 1 ? "document" : "documents")."
          )
          if let targetProjectID {
            summary.append(
              "Available only in \(projectName(id: targetProjectID) ?? "the selected project")."
            )
          } else {
            summary.append("Available everywhere.")
          }
        }
        if duplicateCount > 0 {
          summary.append(
            "Skipped \(duplicateCount) duplicate \(duplicateCount == 1 ? "file" : "files")."
          )
        }
        if insertedOCRPageCount > 0 {
          let pageLabel = insertedOCRPageCount == 1 ? "page" : "pages"
          summary.append("Read \(insertedOCRPageCount) scanned \(pageLabel) with on-device OCR.")
        }
        if insertedOCRFallbackPageCount > 0 {
          let pageLabel = insertedOCRFallbackPageCount == 1 ? "page" : "pages"
          summary.append(
            "Used existing embedded text on \(insertedOCRFallbackPageCount) short \(pageLabel) after the OCR safety limit."
          )
        }
        if !failures.isEmpty {
          summary.append("Could not import: \(failures.joined(separator: "; "))")
        }
        if !indexingWarnings.isEmpty {
          summary.append(indexingWarnings.joined(separator: " "))
        } else if insertedCount > 0 {
          summary.append("Local recall is ready; enabled embedding profiles were backfilled.")
        }
        importStatusMessage =
          summary.isEmpty ? "No documents were selected." : summary.joined(separator: " ")
      } catch is CancellationError {
        modelContext.rollback()
        if importTaskID == taskID {
          importStatusMessage =
            insertedCount == 0
            ? "Document import stopped."
            : "Stopped after importing \(insertedCount) \(insertedCount == 1 ? "document" : "documents"). Their text is available for local recall; any missing embeddings can be rebuilt."
        }
      } catch {
        modelContext.rollback()
        if importTaskID == taskID {
          errorMessage =
            insertedCount == 0
            ? error.localizedDescription
            : "Imported \(insertedCount) \(insertedCount == 1 ? "document" : "documents") before the import stopped. \(error.localizedDescription)"
        }
      }
    }
  }

  private func validatedDocumentImportURLs(_ urls: [URL]) async throws -> [URL] {
    let validationTask = Task.detached(priority: .userInitiated) {
      try DocumentImportBatchPolicy.standard.validatedURLs(urls) { url in
        try DocumentImportBatchPolicy.selectedFileSize(at: url)
      }
    }
    return try await withTaskCancellationHandler {
      try await validationTask.value
    } onCancel: {
      validationTask.cancel()
    }
  }

  private func extractDocumentPayload(at url: URL) async throws -> ImportedDocumentPayload {
    let extractionTask = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let payload = try DocumentIngestor.importDocument(at: url)
      try Task.checkCancellation()
      return payload
    }
    return try await withTaskCancellationHandler {
      try await extractionTask.value
    } onCancel: {
      extractionTask.cancel()
    }
  }

  private func memoryRecord(id: UUID) throws -> MemoryRecord? {
    let targetID = id
    var descriptor = FetchDescriptor<MemoryRecord>(
      predicate: #Predicate { $0.id == targetID }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func topicRecord(id: UUID) throws -> MemoryTopicRecord? {
    let targetID = id
    var descriptor = FetchDescriptor<MemoryTopicRecord>(
      predicate: #Predicate { $0.id == targetID }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func documentRecord(id: UUID) throws -> ImportedDocumentRecord? {
    let targetID = id
    var descriptor = FetchDescriptor<ImportedDocumentRecord>(
      predicate: #Predicate { $0.id == targetID }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func projectName(id: UUID?) -> String? {
    guard let id else { return nil }
    return projects.first(where: { $0.id == id })?.name
  }

  private func deleteProjectBinding(
    resourceKind: ProjectResourceKind,
    resourceID: UUID
  ) throws {
    if let binding = try ProjectBindingStore.binding(
      resourceKind: resourceKind,
      resourceID: resourceID,
      in: modelContext
    ) {
      modelContext.delete(binding)
    }
  }

  private func documentExists(fingerprint: String) throws -> Bool {
    let targetFingerprint = fingerprint
    var descriptor = FetchDescriptor<ImportedDocumentRecord>(
      predicate: #Predicate { $0.contentFingerprint == targetFingerprint }
    )
    descriptor.fetchLimit = 1
    return try !modelContext.fetch(descriptor).isEmpty
  }

  private func clearForSourceReplacement() {
    failedMemoryRetryTask?.cancel()
    snapshot = .empty
    loadedRequest = nil
    memoryCursorHistory = []
    topicCursorHistory = []
    documentCursorHistory = []
    pendingDeletion = nil
    pendingDocumentDeletion = nil
    isAddingMemory = false
    addingMemorySourceGeneration = nil
    editingMemory = nil
    editingMemorySourceGeneration = nil
    selectedTopic = nil
    editingTopic = nil
    editingTopicSourceGeneration = nil
    pendingTopicForget = nil
    showRetryFailedMemoryConfirmation = false
    isRetryingFailedMemory = false
    failedMemoryRetryTask = nil
    failedMemoryRetryStatus = nil
    showEmbeddingProfiles = false
    showDocumentImporter = false
    documentImportProjectID = nil
    isCancellingDocumentImport = false
  }

  private static func normalizedQuery(_ query: String) -> String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

@MainActor
private struct AutomaticMemoryTopicRow: View {
  let topic: MosaicMemoryLibraryTopicItem
  let onOpen: () -> Void
  let onEdit: () -> Void
  let onForget: () -> Void
  let onEnabledChange: (Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Button(action: onOpen) {
          VStack(alignment: .leading, spacing: 4) {
            Label(topic.title, systemImage: topic.kind.systemImage)
              .font(.headline)
              .foregroundStyle(.primary)
            Text(topic.content)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(3)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open learned topic \(topic.title)")
        .accessibilityHint("Shows source messages and change history")

        Menu {
          Button("Review Sources", systemImage: "quote.bubble", action: onOpen)
          Button("Correct", systemImage: "pencil", action: onEdit)
          Divider()
          if topic.status == .active {
            Button("Forget", systemImage: "trash", role: .destructive, action: onForget)
          } else {
            Button("Remember Again", systemImage: "arrow.uturn.backward") {
              onEnabledChange(true)
            }
          }
        } label: {
          Label("Topic Actions", systemImage: "ellipsis.circle")
            .labelStyle(.iconOnly)
            .mosaicControlTarget()
        }
        .accessibilityLabel("Actions for \(topic.title)")
      }

      VStack(alignment: .leading, spacing: 4) {
        topicMetadata
      }
      .labelStyle(.titleAndIcon)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      Toggle(
        topic.status == .forgotten ? "Remember again" : "Use in chats",
        isOn: Binding(
          get: { topic.isEnabled && topic.status == .active },
          set: { onEnabledChange($0) }
        )
      )
      .toggleStyle(.switch)
      .accessibilityLabel(
        topic.status == .forgotten
          ? "Remember \(topic.title) again"
          : "Use \(topic.title) in chats"
      )
      .accessibilityHint(
        topic.status == .forgotten
          ? "Restores this topic and makes it available for future chats"
          : "Controls whether this learned topic can be included in requests"
      )
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var topicMetadata: some View {
    Label(topicScopeDescription, systemImage: topicScopeSystemImage)
    Label(
      topic.kind == .event
        ? (RecentEventMemoryPolicy.isRecent(lastConfirmedAt: topic.lastConfirmedAt)
          ? "Recent event" : "Past event")
        : topic.kind.displayName, systemImage: "tag")
    Label(evidenceDescription, systemImage: "quote.bubble")
    if topic.useCount > 0 {
      Label("Used \(topic.useCount)×", systemImage: "arrow.uturn.forward")
    }
    if topic.status == .forgotten {
      Label("Forgotten", systemImage: "trash")
    } else if !topic.isEnabled {
      Label("Paused", systemImage: "pause.circle")
    }
  }

  private var evidenceDescription: String {
    switch topic.evidenceCount {
    case 0: "Source unavailable"
    case 1: "Learned from 1 message"
    default: "Confirmed by \(topic.evidenceCount) messages"
    }
  }

  private var topicScopeDescription: String {
    switch topic.scope {
    case .global:
      "Everywhere"
    case .project:
      topic.projectName ?? "Unavailable project"
    case .conversation:
      "This chat"
    }
  }

  private var topicScopeSystemImage: String {
    switch topic.scope {
    case .global: "globe"
    case .project: "folder"
    case .conversation: "bubble.left.and.bubble.right"
    }
  }
}

@MainActor
private struct AutomaticMemoryTopicDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  let topic: MosaicMemoryLibraryTopicItem

  @State private var operationCoordinator = MosaicOperationCoordinator.shared
  @State private var currentTopic: MosaicMemoryLibraryTopicItem
  @State private var detail: MosaicMemoryLibraryTopicDetail?
  @State private var isLoading = true
  @State private var editingTopic: MosaicMemoryLibraryTopicItem?
  @State private var showForgetConfirmation = false
  @State private var errorMessage: String?

  init(topic: MosaicMemoryLibraryTopicItem) {
    self.topic = topic
    _currentTopic = State(initialValue: topic)
  }

  var body: some View {
    NavigationStack {
      List {
        Section("Current memory") {
          Label(currentTopic.kind.displayName, systemImage: currentTopic.kind.systemImage)
          if currentTopic.kind == .event {
            LabeledContent(
              "Last reported",
              value: currentTopic.lastConfirmedAt.formatted(date: .abbreviated, time: .omitted))
            Text(
              "A dated report, not a permanent fact. New updates replace the current account while earlier versions stay in history."
            )
            .font(.footnote).foregroundStyle(.secondary)
          }
          Text(currentTopic.content)
            .textSelection(.enabled)
          LabeledContent("Status", value: statusDescription)
          LabeledContent(
            "Sources",
            value: currentTopic.evidenceCount == 1
              ? "1 user message" : "\(currentTopic.evidenceCount) user messages"
          )
          LabeledContent(
            "Scope",
            value: topicScopeDescription
          )
          LabeledContent("Last updated") {
            Text(currentTopic.updatedAt.formatted(date: .abbreviated, time: .shortened))
          }
        }

        Section {
          Button {
            editingTopic = currentTopic
          } label: {
            Label("Correct This Memory", systemImage: "pencil")
          }
          .disabled(operationCoordinator.isSourceAccessBlocked)
          .accessibilityHint("Edits the current value and records your correction in its history")

          Toggle(
            currentTopic.status == .forgotten ? "Remember Again" : "Use in Chats",
            isOn: Binding(
              get: { currentTopic.isEnabled && currentTopic.status == .active },
              set: { setEnabled($0) }
            )
          )
          .disabled(operationCoordinator.isSourceAccessBlocked)
          .accessibilityHint(
            currentTopic.status == .forgotten
              ? "Restores this topic and makes it available for future chats"
              : "Controls whether this learned topic can be included in requests"
          )

          if currentTopic.status == .active {
            Button("Forget This Topic", systemImage: "trash", role: .destructive) {
              showForgetConfirmation = true
            }
            .disabled(operationCoordinator.isSourceAccessBlocked)
            .accessibilityHint(
              "Stops this topic from being recalled while preserving its sources and history"
            )
          }
        } header: {
          Text("Controls")
        } footer: {
          Text(
            "Corrections become the current value. Forgetting keeps an audit trail and can be undone with Remember Again."
          )
        }

        if isLoading {
          Section { ProgressView("Loading sources…") }
        } else if let detail {
          Section {
            if detail.evidence.isEmpty {
              Label("No source message is available", systemImage: "quote.bubble")
                .foregroundStyle(.secondary)
            } else {
              ForEach(detail.evidence) { item in
                VStack(alignment: .leading, spacing: 6) {
                  HStack {
                    Label(
                      item.conversationTitle ?? "Conversation no longer available",
                      systemImage: item.sourceAvailable
                        ? "bubble.left" : "bubble.left.and.exclamationmark.bubble.right"
                    )
                    Spacer(minLength: 8)
                    Text(item.snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                      .foregroundStyle(.tertiary)
                  }
                  .font(.caption)
                  Text(item.snapshot.excerpt)
                    .font(.subheadline)
                    .textSelection(.enabled)
                  if let provenance = extractionDescription(item.snapshot) {
                    Text(provenance)
                      .font(.caption2)
                      .foregroundStyle(.tertiary)
                  }
                }
                .padding(.vertical, 3)
              }
            }
          } header: {
            Text("Sources")
          } footer: {
            Text(sourceFooter(detail))
          }

          Section {
            if detail.revisions.isEmpty {
              Label("No history is available", systemImage: "clock")
                .foregroundStyle(.secondary)
            } else {
              ForEach(detail.revisions) { revision in
                VStack(alignment: .leading, spacing: 4) {
                  Label(revisionLabel(revision.kind), systemImage: revisionSymbol(revision.kind))
                    .font(.subheadline.weight(.medium))
                  if let previousTitle = revision.previousTitle,
                    previousTitle != revision.title
                  {
                    Text("Title: \(previousTitle) → \(revision.title)")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  if let previous = revision.previousContent,
                    previous != revision.content
                  {
                    Text("Previous: \(previous)")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(3)
                  }
                  Text("Current: \(revision.content)")
                    .font(.caption)
                    .lineLimit(3)
                  Text(revision.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 3)
              }
            }
          } header: {
            Text("Change history")
          } footer: {
            if detail.totalRevisionCount > detail.revisions.count {
              Text(
                "Showing the newest \(detail.revisions.count) of \(detail.totalRevisionCount) changes."
              )
            }
          }
        }

        if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle(currentTopic.title)
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task { await load() }
      .onChange(of: operationCoordinator.memoryLibraryRevision) { _, _ in
        Task { await load() }
      }
      .onChange(of: operationCoordinator.sourceStoreGenerationRevision) { _, _ in
        dismiss()
      }
      .sheet(item: $editingTopic) { topic in
        AutomaticMemoryTopicEditorView(
          topic: topic,
          sourceGeneration: operationCoordinator.sourceStoreGenerationRevision
        )
      }
      .confirmationDialog(
        "Forget this learned topic?",
        isPresented: $showForgetConfirmation,
        titleVisibility: .visible
      ) {
        Button("Forget Topic", role: .destructive, action: forget)
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "“\(currentTopic.title)” will stop being recalled. Its sources and change history will remain available."
        )
      }
      .alert("Memory couldn’t be updated", isPresented: errorIsPresented) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "Please try again.")
      }
    }
    #if os(macOS)
      .frame(minWidth: 520, idealWidth: 620, minHeight: 520, idealHeight: 680)
    #endif
  }

  private var statusDescription: String {
    if currentTopic.status == .forgotten {
      return currentTopic.origin == .manual
        ? "Forgotten by you" : "No longer supported by a saved source"
    }
    if !currentTopic.isEnabled { return "Paused by you" }
    if currentTopic.evidenceCount > 1 { return "Confirmed from multiple messages" }
    return "Learned automatically"
  }

  private var topicScopeDescription: String {
    switch currentTopic.scope {
    case .global:
      "Everywhere"
    case .project:
      currentTopic.projectName ?? "Unavailable project"
    case .conversation:
      "This chat"
    }
  }

  private func sourceFooter(_ detail: MosaicMemoryLibraryTopicDetail) -> String {
    let explanation =
      "Only exact user messages can be evidence; assistant replies never become sources."
    guard detail.totalEvidenceCount > detail.evidence.count else { return explanation }
    return
      "\(explanation) Showing the newest \(detail.evidence.count) of \(detail.totalEvidenceCount) sources."
  }

  private func extractionDescription(_ evidence: AutomaticMemoryEvidenceSnapshot) -> String? {
    let endpointHost = evidence.providerEndpoint.flatMap { URL(string: $0)?.host }
    let values = [evidence.providerDisplayName, evidence.modelIdentifier, endpointHost].compactMap {
      value in
      value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    guard !values.isEmpty else { return nil }
    return "Learned with \(values.joined(separator: " · "))"
  }

  private func load() async {
    do {
      let loaded = try await MosaicMemoryLibraryRepository(
        modelContainer: modelContext.container
      ).topicDetail(id: currentTopic.id)
      try Task.checkCancellation()
      detail = loaded
      if let loaded { currentTopic = loaded.topic }
      isLoading = false
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
      isLoading = false
    }
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private func setEnabled(_ isEnabled: Bool) {
    guard !operationCoordinator.isSourceAccessBlocked else { return }
    do {
      guard let record = try topicRecord(id: currentTopic.id) else {
        throw MemoryLibraryMutationError.recordMissing
      }
      guard record.updatedAt == currentTopic.updatedAt,
        record.revision == currentTopic.revision,
        record.revision < Int.max
      else {
        throw MemoryLibraryMutationError.recordChanged
      }
      let now = Date.now
      let nextRevision = record.revision + 1
      let revisionKind: MemoryRevisionKind
      if isEnabled, record.status == .forgotten {
        record.apply(
          title: record.title,
          content: record.content,
          confidence: record.confidence,
          importance: record.importance,
          stability: record.stability,
          status: .active,
          isEnabled: true,
          evidenceCount: record.evidenceCount,
          revision: nextRevision,
          at: now
        )
        record.setOrigin(.manual)
        revisionKind = .reactivated
      } else {
        record.setEnabled(isEnabled, revision: nextRevision, at: now)
        revisionKind = isEnabled ? .userEnabled : .userDisabled
      }
      let revision = MemoryRevisionRecord(
        revisionKey: "\(record.id.uuidString.lowercased())/\(nextRevision)",
        topicID: record.id,
        sequence: nextRevision,
        kind: revisionKind,
        previousTitle: record.title,
        previousContent: record.content,
        title: record.title,
        content: record.content,
        sourceEvidenceID: nil,
        createdAt: now
      )
      try MosaicSourceFieldLimits.validateMemoryTopic(record)
      try MosaicSourceFieldLimits.validateMemoryRevision(revision)
      modelContext.insert(revision)
      try operationCoordinator.saveSourceChanges(in: modelContext)
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
      Task { await load() }
    }
  }

  private func forget() {
    showForgetConfirmation = false
    guard currentTopic.status == .active, !operationCoordinator.isSourceAccessBlocked else {
      return
    }
    do {
      guard let record = try topicRecord(id: currentTopic.id) else {
        throw MemoryLibraryMutationError.recordMissing
      }
      guard record.updatedAt == currentTopic.updatedAt,
        record.revision == currentTopic.revision,
        record.status == .active,
        record.revision < Int.max
      else {
        throw MemoryLibraryMutationError.recordChanged
      }
      let now = Date.now
      let nextRevision = record.revision + 1
      record.apply(
        title: record.title,
        content: record.content,
        confidence: record.confidence,
        importance: record.importance,
        stability: record.stability,
        status: .forgotten,
        isEnabled: false,
        evidenceCount: record.evidenceCount,
        revision: nextRevision,
        at: now
      )
      record.setOrigin(.manual)
      let revision = MemoryRevisionRecord(
        revisionKey: "\(record.id.uuidString.lowercased())/\(nextRevision)",
        topicID: record.id,
        sequence: nextRevision,
        kind: .forgotten,
        previousTitle: record.title,
        previousContent: record.content,
        title: record.title,
        content: record.content,
        sourceEvidenceID: nil,
        createdAt: now
      )
      try MosaicSourceFieldLimits.validateMemoryTopic(record)
      try MosaicSourceFieldLimits.validateMemoryRevision(revision)
      modelContext.insert(revision)
      try operationCoordinator.saveSourceChanges(in: modelContext)
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
      Task { await load() }
    }
  }

  private func topicRecord(id: UUID) throws -> MemoryTopicRecord? {
    let targetID = id
    var descriptor = FetchDescriptor<MemoryTopicRecord>(
      predicate: #Predicate { $0.id == targetID }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func revisionLabel(_ kind: MemoryRevisionKind) -> String {
    switch kind {
    case .created: "Learned"
    case .reinforced: "Confirmed again"
    case .updated: "Updated"
    case .forgotten: "Forgotten"
    case .reactivated: "Learned again"
    case .userEdited: "Edited by you"
    case .userDisabled: "Paused by you"
    case .userEnabled: "Resumed by you"
    }
  }

  private func revisionSymbol(_ kind: MemoryRevisionKind) -> String {
    switch kind {
    case .created: "plus.circle"
    case .reinforced: "checkmark.circle"
    case .updated: "arrow.triangle.2.circlepath"
    case .forgotten: "trash"
    case .reactivated: "arrow.uturn.backward.circle"
    case .userEdited: "pencil"
    case .userDisabled: "pause.circle"
    case .userEnabled: "play.circle"
    }
  }
}

@MainActor
private struct AutomaticMemoryTopicEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  let topic: MosaicMemoryLibraryTopicItem
  let sourceGeneration: UInt64

  @State private var operationCoordinator = MosaicOperationCoordinator.shared
  @State private var title: String
  @State private var content: String
  @State private var errorMessage: String?

  init(
    topic: MosaicMemoryLibraryTopicItem,
    sourceGeneration: UInt64
  ) {
    self.topic = topic
    self.sourceGeneration = sourceGeneration
    _title = State(initialValue: topic.title)
    _content = State(initialValue: topic.content)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Title", text: $title, prompt: Text("Response language"))
            .textContentType(.none)

          TextEditor(text: $content)
            .frame(minHeight: 140)
            .accessibilityLabel("Corrected memory")
            .accessibilityHint("Enter the exact current fact Turing AI should remember")

          if let validationMessage {
            Label(validationMessage, systemImage: "exclamationmark.circle")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .accessibilityLabel("Cannot save. \(validationMessage)")
          }
        } header: {
          Text("Current value")
        } footer: {
          Text(
            "Use a short title and one clear, current fact. Turing AI keeps the previous value in change history."
          )
        }

        Section("What happens next") {
          Label("Your correction becomes authoritative", systemImage: "checkmark.seal")
          Label("Source messages stay unchanged", systemImage: "quote.bubble")
          Label("The edit is added to history", systemImage: "clock.arrow.circlepath")
        }
      }
      .navigationTitle("Correct Memory")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save Correction", action: save)
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
        }
      }
      .onChange(of: operationCoordinator.sourceStoreGenerationRevision) { _, generation in
        if generation != sourceGeneration { dismiss() }
      }
      .interactiveDismissDisabled(hasUnsavedChanges)
      .alert("Correction couldn’t be saved", isPresented: errorIsPresented) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "Please try again.")
      }
    }
    #if os(macOS)
      .frame(minWidth: 460, idealWidth: 540, minHeight: 420, idealHeight: 500)
    #endif
  }

  private var trimmedTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedContent: String {
    content.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var hasUnsavedChanges: Bool {
    title != topic.title || content != topic.content
  }

  private var validationMessage: String? {
    if trimmedTitle.isEmpty { return "Add a title." }
    if trimmedContent.isEmpty { return "Add the fact Turing AI should remember." }
    do {
      try MosaicSourceFieldLimits.validateAutomaticMemoryText(
        title: trimmedTitle,
        content: trimmedContent
      )
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  private var canSave: Bool {
    validationMessage == nil
      && (trimmedTitle != topic.title || trimmedContent != topic.content)
      && sourceGeneration == operationCoordinator.sourceStoreGenerationRevision
      && !operationCoordinator.isSourceAccessBlocked
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private func save() {
    guard canSave else { return }
    do {
      guard let record = try topicRecord(id: topic.id) else {
        throw MemoryLibraryMutationError.recordMissing
      }
      guard record.updatedAt == topic.updatedAt,
        record.revision == topic.revision,
        record.revision < Int.max,
        sourceGeneration == operationCoordinator.sourceStoreGenerationRevision
      else {
        throw MemoryLibraryMutationError.recordChanged
      }
      try MosaicSourceFieldLimits.validateAutomaticMemoryText(
        title: trimmedTitle,
        content: trimmedContent
      )
      let previousTitle = record.title
      let previousContent = record.content
      let nextRevision = record.revision + 1
      let now = Date.now
      let wasForgotten = record.status == .forgotten
      record.apply(
        title: trimmedTitle,
        content: trimmedContent,
        confidence: 1,
        importance: record.importance,
        stability: record.stability,
        status: .active,
        isEnabled: wasForgotten ? true : record.isEnabled,
        evidenceCount: record.evidenceCount,
        revision: nextRevision,
        at: now
      )
      record.setOrigin(.manual)
      let revision = MemoryRevisionRecord(
        revisionKey: "\(record.id.uuidString.lowercased())/\(nextRevision)",
        topicID: record.id,
        sequence: nextRevision,
        kind: .userEdited,
        previousTitle: previousTitle,
        previousContent: previousContent,
        title: record.title,
        content: record.content,
        sourceEvidenceID: nil,
        createdAt: now
      )
      try MosaicSourceFieldLimits.validateMemoryTopic(record)
      try MosaicSourceFieldLimits.validateMemoryRevision(revision)
      modelContext.insert(revision)
      try operationCoordinator.saveSourceChanges(in: modelContext)
      dismiss()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }

  private func topicRecord(id: UUID) throws -> MemoryTopicRecord? {
    let targetID = id
    var descriptor = FetchDescriptor<MemoryTopicRecord>(
      predicate: #Predicate { $0.id == targetID }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }
}

@MainActor
private struct MemoryLibraryRow: View {
  let memory: MosaicMemoryLibraryItem
  let onEdit: () -> Void
  let onDelete: () -> Void
  let onEnabledChange: (Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Button(action: onEdit) {
          VStack(alignment: .leading, spacing: 4) {
            Text(displayTitle)
              .font(.headline)
              .foregroundStyle(.primary)
            Text(memory.content)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(3)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit \(displayTitle)")
        .accessibilityHint("Opens this memory for review and editing")

        Menu {
          Button("Edit", systemImage: "pencil", action: onEdit)
          Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        } label: {
          Label("Memory Actions", systemImage: "ellipsis.circle")
            .labelStyle(.iconOnly)
            .frame(minWidth: 28, minHeight: 28)
        }
        .accessibilityLabel("Actions for \(displayTitle)")
      }

      HStack(alignment: .center, spacing: 12) {
        Label(
          scopeDescription,
          systemImage: scopeSystemImage
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Spacer(minLength: 8)

        Toggle(
          "Use in chats",
          isOn: Binding(
            get: { memory.isEnabled },
            set: { isEnabled in onEnabledChange(isEnabled) }
          )
        )
        .toggleStyle(.switch)
        .fixedSize()
        .accessibilityHint("Controls whether this curated fact can be included in requests")
      }

      Label("Manually curated", systemImage: "checkmark.seal")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
  }

  private var displayTitle: String {
    let title = memory.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Untitled memory" : title
  }

  private var scopeDescription: String {
    switch memory.scope {
    case .global:
      "All conversations · manually saved"
    case .project:
      "\(memory.projectName ?? "Unavailable project") · manually saved"
    case .conversation:
      "\(memory.conversationTitle ?? "Specific conversation") · manually saved"
    }
  }

  private var scopeSystemImage: String {
    switch memory.scope {
    case .global: "globe"
    case .project: "folder"
    case .conversation: "bubble.left.and.bubble.right"
    }
  }
}

@MainActor
private struct MemoryEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \ProjectRecord.name)
  private var projects: [ProjectRecord]

  let memory: MosaicMemoryLibraryItem?
  let sourceGeneration: UInt64

  @State private var operationCoordinator = MosaicOperationCoordinator.shared
  @State private var title: String
  @State private var content: String
  @State private var scope: MemoryScope
  @State private var projectID: UUID?
  @State private var conversationID: UUID?
  @State private var isEnabled: Bool
  @State private var conversationSearchText = ""
  @State private var conversationPage = MosaicMemoryLibraryConversationPage.empty
  @State private var conversationCursorHistory: [MosaicMemoryLibraryConversationCursor] = []
  @State private var loadedConversationRequest: MosaicMemoryConversationRequest?
  @State private var isLoadingConversations = false
  @State private var errorMessage: String?

  private static let conversationPageSize = 16

  init(memory: MosaicMemoryLibraryItem?, sourceGeneration: UInt64) {
    self.memory = memory
    self.sourceGeneration = sourceGeneration
    _title = State(initialValue: memory?.title ?? "")
    _content = State(initialValue: memory?.content ?? "")
    _scope = State(initialValue: memory?.scope ?? .global)
    _projectID = State(initialValue: memory?.projectID)
    _conversationID = State(initialValue: memory?.conversationID)
    _isEnabled = State(initialValue: memory?.isEnabled ?? true)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Memory") {
          TextField("Title", text: $title, prompt: Text("Preferred response style"))
            .textContentType(.none)

          TextEditor(text: $content)
            .frame(minHeight: 140)
            .accessibilityLabel("Memory details")
            .accessibilityHint(
              "Enter the exact fact or preference Turing AI may send to an AI provider"
            )
        }

        Section {
          Picker("Scope", selection: $scope) {
            Label("Everywhere", systemImage: "globe").tag(MemoryScope.global)
            Label("Project", systemImage: "folder").tag(MemoryScope.project)
            Label("Conversation", systemImage: "bubble.left.and.bubble.right")
              .tag(MemoryScope.conversation)
          }
          .pickerStyle(.menu)

          if scope == .project {
            if projectOptionsAreEmpty {
              Label(
                "Create an active project before saving project-scoped memory.",
                systemImage: "info.circle"
              )
              .foregroundStyle(.secondary)
            } else {
              Picker("Project", selection: $projectID) {
                Text("Choose a project").tag(UUID?.none)
                if let unavailableProjectChoice {
                  Text("\(unavailableProjectChoice.name) (Archived)")
                    .tag(Optional(unavailableProjectChoice.id))
                }
                ForEach(activeProjects) { project in
                  Text(project.name).tag(Optional(project.id))
                }
              }
            }
          }

          if scope == .conversation {
            TextField("Search conversations", text: $conversationSearchText)
              .textFieldStyle(.roundedBorder)
            if conversationOptions.isEmpty, !isLoadingConversations {
              Label(
                "Create a conversation before saving conversation-scoped memory.",
                systemImage: "info.circle"
              )
              .foregroundStyle(.secondary)
            } else {
              Picker("Conversation", selection: $conversationID) {
                Text("Choose a conversation").tag(UUID?.none)
                ForEach(conversationOptions) { conversation in
                  Text(conversation.title).tag(Optional(conversation.id))
                }
              }
              conversationPaginationControls
            }
          }

          Toggle("Use in AI requests", isOn: $isEnabled)

          if projectAssignmentChanged, !operationCoordinator.activeOperations.isEmpty {
            Label(
              "Finish active requests and data operations before changing the project.",
              systemImage: "clock"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
        } header: {
          Text("Availability")
        } footer: {
          Text(scopeFooter)
        }

        Section("Provenance") {
          Label("Saved manually by you", systemImage: "hand.tap")
          Text(
            "Saving pins this fact for future requests. Past-chat recall works separately and does not require a review step."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }
      .navigationTitle(memory == nil ? "New Memory" : "Edit Memory")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .onChange(of: scope) { _, newScope in
        switch newScope {
        case .global:
          projectID = nil
          conversationID = nil
        case .project:
          conversationID = nil
          if projectID == nil { projectID = activeProjects.first?.id }
        case .conversation:
          projectID = nil
          if conversationID == nil { conversationID = conversationOptions.first?.id }
        }
      }
      .onChange(of: conversationSearchText) { previous, current in
        guard Self.normalizedQuery(previous) != Self.normalizedQuery(current) else { return }
        conversationCursorHistory = []
      }
      .onChange(of: operationCoordinator.sourceStoreGenerationRevision) { _, generation in
        if generation != sourceGeneration { dismiss() }
      }
      .task(id: conversationRequest) {
        await loadConversations(for: conversationRequest)
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: save)
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
        }
      }
      .interactiveDismissDisabled(hasUnsavedChanges)
      .alert("Memory couldn’t be saved", isPresented: errorIsPresented) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "Please try again.")
      }
    }
  }

  private var activeProjects: [ProjectRecord] {
    projects.filter { !$0.isArchived }
  }

  private var unavailableProjectChoice: (id: UUID, name: String)? {
    guard let id = memory?.projectID,
      !activeProjects.contains(where: { $0.id == id })
    else {
      return nil
    }
    return (id, memory?.projectName ?? "Unavailable project")
  }

  private var projectOptionsAreEmpty: Bool {
    activeProjects.isEmpty && unavailableProjectChoice == nil
  }

  private var scopeFooter: String {
    switch scope {
    case .global:
      "Available in every conversation."
    case .project:
      "Available only to conversations in the selected project."
    case .conversation:
      "Available only when the selected conversation is active."
    }
  }

  private var conversationOptions: [MosaicMemoryLibraryConversationChoice] {
    var values = conversationPage.items
    if let selected = conversationPage.selectedItem,
      !values.contains(where: { $0.id == selected.id })
    {
      values.insert(selected, at: 0)
    }
    return values
  }

  @ViewBuilder
  private var conversationPaginationControls: some View {
    if !conversationCursorHistory.isEmpty || conversationPage.nextCursor != nil {
      HStack(spacing: 8) {
        Button("Newer", systemImage: "chevron.up") {
          conversationCursorHistory.removeLast()
        }
        .disabled(conversationCursorHistory.isEmpty || isLoadingConversations)
        Spacer(minLength: 4)
        Text("Page \((conversationCursorHistory.count + 1).formatted())")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 4)
        Button("Older", systemImage: "chevron.down") {
          if let cursor = conversationPage.nextCursor {
            conversationCursorHistory.append(cursor)
          }
        }
        .disabled(conversationPage.nextCursor == nil || isLoadingConversations)
      }
      .buttonStyle(.borderless)
    }
  }

  private var conversationRequest: MosaicMemoryConversationRequest {
    MosaicMemoryConversationRequest(
      query: Self.normalizedQuery(conversationSearchText),
      cursor: conversationCursorHistory.last,
      selectedID: conversationID,
      sourceStoreGenerationRevision: operationCoordinator.sourceStoreGenerationRevision,
      conversationCatalogRevision: operationCoordinator.conversationCatalogRevision,
      sourceAccessIsBlocked: operationCoordinator.isSourceAccessBlocked
    )
  }

  private func loadConversations(for request: MosaicMemoryConversationRequest) async {
    guard request == conversationRequest, !request.sourceAccessIsBlocked,
      request.sourceStoreGenerationRevision == sourceGeneration
    else {
      return
    }
    isLoadingConversations = true
    defer {
      if conversationRequest == request { isLoadingConversations = false }
    }
    do {
      if !request.query.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
      try Task.checkCancellation()
      let repository = MosaicMemoryLibraryRepository(modelContainer: modelContext.container)
      let page = try await repository.conversationPage(
        query: request.query,
        after: request.cursor,
        pageSize: Self.conversationPageSize,
        selectedID: request.selectedID
      )
      try Task.checkCancellation()
      guard conversationRequest == request else { return }
      conversationPage = page
      loadedConversationRequest = request
      if scope == .conversation, conversationID == nil {
        conversationID = conversationOptions.first?.id
      }
    } catch is CancellationError {
      return
    } catch {
      guard conversationRequest == request else { return }
      errorMessage = error.localizedDescription
    }
  }

  private var canSave: Bool {
    !trimmedTitle.isEmpty
      && !trimmedContent.isEmpty
      && scopeSelectionIsValid
      && sourceGeneration == operationCoordinator.sourceStoreGenerationRevision
      && !operationCoordinator.isSourceAccessBlocked
      && (scope != .conversation || loadedConversationRequest == conversationRequest)
      && (!projectAssignmentChanged || operationCoordinator.activeOperations.isEmpty)
  }

  private var projectAssignmentChanged: Bool {
    let selectedProjectID = scope == .project ? projectID : nil
    return selectedProjectID != memory?.projectID
  }

  private var scopeSelectionIsValid: Bool {
    switch scope {
    case .global:
      return true
    case .project:
      guard let projectID else { return false }
      if projectID == memory?.projectID { return true }
      return activeProjects.contains(where: { $0.id == projectID })
    case .conversation:
      return conversationID != nil
    }
  }

  private var hasUnsavedChanges: Bool {
    title != (memory?.title ?? "")
      || content != (memory?.content ?? "")
      || scope != (memory?.scope ?? .global)
      || projectID != memory?.projectID
      || conversationID != memory?.conversationID
      || isEnabled != (memory?.isEnabled ?? true)
  }

  private var trimmedTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedContent: String {
    content.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private func save() {
    guard canSave,
      sourceGeneration == operationCoordinator.sourceStoreGenerationRevision
    else {
      return
    }
    let selectedProjectID = scope == .project ? projectID : nil
    let selectedConversationID = scope == .conversation ? conversationID : nil

    do {
      try MosaicSourceFieldLimits.validateMemory(title: trimmedTitle, content: trimmedContent)
      if let selectedConversationID {
        guard try conversationRecord(id: selectedConversationID) != nil else {
          throw MemoryLibraryMutationError.conversationMissing
        }
      }
      if let memory {
        guard let record = try memoryRecord(id: memory.id) else {
          throw MemoryLibraryMutationError.recordMissing
        }
        guard record.updatedAt == memory.updatedAt else {
          throw MemoryLibraryMutationError.recordChanged
        }
        if selectedProjectID == nil,
          let binding = try ProjectBindingStore.binding(
            resourceKind: .memory,
            resourceID: record.id,
            in: modelContext
          )
        {
          modelContext.delete(binding)
        }
        record.title = trimmedTitle
        record.content = trimmedContent
        record.scope = scope
        record.conversationID = selectedConversationID
        record.isEnabled = isEnabled
        record.isUserApproved = true
        record.updatedAt = .now
        if let selectedProjectID, selectedProjectID != memory.projectID {
          try ProjectBindingStore.assign(
            resourceKind: .memory,
            resourceID: record.id,
            to: selectedProjectID,
            in: modelContext
          )
        }
      } else {
        let record = MemoryRecord(
          title: trimmedTitle,
          content: trimmedContent,
          scope: scope,
          conversationID: selectedConversationID,
          isEnabled: isEnabled,
          isUserApproved: true
        )
        modelContext.insert(record)
        if let selectedProjectID {
          try ProjectBindingStore.assign(
            resourceKind: .memory,
            resourceID: record.id,
            to: selectedProjectID,
            in: modelContext
          )
        }
      }
      try operationCoordinator.saveSourceChanges(in: modelContext)
      dismiss()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }

  private func memoryRecord(id: UUID) throws -> MemoryRecord? {
    let targetID = id
    var descriptor = FetchDescriptor<MemoryRecord>(
      predicate: #Predicate { $0.id == targetID }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func conversationRecord(id: UUID) throws -> ConversationRecord? {
    let targetID = id
    var descriptor = FetchDescriptor<ConversationRecord>(
      predicate: #Predicate { $0.id == targetID }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private static func normalizedQuery(_ query: String) -> String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

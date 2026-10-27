import Accessibility
import SwiftData
import SwiftUI

private struct MosaicMessageSearchCursor: Sendable {
  let id: UUID
}

private struct MosaicConversationSearchCursor: Sendable {
  let updatedAt: Date
  let createdAt: Date
  let id: UUID
}

private struct AutomaticMemoryRecoveryRequest: Hashable {
  let isActive: Bool
  let isEnabled: Bool
  let providerIDs: [UUID]
  let sourceGeneration: UInt64
}

@ModelActor
actor MosaicConversationMessageSearch {
  func matchingConversationIDs(query: String) throws -> Set<UUID> {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    var conversationIDs: Set<UUID> = []
    var cursor: MosaicMessageSearchCursor?
    while true {
      try Task.checkCancellation()
      var descriptor: FetchDescriptor<MessageRecord>
      if let cursor {
        let cursorID = cursor.id
        descriptor = FetchDescriptor(
          predicate: #Predicate { $0.id > cursorID },
          sortBy: [SortDescriptor(\MessageRecord.id)]
        )
      } else {
        descriptor = FetchDescriptor(sortBy: [SortDescriptor(\MessageRecord.id)])
      }
      descriptor.fetchLimit = 4
      descriptor.includePendingChanges = false
      let messages = try modelContext.fetch(descriptor)
      guard !messages.isEmpty else { break }
      for message in messages {
        if message.content.localizedCaseInsensitiveContains(query) {
          conversationIDs.insert(message.conversationID)
        }
      }
      cursor = messages.last.map { MosaicMessageSearchCursor(id: $0.id) }
      if messages.count < 4 { break }
    }
    return conversationIDs
  }
}

struct MosaicConversationSidebarItem: Hashable, Identifiable, Sendable {
  let id: UUID
  let title: String
  let providerConfigurationID: UUID?
  let projectID: UUID?
  let projectName: String?
  let projectBindingID: UUID?
  let projectBindingUpdatedAt: Date?
  let isArchived: Bool
  let createdAt: Date
  let updatedAt: Date

  fileprivate init(
    _ conversation: ConversationRecord,
    projectID: UUID? = nil,
    projectName: String? = nil,
    projectBindingID: UUID? = nil,
    projectBindingUpdatedAt: Date? = nil
  ) {
    id = conversation.id
    title = conversation.title
    providerConfigurationID = conversation.providerConfigurationID
    self.projectID = projectID
    self.projectName = projectName
    self.projectBindingID = projectBindingID
    self.projectBindingUpdatedAt = projectBindingUpdatedAt
    isArchived = conversation.isArchived
    createdAt = conversation.createdAt
    updatedAt = conversation.updatedAt
  }

  fileprivate init(
    id: UUID,
    title: String,
    providerConfigurationID: UUID?,
    projectID: UUID?,
    projectName: String?,
    projectBindingID: UUID?,
    projectBindingUpdatedAt: Date?,
    isArchived: Bool,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.title = title
    self.providerConfigurationID = providerConfigurationID
    self.projectID = projectID
    self.projectName = projectName
    self.projectBindingID = projectBindingID
    self.projectBindingUpdatedAt = projectBindingUpdatedAt
    self.isArchived = isArchived
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

struct MosaicConversationSidebarPage: Hashable, Sendable {
  let items: [MosaicConversationSidebarItem]
  let offset: Int
  let hasNextPage: Bool

  var hasPreviousPage: Bool { offset > 0 }

  static let empty = MosaicConversationSidebarPage(items: [], offset: 0, hasNextPage: false)
}

struct MosaicConversationSidebarPages: Hashable, Sendable {
  let active: MosaicConversationSidebarPage
  let archived: MosaicConversationSidebarPage

  static let empty = MosaicConversationSidebarPages(active: .empty, archived: .empty)
}

/// Reads only the currently visible sidebar pages on a SwiftData executor. Search may inspect the
/// full store, but only immutable, bounded page snapshots cross back to the UI actor.
@ModelActor
actor MosaicConversationSidebarCatalog {
  func pages(
    query: String,
    activeOffset: Int,
    archivedOffset: Int,
    pageSize: Int
  ) throws -> MosaicConversationSidebarPages {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let pageSize = max(1, pageSize)
    let activeOffset = max(0, activeOffset)
    let archivedOffset = max(0, archivedOffset)
    try Task.checkCancellation()

    if query.isEmpty {
      return try decorated(
        MosaicConversationSidebarPages(
          active: try page(isArchived: false, offset: activeOffset, pageSize: pageSize),
          archived: try page(isArchived: true, offset: archivedOffset, pageSize: pageSize)
        )
      )
    }

    // Keep the potentially large match set on this model actor. Returning it through the root
    // task would move up to the archive record cap onto the main actor before page reduction.
    let messageConversationIDs = try matchingMessageConversationIDs(query: query)
    var activeMatchesSeen = 0
    var archivedMatchesSeen = 0
    var activeItems: [MosaicConversationSidebarItem] = []
    var archivedItems: [MosaicConversationSidebarItem] = []
    var cursor: MosaicConversationSearchCursor?
    activeItems.reserveCapacity(pageSize + 1)
    archivedItems.reserveCapacity(pageSize + 1)

    conversationScan: while true {
      try Task.checkCancellation()
      var descriptor: FetchDescriptor<ConversationRecord>
      if let cursor {
        let cursorUpdatedAt = cursor.updatedAt
        let cursorCreatedAt = cursor.createdAt
        let cursorID = cursor.id
        descriptor = FetchDescriptor(
          predicate: #Predicate {
            $0.updatedAt < cursorUpdatedAt
              || ($0.updatedAt == cursorUpdatedAt
                && ($0.createdAt < cursorCreatedAt
                  || ($0.createdAt == cursorCreatedAt && $0.id > cursorID)))
          },
          sortBy: Self.sortDescriptors
        )
      } else {
        descriptor = FetchDescriptor(sortBy: Self.sortDescriptors)
      }
      descriptor.fetchLimit = 4
      descriptor.includePendingChanges = false
      let conversations = try modelContext.fetch(descriptor)
      guard !conversations.isEmpty else { break }

      for conversation in conversations {
        guard try isVisible(conversation) else { continue }
        guard
          conversation.title.localizedCaseInsensitiveContains(query)
            || messageConversationIDs.contains(conversation.id)
        else {
          continue
        }

        if conversation.isArchived {
          if archivedMatchesSeen >= archivedOffset, archivedItems.count <= pageSize {
            archivedItems.append(MosaicConversationSidebarItem(conversation))
          }
          archivedMatchesSeen += 1
        } else {
          if activeMatchesSeen >= activeOffset, activeItems.count <= pageSize {
            activeItems.append(MosaicConversationSidebarItem(conversation))
          }
          activeMatchesSeen += 1
        }

        if activeItems.count > pageSize, archivedItems.count > pageSize {
          break conversationScan
        }
      }

      cursor = conversations.last.map {
        MosaicConversationSearchCursor(
          updatedAt: $0.updatedAt,
          createdAt: $0.createdAt,
          id: $0.id
        )
      }
      if conversations.count < 4 { break }
    }

    return try decorated(
      MosaicConversationSidebarPages(
        active: Self.page(from: activeItems, offset: activeOffset, pageSize: pageSize),
        archived: Self.page(from: archivedItems, offset: archivedOffset, pageSize: pageSize)
      ))
  }

  private func decorated(
    _ pages: MosaicConversationSidebarPages
  ) throws -> MosaicConversationSidebarPages {
    let ids = Array(Set((pages.active.items + pages.archived.items).map(\.id)))
    let conversationKind = ProjectResourceKind.conversation.rawValue
    let bindings = try modelContext.fetch(
      FetchDescriptor<ProjectResourceBindingRecord>(
        predicate: #Predicate {
          $0.resourceKindRawValue == conversationKind && ids.contains($0.resourceID)
        }
      )
    )
    let bindingsByConversation = Dictionary(
      bindings.map { ($0.resourceID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let projectIDs = Array(Set(bindings.map(\.projectID)))
    let projects = try modelContext.fetch(
      FetchDescriptor<ProjectRecord>(predicate: #Predicate { projectIDs.contains($0.id) })
    )
    let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
    func decorate(_ page: MosaicConversationSidebarPage) -> MosaicConversationSidebarPage {
      MosaicConversationSidebarPage(
        items: page.items.map { item in
          let binding = bindingsByConversation[item.id]
          let projectID = binding?.projectID
          return MosaicConversationSidebarItem(
            id: item.id,
            title: item.title,
            providerConfigurationID: item.providerConfigurationID,
            projectID: projectID,
            projectName: projectID.flatMap { names[$0] },
            projectBindingID: binding?.id,
            projectBindingUpdatedAt: binding?.updatedAt,
            isArchived: item.isArchived,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt
          )
        },
        offset: page.offset,
        hasNextPage: page.hasNextPage
      )
    }
    return MosaicConversationSidebarPages(
      active: decorate(pages.active),
      archived: decorate(pages.archived)
    )
  }

  private func matchingMessageConversationIDs(query: String) throws -> Set<UUID> {
    var conversationIDs: Set<UUID> = []
    var cursor: MosaicMessageSearchCursor?
    while true {
      try Task.checkCancellation()
      var descriptor: FetchDescriptor<MessageRecord>
      if let cursor {
        let cursorID = cursor.id
        descriptor = FetchDescriptor(
          predicate: #Predicate { $0.id > cursorID },
          sortBy: [SortDescriptor(\MessageRecord.id)]
        )
      } else {
        descriptor = FetchDescriptor(sortBy: [SortDescriptor(\MessageRecord.id)])
      }
      descriptor.fetchLimit = 4
      descriptor.includePendingChanges = false
      let messages = try modelContext.fetch(descriptor)
      guard !messages.isEmpty else { break }
      for message in messages {
        if message.content.localizedCaseInsensitiveContains(query) {
          conversationIDs.insert(message.conversationID)
        }
      }
      cursor = messages.last.map { MosaicMessageSearchCursor(id: $0.id) }
      if messages.count < 4 { break }
    }
    return conversationIDs
  }

  private func page(
    isArchived: Bool,
    offset: Int,
    pageSize: Int
  ) throws -> MosaicConversationSidebarPage {
    var items: [MosaicConversationSidebarItem] = []
    var scanned = 0
    var visible = 0
    while items.count <= pageSize {
      try Task.checkCancellation()
      var descriptor = FetchDescriptor<ConversationRecord>(
        predicate: #Predicate { $0.isArchived == isArchived }, sortBy: Self.sortDescriptors)
      descriptor.fetchOffset = scanned
      descriptor.fetchLimit = 32
      descriptor.includePendingChanges = false
      let batch = try modelContext.fetch(descriptor)
      for conversation in batch where try isVisible(conversation) {
        if visible >= offset { items.append(MosaicConversationSidebarItem(conversation)) }
        visible += 1
        if items.count > pageSize { break }
      }
      scanned += batch.count
      if batch.count < 32 { break }
    }
    return Self.page(from: items, offset: offset, pageSize: pageSize)
  }

  private func isVisible(_ conversation: ConversationRecord) throws -> Bool {
    if !conversation.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return true
    }
    let id = conversation.id
    var attachments = FetchDescriptor<ExperienceRecord>(
      predicate: #Predicate {
        $0.category == "attachment" && $0.ownerID == id && $0.messageID == nil
      })
    attachments.fetchLimit = 1
    if try modelContext.fetchCount(attachments) > 0 { return true }
    var descriptor = FetchDescriptor<MessageRecord>(
      predicate: #Predicate { $0.conversationID == id })
    descriptor.fetchLimit = 1
    descriptor.includePendingChanges = false
    return try modelContext.fetchCount(descriptor) > 0
  }

  private nonisolated static let sortDescriptors = [
    SortDescriptor(\ConversationRecord.updatedAt, order: .reverse),
    SortDescriptor(\ConversationRecord.createdAt, order: .reverse),
    SortDescriptor(\ConversationRecord.id),
  ]

  private nonisolated static func page(
    from items: [MosaicConversationSidebarItem],
    offset: Int,
    pageSize: Int
  ) -> MosaicConversationSidebarPage {
    MosaicConversationSidebarPage(
      items: Array(items.prefix(pageSize)),
      offset: offset,
      hasNextPage: items.count > pageSize
    )
  }
}

extension Notification.Name {
  public static let mosaicNewChat = Notification.Name("Mosaic.NewChat")
}

private enum WorkspaceDestination: Hashable {
  case conversation(UUID)
  case project(UUID)
  case projects
  case memory
  case tasks
  case providers
  case dataRecovery
  case sharedInbox
  case settings
  case usage
  case iCloud
  case connections
  #if os(iOS)
    case watch
  #endif
}

private struct SelectedConversationIdentity: Hashable {
  let conversationID: UUID
  let sourceStoreGenerationRevision: UInt64
}

private struct MosaicConversationSidebarRequest: Hashable {
  let query: String
  let sourceStoreGenerationRevision: UInt64
  let conversationCatalogRevision: UInt64
  let messageSearchRevision: UInt64
  let activePageIndex: Int
  let archivedPageIndex: Int
  let reloadRevision: UInt64
  let sourceAccessIsBlocked: Bool
}

@MainActor
public struct MosaicRootView: View {
  @AppStorage(InterfacePreferences.advancedControlsKey) private var advancedControls = false
  @Environment(\.modelContext) private var modelContext
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif
  @Query(sort: \ProviderConfigurationRecord.createdAt)
  private var providers: [ProviderConfigurationRecord]
  @Query(sort: \ProjectRecord.updatedAt, order: .reverse)
  private var projects: [ProjectRecord]
  @AppStorage(AutomaticMemorySettings.enabledKey)
  private var automaticMemoryEnabled = true

  @State private var selection: WorkspaceDestination?
  @State private var showTemporaryChat = false
  @State private var showChatHistory = false
  @State private var opensTemporaryAfterHistory = false
  @State private var homeConversationID: UUID?
  @State private var compactDestinations: [WorkspaceDestination] = []
  @State private var searchText = ""
  @Query private var providerModels: [ProviderModelRecord]
  @State private var conversationPages = MosaicConversationSidebarPages.empty
  @State private var activeConversationPageIndex = 0
  @State private var archivedConversationPageIndex = 0
  @State private var loadedConversationQuery = ""
  @State private var loadedConversationSourceGeneration: UInt64?
  @State private var loadedConversationCatalogRevision: UInt64?
  @State private var isLoadingConversationPages = false
  @State private var conversationLoadError: String?
  @State private var conversationReloadRevision: UInt64 = 0
  @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
  @State private var taskRunner: ForegroundTaskRunner
  @State private var operationCoordinator = MosaicOperationCoordinator.shared
  @State private var persistenceError: String?
  @State private var pendingConversationDeletion: MosaicConversationSidebarItem?
  @State private var pendingConversationDeletionSourceGeneration: UInt64?
  @State private var deletingConversation: MosaicConversationSidebarItem?
  @State private var deletionTask: Task<Void, Never>?
  @State private var deletionCommitStarted = false
  @State private var isCancellingDeletion = false
  @State private var rootIsPresented = false
  @State private var rootSceneIsActive = false
  @State private var scheduledTaskLoop: Task<Void, Never>?
  @State private var scheduledTaskLoopID: UUID?
  @State private var automaticMemoryRecoveryTask: Task<Void, Never>?
  @State private var automaticMemoryRecoveryTaskID: UUID?

  private static let conversationPageSize = 16

  public init(taskRunner: ForegroundTaskRunner = .shared) {
    _taskRunner = State(initialValue: taskRunner)
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--in-memory"),
        ProcessInfo.processInfo.arguments.contains("--google-connections-preview")
      {
        _selection = State(initialValue: .connections)
        _compactDestinations = State(initialValue: [.connections])
      }
    #endif
  }

  private func loadConversationSidebar() async {
    let request = conversationSidebarRequest
    guard !request.sourceAccessIsBlocked else { return }
    if loadedConversationQuery != request.query
      || loadedConversationSourceGeneration != request.sourceStoreGenerationRevision
    {
      conversationPages = .empty
    }
    conversationLoadError = nil
    isLoadingConversationPages = true
    defer {
      if conversationSidebarRequest == request {
        isLoadingConversationPages = false
      }
    }
    do {
      if !request.query.isEmpty {
        try await Task.sleep(for: .milliseconds(180))
      }
      try Task.checkCancellation()
      let container = modelContext.container
      let catalog = await Task.detached(priority: .userInitiated) {
        MosaicConversationSidebarCatalog(modelContainer: container)
      }.value
      let pages = try await catalog.pages(
        query: request.query,
        activeOffset: request.activePageIndex * Self.conversationPageSize,
        archivedOffset: request.archivedPageIndex * Self.conversationPageSize,
        pageSize: Self.conversationPageSize
      )
      try Task.checkCancellation()
      guard conversationSidebarRequest == request else { return }
      conversationPages = pages
      loadedConversationQuery = request.query
      loadedConversationSourceGeneration = request.sourceStoreGenerationRevision
      loadedConversationCatalogRevision = request.conversationCatalogRevision
    } catch is CancellationError {
      return
    } catch {
      guard conversationSidebarRequest == request else { return }
      conversationLoadError = error.localizedDescription
    }
  }

  private var workspaceWithHistory: some View {
    Group {
      workspaceNavigation
        .allowsHitTesting(!showChatHistory)
        .accessibilityHidden(showChatHistory)
    }
    .modifier(
      HistoryEdgeSwipe(
        enabled: usesCompactNavigation && compactDestinations.isEmpty && !showChatHistory
      ) {
        showChatHistory = true
      }
    )
    .overlay {
      if showChatHistory, usesCompactNavigation {
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Button {
              showChatHistory = false
            } label: {
              Color.black.opacity(0.35).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close conversation history")
            NavigationStack {
              sidebar
                .toolbar {
                  ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showChatHistory = false }
                  }
                }
            }
            .frame(width: geometry.size.width)
            .background(.background)
            .transition(.move(edge: .leading))
            .simultaneousGesture(
              DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.width < -60,
                  abs(value.translation.width) > abs(value.translation.height) * 1.5
                {
                  showChatHistory = false
                }
              }
            )
            .disabled(operationCoordinator.isSourceAccessBlocked || deletingConversation != nil)
          }
        }
        .transition(.opacity)
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showChatHistory)

  }

  public var body: some View {
    workspaceWithHistory
      .sheet(isPresented: $showTemporaryChat) { TemporaryChatView() }
      .onChange(of: showChatHistory) { _, visible in
        if !visible, opensTemporaryAfterHistory {
          opensTemporaryAfterHistory = false
          showTemporaryChat = true
        }
      }
      .task(id: shouldPrepareHome) {
        if shouldPrepareHome { createConversation() }
      }
      .overlay {
        if let deletingConversation {
          VStack(spacing: 12) {
            ProgressView(
              deletionCommitStarted
                ? "Finishing deletion…"
                : (isCancellingDeletion ? "Stopping deletion…" : "Deleting conversation…")
            )
            Text(deletingConversation.title)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            if !deletionCommitStarted {
              Button("Cancel", role: .cancel) {
                isCancellingDeletion = true
                deletionTask?.cancel()
              }
              .disabled(isCancellingDeletion)
            }
          }
          .padding(20)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
          .accessibilityElement(children: .contain)
        }
      }
      .task(id: scenePhase == .active) {
        guard scenePhase == .active else { return }
        // Let the first frame and navigation settle before background library work.
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        while !Task.isCancelled {
          await ICloudLibraryCoordinator.shared.sync(in: modelContext)
          do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
      }
      .onAppear {
        #if DEBUG
          if homeConversationID == nil,
            ProcessInfo.processInfo.arguments.contains("--in-memory"),
            ProcessInfo.processInfo.arguments.contains("--sources-preview"),
            let id = try? MessageSourcesPreview.seed(in: modelContext)
          {
            navigate(to: .conversation(id))
          }
        #endif
        #if os(iOS)
          WatchCompanionCoordinator.shared.attach(modelContext)
        #endif
        rootIsPresented = true
        rootSceneIsActive = scenePhase == .active
        reconcileInterruptedResponses()
        if operationCoordinator.isSourceStoreUnavailable {
          navigate(to: .dataRecovery)
        }
        startScheduledTaskLoopIfNeeded()
        startAutomaticMemoryRecoveryIfNeeded()
      }
      .onDisappear {
        // Paid provider work owns its lifecycle. Mark the shell inactive so each loop exits after its
        // current operation instead of cancelling that operation during navigation or window teardown.
        rootIsPresented = false
        rootSceneIsActive = false
      }
      .onChange(of: scenePhase) { _, newPhase in
        rootSceneIsActive = newPhase == .active
        if rootSceneIsActive {
          startScheduledTaskLoopIfNeeded()
          startAutomaticMemoryRecoveryIfNeeded()
        }
      }
      .onChange(of: operationCoordinator.isSourceStoreUnavailable) { _, isUnavailable in
        if isUnavailable { navigate(to: .dataRecovery) }
      }
      .onChange(of: operationCoordinator.isSourceAccessBlocked) { _, isBlocked in
        if isBlocked {
          pendingConversationDeletion = nil
          pendingConversationDeletionSourceGeneration = nil
        } else {
          reconcileInterruptedResponses(reason: .operationsDrained)
          startScheduledTaskLoopIfNeeded()
          startAutomaticMemoryRecoveryIfNeeded()
        }
      }
      .onChange(of: operationCoordinator.activeOperations) { _, activeOperations in
        guard activeOperations.isEmpty else { return }
        reconcileInterruptedResponses(reason: .operationsDrained)
        startScheduledTaskLoopIfNeeded()
        startAutomaticMemoryRecoveryIfNeeded()
      }
      .onReceive(NotificationCenter.default.publisher(for: .mosaicNewChat)) { _ in
        createConversation()
      }
      .onChange(of: selection) { _, destination in
        if case .conversation(let id) = destination { homeConversationID = id }
      }
      .onChange(of: searchText) { previous, current in
        guard Self.normalizedQuery(previous) != Self.normalizedQuery(current) else { return }
        resetConversationPagination()
      }
      .onChange(of: operationCoordinator.conversationCatalogRevision) { _, _ in
        resetConversationPagination()
      }
      .onChange(of: operationCoordinator.sourceStoreGenerationRevision) { _, _ in
        pendingConversationDeletion = nil
        pendingConversationDeletionSourceGeneration = nil
        conversationPages = .empty
        loadedConversationQuery = ""
        loadedConversationSourceGeneration = nil
        loadedConversationCatalogRevision = nil
        resetConversationPagination()
        reconcileInterruptedResponses()
        startScheduledTaskLoopIfNeeded()
        startAutomaticMemoryRecoveryIfNeeded()
      }
      .task(id: conversationSidebarRequest) { await loadConversationSidebar() }
      .alert("Turing AI couldn’t save this change", isPresented: persistenceErrorIsPresented) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(persistenceError ?? "Please try again.")
      }
      .confirmationDialog(
        conversationDeletionTitle,
        isPresented: conversationDeletionIsPresented,
        titleVisibility: .visible
      ) {
        Button("Delete Conversation", role: .destructive) {
          guard let conversation = pendingConversationDeletion,
            let sourceGeneration = pendingConversationDeletionSourceGeneration,
            sourceGeneration == operationCoordinator.sourceStoreGenerationRevision,
            loadedConversationSourceGeneration == sourceGeneration,
            !operationCoordinator.isSourceAccessBlocked
          else {
            pendingConversationDeletion = nil
            pendingConversationDeletionSourceGeneration = nil
            return
          }
          pendingConversationDeletion = nil
          pendingConversationDeletionSourceGeneration = nil
          delete(conversation, sourceGeneration: sourceGeneration)
        }
        Button("Cancel", role: .cancel) {
          pendingConversationDeletion = nil
          pendingConversationDeletionSourceGeneration = nil
        }
      } message: {
        Text(
          "This permanently removes the conversation, its chat-scoped memory, and its local search index. Learned topics supported only by this chat will stop being recalled; topics you corrected manually stay. This can’t be undone."
        )
      }
      .task(id: operationCoordinator.sourceStoreGenerationRevision) {
        guard !operationCoordinator.isSourceAccessBlocked else { return }
        await reconcilePendingProviderCredentialCleanup()
        await taskRunner.reconcileTaskReminders(in: modelContext)
      }
      .onChange(of: automaticMemoryRecoveryRequest) { _, _ in
        startAutomaticMemoryRecoveryIfNeeded()
      }
  }

  private var automaticMemoryRecoveryRequest: AutomaticMemoryRecoveryRequest {
    AutomaticMemoryRecoveryRequest(
      isActive: rootIsPresented && rootSceneIsActive
        && !operationCoordinator.isSourceAccessBlocked,
      isEnabled: automaticMemoryEnabled,
      providerIDs: providers.filter(\.isEnabled).map(\.id).sorted { $0.uuidString < $1.uuidString },
      sourceGeneration: operationCoordinator.sourceStoreGenerationRevision
    )
  }

  private func reconcilePendingProviderCredentialCleanup() async {
    guard
      !operationCoordinator.activeOperations.contains(where: {
        if case .providerMutation = $0 { return true }
        return false
      })
    else { return }

    _ = await ProviderConfigurationDeletionTransaction.reconcile(
      existingProviderIDs: Set(providers.map(\.id)),
      removeCredential: { locator in
        try await SecurityKeychain(service: locator.service).removeAPIKey(
          for: locator.configurationID
        )
      }
    )
  }

  private func startScheduledTaskLoopIfNeeded() {
    guard rootIsPresented, rootSceneIsActive,
      !operationCoordinator.isSourceAccessBlocked,
      scheduledTaskLoop == nil
    else {
      return
    }

    let loopID = UUID()
    scheduledTaskLoopID = loopID
    scheduledTaskLoop = Task { @MainActor in
      defer {
        if scheduledTaskLoopID == loopID {
          scheduledTaskLoop = nil
          scheduledTaskLoopID = nil
        }
      }
      while !Task.isCancelled {
        guard rootIsPresented, rootSceneIsActive,
          !operationCoordinator.isSourceAccessBlocked
        else {
          return
        }
        await taskRunner.runDueTasks(in: modelContext) {
          rootIsPresented && rootSceneIsActive
            && !operationCoordinator.isSourceAccessBlocked
        }
        guard rootIsPresented, rootSceneIsActive,
          !operationCoordinator.isSourceAccessBlocked
        else {
          return
        }
        do {
          try await Task.sleep(for: .seconds(30))
        } catch {
          return
        }
      }
    }
  }

  private func startAutomaticMemoryRecoveryIfNeeded() {
    let request = automaticMemoryRecoveryRequest
    guard request.isActive, request.isEnabled, automaticMemoryRecoveryTask == nil else { return }

    let taskID = UUID()
    automaticMemoryRecoveryTaskID = taskID
    automaticMemoryRecoveryTask = Task { @MainActor in
      await resumeInterruptedMemoryFormation(request: request)
      guard automaticMemoryRecoveryTaskID == taskID else { return }
      automaticMemoryRecoveryTask = nil
      automaticMemoryRecoveryTaskID = nil

      let currentRequest = automaticMemoryRecoveryRequest
      if currentRequest.isActive, currentRequest.isEnabled, currentRequest != request {
        startAutomaticMemoryRecoveryIfNeeded()
      }
    }
  }

  private func reconcileInterruptedResponses(
    reason: ConversationInterruptedResponseRecovery.ScanReason = .generationOpened
  ) {
    do {
      _ = try ConversationInterruptedResponseRecovery.shared.reconcile(
        in: modelContext,
        sourceGeneration: operationCoordinator.sourceStoreGenerationRevision,
        reason: reason
      )
    } catch {
      persistenceError =
        "Turing AI found an interrupted response but could not make it retryable. \(error.localizedDescription)"
    }
  }

  /// Finishes only work interrupted by app termination. Provider failures remain visible for a
  /// user-directed retry instead of creating an uncontrolled retry loop or surprise API spend.
  private func resumeInterruptedMemoryFormation(
    request: AutomaticMemoryRecoveryRequest
  ) async {
    let container = modelContext.container
    let store = await Task.detached(priority: .utility) {
      AutomaticMemoryStore(modelContainer: container)
    }.value
    while !Task.isCancelled, automaticMemoryRecoveryRequest == request {
      guard let jobs = try? await store.pendingJobs(), !jobs.isEmpty else { return }
      var madeProgress = false

      for job in jobs {
        guard !Task.isCancelled,
          automaticMemoryRecoveryRequest == request
        else { return }
        guard let providerID = job.providerConfigurationID,
          let record = providers.first(where: { $0.id == providerID }),
          let modelIdentifier = job.modelIdentifier,
          let provider = try? ProviderModelStore.connection(
            provider: record,
            modelIdentifier: modelIdentifier, models: providerModels)
        else {
          let operationID = MosaicOperationID.memoryFormation(job.throughUserMessageID)
          guard operationCoordinator.begin(operationID) else { continue }
          defer { operationCoordinator.end(operationID) }
          try? await store.markFailed(
            jobID: job.id,
            error: AutomaticMemoryStoreError.providerUnavailable
          )
          operationCoordinator.markMemoryLibraryChanged()
          madeProgress = true
          continue
        }
        let operationID = MosaicOperationID.memoryFormation(job.throughUserMessageID)
        guard operationCoordinator.begin(operationID) else { continue }
        madeProgress = true
        var apiKeyForRedaction: String?
        do {
          let apiKey = try await SecurityKeychain.shared.apiKey(
            for: provider.id,
            expectedBinding: provider.credentialBinding
          )
          apiKeyForRedaction = apiKey
          let connection = provider.authenticated(with: apiKey)
          let result = try await AutomaticMemoryFormationCoordinator.shared.formMemory(
            conversationID: job.conversationID,
            throughUserMessageID: job.throughUserMessageID,
            assistantMessageID: job.assistantMessageID,
            provider: connection,
            client: ProviderClientFactory.make(connection: connection),
            modelContainer: modelContext.container,
            resumingJobID: job.id
          )
          if result.changedCount > 0 { operationCoordinator.markMemoryLibraryChanged() }
        } catch {
          // The coordinator records provider-call failures. This also covers failures that happen
          // while reopening the Keychain before a provider request can begin.
          try? await store.markFailed(
            jobID: job.id,
            error: error,
            redacting: apiKeyForRedaction
          )
          operationCoordinator.markMemoryLibraryChanged()
        }
        operationCoordinator.end(operationID)
      }
      guard madeProgress else { return }
    }
  }

  private var usesCompactNavigation: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize
    #else
      false
    #endif
  }

  // Chat is the compact root; settings/project pages own a separate stack above it.
  // Async sidebar paging must never remove the currently open conversation.
  private var compactPath: Binding<[WorkspaceDestination]> {
    Binding(
      get: { compactDestinations },
      set: {
        compactDestinations = $0
        selection = $0.last ?? homeConversationID.map(WorkspaceDestination.conversation)
      })
  }

  private var shouldPrepareHome: Bool {
    selection == nil && homeConversationID == nil && conversationCatalogIsCurrent
      && !operationCoordinator.isSourceAccessBlocked && deletingConversation == nil
      && !ProviderModelStore.choices(providers: providers, models: providerModels).isEmpty
  }

  private func navigate(to destination: WorkspaceDestination) {
    showChatHistory = false
    if case .conversation(let id) = destination {
      homeConversationID = id
      compactDestinations = []
    } else if usesCompactNavigation {
      compactDestinations.append(destination)
    }
    selection = destination
  }

  @ViewBuilder
  private var workspaceNavigation: some View {
    if usesCompactNavigation {
      NavigationStack(path: compactPath) {
        protectedDetail(for: homeConversationID.map(WorkspaceDestination.conversation))
          .toolbar {
            ToolbarItem(placement: .navigation) {
              Button("Chats", systemImage: "line.3.horizontal") { showChatHistory = true }
                .accessibilityHint("Open conversation history and settings")
            }
            ToolbarItem(placement: .primaryAction) {
              Button("New Chat", systemImage: "square.and.pencil") { createConversation() }
                .disabled(
                  !conversationCatalogIsCurrent || operationCoordinator.isSourceAccessBlocked)
            }
            ToolbarItemGroup(placement: .secondaryAction) {
              Button("Temporary chat", systemImage: "eye.slash") { showTemporaryChat = true }
              Button("Settings", systemImage: "gearshape") { navigate(to: .settings) }
            }
          }
          .navigationDestination(for: WorkspaceDestination.self) { destination in
            protectedDetail(for: destination)
          }
      }
    } else {
      NavigationSplitView(columnVisibility: $columnVisibility) {
        sidebar
          .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
          .disabled(operationCoordinator.isSourceAccessBlocked || deletingConversation != nil)
      } detail: {
        protectedDetail(for: selection)
      }
    }
  }

  private func protectedDetail(for destination: WorkspaceDestination?) -> some View {
    destinationView(for: destination)
      .disabled(
        (detailSourceAccessIsBlocked && destination != .dataRecovery)
          || deletingConversation != nil
      )
      .allowsHitTesting(
        (!detailSourceAccessIsBlocked || destination == .dataRecovery)
          && deletingConversation == nil
      )
      .overlay {
        if detailSourceAccessIsBlocked && destination != .dataRecovery
          && deletingConversation == nil
        {
          ProgressView(
            operationCoordinator.isSourceStoreUnavailable
              ? "Local library needs recovery…"
              : "Updating local library…"
          )
          .padding(20)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
          .accessibilityHint(
            operationCoordinator.isSourceStoreUnavailable
              ? "Open Data and Recovery and restore a valid backup"
              : "Wait for the restore in the Data and Recovery view to finish"
          )
        }
      }
  }

  @ViewBuilder
  private func workspaceLink<LabelContent: View>(
    _ destination: WorkspaceDestination,
    @ViewBuilder label: () -> LabelContent
  ) -> some View {
    Button {
      navigate(to: destination)
    } label: {
      HStack {
        label()
        Spacer(minLength: 8)
        if usesCompactNavigation {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .tag(destination)
  }

  private var sidebar: some View {
    List(selection: usesCompactNavigation ? .constant(nil) : $selection) {
      Section {
        Button("New chat", systemImage: "square.and.pencil") { createConversation() }
        Button("Temporary chat", systemImage: "eye.slash") {
          if showChatHistory {
            opensTemporaryAfterHistory = true
            showChatHistory = false
          } else {
            showTemporaryChat = true
          }
        }
      }

      Section("Projects") {
        workspaceLink(WorkspaceDestination.projects) {
          Label("All Projects", systemImage: "folder")
        }
        ForEach(activeProjects) { project in
          workspaceLink(WorkspaceDestination.project(project.id)) {
            Label(project.name, systemImage: "folder.fill")
              .lineLimit(1)
          }
        }
      }

      Section("Chats") {
        if isLoadingConversationPages, conversationPages.active.items.isEmpty {
          ProgressView(normalizedSearchText.isEmpty ? "Loading chats…" : "Searching chats…")
        }

        ForEach(conversationPages.active.items) { conversation in
          workspaceLink(WorkspaceDestination.conversation(conversation.id)) {
            ConversationRow(
              conversation: conversation,
              provider: providerKind(for: conversation)
            )
          }
          .contextMenu {
            projectAssignmentMenu(for: conversation)
            Button("Archive", systemImage: "archivebox") {
              archive(conversation)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
              requestConversationDeletion(conversation)
            }
          }
        }

        if !isLoadingConversationPages,
          conversationPages.active.items.isEmpty,
          conversationLoadError == nil
        {
          Label(
            normalizedSearchText.isEmpty ? "No active chats" : "No matching active chats",
            systemImage: "bubble.left"
          )
          .foregroundStyle(.secondary)
        }

        conversationPaginationControls(
          page: conversationPages.active,
          pageIndex: activeConversationPageIndex,
          previous: { activeConversationPageIndex -= 1 },
          next: { activeConversationPageIndex += 1 }
        )

        if let conversationLoadError {
          Label(conversationLoadError, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
          Button("Try Again") { conversationReloadRevision &+= 1 }
        } else if isLoadingConversationPages, !conversationPages.active.items.isEmpty {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(
              normalizedSearchText.isEmpty ? "Loading chat page" : "Searching chat page"
            )
        }
      }

      if !conversationPages.archived.items.isEmpty
        || conversationPages.archived.hasPreviousPage
        || conversationPages.archived.hasNextPage
      {
        Section("Archived") {
          ForEach(conversationPages.archived.items) { conversation in
            workspaceLink(WorkspaceDestination.conversation(conversation.id)) {
              ConversationRow(
                conversation: conversation,
                provider: providerKind(for: conversation)
              )
            }
            .contextMenu {
              projectAssignmentMenu(for: conversation)
              Button("Unarchive", systemImage: "tray.and.arrow.up") {
                unarchive(conversation)
              }
              Divider()
              Button("Delete", systemImage: "trash", role: .destructive) {
                requestConversationDeletion(conversation)
              }
            }
          }

          conversationPaginationControls(
            page: conversationPages.archived,
            pageIndex: archivedConversationPageIndex,
            previous: { archivedConversationPageIndex -= 1 },
            next: { archivedConversationPageIndex += 1 }
          )
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        Divider()
        workspaceLink(.settings) {
          Label("Settings", systemImage: "gearshape")
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
      }
      .background(.bar)
    }
    .navigationTitle("Chats")
    .searchable(text: $searchText, prompt: "Search chats")
    .toolbar {
      ToolbarItem(id: "new-chat", placement: .primaryAction) {
        Button(action: { createConversation() }) {
          Label("New Chat", systemImage: "square.and.pencil")
        }
        .keyboardShortcut("n")
        .accessibilityHint("Creates a conversation with your default provider")
      }
    }
  }

  private var settings: some View {
    Form {
      InterfaceModeSection()
      Section {
        workspaceLink(WorkspaceDestination.memory) {
          Label("Memory", systemImage: "brain.head.profile")
        }
        workspaceLink(WorkspaceDestination.tasks) {
          Label("Automations", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
        }
        workspaceLink(WorkspaceDestination.providers) {
          Label(advancedControls ? "Providers" : "AI models & accounts", systemImage: "server.rack")
        }
        #if os(iOS)
          workspaceLink(.watch) { Label("Apple Watch", systemImage: "applewatch") }
          workspaceLink(.sharedInbox) {
            Label("Shared items", systemImage: "square.and.arrow.down")
          }
        #endif
        workspaceLink(.connections) {
          Label("Connections", systemImage: "link")
        }
        workspaceLink(.usage) {
          Label(advancedControls ? "Usage & Cost" : "Spending", systemImage: "chart.bar")
        }
        workspaceLink(.iCloud) {
          Label("iCloud", systemImage: "icloud")
        }
        workspaceLink(WorkspaceDestination.dataRecovery) {
          Label("Data & Recovery", systemImage: "externaldrive")
        }
      }

    }
    .navigationTitle("Settings")
  }

  @ViewBuilder
  private func destinationView(for destination: WorkspaceDestination?) -> some View {
    switch destination {
    case .conversation(let id):
      SelectedConversationDestination(conversationID: id, open: { navigate(to: .conversation($0)) })
      {
        welcome
      }
      .id(
        SelectedConversationIdentity(
          conversationID: id,
          sourceStoreGenerationRevision: operationCoordinator.sourceStoreGenerationRevision
        )
      )
    case .project(let id):
      ProjectDetailView(projectID: id) { projectID in
        createConversation(projectID: projectID)
      }
    case .projects:
      ProjectLibraryView { projectID in
        createConversation(projectID: projectID)
      }
    case .sharedInbox:
      SharedInboxView(open: { navigate(to: .conversation($0)) })
    case .memory:
      MemoryLibraryView()
    case .tasks:
      ScheduledTasksView(runner: taskRunner)
    case .providers:
      ProviderLibraryView()
    case .dataRecovery:
      MosaicDataRecoveryView()
    case .settings:
      settings
    case .usage:
      UsageReportView()
    case .connections:
      ConnectionsView()
    case .iCloud:
      ICloudSettingsView()
    #if os(iOS)
      case .watch:
        WatchSettingsView()
    #endif
    case nil:
      welcome
    }
  }

  private var welcome: some View {
    WelcomeView(
      hasProvider: hasEnabledChatProvider,
      newChat: { createConversation() },
      showProviders: { navigate(to: .providers) }
    )
  }

  private var persistenceErrorIsPresented: Binding<Bool> {
    Binding(
      get: { persistenceError != nil },
      set: { if !$0 { persistenceError = nil } }
    )
  }

  private var hasEnabledChatProvider: Bool {
    providers.contains { $0.isEnabled && $0.provider.supportsChat }
  }

  private var activeProjects: [ProjectRecord] {
    projects.filter { !$0.isArchived }
  }

  private var conversationDeletionIsPresented: Binding<Bool> {
    Binding(
      get: { pendingConversationDeletion != nil },
      set: {
        if !$0 {
          pendingConversationDeletion = nil
          pendingConversationDeletionSourceGeneration = nil
        }
      }
    )
  }

  private var conversationDeletionTitle: String {
    guard let conversation = pendingConversationDeletion else { return "Delete Conversation?" }
    return "Delete \(conversation.title)?"
  }

  private func providerKind(for conversation: MosaicConversationSidebarItem) -> ProviderKind? {
    guard let providerID = conversation.providerConfigurationID else { return nil }
    return providers.first(where: { $0.id == providerID })?.provider
  }

  private var normalizedSearchText: String {
    Self.normalizedQuery(searchText)
  }

  private var conversationSidebarRequest: MosaicConversationSidebarRequest {
    MosaicConversationSidebarRequest(
      query: normalizedSearchText,
      sourceStoreGenerationRevision: operationCoordinator.sourceStoreGenerationRevision,
      conversationCatalogRevision: operationCoordinator.conversationCatalogRevision,
      messageSearchRevision: normalizedSearchText.isEmpty
        ? 0
        : operationCoordinator.messageSearchRevision,
      activePageIndex: activeConversationPageIndex,
      archivedPageIndex: archivedConversationPageIndex,
      reloadRevision: conversationReloadRevision,
      sourceAccessIsBlocked: operationCoordinator.isSourceAccessBlocked
    )
  }

  private var conversationCatalogIsCurrent: Bool {
    loadedConversationSourceGeneration == operationCoordinator.sourceStoreGenerationRevision
      && loadedConversationCatalogRevision == operationCoordinator.conversationCatalogRevision
  }

  /// A document deletion owns the source lease, so every ordinary Memory action is already gated
  /// by `MemoryLibraryView.libraryIsCurrent`. Keep only that destination hittable so the window
  /// that owns the deletion can still expose its pre-commit Cancel control.
  private var detailSourceAccessIsBlocked: Bool {
    operationCoordinator.isSourceAccessBlocked
      && !(operationCoordinator.isDocumentDeletionActive && selection == .memory)
  }

  private func resetConversationPagination() {
    activeConversationPageIndex = 0
    archivedConversationPageIndex = 0
  }

  private static func normalizedQuery(_ query: String) -> String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @ViewBuilder
  private func conversationPaginationControls(
    page: MosaicConversationSidebarPage,
    pageIndex: Int,
    previous: @escaping () -> Void,
    next: @escaping () -> Void
  ) -> some View {
    if page.hasPreviousPage || page.hasNextPage {
      HStack(spacing: 8) {
        Button(action: previous) {
          Label("Newer", systemImage: "chevron.up")
        }
        .disabled(!page.hasPreviousPage || isLoadingConversationPages)

        Spacer(minLength: 4)
        Text("Page \((pageIndex + 1).formatted())")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 4)

        Button(action: next) {
          Label("Older", systemImage: "chevron.down")
        }
        .disabled(!page.hasNextPage || isLoadingConversationPages)
      }
      .buttonStyle(.borderless)
      .accessibilityElement(children: .contain)
    }
  }

  private func requestConversationDeletion(_ item: MosaicConversationSidebarItem) {
    guard conversationCatalogIsCurrent,
      !operationCoordinator.isSourceAccessBlocked
    else {
      return
    }
    pendingConversationDeletion = item
    pendingConversationDeletionSourceGeneration =
      operationCoordinator.sourceStoreGenerationRevision
  }

  private func createConversation(projectID: UUID? = nil) {
    guard conversationCatalogIsCurrent,
      !operationCoordinator.isSourceAccessBlocked
    else {
      return
    }
    guard
      let choice = ExperienceStore.defaultChoice(
        projectID: projectID,
        choices: ProviderModelStore.choices(providers: providers, models: providerModels),
        values: (try? ExperienceStore.preferences(in: modelContext)) ?? [])
    else {
      navigate(to: .providers)
      return
    }
    let conversation = ConversationRecord(
      providerConfigurationID: choice.providerID, modelIdentifier: choice.modelIdentifier)
    modelContext.insert(conversation)
    do {
      if let projectID {
        _ = try ProjectBindingStore.assign(
          resourceKind: .conversation,
          resourceID: conversation.id,
          to: projectID,
          in: modelContext
        )
      }
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
      searchText = ""
      resetConversationPagination()
      loadedConversationQuery = ""
      navigate(to: .conversation(conversation.id))
    } catch {
      modelContext.rollback()
      persistenceError = error.localizedDescription
    }
  }

  @ViewBuilder
  private func projectAssignmentMenu(
    for conversation: MosaicConversationSidebarItem
  ) -> some View {
    Menu("Move to Project", systemImage: "folder") {
      ForEach(activeProjects) { project in
        Button {
          assign(conversation, to: project.id)
        } label: {
          if conversation.projectID == project.id {
            Label(project.name, systemImage: "checkmark")
          } else {
            Text(project.name)
          }
        }
      }
      if conversation.projectID != nil {
        Divider()
        Button("Remove from Project", systemImage: "folder.badge.minus") {
          assign(conversation, to: nil)
        }
      }
    }
  }

  private func assign(_ item: MosaicConversationSidebarItem, to projectID: UUID?) {
    guard conversationCatalogIsCurrent,
      !operationCoordinator.isSourceAccessBlocked,
      operationCoordinator.activeOperations.isEmpty
    else { return }
    do {
      guard try conversationRecord(id: item.id) != nil else {
        throw ProjectBindingError.invalidResource
      }
      _ = try ProjectBindingStore.assignConversation(
        conversationID: item.id,
        to: projectID,
        expected: ConversationProjectScope(
          conversationID: item.id,
          projectID: item.projectID,
          bindingID: item.projectBindingID,
          bindingUpdatedAt: item.projectBindingUpdatedAt
        ),
        in: modelContext
      )
      try operationCoordinator.saveSourceChanges(in: modelContext)
    } catch {
      modelContext.rollback()
      persistenceError = error.localizedDescription
    }
  }

  private func archive(_ item: MosaicConversationSidebarItem) {
    guard conversationCatalogIsCurrent,
      !operationCoordinator.isSourceAccessBlocked
    else {
      return
    }
    guard let conversation = try? conversationRecord(id: item.id) else {
      conversationReloadRevision &+= 1
      return
    }
    conversation.isArchived = true
    conversation.updatedAt = .now
    do {
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
      if homeConversationID == conversation.id { homeConversationID = nil }
      if selection == .conversation(conversation.id) {
        selection =
          usesCompactNavigation
          ? nil
          : conversationPages.active.items.first(where: { $0.id != conversation.id }).map {
            .conversation($0.id)
          }
      }
    } catch {
      modelContext.rollback()
      persistenceError = error.localizedDescription
    }
  }

  private func unarchive(_ item: MosaicConversationSidebarItem) {
    guard conversationCatalogIsCurrent,
      !operationCoordinator.isSourceAccessBlocked
    else {
      return
    }
    guard let conversation = try? conversationRecord(id: item.id) else {
      conversationReloadRevision &+= 1
      return
    }
    conversation.isArchived = false
    conversation.updatedAt = .now
    do {
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
    } catch {
      modelContext.rollback()
      persistenceError = error.localizedDescription
    }
  }

  private func delete(
    _ item: MosaicConversationSidebarItem,
    sourceGeneration: UInt64
  ) {
    guard deletionTask == nil,
      sourceGeneration == operationCoordinator.sourceStoreGenerationRevision,
      loadedConversationSourceGeneration == sourceGeneration,
      !operationCoordinator.isSourceAccessBlocked
    else {
      return
    }
    let operationID = MosaicOperationID.conversationDeletion(item.id)
    do {
      guard
        try operationCoordinator.beginConversationDeletion(
          conversationID: item.id,
          flushing: modelContext
        )
      else {
        persistenceError =
          "Finish active requests and data operations before deleting this conversation."
        return
      }
    } catch {
      modelContext.rollback()
      persistenceError = error.localizedDescription
      return
    }
    deletingConversation = item
    deletionCommitStarted = false
    isCancellingDeletion = false
    let sourceRepository = MosaicConversationSourceDeletionRepository(
      modelContainer: modelContext.container
    )
    let vectorRepository = MosaicConversationVectorDeletionRepository(
      modelContainer: SemanticIndexStore.shared
    )
    deletionTask = Task { @MainActor in
      defer {
        operationCoordinator.end(operationID)
        deletingConversation = nil
        deletionTask = nil
        deletionCommitStarted = false
        isCancellingDeletion = false
      }
      do {
        let result = try await MosaicConversationDeletionPipeline.delete(
          conversationID: item.id,
          sourceRepository: sourceRepository,
          vectorRepository: vectorRepository
        ) {
          try Task.checkCancellation()
          deletionCommitStarted = true
        }
        operationCoordinator.markConversationDeleted()
        if homeConversationID == item.id { homeConversationID = nil }
        if selection == .conversation(item.id) { selection = nil }
        if !result.didDeleteConversation { conversationReloadRevision &+= 1 }
        if result.didDeleteConversation {
          AccessibilityNotification.Announcement("Conversation deleted.").post()
        }
      } catch is CancellationError {
        return
      } catch {
        persistenceError = error.localizedDescription
      }
    }
  }

  private func conversationRecord(id: UUID) throws -> ConversationRecord? {
    var descriptor = FetchDescriptor<ConversationRecord>(
      predicate: #Predicate { $0.id == id }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }
}

private struct SelectedConversationDestination<Missing: View>: View {
  @Query private var conversations: [ConversationRecord]
  private let missing: Missing
  private let open: (UUID) -> Void

  init(conversationID: UUID, open: @escaping (UUID) -> Void, @ViewBuilder missing: () -> Missing) {
    self.open = open
    let selectedID = conversationID
    var descriptor = FetchDescriptor<ConversationRecord>(
      predicate: #Predicate { $0.id == selectedID }
    )
    descriptor.fetchLimit = 1
    _conversations = Query(descriptor)
    self.missing = missing()
  }

  @ViewBuilder
  var body: some View {
    if let conversation = conversations.first {
      ConversationView(conversation: conversation, openConversation: open)
        .id(conversation.id)
    } else {
      missing
    }
  }
}

private struct ConversationRow: View {
  let conversation: MosaicConversationSidebarItem
  let provider: ProviderKind?

  var body: some View {
    HStack(alignment: .center, spacing: 9) {
      if let provider {
        ProviderLogoTile(provider: provider, size: 26)
          .accessibilityHidden(true)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(conversation.title)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Text(secondaryDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .combine)
  }

  private var secondaryDescription: String {
    let relative = conversation.updatedAt.formatted(.relative(presentation: .named))
    guard let projectName = conversation.projectName else { return relative }
    return "\(projectName) · \(relative)"
  }
}

private struct WelcomeView: View {
  @State private var showsFreeOptions = false
  let hasProvider: Bool
  let newChat: () -> Void
  let showProviders: () -> Void

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        Spacer(minLength: 80)
        TuringBrandMark(size: 48)
          .accessibilityHidden(true)
        Text("How can I help?")
          .font(.largeTitle.bold())
          .multilineTextAlignment(.center)
        Text(
          hasProvider
            ? "Start a conversation with your preferred model."
            : "Connect a provider to start chatting with your favorite models."
        )
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)
        Button(action: hasProvider ? newChat : showProviders) {
          Label(hasProvider ? "New chat" : "Connect a provider", systemImage: "plus")
            .frame(minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        if !hasProvider {
          Button("Explore free options", systemImage: "gift") { showsFreeOptions = true }
            .frame(minHeight: 44)
            .accessibilityIdentifier("welcome.freeOptions")
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("Turing AI")
    .sheet(isPresented: $showsFreeOptions) { FreeProviderGuideView() }
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

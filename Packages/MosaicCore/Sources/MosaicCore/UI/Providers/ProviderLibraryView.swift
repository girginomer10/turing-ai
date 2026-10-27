import Foundation
import SwiftData
import SwiftUI

#if os(iOS)
  import UIKit
#endif

@MainActor
public struct ProviderLibraryView: View {
  @AppStorage(InterfacePreferences.advancedControlsKey) private var advancedControls = false
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Query(sort: \ProviderConfigurationRecord.updatedAt, order: .reverse)
  private var configurations: [ProviderConfigurationRecord]

  @Query private var providerModels: [ProviderModelRecord]
  @State private var choosingDefaultModel = false
  @State private var showsFreeOptions = false
  @State private var editorRoute: ProviderEditorRoute?
  @State private var pendingDeletion: ProviderConfigurationRecord?
  @State private var deletionError: String?
  @State private var credentialCleanupWarning: ProviderCredentialCleanupWarning?
  @State private var isDeleting = false

  public init() {}

  public var body: some View {
    Group {
      if configurations.isEmpty {
        ContentUnavailableView {
          VStack(spacing: 16) {
            providerLogoCluster
            Text("No Providers")
              .font(.title2.weight(.semibold))
          }
        } description: {
          Text(
            "Choose your AI service, add its API key, then start chatting. Requests are billed by that service; a chat subscription may not include API access."
          )
        } actions: {
          Button {
            editorRoute = ProviderEditorRoute(configurationID: nil)
          } label: {
            Label("Add Provider", systemImage: "plus")
          }
          .buttonStyle(.borderedProminent)
          .providerTouchTarget()
          Button("Explore free options", systemImage: "gift") { showsFreeOptions = true }
            .providerTouchTarget()
        }
      } else {
        List {
          Section {
            Button("Explore free options", systemImage: "gift") { showsFreeOptions = true }
          }
          Section {
            NavigationLink("iCloud", destination: ICloudSettingsView())
            Button("Default model for new chats") { choosingDefaultModel = true }
              .sheet(isPresented: $choosingDefaultModel) {
                ChatModelSelectionView(
                  choices: ProviderModelStore.choices(
                    providers: configurations, models: providerModels), selectedID: nil,
                  choosingProjectDefault: true
                ) { _ in }
              }
            ForEach(configurations) { configuration in
              providerRow(configuration)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                  Button(role: .destructive) {
                    pendingDeletion = configuration
                  } label: {
                    Label("Delete", systemImage: "trash")
                  }
                }
                .contextMenu {
                  Button {
                    editorRoute = ProviderEditorRoute(
                      configurationID: configuration.id
                    )
                  } label: {
                    Label("Edit Provider", systemImage: "pencil")
                  }

                  Divider()

                  Button(role: .destructive) {
                    pendingDeletion = configuration
                  } label: {
                    Label("Delete Provider", systemImage: "trash")
                  }
                }
            }
          } header: {
            Text("Connected Providers")
          } footer: {
            Label(
              "API keys stay in Apple Keychain. Requests go directly from this device to the selected provider.",
              systemImage: "checkmark.shield"
            )
          }
        }
      }
    }
    .navigationTitle(advancedControls ? "Providers" : "AI models & accounts")
    .sheet(isPresented: $showsFreeOptions) { FreeProviderGuideView() }
    .toolbar {
      ToolbarItem(id: "provider-add", placement: .primaryAction) {
        Button {
          editorRoute = ProviderEditorRoute(configurationID: nil)
        } label: {
          Label("Add Provider", systemImage: "plus")
        }
        .providerTouchTarget()
        .accessibilityHint("Opens a form for connecting an AI provider.")
      }
    }
    .sheet(item: $editorRoute) { route in
      ProviderConfigurationEditorView(
        configuration: configuration(withID: route.configurationID)
      )
    }
    .confirmationDialog(
      deletionTitle,
      isPresented: deletionConfirmationIsPresented,
      titleVisibility: .visible
    ) {
      Button("Delete Provider", role: .destructive) {
        guard let configuration = pendingDeletion else { return }
        startDeleting(configuration)
      }
      Button("Cancel", role: .cancel) {
        pendingDeletion = nil
      }
    } message: {
      Text(
        "The provider configuration and its saved API key will be removed from this device. Conversations remain available. Any unfinished memory updates for this provider will be discarded and won’t be retried."
      )
    }
    .alert("Couldn’t Delete Provider", isPresented: deletionErrorIsPresented) {
      Button("OK") { deletionError = nil }
    } message: {
      Text(deletionError ?? "Please try again.")
    }
    .alert("Provider Deleted; Key Cleanup Pending", isPresented: cleanupWarningIsPresented) {
      Button("Try Key Cleanup") {
        guard let warning = credentialCleanupWarning else { return }
        credentialCleanupWarning = nil
        retryCredentialCleanup(warning.locator)
      }
      Button("OK", role: .cancel) {
        credentialCleanupWarning = nil
      }
    } message: {
      Text(cleanupWarningMessage)
    }
    .task {
      await reconcilePendingCredentialCleanup()
    }
    .disabled(isDeleting)
  }

  @ViewBuilder
  private func providerRow(_ configuration: ProviderConfigurationRecord) -> some View {
    Button {
      editorRoute = ProviderEditorRoute(configurationID: configuration.id)
    } label: {
      Group {
        if dynamicTypeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 10) {
            rowIdentity(for: configuration)
            HStack {
              ProviderStatusBadge(isEnabled: configuration.isEnabled)
              Spacer(minLength: 8)
              Image(systemName: "chevron.forward")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            }
          }
        } else {
          HStack(spacing: 12) {
            rowIdentity(for: configuration)
            Spacer(minLength: 12)
            ProviderStatusBadge(isEnabled: configuration.isEnabled)
            Image(systemName: "chevron.forward")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.tertiary)
              .accessibilityHidden(true)
          }
        }
      }
      .contentShape(Rectangle())
      .providerListRowHeight()
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(rowAccessibilityLabel(for: configuration))
    .accessibilityHint("Opens this provider’s settings.")
  }

  private func rowIdentity(
    for configuration: ProviderConfigurationRecord
  ) -> some View {
    ProviderIdentityView(
      provider: configuration.provider,
      title: configuration.displayName,
      subtitle: enabledModelSummary(for: configuration),
      logoSize: 42
    )
  }

  private func enabledModelSummary(for configuration: ProviderConfigurationRecord) -> String {
    let count = ProviderModelStore.choices(providers: [configuration], models: providerModels).count
    return count == 1 ? "1 model enabled" : "\(count) models enabled"
  }

  private var providerLogoCluster: some View {
    HStack(spacing: -6) {
      ProviderLogoTile(provider: .openAI, size: 42)
        .rotationEffect(.degrees(-7))
      ProviderLogoTile(provider: .anthropic, size: 48)
        .zIndex(1)
      ProviderLogoTile(provider: .deepInfra, size: 42)
        .rotationEffect(.degrees(7))
    }
    .accessibilityHidden(true)
  }

  private var deletionTitle: String {
    guard let pendingDeletion else { return "Delete Provider?" }
    return "Delete \(pendingDeletion.displayName)?"
  }

  private var deletionConfirmationIsPresented: Binding<Bool> {
    Binding(
      get: { pendingDeletion != nil },
      set: { isPresented in
        if !isPresented { pendingDeletion = nil }
      }
    )
  }

  private var deletionErrorIsPresented: Binding<Bool> {
    Binding(
      get: { deletionError != nil },
      set: { isPresented in
        if !isPresented { deletionError = nil }
      }
    )
  }

  private var cleanupWarningIsPresented: Binding<Bool> {
    Binding(
      get: { credentialCleanupWarning != nil },
      set: { isPresented in
        if !isPresented { credentialCleanupWarning = nil }
      }
    )
  }

  private var cleanupWarningMessage: String {
    guard let warning = credentialCleanupWarning else {
      return "The provider is deleted, but its saved API key still needs cleanup."
    }
    return
      "The provider is deleted and can no longer use this key, but Turing AI couldn’t remove the leftover API key from Apple Keychain. Try again now, or Turing AI will retry safely on a future launch.\n\n\(warning.message)"
  }

  private func configuration(withID id: UUID?) -> ProviderConfigurationRecord? {
    guard let id else { return nil }
    return configurations.first { $0.id == id }
  }

  private func rowAccessibilityLabel(
    for configuration: ProviderConfigurationRecord
  ) -> String {
    let status = configuration.isEnabled ? "enabled" : "disabled"
    return
      "\(configuration.displayName), \(configuration.provider.displayName), \(enabledModelSummary(for: configuration)), \(status)"
  }

  private func startDeleting(_ configuration: ProviderConfigurationRecord) {
    guard !isDeleting else { return }
    let operationID = MosaicOperationID.providerMutation(configuration.id)
    guard MosaicOperationCoordinator.shared.begin(operationID) else {
      deletionError =
        "Finish active chats, automations, imports, indexing, or data recovery before deleting a provider."
      return
    }
    isDeleting = true
    Task { @MainActor in
      await delete(configuration, operationID: operationID)
    }
  }

  private func delete(
    _ configuration: ProviderConfigurationRecord,
    operationID: MosaicOperationID
  ) async {
    defer {
      MosaicOperationCoordinator.shared.end(operationID)
      isDeleting = false
      pendingDeletion = nil
    }

    do {
      try ProviderConfigurationDeletionGuard.validateCanDelete(
        configurationID: configuration.id,
        in: modelContext
      )
      // Capture the complete non-secret Keychain locator while the source row still exists. The
      // durable tombstone lets launch recovery distinguish a failed source transaction from a
      // committed deletion without ever persisting the API key.
      let locator = ProviderCredentialCleanupLocator(
        configurationID: configuration.id,
        service: SecurityKeychain.shared.service
      )
      let outcome = try await ProviderConfigurationDeletionTransaction.execute(
        locator: locator,
        commitSourceDeletion: {
          do {
            _ = try AutomaticMemoryStore.abandonRetryableJobsForProviderDeletion(
              providerConfigurationID: configuration.id,
              in: modelContext
            )
            // The provider-mutation lease blocks new provider-backed work. Recheck immediately
            // before the synchronous commit to catch any source path that bypassed that lease.
            try ProviderConfigurationDeletionGuard.validateCanDelete(
              configurationID: configuration.id,
              in: modelContext
            )
            try ProviderModelStore.records(providerID: configuration.id, in: modelContext).forEach(
              modelContext.delete)
            modelContext.delete(configuration)
            try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
          } catch {
            modelContext.rollback()
            throw error
          }
        },
        removeCredential: { locator in
          try await SecurityKeychain(service: locator.service).removeAPIKey(
            for: locator.configurationID
          )
        }
      )
      if case .deletedWithCredentialCleanupPending(let message) = outcome {
        credentialCleanupWarning = ProviderCredentialCleanupWarning(
          locator: locator,
          message: message
        )
      }
    } catch {
      deletionError = ProviderErrorPresenter.message(for: error)
    }
  }

  private func reconcilePendingCredentialCleanup() async {
    let operationCoordinator = MosaicOperationCoordinator.shared
    guard
      !operationCoordinator.isSourceAccessBlocked,
      !operationCoordinator.activeOperations.contains(where: {
        if case .providerMutation = $0 { return true }
        return false
      })
    else { return }

    let failures = await ProviderConfigurationDeletionTransaction.reconcile(
      existingProviderIDs: Set(configurations.map(\.id)),
      removeCredential: { locator in
        try await SecurityKeychain(service: locator.service).removeAPIKey(
          for: locator.configurationID
        )
      }
    )
    if let failure = failures.first {
      credentialCleanupWarning = ProviderCredentialCleanupWarning(
        locator: failure.locator,
        message: failure.message
      )
    }
  }

  private func retryCredentialCleanup(_ locator: ProviderCredentialCleanupLocator) {
    guard !isDeleting else { return }
    let operationID = MosaicOperationID.providerMutation(locator.configurationID)
    guard MosaicOperationCoordinator.shared.begin(operationID) else {
      credentialCleanupWarning = ProviderCredentialCleanupWarning(
        locator: locator,
        message: "Finish the current Turing AI operation, then try Keychain cleanup again."
      )
      return
    }
    isDeleting = true
    Task { @MainActor in
      defer {
        MosaicOperationCoordinator.shared.end(operationID)
        isDeleting = false
      }
      do {
        let providerID = locator.configurationID
        let liveProviderCount = try modelContext.fetchCount(
          FetchDescriptor<ProviderConfigurationRecord>(
            predicate: #Predicate { $0.id == providerID }
          )
        )
        guard liveProviderCount == 0 else {
          // A backup restore may have brought this exact provider back in another window. In that
          // case the tombstone describes an uncommitted deletion and the key must be preserved.
          ProviderCredentialCleanupTombstoneStore.shared.discard(locator)
          return
        }
        try await SecurityKeychain(service: locator.service).removeAPIKey(
          for: locator.configurationID
        )
        ProviderCredentialCleanupTombstoneStore.shared.discard(locator)
      } catch {
        credentialCleanupWarning = ProviderCredentialCleanupWarning(
          locator: locator,
          message: ProviderErrorPresenter.message(for: error)
        )
      }
    }
  }
}

private struct ProviderEditorRoute: Identifiable {
  let id = UUID()
  let configurationID: UUID?
}

private struct ProviderCredentialCleanupWarning {
  let locator: ProviderCredentialCleanupLocator
  let message: String
}

private struct ProviderStatusBadge: View {
  let isEnabled: Bool

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: isEnabled ? "checkmark.circle.fill" : "pause.circle.fill")
        .foregroundStyle(isEnabled ? Color.green : Color.secondary)
      Text(isEnabled ? "Enabled" : "Disabled")
        .foregroundStyle(.primary)
    }
    .font(.caption.weight(.medium))
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(.secondary.opacity(0.09), in: Capsule())
    .accessibilityLabel(isEnabled ? "Provider enabled" : "Provider disabled")
  }
}

private struct ProviderKindSelectionView: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var selection: ProviderKind
  @State private var searchText = ""

  var body: some View {
    List {
      ForEach(ProviderCategory.allCases) { category in
        let providers = matchingProviders(in: category)
        if !providers.isEmpty {
          Section(category.displayName) {
            ForEach(providers) { provider in
              Button {
                selection = provider
                dismiss()
              } label: {
                HStack(spacing: 12) {
                  ProviderIdentityView(
                    provider: provider,
                    subtitle: provider.serviceSummary,
                    logoSize: 36
                  )
                  Spacer(minLength: 8)
                  if provider == selection {
                    Image(systemName: "checkmark")
                      .font(.body.weight(.semibold))
                      .foregroundStyle(.tint)
                      .accessibilityHidden(true)
                  }
                }
                .contentShape(Rectangle())
                .providerListRowHeight()
              }
              .buttonStyle(.plain)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(
                "\(provider.displayName), \(provider.serviceSummary)"
              )
              .accessibilityValue(provider == selection ? "Selected" : "")
              .accessibilityHint("Selects this provider.")
            }
          }
        }
      }
    }
    .overlay {
      if matchingProviderCount == 0 {
        ContentUnavailableView.search(text: searchText)
      }
    }
    .navigationTitle("Choose Provider")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .searchable(text: $searchText, prompt: "Search providers")
  }

  private var normalizedSearchText: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var matchingProviderCount: Int {
    ProviderCategory.allCases.reduce(0) { count, category in
      count + matchingProviders(in: category).count
    }
  }

  private func matchingProviders(in category: ProviderCategory) -> [ProviderKind] {
    let providers = ProviderKind.cases(in: category)
    guard !normalizedSearchText.isEmpty else { return providers }

    return providers.filter { provider in
      [
        provider.displayName,
        provider.serviceSummary,
        category.displayName,
      ].contains { value in
        value.localizedCaseInsensitiveContains(normalizedSearchText)
      }
    }
  }
}

private struct ProviderCapabilityBadge: View {
  let title: String
  let systemImage: String

  var body: some View {
    Label(title, systemImage: systemImage)
      .labelStyle(.titleAndIcon)
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      .background(.secondary.opacity(0.09), in: Capsule())
  }
}

/// Keeps capability labels readable at their natural width and moves whole
/// badges to the next line when a compact device cannot fit them side by side.
private struct ProviderCapabilityFlowLayout: Layout {
  let spacing: CGFloat

  init(spacing: CGFloat = 8) {
    self.spacing = spacing
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    let maximumWidth = proposal.width ?? .infinity
    var lineWidth: CGFloat = 0
    var lineHeight: CGFloat = 0
    var totalHeight: CGFloat = 0
    var measuredWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      let nextWidth = lineWidth == 0 ? size.width : lineWidth + spacing + size.width

      if lineWidth > 0, nextWidth > maximumWidth {
        measuredWidth = max(measuredWidth, lineWidth)
        totalHeight += lineHeight + spacing
        lineWidth = size.width
        lineHeight = size.height
      } else {
        lineWidth = nextWidth
        lineHeight = max(lineHeight, size.height)
      }
    }

    measuredWidth = max(measuredWidth, lineWidth)
    totalHeight += lineHeight
    return CGSize(width: measuredWidth, height: totalHeight)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    var origin = bounds.origin
    var lineHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if origin.x > bounds.minX, origin.x + size.width > bounds.maxX {
        origin.x = bounds.minX
        origin.y += lineHeight + spacing
        lineHeight = 0
      }

      subview.place(
        at: origin,
        anchor: .topLeading,
        proposal: ProposedViewSize(size)
      )
      origin.x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
  }
}

enum ProviderConfigurationDisplayNamePolicy {
  static func usesCustomName(for provider: ProviderKind) -> Bool {
    provider == .custom
  }

  static func resolvedName(
    for provider: ProviderKind,
    enteredName: String,
    existingProvider: ProviderKind? = nil,
    existingName: String? = nil
  ) -> String {
    if usesCustomName(for: provider) {
      return enteredName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if existingProvider == provider,
      let existingName = existingName?.trimmingCharacters(in: .whitespacesAndNewlines),
      !existingName.isEmpty
    {
      return existingName
    }

    return provider.displayName
  }
}

@MainActor
struct ProviderConfigurationEditorView: View {
  @AppStorage(InterfacePreferences.advancedControlsKey) private var advancedControls = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  private let configuration: ProviderConfigurationRecord?
  private let configurationID: UUID

  @State private var displayName: String
  @State private var provider: ProviderKind
  @State private var modelIdentifier: String
  @State private var contextWindowTokensText: String
  @State private var maximumOutputTokensText: String
  @State private var baseURLString: String
  @State private var apiKey = ""
  @State private var isEnabled: Bool
  @State private var storedCredentialState: StoredCredentialState
  @State private var discoveredModels: [String] = []
  @State private var savedModelIdentifiers: [String] = []
  @State private var enabledModelIdentifiers: Set<String>
  @State private var catalogLoaded = false
  @State private var modelLimitDrafts: [String: ProviderModelLimitsDraft] = [:]
  @State private var connectionState: ConnectionState = .idle
  @State private var connectionTestGate = ProviderConnectionTestGate()
  @State private var connectionTask: Task<Void, Never>?
  @State private var isSaving = false
  @State private var isRemovingCredential = false
  @State private var errorMessage: String?
  @State private var showRemoveCredentialConfirmation = false

  init(configuration: ProviderConfigurationRecord?, suggestion: FreeProviderOption? = nil) {
    self.configuration = configuration

    let initialProvider = configuration?.provider ?? suggestion?.provider ?? .openAI
    let id = configuration?.id ?? UUID()
    let initialModelIdentifier =
      configuration?.modelIdentifier ?? suggestion?.modelID
      ?? initialProvider.defaultModelIdentifier
    let initialModelLimits = ProviderModelMetadataRegistry.defaultLimits(
      for: initialProvider,
      modelIdentifier: initialModelIdentifier
    )
    configurationID = id
    _displayName = State(initialValue: configuration?.displayName ?? initialProvider.displayName)
    _provider = State(initialValue: initialProvider)
    _modelIdentifier = State(initialValue: initialModelIdentifier)
    _enabledModelIdentifiers = State(
      initialValue: initialModelIdentifier.isEmpty ? [] : [initialModelIdentifier])
    _contextWindowTokensText = State(
      initialValue: String(
        configuration?.contextWindowTokens ?? initialModelLimits.contextWindowTokens
      )
    )
    _maximumOutputTokensText = State(
      initialValue: String(
        configuration?.maximumOutputTokens ?? initialModelLimits.maximumOutputTokens
      )
    )
    _baseURLString = State(
      initialValue: configuration?.baseURL?.absoluteString
        ?? initialProvider.defaultBaseURL?.absoluteString
        ?? ""
    )
    _isEnabled = State(initialValue: configuration?.isEnabled ?? true)
    _storedCredentialState = State(
      initialValue: configuration == nil ? .absent : .loading
    )
  }

  var body: some View {
    NavigationStack {
      Form {
        if advancedControls { editorHeader }
        if configuration == nil && !advancedControls {
          Section("Start chatting") {
            Text(
              "1. Choose your AI service below.\n2. Add your API key.\n3. Save, then choose a model in your chat."
            )
            Text(
              "Your key stays in Apple Keychain. Messages go directly to your selected service, which may charge for API use."
            )
            .font(.footnote).foregroundStyle(.secondary)
          }
        }
        identitySection
        connectionSection
        if provider.supportsChat {
          modelSection
        } else {
          Section("Embedding models") {
            Text(
              "Choose embedding models in Memory → Embedding Models after saving this connection."
            )
            .foregroundStyle(.secondary)
          }
        }

      }
      .formStyle(.grouped)
      .scrollDismissesKeyboard(.interactively)
      .disabled(isSaving)
      .navigationTitle(configuration == nil ? "Add Provider" : "Edit Provider")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isSaving)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            save()
          }
          .disabled(!canSave)
        }

      }
    }
    .providerEditorFrame()
    .interactiveDismissDisabled(isSaving)
    .task(id: configurationID) {
      do {
        let models = try ProviderModelStore.records(providerID: configurationID, in: modelContext)
        savedModelIdentifiers = models.map(\.modelIdentifier)
        if !models.isEmpty {
          enabledModelIdentifiers = Set(models.filter(\.isEnabled).map(\.modelIdentifier))
          modelLimitDrafts = Dictionary(
            uniqueKeysWithValues: models.map {
              (
                $0.modelIdentifier,
                ProviderModelLimitsDraft(
                  contextWindow: $0.contextWindowTokens, maximumOutput: $0.maximumOutputTokens)
              )
            })
        } else if let configuration {
          modelLimitDrafts[configuration.modelIdentifier] = ProviderModelLimitsDraft(
            contextWindow: configuration.contextWindowTokens,
            maximumOutput: configuration.maximumOutputTokens)
        }
        catalogLoaded = true
      } catch { errorMessage = error.localizedDescription }
      await loadStoredCredentialState()
    }
    .onChange(of: provider) { oldProvider, newProvider in
      applyDefaultsAfterProviderChange(from: oldProvider, to: newProvider)
    }
    .onChange(of: modelIdentifier) { oldIdentifier, newIdentifier in
      applyDefaultsAfterModelChange(from: oldIdentifier, to: newIdentifier)
    }
    .onChange(of: enabledModelIdentifiers) { _, identifiers in
      if modelIdentifierTrimmed.isEmpty,
        let first = identifiers.filter({ !$0.isEmpty }).sorted().first
      {
        modelIdentifier = first
      }
    }
    .onChange(of: baseURLString) { _, _ in
      invalidateConnectionTest()
    }
    .onChange(of: apiKey) { _, _ in
      invalidateConnectionTest()
    }
    .onDisappear {
      connectionTestGate.invalidate()
      connectionTask?.cancel()
      connectionTask = nil
      apiKey = ""
    }
    .confirmationDialog(
      "Remove Saved API Key?",
      isPresented: $showRemoveCredentialConfirmation,
      titleVisibility: .visible
    ) {
      Button("Remove API Key", role: .destructive) {
        startRemovingStoredCredential()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(removeCredentialMessage)
    }
    .alert("Couldn’t Complete Action", isPresented: errorIsPresented) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "Please try again.")
    }
  }

  private var editorHeader: some View {
    Section {
      VStack(alignment: .leading, spacing: 14) {
        ProviderIdentityView(
          provider: provider,
          title: editorIdentityTitle,
          subtitle: provider.serviceSummary,
          logoSize: 52
        )

        ProviderCapabilityFlowLayout(spacing: 8) {
          providerCapabilityBadges
        }
      }
      .padding(.vertical, 6)
    }
  }

  @ViewBuilder
  private var providerCapabilityBadges: some View {
    if provider.supportsChat {
      ProviderCapabilityBadge(title: "Chat", systemImage: "message")
    }
    if provider.supportsEmbeddings {
      ProviderCapabilityBadge(title: "Embeddings", systemImage: "square.stack.3d.up")
    }
    if provider.supportsLiveTranscription {
      ProviderCapabilityBadge(title: "Live Transcript", systemImage: "waveform.badge.mic")
    }
    ProviderCapabilityBadge(
      title: provider.requiresAPIKey ? "API key" : "Key optional",
      systemImage: provider.requiresAPIKey ? "key" : "network"
    )
  }

  private var editorIdentityTitle: String {
    if configuration == nil { return "Connect \(provider.displayName)" }
    return resolvedDisplayName.isEmpty ? provider.displayName : resolvedDisplayName
  }

  private var identitySection: some View {
    Section("Provider") {
      NavigationLink {
        ProviderKindSelectionView(selection: $provider)
      } label: {
        HStack(spacing: 10) {
          Text("Provider type")
          Spacer(minLength: 12)
          ProviderLogoTile(provider: provider, size: 24)
          Text(provider.displayName)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Provider type, \(provider.displayName)")
      .accessibilityHint("Opens a searchable list of providers.")

      if ProviderConfigurationDisplayNamePolicy.usesCustomName(for: provider) {
        TextField("Display name", text: $displayName)

        if displayNameTrimmed.isEmpty {
          Label("Enter a display name.", systemImage: "exclamationmark.circle")
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }

      Toggle("Enabled", isOn: $isEnabled)
    }
  }

  private var connectionSection: some View {
    Section {
      if advancedControls || provider.defaultBaseURL == nil
        || ProviderConfigurationDisplayNamePolicy.usesCustomName(for: provider)
        || ["localhost", "127.0.0.1", "::1"].contains(provider.defaultBaseURL?.host ?? "")
        || endpointIssue != nil
      {
        TextField("Base URL", text: $baseURLString)
          .providerURLInputTraits()
          .accessibilityHint("Include http or https and any API path prefix, such as slash v1.")
      } else {
        LabeledContent("Service address") {
          Text(baseURLString).font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      SecureField("API key", text: $apiKey)
        .providerSecretInputTraits()
        .privacySensitive()
        .accessibilityHint(apiKeyAccessibilityHint)

      credentialStatus

      if storedCredentialState.canRemove {
        Button(role: .destructive) {
          showRemoveCredentialConfirmation = true
        } label: {
          Label("Remove Saved API Key", systemImage: "key.slash")
        }
        .disabled(isSaving || isRemovingCredential)
        .providerTouchTarget()
      }

      if showsPhysicalIPhoneLoopbackWarning {
        Label {
          Text(
            "On a physical iPhone, localhost and 127.0.0.1 refer to the iPhone itself. To reach a server on your Mac, use the Mac’s local network address and allow the server to accept local connections."
          )
        } icon: {
          Image(systemName: "iphone")
        }
        .font(.footnote)
        .foregroundStyle(.orange)
        .accessibilityLabel(
          "Local address warning. On a physical iPhone, localhost and 127.0.0.1 refer to the iPhone itself. Use the Mac’s local network address to reach a server on your Mac."
        )
      }

      if let endpointIssue {
        Label(endpointIssue, systemImage: "exclamationmark.triangle.fill")
          .font(.footnote)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Connection")
    } footer: {
      Text(connectionFooter)
    }
  }

  @ViewBuilder
  private var credentialStatus: some View {
    switch storedCredentialState {
    case .loading:
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Checking Keychain…")
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    case .present:
      if credentialDestinationChanged {
        Label(
          "A key is saved for the previous provider destination. It won’t be sent to this destination. Enter a replacement, or the old key will be removed when you save.",
          systemImage: "key.slash"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      } else {
        Label(
          "An API key is saved in Keychain. Leave the field empty to keep it.",
          systemImage: "checkmark.shield"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    case .absent:
      if provider.requiresAPIKey && apiKeyTrimmed.isEmpty {
        Label("An API key is required for this provider.", systemImage: "key")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.footnote)
        .foregroundStyle(.red)
    }
  }

  private var modelSection: some View {
    Section {
      NavigationLink {
        ProviderModelsView(
          provider: provider, identifiers: availableModelIdentifiers,
          enabled: $enabledModelIdentifiers, customIdentifiers: $savedModelIdentifiers,
          limits: $modelLimitDrafts,
          canRefresh: canTestConnection, isRefreshing: connectionState.isTesting,
          refresh: startConnectionTest, refreshStatus: connectionStatus)
      } label: {
        LabeledContent("Manage Models", value: "\(enabledModelIdentifiers.count) enabled")
      }
      .accessibilityHint("Enable or disable models for conversations and tasks")

      if provider.supportsModelDiscovery {
        Button {
          startConnectionTest()
        } label: {
          HStack(spacing: 10) {
            if connectionState.isTesting {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "arrow.clockwise")
            }
            Text(modelCatalogLoadButtonTitle)
          }
        }
        .disabled(!canTestConnection)
        .providerTouchTarget()
        .accessibilityHint(connectionTestAccessibilityHint)

        connectionStatus
      }

      if modelIdentifierTrimmed.isEmpty {
        Label("Enter or choose a model ID.", systemImage: "exclamationmark.circle")
          .font(.footnote)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Models")
    } footer: {
      if !advancedControls {
        Text(
          "Choose which models appear in your chats. Suggested models may need separate account access; loading a catalog does not guarantee access to every model."
        )
      } else if connectionTestUsesUnauthenticatedPublicCatalog, discoveredModels.isEmpty {
        Text(
          "Suggested models are starting points. Check the public catalog to load its current model IDs, or enter an exact ID. This does not verify your API key or access to the selected model."
        )
      } else if provider.supportsModelDiscovery, discoveredModels.isEmpty {
        Text(
          "Suggested models are starting points. Load models to see the current IDs available to this account without sending a paid prompt, or enter any exact model ID."
        )
      } else if connectionTestUsesUnauthenticatedPublicCatalog {
        Text(
          "Enable publicly listed models or add an exact model ID. Access is verified only when you make a model request."
        )
      } else if provider.supportsModelDiscovery {
        Text(
          "Enable models listed for this account, use Turing AI suggestions, or add an exact model ID. Suggested models can still require account access."
        )
      } else {
        Text(
          "This provider does not publish a compatible live catalog here. Enable suggestions or add an exact model ID from its current documentation."
        )
      }
    }
  }

  private var availableModelIdentifiers: [String] {
    ProviderModelOptionCatalog.merge(
      suggested: provider.suggestedModelIdentifiers,
      discovered: discoveredModels + savedModelIdentifiers,
      selected: modelIdentifierTrimmed
    )
  }

  @ViewBuilder
  private var connectionStatus: some View {
    switch connectionState {
    case .idle, .testing:
      EmptyView()
    case .success(let message):
      Label(message, systemImage: "checkmark.circle.fill")
        .font(.footnote)
        .foregroundStyle(.green)
        .accessibilityLabel(connectionTestSuccessAccessibilityLabel(message: message))
    case .failure(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.footnote)
        .foregroundStyle(.red)
        .accessibilityLabel("Connection test failed. \(message)")
    }
  }

  private var canSave: Bool {
    !isSaving && catalogLoaded && formValidationIssue == nil
  }

  private var canTestConnection: Bool {
    provider.supportsModelDiscovery && !connectionState.isTesting
      && connectionTestValidationIssue == nil
  }

  private var formValidationIssue: String? {
    if ProviderConfigurationDisplayNamePolicy.usesCustomName(for: provider),
      displayNameTrimmed.isEmpty
    {
      return "Enter a display name."
    }
    if modelIdentifierTrimmed.isEmpty { return "Enter or choose a model ID." }
    if provider.supportsChat {
      for (identifier, limits) in modelLimitDrafts {
        let defaults = ProviderModelMetadataRegistry.defaultLimits(
          for: provider, modelIdentifier: identifier)
        if let issue = ProviderRequestLimitPolicy.validationIssue(
          contextWindowTokens: limits.contextWindow ?? defaults.contextWindowTokens,
          maximumOutputTokens: limits.maximumOutput ?? defaults.maximumOutputTokens)
        {
          return "\(identifier): \(issue)"
        }
      }
    }
    return formValidationIssueExcludingModel
  }

  private var formValidationIssueExcludingModel: String? {
    if let endpointIssue { return endpointIssue }
    return credentialIssue
  }

  private var connectionTestValidationIssue: String? {
    if let endpointIssue { return endpointIssue }
    if connectionTestUsesUnauthenticatedPublicCatalog { return nil }
    return credentialIssue
  }

  private var credentialIssue: String? {
    if provider.requiresAPIKey, apiKeyTrimmed.isEmpty {
      if credentialDestinationChanged {
        return "Enter an API key for \(provider.displayName)."
      } else {
        switch storedCredentialState {
        case .present:
          break
        case .loading:
          return "Wait while Turing AI checks Keychain."
        case .absent:
          return "Enter an API key."
        case .failed(let message):
          return message
        }
      }
    }
    return nil
  }

  private var connectionTestUsesUnauthenticatedPublicCatalog: Bool {
    guard provider == .aimlAPI else { return false }
    do {
      return ProviderConnectionTestSemantics.usesUnauthenticatedPublicCatalog(
        for: draftProviderSnapshot(baseURL: try resolvedBaseURL())
      )
    } catch {
      return false
    }
  }

  private var modelCatalogLoadButtonTitle: String {
    if connectionTestUsesUnauthenticatedPublicCatalog {
      return connectionState.isTesting ? "Loading Public Models…" : "Load Public Models"
    }
    return connectionState.isTesting ? "Loading Account Models…" : "Load Models from Account"
  }

  private var connectionTestAccessibilityHint: String {
    if connectionTestUsesUnauthenticatedPublicCatalog {
      return
        "Checks AI/ML API’s public model catalog without sending the API key. The key and selected model are not verified."
    }
    return "Checks the provider’s model catalog without sending a prompt."
  }

  private func connectionTestSuccessAccessibilityLabel(message: String) -> String {
    connectionTestUsesUnauthenticatedPublicCatalog
      ? "Public catalog check succeeded. \(message)"
      : "Connection test succeeded. \(message)"
  }

  private var endpointIssue: String? {
    do {
      _ = try resolvedBaseURL()
      return nil
    } catch {
      return ProviderErrorPresenter.message(for: error)
    }
  }

  private var displayNameTrimmed: String {
    displayName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var resolvedDisplayName: String {
    ProviderConfigurationDisplayNamePolicy.resolvedName(
      for: provider,
      enteredName: displayName,
      existingProvider: configuration?.provider,
      existingName: configuration?.displayName
    )
  }

  private var modelIdentifierTrimmed: String {
    modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var contextWindowTokensValue: Int? {
    Int(contextWindowTokensText.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private var maximumOutputTokensValue: Int? {
    Int(maximumOutputTokensText.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private var apiKeyTrimmed: String {
    apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var connectionFooter: String {
    if provider == .microsoftFoundry {
      return
        "Paste the resource endpoint ending in /openai/v1 and use the deployment name as the model ID. The API key is stored only in Apple Keychain."
    }
    if provider == .amazonBedrock {
      return
        "Paste the regional AWS Bedrock OpenAI-compatible endpoint ending in /openai/v1 and use a Bedrock API key. The key is stored only in Apple Keychain."
    }
    if provider == .tinfoil {
      return
        "This preset uses Tinfoil’s direct HTTPS-compatible API. Enclave attestation verification through Tinfoil’s SDK is not integrated yet. The key is stored only in Apple Keychain."
    }
    if provider == .google {
      return
        "The key is stored only in Apple Keychain. Gemini Live Transcript uses the same personal key to open a direct, temporary WebSocket to Google’s official Gemini origin; Turing AI never logs that URL."
    }
    if provider.requiresAPIKey {
      return
        "The key is stored only in Apple Keychain. Remote addresses must use HTTPS; HTTP is limited to local network addresses."
    }
    return
      "An API key is optional for \(provider.displayName). Remote addresses must use HTTPS; HTTP is limited to local network addresses."
  }

  private var apiKeyAccessibilityHint: String {
    if storedCredentialState.isPresent, credentialDestinationChanged {
      return
        "The saved key belongs to the previous provider and will not be reused. Enter a new key for this provider."
    }
    if storedCredentialState.isPresent {
      return "A key is already saved. Leave this field empty to keep it, or enter a replacement."
    }
    return provider.requiresAPIKey
      ? "Required. The key is saved in Apple Keychain."
      : "Optional. If entered, the key is saved in Apple Keychain."
  }

  private var removeCredentialMessage: String {
    if provider.requiresAPIKey {
      return
        "This provider will stop working until you save a new key. The provider configuration will remain."
    }
    return
      "The saved key will be removed. This provider can continue working if its server does not require authentication."
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { isPresented in
        if !isPresented { errorMessage = nil }
      }
    )
  }

  private var showsPhysicalIPhoneLoopbackWarning: Bool {
    #if os(iOS) && !targetEnvironment(simulator)
      let explicitURL: URL?
      do {
        explicitURL = try resolvedBaseURL()
      } catch {
        return false
      }
      guard UIDevice.current.userInterfaceIdiom == .phone,
        let effectiveURL = explicitURL ?? provider.defaultBaseURL,
        let host = effectiveURL.host?.lowercased()
      else {
        return false
      }
      return host == "localhost" || host == "127.0.0.1" || host == "::1"
    #else
      return false
    #endif
  }

  private func loadStoredCredentialState() async {
    guard let configuration else {
      storedCredentialState = .absent
      return
    }
    do {
      let snapshot = ProviderConnection(configuration: configuration)
      let key = try await SecurityKeychain.shared.apiKey(
        for: configurationID,
        expectedBinding: snapshot.credentialBinding
      )
      storedCredentialState = key?.isEmpty == false ? .present : .absent
    } catch {
      storedCredentialState = .failed(ProviderErrorPresenter.message(for: error))
    }
  }

  private func applyDefaultsAfterProviderChange(
    from oldProvider: ProviderKind,
    to newProvider: ProviderKind
  ) {
    invalidateConnectionTest()
    if displayNameTrimmed.isEmpty || displayName == oldProvider.displayName {
      displayName = newProvider.displayName
    }

    // Endpoint, model, and limits form one provider-specific destination. Carrying any of them
    // across a provider-type change can silently route a newly entered credential to the prior
    // custom host or use an incompatible model. Reset the complete destination and let the user
    // explicitly re-enter any intentional proxy configuration.
    let modelIdentifier = newProvider.defaultModelIdentifier
    let modelLimits = ProviderModelMetadataRegistry.defaultLimits(
      for: newProvider,
      modelIdentifier: modelIdentifier
    )
    self.modelIdentifier = modelIdentifier
    savedModelIdentifiers = []
    enabledModelIdentifiers = modelIdentifier.isEmpty ? [] : [modelIdentifier]
    modelLimitDrafts = [:]
    contextWindowTokensText = String(modelLimits.contextWindowTokens)
    maximumOutputTokensText = String(modelLimits.maximumOutputTokens)
    baseURLString = newProvider.defaultBaseURL?.absoluteString ?? ""

    apiKey = ""
  }

  private func applyDefaultsAfterModelChange(
    from oldIdentifier: String,
    to newIdentifier: String
  ) {
    guard provider.supportsChat,
      let contextWindowTokensValue,
      let maximumOutputTokensValue
    else { return }

    let updated = ProviderModelMetadataRegistry.limitsAfterModelChange(
      current: ProviderModelRequestLimits(
        contextWindowTokens: contextWindowTokensValue,
        maximumOutputTokens: maximumOutputTokensValue
      ),
      provider: provider,
      previousModelIdentifier: oldIdentifier,
      newModelIdentifier: newIdentifier
    )
    if updated.contextWindowTokens != contextWindowTokensValue {
      contextWindowTokensText = String(updated.contextWindowTokens)
    }
    if updated.maximumOutputTokens != maximumOutputTokensValue {
      maximumOutputTokensText = String(updated.maximumOutputTokens)
    }
  }

  private func resolvedBaseURL() throws -> URL? {
    let value = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty {
      guard provider.defaultBaseURL != nil else {
        throw ProviderClientError.invalidEndpoint
      }
      return nil
    }

    guard let components = URLComponents(string: value),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      scheme == "https" || scheme == "http",
      !host.isEmpty,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      let url = components.url
    else {
      throw ProviderClientError.invalidEndpoint
    }

    try ProviderWireProtocol.validate(baseURL: url)
    return url
  }

  private func credentialForRequest(
    snapshot: ProviderConnection,
    enteredKey: String,
    destinationChanged: Bool
  ) async throws -> String? {
    if !enteredKey.isEmpty { return enteredKey }
    if destinationChanged { return nil }
    if !snapshot.provider.requiresAPIKey, !storedCredentialState.isPresent { return nil }
    return try await SecurityKeychain.shared.apiKey(
      for: configurationID,
      expectedBinding: snapshot.credentialBinding
    )
  }

  private func startConnectionTest() {
    connectionTestGate.invalidate()
    connectionTask?.cancel()

    let requestID = connectionTestGate.begin()
    connectionState = .testing
    connectionTask = Task { await testConnection(requestID: requestID) }
  }

  private func invalidateConnectionTest() {
    connectionTestGate.invalidate()
    connectionTask?.cancel()
    connectionTask = nil
    connectionState = .idle
    discoveredModels = []
  }

  private func testConnection(requestID: UUID) async {
    guard connectionTestGate.accepts(requestID) else { return }
    var requestKey = ""
    defer {
      requestKey = ""
      if connectionTestGate.finish(requestID) {
        connectionTask = nil
      }
    }

    guard provider.supportsModelDiscovery else {
      connectionState = .failure(
        ProviderClientError.modelCatalogUnavailable.localizedDescription
      )
      return
    }

    do {
      let snapshot = try draftProviderSnapshot(baseURL: resolvedBaseURL())
      let usesUnauthenticatedPublicCatalog =
        ProviderConnectionTestSemantics.usesUnauthenticatedPublicCatalog(for: snapshot)
      let key =
        usesUnauthenticatedPublicCatalog
        ? nil
        : try await credentialForRequest(
          snapshot: snapshot,
          enteredKey: apiKeyTrimmed,
          destinationChanged: credentialDestinationChanged
        )
      requestKey = key ?? ""
      try Task.checkCancellation()

      let connection = snapshot.authenticated(with: key)
      let models = try await ProviderClientFactory.make(connection: connection).listModels()
      try Task.checkCancellation()
      guard connectionTestGate.accepts(requestID) else { return }

      discoveredModels = Array(Set(models)).sorted()
      if modelIdentifierTrimmed.isEmpty, let first = discoveredModels.first {
        modelIdentifier = first
      }
      connectionState = .success(
        ProviderConnectionTestSemantics.successMessage(
          modelCount: discoveredModels.count,
          usesUnauthenticatedPublicCatalog: usesUnauthenticatedPublicCatalog
        )
      )
    } catch is CancellationError {
      guard connectionTestGate.accepts(requestID) else { return }
      connectionState = .idle
    } catch let error as URLError where error.code == .cancelled {
      guard connectionTestGate.accepts(requestID) else { return }
      connectionState = .idle
    } catch {
      guard !Task.isCancelled, connectionTestGate.accepts(requestID) else { return }
      connectionState = .failure(
        ProviderErrorPresenter.message(for: error, redacting: requestKey)
      )
    }
  }

  private func save() {
    if let formValidationIssue {
      errorMessage = formValidationIssue
      return
    }
    guard !isSaving else { return }
    let operationID = MosaicOperationID.providerMutation(configurationID)
    guard MosaicOperationCoordinator.shared.begin(operationID) else {
      errorMessage = "Wait for data recovery to finish before saving a provider."
      return
    }
    isSaving = true
    Task { @MainActor in
      await persistConfiguration(operationID: operationID)
    }
  }

  private func draftProviderSnapshot(baseURL: URL?) -> ProviderConnection {
    ProviderConnection(
      id: configurationID,
      displayName: resolvedDisplayName,
      provider: provider,
      baseURL: baseURL,
      modelIdentifier: modelIdentifierTrimmed,
      contextWindowTokens: contextWindowTokensValue,
      maximumOutputTokens: maximumOutputTokensValue
    )
  }

  private func persistConfiguration(operationID: MosaicOperationID) async {
    defer {
      MosaicOperationCoordinator.shared.end(operationID)
      isSaving = false
    }

    let newKey = apiKeyTrimmed.isEmpty ? nil : apiKeyTrimmed

    do {
      let resolvedURL = try resolvedBaseURL()
      let draftSnapshot = draftProviderSnapshot(baseURL: resolvedURL)
      let destinationChanged = credentialDestinationChanged
      let credentialChanged = newKey != nil || destinationChanged
      let previousCredential =
        credentialChanged
        ? try await SecurityKeychain.shared.credentialSnapshot(for: configurationID)
        : nil

      if draftSnapshot.provider.requiresAPIKey, newKey == nil {
        guard !destinationChanged else { throw ProviderClientError.missingAPIKey }
        let savedKey = try await SecurityKeychain.shared.apiKey(
          for: configurationID,
          expectedBinding: draftSnapshot.credentialBinding
        )
        guard savedKey != nil else { throw ProviderClientError.missingAPIKey }
      }

      if let newKey {
        try await SecurityKeychain.shared.setAPIKey(
          newKey,
          for: configurationID,
          binding: draftSnapshot.credentialBinding
        )
      } else if destinationChanged {
        try await SecurityKeychain.shared.removeAPIKey(for: configurationID)
      }

      if let configuration {
        let previousValues = ProviderRecordValues(configuration: configuration)
        do {
          applyDraft(to: configuration, baseURL: resolvedURL)
          try saveModelCatalog(for: configuration, reset: destinationChanged)
          try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
        } catch {
          modelContext.rollback()
          previousValues.restore(configuration)
          try await restoreCredential(
            previousCredential,
            ifChanged: credentialChanged
          )
          throw error
        }
      } else {
        let record = ProviderConfigurationRecord(
          id: configurationID,
          displayName: resolvedDisplayName,
          provider: provider,
          modelIdentifier: modelIdentifierTrimmed,
          baseURL: resolvedURL,
          contextWindowTokens: contextWindowTokensValue,
          maximumOutputTokens: maximumOutputTokensValue,
          isEnabled: isEnabled
        )
        modelContext.insert(record)
        do {
          try saveModelCatalog(for: record, reset: false)
          try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
        } catch {
          modelContext.rollback()
          try await restoreCredential(
            previousCredential,
            ifChanged: credentialChanged
          )
          throw error
        }
      }

      apiKey = ""
      dismiss()
    } catch {
      errorMessage = ProviderErrorPresenter.message(for: error, redacting: apiKeyTrimmed)
    }
  }

  private func saveModelCatalog(for record: ProviderConfigurationRecord, reset: Bool) throws {
    guard provider.supportsChat else { return }
    try ProviderModelStore.saveCatalog(
      provider: record,
      identifiers: BundledProviderModelCatalog.identifiersToPersist(
        provider: provider, available: availableModelIdentifiers, enabled: enabledModelIdentifiers,
        saved: savedModelIdentifiers, customized: Array(modelLimitDrafts.keys),
        legacy: modelIdentifierTrimmed),
      enabled: enabledModelIdentifiers, reset: reset, in: modelContext)
    for model in try ProviderModelStore.records(providerID: record.id, in: modelContext) {
      if let limits = modelLimitDrafts[model.modelIdentifier] {
        model.contextWindowTokens = limits.contextWindow
        model.maximumOutputTokens = limits.maximumOutput
      }
    }
  }

  private func applyDraft(
    to configuration: ProviderConfigurationRecord,
    baseURL: URL?
  ) {
    configuration.displayName = resolvedDisplayName
    configuration.provider = provider
    configuration.modelIdentifier = modelIdentifierTrimmed
    configuration.baseURL = baseURL
    configuration.contextWindowTokens = contextWindowTokensValue
    configuration.maximumOutputTokens = maximumOutputTokensValue
    configuration.isEnabled = isEnabled
    configuration.updatedAt = .now
  }

  private func restoreCredential(
    _ snapshot: ProviderCredentialSnapshot?,
    ifChanged credentialChanged: Bool
  ) async throws {
    guard credentialChanged, let snapshot else { return }
    try await SecurityKeychain.shared.restoreCredentialSnapshot(
      snapshot,
      for: configurationID
    )
  }

  private func startRemovingStoredCredential() {
    guard !isRemovingCredential else { return }
    let operationID = MosaicOperationID.providerMutation(configurationID)
    guard MosaicOperationCoordinator.shared.begin(operationID) else {
      errorMessage = "Wait for data recovery to finish before removing this API key."
      return
    }
    isRemovingCredential = true
    Task { @MainActor in
      await removeStoredCredential(operationID: operationID)
    }
  }

  private func removeStoredCredential(operationID: MosaicOperationID) async {
    defer {
      MosaicOperationCoordinator.shared.end(operationID)
      isRemovingCredential = false
    }

    do {
      try await SecurityKeychain.shared.removeAPIKey(for: configurationID)
      storedCredentialState = .absent
      connectionState = .idle
      discoveredModels = []
    } catch {
      errorMessage = ProviderErrorPresenter.message(for: error)
    }
  }

  private var credentialDestinationChanged: Bool {
    guard let configuration else { return false }
    do {
      let previousBinding = ProviderConnection(configuration: configuration).credentialBinding
      let currentBinding = draftProviderSnapshot(
        baseURL: try resolvedBaseURL()
      ).credentialBinding
      return previousBinding != currentBinding
    } catch {
      return true
    }
  }
}

private struct ProviderRecordValues {
  let displayName: String
  let provider: ProviderKind
  let modelIdentifier: String
  let baseURL: URL?
  let contextWindowTokens: Int?
  let maximumOutputTokens: Int?
  let isEnabled: Bool
  let updatedAt: Date

  init(configuration: ProviderConfigurationRecord) {
    displayName = configuration.displayName
    provider = configuration.provider
    modelIdentifier = configuration.modelIdentifier
    baseURL = configuration.baseURL
    contextWindowTokens = configuration.contextWindowTokens
    maximumOutputTokens = configuration.maximumOutputTokens
    isEnabled = configuration.isEnabled
    updatedAt = configuration.updatedAt
  }

  func restore(_ configuration: ProviderConfigurationRecord) {
    configuration.displayName = displayName
    configuration.provider = provider
    configuration.modelIdentifier = modelIdentifier
    configuration.baseURL = baseURL
    configuration.contextWindowTokens = contextWindowTokens
    configuration.maximumOutputTokens = maximumOutputTokens
    configuration.isEnabled = isEnabled
    configuration.updatedAt = updatedAt
  }
}

private enum StoredCredentialState {
  case loading
  case present
  case absent
  case failed(String)

  var isPresent: Bool {
    if case .present = self { return true }
    return false
  }

  var canRemove: Bool {
    switch self {
    case .present, .failed:
      true
    case .loading, .absent:
      false
    }
  }
}

private enum ConnectionState {
  case idle
  case testing
  case success(String)
  case failure(String)

  var isTesting: Bool {
    if case .testing = self { return true }
    return false
  }
}

struct ProviderConnectionTestGate: Equatable, Sendable {
  private(set) var activeRequestID: UUID?

  init(activeRequestID: UUID? = nil) {
    self.activeRequestID = activeRequestID
  }

  mutating func begin(id: UUID = UUID()) -> UUID {
    activeRequestID = id
    return id
  }

  mutating func invalidate() {
    activeRequestID = nil
  }

  func accepts(_ requestID: UUID) -> Bool {
    activeRequestID == requestID
  }

  @discardableResult
  mutating func finish(_ requestID: UUID) -> Bool {
    guard accepts(requestID) else { return false }
    activeRequestID = nil
    return true
  }
}

enum ProviderConnectionTestSemantics {
  static func usesUnauthenticatedPublicCatalog(for connection: ProviderConnection) -> Bool {
    guard connection.provider == .aimlAPI else { return false }
    return
      (try? ProviderWireProtocol.modelsRequest(
        connection: connection.authenticated(with: nil)
      )) != nil
  }

  static func successMessage(
    modelCount: Int,
    usesUnauthenticatedPublicCatalog: Bool
  ) -> String {
    let modelNoun = modelCount == 1 ? "model" : "models"
    if usesUnauthenticatedPublicCatalog {
      guard modelCount > 0 else {
        return
          "Public model catalog is reachable, but it returned no models. The API key was not sent or verified; enter a model ID manually."
      }
      return
        "Public model catalog is reachable. Found \(modelCount) \(modelNoun). The API key was not sent or verified."
    }

    guard modelCount > 0 else {
      return "Connected, but the provider returned no models. Enter a model ID manually."
    }
    return "Connected. Found \(modelCount) \(modelNoun)."
  }
}

private enum ProviderErrorPresenter {
  static func message(for error: Error, redacting secret: String = "") -> String {
    let message: String
    switch error {
    case ProviderClientError.invalidEndpoint:
      message =
        "Enter a complete base URL beginning with https://, or use http:// only for a local network address. URLs cannot contain credentials, a query, or a fragment."
    case ProviderClientError.insecureEndpoint:
      message =
        "For your security, a remote provider must use https://. Plain http:// is allowed only for localhost or a private local network address."
    case ProviderClientError.missingAPIKey:
      message = "Enter an API key for this provider. It will be stored in Apple Keychain."
    case ProviderClientError.missingModelIdentifier:
      message = "Enter or choose a model ID."
    case ProviderClientError.invalidResponse:
      message =
        "The provider responded, but Turing AI could not read its model list. You can still enter a model ID manually."
    case ProviderClientError.chatUnavailable:
      message = "This provider is configured for embeddings and cannot send chat messages."
    case ProviderClientError.modelCatalogUnavailable:
      message =
        "This provider does not publish a compatible model catalog. Enter an exact model ID instead."
    case ProviderClientError.httpStatus(let status, let providerMessage):
      message = httpMessage(status: status, providerMessage: providerMessage)
    case ProviderClientError.provider(let providerMessage):
      message = limited(providerMessage)
    case let urlError as URLError:
      message = urlErrorMessage(urlError)
    default:
      message = limited(error.localizedDescription)
    }

    guard !secret.isEmpty else { return message }
    return message.replacingOccurrences(of: secret, with: "••••")
  }

  private static func httpMessage(status: Int, providerMessage: String) -> String {
    switch status {
    case 401:
      return "The provider rejected the API key (HTTP 401). Check the key and try again."
    case 402:
      return
        "The provider requires billing or available credit before it can complete this request (HTTP 402)."
    case 403:
      return "The API key does not have permission to list models (HTTP 403)."
    case 404:
      return
        "The provider does not expose a model catalog at this address (HTTP 404). Enter the model ID manually, or check the base URL."
    case 429:
      return "The provider is rate limiting requests (HTTP 429). Wait a moment and try again."
    case 500...599:
      return "The provider is temporarily unavailable (HTTP \(status)). Try again later."
    default:
      let detail = limited(providerMessage)
      return detail.isEmpty ? "The provider returned HTTP \(status)." : detail
    }
  }

  private static func urlErrorMessage(_ error: URLError) -> String {
    switch error.code {
    case .timedOut:
      return "The connection timed out. Check the provider address and try again."
    case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
      return
        "Turing AI could not reach the provider. Check the address, make sure the server is running, and verify local network access when using a server on your Mac."
    case .notConnectedToInternet, .networkConnectionLost:
      return "The network connection is unavailable. Reconnect and try again."
    case .secureConnectionFailed, .serverCertificateUntrusted,
      .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
      return
        "Turing AI could not establish a secure TLS connection. Check the provider’s HTTPS certificate."
    case .cancelled:
      return "The connection test was cancelled."
    default:
      return limited(error.localizedDescription)
    }
  }

  private static func limited(_ value: String) -> String {
    let collapsed =
      value
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(collapsed.prefix(400))
  }
}

extension View {
  @ViewBuilder
  fileprivate func providerTouchTarget() -> some View {
    #if os(iOS)
      frame(minWidth: 44, minHeight: 44)
    #else
      frame(minWidth: 28, minHeight: 28)
    #endif
  }

  @ViewBuilder
  fileprivate func providerListRowHeight() -> some View {
    #if os(iOS)
      frame(minHeight: 56)
    #else
      frame(minHeight: 48)
    #endif
  }

  @ViewBuilder
  fileprivate func providerEditorFrame() -> some View {
    #if os(macOS)
      frame(minWidth: 540, idealWidth: 620, minHeight: 580, idealHeight: 680)
    #else
      self
    #endif
  }

  @ViewBuilder
  fileprivate func providerURLInputTraits() -> some View {
    #if os(iOS)
      textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
    #else
      autocorrectionDisabled()
    #endif
  }

  @ViewBuilder
  fileprivate func providerSecretInputTraits() -> some View {
    #if os(iOS)
      textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    #else
      autocorrectionDisabled()
    #endif
  }

  @ViewBuilder
  fileprivate func providerIdentifierInputTraits() -> some View {
    #if os(iOS)
      textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    #else
      autocorrectionDisabled()
    #endif
  }

  @ViewBuilder
  fileprivate func providerNumberInputTraits() -> some View {
    #if os(iOS)
      keyboardType(.numberPad)
    #else
      self
    #endif
  }
}

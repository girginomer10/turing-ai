import SwiftData
import SwiftUI

@MainActor
private enum EmbeddingProfileActivationPolicy {
  static let maximumEnabledProfiles = 4
  static let limitDescription =
    "Turing AI can use up to four embedding models at once. Disable another model before enabling this one."

  static func canEnable(
    profileID: UUID?,
    among profiles: [EmbeddingProfileRecord]
  ) -> Bool {
    profiles.lazy.filter { $0.id != profileID && $0.isEnabled }.count
      < maximumEnabledProfiles
  }
}

@MainActor
struct EmbeddingProfilesView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \EmbeddingProfileRecord.updatedAt, order: .reverse)
  private var profiles: [EmbeddingProfileRecord]
  @Query(sort: \ProviderConfigurationRecord.updatedAt, order: .reverse)
  private var providers: [ProviderConfigurationRecord]

  @State private var editingProfile: EmbeddingProfileRecord?
  @State private var isAdding = false
  @State private var pendingDeletion: EmbeddingProfileRecord?
  @State private var errorMessage: String?
  @State private var isIndexingDocuments = false
  @State private var indexingStatus: String?
  @State private var indexingStatusKind: DocumentIndexStatusKind = .success
  @State private var indexHealth: SemanticDocumentIndexHealth?
  @State private var indexHealthError: String?
  @State private var indexHealthRefreshID = UUID()

  var body: some View {
    NavigationStack {
      List {
        Section {
          Label {
            VStack(alignment: .leading, spacing: 4) {
              Text("Local hybrid index")
                .font(.headline)
              Text("Always available · Turkish-aware lexical and character retrieval")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "internaldrive")
              .foregroundStyle(.tint)
          }
        } header: {
          Text("Built in")
        } footer: {
          Text(
            "This fallback runs entirely on the device and keeps recall working when an embedding model is offline."
          )
        }

        Section {
          if profiles.isEmpty {
            ContentUnavailableView {
              Label("No embedding models", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
              Text(
                compatibleProviders.isEmpty
                  ? "Add and enable an embedding-capable connection in Providers first."
                  : "Add EmbeddingGemma, Arctic, Qwen, or another compatible model to improve semantic recall."
              )
            } actions: {
              if !compatibleProviders.isEmpty {
                Button("Add Embedding Model") { isAdding = true }
                  .buttonStyle(.borderedProminent)
                  .disabled(isIndexingDocuments)
              }
            }
          } else {
            ForEach(profiles) { profile in
              profileRow(profile)
                .deleteDisabled(isIndexingDocuments)
            }
            .onDelete(perform: deleteProfiles)
          }
        } header: {
          Text("Embedding ensemble")
        } footer: {
          Text(
            "Up to four enabled models run in parallel. Turing AI keeps vector spaces separate and combines rankings, so you can mix a local Qwen model with DeepInfra or Tinfoil. Enabling a profile sends the current query and its selected chat or document excerpts to that connection; remote calls may incur usage charges."
          )
        }

        RerankerSettingsSection(providers: rerankProviders)

        Section {
          documentIndexHealthContent

          Button(action: rebuildDocuments) {
            Label("Rebuild All Document Vectors", systemImage: "arrow.triangle.2.circlepath")
          }
          .disabled(!canRebuildDocuments)

          if isIndexingDocuments {
            HStack(spacing: 10) {
              ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Indexing enabled documents")
              Text("Indexing enabled documents…")
            }
          } else if let indexingStatus {
            Label(indexingStatus, systemImage: indexingStatusKind.systemImage)
              .font(.footnote)
              .foregroundStyle(indexingStatusKind.color)
          }
        } header: {
          Text("Document index health")
        } footer: {
          Text(
            "Rebuild clears document vectors for the active embedding models, then regenerates every enabled document. Source text and local lexical recall remain available if a provider fails; remote models may incur usage charges."
          )
        }
      }
      .navigationTitle("Embedding Models")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            isAdding = true
          } label: {
            Label("Add Embedding Model", systemImage: "plus")
          }
          .disabled(compatibleProviders.isEmpty)
          .disabled(isIndexingDocuments)
        }
      }
      .sheet(isPresented: $isAdding) {
        EmbeddingProfileEditor(
          profile: nil,
          providers: compatibleProviders,
          onSaved: backfillDocuments
        )
      }
      .sheet(item: $editingProfile) { profile in
        EmbeddingProfileEditor(
          profile: profile,
          providers: compatibleProviders,
          onSaved: backfillDocuments
        )
      }
      .confirmationDialog(
        "Delete this embedding model?",
        isPresented: deletionDialogIsPresented,
        titleVisibility: .visible,
        presenting: pendingDeletion
      ) { profile in
        Button("Delete Model", role: .destructive) { delete(profile) }
          .disabled(isIndexingDocuments)
        Button("Cancel", role: .cancel) {}
      } message: { profile in
        Text("Cached vectors for \(profile.displayName) will also be removed.")
      }
      .alert("Embedding models couldn’t be updated", isPresented: errorIsPresented) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "Please try again.")
      }
      .task {
        await refreshIndexHealth()
      }
    }
    #if os(macOS)
      .frame(minWidth: 500, minHeight: 540)
    #endif
  }

  private var compatibleProviders: [ProviderConfigurationRecord] {
    providers.filter { $0.isEnabled && $0.provider.supportsEmbeddings }
  }

  private var rerankProviders: [ProviderConfigurationRecord] {
    providers.filter { $0.isEnabled && $0.provider.supportsReranking }
  }

  private var canRebuildDocuments: Bool {
    guard !isIndexingDocuments, let indexHealth else { return false }
    return indexHealth.orphanVectorCount > 0
      || (indexHealth.chunkCount > 0
        && indexHealth.profiles.contains { $0.availability == .available })
  }

  @ViewBuilder
  private var documentIndexHealthContent: some View {
    if let indexHealth {
      LabeledContent("Enabled documents", value: indexHealth.enabledDocumentCount.formatted())
      LabeledContent("Text chunks", value: indexHealth.chunkCount.formatted())
      LabeledContent("Stored vectors", value: indexHealth.storedVectorCount.formatted())
      LabeledContent {
        Text(
          "\(indexHealth.validVectorCount.formatted()) / \(indexHealth.expectedVectorCount.formatted())"
        )
        .foregroundStyle(indexHealth.needsAttention ? .orange : .secondary)
      } label: {
        Text("Current vectors")
      }

      if indexHealth.profiles.isEmpty {
        Label(
          "Enable an embedding model for imported documents to add vector recall.",
          systemImage: "info.circle"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      } else {
        ForEach(indexHealth.profiles) { profile in
          documentProfileHealthRow(profile, documentCount: indexHealth.enabledDocumentCount)
        }
      }

      if indexHealth.orphanVectorCount > 0 {
        Label(
          "\(indexHealth.orphanVectorCount.formatted()) orphaned document vectors can be removed by rebuilding.",
          systemImage: "exclamationmark.triangle"
        )
        .font(.footnote)
        .foregroundStyle(.orange)
      }
      if indexHealth.isTemporary {
        Label(
          "The persistent vector cache is unavailable. This index lasts only for the current session.",
          systemImage: "externaldrive.badge.exclamationmark"
        )
        .font(.footnote)
        .foregroundStyle(.orange)
      }
    } else if let indexHealthError {
      Label(indexHealthError, systemImage: "exclamationmark.triangle")
        .font(.footnote)
        .foregroundStyle(.orange)
    } else {
      HStack(spacing: 10) {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Checking document vector health")
        Text("Checking document vectors…")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func documentProfileHealthRow(
    _ profile: SemanticDocumentProfileHealth,
    documentCount: Int
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(profile.displayName)
          .font(.subheadline.weight(.semibold))
        Spacer()
        Label(profileAvailabilityText(profile), systemImage: profileAvailabilityIcon(profile))
          .font(.caption)
          .foregroundStyle(profile.needsAttention ? .orange : .green)
      }
      ProgressView(
        value: Double(profile.validVectorCount),
        total: Double(max(profile.expectedVectorCount, 1))
      )
      .accessibilityLabel("\(profile.displayName) document vector coverage")
      .accessibilityValue(
        "\(profile.validVectorCount.formatted()) of \(profile.expectedVectorCount.formatted()) current"
      )
      Text(
        "\(profile.indexedDocumentCount.formatted()) / \(documentCount.formatted()) documents · \(profile.validVectorCount.formatted()) / \(profile.expectedVectorCount.formatted()) current vectors"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      if profile.missingVectorCount > 0 || profile.staleVectorCount > 0 {
        Text(
          "\(profile.missingVectorCount.formatted()) missing · \(profile.staleVectorCount.formatted()) stale"
        )
        .font(.caption2)
        .foregroundStyle(.orange)
      }
    }
    .padding(.vertical, 3)
  }

  private func profileAvailabilityText(_ profile: SemanticDocumentProfileHealth) -> String {
    switch profile.availability {
    case .available:
      profile.needsAttention ? "Needs repair" : "Ready"
    case .providerUnavailable:
      "Provider unavailable"
    case .profileLimitExceeded:
      "Outside four-model limit"
    }
  }

  private func profileAvailabilityIcon(_ profile: SemanticDocumentProfileHealth) -> String {
    profile.needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
  }

  @ViewBuilder
  private func profileRow(_ profile: EmbeddingProfileRecord) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Button {
        editingProfile = profile
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          Text(profile.displayName)
            .font(.headline)
            .foregroundStyle(.primary)
          Text(profile.modelIdentifier)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text(profileDescription(profile))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isIndexingDocuments)

      Toggle(
        "Enabled",
        isOn: Binding(
          get: { profile.isEnabled },
          set: { enabled in
            if enabled,
              !EmbeddingProfileActivationPolicy.canEnable(
                profileID: profile.id,
                among: profiles
              )
            {
              errorMessage = EmbeddingProfileActivationPolicy.limitDescription
              return
            }
            profile.isEnabled = enabled
            profile.updatedAt = .now
            saveChanges()
            if enabled { backfillDocuments() }
          }
        )
      )
      .labelsHidden()
      .accessibilityLabel("Use \(profile.displayName)")
      .disabled(isIndexingDocuments)
    }
    .padding(.vertical, 4)
    .contextMenu {
      Button("Edit", systemImage: "pencil") { editingProfile = profile }
        .disabled(isIndexingDocuments)
      Button("Delete", systemImage: "trash", role: .destructive) {
        pendingDeletion = profile
      }
      .disabled(isIndexingDocuments)
    }
  }

  private func profileDescription(_ profile: EmbeddingProfileRecord) -> String {
    let provider = providers.first { $0.id == profile.providerConfigurationID }
    var parts = [provider?.displayName ?? "Missing provider"]
    if profile.indexesConversations { parts.append("chats") }
    if profile.indexesDocuments { parts.append("documents") }
    parts.append("weight \(profile.weight.formatted(.number.precision(.fractionLength(2))))")
    return parts.joined(separator: " · ")
  }

  private var deletionDialogIsPresented: Binding<Bool> {
    Binding(
      get: { pendingDeletion != nil },
      set: { if !$0 { pendingDeletion = nil } }
    )
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private func deleteProfiles(at offsets: IndexSet) {
    guard !isIndexingDocuments else { return }
    guard let offset = offsets.first, profiles.indices.contains(offset) else { return }
    pendingDeletion = profiles[offset]
  }

  private func delete(_ profile: EmbeddingProfileRecord) {
    guard !isIndexingDocuments else { return }
    let profileID = profile.id
    let operationID = MosaicOperationID.embeddingProfileDeletion(profileID)
    guard MosaicOperationCoordinator.shared.begin(operationID) else {
      errorMessage =
        "Finish the current request or data operation before deleting this embedding model."
      return
    }
    isIndexingDocuments = true
    Task { @MainActor in
      defer {
        isIndexingDocuments = false
        MosaicOperationCoordinator.shared.end(operationID)
      }
      do {
        modelContext.delete(profile)
        try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
        pendingDeletion = nil
        do {
          try await SemanticDocumentIndexPipeline.deleteVectors(
            profileID: profileID,
            vectorContainer: SemanticIndexStore.shared
          )
        } catch {
          errorMessage =
            "The embedding model was deleted, but its rebuildable vector cache could not be cleared completely. Rebuild the document index to clean it up. \(error.localizedDescription)"
        }
        scheduleIndexHealthRefresh()
      } catch {
        modelContext.rollback()
        pendingDeletion = nil
        errorMessage = "The embedding model could not be deleted: \(error.localizedDescription)"
      }
    }
  }

  private func saveChanges() {
    do {
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
      scheduleIndexHealthRefresh()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }

  private func backfillDocuments() {
    guard !isIndexingDocuments else { return }
    if let indexHealth, indexHealth.enabledDocumentCount == 0 {
      indexingStatus = "No enabled documents need indexing."
      indexingStatusKind = .success
      scheduleIndexHealthRefresh()
      return
    }
    let operationID = MosaicOperationID.semanticIndexing(UUID())
    guard MosaicOperationCoordinator.shared.begin(operationID) else {
      indexingStatus = "Wait for data recovery to finish before indexing documents."
      indexingStatusKind = .warning
      return
    }
    isIndexingDocuments = true
    indexingStatus = nil
    Task { @MainActor in
      defer { MosaicOperationCoordinator.shared.end(operationID) }
      let warnings = await SemanticDocumentIndexer.indexAllEnabledDocuments(in: modelContext)
      isIndexingDocuments = false
      await refreshIndexHealth()
      if warnings.isEmpty {
        indexingStatusKind = .success
        indexingStatus = indexCompletionMessage
      } else {
        indexingStatusKind = .warning
        indexingStatus = warnings.joined(separator: " ")
      }
    }
  }

  private func rebuildDocuments() {
    guard !isIndexingDocuments else { return }
    let operationID = MosaicOperationID.semanticIndexing(UUID())
    guard MosaicOperationCoordinator.shared.begin(operationID) else {
      indexingStatus = "Wait for data recovery to finish before rebuilding the index."
      indexingStatusKind = .warning
      return
    }
    isIndexingDocuments = true
    indexingStatus = nil
    Task { @MainActor in
      defer { MosaicOperationCoordinator.shared.end(operationID) }
      do {
        let warnings = try await SemanticDocumentIndexer.rebuildAllEnabledDocuments(
          in: modelContext
        )
        await refreshIndexHealth()
        if warnings.isEmpty {
          indexingStatusKind = .success
          indexingStatus = indexCompletionMessage
        } else {
          indexingStatusKind = .warning
          indexingStatus = warnings.joined(separator: " ")
        }
      } catch {
        await refreshIndexHealth()
        indexingStatusKind = .failure
        let details = error.localizedDescription
        indexingStatus =
          details.localizedCaseInsensitiveContains("lexical recall")
          ? "Rebuild failed: \(details)"
          : "Rebuild failed: \(details) Local lexical recall remains available."
      }
      isIndexingDocuments = false
    }
  }

  private var indexCompletionMessage: String {
    guard let indexHealth else {
      return "Document indexing finished."
    }
    if indexHealth.expectedVectorCount == 0 {
      return "Document indexing finished; no document vectors are required."
    }
    return
      "\(indexHealth.validVectorCount.formatted()) of \(indexHealth.expectedVectorCount.formatted()) document vectors are current."
  }

  private func scheduleIndexHealthRefresh() {
    Task { @MainActor in await refreshIndexHealth() }
  }

  private func refreshIndexHealth() async {
    let refreshID = UUID()
    indexHealthRefreshID = refreshID
    do {
      let health = try await SemanticDocumentIndexer.health(in: modelContext)
      guard indexHealthRefreshID == refreshID else { return }
      indexHealth = health
      indexHealthError = nil
    } catch {
      guard indexHealthRefreshID == refreshID else { return }
      indexHealth = nil
      indexHealthError =
        "Document index health could not be read. Local lexical recall remains available."
    }
  }
}

private enum DocumentIndexStatusKind {
  case success
  case warning
  case failure

  var systemImage: String {
    switch self {
    case .success: "checkmark.circle"
    case .warning: "exclamationmark.triangle"
    case .failure: "xmark.octagon"
    }
  }

  var color: Color {
    switch self {
    case .success: .secondary
    case .warning: .orange
    case .failure: .red
    }
  }
}

struct EmbeddingProfileProviderSelection: Equatable, Sendable {
  let displayName: String
  let modelIdentifier: String

  static func resolvingChange(
    currentDisplayName: String,
    currentModelIdentifier: String,
    previousProviderID: UUID?,
    previousProviderKind: ProviderKind?,
    newProviderDisplayName: String,
    newProviderKind: ProviderKind
  ) -> Self {
    let providerKindChanged =
      previousProviderID != nil && previousProviderKind != newProviderKind
    let previousDefault = previousProviderKind?.defaultEmbeddingModelIdentifier
    let nextDefault = newProviderKind.defaultEmbeddingModelIdentifier ?? ""
    let resolvedModelIdentifier =
      if providerKindChanged
        || currentModelIdentifier.isEmpty
        || currentModelIdentifier == previousDefault
      {
        nextDefault
      } else {
        currentModelIdentifier
      }
    let resolvedDisplayName =
      if currentDisplayName.isEmpty || currentDisplayName.hasSuffix(" Embeddings") {
        "\(newProviderDisplayName) Embeddings"
      } else {
        currentDisplayName
      }
    return Self(
      displayName: resolvedDisplayName,
      modelIdentifier: resolvedModelIdentifier
    )
  }
}

@MainActor
private struct EmbeddingProfileEditor: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Query private var profiles: [EmbeddingProfileRecord]

  let profile: EmbeddingProfileRecord?
  let providers: [ProviderConfigurationRecord]
  let onSaved: () -> Void

  @State private var displayName: String
  @State private var providerID: UUID?
  @State private var modelIdentifier: String
  @State private var weight: Double
  @State private var isEnabled: Bool
  @State private var indexesConversations: Bool
  @State private var indexesDocuments: Bool
  @State private var errorMessage: String?

  init(
    profile: EmbeddingProfileRecord?,
    providers: [ProviderConfigurationRecord],
    onSaved: @escaping () -> Void
  ) {
    self.profile = profile
    self.providers = providers
    self.onSaved = onSaved
    let initialProviderID = profile?.providerConfigurationID ?? providers.first?.id
    let initialProvider = providers.first { $0.id == initialProviderID }
    _displayName = State(
      initialValue: profile?.displayName
        ?? initialProvider.map { "\($0.displayName) Embeddings" }
        ?? "Embedding Model"
    )
    _providerID = State(initialValue: initialProviderID)
    _modelIdentifier = State(
      initialValue: profile?.modelIdentifier
        ?? initialProvider?.provider.defaultEmbeddingModelIdentifier
        ?? ""
    )
    _weight = State(initialValue: profile?.weight ?? 1)
    _isEnabled = State(initialValue: profile?.isEnabled ?? true)
    _indexesConversations = State(initialValue: profile?.indexesConversations ?? true)
    _indexesDocuments = State(initialValue: profile?.indexesDocuments ?? true)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Model") {
          TextField("Name", text: $displayName)
          Picker("Provider connection", selection: $providerID) {
            Text("Choose a provider").tag(UUID?.none)
            ForEach(providers) { provider in
              Text("\(provider.displayName) · \(provider.provider.displayName)")
                .tag(Optional(provider.id))
            }
          }
          TextField("Embedding model ID", text: $modelIdentifier)
            .textInputAutocapitalizationNeverWhenAvailable()
            .disableAutocorrection(true)
          if let kind = selectedProvider?.provider,
            let models = BundledProviderModelCatalog.entry(for: kind)?.embeddingModels,
            !models.isEmpty
          {
            Menu("Choose a suggested model") {
              ForEach(models, id: \.self) { identifier in
                Button(identifier) { modelIdentifier = identifier }
              }
            }
          }
        }

        Section {
          Toggle("Previous conversations", isOn: $indexesConversations)
          Toggle("Imported documents", isOn: $indexesDocuments)
          Toggle("Enabled", isOn: $isEnabled)
        } header: {
          Text("Sources")
        } footer: {
          Text("At least one source must be enabled.")
        }

        Section {
          Slider(value: $weight, in: 0.25...2, step: 0.25)
          LabeledContent("Ensemble weight") {
            Text(weight.formatted(.number.precision(.fractionLength(2))))
          }
        } footer: {
          Text("Higher weight gives this model more influence when rankings are combined.")
        }

        if let provider = selectedProvider {
          Section("Suggested setup") {
            Text(suggestion(for: provider.provider))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(profile == nil ? "Add Embedding Model" : "Edit Embedding Model")
      .onChange(of: providerID) { oldID, newID in
        guard oldID != newID, let provider = selectedProvider else { return }
        let previousProviderKind = providers.first { $0.id == oldID }?.provider
        let selection = EmbeddingProfileProviderSelection.resolvingChange(
          currentDisplayName: displayName,
          currentModelIdentifier: modelIdentifier,
          previousProviderID: oldID,
          previousProviderKind: previousProviderKind,
          newProviderDisplayName: provider.displayName,
          newProviderKind: provider.provider
        )
        displayName = selection.displayName
        modelIdentifier = selection.modelIdentifier
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: save)
            .disabled(!canSave)
        }
      }
      .alert("Embedding model couldn’t be saved", isPresented: errorIsPresented) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "Please try again.")
      }
    }
    #if os(macOS)
      .frame(minWidth: 460, minHeight: 520)
    #endif
  }

  private var selectedProvider: ProviderConfigurationRecord? {
    providers.first { $0.id == providerID }
  }

  private var canSave: Bool {
    !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && providerID != nil
      && !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (indexesConversations || indexesDocuments)
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private func suggestion(for kind: ProviderKind) -> String {
    switch kind {
    case .tinfoil:
      "Tinfoil exposes nomic-embed-text here through direct HTTPS. Turing AI does not yet verify enclave attestation with Tinfoil’s SDK."
    case .ollama, .lmStudio, .localAI, .vLLM, .sglang, .llamaCpp, .jan:
      "Enter a model installed in this runtime, such as embeddinggemma. Each model keeps an independent vector space."
    default:
      if let suggestedModel = kind.defaultEmbeddingModelIdentifier {
        "Start with \(suggestedModel), or enter any compatible embedding model ID available to this connection."
      } else {
        "Enter an embedding model ID supported by this provider connection."
      }
    }
  }

  private func save() {
    guard canSave else { return }
    guard
      !isEnabled
        || EmbeddingProfileActivationPolicy.canEnable(
          profileID: profile?.id,
          among: profiles
        )
    else {
      errorMessage = EmbeddingProfileActivationPolicy.limitDescription
      return
    }
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let model = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    if let profile {
      profile.displayName = name
      profile.backend = .provider
      profile.providerConfigurationID = providerID
      profile.modelIdentifier = model
      profile.weight = weight
      profile.isEnabled = isEnabled
      profile.indexesConversations = indexesConversations
      profile.indexesDocuments = indexesDocuments
      profile.updatedAt = .now
    } else {
      modelContext.insert(
        EmbeddingProfileRecord(
          displayName: name,
          providerConfigurationID: providerID,
          modelIdentifier: model,
          weight: weight,
          isEnabled: isEnabled,
          indexesConversations: indexesConversations,
          indexesDocuments: indexesDocuments
        )
      )
    }
    do {
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
      onSaved()
      dismiss()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }
}

extension View {
  @ViewBuilder
  fileprivate func textInputAutocapitalizationNeverWhenAvailable() -> some View {
    #if os(iOS)
      textInputAutocapitalization(.never)
    #else
      self
    #endif
  }
}

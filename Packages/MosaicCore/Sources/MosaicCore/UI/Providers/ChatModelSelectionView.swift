import SwiftData
import SwiftUI

struct ChatModelSelectionView: View {
  @AppStorage(InterfacePreferences.advancedControlsKey) private var advancedControls = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Query(
    filter: #Predicate<ExperienceRecord> {
      $0.category == "model" || $0.category == "projectDefault"
    }) private
    var experienceRecords: [ExperienceRecord]
  let choices: [ChatModelChoice]
  let selectedID: String?
  var defaultProjectID: UUID? = nil
  var choosingProjectDefault = false
  var privateMode = false
  let onSelect: (ChatModelChoice) -> Void
  @State private var search = ""
  @State private var imagesOnly = false
  @State private var errorMessage: String?

  private var preferences: [ExperienceValue] {
    experienceRecords.compactMap {
      try? JSONDecoder().decode(ExperienceValue.self, from: $0.payload)
    }.filter { $0.kind != .attachment }
  }
  private func preference(_ choice: ChatModelChoice) -> ExperienceValue {
    preferences.first { $0.kind == .model && $0.selectionKey == choice.id } ?? .preference(choice)
  }
  private var filtered: [ChatModelChoice] {
    choices.filter {
      (!imagesOnly || ModelImageCapability.supports($0, preference: preference($0)))
        && (search.isEmpty || $0.modelIdentifier.localizedCaseInsensitiveContains(search)
          || $0.providerName.localizedCaseInsensitiveContains(search))
    }
  }
  private var favorites: [ChatModelChoice] { filtered.filter { preference($0).favorite } }
  private var recent: [ChatModelChoice] {
    filtered.filter { !preference($0).favorite && preference($0).lastUsed != nil }
      .sorted { preference($0).lastUsed! > preference($1).lastUsed! }.prefix(5).map { $0 }
  }
  private var others: [ChatModelChoice] {
    let shown = Set((favorites + recent).map(\.id))
    return filtered.filter { !shown.contains($0.id) }
  }
  var body: some View {
    NavigationStack {
      List {
        if choosingProjectDefault {
          Section {
            Button(defaultProjectID == nil ? "Use the most recently used model" : "Use app default")
            {
              guard !MosaicOperationCoordinator.shared.isSourceAccessBlocked else { return }
              do {
                try ExperienceStore.remove(
                  ExperienceValue.modelID("default:" + (defaultProjectID?.uuidString ?? "global")),
                  in: modelContext)
                try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
                dismiss()
              } catch {
                modelContext.rollback()
                errorMessage = error.localizedDescription
              }
            }
          }
        }
        Section { Toggle("Supports photos", isOn: $imagesOnly) }
        if !favorites.isEmpty { Section("Favorites") { rows(favorites) } }
        if !recent.isEmpty { Section("Recently used") { rows(recent) } }
        if !others.isEmpty { Section("All models") { rows(others) } }
        if filtered.isEmpty {
          ContentUnavailableView(
            "No matching models", systemImage: "magnifyingglass",
            description: Text("Enable models in Providers, or adjust your search."))
        }
      }
      .searchable(text: $search, prompt: "Search models or providers")
      .navigationTitle(choosingProjectDefault ? "Default Model" : "Choose Model")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
      .alert(
        "Couldn’t save preference",
        isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "")
      }
    }
    #if os(macOS)
      .frame(minWidth: 420, idealWidth: 500, minHeight: 450)
    #endif
  }
  private func rows(_ items: [ChatModelChoice]) -> some View {
    ForEach(items) { choice in
      HStack(spacing: 12) {
        Button {
          var value = preference(choice)
          value.lastUsed = .now
          guard privateMode || persist(value) else { return }
          if choosingProjectDefault {
            let scope = defaultProjectID?.uuidString ?? "global"
            guard
              persist(
                ExperienceValue(
                  id: ExperienceValue.modelID("default:" + scope), kind: .projectDefault,
                  providerID: choice.providerID, model: choice.modelIdentifier,
                  projectID: defaultProjectID))
            else { return }
          }
          onSelect(choice)
          dismiss()
        } label: {
          HStack(spacing: 12) {
            ProviderLogoTile(provider: choice.providerKind, size: 28)
            VStack(alignment: .leading, spacing: 4) {
              Text(choice.modelIdentifier).foregroundStyle(.primary)
              Text(choice.providerName).font(.caption).foregroundStyle(.secondary)
              if ModelImageCapability.supports(choice, preference: preference(choice)) {
                Label("Photos", systemImage: "photo").font(.caption2).foregroundStyle(.secondary)
              }
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if (choosingProjectDefault
              ? preferences.first(where: {
                $0.kind == .projectDefault && $0.projectID == defaultProjectID
              })?.selectionKey : selectedID) == choice.id
            {
              Image(systemName: "checkmark").foregroundStyle(.tint)
            }
          }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
        Menu {
          Button(
            preference(choice).favorite ? "Remove Favorite" : "Add Favorite", systemImage: "star"
          ) {
            var value = preference(choice)
            value.favorite.toggle()
            _ = persist(value)
          }
          if advancedControls {
            Button(
              ModelImageCapability.supports(choice, preference: preference(choice))
                ? "Mark as Text Only" : "Mark as Supporting Photos", systemImage: "photo"
            ) {
              var value = preference(choice)
              value.supportsImages = !ModelImageCapability.supports(choice, preference: value)
              _ = persist(value)
            }
          }
        } label: {
          Image(systemName: preference(choice).favorite ? "star.fill" : "ellipsis").frame(
            minWidth: 44, minHeight: 44)
        }
        .disabled(privateMode)
        .accessibilityLabel("Options for \(choice.modelIdentifier)")
      }
    }
  }
  private func persist(_ value: ExperienceValue) -> Bool {
    guard !MosaicOperationCoordinator.shared.isSourceAccessBlocked else { return false }
    do {
      var value = value
      value.updatedAt = .now
      try ExperienceStore.save(value, in: modelContext)
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
      return true
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
      return false
    }
  }
}

/// Conservative built-in defaults. Arbitrary gateway/deployment IDs require an explicit override.
enum ModelImageCapability {
  static func supports(_ choice: ChatModelChoice, preference: ExperienceValue?) -> Bool {
    if let override = preference?.supportsImages { return override }
    let model = choice.modelIdentifier.lowercased()
    guard !["audio", "transcribe", "tts", "realtime", "embedding"].contains(where: model.contains)
    else { return false }
    switch choice.providerKind {
    case .openAI:
      return model.hasPrefix("gpt-4o") || model.hasPrefix("gpt-4.1") || model.hasPrefix("gpt-5")
        || model == "o3" || model == "o4-mini"
    case .anthropic:
      return model.hasPrefix("claude-3") || model.hasPrefix("claude-sonnet-4")
        || model.hasPrefix("claude-opus-4") || model.hasPrefix("claude-haiku-4")
    case .google: return model.hasPrefix("gemini-2") || model.hasPrefix("gemini-3")
    default: return false
    }
  }
}

import SwiftUI

struct ProviderModelLimitsDraft: Equatable {
  var contextWindow: Int?
  var maximumOutput: Int?
}

struct ProviderModelsView<RefreshStatus: View>: View {
  @AppStorage(InterfacePreferences.advancedControlsKey) private var advancedControls = false
  let provider: ProviderKind
  let identifiers: [String]
  @Binding var enabled: Set<String>
  @Binding var customIdentifiers: [String]
  @Binding var limits: [String: ProviderModelLimitsDraft]
  let canRefresh: Bool
  let isRefreshing: Bool
  let refresh: () -> Void
  let refreshStatus: RefreshStatus
  @State private var search = ""
  @State private var enabledOnly = false
  @State private var customID = ""
  @FocusState private var customFieldFocused: Bool

  private var filtered: [String] {
    identifiers.filter {
      (!enabledOnly || enabled.contains($0))
        && (search.isEmpty || $0.localizedCaseInsensitiveContains(search))
    }
  }

  var body: some View {
    List {
      Section {
        TextField("Search models", text: $search)
          .autocorrectionDisabled()
        Toggle("Enabled only", isOn: $enabledOnly)
        if provider.supportsModelDiscovery {
          Button(action: refresh) {
            HStack {
              if isRefreshing { ProgressView() }
              Label("Refresh Models", systemImage: "arrow.clockwise")
            }
          }
          .disabled(!canRefresh)
          refreshStatus
        }
      } footer: {
        Text(
          "Catalog suggestions may require account or regional access. Refresh to check the configured connection."
        )
      }
      if advancedControls { addModelSection }
      Section {
        ForEach(filtered, id: \.self) { identifier in
          VStack(alignment: .leading, spacing: 8) {
            Toggle(
              isOn: Binding(
                get: { enabled.contains(identifier) },
                set: {
                  if $0 { enabled.insert(identifier) } else { enabled.remove(identifier) }
                })
            ) {
              Text(identifier).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityLabel("Enable \(identifier)")
            if advancedControls {
              NavigationLink {
                ProviderModelLimitsView(
                  provider: provider, identifier: identifier,
                  draft: Binding(
                    get: { limits[identifier] ?? ProviderModelLimitsDraft() },
                    set: { limits[identifier] = $0 }))
              } label: {
                Label("Request limits", systemImage: "slider.horizontal.3").font(.caption)
              }
            }
          }
          .padding(.vertical, 4)
        }
      } header: {
        Text("\(enabled.count) enabled · \(identifiers.count) available")
      } footer: {
        Text(
          "Enabled models appear in conversations and tasks. New catalog entries stay disabled until you enable them. Save the provider to apply changes."
        )
      }
    }
    .scrollDismissesKeyboard(.interactively)
    .navigationTitle("Models")
  }

  private var addModelSection: some View {
    Section("Add a model ID") {
      TextField("Exact model ID", text: $customID)
        .focused($customFieldFocused)
        .autocorrectionDisabled()
        #if os(iOS)
          .textInputAutocapitalization(.never)
        #endif
      Button("Add and Enable") {
        let identifier = customID.trimmingCharacters(in: .whitespacesAndNewlines)
        customIdentifiers.append(identifier)
        enabled.insert(identifier)
        customID = ""
        customFieldFocused = false
        search = ""
      }
      .disabled(
        customID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || customID.utf8.count > 2_048 || customID.contains(where: { $0.isNewline }))
    }
  }
}

private struct ProviderModelLimitsView: View {
  let provider: ProviderKind
  let identifier: String
  @Binding var draft: ProviderModelLimitsDraft
  private var defaults: ProviderModelRequestLimits {
    ProviderModelMetadataRegistry.defaultLimits(for: provider, modelIdentifier: identifier)
  }
  private var context: Binding<Int> {
    Binding(
      get: { draft.contextWindow ?? defaults.contextWindowTokens },
      set: { draft.contextWindow = $0 })
  }
  private var output: Binding<Int> {
    Binding(
      get: { draft.maximumOutput ?? defaults.maximumOutputTokens },
      set: { draft.maximumOutput = $0 })
  }
  var body: some View {
    Form {
      Section {
        Text(identifier).font(.headline).textSelection(.enabled)
        Text(provider.displayName).foregroundStyle(.secondary)
      }
      Section("Request limits") {
        VStack(alignment: .leading) {
          Text("Context window")
          TextField("Tokens", value: context, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Context window tokens")
        }
        VStack(alignment: .leading) {
          Text("Maximum output")
          TextField("Tokens", value: output, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Maximum output tokens")
        }
        if let issue = ProviderRequestLimitPolicy.validationIssue(
          contextWindowTokens: context.wrappedValue, maximumOutputTokens: output.wrappedValue)
        {
          Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red)
        }
        Button("Use Suggested Limits") { draft = ProviderModelLimitsDraft() }
      }
      Section {
        Text(
          "These limits apply only to this model. Suggested values are estimates; use the model’s published limits when available."
        )
      }
    }
    .navigationTitle("Model Settings")
  }
}

import SwiftUI

/// Optional second recall stage. Off by default because it sends the question and the candidate
/// memories to the chosen provider on every recall.
struct RerankerSettingsSection: View {
  let providers: [ProviderConfigurationRecord]

  @AppStorage(RecallRerankerSettings.enabledKey) private var isEnabled = false
  @AppStorage(RecallRerankerSettings.providerKey) private var providerID = ""
  @AppStorage(RecallRerankerSettings.modelKey) private var model = ""
  @AppStorage(RecallRerankerSettings.minimumScoreKey) private var minimumScore = 0.0
  @AppStorage("smartMemoryEnabled") private var smartMemoryEnabled = true

  var body: some View {
    Section {
      Toggle("Rerank recalled memories", isOn: $isEnabled)
        .disabled(providers.isEmpty)
      if providers.isEmpty {
        Text(
          "Add a Voyage, Cohere, Jina, DeepInfra, llama.cpp, vLLM, LocalAI or custom connection in Providers to choose a reranker."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      } else if isEnabled {
        Picker("Provider", selection: $providerID) {
          Text("Choose…").tag("")
          ForEach(providers) { provider in
            Text(provider.displayName).tag(provider.id.uuidString)
          }
        }
        .onChange(of: providerID) { _, newValue in
          guard model.trimmingCharacters(in: .whitespaces).isEmpty,
            let selected = providers.first(where: { $0.id.uuidString == newValue }),
            let suggestion = selected.provider.defaultRerankModelIdentifier
          else { return }
          model = suggestion
        }
        TextField("Reranker model ID", text: $model)
          .autocorrectionDisabled()
          #if os(iOS)
            .textInputAutocapitalization(.never)
          #endif
        VStack(alignment: .leading, spacing: 4) {
          LabeledContent("Minimum relevance") {
            Text(
              minimumScore == 0
                ? "Off" : minimumScore.formatted(.percent.precision(.fractionLength(0)))
            )
            .foregroundStyle(.secondary)
          }
          Slider(value: $minimumScore, in: 0...0.9, step: 0.05)
            .accessibilityLabel("Minimum reranker relevance")
        }
        if smartMemoryEnabled {
          VStack(alignment: .leading, spacing: 6) {
            Label(
              "Smart memory is on and ranks recall first. The reranker only runs when Smart memory is unavailable.",
              systemImage: "exclamationmark.triangle"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
            Toggle("Smart memory", isOn: $smartMemoryEnabled)
          }
        }
        if !RecallRerankerSettings.load().isUsable {
          Label(
            "Choose a provider and enter a model ID to start reranking.",
            systemImage: "exclamationmark.triangle"
          )
          .font(.footnote)
          .foregroundStyle(.orange)
        }
      }
    } header: {
      Text("Reranker (optional)")
    } footer: {
      Text(
        "Embeddings first narrow recall to 20 candidates; a reranker then reads your question together with each one and decides what reaches the chat model. On the project's personal-memory benchmark this raised MRR@10 from 0.89 to 0.94 (bge-reranker-v2-m3) and 0.96 (Qwen3-Reranker-4B). A minimum relevance also drops some memories that do not help instead of always injecting six, at the cost of occasionally dropping a correct one. This sends the question and the candidate excerpts to the selected provider on every recall and may incur usage charges; if it fails, Turing AI falls back to embedding and local ranking. The suggested Voyage, Cohere and DeepInfra models were measured on the benchmark; the Jina suggestion was not."
      )
    }
  }
}

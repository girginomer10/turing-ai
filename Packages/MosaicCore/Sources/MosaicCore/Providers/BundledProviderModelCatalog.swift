import Foundation

/// Offline discovery suggestions, never an account entitlement or an enablement decision.
enum BundledProviderModelCatalog {
  struct Entry: Decodable, Sendable {
    let provider: ProviderKind
    let models: [String]
    let sources: [String]
    let notes: String
    let coverage: String
    let embeddingModels: [String]?
    let limits: [String: Limits]?
  }

  struct Limits: Decodable, Sendable {
    let contextWindowTokens: Int
    let maximumOutputTokens: Int
  }

  struct Catalog: Decodable, Sendable {
    let verifiedAt: String
    let providers: [Entry]
  }

  static let catalog: Catalog? = {
    guard let url = Bundle.module.url(forResource: "ProviderModels", withExtension: "json"),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return try? JSONDecoder().decode(Catalog.self, from: data)
  }()

  private static let entries: [ProviderKind: Entry] = Dictionary(
    (catalog?.providers ?? []).map { ($0.provider, $0) },
    uniquingKeysWith: { first, _ in first })

  static func entry(for provider: ProviderKind) -> Entry? { entries[provider] }

  private static let suggestions: [ProviderKind: [String]] = entries.mapValues { entry in
    let preferred = entry.provider.providerProfile.suggestedModels.filter {
      entry.models.contains($0)
    }
    return ProviderModelOptionCatalog.merge(
      suggested: preferred, discovered: entry.models, selected: nil)
  }

  static func models(for provider: ProviderKind) -> [String] {
    guard let models = suggestions[provider], !models.isEmpty else {
      return provider.providerProfile.suggestedModels
    }
    return models
  }

  /// Bundled disabled rows need no database entry. Retain personal IDs and explicit choices.
  static func identifiersToPersist(
    provider: ProviderKind, available: [String], enabled: Set<String>,
    saved: [String], customized: [String], legacy: String
  ) -> [String] {
    let bundled = Set(entry(for: provider)?.models ?? [])
    return Set(available.filter { !bundled.contains($0) })
      .union(enabled).union(saved).union(customized).union([legacy])
      .filter { !$0.isEmpty }.sorted()
  }
}

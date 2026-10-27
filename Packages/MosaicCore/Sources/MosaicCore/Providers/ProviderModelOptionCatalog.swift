import Foundation

/// Builds the model choices shown by provider editors without treating any source as exhaustive.
///
/// Curated suggestions make a provider useful before a network request, discovered identifiers
/// reflect the models visible to the current account, and an arbitrary selected identifier remains
/// visible even when neither catalog knows about it yet.
enum ProviderModelOptionCatalog {
  static func merge(
    suggested: [String],
    discovered: [String],
    selected: String?
  ) -> [String] {
    var identifiers: [String] = []
    var seen: Set<String> = []

    func appendUnique(_ identifier: String) {
      guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        seen.insert(identifier).inserted
      else { return }
      identifiers.append(identifier)
    }

    suggested.forEach(appendUnique)
    discovered.sorted().forEach(appendUnique)

    if let selected,
      !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      seen.insert(selected).inserted
    {
      identifiers.insert(selected, at: 0)
    }

    return identifiers
  }
}

struct ProviderModelRequestLimits: Equatable, Sendable {
  let contextWindowTokens: Int
  let maximumOutputTokens: Int
}

/// Exact, documentation-backed request limits for curated models.
///
/// Unknown identifiers deliberately use a conservative fallback. This keeps custom deployment
/// names and older records usable without assuming that a provider-wide maximum belongs to every
/// model hosted by that provider.
enum ProviderModelMetadataRegistry {
  private static let largeOpenAILimits = ProviderModelRequestLimits(
    contextWindowTokens: 1_050_000,
    maximumOutputTokens: 128_000
  )
  private static let compactOpenAILimits = ProviderModelRequestLimits(
    contextWindowTokens: 400_000,
    maximumOutputTokens: 128_000
  )
  private static let currentClaudeLimits = ProviderModelRequestLimits(
    contextWindowTokens: 1_000_000,
    maximumOutputTokens: 128_000
  )
  private static let claudeHaiku45Limits = ProviderModelRequestLimits(
    contextWindowTokens: 200_000,
    maximumOutputTokens: 64_000
  )

  static func exactLimits(
    for provider: ProviderKind,
    modelIdentifier: String
  ) -> ProviderModelRequestLimits? {
    let identifier = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)

    if let limits = BundledProviderModelCatalog.entry(for: provider)?.limits?[identifier] {
      return ProviderModelRequestLimits(
        contextWindowTokens: limits.contextWindowTokens,
        maximumOutputTokens: limits.maximumOutputTokens)
    }

    switch provider {
    case .openAI:
      switch identifier {
      case "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.4":
        return largeOpenAILimits
      case "gpt-5.4-mini", "gpt-5.4-nano":
        return compactOpenAILimits
      default:
        return nil
      }
    case .anthropic:
      switch identifier {
      case "claude-sonnet-5", "claude-opus-5", "claude-fable-5-1":
        return currentClaudeLimits
      case "claude-haiku-4-5-20251001":
        return claudeHaiku45Limits
      default:
        return nil
      }
    default:
      return nil
    }
  }

  static func defaultLimits(
    for provider: ProviderKind,
    modelIdentifier: String
  ) -> ProviderModelRequestLimits {
    if let exact = exactLimits(for: provider, modelIdentifier: modelIdentifier) {
      return exact
    }

    if !provider.defaultModelIdentifier.isEmpty,
      modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        == provider.defaultModelIdentifier
    {
      return ProviderModelRequestLimits(
        contextWindowTokens: provider.suggestedContextWindowTokens,
        maximumOutputTokens: provider.suggestedMaximumOutputTokens
      )
    }

    return conservativeFallback(for: provider)
  }

  static func limitsAfterModelChange(
    current: ProviderModelRequestLimits,
    provider: ProviderKind,
    previousModelIdentifier: String,
    newModelIdentifier: String
  ) -> ProviderModelRequestLimits {
    let previousDefaults = defaultLimits(
      for: provider,
      modelIdentifier: previousModelIdentifier
    )
    let newDefaults = defaultLimits(
      for: provider,
      modelIdentifier: newModelIdentifier
    )

    return ProviderModelRequestLimits(
      contextWindowTokens: current.contextWindowTokens
        == previousDefaults.contextWindowTokens
        ? newDefaults.contextWindowTokens
        : current.contextWindowTokens,
      maximumOutputTokens: current.maximumOutputTokens
        == previousDefaults.maximumOutputTokens
        ? newDefaults.maximumOutputTokens
        : current.maximumOutputTokens
    )
  }

  private static func conservativeFallback(
    for provider: ProviderKind
  ) -> ProviderModelRequestLimits {
    let contextWindowTokens = max(
      2_048,
      min(32_768, provider.suggestedContextWindowTokens)
    )
    let safetyMarginTokens = max(512, min(2_048, contextWindowTokens / 8))
    let maximumSafeOutput = max(128, contextWindowTokens - safetyMarginTokens - 1)
    let maximumOutputTokens = min(
      4_096,
      max(128, provider.suggestedMaximumOutputTokens),
      maximumSafeOutput
    )

    return ProviderModelRequestLimits(
      contextWindowTokens: contextWindowTokens,
      maximumOutputTokens: maximumOutputTokens
    )
  }
}

// Follow-up: ProviderModelCatalogPage currently retains only identifiers. Anthropic's Models API
// also returns per-model max_input_tokens and max_tokens; carry that metadata through discovery in
// a future wire-format revision so account-specific models can receive exact limits automatically.

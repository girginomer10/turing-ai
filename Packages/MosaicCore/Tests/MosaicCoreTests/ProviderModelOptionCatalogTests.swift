import Foundation
import Testing

@testable import MosaicCore

struct ProviderModelOptionCatalogTests {
  @Test
  func currentOpenAIAndAnthropicSuggestionsOfferMultipleUsefulTiers() {
    #expect(
      Array(ProviderKind.openAI.suggestedModelIdentifiers.prefix(6)) == [
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
      ])
    #expect(
      Array(ProviderKind.anthropic.suggestedModelIdentifiers.prefix(4)) == [
        "claude-sonnet-5",
        "claude-opus-5",
        "claude-fable-5-1",
        "claude-haiku-4-5-20251001",
      ])
    #expect(ProviderKind.openAI.suggestedContextWindowTokens == 1_050_000)
    #expect(ProviderKind.openAI.suggestedMaximumOutputTokens == 128_000)
    #expect(ProviderKind.anthropic.suggestedContextWindowTokens == 1_000_000)
    #expect(ProviderKind.anthropic.suggestedMaximumOutputTokens == 128_000)
    #expect(!ProviderKind.openAI.supportsModelDiscovery)
    #expect(ProviderKind.anthropic.supportsModelDiscovery)
  }

  @Test
  func mergePreservesCuratedOrderAndSortsDiscoveredModels() {
    #expect(
      ProviderModelOptionCatalog.merge(
        suggested: ["recommended", "shared", "recommended"],
        discovered: ["zeta", "shared", "alpha"],
        selected: "shared"
      ) == ["recommended", "shared", "alpha", "zeta"])
  }

  @Test
  func mergeKeepsAnArbitrarySelectedIdentifierVisible() {
    #expect(
      ProviderModelOptionCatalog.merge(
        suggested: ["recommended"],
        discovered: ["discovered"],
        selected: "private-deployment-name"
      ) == ["private-deployment-name", "recommended", "discovered"])
  }

  @Test
  func mergeIgnoresEmptyOptionsWithoutNormalizingExactIdentifiers() {
    #expect(
      ProviderModelOptionCatalog.merge(
        suggested: ["", "  ", "CaseSensitive"],
        discovered: ["casesensitive"],
        selected: nil
      ) == ["CaseSensitive", "casesensitive"])
  }

  @Test
  func exactModelLimitsMatchDocumentationBackedCatalogMetadata() {
    let openAILarge = ProviderModelRequestLimits(
      contextWindowTokens: 1_050_000,
      maximumOutputTokens: 128_000
    )
    let openAICompact = ProviderModelRequestLimits(
      contextWindowTokens: 400_000,
      maximumOutputTokens: 128_000
    )
    let claudeCurrent = ProviderModelRequestLimits(
      contextWindowTokens: 1_000_000,
      maximumOutputTokens: 128_000
    )

    for identifier in [
      "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.4",
    ] {
      #expect(
        ProviderModelMetadataRegistry.exactLimits(
          for: .openAI,
          modelIdentifier: identifier
        ) == openAILarge)
    }
    for identifier in ["gpt-5.4-mini", "gpt-5.4-nano"] {
      #expect(
        ProviderModelMetadataRegistry.exactLimits(
          for: .openAI,
          modelIdentifier: identifier
        ) == openAICompact)
    }
    for identifier in ["claude-sonnet-5", "claude-opus-5", "claude-fable-5-1"] {
      #expect(
        ProviderModelMetadataRegistry.exactLimits(
          for: .anthropic,
          modelIdentifier: identifier
        ) == claudeCurrent)
    }
    #expect(
      ProviderModelMetadataRegistry.exactLimits(
        for: .anthropic,
        modelIdentifier: "claude-haiku-4-5-20251001"
      )
        == ProviderModelRequestLimits(
          contextWindowTokens: 200_000,
          maximumOutputTokens: 64_000
        ))
  }

  @Test
  func unknownAndCustomModelsUseAConservativeProviderBoundedFallback() {
    #expect(
      ProviderModelMetadataRegistry.defaultLimits(
        for: .openAI,
        modelIdentifier: "private-fine-tune"
      )
        == ProviderModelRequestLimits(
          contextWindowTokens: 32_768,
          maximumOutputTokens: 4_096
        ))
    #expect(
      ProviderModelMetadataRegistry.defaultLimits(
        for: .custom,
        modelIdentifier: "private-local-model"
      )
        == ProviderModelRequestLimits(
          contextWindowTokens: 8_192,
          maximumOutputTokens: 2_048
        ))
  }

  @Test
  func modelChangesReplaceOnlyValuesThatStillMatchPreviousDefaults() {
    let automatic = ProviderModelMetadataRegistry.limitsAfterModelChange(
      current: ProviderModelRequestLimits(
        contextWindowTokens: 1_050_000,
        maximumOutputTokens: 128_000
      ),
      provider: .openAI,
      previousModelIdentifier: "gpt-5.6-sol",
      newModelIdentifier: "gpt-5.4-mini"
    )
    #expect(
      automatic
        == ProviderModelRequestLimits(
          contextWindowTokens: 400_000,
          maximumOutputTokens: 128_000
        ))

    let partiallyCustomized = ProviderModelMetadataRegistry.limitsAfterModelChange(
      current: ProviderModelRequestLimits(
        contextWindowTokens: 600_000,
        maximumOutputTokens: 128_000
      ),
      provider: .anthropic,
      previousModelIdentifier: "claude-sonnet-5",
      newModelIdentifier: "claude-haiku-4-5-20251001"
    )
    #expect(
      partiallyCustomized
        == ProviderModelRequestLimits(
          contextWindowTokens: 600_000,
          maximumOutputTokens: 64_000
        ))

    let customized = ProviderModelMetadataRegistry.limitsAfterModelChange(
      current: ProviderModelRequestLimits(
        contextWindowTokens: 600_000,
        maximumOutputTokens: 80_000
      ),
      provider: .anthropic,
      previousModelIdentifier: "claude-sonnet-5",
      newModelIdentifier: "claude-haiku-4-5-20251001"
    )
    #expect(
      customized
        == ProviderModelRequestLimits(
          contextWindowTokens: 600_000,
          maximumOutputTokens: 80_000
        ))
  }

  @Test
  func legacyRecordsWithoutSavedLimitsUseExactOrConservativeModelFallbacks() {
    let compactOpenAI = ProviderConversationContextLimits(
      configuration: ProviderConnection(
        id: UUID(),
        displayName: "OpenAI",
        provider: .openAI,
        modelIdentifier: "gpt-5.4-mini"
      )
    )
    #expect(compactOpenAI.policy.contextWindowTokens == 400_000)
    #expect(compactOpenAI.policy.maximumOutputTokens == 128_000)

    let haiku = ProviderConversationContextLimits(
      configuration: ProviderConnection(
        id: UUID(),
        displayName: "Anthropic",
        provider: .anthropic,
        modelIdentifier: "claude-haiku-4-5-20251001"
      )
    )
    #expect(haiku.policy.contextWindowTokens == 200_000)
    #expect(haiku.policy.maximumOutputTokens == 64_000)

    let unknown = ProviderConversationContextLimits(
      configuration: ProviderConnection(
        id: UUID(),
        displayName: "Old OpenAI configuration",
        provider: .openAI,
        modelIdentifier: "legacy-or-private-model"
      )
    )
    #expect(unknown.policy.contextWindowTokens == 32_768)
    #expect(unknown.policy.maximumOutputTokens == 4_096)
  }
}

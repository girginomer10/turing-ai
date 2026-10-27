import Foundation
import SwiftData
import Testing

@testable import MosaicCore

struct BundledProviderModelCatalogTests {
  @Test func resourceCoversEveryProviderWithValidDistinctIdentifiersAndSources() throws {
    let catalog = try #require(BundledProviderModelCatalog.catalog)
    #expect(Set(catalog.providers.map(\.provider)) == Set(ProviderKind.allCases))
    #expect(catalog.providers.count == ProviderKind.allCases.count)
    for entry in catalog.providers {
      #expect(Set(entry.models).count == entry.models.count)
      #expect(!entry.sources.isEmpty)
      #expect(entry.sources.allSatisfy { URL(string: $0)?.scheme == "https" })
      #expect(
        entry.models.allSatisfy {
          !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
            && $0.utf8.count <= 2_048 && !$0.contains(where: \.isNewline)
        })
      if !entry.provider.supportsChat { #expect(entry.models.isEmpty) }
    }
  }

  @Test func expandedCatalogOffersMissingFamiliesWithoutRetiredOrWrongEndpointModels() {
    let google = Set(ProviderKind.google.suggestedModelIdentifiers)
    #expect(
      google.isSuperset(of: [
        "gemini-3.8-flash", "gemini-3.1-pro-preview", "gemini-2.5-pro", "gemma-4-31b-it",
      ]))
    #expect(
      google.isDisjoint(with: [
        "gemini-2.0-flash", "gemini-3-pro-preview", "gemini-3.1-flash-image",
      ]))
    #expect(ProviderKind.anthropic.suggestedModelIdentifiers.contains("claude-opus-4-8"))
    #expect(ProviderKind.qwen.suggestedModelIdentifiers.contains("qwen3-coder-next"))
    #expect(ProviderKind.miniMax.suggestedModelIdentifiers.contains("MiniMax-M2.7-highspeed"))
    #expect(!ProviderKind.openAI.suggestedModelIdentifiers.contains("gpt-5.2-chat-latest"))
    #expect(!ProviderKind.kimi.suggestedModelIdentifiers.contains("kimi-k2.5"))
    #expect(!ProviderKind.amazonBedrock.suggestedModelIdentifiers.contains("openai.gpt-5.6-sol"))
    #expect(!ProviderKind.openRouter.suggestedModelIdentifiers.contains { $0.hasSuffix(":batch") })
    #expect((BundledProviderModelCatalog.entry(for: .voyageAI)?.embeddingModels?.count ?? 0) > 10)
    #expect((BundledProviderModelCatalog.entry(for: .jinaAI)?.embeddingModels?.count ?? 0) > 10)
  }

  @MainActor @Test func largeCatalogPersistsChoicesAndKeepsNewModelsDisabled() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let kind = ProviderKind.featherlessAI
    let available = kind.suggestedModelIdentifiers
    #expect(available.count > 7_000)
    let first = try #require(available.first)
    let provider = ProviderConfigurationRecord(
      displayName: "Catalog test", provider: kind, modelIdentifier: first)
    context.insert(provider)
    let identifiers = BundledProviderModelCatalog.identifiersToPersist(
      provider: kind, available: available + ["private-model"], enabled: [first],
      saved: ["old-model"], customized: [available[1]], legacy: first)
    #expect(identifiers.count == 4)
    try ProviderModelStore.saveCatalog(
      provider: provider, identifiers: identifiers, enabled: [first], in: context)
    try context.save()
    var records = try ProviderModelStore.records(providerID: provider.id, in: context)
    #expect(
      ProviderModelStore.choices(providers: [provider], models: records).map(\.modelIdentifier) == [
        first
      ])
    try ProviderModelStore.saveCatalog(
      provider: provider, identifiers: identifiers, enabled: [], in: context)
    try context.save()
    records = try ProviderModelStore.records(providerID: provider.id, in: context)
    #expect(ProviderModelStore.choices(providers: [provider], models: records).isEmpty)
    #expect(records.count == 4)
  }
}

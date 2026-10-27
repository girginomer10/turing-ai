import Foundation
import Testing

@testable import MosaicCore

@Suite("Embedding profile provider selection")
struct EmbeddingProfileProviderSelectionTests {
  @Test("changing provider kind replaces a stale custom model with the new default")
  func changingProviderKindResetsCustomModel() {
    let selection = EmbeddingProfileProviderSelection.resolvingChange(
      currentDisplayName: "DeepInfra Embeddings",
      currentModelIdentifier: "vendor/private-embedding-model",
      previousProviderID: UUID(),
      previousProviderKind: .deepInfra,
      newProviderDisplayName: "Private Tinfoil",
      newProviderKind: .tinfoil
    )

    #expect(selection.modelIdentifier == "nomic-embed-text")
    #expect(selection.displayName == "Private Tinfoil Embeddings")
  }

  @Test("changing to a provider kind without a default clears the stale model")
  func changingToProviderWithoutDefaultClearsModel() {
    let selection = EmbeddingProfileProviderSelection.resolvingChange(
      currentDisplayName: "Research vectors",
      currentModelIdentifier: "nomic-embed-text",
      previousProviderID: UUID(),
      previousProviderKind: .tinfoil,
      newProviderDisplayName: "Lab endpoint",
      newProviderKind: .custom
    )

    #expect(selection.modelIdentifier.isEmpty)
    #expect(selection.displayName == "Research vectors")
  }

  @Test("changing connections within one provider kind preserves a custom model")
  func sameProviderKindPreservesCustomModel() {
    let selection = EmbeddingProfileProviderSelection.resolvingChange(
      currentDisplayName: "Research vectors",
      currentModelIdentifier: "Qwen/custom-embedding",
      previousProviderID: UUID(),
      previousProviderKind: .deepInfra,
      newProviderDisplayName: "DeepInfra backup",
      newProviderKind: .deepInfra
    )

    #expect(selection.modelIdentifier == "Qwen/custom-embedding")
    #expect(selection.displayName == "Research vectors")
  }
}

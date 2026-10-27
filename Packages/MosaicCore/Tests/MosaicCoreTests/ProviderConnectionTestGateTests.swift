import Foundation
import Testing

@testable import MosaicCore

struct ProviderConnectionTestGateTests {
  @Test
  func aNewRequestRejectsEveryCompletionFromThePreviousRequest() {
    let staleRequestID = UUID()
    let currentRequestID = UUID()
    var gate = ProviderConnectionTestGate()

    #expect(gate.begin(id: staleRequestID) == staleRequestID)
    #expect(gate.begin(id: currentRequestID) == currentRequestID)

    #expect(!gate.accepts(staleRequestID))
    let staleRequestFinished = gate.finish(staleRequestID)
    #expect(!staleRequestFinished)
    #expect(gate.accepts(currentRequestID))
    let currentRequestFinished = gate.finish(currentRequestID)
    #expect(currentRequestFinished)
    #expect(gate.activeRequestID == nil)
  }

  @Test
  func invalidationRejectsALateCancellationOrFailure() {
    let requestID = UUID()
    var gate = ProviderConnectionTestGate()

    _ = gate.begin(id: requestID)
    gate.invalidate()

    #expect(!gate.accepts(requestID))
    let invalidatedRequestFinished = gate.finish(requestID)
    #expect(!invalidatedRequestFinished)
    #expect(gate.activeRequestID == nil)
  }

  @Test
  func officialAIMLAPICatalogIsExplicitlyUnauthenticatedButCustomCatalogIsNot() {
    let official = ProviderConnection(
      id: UUID(),
      displayName: ProviderKind.aimlAPI.displayName,
      provider: .aimlAPI,
      modelIdentifier: ""
    )
    let custom = ProviderConnection(
      id: UUID(),
      displayName: "AI/ML API proxy",
      provider: .aimlAPI,
      baseURL: URL(string: "https://gateway.example/v1"),
      modelIdentifier: "",
      apiKey: "test-key"
    )

    #expect(ProviderConnectionTestSemantics.usesUnauthenticatedPublicCatalog(for: official))
    #expect(!ProviderConnectionTestSemantics.usesUnauthenticatedPublicCatalog(for: custom))
  }

  @Test
  func publicCatalogSuccessNeverClaimsThatTheCredentialWasVerified() {
    #expect(
      ProviderConnectionTestSemantics.successMessage(
        modelCount: 2,
        usesUnauthenticatedPublicCatalog: true
      )
        == "Public model catalog is reachable. Found 2 models. The API key was not sent or verified."
    )
    #expect(
      ProviderConnectionTestSemantics.successMessage(
        modelCount: 0,
        usesUnauthenticatedPublicCatalog: true
      )
        == "Public model catalog is reachable, but it returned no models. The API key was not sent or verified; enter a model ID manually."
    )
  }

  @Test
  func authenticatedCatalogSuccessWordingRemainsUnchanged() {
    #expect(
      ProviderConnectionTestSemantics.successMessage(
        modelCount: 0,
        usesUnauthenticatedPublicCatalog: false
      )
        == "Connected, but the provider returned no models. Enter a model ID manually."
    )
    #expect(
      ProviderConnectionTestSemantics.successMessage(
        modelCount: 1,
        usesUnauthenticatedPublicCatalog: false
      ) == "Connected. Found 1 model."
    )
    #expect(
      ProviderConnectionTestSemantics.successMessage(
        modelCount: 2,
        usesUnauthenticatedPublicCatalog: false
      ) == "Connected. Found 2 models."
    )
  }
}

import Foundation
import Testing

@testable import MosaicCore

struct ConversationContextPlannerTests {
  private let estimator = ConservativeTokenEstimator(
    messageFramingTokens: 0,
    systemFramingTokens: 0
  )

  @Test
  func underBudgetHistoryPassesThroughExactly() throws {
    let messages = [
      message(.user, "Earlier question"),
      message(.assistant, "Earlier answer"),
      message(.user, "Current question"),
    ]
    let planner = makePlanner(inputBudget: 200, minimumRecentTurns: 1)

    let plan = try planner.plan(messages: messages, systemPrompt: "Instructions")

    #expect(plan.messages == messages)
    #expect(plan.receipt.strategy == .full)
    #expect(plan.receipt.includedMessageIDs == messages.map(\.id))
    #expect(plan.receipt.omittedMessageIDs.isEmpty)
  }

  @Test
  func overflowOmitsOnlyTheOldestCompleteTurn() throws {
    let oldest = [
      message(.user, repeated("o", count: 90)),
      message(.assistant, repeated("a", count: 90)),
    ]
    let recent = [
      message(.user, repeated("r", count: 30)),
      message(.assistant, repeated("s", count: 30)),
      message(.user, repeated("c", count: 30)),
    ]
    let planner = makePlanner(inputBudget: 100, minimumRecentTurns: 1)

    let plan = try planner.plan(messages: oldest + recent, systemPrompt: nil)

    #expect(plan.messages == recent)
    #expect(plan.receipt.strategy == .recentOnly)
    #expect(plan.receipt.omittedMessageIDs == oldest.map(\.id))
    #expect(plan.receipt.includedMessageIDs == recent.map(\.id))
    #expect(plan.receipt.estimatedInputTokens == 90)
  }

  @Test
  func currentMessageAndConfiguredPriorTurnsAreAlwaysProtected() throws {
    let first = turn(marker: "1", charactersPerMessage: 75)
    let second = turn(marker: "2", charactersPerMessage: 30)
    let third = turn(marker: "3", charactersPerMessage: 30)
    let current = message(.user, repeated("4", count: 30))
    let planner = makePlanner(inputBudget: 160, minimumRecentTurns: 2)

    let plan = try planner.plan(
      messages: first + second + third + [current],
      systemPrompt: nil
    )

    #expect(plan.messages == second + third + [current])
    #expect(plan.receipt.omittedMessageIDs == first.map(\.id))
  }

  @Test
  func requiredContentThatCannotFitFailsWithoutTruncating() throws {
    let current = message(.user, repeated("x", count: 60))
    let planner = makePlanner(inputBudget: 10, minimumRecentTurns: 1)

    do {
      _ = try planner.plan(messages: [current], systemPrompt: nil)
      Issue.record("Expected the planner to reject required content above the safe budget")
    } catch let error as ConversationContextPlannerError {
      guard case .requiredContentExceedsBudget(let required, let available) = error else {
        Issue.record("Unexpected planner error: \(error)")
        return
      }
      #expect(required == 60)
      #expect(available == 10)
    }
  }

  @Test
  func systemPromptConsumesTheSameInputBudgetAsMessages() throws {
    let oldest = turn(marker: "o", charactersPerMessage: 45)
    let recent = turn(marker: "r", charactersPerMessage: 30)
    let current = message(.user, repeated("c", count: 30))
    let planner = makePlanner(inputBudget: 140, minimumRecentTurns: 1)

    let plan = try planner.plan(
      messages: oldest + recent + [current],
      systemPrompt: repeated("s", count: 45)
    )

    #expect(plan.messages == recent + [current])
    #expect(plan.receipt.estimatedInputTokens == 135)
    #expect(plan.receipt.omittedMessageIDs == oldest.map(\.id))
  }

  @Test
  func estimatorIsDeterministicAndConservativeForUnicodeCodeAndDenseText() {
    let text =
      "Türkçe tercih: kısa cevap 🙂\n```swift\nlet sayı = 42\n```\nQWxhZGRpbjpvcGVuIHNlc2FtZQ=="

    let first = estimator.estimate(text: text)
    let second = estimator.estimate(text: text)

    #expect(first == second)
    #expect(first == text.utf8.count)
    #expect(first >= text.count)
  }

  @MainActor
  @Test
  func providerSavedLimitsDriveTheRequestPolicy() {
    let provider = ProviderConfigurationRecord(
      displayName: "Configured",
      provider: .custom,
      modelIdentifier: "model",
      contextWindowTokens: 16_384,
      maximumOutputTokens: 1_024
    )

    let limits = ProviderConversationContextLimits(
      configuration: ProviderConnection(configuration: provider)
    )

    #expect(limits.policy.contextWindowTokens == 16_384)
    #expect(limits.policy.maximumOutputTokens == 1_024)
    #expect(limits.policy.safetyMarginTokens == 2_048)
    #expect(limits.warnings.contains { $0.contains("saved") })
  }

  @MainActor
  @Test
  func legacyProviderGetsDisclosedCategoryFallbackLimits() {
    let provider = ProviderConfigurationRecord(
      displayName: "Legacy local",
      provider: .ollama,
      modelIdentifier: "model"
    )

    let limits = ProviderConversationContextLimits(
      configuration: ProviderConnection(configuration: provider)
    )

    #expect(limits.policy.contextWindowTokens == 8_192)
    #expect(limits.policy.maximumOutputTokens == 2_048)
    #expect(limits.policy.safetyMarginTokens == 1_024)
    #expect(limits.warnings.contains { $0.contains("older provider configuration") })
  }

  @MainActor
  @Test
  func providerRequestSnapshotDoesNotChangeWhenTheSavedConfigurationChanges() {
    let provider = ProviderConfigurationRecord(
      displayName: "Before",
      provider: .custom,
      modelIdentifier: "model-before",
      baseURL: URL(string: "https://before.example/v1"),
      contextWindowTokens: 16_384,
      maximumOutputTokens: 1_024
    )
    let snapshot = ProviderConnection(configuration: provider)

    provider.displayName = "After"
    provider.modelIdentifier = "model-after"
    provider.baseURL = URL(string: "https://after.example/v1")
    provider.contextWindowTokens = 4_096
    provider.maximumOutputTokens = 512

    let authenticated = snapshot.authenticated(with: "secret")
    let limits = ProviderConversationContextLimits(configuration: snapshot)

    #expect(authenticated.displayName == "Before")
    #expect(authenticated.modelIdentifier == "model-before")
    #expect(authenticated.resolvedBaseURL?.host == "before.example")
    #expect(authenticated.apiKey == "secret")
    #expect(limits.policy.contextWindowTokens == 16_384)
    #expect(limits.policy.maximumOutputTokens == 1_024)
  }

  @Test
  func legacyRequestReceiptDecodesWithoutConversationContext() throws {
    let legacy = LegacyRequestContextReceipt(
      curatedContext: .empty,
      retrievedContext: .empty,
      createdAt: Date(timeIntervalSince1970: 123)
    )

    let data = try JSONEncoder().encode(legacy)
    let decoded = try JSONDecoder().decode(RequestContextReceipt.self, from: data)

    #expect(decoded.curatedContext == .empty)
    #expect(decoded.retrievedContext == .empty)
    #expect(decoded.conversationContext == nil)
    #expect(decoded.conversationCompaction == nil)
    #expect(decoded.createdAt == legacy.createdAt)
  }

  @Test
  func legacyNestedConversationReceiptDecodesWithoutCompactionFields() throws {
    let messageID = UUID()
    let legacy = LegacyRequestWithConversationReceipt(
      curatedContext: .empty,
      retrievedContext: .empty,
      conversationContext: LegacyConversationContextReceipt(
        strategy: .recentOnly,
        originalMessageCount: 2,
        includedMessageIDs: [messageID],
        omittedMessageIDs: [UUID()],
        estimatedInputTokens: 100,
        contextWindowTokens: 1_000,
        maximumOutputTokens: 100,
        safetyMarginTokens: 50,
        warnings: ["legacy"]
      ),
      createdAt: Date(timeIntervalSince1970: 456)
    )

    let decoded = try JSONDecoder().decode(
      RequestContextReceipt.self,
      from: JSONEncoder().encode(legacy)
    )

    #expect(decoded.conversationContext?.includedMessageIDs == [messageID])
    #expect(decoded.conversationContext?.summarizedMessageIDs == nil)
    #expect(decoded.conversationCompaction == nil)
  }

  private func makePlanner(
    inputBudget: Int,
    minimumRecentTurns: Int
  ) -> ConversationContextPlanner {
    ConversationContextPlanner(
      policy: ConversationContextPolicy(
        contextWindowTokens: inputBudget + 1,
        maximumOutputTokens: 1,
        safetyMarginTokens: 0,
        minimumRecentTurns: minimumRecentTurns
      ),
      estimator: estimator
    )
  }

  private func message(_ role: MessageRole, _ content: String) -> AIChatMessage {
    AIChatMessage(role: role, content: content)
  }

  private func turn(marker: String, charactersPerMessage: Int) -> [AIChatMessage] {
    [
      message(.user, repeated(marker, count: charactersPerMessage)),
      message(.assistant, repeated(marker.uppercased(), count: charactersPerMessage)),
    ]
  }

  private func repeated(_ value: String, count: Int) -> String {
    String(repeating: value, count: count)
  }
}

private struct LegacyRequestContextReceipt: Codable {
  let curatedContext: MemoryContext
  let retrievedContext: RetrievedContext
  let createdAt: Date
}

private struct LegacyRequestWithConversationReceipt: Codable {
  let curatedContext: MemoryContext
  let retrievedContext: RetrievedContext
  let conversationContext: LegacyConversationContextReceipt
  let createdAt: Date
}

private struct LegacyConversationContextReceipt: Codable {
  let strategy: ConversationContextStrategy
  let originalMessageCount: Int
  let includedMessageIDs: [UUID]
  let omittedMessageIDs: [UUID]
  let estimatedInputTokens: Int
  let contextWindowTokens: Int
  let maximumOutputTokens: Int
  let safetyMarginTokens: Int
  let warnings: [String]
}

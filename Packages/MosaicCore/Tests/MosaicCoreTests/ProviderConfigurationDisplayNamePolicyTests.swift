import Testing

@testable import MosaicCore

@Suite("Provider configuration display names")
struct ProviderConfigurationDisplayNamePolicyTests {
  @Test("new built-in providers use their catalog name")
  func newBuiltInProviderIgnoresEnteredName() {
    #expect(!ProviderConfigurationDisplayNamePolicy.usesCustomName(for: .openAI))
    #expect(
      ProviderConfigurationDisplayNamePolicy.resolvedName(
        for: .openAI,
        enteredName: "Personal account"
      ) == "OpenAI"
    )
  }

  @Test("an existing built-in alias survives unrelated edits")
  func existingBuiltInProviderPreservesAlias() {
    #expect(
      ProviderConfigurationDisplayNamePolicy.resolvedName(
        for: .openAI,
        enteredName: "OpenAI",
        existingProvider: .openAI,
        existingName: "Work account"
      ) == "Work account"
    )
  }

  @Test("changing a built-in provider uses the new catalog name")
  func changedBuiltInProviderDoesNotCarryAlias() {
    #expect(
      ProviderConfigurationDisplayNamePolicy.resolvedName(
        for: .anthropic,
        enteredName: "Work account",
        existingProvider: .openAI,
        existingName: "Work account"
      ) == "Anthropic"
    )
  }

  @Test("custom providers preserve a trimmed user-facing name")
  func customProviderUsesEnteredName() {
    #expect(ProviderConfigurationDisplayNamePolicy.usesCustomName(for: .custom))
    #expect(
      ProviderConfigurationDisplayNamePolicy.resolvedName(
        for: .custom,
        enteredName: "  Local lab  "
      ) == "Local lab"
    )
  }
}

import Testing

@testable import MosaicCore

struct ProviderRequestLimitPolicyTests {
  @Test
  func derivedValuesMatchTheConversationPlannerHeuristic() {
    #expect(ProviderRequestLimitPolicy.safetyMarginTokens(for: 2_048) == 512)
    #expect(ProviderRequestLimitPolicy.safetyMarginTokens(for: 8_192) == 1_024)
    #expect(ProviderRequestLimitPolicy.safetyMarginTokens(for: 32_768) == 2_048)
    #expect(ProviderRequestLimitPolicy.safetyMarginTokens(for: 2_000_000) == 2_048)

    #expect(
      ProviderRequestLimitPolicy.estimatedInputBudget(
        contextWindowTokens: 32_768,
        maximumOutputTokens: 4_096
      ) == 26_624
    )
  }

  @Test
  func validationRejectsEveryInvalidLimitBoundary() {
    #expect(
      ProviderRequestLimitPolicy.validationIssue(
        contextWindowTokens: 2_047,
        maximumOutputTokens: 128
      ) != nil
    )
    #expect(
      ProviderRequestLimitPolicy.validationIssue(
        contextWindowTokens: 2_048,
        maximumOutputTokens: 127
      ) != nil
    )
    #expect(
      ProviderRequestLimitPolicy.validationIssue(
        contextWindowTokens: 2_048,
        maximumOutputTokens: 1_536
      ) != nil
    )
    #expect(
      ProviderRequestLimitPolicy.validationIssue(
        contextWindowTokens: 32_768,
        maximumOutputTokens: 4_096
      ) == nil
    )
  }

  @Test
  func steppersRequireValidVisibleValues() {
    #expect(!ProviderRequestLimitPolicy.canAdjustContextWindow(nil))
    #expect(!ProviderRequestLimitPolicy.canAdjustContextWindow(100))
    #expect(ProviderRequestLimitPolicy.canAdjustContextWindow(2_048))

    #expect(
      !ProviderRequestLimitPolicy.canAdjustMaximumOutput(
        1_000_000,
        contextWindowTokens: 2_048
      )
    )
    #expect(
      !ProviderRequestLimitPolicy.canAdjustMaximumOutput(
        128,
        contextWindowTokens: 100
      )
    )
    #expect(
      ProviderRequestLimitPolicy.canAdjustMaximumOutput(
        1_535,
        contextWindowTokens: 2_048
      )
    )
  }

  @Test
  func maximumOutputStepperRangeTracksTheCurrentContextWindow() {
    #expect(
      ProviderRequestLimitPolicy.maximumOutputRange(for: 2_048)
        == 128...1_535
    )
    #expect(
      ProviderRequestLimitPolicy.maximumOutputRange(for: 32_768)
        == 128...30_719
    )
    #expect(
      ProviderRequestLimitPolicy.maximumOutputRange(for: 2_000_000)
        == 128...1_000_000
    )
  }
}

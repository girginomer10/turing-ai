enum ProviderRequestLimitPolicy {
  static let contextWindowRange: ClosedRange<Int> = 2_048...2_000_000
  static let maximumOutputRange: ClosedRange<Int> = 128...1_000_000
  static let contextWindowStep = 1_024
  static let maximumOutputStep = 128

  static func safetyMarginTokens(for contextWindowTokens: Int) -> Int {
    max(512, min(2_048, contextWindowTokens / 8))
  }

  static func estimatedInputBudget(
    contextWindowTokens: Int?,
    maximumOutputTokens: Int?
  ) -> Int? {
    guard
      validationIssue(
        contextWindowTokens: contextWindowTokens,
        maximumOutputTokens: maximumOutputTokens
      ) == nil,
      let contextWindowTokens,
      let maximumOutputTokens
    else {
      return nil
    }

    return contextWindowTokens - maximumOutputTokens
      - safetyMarginTokens(for: contextWindowTokens)
  }

  static func validationIssue(
    contextWindowTokens: Int?,
    maximumOutputTokens: Int?
  ) -> String? {
    guard let contextWindowTokens, contextWindowRange.contains(contextWindowTokens) else {
      return "Enter a context window between 2048 and 2000000 tokens."
    }
    guard let maximumOutputTokens, maximumOutputRange.contains(maximumOutputTokens) else {
      return "Enter a maximum output between 128 and 1000000 tokens."
    }
    guard maximumOutputTokens < contextWindowTokens - safetyMarginTokens(for: contextWindowTokens)
    else {
      return "Maximum output plus the safety margin must be smaller than the context window."
    }
    return nil
  }

  static func normalizedContextWindow(_ value: Int) -> Int {
    clamped(value, to: contextWindowRange)
  }

  static func maximumOutputRange(for contextWindowTokens: Int) -> ClosedRange<Int> {
    let contextWindowTokens = normalizedContextWindow(contextWindowTokens)
    let highestSafeOutput =
      contextWindowTokens - safetyMarginTokens(for: contextWindowTokens) - 1
    let upperBound = min(maximumOutputRange.upperBound, highestSafeOutput)
    return maximumOutputRange.lowerBound...max(maximumOutputRange.lowerBound, upperBound)
  }

  static func normalizedMaximumOutput(
    _ value: Int,
    contextWindowTokens: Int
  ) -> Int {
    clamped(value, to: maximumOutputRange(for: contextWindowTokens))
  }

  static func canAdjustContextWindow(_ contextWindowTokens: Int?) -> Bool {
    guard let contextWindowTokens else { return false }
    return contextWindowRange.contains(contextWindowTokens)
  }

  static func canAdjustMaximumOutput(
    _ maximumOutputTokens: Int?,
    contextWindowTokens: Int?
  ) -> Bool {
    guard let maximumOutputTokens,
      let contextWindowTokens,
      canAdjustContextWindow(contextWindowTokens)
    else { return false }

    return maximumOutputRange(for: contextWindowTokens).contains(maximumOutputTokens)
  }

  private static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
    min(range.upperBound, max(range.lowerBound, value))
  }
}

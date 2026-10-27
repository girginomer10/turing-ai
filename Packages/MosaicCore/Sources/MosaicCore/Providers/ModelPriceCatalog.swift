import Foundation

/// Reviewed public list prices. No account credentials, runtime network call or billing claim.
enum ModelPriceCatalog {
  struct Tier: Decodable, Sendable {
    let fromInput: Int
    let input: Double
    let output: Double
  }
  struct Rate: Decodable, Sendable {
    let provider: ProviderKind
    let models: [String]
    let input: Double
    let output: Double
    let source: URL
    var tiers: [Tier]?
    var maximumInput: Int?
    var weekdayPeakMultiplier: Double?
    var validUntil: String?

    func estimate(input tokens: Int, output outputTokens: Int, at date: Date) -> Double? {
      guard tokens >= 0, outputTokens >= 0,
        maximumInput.map({ tokens <= $0 }) ?? true
      else { return nil }
      let tier = tiers?.last(where: { tokens >= $0.fromInput })
      var multiplier = 1.0
      if let peak = weekdayPeakMultiplier {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.component(.weekday, from: date)
        let hour = calendar.component(.hour, from: date)
        if (2...6).contains(day), (1..<4).contains(hour) || (6..<10).contains(hour) {
          multiplier = peak
        }
      }
      return
        (Double(tokens) * (tier?.input ?? input)
        + Double(outputTokens) * (tier?.output ?? output)) * multiplier / 1_000_000
    }
  }
  struct Catalog: Decodable, Sendable {
    let verifiedAt: String
    let validUntil: String
    let entries: [Rate]
  }
  static let catalog: Catalog? = {
    guard let url = Bundle.module.url(forResource: "ModelPrices", withExtension: "json"),
      let data = try? Data(contentsOf: url), data.count <= 2_000_000,
      let value = try? JSONDecoder().decode(Catalog.self, from: data),
      value.entries.count <= 10_000,
      value.entries.allSatisfy({ rate in
        rate.source.scheme == "https" && rate.source.host != nil && !rate.models.isEmpty
          && [rate.input, rate.output].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1_000_000 }
          && (rate.tiers ?? []).allSatisfy {
            $0.fromInput >= 0 && $0.input.isFinite && $0.output.isFinite
              && $0.input >= 0 && $0.output >= 0 && $0.input <= 1_000_000 && $0.output <= 1_000_000
          }
      })
    else { return nil }
    return value
  }()
  private static let rates: [String: Rate] = Dictionary(
    (catalog?.entries ?? []).flatMap { rate in
      rate.models.map { (rate.provider.rawValue + "/" + $0, rate) }
    }, uniquingKeysWith: { first, _ in first })

  private static let deadlines: [String: Date] = Dictionary(
    Set((catalog?.entries.compactMap(\.validUntil) ?? []) + [catalog?.validUntil ?? ""])
      .map { ($0, date($0)) }, uniquingKeysWith: { first, _ in first })

  static func rate(provider: ProviderKind?, host: String?, model: String, now: Date = .now) -> Rate?
  {
    guard let provider, let host,
      normalizedHost(host) == provider.defaultBaseURL?.host?.lowercased(),
      let catalog, now < (deadlines[catalog.validUntil] ?? .distantPast),
      let rate = rates[provider.rawValue + "/" + model],
      rate.validUntil.map({ now < (deadlines[$0] ?? .distantPast) }) ?? true
    else { return nil }
    return rate
  }
  static func normalizedHost(_ value: String) -> String? {
    if value.contains("://") { return URL(string: value)?.host?.lowercased() }
    guard !value.contains("/"), !value.contains("@"), !value.contains(":") else { return nil }
    return value.lowercased()
  }
  private static func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value + "T00:00:00Z") ?? .distantPast
  }
  static var isOutdated: Bool {
    guard let catalog else { return true }
    return Date.now >= (deadlines[catalog.validUntil] ?? .distantPast)
  }
}

import Foundation

/// How strongly an old event is discounted relative to lasting memories and messages.
public struct EventFadePolicy: Hashable, Sendable {
  /// Days for the fade factor to halve.
  public var halfLifeDays: Double
  /// The weakest weight an old event can reach.
  public var floor: Double
  /// An event that already ranks within this many results before fading is shielded, so asking
  /// about a specific past event still finds it. Zero disables the shield.
  public var protectedRanks: Int
  /// Weight floor for a shielded event. Below 1 so a newer, equally relevant event still wins.
  public var protectedWeight: Double

  public init(
    halfLifeDays: Double, floor: Double, protectedRanks: Int = 0, protectedWeight: Double = 1
  ) {
    self.halfLifeDays = max(0.001, halfLifeDays)
    self.floor = min(1, max(0, floor))
    self.protectedRanks = max(0, protectedRanks)
    self.protectedWeight = min(1, max(0, protectedWeight))
  }

  /// The original behavior: a 14-day half-life with a 15% floor and no shield.
  public static let legacy = EventFadePolicy(halfLifeDays: 14, floor: 0.15)

  /// Chosen on held-out personas of the synthetic memory benchmark (benchmarks/memory): a slower
  /// fade, a higher floor, and a shield for events that already rank among the top three results.
  /// Under the legacy policy an event only a month old was almost never recalled when asked about.
  public static let standard = EventFadePolicy(
    halfLifeDays: 45, floor: 0.4, protectedRanks: 3, protectedWeight: 0.85)

  public func weight(ageInDays: Double) -> Double {
    max(floor, pow(0.5, max(0, ageInDays) / halfLifeDays))
  }
}

enum RecentEventMemoryPolicy {
  /// Relevance fades without deleting history or converting an event into a lasting fact.
  static func relevanceWeight(
    lastConfirmedAt: Date, now: Date = .now, policy: EventFadePolicy = .standard
  ) -> Double {
    policy.weight(ageInDays: now.timeIntervalSince(lastConfirmedAt) / 86_400)
  }

  static func isRecent(lastConfirmedAt: Date, now: Date = .now) -> Bool {
    now.timeIntervalSince(lastConfirmedAt) <= 30 * 86_400
  }
}

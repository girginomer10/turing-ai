import Foundation

/// Bounds the amount of streamed text that exists only in memory without forcing a SwiftData save
/// for every provider token. Terminal response states are always persisted separately by the
/// caller.
struct ConversationStreamPersistencePolicy: Sendable {
  static let defaultMaximumUnpersistedUTF8Bytes = 8 * 1_024
  static let defaultMaximumUnpersistedInterval: TimeInterval = 0.25

  let maximumUnpersistedUTF8Bytes: Int
  let maximumUnpersistedInterval: TimeInterval

  private(set) var unpersistedUTF8Bytes = 0
  private(set) var lastPersistedAt: Date

  init(
    maximumUnpersistedUTF8Bytes: Int = Self.defaultMaximumUnpersistedUTF8Bytes,
    maximumUnpersistedInterval: TimeInterval = Self.defaultMaximumUnpersistedInterval,
    lastPersistedAt: Date = .now
  ) {
    precondition(maximumUnpersistedUTF8Bytes > 0)
    precondition(maximumUnpersistedInterval > 0)
    self.maximumUnpersistedUTF8Bytes = maximumUnpersistedUTF8Bytes
    self.maximumUnpersistedInterval = maximumUnpersistedInterval
    self.lastPersistedAt = lastPersistedAt
  }

  mutating func shouldPersist(afterAppendingUTF8Bytes byteCount: Int, now: Date) -> Bool {
    precondition(byteCount >= 0)
    let (nextByteCount, overflow) = unpersistedUTF8Bytes.addingReportingOverflow(byteCount)
    unpersistedUTF8Bytes = overflow ? .max : nextByteCount
    return overflow
      || unpersistedUTF8Bytes >= maximumUnpersistedUTF8Bytes
      || now.timeIntervalSince(lastPersistedAt) >= maximumUnpersistedInterval
  }

  mutating func didPersist(at date: Date) {
    unpersistedUTF8Bytes = 0
    lastPersistedAt = date
  }
}

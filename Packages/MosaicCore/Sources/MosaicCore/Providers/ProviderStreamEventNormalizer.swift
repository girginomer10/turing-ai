import Foundation

/// Normalizes provider-specific streaming semantics before deltas reach persistence or UI code.
/// Most OpenAI-compatible hosts emit true deltas. MiniMax documents `delta.content` as the full
/// text accumulated so far, so forwarding it directly would duplicate every prior fragment.
struct ProviderStreamEventNormalizer {
  private let provider: ProviderKind
  private var miniMaxAccumulatedTextUTF8: [UInt8] = []

  init(provider: ProviderKind) {
    self.provider = provider
  }

  mutating func normalize(_ events: [AIStreamEvent]) throws -> [AIStreamEvent] {
    guard provider == .miniMax else { return events }

    var normalized: [AIStreamEvent] = []
    normalized.reserveCapacity(events.count)
    for event in events {
      guard case .textDelta(let cumulativeText) = event else {
        normalized.append(event)
        continue
      }
      let cumulativeTextUTF8 = Array(cumulativeText.utf8)
      guard cumulativeTextUTF8.count <= MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes
      else {
        throw ProviderClientError.responseTooLarge
      }
      guard cumulativeTextUTF8.starts(with: miniMaxAccumulatedTextUTF8) else {
        throw ProviderClientError.invalidResponse
      }

      let deltaUTF8 = cumulativeTextUTF8.dropFirst(miniMaxAccumulatedTextUTF8.count)
      miniMaxAccumulatedTextUTF8 = cumulativeTextUTF8
      if !deltaUTF8.isEmpty {
        normalized.append(.textDelta(String(decoding: deltaUTF8, as: UTF8.self)))
      }
    }
    return normalized
  }
}

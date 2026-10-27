import Foundation

public struct LiveTranscriptSnapshot: Hashable, Sendable {
  public let finalizedText: String
  public let interimText: String?
  public let displayText: String
  public let languageCode: String?

  public init(
    finalizedText: String,
    interimText: String?,
    displayText: String,
    languageCode: String?
  ) {
    self.finalizedText = finalizedText
    self.interimText = interimText
    self.displayText = displayText
    self.languageCode = languageCode
  }
}

/// A deterministic value-type reducer for rendering speculative text without committing it.
/// Interim hypotheses replace each other; only final events are appended to `finalizedText`.
public struct LiveTranscriptAssembler: Sendable {
  public static let defaultMaximumTranscriptBytes = 4 * 1_024 * 1_024

  public private(set) var snapshot: LiveTranscriptSnapshot

  private let maximumTranscriptBytes: Int

  public init() {
    maximumTranscriptBytes = Self.defaultMaximumTranscriptBytes
    snapshot = Self.emptySnapshot
  }

  public init(maximumTranscriptBytes: Int) throws {
    guard
      maximumTranscriptBytes > 0,
      maximumTranscriptBytes <= Self.defaultMaximumTranscriptBytes
    else {
      throw LiveTranscriptionError.invalidConfiguration(
        "The transcript size limit must be between 1 byte and \(Self.defaultMaximumTranscriptBytes) bytes."
      )
    }
    self.maximumTranscriptBytes = maximumTranscriptBytes
    snapshot = Self.emptySnapshot
  }

  @discardableResult
  public mutating func consume(_ event: LiveTranscriptionEvent) throws -> LiveTranscriptSnapshot {
    switch event {
    case .interimTranscript(let text, let languageCode):
      let interim = normalized(text)
      let nextInterim = interim.isEmpty ? nil : interim
      let displayText = Self.join(snapshot.finalizedText, nextInterim ?? "")
      try validateByteCount(displayText)
      snapshot = LiveTranscriptSnapshot(
        finalizedText: snapshot.finalizedText,
        interimText: nextInterim,
        displayText: displayText,
        languageCode: languageCode ?? snapshot.languageCode
      )

    case .finalTranscript(let text, let languageCode):
      let finalizedSegment = normalized(text)
      let finalizedText = Self.join(snapshot.finalizedText, finalizedSegment)
      try validateByteCount(finalizedText)
      snapshot = LiveTranscriptSnapshot(
        finalizedText: finalizedText,
        interimText: nil,
        displayText: finalizedText,
        languageCode: languageCode ?? snapshot.languageCode
      )

    case .ended:
      snapshot = LiveTranscriptSnapshot(
        finalizedText: snapshot.finalizedText,
        interimText: nil,
        displayText: snapshot.finalizedText,
        languageCode: snapshot.languageCode
      )

    case .setupComplete, .turnComplete, .durationLimitApproaching, .goAway:
      break
    }
    return snapshot
  }

  public mutating func reset() {
    snapshot = Self.emptySnapshot
  }

  private func normalized(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func validateByteCount(_ text: String) throws {
    guard text.utf8.count <= maximumTranscriptBytes else {
      throw LiveTranscriptionError.responseTooLarge
    }
  }

  private static func join(_ existing: String, _ addition: String) -> String {
    guard !existing.isEmpty else { return addition }
    guard !addition.isEmpty else { return existing }
    guard existing.last?.isWhitespace != true else { return existing + addition }

    let punctuationWithoutLeadingSpace = CharacterSet(charactersIn: ",.;:!?%…)]}")
    if let firstScalar = addition.unicodeScalars.first,
      punctuationWithoutLeadingSpace.contains(firstScalar)
    {
      return existing + addition
    }
    return existing + " " + addition
  }

  private static let emptySnapshot = LiveTranscriptSnapshot(
    finalizedText: "",
    interimText: nil,
    displayText: "",
    languageCode: nil
  )
}

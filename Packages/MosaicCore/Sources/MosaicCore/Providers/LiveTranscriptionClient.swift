import Foundation

/// Controls how Gemini Live balances literal transcription against readability.
public enum LiveTranscriptionMode: String, Codable, Hashable, Sendable {
  case verbatim = "VERBATIM"
  case smart = "SMART"
}

/// Provider-independent options for a live transcription session.
public struct LiveTranscriptionConfiguration: Codable, Hashable, Sendable {
  public static let maximumLanguageCount = 8
  public static let maximumVocabularyCount = 1_000
  public static let maximumVocabularyEntryBytes = 128
  public static let maximumVocabularyBytes = 128 * 1_024

  public let languageCodes: [String]
  public let mode: LiveTranscriptionMode
  public let customVocabulary: [String]

  /// An empty language list asks the provider to detect the language. Language identifiers use
  /// BCP-47 syntax, for example `tr-TR` or `en-US`.
  public init(
    languageCodes: [String] = [],
    mode: LiveTranscriptionMode = .smart,
    customVocabulary: [String] = []
  ) throws {
    guard languageCodes.count <= Self.maximumLanguageCount else {
      throw LiveTranscriptionError.invalidConfiguration(
        "Live transcription supports at most \(Self.maximumLanguageCount) language hints."
      )
    }
    guard languageCodes.allSatisfy(Self.isValidLanguageCode) else {
      throw LiveTranscriptionError.invalidConfiguration(
        "Language hints must be valid BCP-47 identifiers."
      )
    }
    guard customVocabulary.count <= Self.maximumVocabularyCount else {
      throw LiveTranscriptionError.invalidConfiguration(
        "Custom vocabulary supports at most \(Self.maximumVocabularyCount) entries."
      )
    }

    let normalizedVocabulary = customVocabulary.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard
      normalizedVocabulary.allSatisfy({
        !$0.isEmpty && $0.utf8.count <= Self.maximumVocabularyEntryBytes
      })
    else {
      throw LiveTranscriptionError.invalidConfiguration(
        "Custom vocabulary entries must be non-empty and at most \(Self.maximumVocabularyEntryBytes) bytes."
      )
    }
    guard normalizedVocabulary.reduce(0, { $0 + $1.utf8.count }) <= Self.maximumVocabularyBytes
    else {
      throw LiveTranscriptionError.invalidConfiguration(
        "Custom vocabulary exceeds the live transcription size limit."
      )
    }

    self.languageCodes = languageCodes
    self.mode = mode
    self.customVocabulary = normalizedVocabulary
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      languageCodes: try container.decodeIfPresent([String].self, forKey: .languageCodes) ?? [],
      mode: try container.decodeIfPresent(LiveTranscriptionMode.self, forKey: .mode) ?? .smart,
      customVocabulary: try container.decodeIfPresent([String].self, forKey: .customVocabulary)
        ?? []
    )
  }

  private static func isValidLanguageCode(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 63 else { return false }
    guard value.first != "-", value.last != "-" else { return false }
    var previousWasHyphen = false
    for scalar in value.unicodeScalars {
      let isASCIILetter = (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
      let isDigit = (48...57).contains(scalar.value)
      let isHyphen = scalar.value == 45
      guard isASCIILetter || isDigit || isHyphen else { return false }
      guard !(isHyphen && previousWasHyphen) else { return false }
      previousWasHyphen = isHyphen
    }
    return true
  }

  private enum CodingKeys: String, CodingKey {
    case languageCodes
    case mode
    case customVocabulary
  }
}

/// A bounded packet of raw 16-bit little-endian, mono, 16 kHz PCM audio.
public struct LivePCM16AudioChunk: Hashable, Sendable {
  public static let sampleRate = 16_000
  public static let channelCount = 1
  public static let bytesPerFrame = 2
  public static let maximumFrameCount = 2_048

  public let data: Data

  public init(data: Data) throws {
    guard !data.isEmpty else {
      throw LiveTranscriptionError.invalidAudioChunk("An audio chunk cannot be empty.")
    }
    guard data.count.isMultiple(of: Self.bytesPerFrame) else {
      throw LiveTranscriptionError.invalidAudioChunk(
        "PCM16 audio must contain complete two-byte frames."
      )
    }
    guard data.count <= Self.maximumFrameCount * Self.bytesPerFrame else {
      throw LiveTranscriptionError.invalidAudioChunk(
        "An audio chunk cannot exceed \(Self.maximumFrameCount) PCM frames."
      )
    }
    self.data = data
  }

  public var frameCount: Int {
    data.count / Self.bytesPerFrame
  }
}

public enum LiveTranscriptionEndReason: Hashable, Sendable {
  case cancelled
  case durationLimitReached
}

/// Events are deliberately independent from chat providers so dictated text can be sent to any
/// configured model after transcription.
public enum LiveTranscriptionEvent: Hashable, Sendable {
  case setupComplete
  case interimTranscript(text: String, languageCode: String?)
  case finalTranscript(text: String, languageCode: String?)
  case turnComplete
  case durationLimitApproaching(timeLeftSeconds: Double)
  case goAway(timeLeftSeconds: Double?)
  case ended(reason: LiveTranscriptionEndReason)
}

public enum LiveTranscriptionFinalizationResult: Hashable, Sendable {
  /// Gemini emitted a final transcript after Mosaic closed the audio stream.
  case finalTranscriptReceived
  /// Gemini confirmed that the current turn completed after Mosaic closed the audio stream.
  case turnCompleted
  /// The bounded drain elapsed without a speculative transcript left unresolved.
  case nothingPending
  /// The bounded drain elapsed while an interim transcript was still unresolved.
  case timedOut

  public var mayHaveUnconfirmedWords: Bool { self == .timedOut }
}

public enum LiveTranscriptionError: Error, Equatable, Sendable {
  case missingAPIKey
  case invalidConfiguration(String)
  case invalidAudioChunk(String)
  case setupNotComplete
  case setupTimedOut
  case sessionEnded
  case finalizationTimedOut
  case backgroundFinalizationExpired
  case backpressure
  case responseTooLarge
  case invalidResponse
  case provider(String)
  case transport(String)
}

extension LiveTranscriptionError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      "Add a Google API key before starting live transcription."
    case .invalidConfiguration(let message), .invalidAudioChunk(let message):
      message
    case .setupNotComplete:
      "Live transcription is still connecting. Wait for setupComplete before sending audio."
    case .setupTimedOut:
      "Gemini Live did not finish setting up the transcription session in time."
    case .sessionEnded:
      "This live transcription session has ended."
    case .finalizationTimedOut:
      "Gemini Live did not confirm the final transcript before the session closed. Finalized text remains in the draft, but the last unconfirmed words may be missing."
    case .backgroundFinalizationExpired:
      "iOS ended Turing AI’s background time before Gemini Live confirmed the final transcript. Finalized text remains in the draft, but the last unconfirmed words may be missing."
    case .backpressure:
      "Live transcription could not keep up with the audio stream."
    case .responseTooLarge:
      "The live transcription response exceeded Turing AI’s safety limit."
    case .invalidResponse:
      "Gemini Live returned a response Turing AI could not read."
    case .provider(let message), .transport(let message):
      message
    }
  }
}

public protocol LiveTranscriptionSession: Sendable {
  func eventStream() async -> AsyncThrowingStream<LiveTranscriptionEvent, Error>
  func send(_ chunk: LivePCM16AudioChunk) async throws
  /// Signals the end of audio and drains provider events up to a bounded deadline. The result
  /// distinguishes confirmed completion and silence from an unresolved interim hypothesis.
  func endAudio() async throws -> LiveTranscriptionFinalizationResult
  func cancel() async
}

public protocol LiveTranscriptionClient: Sendable {
  func connect(
    apiKey: String,
    configuration: LiveTranscriptionConfiguration
  ) async throws -> any LiveTranscriptionSession
}

extension LiveTranscriptionClient {
  public func connect(apiKey: String) async throws -> any LiveTranscriptionSession {
    try await connect(
      apiKey: apiKey,
      configuration: LiveTranscriptionConfiguration()
    )
  }
}

import CoreFoundation
import Foundation

public struct VoiceTokenUsage: Codable, Hashable, Sendable {
  public var input: Int?
  public var output: Int?
  public var inputText: Int?
  public var inputAudio: Int?
  public var outputText: Int?
  public var outputAudio: Int?
  public var cachedText: Int?
  public var cachedAudio: Int?
  public var seconds: Double?
  public init(
    input: Int? = nil, output: Int? = nil, inputText: Int? = nil, inputAudio: Int? = nil,
    outputText: Int? = nil, outputAudio: Int? = nil, cachedText: Int? = nil,
    cachedAudio: Int? = nil, seconds: Double? = nil
  ) {
    self.input = input
    self.output = output
    self.inputText = inputText
    self.inputAudio = inputAudio
    self.outputText = outputText
    self.outputAudio = outputAudio
    self.cachedText = cachedText
    self.cachedAudio = cachedAudio
    self.seconds = seconds
  }
  public func validate() throws {
    guard
      [input, output, inputText, inputAudio, outputText, outputAudio, cachedText, cachedAudio]
        .allSatisfy({ $0 == nil || (0...1_000_000_000).contains($0!) }),
      seconds.map({ $0.isFinite && (0...86400).contains($0) }) ?? true
    else { throw VoiceError.invalidResponse }
  }
  public mutating func add(_ other: Self) {
    func sum(_ a: Int?, _ b: Int?) -> Int? {
      guard let a, let b else { return nil }
      return min(1_000_000_000, a + b)
    }
    input = sum(input, other.input)
    output = sum(output, other.output)
    inputText = sum(inputText, other.inputText)
    inputAudio = sum(inputAudio, other.inputAudio)
    outputText = sum(outputText, other.outputText)
    outputAudio = sum(outputAudio, other.outputAudio)
    cachedText = sum(cachedText, other.cachedText)
    cachedAudio = sum(cachedAudio, other.cachedAudio)
  }
}
public struct VoiceUsageEntry: Codable, Hashable, Sendable, Identifiable {
  public var id: UUID
  public var providerID: UUID
  public var provider: String
  public var host: String
  public var model: String
  public var category: String
  public var date: Date
  public var revision: Int
  public var finished: Bool
  public var tokens: VoiceTokenUsage
  public init(id: UUID = UUID(), choice: WatchModel, category: String, date: Date = .now) {
    self.id = id
    providerID = choice.endpoint.id
    provider = choice.endpoint.provider
    host = choice.endpoint.baseURL.host ?? ""
    model = choice.model
    self.category = category
    self.date = date
    revision = 0
    finished = false
    tokens = VoiceTokenUsage()
  }
  public func validate() throws {
    guard
      [
        "Watch chat", "Watch live", "Watch transcription", "Watch speech",
        "Watch live transcription",
      ].contains(category),
      !model.isEmpty, model.utf8.count <= 512, provider.utf8.count <= 128, !host.isEmpty,
      host.utf8.count <= 253,
      date.timeIntervalSinceReferenceDate.isFinite, (0...100_000).contains(revision)
    else { throw VoiceError.invalidConfiguration }
    try tokens.validate()
  }
}
public struct VoiceTextResult: Sendable {
  public let text: String
  public let usage: VoiceTokenUsage
}
public struct VoiceSpeechResult: Sendable {
  public let audio: Data
  public let usage: VoiceTokenUsage
}

public enum VoiceUsageWire {
  private static func count(_ object: [String: Any], _ key: String) -> Int? {
    guard let n = object[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
      n.doubleValue.isFinite, n.doubleValue == Double(n.intValue),
      (0...1_000_000_000).contains(n.intValue)
    else { return nil }
    return n.intValue
  }
  public static func parse(_ object: [String: Any], provider: String, live: Bool = false)
    -> VoiceTokenUsage
  {
    var usage = VoiceTokenUsage()
    if provider == "google" {
      usage.input = count(object, "promptTokenCount")
      if let output = count(object, live ? "responseTokenCount" : "candidatesTokenCount") {
        usage.output = output + (count(object, "thoughtsTokenCount") ?? 0)
      }
      func modality(_ key: String, _ name: String) -> Int? {
        guard let entries = object[key] as? [[String: Any]] else { return nil }
        return entries.filter { $0["modality"] as? String == name }.reduce(0) {
          $0 + (count($1, "tokenCount") ?? 0)
        }
      }
      usage.inputText = modality("promptTokensDetails", "TEXT")
      usage.inputAudio = modality("promptTokensDetails", "AUDIO")
      usage.outputText = modality("responseTokensDetails", "TEXT").map {
        $0 + (count(object, "thoughtsTokenCount") ?? 0)
      }
      usage.outputAudio = modality("responseTokensDetails", "AUDIO")
      let cached = count(object, "cachedContentTokenCount") ?? 0
      usage.cachedText = cached == 0 ? 0 : modality("cacheTokensDetails", "TEXT")
      usage.cachedAudio = cached == 0 ? 0 : modality("cacheTokensDetails", "AUDIO")
    } else {
      usage.input = count(object, "input_tokens") ?? count(object, "prompt_tokens")
      usage.output = count(object, "output_tokens") ?? count(object, "completion_tokens")
      if provider == "anthropic", let input = usage.input {
        usage.input =
          input + (count(object, "cache_read_input_tokens") ?? 0)
          + (count(object, "cache_creation_input_tokens") ?? 0)
      }
      let details =
        object["input_token_details"] as? [String: Any] ?? object["input_tokens_details"]
        as? [String: Any] ?? [:]
      let outputs = object["output_token_details"] as? [String: Any] ?? [:]
      usage.inputText = count(details, "text_tokens")
      usage.inputAudio = count(details, "audio_tokens")
      usage.outputText = count(outputs, "text_tokens")
      usage.outputAudio = count(outputs, "audio_tokens")
      let cached = details["cached_tokens_details"] as? [String: Any] ?? [:]
      let cachedCount = count(details, "cached_tokens") ?? 0
      usage.cachedText = cachedCount == 0 ? 0 : count(cached, "text_tokens")
      usage.cachedAudio = cachedCount == 0 ? 0 : count(cached, "audio_tokens")
      if let seconds = object["seconds"] as? Double, seconds.isFinite, seconds >= 0 {
        usage.seconds = seconds
      }
    }
    return usage
  }
  public static func response(_ data: Data, provider: String) throws -> VoiceTokenUsage {
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    return parse(
      object[provider == "google" ? "usageMetadata" : "usage"] as? [String: Any] ?? [:],
      provider: provider)
  }
  public static func speechEvents(_ data: Data) throws -> VoiceSpeechResult {
    guard let text = String(data: data, encoding: .utf8) else { throw VoiceError.invalidResponse }
    var audio = Data()
    var usage = VoiceTokenUsage()
    var done = false
    for line in text.split(separator: "\n") where line.hasPrefix("data:") {
      let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
      if payload == "[DONE]" { continue }
      let object =
        try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] ?? [:]
      switch object["type"] as? String {
      case "speech.audio.delta":
        guard let value = object["audio"] as? String, let bytes = Data(base64Encoded: value),
          audio.count + bytes.count <= 8_388_608
        else { throw VoiceError.invalidResponse }
        audio.append(bytes)
      case "speech.audio.done":
        usage = parse(object["usage"] as? [String: Any] ?? [:], provider: "openai")
        done = true
        // Speech API output is all audio; input modality details may be omitted for text-only input.
        usage.inputText = usage.inputText ?? usage.input
        usage.inputAudio = usage.inputAudio ?? 0
        usage.outputAudio = usage.outputAudio ?? usage.output
        usage.outputText = usage.outputText ?? 0
      case "error": throw VoiceError.invalidResponse
      default: break
      }
    }
    guard done, !audio.isEmpty else { throw VoiceError.invalidResponse }
    try usage.validate()
    return VoiceSpeechResult(audio: audio, usage: usage)
  }
}

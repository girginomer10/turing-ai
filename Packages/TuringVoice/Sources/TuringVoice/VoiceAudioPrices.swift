import Foundation

/// Official standard paid-tier rates reviewed 2026-09-06. No account discounts or billing claims.
public enum VoiceAudioPrices {
  public static let verifiedAt = "2026-09-06"
  public static let validUntil = Date(timeIntervalSince1970: 1_791_244_800)  // 2026-10-06 UTC
  public static func source(provider: String) -> URL {
    URL(
      string: provider == "google"
        ? "https://ai.google.dev/gemini-api/docs/pricing"
        : "https://developers.openai.com/api/docs/pricing")!
  }
  public static func estimate(_ entry: VoiceUsageEntry, now: Date = .now) -> Double? {
    guard now < validUntil, (try? entry.validate()) != nil else { return nil }
    let t = entry.tokens
    if entry.provider == "openai", entry.host == "api.openai.com" {
      if entry.model == "gpt-transcribe" {
        guard let seconds = t.seconds else { return nil }
        return seconds / 60 * 0.0045
      }
      if entry.model == "gpt-4o-mini-tts" {
        guard let input = t.input, let output = t.output else { return nil }
        return (Double(input) * 0.6 + Double(output) * 12) / 1_000_000
      }
      if entry.model == "gpt-4o-mini-transcribe" {
        guard let input = t.input, let output = t.output, let text = t.inputText,
          let audio = t.inputAudio, text + audio == input
        else { return nil }
        return (Double(text) * 1.25 + Double(audio) * 1.25 + Double(output) * 5) / 1_000_000
      }
      if entry.model == "gpt-realtime-2.1" {
        return multimodal(
          t, textIn: 4, audioIn: 32, textOut: 24, audioOut: 64, cachedText: 0.4, cachedAudio: 0.4)
      }
      if entry.model == "gpt-realtime-2.1-mini" {
        return multimodal(
          t, textIn: 0.6, audioIn: 10, textOut: 2.4, audioOut: 20, cachedText: 0.06,
          cachedAudio: 0.3)
      }
    }
    if entry.provider == "google", entry.host == "generativelanguage.googleapis.com",
      entry.model == "gemini-3.1-flash-live-preview",
      t.cachedText == 0, t.cachedAudio == 0
    {
      return multimodal(
        t, textIn: 0.75, audioIn: 3, textOut: 4.5, audioOut: 12, cachedText: 0, cachedAudio: 0)
    }
    return nil
  }
  private static func multimodal(
    _ t: VoiceTokenUsage, textIn: Double, audioIn: Double, textOut: Double, audioOut: Double,
    cachedText: Double, cachedAudio: Double
  ) -> Double? {
    guard let input = t.input, let output = t.output, let it = t.inputText, let ia = t.inputAudio,
      let ot = t.outputText, let oa = t.outputAudio, let ct = t.cachedText, let ca = t.cachedAudio,
      it + ia == input, ot + oa == output, ct <= it, ca <= ia
    else { return nil }
    return
      (Double(it - ct) * textIn + Double(ia - ca) * audioIn + Double(ot) * textOut + Double(oa)
      * audioOut + Double(ct) * cachedText + Double(ca) * cachedAudio) / 1_000_000
  }
}

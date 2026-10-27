import Foundation

public struct WebSource: Codable, Hashable, Sendable {
  public var title: String
  public var url: String
  public var start: Int?
  public var end: Int?
  var isValid: Bool {
    guard title.utf8.count <= 2048, url.utf8.count <= 8192,
      let value = URL(string: url), ["https", "http"].contains(value.scheme?.lowercased() ?? ""),
      value.host?.isEmpty == false, value.user == nil, value.password == nil,
      !url.contains("<"), !url.contains(">"), !url.contains("\n")
    else { return false }
    return (start ?? 0) >= 0 && (end ?? 0) >= 0 && (end ?? 0) <= 2_000_000
  }
}

enum WebSearchCapability {
  static func supports(_ provider: ProviderConnection) -> Bool {
    // Native tools only. Compatible gateways must not receive vendor-specific tool schemas.
    let host = provider.resolvedBaseURL?.host?.lowercased()
    let model = provider.modelIdentifier.lowercased()
    switch provider.provider {
    case .openAI:
      return host == "api.openai.com" && !model.contains("nano")
        && !model.contains("search-preview")
        && (model.hasPrefix("gpt-4.1") || model.hasPrefix("gpt-5") || model.hasPrefix("gpt-6")
          || model == "o3" || model == "o4-mini")
    case .anthropic:
      return host == "api.anthropic.com"
        && (model.hasPrefix("claude-sonnet-4") || model.hasPrefix("claude-opus-4")
          || model.hasPrefix("claude-haiku-4") || model.hasPrefix("claude-3-7"))
    default: return false
    }
  }
  static func source(_ object: [String: Any]) -> WebSource? {
    guard let url = object["url"] as? String else { return nil }
    let result = WebSource(
      title: String((object["title"] as? String ?? URL(string: url)?.host ?? "Source").prefix(500)),
      url: url, start: object["start_index"] as? Int, end: object["end_index"] as? Int)
    return result.isValid ? result : nil
  }
  static func annotated(_ text: String, sources: [WebSource]) -> String {
    // Keep the raw answer immutable. Citations become visible native Markdown links in UI.
    let scalars = Array(text.unicodeScalars)
    var inserts: [Int: [String]] = [:]
    for (index, source) in sources.enumerated() where source.isValid {
      let position = min(max(0, source.end ?? scalars.count), scalars.count)
      inserts[position, default: []].append(" [\(index + 1)](<\(source.url)>)")
    }
    var result = ""
    for i in 0...scalars.count {
      result += inserts[i]?.joined() ?? ""
      if i < scalars.count { result.unicodeScalars.append(scalars[i]) }
    }
    return result
  }
}

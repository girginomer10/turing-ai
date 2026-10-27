import Foundation

enum MemoryRecallQuery {
  /// A short referential question can borrow its subject from recent user turns. Assistant text
  /// never supplies evidence, and self-contained questions keep their original retrieval query.
  static func make(current: String, messages: [AIChatMessage]) -> String {
    let normalized = current.lowercased(with: Locale(identifier: "tr_TR"))
      .folding(
        options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "tr_TR"))
    let words = normalized.split(whereSeparator: { !$0.isLetter }).map(String.init)
    let references: Set<String> = [
      "onlar", "onlara", "onlari", "onlarin", "bunlar", "bunlara",
      "bunlari", "bunlarin", "kucukler", "kucuklere", "kucuklerin", "them", "their", "those",
      "these",
    ]
    guard current.count <= 240, !references.isDisjoint(with: words) else { return current }
    let users = messages.filter { $0.role == .user }
    let previous = users.last?.content == current ? Array(users.dropLast()) : users
    let context = previous.suffix(2).map { String($0.content.prefix(450)) }
    guard !context.isEmpty else { return current }
    return current + "\nRecent user context:\n" + context.joined(separator: "\n")
  }
}

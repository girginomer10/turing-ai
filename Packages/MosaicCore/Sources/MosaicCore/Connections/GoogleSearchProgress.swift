import Foundation

/// Emitted by actual planner/list/read work, never by a simulated progress timer.
enum GoogleSearchProgress: Equatable, Sendable {
  case connection(String)
  case evaluating
  case summarizing
  case planning
  case searching(GoogleService)
  case reading(GoogleService, current: Int, total: Int)

  var title: String {
    switch self {
    case .connection(let title): title
    case .evaluating: "Finding relevant emails…"
    case .summarizing: "Summarizing email findings…"
    case .planning: "Preparing search…"
    case .searching(let service): "Searching \(service.title)…"
    case .reading(let service, let current, let total):
      service == .gmail
        ? "Reading email \(current) of \(total)…"
        : "Opening file \(current) of \(total)…"
    }
  }
}

struct MessageSearchActivity: Equatable {
  let messageID: UUID
  let progress: GoogleSearchProgress
}

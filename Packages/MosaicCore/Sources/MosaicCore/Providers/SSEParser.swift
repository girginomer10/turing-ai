import Foundation

struct ServerSentEvent: Equatable, Sendable {
  let name: String?
  let data: String
  let id: String?
}

struct SSEParser: Sendable {
  private var eventName: String?
  private var eventID: String?
  private var dataLines: [String] = []

  mutating func consume(line: String) -> ServerSentEvent? {
    if line.isEmpty {
      guard eventName != nil || eventID != nil || !dataLines.isEmpty else { return nil }
      defer { reset() }
      return ServerSentEvent(name: eventName, data: dataLines.joined(separator: "\n"), id: eventID)
    }

    guard !line.hasPrefix(":") else { return nil }
    let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let field = String(parts[0])
    var value = parts.count > 1 ? String(parts[1]) : ""
    if value.first == " " { value.removeFirst() }

    switch field {
    case "event": eventName = value
    case "data": dataLines.append(value)
    case "id": eventID = value
    default: break
    }
    return nil
  }

  mutating func finish() -> ServerSentEvent? {
    consume(line: "")
  }

  private mutating func reset() {
    eventName = nil
    eventID = nil
    dataLines.removeAll(keepingCapacity: true)
  }
}

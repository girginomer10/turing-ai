import Foundation

struct CloudConflict: Identifiable, Codable, Sendable {
  var id: String { key }
  let key: String
  let local: CloudEntry
  let remote: CloudEntry
  var title: String { key.components(separatedBy: "/").first ?? "Item" }
  static func preview(_ entry: CloudEntry) -> String {
    guard let data = entry.value else { return "Deleted on this device" }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return "Saved item"
    }
    let text = ["title", "name", "displayName", "modelIdentifier", "draftText", "content"]
      .compactMap { object[$0] as? String }.filter { !$0.isEmpty }.joined(separator: "\n")
    return text.isEmpty ? "Saved \(data.count.formatted()) bytes" : String(text.prefix(1200))
  }
}
struct CloudConflictResolution: Codable, Sendable {
  let local: CloudEntry
  let remote: CloudEntry
  let useLocal: Bool
}
extension CloudDeviceState {
  func conflicts(with remote: CloudLibraryEnvelope) -> [CloudConflict] {
    remote.entries.compactMap { key, incoming in
      guard let local = envelope.entries[key], local.value != incoming.value,
        local.revision != incoming.revision,
        local.revision != acknowledged?[key], incoming.revision != acknowledged?[key],
        local.revision.device == deviceID
      else { return nil }
      if let choice = resolutions?[key], choice.local == local, choice.remote == incoming {
        return nil
      }
      return CloudConflict(key: key, local: local, remote: incoming)
    }.sorted { $0.key < $1.key }
  }
  mutating func applyResolutions(for remote: CloudLibraryEnvelope) throws {
    for (key, resolution) in resolutions ?? [:] {
      guard envelope.entries[key] == resolution.local, remote.entries[key] == resolution.remote
      else { continue }
      let maximum = max(counter, remote.entries.values.map(\.revision.counter).max() ?? 0)
      guard maximum < UInt64.max else { throw MosaicPortableBackupError.malformedEnvelope }
      counter = maximum + 1
      envelope.entries[key] = CloudEntry(
        revision: CloudRevision(counter: counter, device: deviceID),
        value: resolution.useLocal ? resolution.local.value : resolution.remote.value)
    }
    resolutions = nil
  }
}

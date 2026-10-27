import Foundation

/// Compiled directly into the small Share Extension as well as MosaicCore. The extension
/// cannot read the main library or Keychain; it only deposits a bounded, atomic inbox item.
struct SharedInboxItem: Codable, Identifiable, Sendable {
  struct File: Codable, Sendable {
    var storedName: String
    var displayName: String
  }
  var id: UUID
  var createdAt: Date
  var prompt: String
  var files: [File]
}
enum SharedInbox {
  static let group = "group.com.omergirgin.mosaic"
  static func directory() throws -> URL {
    guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    return group.appendingPathComponent("SharedInbox", isDirectory: true)
  }
  static func items(in directory: URL) throws -> [SharedInboxItem] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { UUID(uuidString: $0.lastPathComponent) != nil }.compactMap { url in
      let manifest = url.appendingPathComponent("item.json")
      guard let size = try? manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size <= 64_000
      else { return nil }
      let item = try JSONDecoder().decode(SharedInboxItem.self, from: Data(contentsOf: manifest))
      guard item.id.uuidString == url.lastPathComponent, item.files.count <= 4,
        item.prompt.utf8.count <= 32_000,
        item.files.allSatisfy({
          $0.storedName == URL(fileURLWithPath: $0.storedName).lastPathComponent
            && !$0.storedName.hasPrefix(".") && !$0.storedName.contains("/")
            && $0.displayName.utf8.count <= 1024
        })
      else { throw CocoaError(.fileReadCorruptFile) }
      return item
    }.sorted { $0.createdAt < $1.createdAt }
  }
  static func remove(_ id: UUID, in directory: URL) throws {
    try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString))
  }
}

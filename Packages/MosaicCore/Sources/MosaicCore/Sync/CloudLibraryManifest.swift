import CryptoKit
import Foundation

/// One CAS-protected manifest points to immutable, content-addressed assets. A failed or
/// interrupted upload cannot publish a partial graph; unreferenced blobs are harmless.
struct CloudLibraryManifest: Codable, Sendable {
  struct Item: Codable, Hashable, Sendable {
    var revision: CloudRevision
    var hash: String?
    var bytes: Int
  }
  var format = "turing-library-v2"
  var items: [String: Item]
  static let maximumBytes = 128 * 1_024 * 1_024
  static let maximumManifestBytes = 32 * 1_024 * 1_024
  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  init(_ envelope: CloudLibraryEnvelope) throws {
    guard envelope.version == 1 else { throw MosaicPortableBackupError.malformedEnvelope }
    items = envelope.entries.mapValues {
      Item(revision: $0.revision, hash: $0.value.map(Self.hash), bytes: $0.value?.count ?? 0)
    }
    try validate()
  }
  func validate() throws {
    guard format == "turing-library-v2", items.count <= 100_000 else {
      throw MosaicPortableBackupError.malformedEnvelope
    }
    var total = 0
    for (key, item) in items {
      guard key.utf8.count <= 1024,
        CloudLibraryMerge.collections.contains(String(key.split(separator: "/").first ?? "")),
        item.bytes >= 0, item.bytes <= 8 * 1_024 * 1_024,
        item.bytes <= Self.maximumBytes - total,
        item.hash.map({ $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } })
          ?? (item.bytes == 0)
      else {
        throw ChatAttachmentFailure(
          message:
            "This library exceeds the 128 MB sync limit or contains invalid records. Local data is unchanged."
        )
      }
      total += item.bytes
    }
  }
  func envelope(values: [String: Data]) throws -> CloudLibraryEnvelope {
    try validate()
    var envelope = CloudLibraryEnvelope()
    for (key, item) in items {
      var data: Data?
      if let hash = item.hash {
        guard let value = values[hash], value.count == item.bytes, Self.hash(value) == hash else {
          throw MosaicPortableBackupError.malformedEnvelope
        }
        data = value
      }
      envelope.entries[key] = CloudEntry(revision: item.revision, value: data)
    }
    return envelope
  }
}

import Foundation

struct CloudRevision: Codable, Hashable, Comparable, Sendable {
  var counter: UInt64
  var device: UUID
  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.counter == rhs.counter
      ? lhs.device.uuidString < rhs.device.uuidString : lhs.counter < rhs.counter
  }
}
struct CloudEntry: Codable, Hashable, Sendable {
  var revision: CloudRevision
  /// Nil is a retained tombstone; an offline device must not resurrect deletions.
  var value: Data?
}
struct CloudLibraryEnvelope: Codable, Sendable {
  var version = 1
  var entries: [String: CloudEntry] = [:]
}
struct CloudDeviceState: Codable, Sendable {
  var version = 1
  var accountID: String
  var deviceID: UUID = UUID()
  var counter: UInt64 = 0
  var observed: [String: Data] = [:]
  var envelope = CloudLibraryEnvelope()
  var pendingAppliedRecords: [String: Data]?
  var acknowledged: [String: CloudRevision]?
  var resolutions: [String: CloudConflictResolution]?

  mutating func observe(_ snapshot: MosaicPortableBackupSnapshot) throws {
    let current = try CloudLibraryMerge.records(snapshot)
    // If replacement completed before a process exit, it is a receive, not a fresh local edit.
    if current == pendingAppliedRecords { observed = current }
    pendingAppliedRecords = nil
    let changed = Set(observed.keys).union(current.keys).filter { observed[$0] != current[$0] }
    if !changed.isEmpty {
      let maximum = max(counter, envelope.entries.values.map(\.revision.counter).max() ?? 0)
      guard maximum < UInt64.max else {
        throw ChatAttachmentFailure(message: "iCloud revision limit reached.")
      }
      counter = maximum + 1
      for key in changed {
        envelope.entries[key] = CloudEntry(
          revision: CloudRevision(counter: counter, device: deviceID), value: current[key])
      }
    }
    observed = current
  }
  mutating func merge(_ remote: CloudLibraryEnvelope) throws {
    guard remote.version == 1, remote.entries.count <= 1_000_000 else {
      throw ChatAttachmentFailure(message: "Update Turing AI to read this iCloud library.")
    }
    for (key, entry) in remote.entries {
      guard CloudLibraryMerge.collections.contains(String(key.split(separator: "/").first ?? "")),
        key.utf8.count <= 1024, entry.value?.count ?? 0 <= 8 * 1_024 * 1_024
      else { throw MosaicPortableBackupError.malformedEnvelope }
      if key.hasPrefix("extensionRecords/"), let data = entry.value,
        let item = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        CloudLibraryMerge.isLocalOnlyExtension(item)
      {
        throw MosaicPortableBackupError.malformedEnvelope
      }
      if let local = envelope.entries[key], local.revision >= entry.revision {
        guard local.revision != entry.revision || local.value == entry.value else {
          throw MosaicPortableBackupError.malformedEnvelope
        }
        continue
      }
      envelope.entries[key] = entry
      counter = max(counter, entry.revision.counter)
    }
  }
}

enum CloudLibraryMerge {
  static let collections = [
    "conversations", "messages", "memories", "providerConfigurations", "embeddingProfiles",
    "importedDocuments", "documentChunks", "requestContextEvents", "compactionArtifacts",
    "conversationCompactionHeads", "extensionRecords",
  ]
  static func canonical(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }
  static func isLocalOnlyExtension(_ item: [String: Any]) -> Bool {
    // Execution belongs to one device. Synchronizing pending jobs would run paid work twice.
    let type = item["recordType"] as? String ?? ""
    return type == "formation_job" || type == "formation_audit" || type == "task_model"
  }
  static func key(_ item: [String: Any], collection: String) throws -> String {
    let id = (item["id"] ?? item["conversationID"]) as? String
    guard let id else { throw MosaicPortableBackupError.malformedEnvelope }
    if collection == "extensionRecords" {
      guard let namespace = item["namespace"] as? String, let type = item["recordType"] as? String
      else { throw MosaicPortableBackupError.malformedEnvelope }
      return collection + "/" + namespace + "/" + type + "/" + id
    }
    return collection + "/" + id
  }
  static func records(_ snapshot: MosaicPortableBackupSnapshot) throws -> [String: Data] {
    let root =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
    var result: [String: Data] = [:]
    for collection in collections {
      for item in root[collection] as? [[String: Any]] ?? [] {
        if collection == "extensionRecords", isLocalOnlyExtension(item) { continue }
        let id = try key(item, collection: collection)
        guard result[id] == nil else { throw MosaicPortableBackupError.malformedEnvelope }
        result[id] = try canonical(item)
      }
    }
    return result
  }
  static func snapshot(_ envelope: CloudLibraryEnvelope, local: MosaicPortableBackupSnapshot) throws
    -> MosaicPortableBackupSnapshot
  {
    var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(local)) as! [String: Any]
    let localExtensions = (root["extensionRecords"] as? [[String: Any]] ?? []).filter(
      isLocalOnlyExtension)
    for collection in collections {
      var values: [[String: Any]] = []
      for (key, entry) in envelope.entries.sorted(by: { $0.key < $1.key })
      where key.hasPrefix(collection + "/") {
        guard let bytes = entry.value else { continue }
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          try self.key(value, collection: collection) == key
        else { throw MosaicPortableBackupError.malformedEnvelope }
        values.append(value)
      }
      root[collection] = values + (collection == "extensionRecords" ? localExtensions : [])
    }
    // A remote conversation deletion also retires this device's formation queue for it.
    // Jobs never cross devices and cannot survive without their exact source messages.
    let conversationIDs = Set(
      (root["conversations"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
    let messageIDs = Set(
      (root["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
    func payload(_ item: [String: Any]) throws -> [String: Any] {
      guard let raw = item["payload"] as? String, let data = Data(base64Encoded: raw),
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { throw MosaicPortableBackupError.malformedEnvelope }
      return result
    }
    var extensions = root["extensionRecords"] as? [[String: Any]] ?? []
    var survivingJobs: Set<String> = []
    extensions = try extensions.filter { item in
      guard item["namespace"] as? String == AutomaticMemoryPortableArchive.namespace,
        item["recordType"] as? String == "formation_job"
      else { return true }
      let value = try payload(item)
      let survives =
        conversationIDs.contains(value["conversationID"] as? String ?? "")
        && messageIDs.contains(value["throughUserMessageID"] as? String ?? "")
        && messageIDs.contains(value["assistantMessageID"] as? String ?? "")
      if survives, let id = item["id"] as? String { survivingJobs.insert(id) }
      return survives
    }
    extensions = try extensions.filter { item in
      guard item["namespace"] as? String == AutomaticMemoryPortableArchive.namespace,
        item["recordType"] as? String == "formation_audit"
      else { return true }
      return survivingJobs.contains(try payload(item)["jobID"] as? String ?? "")
    }
    root["extensionRecords"] = extensions
    root["backupID"] = local.backupID.uuidString
    root["sourceSchemaVersion"] = MosaicPortableBackup.sourceSchemaVersion
    return try JSONDecoder().decode(MosaicPortableBackupSnapshot.self, from: canonical(root))
  }
}

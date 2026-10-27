@preconcurrency import CloudKit
import Foundation

protocol ICloudLibraryTransporting: Sendable {
  func account() async throws -> String
  func fetch() async throws -> CloudLibraryEnvelope
  func save(_ envelope: CloudLibraryEnvelope) async throws
}

actor ICloudLibraryTransport: ICloudLibraryTransporting {
  static let containerIdentifier = "iCloud.com.omergirgin.mosaic"
  private var container: CKContainer { CKContainer(identifier: Self.containerIdentifier) }
  private let recordID = CKRecord.ID(recordName: "library-v1")
  private var fetchedRecord: CKRecord?
  private var knownHashes = Set<String>()
  private var accountID: String?
  private var cacheDirectory: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(
        "TuringCloud/" + CloudLibraryManifest.hash(Data((accountID ?? "unknown").utf8)))
  }
  func account() async throws -> String {
    guard try await container.accountStatus() == .available else {
      throw ChatAttachmentFailure(message: "Sign in to iCloud in system settings, then try again.")
    }
    let id = try await container.userRecordID().recordName
    if id != accountID {
      knownHashes = []
      fetchedRecord = nil
      accountID = id
    }
    return id
  }
  private func assetData(_ record: CKRecord, maximum: Int) throws -> Data {
    guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL,
      let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, count <= maximum
    else { throw MosaicPortableBackupError.malformedEnvelope }
    return try Data(contentsOf: url)
  }
  func fetch() async throws -> CloudLibraryEnvelope {
    let record: CKRecord
    do { record = try await container.privateCloudDatabase.record(for: recordID) } catch let error
      as CKError where error.code == .unknownItem
    {
      fetchedRecord = nil
      knownHashes = []
      return CloudLibraryEnvelope()
    }
    let data = try assetData(record, maximum: 50 * 1_024 * 1_024)
    if let legacy = try? JSONDecoder().decode(CloudLibraryEnvelope.self, from: data) {
      guard legacy.version == 1 else { throw MosaicPortableBackupError.malformedEnvelope }
      fetchedRecord = record
      knownHashes = []
      return legacy
    }
    let manifest = try JSONDecoder().decode(CloudLibraryManifest.self, from: data)
    try manifest.validate()
    let hashes = Set(manifest.items.values.compactMap(\.hash))
    let cache = cacheDirectory
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    var values: [String: Data] = [:]
    var missing: [String] = []
    for hash in hashes.sorted() {
      let file = cache.appendingPathComponent(hash)
      if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size <= 8 * 1_024 * 1_024,
        let bytes = try? Data(contentsOf: file), CloudLibraryManifest.hash(bytes) == hash
      {
        values[hash] = bytes
      } else {
        missing.append(hash)
      }
    }
    for offset in stride(from: 0, to: missing.count, by: 20) {
      try Task.checkCancellation()
      let batch = Array(missing[offset..<min(offset + 20, missing.count)])
      let ids = batch.map { CKRecord.ID(recordName: "blob-v2-" + $0) }
      let records = try await container.privateCloudDatabase.records(for: ids)
      for (hash, id) in zip(batch, ids) {
        guard let result = records[id] else { throw ProviderClientError.invalidResponse }
        let bytes = try assetData(result.get(), maximum: 8 * 1_024 * 1_024)
        guard CloudLibraryManifest.hash(bytes) == hash else {
          throw MosaicPortableBackupError.malformedEnvelope
        }
        values[hash] = bytes
        try bytes.write(to: cache.appendingPathComponent(hash), options: .atomic)
      }
    }
    let result = try manifest.envelope(values: values)
    fetchedRecord = record
    knownHashes = hashes
    // A cache is disposable. Retain only currently referenced values to bound local disk use.
    for url in try FileManager.default.contentsOfDirectory(
      at: cache, includingPropertiesForKeys: nil)
    where !hashes.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
    return result
  }
  func save(_ envelope: CloudLibraryEnvelope) async throws {
    guard let expectedAccount = accountID, try await account() == expectedAccount else {
      throw ProviderClientError.invalidResponse
    }
    let manifest = try CloudLibraryManifest(envelope)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(manifest)
    guard data.count <= CloudLibraryManifest.maximumManifestBytes else {
      throw ProviderClientError.responseTooLarge
    }
    var values: [String: Data] = [:]
    for entry in envelope.entries.values {
      if let bytes = entry.value { values[CloudLibraryManifest.hash(bytes)] = bytes }
    }
    let pending = values.keys.filter { !knownHashes.contains($0) }.sorted()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for offset in stride(from: 0, to: pending.count, by: 20) {
      try Task.checkCancellation()
      guard try await account() == expectedAccount else {
        throw ProviderClientError.invalidResponse
      }
      let batch = Array(pending[offset..<min(offset + 20, pending.count)])
      var records: [CKRecord] = []
      for hash in batch {
        let url = directory.appendingPathComponent(hash)
        try values[hash]!.write(to: url, options: .atomic)
        let record = CKRecord(
          recordType: "TuringLibrary", recordID: CKRecord.ID(recordName: "blob-v2-" + hash))
        record["payload"] = CKAsset(fileURL: url)
        records.append(record)
      }
      let result = try await container.privateCloudDatabase.modifyRecords(
        saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
      for record in records {
        guard let saved = result.saveResults[record.recordID] else {
          throw ProviderClientError.invalidResponse
        }
        do { _ = try saved.get() } catch let error as CKError
          where error.code == .serverRecordChanged
        {
          let existing = try await container.privateCloudDatabase.record(for: record.recordID)
          let bytes = try assetData(existing, maximum: 8 * 1_024 * 1_024)
          guard "blob-v2-" + CloudLibraryManifest.hash(bytes) == record.recordID.recordName else {
            throw MosaicPortableBackupError.malformedEnvelope
          }
        }
      }
      for hash in batch {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(hash))
      }
    }
    guard try await account() == expectedAccount else { throw ProviderClientError.invalidResponse }
    let url = directory.appendingPathComponent("manifest.json")
    try data.write(to: url, options: .atomic)
    let record = fetchedRecord ?? CKRecord(recordType: "TuringLibrary", recordID: recordID)
    record["payload"] = CKAsset(fileURL: url)
    // Single-record CAS publishes all new blobs together. Build 9 cannot decode this manifest
    // and therefore pauses before writing: an older client cannot overwrite a migrated library.
    let result = try await container.privateCloudDatabase.modifyRecords(
      saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
    guard let saved = result.saveResults[recordID] else {
      throw ProviderClientError.invalidResponse
    }
    fetchedRecord = try saved.get()
    knownHashes = Set(values.keys)
    let cache = cacheDirectory
    try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    for (hash, bytes) in values {
      if !FileManager.default.fileExists(atPath: cache.appendingPathComponent(hash).path) {
        try? bytes.write(to: cache.appendingPathComponent(hash), options: .atomic)
      }
    }
  }
}

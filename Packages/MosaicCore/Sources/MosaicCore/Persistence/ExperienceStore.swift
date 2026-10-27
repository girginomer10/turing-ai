import CryptoKit
import Foundation
import SwiftData
import TuringVoice

/// Additive V6 sidecar: never change hashes of already shipped source entities.
@Model
public final class ExperienceRecord {
  @Attribute(.unique) public var id: UUID
  public var payload: Data
  public var category: String
  public var ownerID: UUID?
  public var messageID: UUID?
  public init(
    id: UUID, payload: Data, category: String, ownerID: UUID? = nil, messageID: UUID? = nil
  ) {
    self.id = id
    self.payload = payload
    self.category = category
    self.ownerID = ownerID
    self.messageID = messageID
  }
}

struct ExperienceValue: Codable, Hashable, Sendable {
  enum Kind: String, Codable, Sendable {
    case model, projectDefault, attachment, branch, webSources, usage, watchReceipt
  }
  var id: UUID
  var kind: Kind
  var providerID: UUID?
  var model: String?
  var projectID: UUID?
  var favorite: Bool = false
  var lastUsed: Date?
  var supportsImages: Bool?
  var conversationID: UUID?
  var messageID: UUID?
  var filename: String?
  var mimeType: String?
  var bytes: Data?
  var extractedText: String?
  var branchGroupID: UUID?
  var originalConversationID: UUID?
  var inputPricePerMillion: Double?
  var outputPricePerMillion: Double?
  var sources: [WebSource]?
  var searchedServices: [GoogleService]?
  var searchNotice: String?
  var connectionActions: [ConnectionActionReceipt]?
  var watchUserMessageID: UUID?
  var watchAssistantMessageID: UUID?
  var watchUsage: VoiceUsageEntry?
  var usageCategory: String?
  var inputTokens: Int?
  var outputTokens: Int?
  var usageDate: Date?
  var usageProviderKind: ProviderKind?
  var usageProviderHost: String?
  var updatedAt: Date = .now

  static func modelID(_ key: String) -> UUID {
    let digest = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
    return UUID(
      uuid: (
        digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
        digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
      ))
  }
  static func preference(_ choice: ChatModelChoice) -> Self {
    Self(
      id: modelID(choice.id), kind: .model, providerID: choice.providerID,
      model: choice.modelIdentifier)
  }
  var selectionKey: String? {
    guard let providerID, let model else { return nil }
    return ProviderModelRecord.key(providerID: providerID, model: model)
  }
  var isImage: Bool { mimeType?.hasPrefix("image/") == true }
}

enum ExperienceStore {
  static func preferences(in context: ModelContext) throws -> [ExperienceValue] {
    try context.fetch(
      FetchDescriptor<ExperienceRecord>(
        predicate: #Predicate { $0.category == "model" || $0.category == "projectDefault" })
    ).map { try JSONDecoder().decode(ExperienceValue.self, from: $0.payload) }
  }
  static func values(in context: ModelContext) throws -> [ExperienceValue] {
    try context.fetch(FetchDescriptor<ExperienceRecord>()).map {
      try JSONDecoder().decode(ExperienceValue.self, from: $0.payload)
    }
  }
  static func save(_ value: ExperienceValue, in context: ModelContext) throws {
    let id = value.id
    _ = try ExperiencePortableArchive.decode(ExperiencePortableArchive.record(value))
    let data = try JSONEncoder().encode(value)
    let existing = try context.fetch(
      FetchDescriptor<ExperienceRecord>(predicate: #Predicate { $0.id == id })
    ).first
    if let existing {
      existing.payload = data
      existing.category = value.kind.rawValue
      existing.ownerID = value.conversationID
      existing.messageID = value.messageID
    } else {
      context.insert(
        ExperienceRecord(
          id: id, payload: data, category: value.kind.rawValue, ownerID: value.conversationID,
          messageID: value.messageID))
    }
  }
  static func remove(_ id: UUID, in context: ModelContext) throws {
    for row in try context.fetch(
      FetchDescriptor<ExperienceRecord>(predicate: #Predicate { $0.id == id }))
    { context.delete(row) }
  }
  static func defaultChoice(projectID: UUID?, choices: [ChatModelChoice], values: [ExperienceValue])
    -> ChatModelChoice?
  {
    let scopes: [UUID?] = projectID == nil ? [nil] : [projectID, nil]
    for scope in scopes {
      if let selected = values.first(where: { $0.kind == .projectDefault && $0.projectID == scope }
      ),
        let choice = choices.first(where: { $0.id == selected.selectionKey })
      {
        return choice
      }
    }
    let recent = values.filter { $0.kind == .model && $0.lastUsed != nil }.sorted {
      $0.lastUsed! > $1.lastUsed!
    }
    return recent.lazy.compactMap { value in choices.first { $0.id == value.selectionKey } }.first
      ?? choices.first
  }
}

/// One portable, validated extension namespace for attachment and chooser state.
enum ExperiencePortableArchive {
  static let namespace = "com.omergirgin.mosaic.experience"
  static func isOwned(_ record: MosaicPortableExtensionRecord) -> Bool {
    record.namespace == namespace
  }
  static func decode(_ record: MosaicPortableExtensionRecord) throws -> ExperienceValue {
    let value = try JSONDecoder().decode(ExperienceValue.self, from: record.payload)
    guard record.recordVersion == 1, record.recordType == value.kind.rawValue,
      record.id == value.id,
      value.model?.utf8.count ?? 0 <= 2048, value.filename?.utf8.count ?? 0 <= 1024,
      value.bytes?.count ?? 0 <= 1_048_576, value.extractedText?.utf8.count ?? 0 <= 800_000,
      value.updatedAt.timeIntervalSinceReferenceDate.isFinite,
      [value.inputPricePerMillion, value.outputPricePerMillion].allSatisfy({
        $0 == nil || ($0!.isFinite && $0! >= 0 && $0! <= 1_000_000)
      }),
      (value.sources?.count ?? 0) <= 100,
      (value.usageProviderHost?.utf8.count ?? 0) <= 253,
      value.lastUsed?.timeIntervalSinceReferenceDate.isFinite ?? true
    else { throw MosaicPortableBackupError.malformedEnvelope }
    if let actions = value.connectionActions {
      guard value.kind == .webSources, actions.count <= 20,
        Set(actions.map(\.id)).count == actions.count
      else { throw MosaicPortableBackupError.malformedEnvelope }
      for action in actions { try action.validate() }
    }
    if let notice = value.searchNotice {
      guard value.kind == .webSources, notice.utf8.count <= 1500 else {
        throw MosaicPortableBackupError.malformedEnvelope
      }
    }
    if let services = value.searchedServices {
      guard value.kind == .webSources, services.count <= 2, Set(services).count == services.count
      else { throw MosaicPortableBackupError.malformedEnvelope }
    }
    if let usage = value.watchUsage {
      try usage.validate()
      guard value.kind == .usage, value.id == usage.id, value.providerID == usage.providerID,
        value.model == usage.model, value.usageCategory == usage.category,
        value.inputTokens == usage.tokens.input, value.outputTokens == usage.tokens.output
      else { throw MosaicPortableBackupError.malformedEnvelope }
    }
    switch value.kind {
    case .model, .projectDefault:
      guard value.providerID != nil, value.model?.isEmpty == false, value.bytes == nil,
        value.extractedText == nil, value.conversationID == nil, value.messageID == nil,
        value.mimeType == nil, value.filename == nil
      else { throw MosaicPortableBackupError.malformedEnvelope }
    case .usage:
      guard value.providerID != nil, value.model != nil, value.usageCategory != nil,
        value.bytes == nil, value.extractedText == nil,
        value.usageDate?.timeIntervalSinceReferenceDate.isFinite == true,
        [value.inputTokens, value.outputTokens].allSatisfy({
          $0 == nil || (0...1_000_000_000).contains($0!)
        })
      else { throw MosaicPortableBackupError.malformedEnvelope }
    case .watchReceipt:
      guard value.originalConversationID != nil, value.conversationID == nil,
        value.messageID == nil,
        (value.watchUserMessageID == nil) == (value.watchAssistantMessageID == nil),
        value.bytes == nil, value.extractedText == nil
      else { throw MosaicPortableBackupError.malformedEnvelope }
    case .branch:
      guard value.conversationID != nil, value.branchGroupID != nil,
        value.bytes == nil, value.extractedText == nil, value.messageID == nil
      else { throw MosaicPortableBackupError.malformedEnvelope }
    case .webSources:
      guard value.conversationID != nil, value.messageID != nil, value.bytes == nil,
        value.sources?.allSatisfy({ $0.isValid }) == true
      else { throw MosaicPortableBackupError.malformedEnvelope }
    case .attachment:
      guard value.conversationID != nil, value.filename?.isEmpty == false,
        value.providerID == nil, value.model == nil, value.projectID == nil,
        value.mimeType?.isEmpty == false,
        !value.isImage || value.extractedText == nil,
        value.isImage
          ? (value.mimeType == "image/jpeg" && value.bytes?.isEmpty == false)
          : (value.bytes == nil && value.extractedText?.isEmpty == false)
      else { throw MosaicPortableBackupError.malformedEnvelope }
    }
    return value
  }
  static func record(_ value: ExperienceValue) throws -> MosaicPortableExtensionRecord {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return MosaicPortableExtensionRecord(
      namespace: namespace, recordType: value.kind.rawValue, recordVersion: 1, id: value.id,
      payload: try encoder.encode(value))
  }
  static func capture(
    from context: ModelContext, includesPendingChanges: Bool = false,
    limits: MosaicPortableBackupLimits = .default, honorsCancellation: Bool = true
  ) throws -> [MosaicPortableExtensionRecord] {
    var results: [MosaicPortableExtensionRecord] = []
    var bytes = 0
    var offset = 0
    while true {
      var descriptor = FetchDescriptor<ExperienceRecord>(sortBy: [SortDescriptor(\.id)])
      descriptor.includePendingChanges = includesPendingChanges
      descriptor.fetchLimit = 4
      descriptor.fetchOffset = offset
      let rows = try context.fetch(descriptor)
      if rows.isEmpty { break }
      for row in rows {
        if honorsCancellation { try Task.checkCancellation() }
        guard row.payload.count <= limits.maximumRecordBytes,
          row.payload.count <= limits.maximumTotalBytes - bytes,
          results.count < limits.maximumRecordCount
        else { throw MosaicPortableBackupError.malformedEnvelope }
        bytes += row.payload.count
        let value = try JSONDecoder().decode(ExperienceValue.self, from: row.payload)
        guard value.id == row.id, value.kind.rawValue == row.category,
          value.conversationID == row.ownerID, value.messageID == row.messageID
        else { throw MosaicPortableBackupError.malformedEnvelope }
        let result = try record(value)
        _ = try decode(result)
        results.append(result)
      }
      offset += rows.count
    }
    return results.sorted(by: MosaicPortableBackup.extensionRecordOrder)
  }

  static func validate(
    _ records: [MosaicPortableExtensionRecord], snapshot: MosaicPortableBackupSnapshot
  ) throws {
    let conversations = Set(snapshot.conversations.map(\.id))
    let messages = Dictionary(
      uniqueKeysWithValues: snapshot.messages.map { ($0.id, $0.conversationID) })
    for record in records {
      let value = try decode(record)
      if [.attachment, .branch, .webSources].contains(value.kind) {
        guard let conversationID = value.conversationID, conversations.contains(conversationID),
          value.messageID == nil || messages[value.messageID!] == conversationID
        else { throw MosaicPortableBackupError.malformedEnvelope }
      }
    }
  }
  static func remap(_ records: [MosaicPortableExtensionRecord], using ids: [UUID: UUID]) throws
    -> [MosaicPortableExtensionRecord]
  {
    try records.map {
      var value = try decode($0)
      if let id = value.providerID { value.providerID = ids[id] ?? id }
      if let id = value.watchUsage?.providerID { value.watchUsage?.providerID = ids[id] ?? id }
      if value.kind == .model, let key = value.selectionKey {
        value.id = ExperienceValue.modelID(key)
      }
      return try record(value)
    }
  }
  static func insert(_ records: [MosaicPortableExtensionRecord], into context: ModelContext) throws
  {
    for record in records {
      let value = try decode(record)
      try ExperienceStore.save(value, in: context)
    }
  }
  static func deleteAll(in context: ModelContext) throws {
    for row in try context.fetch(FetchDescriptor<ExperienceRecord>()) { context.delete(row) }
  }
}

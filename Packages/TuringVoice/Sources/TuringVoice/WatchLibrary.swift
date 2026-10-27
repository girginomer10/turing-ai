import CryptoKit
import Foundation
import Observation

public enum VoiceIdentity {
  public static func id(_ value: String) -> UUID {
    let b = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
    return UUID(
      uuid: (
        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13],
        b[14], b[15]
      ))
  }
  public static func bounded(_ text: String, bytes: Int) -> String {
    var result = ""
    var size = 0
    for c in text {
      let n = String(c).utf8.count
      if size + n > bytes { break }
      result.append(c)
      size += n
    }
    return result
  }
}

public struct WatchChat: Codable, Sendable, Identifiable, Equatable {
  public var id: UUID
  public var title: String
  public var providerID: UUID?
  public var model: String?
  public var knownToPhone: Bool
  public var createdAt: Date
  public var updatedAt: Date
  public var messages: [WatchMessage]
  public var draft: String
  public var deleted: Bool
  public init(
    id: UUID = UUID(), title: String = "New conversation", providerID: UUID? = nil,
    model: String? = nil, knownToPhone: Bool = false, createdAt: Date = .now,
    updatedAt: Date = .now, messages: [WatchMessage] = [], draft: String = "", deleted: Bool = false
  ) {
    self.id = id
    self.title = title
    self.providerID = providerID
    self.model = model
    self.knownToPhone = knownToPhone
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.messages = messages
    self.draft = draft
    self.deleted = deleted
  }
  public var isVisible: Bool { !deleted && (!messages.isEmpty || !draft.isEmpty || knownToPhone) }
  public func validate() throws {
    guard title.utf8.count <= 512, (model?.utf8.count ?? 0) <= 512, draft.utf8.count <= 16_384,
      createdAt.timeIntervalSinceReferenceDate.isFinite,
      updatedAt.timeIntervalSinceReferenceDate.isFinite,
      messages.count <= 1000, Set(messages.map(\.id)).count == messages.count
    else { throw VoiceError.invalidConfiguration }
    for m in messages { try m.validate() }
  }
}
public struct WatchMessage: Codable, Sendable, Identifiable, Equatable {
  public var id: UUID
  public var role: String
  public var text: String
  public var date: Date
  public var providerID: UUID?
  public var provider: String?
  public var providerName: String?
  public var host: String?
  public var model: String?
  public var replyTo: UUID?
  public var complete: Bool
  public var memoryIDs: [UUID]
  public init(
    id: UUID = UUID(), role: String, text: String, date: Date = .now, choice: WatchModel? = nil,
    replyTo: UUID? = nil, complete: Bool = true, memoryIDs: [UUID] = []
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.date = date
    self.providerID = choice?.endpoint.id
    self.provider = choice?.endpoint.provider
    self.providerName = choice?.endpoint.name
    self.host = choice?.endpoint.baseURL.host
    self.model = choice?.model
    self.replyTo = replyTo
    self.complete = complete
    self.memoryIDs = memoryIDs
  }
  public func validate() throws {
    guard ["user", "assistant"].contains(role), !text.isEmpty, text.utf8.count <= 16_384,
      date.timeIntervalSinceReferenceDate.isFinite, (model?.utf8.count ?? 0) <= 512,
      (providerName?.utf8.count ?? 0) <= 512, (host?.utf8.count ?? 0) <= 253,
      (provider?.utf8.count ?? 0) <= 128, memoryIDs.count <= 16
    else { throw VoiceError.invalidConfiguration }
  }
  public var turn: VoiceTurn { VoiceTurn(id: id, role: role, text: text) }
}
public struct WatchContext: Codable, Sendable {
  public var instructions: String
  public var offline: Bool = false
  public var memoryIDs: [UUID]
  public init(instructions: String = "", memoryIDs: [UUID] = [], offline: Bool = false) {
    self.instructions = instructions
    self.memoryIDs = memoryIDs
    self.offline = offline
  }
}
public struct WatchTransfer: Codable, Sendable, Identifiable, Equatable {
  public var id: UUID
  public var chat: WatchChat
  public var message: WatchMessage?
  public var usage: VoiceUsageEntry?
  public init(chat: WatchChat, message: WatchMessage? = nil, usage: VoiceUsageEntry? = nil) {
    self.id = UUID()
    self.chat = chat
    self.chat.messages = []
    self.chat.draft = ""
    self.message = message
    self.usage = usage
  }
}
public struct WatchSyncRequest: Codable, Sendable {
  public var version = 2
  public var operation: String
  public var chatID: UUID?
  public var newChat: Bool = false
  public var before: Date?
  public var beforeID: UUID?
  public var query: String?
  public var providerID: UUID?
  public var model: String?
  public var transfer: WatchTransfer?
  public init(
    operation: String, chatID: UUID? = nil, newChat: Bool = false, before: Date? = nil,
    beforeID: UUID? = nil, query: String? = nil, providerID: UUID? = nil, model: String? = nil,
    transfer: WatchTransfer? = nil
  ) {
    self.operation = operation
    self.chatID = chatID
    self.newChat = newChat
    self.before = before
    self.beforeID = beforeID
    self.query = query
    self.providerID = providerID
    self.model = model
    self.transfer = transfer
  }
}
public struct WatchSyncReply: Codable, Sendable {
  public var version = 2
  public var status: String
  public var acknowledged: UUID?
  public var chats: [WatchChat]
  public var context: WatchContext?
  public var nextPage: Date?
  public var nextPageID: UUID?
  public init(
    status: String = "ok", acknowledged: UUID? = nil, chats: [WatchChat] = [],
    context: WatchContext? = nil, nextPage: Date? = nil, nextPageID: UUID? = nil
  ) {
    self.status = status
    self.acknowledged = acknowledged
    self.chats = chats
    self.context = context
    self.nextPage = nextPage
    self.nextPageID = nextPageID
  }
}
public enum WatchSyncWire {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let data = try JSONEncoder().encode(value)
    guard data.count <= 60_000 else { throw VoiceError.responseTooLarge }
    return data
  }
  public static func request(_ data: Data) throws -> WatchSyncRequest {
    guard data.count <= 60_000 else { throw VoiceError.responseTooLarge }
    let value = try JSONDecoder().decode(WatchSyncRequest.self, from: data)
    guard value.version == 2, ["list", "context", "upload"].contains(value.operation),
      (value.query?.utf8.count ?? 0) <= 16_384, (value.model?.utf8.count ?? 0) <= 512,
      value.before?.timeIntervalSinceReferenceDate.isFinite ?? true
    else { throw VoiceError.invalidConfiguration }
    if let t = value.transfer {
      try t.chat.validate()
      try t.message?.validate()
      try t.usage?.validate()
      guard t.chat.messages.isEmpty, t.chat.draft.isEmpty, (t.message != nil) != (t.usage != nil)
      else { throw VoiceError.invalidConfiguration }
    }
    guard value.operation != "upload" || value.transfer != nil else {
      throw VoiceError.invalidConfiguration
    }
    return value
  }
  public static func reply(_ data: Data) throws -> WatchSyncReply {
    guard data.count <= 60_000 else { throw VoiceError.responseTooLarge }
    let value = try JSONDecoder().decode(WatchSyncReply.self, from: data)
    guard value.version == 2, value.chats.count <= 30,
      (value.context?.instructions.utf8.count ?? 0) <= 8_000,
      (value.context?.memoryIDs.count ?? 0) <= 16
    else { throw VoiceError.invalidConfiguration }
    for c in value.chats { try c.validate() }
    return value
  }
}

/// Credentials never enter this file. Atomic local history + acknowledged outbox survives relaunch.
@MainActor @Observable public final class WatchLibrary {
  private struct State: Codable {
    var chats: [WatchChat] = []
    var pending: [WatchTransfer] = []
  }
  private var state = State()
  public var chats: [WatchChat] {
    state.chats.filter(\.isVisible).sorted { $0.updatedAt > $1.updatedAt }
  }
  public var pending: [WatchTransfer] { state.pending }
  public var onChange: (() -> Void)?
  private let url: URL?
  public init(url: URL? = nil) throws {
    self.url = url
    if let url, FileManager.default.fileExists(atPath: url.path) {
      let info = try url.resourceValues(forKeys: [.fileSizeKey])
      guard (info.fileSize ?? 0) <= 32_000_000 else { throw VoiceError.responseTooLarge }
      state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
      guard state.chats.count <= 200, state.pending.count <= 5000 else {
        throw VoiceError.responseTooLarge
      }
      for chat in state.chats { try chat.validate() }
      for transfer in state.pending {
        _ = try WatchSyncWire.request(
          WatchSyncWire.encode(WatchSyncRequest(operation: "upload", transfer: transfer)))
      }
    }
  }
  public func chat(_ id: UUID) -> WatchChat? { state.chats.first { $0.id == id } }
  private func transaction(_ change: (inout State) throws -> Void) throws {
    var next = state
    try change(&next)
    guard next.chats.count <= 200, next.pending.count <= 5000 else {
      throw VoiceError.message("Watch storage is full. Sync with iPhone before continuing.")
    }
    let data = try JSONEncoder().encode(next)
    guard data.count <= 32_000_000 else { throw VoiceError.responseTooLarge }
    if let url {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      #if os(watchOS) || os(iOS)
        try data.write(
          to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      #else
        try data.write(to: url, options: .atomic)
      #endif
    }
    state = next
    onChange?()
  }
  public func saveDraft(_ chat: WatchChat) throws {
    try chat.validate()
    try transaction { state in
      if let i = state.chats.firstIndex(where: { $0.id == chat.id }) {
        state.chats[i].draft = chat.draft
        state.chats[i].providerID = chat.providerID
        state.chats[i].model = chat.model
      } else if chat.isVisible {
        state.chats.append(chat)
      }
    }
  }
  public func record(_ message: WatchMessage, chat: WatchChat) throws {
    try message.validate()
    try chat.validate()
    try transaction { state in
      var current = state.chats.first { $0.id == chat.id } ?? chat
      guard !current.deleted else {
        throw VoiceError.message("This chat was deleted on iPhone. Start a new conversation.")
      }
      guard !current.messages.contains(where: { $0.id == message.id }) else { return }
      guard current.messages.count < 1000 else {
        throw VoiceError.message("Start a new chat; this Watch conversation is full.")
      }
      current.messages.append(message)
      current.messages.sort { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
      current.updatedAt = max(current.updatedAt, message.date)
      if message.role == "user" { current.draft = "" }
      if !current.knownToPhone, current.title == "New conversation", message.role == "user" {
        current.title = VoiceIdentity.bounded(message.text, bytes: 120)
      }
      current.providerID = chat.providerID
      current.model = chat.model
      state.chats.removeAll { $0.id == current.id }
      state.chats.append(current)
      state.pending.append(WatchTransfer(chat: current, message: message))
    }
  }
  public func record(_ usage: VoiceUsageEntry, chat: WatchChat) throws {
    try usage.validate()
    try transaction { state in
      // Every revision is an immutable transfer; the phone upserts the stable usage ID.
      state.pending.append(WatchTransfer(chat: chat, usage: usage))
    }
  }
  public func acknowledge(_ id: UUID, deleted: Bool = false) throws {
    try transaction { state in
      guard let item = state.pending.first(where: { $0.id == id }) else { return }
      state.pending.removeAll { $0.id == id }
      if let index = state.chats.firstIndex(where: { $0.id == item.chat.id }) {
        if item.message != nil { state.chats[index].knownToPhone = true }
        if deleted {
          state.chats[index].deleted = true
          state.chats[index].draft = ""
        }
      }
    }
  }
  public func merge(_ remote: WatchChat) throws {
    try remote.validate()
    try transaction { state in
      if let index = state.chats.firstIndex(where: { $0.id == remote.id }) {
        var merged = remote
        let local = state.chats[index]
        // A detail response is a bounded page, never a deletion list. Keep older downloaded turns.
        let ids = Set(remote.messages.map(\.id))
        merged.messages += local.messages.filter { !ids.contains($0.id) }
        merged.messages.sort { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
        merged.messages = Array(merged.messages.suffix(1000))
        merged.draft = local.draft
        state.chats[index] = merged
      } else {
        state.chats.append(remote)
      }
    }
  }
}

/// Background delivery is restricted to usage-only transfers; never credentials, drafts or messages.
public enum WatchUsageDelivery {
  public static let payloadKey = "turing-watch-usage-v1"
  public static let receiptKey = "turing-watch-usage-receipt-v1"
  public static func decode(_ data: Data) throws -> WatchTransfer {
    let request = try WatchSyncWire.request(data)
    guard request.operation == "upload", let transfer = request.transfer,
      transfer.usage != nil, transfer.message == nil, transfer.chat.messages.isEmpty,
      transfer.chat.draft.isEmpty
    else { throw VoiceError.invalidConfiguration }
    return transfer
  }
  public static func candidates(_ pending: [WatchTransfer]) -> [WatchTransfer] {
    // A newer revision subsumes the older counters, but keep all durable entries until acknowledged.
    var latest: [UUID: WatchTransfer] = [:]
    for item in pending where item.message == nil {
      guard let usage = item.usage else { continue }
      if usage.revision > (latest[usage.id]?.usage?.revision ?? -1) { latest[usage.id] = item }
    }
    return latest.values.sorted {
      ($0.usage!.date, $0.id.uuidString) < ($1.usage!.date, $1.id.uuidString)
    }
  }
}

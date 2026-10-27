import Foundation
import Observation
import Security
import TuringVoice
@preconcurrency import WatchConnectivity

@MainActor @Observable
final class WatchConnection: NSObject, WCSessionDelegate {
  private(set) var configuration: VoiceConfiguration?
  var status = "Connect from Turing AI on iPhone"
  var syncing = false
  var library: WatchLibrary?
  var libraryStatus = ""
  var nextChatPage: Date?
  var nextChatPageID: UUID?
  private var usageRetryTask: Task<Void, Never>?
  private var usageAttempts: [UUID: Date] = [:]
  private var libraryTask: Task<Void, Never>?
  private var libraryGeneration = UUID()
  var didReplaceConfiguration: (() -> Void)?
  private var syncGeneration = UUID()
  private let service = "com.omergirgin.mosaic.watch.voice"
  override init() {
    super.init()
    do {
      let folder = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      library = try WatchLibrary(url: folder.appendingPathComponent("WatchLibrary-v2.json"))
      library?.onChange = { [weak self] in self?.flushLibrary() }
    } catch {
      libraryStatus =
        "Watch history could not be opened. Sync is paused to protect your saved data."
    }
    var query = keychainQuery
    query[kSecReturnData as String] = true
    var item: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data
    {
      configuration = try? JSONDecoder().decode(VoiceConfiguration.self, from: data).validated()
      if let saved = configuration,
        saved.issuedAt.timeIntervalSince1970
          <= UserDefaults.standard.double(forKey: "watchVoiceRevokedAt")
      {
        configuration = nil
        SecItemDelete(keychainQuery as CFDictionary)
      }
      if configuration != nil { status = "Ready" }
    }
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--watch-ui-preview") {
        library = try? WatchLibrary()
        configuration = VoiceConfiguration(endpoints: [
          VoiceEndpoint(
            id: UUID(), provider: "openai", name: "OpenAI",
            baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "preview-not-a-key",
            models: ["gpt-5.4"]),
          VoiceEndpoint(
            id: UUID(), provider: "google", name: "Google Gemini",
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            apiKey: "preview-not-a-key", models: ["gemini-3.5-flash"]),
        ])
        if let library, let endpoint = configuration?.endpoints.first {
          let choice = WatchModel(endpoint: endpoint, model: "gpt-5.4")
          let user = WatchMessage(
            role: "user", text: "Bugün yapacaklarımı birlikte planlayalım.",
            date: Date(timeIntervalSince1970: 100), choice: choice)
          let answer = WatchMessage(
            role: "assistant",
            text:
              "Önce kısa bir yürüyüş yapabilir, ardından en önemli işin için yarım saat ayırabilirsin. Bu sohbeti iPhone’da da sürdürebilirsin.",
            date: Date(timeIntervalSince1970: 101), choice: choice, replyTo: user.id)
          try? library.merge(
            WatchChat(
              title: "Günün planı", providerID: endpoint.id, model: choice.model,
              knownToPhone: true, messages: [user, answer],
              draft: "Bir de alışveriş listesi hazırlayalım."))
        }
        status = "UI preview · no network requests"
        return
      }
    #endif
    WCSession.default.delegate = self
    WCSession.default.activate()
  }
  private var keychainQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "providers", kSecAttrSynchronizable as String: false,
    ]
  }
  private func apply(_ data: Data) throws {
    guard data.count <= 60_000 else { throw VoiceError.invalidConfiguration }
    let configuration = try JSONDecoder().decode(VoiceConfiguration.self, from: data).validated()
    guard
      configuration.issuedAt.timeIntervalSince1970
        > UserDefaults.standard.double(forKey: "watchVoiceRevokedAt")
    else { throw VoiceError.invalidConfiguration }
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    var status = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(keychainQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw VoiceError.message("Unlock your Watch and try syncing again.")
    }
    didReplaceConfiguration?()
    self.configuration = configuration
    self.status = "Ready"
    syncing = false
    Task { await refreshChats() }
  }
  func disconnect(revokedAt: Double = Date().timeIntervalSince1970) {
    UserDefaults.standard.set(
      max(revokedAt, UserDefaults.standard.double(forKey: "watchVoiceRevokedAt")),
      forKey: "watchVoiceRevokedAt")
    syncGeneration = UUID()
    libraryGeneration = UUID()
    usageRetryTask?.cancel()
    usageRetryTask = nil
    for transfer in WCSession.default.outstandingUserInfoTransfers
    where transfer.userInfo[WatchUsageDelivery.payloadKey] != nil { transfer.cancel() }
    usageAttempts = [:]
    libraryTask?.cancel()
    libraryTask = nil
    didReplaceConfiguration?()
    configuration = nil
    syncing = false
    SecItemDelete(keychainQuery as CFDictionary)
    status = "Connect from Turing AI on iPhone"
  }
  func sync() {
    guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
      status = "Open Turing AI on your paired iPhone, then try again."
      return
    }
    guard !syncing else { return }
    syncing = true
    status = "Syncing…"
    let token = UUID()
    syncGeneration = token
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(30))
      guard let self, self.syncGeneration == token, self.syncing else { return }
      self.syncGeneration = UUID()
      self.syncing = false
      self.status = "Sync timed out. Keep both apps open and retry."
    }
    let delivery = VoiceCallbackDelivery { [weak self] result in
      guard let self, self.syncGeneration == token else { return }
      switch result {
      case .success(let data):
        do { try self.apply(data) } catch {
          self.syncing = false
          self.status = "Enable Apple Watch in Turing AI Settings on iPhone, then sync again."
        }
      case .failure:
        self.syncing = false
        self.status = "Could not reach iPhone. Open Turing AI and retry."
      }
    }
    WCSession.default.sendMessageData(
      Data("request-voice-config-v1".utf8),
      replyHandler: delivery.replyHandler, errorHandler: delivery.errorHandler)
  }
  private func exchange(_ request: WatchSyncRequest) async throws -> WatchSyncReply {
    guard configuration != nil, WCSession.default.activationState == .activated,
      WCSession.default.isReachable
    else { throw VoiceError.disconnected }
    let bytes = try WatchSyncWire.encode(request)
    let token = libraryGeneration
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      let pending = PendingWatchReply(continuation)
      let delivery = VoiceCallbackDelivery { pending.finish($0.mapError { $0 as Error }) }
      WCSession.default.sendMessageData(
        bytes, replyHandler: delivery.replyHandler, errorHandler: delivery.errorHandler)
      Task {
        try? await Task.sleep(for: .seconds(25))
        pending.finish(.failure(VoiceError.timeout))
      }
    }
    try Task.checkCancellation()
    guard token == libraryGeneration, configuration != nil else { throw VoiceError.disconnected }
    return try WatchSyncWire.reply(data)
  }
  func flushLibrary() {
    queueUsage()
    guard libraryTask == nil, let library, !library.pending.isEmpty, configuration != nil,
      WCSession.default.isReachable
    else { return }
    libraryTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let token = libraryGeneration
      defer { if token == libraryGeneration { self.libraryTask = nil } }
      do {
        while let item = library.pending.first {
          try Task.checkCancellation()
          let reply = try await exchange(WatchSyncRequest(operation: "upload", transfer: item))
          guard reply.acknowledged == item.id, ["ok", "deleted"].contains(reply.status) else {
            throw VoiceError.message(
              reply.status == "archived"
                ? "Chat archived on iPhone. Unarchive it to sync pending messages."
                : "iPhone is busy or needs an update. Keep both apps open and retry sync.")
          }
          try library.acknowledge(item.id, deleted: reply.status == "deleted")
        }
        libraryStatus = "Chats and usage synced"
      } catch {
        libraryStatus = "\(library.pending.count) updates waiting · \(error.localizedDescription)"
      }
    }
  }
  private func queueUsage() {
    guard configuration != nil, WCSession.default.activationState == .activated, let library else {
      return
    }
    let queued = WCSession.default.outstandingUserInfoTransfers.compactMap {
      ($0.userInfo[WatchUsageDelivery.payloadKey] as? Data).flatMap {
        try? WatchUsageDelivery.decode($0).id
      }
    }
    let candidates = WatchUsageDelivery.candidates(library.pending)
    for item in candidates.filter({ !queued.contains($0.id) }).prefix(max(0, 10 - queued.count)) {
      guard Date().timeIntervalSince(usageAttempts[item.id] ?? .distantPast) >= 60,
        let data = try? WatchSyncWire.encode(WatchSyncRequest(operation: "upload", transfer: item))
      else { continue }
      usageAttempts[item.id] = .now
      WCSession.default.transferUserInfo([WatchUsageDelivery.payloadKey: data])
    }
    if !candidates.isEmpty, usageRetryTask == nil {
      usageRetryTask = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .seconds(60)) } catch { return }
        self?.usageRetryTask = nil
        self?.flushLibrary()
      }
    }
  }
  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
    guard let data = userInfo[WatchUsageDelivery.receiptKey] as? Data else { return }
    Task { @MainActor in
      guard configuration != nil, let library,
        let reply = try? WatchSyncWire.reply(data), ["ok", "deleted"].contains(reply.status),
        let id = reply.acknowledged,
        let item = library.pending.first(where: { $0.id == id }), let usage = item.usage,
        item.message == nil
      else { return }
      do {
        // Phone has durably stored this cumulative revision: older revisions are also covered.
        let covered = library.pending.filter {
          $0.message == nil && $0.usage?.id == usage.id
            && ($0.usage?.revision ?? Int.max) <= usage.revision
        }.map(\.id)
        for id in covered {
          try library.acknowledge(id)
          usageAttempts.removeValue(forKey: id)
        }
        libraryStatus =
          library.pending.isEmpty
          ? "Chats and usage synced" : "Usage synced · chats waiting for iPhone"
        flushLibrary()
      } catch { libraryStatus = "Usage receipt could not be saved. Will retry." }
    }
  }
  func refreshChats(more: Bool = false) async {
    flushLibrary()
    await libraryTask?.value
    guard let library, configuration != nil else { return }
    do {
      let reply = try await exchange(
        WatchSyncRequest(
          operation: "list", before: more ? nextChatPage : nil,
          beforeID: more ? nextChatPageID : nil))
      guard reply.status == "ok" else { throw VoiceError.disconnected }
      for chat in reply.chats { try library.merge(chat) }
      nextChatPage = reply.nextPage
      nextChatPageID = reply.nextPageID
      libraryStatus =
        library.pending.isEmpty
        ? "Chats and usage synced" : "\(library.pending.count) updates waiting"
    } catch { libraryStatus = "iPhone unavailable · saved chats remain on Watch" }
  }
  func prepareChat(_ chat: WatchChat, query: String) async throws -> (WatchChat, WatchContext) {
    guard let library else {
      throw VoiceError.message("Watch history is unavailable. Reopen the app before continuing.")
    }
    guard WCSession.default.isReachable else {
      return (library.chat(chat.id) ?? chat, WatchContext(offline: true))
    }
    flushLibrary()
    await libraryTask?.value
    if library.pending.contains(where: { $0.chat.id == chat.id && $0.message != nil }) {
      throw VoiceError.message(
        "Sync this conversation with iPhone before continuing. Your messages are saved on Watch.")
    }
    let current = library.chat(chat.id) ?? chat
    let reply = try await exchange(
      WatchSyncRequest(
        operation: "context", chatID: chat.id, newChat: !current.knownToPhone, query: query,
        providerID: chat.providerID, model: chat.model))
    guard reply.status == "ok" else {
      throw VoiceError.message(
        reply.status == "modelDisabled"
          ? "Model disabled on iPhone. Sync models and choose another."
          : "This chat was removed or archived, or iPhone is busy. Refresh before continuing.")
    }
    for value in reply.chats { try library.merge(value) }
    return (library.chat(chat.id) ?? chat, reply.context ?? WatchContext())
  }
  func loadOlder(_ chat: WatchChat) async {
    do {
      let reply = try await exchange(
        WatchSyncRequest(
          operation: "context", chatID: chat.id, before: chat.messages.first?.date,
          beforeID: chat.messages.first?.id))
      guard reply.status == "ok" else { throw VoiceError.disconnected }
      for value in reply.chats { try library?.merge(value) }
      libraryStatus =
        reply.nextPage == nil ? "Beginning of conversation" : "Earlier messages loaded"
    } catch { libraryStatus = "Keep iPhone open to load earlier messages." }
  }
  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor in self.flushLibrary() }
  }
  nonisolated func session(
    _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    self.session(session, didReceiveApplicationContext: session.receivedApplicationContext)
    Task { @MainActor in self.flushLibrary() }
  }
  nonisolated func session(
    _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    if applicationContext["voiceAccess"] as? Bool == false,
      let time = applicationContext["changedAt"] as? Double
    {
      Task { @MainActor in
        if (self.configuration?.issuedAt.timeIntervalSince1970 ?? 0) <= time {
          self.disconnect(revokedAt: time)
        }
      }
    }
  }
  nonisolated func session(
    _ session: WCSession, didReceiveMessageData messageData: Data,
    replyHandler: @escaping (Data) -> Void
  ) {
    let reply = WatchReply(replyHandler)
    Task { @MainActor in
      do {
        try apply(messageData)
        reply.send(Data("ok".utf8))
      } catch { reply.send(Data("invalid".utf8)) }
    }
  }
}
private struct WatchReply: @unchecked Sendable {
  let send: (Data) -> Void
  init(_ send: @escaping (Data) -> Void) { self.send = send }
}

@MainActor private final class PendingWatchReply {
  private var continuation: CheckedContinuation<Data, Error>?
  init(_ value: CheckedContinuation<Data, Error>) { continuation = value }
  func finish(_ result: Result<Data, Error>) {
    let value = continuation
    continuation = nil
    value?.resume(with: result)
  }
}

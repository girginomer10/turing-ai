import Foundation
import PDFKit

protocol GoogleSourceSearching: Sendable {
  func search(service: GoogleService, query: String, account: GoogleAccount) async throws
    -> [ConnectedGoogleSource]
  func search(
    service: GoogleService, query: String, account: GoogleAccount,
    onProgress: @Sendable (GoogleSearchProgress) async -> Void
  ) async throws -> [ConnectedGoogleSource]
}

extension GoogleSourceSearching {
  func search(
    service: GoogleService, query: String, account: GoogleAccount,
    onProgress: @Sendable (GoogleSearchProgress) async -> Void
  ) async throws -> [ConnectedGoogleSource] {
    await onProgress(.searching(service))
    return try await search(service: service, query: query, account: account)
  }
}

struct GoogleSourceClient: GoogleSourceSearching, GmailBrowsing {
  let store: GoogleConnectionStore
  let transport: any GoogleHTTPTransport
  init(
    store: GoogleConnectionStore = .shared, transport: any GoogleHTTPTransport = GoogleHTTPClient()
  ) {
    self.store = store
    self.transport = transport
  }
  func search(service: GoogleService, query: String, account: GoogleAccount) async throws
    -> [ConnectedGoogleSource]
  {
    try await search(service: service, query: query, account: account, onProgress: { _ in })
  }
  func search(
    service: GoogleService, query: String, account: GoogleAccount,
    onProgress: @Sendable (GoogleSearchProgress) async -> Void
  ) async throws -> [ConnectedGoogleSource] {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf8.count <= 512
    else {
      throw GoogleConnectionError.invalidQuery
    }
    guard service == .gmail || service == .drive else { throw GoogleConnectionError.invalidQuery }
    await onProgress(.searching(service))
    let results =
      try await service == .gmail
      ? gmail(query, account, onProgress: onProgress)
      : drive(query, account, onProgress: onProgress)
    try Task.checkCancellation()
    try await store.assertAccount(account.subject)
    return results
  }
  private func get(
    _ path: String, _ query: [String: String], _ service: GoogleService,
    _ account: GoogleAccount, limit: Int = 2_000_000
  ) async throws -> Data {
    let token = try await store.token(for: service, subject: account.subject)
    do {
      return try await transport.send(
        GoogleWire.get(path, query: query, token: token), maximumBytes: limit)
    } catch GoogleConnectionError.http(401) { throw GoogleConnectionError.disconnected }
  }
  // Compatibility entry point: one explicitly incomplete page. Chat retrieval uses GmailResearch.
  private func gmail(
    _ query: String, _ account: GoogleAccount,
    onProgress: @Sendable (GoogleSearchProgress) async -> Void
  ) async throws -> [ConnectedGoogleSource] {
    let page = try await gmailPage(query: query, cursor: nil, account: account)
    var sources: [ConnectedGoogleSource] = []
    for (index, item) in page.items.enumerated() {
      await onProgress(.reading(.gmail, current: index + 1, total: page.items.count))
      sources.append(try await gmailBody(id: item.id, account: account))
    }
    if !sources.isEmpty { sources[sources.count - 1].hasMoreResults = page.cursor != nil }
    return sources
  }

  func gmailPage(query: String, cursor: String?, account: GoogleAccount) async throws
    -> GmailResultPage
  {
    try await gmailPage(query: query, cursor: cursor, account: account, check: {})
  }

  func gmailPage(
    query: String, cursor: String?, account: GoogleAccount,
    check: @MainActor @Sendable () async throws -> Void
  ) async throws -> GmailResultPage {
    try await check()
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf8.count <= 512,
      cursor.map({ !$0.isEmpty && $0.utf8.count <= 4096 }) ?? true
    else { throw GoogleConnectionError.invalidQuery }
    var parameters = ["q": query, "maxResults": "10", "fields": "messages(id),nextPageToken"]
    if let cursor { parameters["pageToken"] = cursor }
    let data = try await get(
      "https://gmail.googleapis.com/gmail/v1/users/me/messages", parameters, .gmail, account)
    let list = try JSONDecoder().decode(GmailList.self, from: data)
    let next = list.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
    guard next.map({ $0.utf8.count <= 4096 && $0 != cursor }) ?? true,
      (list.messages?.count ?? 0) <= 10
    else { throw GoogleConnectionError.invalidResponse }
    var seen = Set<String>()
    var items: [ConnectedGoogleSource] = []
    for item in list.messages ?? [] where seen.insert(item.id).inserted {
      try await check()
      guard GoogleWire.validID(item.id) else { throw GoogleConnectionError.invalidResponse }
      // Metadata includes headers/snippet but deliberately excludes message bodies/attachments.
      let data = try await get(
        "https://gmail.googleapis.com/gmail/v1/users/me/messages/" + item.id,
        ["format": "metadata", "fields": "id,threadId,snippet,payload(headers)"], .gmail, account)
      let message = try JSONDecoder().decode(GmailMessage.self, from: data)
      guard message.id == item.id else { throw GoogleConnectionError.invalidResponse }
      items.append(try message.source(email: account.email))
    }
    try await store.assertAccount(account.subject)
    return GmailResultPage(items: items, cursor: next)
  }

  func gmailBody(id: String, account: GoogleAccount) async throws -> ConnectedGoogleSource {
    guard GoogleWire.validID(id) else { throw GoogleConnectionError.invalidResponse }
    let data = try await get(
      "https://gmail.googleapis.com/gmail/v1/users/me/messages/" + id,
      ["format": "full"], .gmail, account)
    let message = try JSONDecoder().decode(GmailMessage.self, from: data)
    guard message.id == id else { throw GoogleConnectionError.invalidResponse }
    try await store.assertAccount(account.subject)
    return try message.source(email: account.email)
  }
  private func drive(
    _ query: String, _ account: GoogleAccount,
    onProgress: @Sendable (GoogleSearchProgress) async -> Void
  ) async throws
    -> [ConnectedGoogleSource]
  {
    let data = try await get(
      "https://www.googleapis.com/drive/v3/files",
      [
        "q": Self.driveQuery(query), "pageSize": "5", "orderBy": "modifiedTime desc",
        "fields": "files(id,name,mimeType,size,description),nextPageToken",
        "supportsAllDrives": "true", "includeItemsFromAllDrives": "true",
      ], .drive, account)
    let list = try JSONDecoder().decode(DriveList.self, from: data)
    var sources: [ConnectedGoogleSource] = []
    let files = Array(list.files.prefix(5))
    for (index, file) in files.enumerated() {
      try Task.checkCancellation()
      await onProgress(.reading(.drive, current: index + 1, total: files.count))
      guard GoogleWire.validID(file.id) else { throw GoogleConnectionError.invalidResponse }
      var content = file.description ?? ""
      do {
        content = try await read(file, account)
      } catch GoogleConnectionError.unsupportedFile {
        content += "\n[Content not read: unsupported format. Only file metadata is available.]"
      } catch GoogleConnectionError.oversizedResponse {
        content += "\n[Content not read: file is too large. Only file metadata is available.]"
      }
      sources.append(
        ConnectedGoogleSource(
          service: .drive, id: file.id,
          title: GoogleWire.bounded(file.name, bytes: 500),
          url: "https://drive.google.com/file/d/\(file.id)/view",
          text: GoogleWire.bounded(content, bytes: 5_000)))
    }
    if !sources.isEmpty {
      sources[sources.count - 1].hasMoreResults = list.nextPageToken?.isEmpty == false
    }
    return sources
  }
  static func driveQuery(_ query: String) -> String {
    let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
      of: "'", with: "\\'")
    return
      "trashed = false and mimeType != 'application/vnd.google-apps.folder' and fullText contains '\(escaped)'"
  }
  private func read(_ file: DriveFile, _ account: GoogleAccount) async throws -> String {
    let path = "https://www.googleapis.com/drive/v3/files/" + file.id
    let data: Data
    switch file.mimeType {
    case "application/vnd.google-apps.document", "application/vnd.google-apps.presentation":
      data = try await get(path + "/export", ["mimeType": "text/plain"], .drive, account)
    case "application/vnd.google-apps.spreadsheet":
      data = try await get(path + "/export", ["mimeType": "text/csv"], .drive, account)
      return "[First sheet only; other sheets were not read.]\n"
        + GoogleWire.bounded(String(decoding: data, as: UTF8.self), bytes: 4_900)
    case "application/pdf":
      guard (Int(file.size ?? "0") ?? 0) <= 2_000_000 else {
        throw GoogleConnectionError.oversizedResponse
      }
      data = try await get(path, ["alt": "media", "supportsAllDrives": "true"], .drive, account)
      guard let pdf = PDFDocument(data: data), !pdf.isLocked else {
        throw GoogleConnectionError.unsupportedFile
      }
      var text = ""
      for index in 0..<min(pdf.pageCount, 20) {
        text += pdf.page(at: index)?.string ?? ""
        text += "\n"
        if text.utf8.count >= 5_000 { break }
      }
      return text.isEmpty
        ? "[PDF has no readable text; scanned pages were not transcribed.]"
        : text + "\n[Bounded PDF excerpt; not necessarily the complete document.]"
    default:
      guard
        file.mimeType.hasPrefix("text/")
          || ["application/json", "application/xml"].contains(file.mimeType)
      else {
        throw GoogleConnectionError.unsupportedFile
      }
      guard (Int(file.size ?? "0") ?? 0) <= 2_000_000 else {
        throw GoogleConnectionError.oversizedResponse
      }
      data = try await get(path, ["alt": "media", "supportsAllDrives": "true"], .drive, account)
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw GoogleConnectionError.unsupportedFile
    }
    return text
  }
}

private struct GmailList: Decodable {
  struct Entry: Decodable { let id: String }
  let messages: [Entry]?
  let nextPageToken: String?
}
struct GmailMessage: Decodable {
  let id: String
  let threadId: String
  let snippet: String?
  let payload: Part?
  struct Part: Decodable {
    struct Header: Decodable {
      let name: String
      let value: String
    }
    struct Body: Decodable { let data: String? }
    let mimeType: String?
    let filename: String?
    let headers: [Header]?
    let body: Body?
    let parts: [Part]?
    func text(depth: Int = 0) -> String {
      guard depth < 12, (filename ?? "").isEmpty else { return "" }
      if let encoded = body?.data, let data = Data.googleBase64URL(encoded),
        let value = String(data: data, encoding: .utf8)
      {
        if mimeType == "text/plain" { return value }
        if mimeType == "text/html" {
          return value.replacingOccurrences(
            of: "(?is)<(script|style)\\b[^>]*>.*?</\\1>", with: "", options: .regularExpression
          )
          .replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
          .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(
            of: "&amp;", with: "&")
        }
      }
      let children = parts ?? []
      let plain = children.filter { $0.mimeType == "text/plain" }
      return (plain.isEmpty ? children : plain).prefix(30).map { $0.text(depth: depth + 1) }.joined(
        separator: "\n")
    }
  }
  func source(email: String) throws -> ConnectedGoogleSource {
    guard GoogleWire.validID(id), GoogleWire.validID(threadId) else {
      throw GoogleConnectionError.invalidResponse
    }
    func header(_ name: String) -> String {
      GoogleWire.bounded(
        payload?.headers?.first { $0.name.lowercased() == name }?.value ?? "", bytes: 500)
    }
    var url = URLComponents(string: "https://mail.google.com/mail/")!
    url.queryItems = [.init(name: "authuser", value: email)]
    url.fragment = "all/" + threadId
    let body = payload?.text() ?? ""
    return ConnectedGoogleSource(
      service: .gmail, id: id, title: header("subject").isEmpty ? "Email" : header("subject"),
      url: url.url!.absoluteString,
      text: GoogleWire.bounded(
        "From: \(header("from"))\nDate: \(header("date"))\n\(body.isEmpty ? (snippet ?? "[No readable body]") : body)",
        bytes: 5_000))
  }
}
private struct DriveList: Decodable {
  let files: [DriveFile]
  let nextPageToken: String?
}
private struct DriveFile: Decodable {
  let id: String
  let name: String
  let mimeType: String
  let size: String?
  let description: String?
}

import Foundation

struct ConnectorHTTPResponse: Sendable {
  let status: Int
  let headers: [String: String]
  let data: Data
  func requireSuccess() throws -> Data {
    guard (200...299).contains(status) else { throw ConnectorError.http(status) }
    return data
  }
}
protocol ConnectorTransport: Sendable {
  func send(
    _ request: URLRequest, allowedHosts: Set<String>, maximumBytes: Int,
    rpcID: String?
  ) async throws -> ConnectorHTTPResponse
}

/// Each call supplies its own origin allowlist. Credentials cannot follow redirects or be sent
/// to URLs from a model/tool result. Event streams stop when this request's JSON-RPC reply arrives.
final class ConnectorHTTP: NSObject, ConnectorTransport, URLSessionTaskDelegate, Sendable {
  static func isAllowed(_ url: URL?, hosts: Set<String>) -> Bool {
    guard let url, url.scheme == "https", let host = url.host?.lowercased(), hosts.contains(host),
      url.user == nil, url.password == nil, url.fragment == nil,
      url.port == nil || url.port == 443
    else { return false }
    return true
  }
  func send(
    _ request: URLRequest, allowedHosts: Set<String>, maximumBytes: Int = 2_000_000,
    rpcID: String? = nil
  ) async throws -> ConnectorHTTPResponse {
    guard Self.isAllowed(request.url, hosts: allowedHosts) else {
      throw ConnectorError.invalidArguments
    }
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.urlCache = nil
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 90
    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw ConnectorError.invalidResponse }
    let headers = http.allHeaderFields.reduce(into: [String: String]()) {
      if let key = $1.key as? String, let value = $1.value as? String {
        $0[key.lowercased()] = value
      }
    }
    guard response.expectedContentLength <= maximumBytes else { throw ConnectorError.tooLarge }
    var data = Data()
    if let rpcID, (headers["content-type"] ?? "").lowercased().contains("text/event-stream"),
      http.statusCode == 200
    {
      var decoder = ConnectorRPCEventDecoder(id: rpcID, maximumBytes: maximumBytes)
      for try await byte in bytes {
        try Task.checkCancellation()
        if let reply = try decoder.consume(byte) {
          return .init(status: http.statusCode, headers: headers, data: reply)
        }
      }
      if let reply = try decoder.finish() {
        return .init(status: http.statusCode, headers: headers, data: reply)
      }
      throw ConnectorError.invalidResponse
    }
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < maximumBytes else { throw ConnectorError.tooLarge }
      data.append(byte)
    }
    return .init(status: http.statusCode, headers: headers, data: data)
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

/// Foundation AsyncBytes.lines drops empty lines, which are significant SSE event delimiters.
/// Use the same byte-oriented decoder as provider streams and match only this JSON-RPC ID.
struct ConnectorRPCEventDecoder {
  let id: String
  let maximumBytes: Int
  private var total = 0
  private var stream = BoundedSSEStreamDecoder()
  init(id: String, maximumBytes: Int) {
    self.id = id
    self.maximumBytes = maximumBytes
  }
  mutating func consume(_ byte: UInt8) throws -> Data? {
    total += 1
    guard total <= maximumBytes else { throw ConnectorError.tooLarge }
    guard let event = try stream.consume(byte: byte) else { return nil }
    return reply(event)
  }
  mutating func finish() throws -> Data? { try stream.finish().compactMap(reply).first }
  private func reply(_ event: ServerSentEvent) -> Data? {
    let data = Data(event.data.utf8)
    guard let value = try? ConnectorJSON.decode(data), value["id"].string == id else { return nil }
    return data
  }
}

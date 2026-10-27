import Foundation

protocol GoogleHTTPTransport: Sendable {
  func send(_ request: URLRequest, maximumBytes: Int) async throws -> Data
}

/// No redirects, cookies, URL cache, arbitrary hosts, or error-body logging. OAuth tokens never
/// reach model providers. The bound request path is built by the app, never supplied by a model.
final class GoogleHTTPClient: NSObject, GoogleHTTPTransport, URLSessionTaskDelegate, Sendable {
  static let allowedHosts: Set<String> = [
    "oauth2.googleapis.com", "openidconnect.googleapis.com", "gmail.googleapis.com",
    "www.googleapis.com",
  ]
  func send(_ request: URLRequest, maximumBytes: Int = 2_000_000) async throws -> Data {
    guard let url = request.url, url.scheme == "https", let host = url.host,
      Self.allowedHosts.contains(host), url.user == nil, url.password == nil,
      url.port == nil || url.port == 443
    else { throw GoogleConnectionError.invalidResponse }
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.urlCache = nil
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 60
    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw GoogleConnectionError.invalidResponse
    }
    guard (200...299).contains(http.statusCode) else {
      throw GoogleConnectionError.http(http.statusCode)
    }
    guard response.expectedContentLength <= maximumBytes else {
      throw GoogleConnectionError.oversizedResponse
    }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < maximumBytes else { throw GoogleConnectionError.oversizedResponse }
      data.append(byte)
    }
    return data
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

enum GoogleWire {
  static func form(_ values: [String: String]) -> Data {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return Data(
      values.sorted(by: { $0.key < $1.key }).map {
        "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
      }.joined(separator: "&").utf8)
  }
  static func post(_ url: String, values: [String: String]) -> URLRequest {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = form(values)
    return request
  }
  static func get(_ base: String, query: [String: String] = [:], token: String) -> URLRequest {
    var components = URLComponents(string: base)!
    components.queryItems = query.sorted(by: { $0.key < $1.key }).map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    return request
  }
  static func validID(_ id: String) -> Bool {
    !id.isEmpty && id.count < 256
      && id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
  }
  static func bounded(_ value: String, bytes: Int) -> String {
    String(decoding: value.utf8.prefix(max(0, bytes)), as: UTF8.self)
  }
}

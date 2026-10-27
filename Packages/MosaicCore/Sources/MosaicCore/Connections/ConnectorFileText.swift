import Foundation
import PDFKit

enum ConnectorFileText {
  static func extract(_ data: Data, name: String) throws -> ConnectorJSON {
    guard data.count <= 2_000_000 else { throw ConnectorError.tooLarge }
    let ext = (name as NSString).pathExtension.lowercased()
    if ext == "pdf" {
      guard let document = PDFDocument(data: data), document.pageCount > 0 else {
        throw ConnectorError.invalidResponse
      }
      let pages = min(20, document.pageCount)
      var text = ""
      for index in 0..<pages {
        try Task.checkCancellation()
        text +=
          "\nPage \(index + 1)\n"
          + (document.page(at: index)?.string ?? "[No selectable text; OCR was not performed.]")
        if text.utf8.count > 30_000 { break }
      }
      return .object([
        "name": .string(name), "text": .string(GoogleWire.bounded(text, bytes: 30_000)),
        "notice": .string(
          "Selectable PDF text from at most the first 20 pages, capped at 30KB. Images, scans, tables and remaining pages may be omitted; no OCR was performed."
        ),
        "total_pages": .number(Double(document.pageCount)),
      ])
    }
    guard ["txt", "md", "csv", "json", "log"].contains(ext),
      let text = String(data: data, encoding: .utf8)
    else { throw ConnectorError.invalidArguments }
    return .object([
      "name": .string(name), "text": .string(GoogleWire.bounded(text, bytes: 30_000)),
      "truncated": .bool(text.utf8.count > 30_000),
    ])
  }
  static func microsoftDownloadHost(_ url: URL) -> String? {
    guard let host = url.host?.lowercased(), url.scheme == "https", url.user == nil,
      url.password == nil,
      url.fragment == nil, url.port == nil || url.port == 443,
      ["sharepoint.com", "sharepoint-df.com", "1drv.com", "storage.live.com"].contains(where: {
        host.hasSuffix("." + $0)
      })
    else { return nil }
    return host
  }
  static func asciiHeader(_ json: ConnectorJSON) -> String {
    json.encoded.utf16.map { $0 < 128 ? String(UnicodeScalar($0)!) : String(format: "\\u%04x", $0) }
      .joined()
  }
}

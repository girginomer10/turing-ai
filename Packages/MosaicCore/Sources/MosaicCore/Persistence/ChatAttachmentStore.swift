import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ChatAttachmentFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

enum ChatAttachmentStore {
  static let documentMarker = "\n\n[Attached document content]\n"
  static let imageMarker = "[Attached photo SHA256:"
  static func importFile(_ url: URL, conversationID: UUID) throws -> ExperienceValue {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let type = UTType(filenameExtension: url.pathExtension)
    if type?.conforms(to: .image) == true {
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= 30 * 1_024 * 1_024 else {
        throw ChatAttachmentFailure(message: "Choose a photo smaller than 30 MB.")
      }
      return try photo(
        Data(contentsOf: url), filename: url.lastPathComponent, conversationID: conversationID)
    }
    let document = try DocumentIngestor.importDocument(at: url)
    let text = document.chunks.map { chunk in
      (chunk.pageNumber.map { "Page \($0):\n" } ?? "") + chunk.content
    }.joined(separator: "\n\n")
    guard text.utf8.count <= 800_000 else {
      throw ChatAttachmentFailure(
        message:
          "This document is too long for a chat attachment. Import it into Memory instead, so only relevant passages are used."
      )
    }
    return ExperienceValue(
      id: UUID(), kind: .attachment, conversationID: conversationID,
      filename: String(url.lastPathComponent.prefix(200)), mimeType: document.mimeType,
      extractedText: text)
  }
  static func photo(_ data: Data, filename: String, conversationID: UUID) throws -> ExperienceValue
  {
    guard data.count <= 30 * 1_024 * 1_024,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 1024,
        ] as CFDictionary)
    else { throw ChatAttachmentFailure(message: "This photo could not be opened.") }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw ChatAttachmentFailure(message: "This photo could not be prepared.") }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(destination), output.length <= 1_048_576 else {
      throw ChatAttachmentFailure(message: "This photo is too large. Choose a smaller image.")
    }
    // Re-encoding drops location/camera metadata and normalizes orientation.
    return ExperienceValue(
      id: UUID(), kind: .attachment, conversationID: conversationID,
      filename: String(filename.prefix(200)), mimeType: "image/jpeg", bytes: output as Data)
  }
  static func messageContent(text: String, attachments: [ExperienceValue]) -> String {
    var result = text
    for attachment in attachments {
      if let data = attachment.bytes, attachment.isImage {
        result +=
          "\n\n\(imageMarker) \(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())] \(attachment.filename ?? "Photo")"
      } else if let content = attachment.extractedText {
        let encoded =
          (try? JSONSerialization.data(
            withJSONObject: ["filename": attachment.filename ?? "Document", "content": content],
            options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        result += documentMarker + encoded
      }
    }
    return result
  }
  static func displayText(_ content: String) -> String {
    let document = content.range(of: documentMarker)?.lowerBound ?? content.endIndex
    let image = content.range(of: "\n\n" + imageMarker)?.lowerBound ?? content.endIndex
    return String(content[..<min(document, image)])
  }
}

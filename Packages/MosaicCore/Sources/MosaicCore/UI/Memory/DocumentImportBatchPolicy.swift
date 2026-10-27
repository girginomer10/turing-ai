import Foundation

enum DocumentImportBatchPolicyError: LocalizedError, Equatable, Sendable {
  case tooManyFiles(selected: Int, maximum: Int)
  case fileSizeUnavailable(filename: String)
  case invalidFileSize(filename: String)
  case fileTooLarge(filename: String, bytes: Int64, maximumBytes: Int64)
  case batchTooLarge(bytes: Int64, maximumBytes: Int64)

  var errorDescription: String? {
    switch self {
    case .tooManyFiles(_, let maximum):
      "Select up to \(maximum) documents at a time."
    case .fileSizeUnavailable(let filename):
      "Turing AI couldn’t verify the size of “\(filename)”. Download it to this device and try again."
    case .invalidFileSize(let filename):
      "Turing AI couldn’t read a valid size for “\(filename)”. Choose another copy and try again."
    case .fileTooLarge(let filename, let bytes, let maximumBytes):
      "“\(filename)” is \(Self.formatted(bytes)). Each file must be \(Self.formatted(maximumBytes)) or smaller."
    case .batchTooLarge(let bytes, let maximumBytes):
      "The selected documents total \(Self.formatted(bytes)). Select at most \(Self.formatted(maximumBytes)) at a time."
    }
  }

  private static func formatted(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
  }
}

/// Bounds one picker result before extraction starts. Import remains sequential, so at most one
/// expanded/OCR-derived payload is retained at a time even when the user selects several files.
struct DocumentImportBatchPolicy: Sendable {
  static let standard = DocumentImportBatchPolicy(
    maximumFileCount: 8,
    maximumFileBytes: 50 * 1_024 * 1_024,
    maximumBatchBytes: 100 * 1_024 * 1_024
  )

  let maximumFileCount: Int
  let maximumFileBytes: Int64
  let maximumBatchBytes: Int64

  init(
    maximumFileCount: Int,
    maximumFileBytes: Int64,
    maximumBatchBytes: Int64
  ) {
    precondition(maximumFileCount > 0)
    precondition(maximumFileBytes > 0)
    precondition(maximumBatchBytes >= maximumFileBytes)
    self.maximumFileCount = maximumFileCount
    self.maximumFileBytes = maximumFileBytes
    self.maximumBatchBytes = maximumBatchBytes
  }

  static func selectedFileSize(at url: URL) throws -> Int64? {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    return try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
  }

  func validatedURLs(
    _ urls: [URL],
    fileSize: (URL) throws -> Int64?
  ) throws -> [URL] {
    guard urls.count <= maximumFileCount else {
      throw DocumentImportBatchPolicyError.tooManyFiles(
        selected: urls.count,
        maximum: maximumFileCount
      )
    }

    var totalBytes: Int64 = 0
    for url in urls {
      try Task.checkCancellation()
      guard let bytes = try fileSize(url) else {
        throw DocumentImportBatchPolicyError.fileSizeUnavailable(
          filename: url.lastPathComponent
        )
      }
      guard bytes >= 0 else {
        throw DocumentImportBatchPolicyError.invalidFileSize(
          filename: url.lastPathComponent
        )
      }
      guard bytes <= maximumFileBytes else {
        throw DocumentImportBatchPolicyError.fileTooLarge(
          filename: url.lastPathComponent,
          bytes: bytes,
          maximumBytes: maximumFileBytes
        )
      }
      let (nextTotal, overflow) = totalBytes.addingReportingOverflow(bytes)
      guard !overflow, nextTotal <= maximumBatchBytes else {
        throw DocumentImportBatchPolicyError.batchTooLarge(
          bytes: overflow ? .max : nextTotal,
          maximumBytes: maximumBatchBytes
        )
      }
      totalBytes = nextTotal
    }
    return urls
  }
}

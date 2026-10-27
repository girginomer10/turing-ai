import Foundation
import Testing

@testable import MosaicCore

@Suite("Document import batch policy")
struct DocumentImportBatchPolicyTests {
  private let policy = DocumentImportBatchPolicy(
    maximumFileCount: 2,
    maximumFileBytes: 50,
    maximumBatchBytes: 75
  )

  @Test("accepts a bounded selection and checks every file")
  func acceptsBoundedSelection() throws {
    let urls = [URL(fileURLWithPath: "/tmp/one.pdf"), URL(fileURLWithPath: "/tmp/two.txt")]
    let sizes = ["one.pdf": Int64(30), "two.txt": Int64(40)]
    var checked: [String] = []

    let result = try policy.validatedURLs(urls) { url in
      checked.append(url.lastPathComponent)
      return sizes[url.lastPathComponent]
    }

    #expect(result == urls)
    #expect(checked == ["one.pdf", "two.txt"])
  }

  @Test("rejects too many files before reading their metadata")
  func rejectsTooManyFiles() {
    let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/\($0).pdf") }
    var metadataReadCount = 0

    #expect(throws: DocumentImportBatchPolicyError.tooManyFiles(selected: 3, maximum: 2)) {
      try policy.validatedURLs(urls) { _ in
        metadataReadCount += 1
        return 1
      }
    }
    #expect(metadataReadCount == 0)
  }

  @Test("rejects an individually oversized file")
  func rejectsOversizedFile() {
    let url = URL(fileURLWithPath: "/tmp/large.pdf")

    #expect(
      throws: DocumentImportBatchPolicyError.fileTooLarge(
        filename: "large.pdf",
        bytes: 51,
        maximumBytes: 50
      )
    ) {
      try policy.validatedURLs([url]) { _ in 51 }
    }
  }

  @Test("rejects a batch whose combined source size exceeds the cap")
  func rejectsOversizedBatch() {
    let urls = [URL(fileURLWithPath: "/tmp/one.pdf"), URL(fileURLWithPath: "/tmp/two.pdf")]

    #expect(
      throws: DocumentImportBatchPolicyError.batchTooLarge(bytes: 80, maximumBytes: 75)
    ) {
      try policy.validatedURLs(urls) { _ in 40 }
    }
  }

  @Test("fails closed when a file provider does not expose a size")
  func rejectsUnknownSize() {
    let url = URL(fileURLWithPath: "/tmp/cloud.pdf")

    #expect(
      throws: DocumentImportBatchPolicyError.fileSizeUnavailable(filename: "cloud.pdf")
    ) {
      try policy.validatedURLs([url]) { _ in nil }
    }
  }

  @Test("cancellation stops validation before more file work starts")
  func observesCancellation() async {
    let url = URL(fileURLWithPath: "/tmp/cancelled.pdf")
    let validation = Task<[URL], Error> {
      withUnsafeCurrentTask { task in
        task?.cancel()
      }
      return try policy.validatedURLs([url]) { _ in
        Issue.record("Cancelled validation should not read file metadata")
        return 1
      }
    }

    await #expect(throws: CancellationError.self) {
      try await validation.value
    }
  }
}

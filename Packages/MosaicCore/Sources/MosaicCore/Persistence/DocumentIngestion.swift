import Foundation
import PDFKit
import UniformTypeIdentifiers

public struct ExtractedDocumentChunk: Hashable, Sendable {
  public let index: Int
  public let content: String
  public let pageNumber: Int?
  public let isOCRDerived: Bool

  public init(
    index: Int,
    content: String,
    pageNumber: Int?,
    isOCRDerived: Bool = false
  ) {
    self.index = index
    self.content = content
    self.pageNumber = pageNumber
    self.isOCRDerived = isOCRDerived
  }
}

public struct ImportedDocumentPayload: Hashable, Sendable {
  public let title: String
  public let sourceFilename: String
  public let mimeType: String
  public let contentFingerprint: String
  public let characterCount: Int
  public let pageCount: Int?
  public let ocrPageCount: Int
  public let ocrFallbackPageCount: Int
  public let chunks: [ExtractedDocumentChunk]

  public init(
    title: String,
    sourceFilename: String,
    mimeType: String,
    contentFingerprint: String,
    characterCount: Int,
    pageCount: Int?,
    chunks: [ExtractedDocumentChunk],
    ocrPageCount: Int = 0,
    ocrFallbackPageCount: Int = 0
  ) {
    self.title = title
    self.sourceFilename = sourceFilename
    self.mimeType = mimeType
    self.contentFingerprint = contentFingerprint
    self.characterCount = characterCount
    self.pageCount = pageCount
    self.ocrPageCount = ocrPageCount
    self.ocrFallbackPageCount = ocrFallbackPageCount
    self.chunks = chunks
  }
}

public enum DocumentIngestionError: LocalizedError, Equatable, Sendable {
  case fileTooLarge
  case unsupportedType
  case unreadable
  case lockedPDF
  case noExtractableText
  case ocrPageLimitExceeded(maximumPages: Int)
  case ocrFailed(pageNumber: Int)

  public var errorDescription: String? {
    switch self {
    case .fileTooLarge:
      "The document is too large. Turing AI currently accepts files up to 50 MB and 3 million extracted characters."
    case .unsupportedType:
      "Turing AI currently imports text, Markdown, and PDF files."
    case .unreadable:
      "Turing AI could not read this document."
    case .lockedPDF:
      "This PDF is password-protected. Unlock it, save an unprotected copy, and import that copy."
    case .noExtractableText:
      "Turing AI could not find readable text in this PDF, even after on-device OCR. Try a clearer scan or export it as text or Markdown."
    case .ocrPageLimitExceeded(let maximumPages):
      "This PDF needs OCR on more than \(maximumPages) pages. Split the scanned PDF into smaller files and import them separately."
    case .ocrFailed(let pageNumber):
      "On-device OCR could not process page \(pageNumber). Try a clearer scan or export that page as a new PDF."
    }
  }
}

struct PDFExtractedText: Equatable {
  let sections: [(page: Int?, text: String)]
  let characterCount: Int
  let ocrPageCount: Int
  let ocrFallbackPageCount: Int
  let ocrPageNumbers: Set<Int>

  static func == (lhs: PDFExtractedText, rhs: PDFExtractedText) -> Bool {
    lhs.characterCount == rhs.characterCount
      && lhs.ocrPageCount == rhs.ocrPageCount
      && lhs.ocrFallbackPageCount == rhs.ocrFallbackPageCount
      && lhs.ocrPageNumbers == rhs.ocrPageNumbers
      && lhs.sections.count == rhs.sections.count
      && zip(lhs.sections, rhs.sections).allSatisfy { pair in
        pair.0.page == pair.1.page && pair.0.text == pair.1.text
      }
  }
}

public enum DocumentIngestor {
  private static let maximumFileBytes = 50 * 1_024 * 1_024
  private static let maximumCharacters = 3_000_000
  private static let maximumOCRPages = 200

  public static func importDocument(at url: URL) throws -> ImportedDocumentPayload {
    try Task.checkCancellation()
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }

    let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
    try Task.checkCancellation()
    if let size = resourceValues?.fileSize, size > maximumFileBytes {
      throw DocumentIngestionError.fileTooLarge
    }

    let contentType =
      resourceValues?.contentType
      ?? UTType(filenameExtension: url.pathExtension)
    if contentType?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
      return try importPDF(at: url)
    }
    if contentType?.conforms(to: .text) == true
      || ["txt", "md", "markdown"].contains(url.pathExtension.lowercased())
    {
      return try importText(at: url, contentType: contentType)
    }
    throw DocumentIngestionError.unsupportedType
  }

  private static func importPDF(at url: URL) throws -> ImportedDocumentPayload {
    try Task.checkCancellation()
    guard let document = PDFDocument(url: url) else {
      throw DocumentIngestionError.unreadable
    }
    try Task.checkCancellation()
    guard !document.isLocked else {
      throw DocumentIngestionError.lockedPDF
    }

    let recognizer = VisionPDFPageTextRecognizer()
    let extraction = try extractPDFText(from: document) { page, _ in
      try recognizer.recognizeText(in: page)
    }
    try Task.checkCancellation()
    let chunks = DocumentTextChunker().chunks(
      from: extraction.sections,
      ocrPageNumbers: extraction.ocrPageNumbers
    )
    try Task.checkCancellation()
    return ImportedDocumentPayload(
      title: displayTitle(for: url),
      sourceFilename: url.lastPathComponent,
      mimeType: UTType.pdf.preferredMIMEType ?? "application/pdf",
      contentFingerprint: EmbeddingVectorCodec.fingerprint(
        for: extraction.sections.map(\.text).joined(separator: "\n")
      ),
      characterCount: extraction.characterCount,
      pageCount: document.pageCount,
      chunks: chunks,
      ocrPageCount: extraction.ocrPageCount,
      ocrFallbackPageCount: extraction.ocrFallbackPageCount
    )
  }

  static func extractPDFText(
    from document: PDFDocument,
    maximumOCRPages: Int = maximumOCRPages,
    checkCancellation: () throws -> Void = { try Task.checkCancellation() },
    recognizeText: (PDFPage, Int) throws -> String
  ) throws -> PDFExtractedText {
    try checkCancellation()
    var embeddedCharacterCount = 0
    let pages = try (0..<document.pageCount).compactMap { pageIndex -> (PDFPage, Int, String)? in
      try checkCancellation()
      guard let page = document.page(at: pageIndex) else { return nil }
      let embeddedText = page.string ?? ""
      try checkCancellation()
      embeddedCharacterCount += embeddedText.count
      guard embeddedCharacterCount <= maximumCharacters else {
        throw DocumentIngestionError.fileTooLarge
      }
      return (page, pageIndex + 1, embeddedText)
    }
    try checkCancellation()
    let ocrPlan = try PDFPageTextSelector.ocrPlan(
      for: pages.map(\.2),
      maximumOCRPages: maximumOCRPages
    )

    var sections: [(page: Int?, text: String)] = []
    var characterCount = 0
    var ocrPageCount = 0
    var ocrFallbackPageCount = 0
    var ocrPageNumbers: Set<Int> = []
    for (pageIndex, pageData) in pages.enumerated() {
      try checkCancellation()
      let (page, pageNumber, embeddedText) = pageData
      let selection: PDFPageTextSelection?
      if ocrPlan.shouldRunOCR[pageIndex] {
        do {
          let recognizedText = try autoreleasepool {
            try checkCancellation()
            return try recognizeText(page, pageNumber)
          }
          try checkCancellation()
          selection = PDFPageTextSelector.select(
            embeddedText: embeddedText,
            recognizedText: recognizedText
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          guard !ocrPlan.requiresOCR[pageIndex] else {
            throw DocumentIngestionError.ocrFailed(pageNumber: pageNumber)
          }
          selection = PDFPageTextSelector.embeddedSelection(from: embeddedText)
        }
      } else {
        selection = PDFPageTextSelector.embeddedSelection(from: embeddedText)
      }

      try checkCancellation()
      guard let selection else { continue }
      characterCount += selection.text.count
      guard characterCount <= maximumCharacters else {
        throw DocumentIngestionError.fileTooLarge
      }
      sections.append((pageNumber, selection.text))
      if selection.source == .ocr {
        ocrPageCount += 1
        ocrPageNumbers.insert(pageNumber)
      } else if PDFPageTextSelector.shouldRunOCR(for: embeddedText) {
        ocrFallbackPageCount += 1
      }
    }
    guard !sections.isEmpty else { throw DocumentIngestionError.noExtractableText }
    return PDFExtractedText(
      sections: sections,
      characterCount: characterCount,
      ocrPageCount: ocrPageCount,
      ocrFallbackPageCount: ocrFallbackPageCount,
      ocrPageNumbers: ocrPageNumbers
    )
  }

  private static func importText(
    at url: URL,
    contentType: UTType?
  ) throws -> ImportedDocumentPayload {
    try Task.checkCancellation()
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
      throw DocumentIngestionError.unreadable
    }
    try Task.checkCancellation()
    guard data.count <= maximumFileBytes,
      let text = String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .utf16)
    else {
      throw DocumentIngestionError.unreadable
    }
    try Task.checkCancellation()
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw DocumentIngestionError.noExtractableText }
    guard trimmed.count <= maximumCharacters else { throw DocumentIngestionError.fileTooLarge }
    try Task.checkCancellation()
    let chunks = DocumentTextChunker().chunks(from: [(nil, trimmed)])
    try Task.checkCancellation()
    return ImportedDocumentPayload(
      title: displayTitle(for: url),
      sourceFilename: url.lastPathComponent,
      mimeType: contentType?.preferredMIMEType ?? "text/plain",
      contentFingerprint: EmbeddingVectorCodec.fingerprint(for: trimmed),
      characterCount: trimmed.count,
      pageCount: nil,
      chunks: chunks
    )
  }

  private static func displayTitle(for url: URL) -> String {
    let title = url.deletingPathExtension().lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? url.lastPathComponent : title
  }
}

public struct DocumentTextChunker: Sendable {
  public let maximumCharacters: Int
  public let overlapCharacters: Int

  public init(maximumCharacters: Int = 1_200, overlapCharacters: Int = 180) {
    self.maximumCharacters = max(200, maximumCharacters)
    self.overlapCharacters = max(0, min(overlapCharacters, self.maximumCharacters / 3))
  }

  public func chunks(
    from sections: [(page: Int?, text: String)],
    ocrPageNumbers: Set<Int> = []
  ) -> [ExtractedDocumentChunk] {
    var result: [ExtractedDocumentChunk] = []
    for section in sections {
      let normalized = section.text
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
      guard !normalized.isEmpty else { continue }
      var start = normalized.startIndex
      while start < normalized.endIndex {
        let hardEnd =
          normalized.index(
            start,
            offsetBy: maximumCharacters,
            limitedBy: normalized.endIndex
          ) ?? normalized.endIndex
        let end = preferredBoundary(in: normalized, start: start, hardEnd: hardEnd)
        let content = String(normalized[start..<end])
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
          result.append(
            ExtractedDocumentChunk(
              index: result.count,
              content: content,
              pageNumber: section.page,
              isOCRDerived: section.page.map(ocrPageNumbers.contains) ?? false
            )
          )
        }
        guard end < normalized.endIndex else { break }
        let overlapStart =
          normalized.index(
            end,
            offsetBy: -overlapCharacters,
            limitedBy: start
          ) ?? end
        let nextWord =
          normalized[overlapStart..<end].firstIndex(of: " ")
          .map { normalized.index(after: $0) } ?? overlapStart
        start = nextWord > start ? nextWord : end
      }
    }
    return result
  }

  private func preferredBoundary(
    in text: String,
    start: String.Index,
    hardEnd: String.Index
  ) -> String.Index {
    guard hardEnd < text.endIndex else { return text.endIndex }
    let minimum =
      text.index(
        start,
        offsetBy: maximumCharacters * 2 / 3,
        limitedBy: hardEnd
      ) ?? start
    var cursor = hardEnd
    while cursor > minimum {
      let previous = text.index(before: cursor)
      if text[previous] == " " { return previous }
      cursor = previous
    }
    return hardEnd
  }
}

import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import MosaicCore

struct DocumentOCRTests {
  @Test
  func shortEmbeddedHeaderUsesOCRWithoutDuplicatingThePage() throws {
    let embedded = "CONFIDENTIAL • Page 4"
    let recognized =
      "Bu taranmış sayfanın gövdesinde sözleşmenin fesih koşulları ve ödeme tarihleri ayrıntılı olarak açıklanıyor."

    #expect(PDFPageTextSelector.shouldRunOCR(for: embedded))
    let selection = try #require(
      PDFPageTextSelector.select(embeddedText: embedded, recognizedText: recognized)
    )

    #expect(selection.source == .ocr)
    #expect(selection.text == recognized)
    #expect(!selection.text.contains(embedded))
  }

  @Test
  func usefulEmbeddedTextWinsWithoutAnOCRMerge() throws {
    let embedded = Array(
      repeating: "Bu dijital PDF metni güvenilir ve doğrudan çıkarılabilir.",
      count: 12
    ).joined(separator: " ")
    let recognized = embedded + " OCR tarafından eklenmiş olası tekrar."

    #expect(!PDFPageTextSelector.shouldRunOCR(for: embedded))
    let selection = try #require(
      PDFPageTextSelector.select(embeddedText: embedded, recognizedText: recognized)
    )

    #expect(selection.source == .embedded)
    #expect(selection.text == embedded)
  }

  @Test
  func weakOCROutputFallsBackToExistingShortText() throws {
    let selection = try #require(
      PDFPageTextSelector.select(
        embeddedText: "İmzalar ve ekler",
        recognizedText: "..."
      )
    )

    #expect(selection.source == .embedded)
    #expect(selection.text == "İmzalar ve ekler")
  }

  @Test
  func recognizedLinesAreDeterministicAndOverlappingDuplicatesAreRemoved() {
    let lines = [
      OCRTextLine(
        text: "Alt satır", boundingBox: CGRect(x: 0.1, y: 0.60, width: 0.4, height: 0.04)),
      OCRTextLine(text: "Üst sağ", boundingBox: CGRect(x: 0.55, y: 0.88, width: 0.3, height: 0.04)),
      OCRTextLine(
        text: "Üst sol", boundingBox: CGRect(x: 0.10, y: 0.881, width: 0.3, height: 0.04)),
      OCRTextLine(
        text: "  üst   sol  ", boundingBox: CGRect(x: 0.101, y: 0.882, width: 0.3, height: 0.04)),
    ]

    #expect(OCRTextAssembler.assemble(lines) == "Üst sol\nÜst sağ\nAlt satır")
    #expect(OCRTextAssembler.assemble(lines.reversed()) == "Üst sol\nÜst sağ\nAlt satır")
  }

  @Test
  func scannedPagesUseOCRAndPreservePageNumbers() throws {
    let document = try makeBlankPDF(pageCount: 2)

    let extraction = try DocumentIngestor.extractPDFText(
      from: document,
      maximumOCRPages: 2
    ) { _, pageNumber in
      "OCR ile okunan sayfa \(pageNumber), önemli içerik burada."
    }

    #expect(extraction.ocrPageCount == 2)
    #expect(extraction.ocrFallbackPageCount == 0)
    #expect(extraction.ocrPageNumbers == [1, 2])
    #expect(extraction.sections.map(\.page) == [1, 2])
    #expect(
      extraction.sections.map(\.text) == [
        "OCR ile okunan sayfa 1, önemli içerik burada.",
        "OCR ile okunan sayfa 2, önemli içerik burada.",
      ])
    #expect(extraction.characterCount == extraction.sections.map(\.text.count).reduce(0, +))
  }

  @Test
  func shortEmbeddedPagesFallBackAfterOptionalOCRBudgetIsExhausted() throws {
    let shortEmbeddedPages = (1...201).map { "Kısa geçerli sayfa \($0)" }

    let plan = try PDFPageTextSelector.ocrPlan(
      for: shortEmbeddedPages,
      maximumOCRPages: 1
    )

    #expect(plan.shouldRunOCR.filter { $0 }.count == 1)
    #expect(plan.requiresOCR.filter { $0 }.isEmpty)
    #expect(plan.embeddedFallbackPageCount == 200)
  }

  @Test
  func blankPagesKeepPriorityOverOptionalOCRCandidates() throws {
    let plan = try PDFPageTextSelector.ocrPlan(
      for: ["Kısa başlık", "", "Kısa dipnot"],
      maximumOCRPages: 1
    )

    #expect(plan.shouldRunOCR == [false, true, false])
    #expect(plan.requiresOCR == [false, true, false])
    #expect(plan.embeddedFallbackPageCount == 2)
  }

  @Test
  func optionalOCRFailureFallsBackWithoutRejectingEmbeddedText() throws {
    struct SampleError: Error {}
    let document = try makePDF(withText: "Short but valid content")

    let extraction = try DocumentIngestor.extractPDFText(
      from: document,
      maximumOCRPages: 1
    ) { _, _ in
      throw SampleError()
    }

    #expect(extraction.sections.map(\.text) == ["Short but valid content"])
    #expect(extraction.ocrPageCount == 0)
    #expect(extraction.ocrFallbackPageCount == 1)
  }

  @Test
  func ocrPageLimitIsCheckedBeforeExpensiveRecognitionStarts() throws {
    let document = try makeBlankPDF(pageCount: 2)
    var recognitionCallCount = 0

    #expect(throws: DocumentIngestionError.ocrPageLimitExceeded(maximumPages: 1)) {
      try DocumentIngestor.extractPDFText(
        from: document,
        maximumOCRPages: 1
      ) { _, _ in
        recognitionCallCount += 1
        return "unreachable"
      }
    }
    #expect(recognitionCallCount == 0)
  }

  @Test
  func extractionObservesCancellationDuringPagePreparation() throws {
    let document = try makeBlankPDF(pageCount: 2)
    var cancellationChecks = 0
    var recognitionCallCount = 0

    #expect(throws: CancellationError.self) {
      try DocumentIngestor.extractPDFText(
        from: document,
        maximumOCRPages: 2,
        checkCancellation: {
          cancellationChecks += 1
          if cancellationChecks == 3 { throw CancellationError() }
        },
        recognizeText: { _, _ in
          recognitionCallCount += 1
          return "unreachable"
        }
      )
    }
    #expect(recognitionCallCount == 0)
  }

  @Test
  func visionFailureIsReportedWithTheAffectedPage() throws {
    struct SampleError: Error {}
    let document = try makeBlankPDF(pageCount: 2)

    #expect(throws: DocumentIngestionError.ocrFailed(pageNumber: 2)) {
      try DocumentIngestor.extractPDFText(
        from: document,
        maximumOCRPages: 2
      ) { _, pageNumber in
        if pageNumber == 2 { throw SampleError() }
        return "Birinci sayfada OCR ile okunan metin bulunuyor."
      }
    }
  }

  @Test
  func emptyOCRResultHasAnActionableNoTextError() throws {
    let document = try makeBlankPDF(pageCount: 1)

    #expect(throws: DocumentIngestionError.noExtractableText) {
      try DocumentIngestor.extractPDFText(
        from: document,
        maximumOCRPages: 1
      ) { _, _ in "" }
    }
  }

  private func makeBlankPDF(pageCount: Int) throws -> PDFDocument {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
      throw PDFTestFixtureError.couldNotCreatePDF
    }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
      throw PDFTestFixtureError.couldNotCreatePDF
    }
    for _ in 0..<pageCount {
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(mediaBox)
      context.endPDFPage()
    }
    context.closePDF()
    guard let document = PDFDocument(data: data as Data) else {
      throw PDFTestFixtureError.couldNotCreatePDF
    }
    return document
  }

  private func makePDF(withText text: String) throws -> PDFDocument {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
      throw PDFTestFixtureError.couldNotCreatePDF
    }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
      throw PDFTestFixtureError.couldNotCreatePDF
    }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: text,
        attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
      )
    )
    context.textPosition = CGPoint(x: 72, y: 720)
    CTLineDraw(line, context)
    context.endPDFPage()
    context.closePDF()
    guard let document = PDFDocument(data: data as Data) else {
      throw PDFTestFixtureError.couldNotCreatePDF
    }
    return document
  }
}

private enum PDFTestFixtureError: Error {
  case couldNotCreatePDF
}

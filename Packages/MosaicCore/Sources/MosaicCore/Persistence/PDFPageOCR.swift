import CoreGraphics
import Foundation
import PDFKit
import Vision

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

enum PDFPageTextSource: Equatable {
  case embedded
  case ocr
}

struct PDFPageTextSelection: Equatable {
  let text: String
  let source: PDFPageTextSource
}

struct PDFPageOCRPlan: Equatable {
  let shouldRunOCR: [Bool]
  let requiresOCR: [Bool]
  let embeddedFallbackPageCount: Int
}

enum PDFPageTextSelector {
  // A short digital header or page number can coexist with a scanned page body.
  // Requiring both enough characters and enough words sends those mixed pages to OCR.
  static let minimumMeaningfulCharacters = 80
  static let minimumWords = 8

  static func shouldRunOCR(for embeddedText: String) -> Bool {
    !metrics(for: embeddedText).isUsefulEmbeddedText
  }

  /// Reserves the bounded OCR budget for pages that have no usable embedded text.
  /// Short but valid embedded pages can still receive OCR while capacity remains;
  /// after that they safely fall back to their existing text instead of rejecting
  /// the complete document.
  static func ocrPlan(
    for embeddedTexts: [String],
    maximumOCRPages: Int
  ) throws -> PDFPageOCRPlan {
    let pageLimit = max(0, maximumOCRPages)
    let mandatoryPages = embeddedTexts.indices.filter {
      !canSafelyUseEmbeddedFallback(embeddedTexts[$0])
    }
    guard mandatoryPages.count <= pageLimit else {
      throw DocumentIngestionError.ocrPageLimitExceeded(maximumPages: pageLimit)
    }

    var decisions = Array(repeating: false, count: embeddedTexts.count)
    var required = Array(repeating: false, count: embeddedTexts.count)
    for index in mandatoryPages { decisions[index] = true }
    for index in mandatoryPages { required[index] = true }

    var optionalBudget = pageLimit - mandatoryPages.count
    var embeddedFallbackPageCount = 0
    let optionalPages = embeddedTexts.indices.filter {
      !decisions[$0] && shouldRunOCR(for: embeddedTexts[$0])
    }.sorted {
      let left = metrics(for: embeddedTexts[$0]).qualityScore
      let right = metrics(for: embeddedTexts[$1]).qualityScore
      return left == right ? $0 < $1 : left < right
    }
    for index in optionalPages {
      if optionalBudget > 0 {
        decisions[index] = true
        optionalBudget -= 1
      } else {
        embeddedFallbackPageCount += 1
      }
    }
    return PDFPageOCRPlan(
      shouldRunOCR: decisions,
      requiresOCR: required,
      embeddedFallbackPageCount: embeddedFallbackPageCount
    )
  }

  private static func canSafelyUseEmbeddedFallback(_ text: String) -> Bool {
    let textMetrics = metrics(for: normalizedForStorage(text))
    return textMetrics.meaningfulCharacterCount > 0
      && textMetrics.noisyCharacterCount * 20 <= max(1, textMetrics.scalarCount)
  }

  static func embeddedSelection(from text: String) -> PDFPageTextSelection? {
    let normalized = normalizedForStorage(text)
    guard metrics(for: normalized).meaningfulCharacterCount > 0 else { return nil }
    return PDFPageTextSelection(text: normalized, source: .embedded)
  }

  static func select(
    embeddedText: String,
    recognizedText: String
  ) -> PDFPageTextSelection? {
    let embedded = normalizedForStorage(embeddedText)
    let recognized = normalizedForStorage(recognizedText)
    let embeddedMetrics = metrics(for: embedded)
    let recognizedMetrics = metrics(for: recognized)

    if embeddedMetrics.isUsefulEmbeddedText {
      return PDFPageTextSelection(text: embedded, source: .embedded)
    }
    guard recognizedMetrics.meaningfulCharacterCount > 0 else {
      return embeddedSelection(from: embedded)
    }
    guard embeddedMetrics.meaningfulCharacterCount > 0 else {
      return PDFPageTextSelection(text: recognized, source: .ocr)
    }

    // Choose one representation of the page instead of concatenating embedded and
    // OCR text. This prevents the common hidden-text-layer duplication failure.
    let meaningfulGain =
      recognizedMetrics.meaningfulCharacterCount - embeddedMetrics.meaningfulCharacterCount
    let scoreGain = recognizedMetrics.qualityScore - embeddedMetrics.qualityScore
    if recognizedMetrics.isUsefulEmbeddedText
      || meaningfulGain >= 12
      || scoreGain >= max(16, embeddedMetrics.qualityScore / 5)
    {
      return PDFPageTextSelection(text: recognized, source: .ocr)
    }
    return PDFPageTextSelection(text: embedded, source: .embedded)
  }

  private struct TextMetrics {
    let meaningfulCharacterCount: Int
    let wordCount: Int
    let noisyCharacterCount: Int
    let scalarCount: Int

    var isUsefulEmbeddedText: Bool {
      meaningfulCharacterCount >= minimumMeaningfulCharacters
        && wordCount >= minimumWords
        && noisyCharacterCount * 20 <= max(1, scalarCount)
    }

    var qualityScore: Int {
      meaningfulCharacterCount * 2 + min(wordCount, 2_000) * 4 - noisyCharacterCount * 24
    }
  }

  private static func metrics(for text: String) -> TextMetrics {
    let scalars = text.unicodeScalars
    let meaningfulCharacterCount = scalars.lazy.filter {
      CharacterSet.alphanumerics.contains($0)
    }.count
    let noisyCharacterCount = scalars.lazy.filter {
      $0.value == 0xFFFD
        || (CharacterSet.controlCharacters.contains($0)
          && !CharacterSet.whitespacesAndNewlines.contains($0))
    }.count
    let wordCount = text.split(whereSeparator: \.isWhitespace).lazy.filter { word in
      word.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }.count
    return TextMetrics(
      meaningfulCharacterCount: meaningfulCharacterCount,
      wordCount: wordCount,
      noisyCharacterCount: noisyCharacterCount,
      scalarCount: scalars.count
    )
  }

  private static func normalizedForStorage(_ text: String) -> String {
    text.components(separatedBy: .newlines)
      .map { line in
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct OCRTextLine: Equatable {
  let text: String
  let boundingBox: CGRect
}

enum OCRTextAssembler {
  private static let rowHeight: CGFloat = 0.0125

  static func assemble(_ lines: [OCRTextLine]) -> String {
    let sorted =
      lines
      .map {
        OCRTextLine(
          text: $0.text.split(whereSeparator: \.isWhitespace).joined(separator: " "),
          boundingBox: $0.boundingBox
        )
      }
      .filter { !$0.text.isEmpty }
      .sorted(by: comesBefore)

    var accepted: [OCRTextLine] = []
    for line in sorted {
      let canonical = line.text.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
      let isOverlappingDuplicate = accepted.contains { existing in
        existing.text.folding(
          options: [.caseInsensitive, .diacriticInsensitive],
          locale: Locale(identifier: "en_US_POSIX")
        ) == canonical && overlapRatio(existing.boundingBox, line.boundingBox) >= 0.6
      }
      if !isOverlappingDuplicate {
        accepted.append(line)
      }
    }
    return accepted.map(\.text).joined(separator: "\n")
  }

  private static func comesBefore(_ lhs: OCRTextLine, _ rhs: OCRTextLine) -> Bool {
    let lhsRow = Int(((1 - lhs.boundingBox.maxY) / rowHeight).rounded(.down))
    let rhsRow = Int(((1 - rhs.boundingBox.maxY) / rowHeight).rounded(.down))
    if lhsRow != rhsRow { return lhsRow < rhsRow }
    if lhs.boundingBox.minX != rhs.boundingBox.minX {
      return lhs.boundingBox.minX < rhs.boundingBox.minX
    }
    if lhs.boundingBox.maxY != rhs.boundingBox.maxY {
      return lhs.boundingBox.maxY > rhs.boundingBox.maxY
    }
    return lhs.text < rhs.text
  }

  private static func overlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull, !intersection.isEmpty else { return 0 }
    let smallerArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
    guard smallerArea > 0 else { return 0 }
    return intersection.width * intersection.height / smallerArea
  }
}

struct VisionPDFPageTextRecognizer {
  private static let maximumRenderedPixels = 12_000_000
  private static let maximumPixelDimension: CGFloat = 4_096
  private static let preferredScale: CGFloat = 2.5

  func recognizeText(in page: PDFPage) throws -> String {
    guard let image = renderedImage(for: page) else {
      throw PDFPageOCRError.renderFailed
    }

    let request = VNRecognizeTextRequest()
    request.revision = VNRecognizeTextRequestRevision3
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    let supportedLanguages = (try? request.supportedRecognitionLanguages()) ?? []
    let preferredLanguages = ["tr-TR", "en-US"].compactMap { language in
      supportedLanguages.first { supported in
        supported.caseInsensitiveCompare(language) == .orderedSame
          || supported.lowercased().hasPrefix(language.prefix(2).lowercased())
      }
    }
    if !preferredLanguages.isEmpty {
      request.recognitionLanguages = preferredLanguages
    }

    let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
    try handler.perform([request])
    let lines = (request.results ?? []).compactMap { observation -> OCRTextLine? in
      guard let candidate = observation.topCandidates(1).first,
        candidate.confidence >= 0.2
      else { return nil }
      return OCRTextLine(text: candidate.string, boundingBox: observation.boundingBox)
    }
    return OCRTextAssembler.assemble(lines)
  }

  private func renderedImage(for page: PDFPage) -> CGImage? {
    let bounds = page.bounds(for: .cropBox)
    var width = abs(bounds.width)
    var height = abs(bounds.height)
    let normalizedRotation = ((page.rotation % 360) + 360) % 360
    if normalizedRotation == 90 || normalizedRotation == 270 {
      swap(&width, &height)
    }
    guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }

    let pagePixels = width * height
    let pixelCapScale = sqrt(CGFloat(Self.maximumRenderedPixels) / pagePixels)
    let dimensionCapScale = Self.maximumPixelDimension / max(width, height)
    let scale = min(Self.preferredScale, pixelCapScale, dimensionCapScale)
    let targetSize = CGSize(
      width: max(1, floor(width * scale)),
      height: max(1, floor(height * scale))
    )
    let thumbnail = page.thumbnail(of: targetSize, for: .cropBox)

    #if canImport(AppKit)
      var proposedRect = CGRect(origin: .zero, size: thumbnail.size)
      return thumbnail.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    #elseif canImport(UIKit)
      return thumbnail.cgImage
    #else
      return nil
    #endif
  }
}

private enum PDFPageOCRError: Error {
  case renderFailed
}

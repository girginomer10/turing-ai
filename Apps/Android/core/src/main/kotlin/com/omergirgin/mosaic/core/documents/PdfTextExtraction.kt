package com.omergirgin.mosaic.core.documents

import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Selected page texts of one PDF plus OCR provenance (iOS `PDFExtractedText`). */
data class PdfExtractedText(
  val sections: List<DocumentSection>,
  val characterCount: Int,
  val ocrPageCount: Int,
  val ocrFallbackPageCount: Int,
  val ocrPageNumbers: Set<Int>,
) {
  /** Fingerprint input: selected page texts joined by newlines (iOS parity). */
  val joinedText: String get() = sections.joinToString("\n") { it.text }
}

/**
 * Platform-independent half of iOS `DocumentIngestor.extractPDFText`: given each page's embedded
 * text layer, plans OCR, asks [recognizeText] for planned pages and keeps one representation per
 * page. Rendering and recognition live in the data layer.
 */
object PdfTextExtraction {
  /**
   * @param embeddedTexts embedded text per page, index 0 = page 1.
   * @param onOcrPage called before each OCR page with (ordinal, planned total, 1-based page).
   * @param recognizeText recognizes the 0-based page; any non-cancellation failure falls back to
   *   embedded text for optional pages and fails the document for required ones.
   */
  suspend fun extract(
    embeddedTexts: List<String>,
    maximumOcrPages: Int = DocumentLimits.MAXIMUM_OCR_PAGES,
    maximumCharacters: Int = DocumentLimits.MAXIMUM_CHARACTERS,
    onOcrPage: (ordinal: Int, total: Int, pageNumber: Int) -> Unit = { _, _, _ -> },
    recognizeText: suspend (pageIndex: Int) -> String,
  ): PdfExtractedText {
    currentCoroutineContext().ensureActive()
    val plan = PdfPageTextSelector.ocrPlan(embeddedTexts, maximumOcrPages)
    val plannedOcrPages = plan.shouldRunOcr.count { it }
    var ocrOrdinal = 0

    val sections = ArrayList<DocumentSection>()
    var characterCount = 0
    var ocrPageCount = 0
    var ocrFallbackPageCount = 0
    val ocrPageNumbers = LinkedHashSet<Int>()
    for ((pageIndex, embeddedText) in embeddedTexts.withIndex()) {
      currentCoroutineContext().ensureActive()
      val pageNumber = pageIndex + 1
      val selection = if (plan.shouldRunOcr[pageIndex]) {
        ocrOrdinal++
        try {
          onOcrPage(ocrOrdinal, plannedOcrPages, pageNumber)
          val recognized = recognizeText(pageIndex)
          currentCoroutineContext().ensureActive()
          PdfPageTextSelector.select(embeddedText, recognized)
        } catch (cancellation: CancellationException) {
          throw cancellation
        } catch (error: Exception) {
          if (plan.requiresOcr[pageIndex]) throw DocumentIngestionException.OcrFailed(pageNumber)
          PdfPageTextSelector.embeddedSelection(embeddedText)
        }
      } else {
        PdfPageTextSelector.embeddedSelection(embeddedText)
      }

      currentCoroutineContext().ensureActive()
      if (selection == null) continue
      characterCount += DocumentText.characterCount(selection.text)
      if (characterCount > maximumCharacters) throw DocumentIngestionException.FileTooLarge()
      sections += DocumentSection(pageNumber, selection.text)
      if (selection.source == PdfPageTextSource.OCR) {
        ocrPageCount += 1
        ocrPageNumbers += pageNumber
      } else if (PdfPageTextSelector.shouldRunOcr(embeddedText)) {
        ocrFallbackPageCount += 1
      }
    }
    if (sections.isEmpty()) throw DocumentIngestionException.NoExtractableText(isPdf = true)
    return PdfExtractedText(sections, characterCount, ocrPageCount, ocrFallbackPageCount, ocrPageNumbers)
  }
}

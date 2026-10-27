package com.omergirgin.mosaic.core.documents

enum class PdfPageTextSource { EMBEDDED, OCR }

data class PdfPageTextSelection(val text: String, val source: PdfPageTextSource)

data class PdfPageOcrPlan(
  val shouldRunOcr: List<Boolean>,
  /** Pages without any safe embedded fallback; their OCR failure fails the document. */
  val requiresOcr: List<Boolean>,
  val embeddedFallbackPageCount: Int,
)

/**
 * Port of iOS `PDFPageTextSelector`: decides whether a page's embedded text layer is useful,
 * plans the bounded OCR budget and keeps exactly one representation per page.
 */
object PdfPageTextSelector {
  // A short digital header or page number can coexist with a scanned page body. Requiring both
  // enough characters and enough words sends those mixed pages to OCR.
  const val MINIMUM_MEANINGFUL_CHARACTERS = 80
  const val MINIMUM_WORDS = 8

  fun shouldRunOcr(embeddedText: String): Boolean = !metrics(embeddedText).isUsefulEmbeddedText

  /**
   * Reserves the OCR budget for pages with no usable embedded text. Short but valid embedded
   * pages still get OCR while capacity remains (weakest first); after that they keep their
   * existing text instead of rejecting the whole document.
   */
  fun ocrPlan(embeddedTexts: List<String>, maximumOcrPages: Int): PdfPageOcrPlan {
    val pageLimit = maxOf(0, maximumOcrPages)
    val mandatoryPages = embeddedTexts.indices.filter { !canSafelyUseEmbeddedFallback(embeddedTexts[it]) }
    if (mandatoryPages.size > pageLimit) throw DocumentIngestionException.OcrPageLimitExceeded(pageLimit)

    val decisions = BooleanArray(embeddedTexts.size)
    val required = BooleanArray(embeddedTexts.size)
    for (index in mandatoryPages) {
      decisions[index] = true
      required[index] = true
    }

    var optionalBudget = pageLimit - mandatoryPages.size
    var embeddedFallbackPageCount = 0
    val optionalPages = embeddedTexts.indices
      .filter { !decisions[it] && shouldRunOcr(embeddedTexts[it]) }
      .map { it to metrics(embeddedTexts[it]).qualityScore }
      .sortedWith(compareBy({ it.second }, { it.first }))
      .map { it.first }
    for (index in optionalPages) {
      if (optionalBudget > 0) {
        decisions[index] = true
        optionalBudget -= 1
      } else {
        embeddedFallbackPageCount += 1
      }
    }
    return PdfPageOcrPlan(decisions.toList(), required.toList(), embeddedFallbackPageCount)
  }

  fun embeddedSelection(text: String): PdfPageTextSelection? {
    val normalized = DocumentText.normalizedForStorage(text)
    if (metrics(normalized).meaningfulCharacterCount <= 0) return null
    return PdfPageTextSelection(normalized, PdfPageTextSource.EMBEDDED)
  }

  fun select(embeddedText: String, recognizedText: String): PdfPageTextSelection? {
    val embedded = DocumentText.normalizedForStorage(embeddedText)
    val recognized = DocumentText.normalizedForStorage(recognizedText)
    val embeddedMetrics = metrics(embedded)
    val recognizedMetrics = metrics(recognized)

    if (embeddedMetrics.isUsefulEmbeddedText) return PdfPageTextSelection(embedded, PdfPageTextSource.EMBEDDED)
    if (recognizedMetrics.meaningfulCharacterCount <= 0) return embeddedSelection(embedded)
    if (embeddedMetrics.meaningfulCharacterCount <= 0) return PdfPageTextSelection(recognized, PdfPageTextSource.OCR)

    // Choose one representation instead of concatenating embedded and OCR text; this prevents
    // the common hidden-text-layer duplication failure.
    val meaningfulGain = recognizedMetrics.meaningfulCharacterCount - embeddedMetrics.meaningfulCharacterCount
    val scoreGain = recognizedMetrics.qualityScore - embeddedMetrics.qualityScore
    return if (
      recognizedMetrics.isUsefulEmbeddedText ||
      meaningfulGain >= 12 ||
      scoreGain >= maxOf(16, embeddedMetrics.qualityScore / 5)
    ) {
      PdfPageTextSelection(recognized, PdfPageTextSource.OCR)
    } else {
      PdfPageTextSelection(embedded, PdfPageTextSource.EMBEDDED)
    }
  }

  private fun canSafelyUseEmbeddedFallback(text: String): Boolean {
    val textMetrics = metrics(DocumentText.normalizedForStorage(text))
    return textMetrics.meaningfulCharacterCount > 0 &&
      textMetrics.noisyCharacterCount * 20 <= maxOf(1, textMetrics.scalarCount)
  }

  internal data class TextMetrics(
    val meaningfulCharacterCount: Int,
    val wordCount: Int,
    val noisyCharacterCount: Int,
    val scalarCount: Int,
  ) {
    val isUsefulEmbeddedText: Boolean
      get() = meaningfulCharacterCount >= MINIMUM_MEANINGFUL_CHARACTERS &&
        wordCount >= MINIMUM_WORDS &&
        noisyCharacterCount * 20 <= maxOf(1, scalarCount)

    val qualityScore: Int
      get() = meaningfulCharacterCount * 2 + minOf(wordCount, 2_000) * 4 - noisyCharacterCount * 24
  }

  internal fun metrics(text: String): TextMetrics {
    var meaningful = 0
    var noisy = 0
    var scalars = 0
    var words = 0
    var inWord = false
    var wordHasAlphanumeric = false
    var index = 0
    while (index < text.length) {
      val cp = text.codePointAt(index)
      index += Character.charCount(cp)
      scalars++
      val alphanumeric = DocumentText.isAlphanumeric(cp)
      if (alphanumeric) meaningful++
      if (cp == 0xFFFD || (DocumentText.isControl(cp) && !DocumentText.isWhitespaceOrNewline(cp))) noisy++
      if (DocumentText.isWhitespace(cp)) {
        if (inWord && wordHasAlphanumeric) words++
        inWord = false
        wordHasAlphanumeric = false
      } else {
        inWord = true
        if (alphanumeric) wordHasAlphanumeric = true
      }
    }
    if (inWord && wordHasAlphanumeric) words++
    return TextMetrics(meaningful, words, noisy, scalars)
  }
}

package com.omergirgin.mosaic.core.documents

import java.text.Normalizer
import java.util.Locale
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** One recognized line. Coordinates are normalized to 0...1 with a top-left origin. */
data class OcrTextLine(
  val text: String,
  val left: Float,
  val top: Float,
  val right: Float,
  val bottom: Float,
) {
  internal val width: Float get() = right - left
  internal val height: Float get() = bottom - top
}

/**
 * Port of iOS `OCRTextAssembler`: orders lines into reading rows (top to bottom, then left to
 * right) and drops overlapping duplicates that recognizers sometimes report twice.
 */
object OcrTextAssembler {
  private const val ROW_HEIGHT = 0.0125f

  fun assemble(lines: List<OcrTextLine>): String {
    val sorted = lines
      .map { it.copy(text = DocumentText.collapseWhitespace(it.text)) }
      .filter { it.text.isNotEmpty() }
      .sortedWith(::compare)

    val accepted = ArrayList<OcrTextLine>()
    val acceptedKeys = ArrayList<String>()
    for (line in sorted) {
      val canonical = fold(line.text)
      val isOverlappingDuplicate = accepted.indices.any { index ->
        acceptedKeys[index] == canonical && overlapRatio(accepted[index], line) >= 0.6f
      }
      if (!isOverlappingDuplicate) {
        accepted += line
        acceptedKeys += canonical
      }
    }
    return accepted.joinToString("\n") { it.text }
  }

  private fun row(line: OcrTextLine): Int = floor(line.top / ROW_HEIGHT).toInt()

  private fun compare(lhs: OcrTextLine, rhs: OcrTextLine): Int {
    val lhsRow = row(lhs)
    val rhsRow = row(rhs)
    if (lhsRow != rhsRow) return lhsRow.compareTo(rhsRow)
    if (lhs.left != rhs.left) return lhs.left.compareTo(rhs.left)
    if (lhs.top != rhs.top) return lhs.top.compareTo(rhs.top)
    return lhs.text.compareTo(rhs.text)
  }

  /** Case- and diacritic-insensitive comparison key. */
  private fun fold(text: String): String =
    Normalizer.normalize(text, Normalizer.Form.NFD)
      .replace(Regex("\\p{Mn}+"), "")
      .lowercase(Locale.ROOT)

  private fun overlapRatio(lhs: OcrTextLine, rhs: OcrTextLine): Float {
    if (lhs.width <= 0f || lhs.height <= 0f || rhs.width <= 0f || rhs.height <= 0f) return 0f
    val width = min(lhs.right, rhs.right) - max(lhs.left, rhs.left)
    val height = min(lhs.bottom, rhs.bottom) - max(lhs.top, rhs.top)
    if (width <= 0f || height <= 0f) return 0f
    val smallerArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
    if (smallerArea <= 0f) return 0f
    return width * height / smallerArea
  }
}

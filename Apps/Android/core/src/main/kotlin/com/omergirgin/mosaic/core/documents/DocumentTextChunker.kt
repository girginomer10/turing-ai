package com.omergirgin.mosaic.core.documents

import kotlin.math.max
import kotlin.math.min

/**
 * Port of iOS `DocumentTextChunker`: whitespace-collapsed sections are cut into chunks of at most
 * [maximumCharacters] characters, preferring a space in the last third, with roughly
 * [overlapCharacters] of overlap starting at a word boundary. Chunks never span pages; each keeps
 * its 1-based page and whether the page text came from OCR. Character offsets are grapheme
 * clusters, matching Swift `String.Index` arithmetic.
 */
class DocumentTextChunker(maximumCharacters: Int = 1_200, overlapCharacters: Int = 180) {
  val maximumCharacters: Int = max(200, maximumCharacters)
  val overlapCharacters: Int = max(0, min(overlapCharacters, this.maximumCharacters / 3))

  /** [checkCancellation] runs before every chunk so a large document can be stopped promptly. */
  fun chunks(
    sections: List<DocumentSection>,
    ocrPageNumbers: Set<Int> = emptySet(),
    checkCancellation: () -> Unit = {},
  ): List<ExtractedDocumentChunk> {
    val result = ArrayList<ExtractedDocumentChunk>()
    for (section in sections) {
      checkCancellation()
      val normalized = DocumentText.collapseWhitespace(section.text)
      if (normalized.isEmpty()) continue
      val bounds = DocumentText.characterBoundaries(normalized)
      val count = bounds.size - 1
      val isOcrDerived = section.page?.let { it in ocrPageNumbers } ?: false

      fun isSpace(index: Int): Boolean = bounds[index + 1] - bounds[index] == 1 && normalized[bounds[index]] == ' '

      fun preferredBoundary(start: Int, hardEnd: Int): Int {
        if (hardEnd >= count) return count
        val preferredMinimum = start + maximumCharacters * 2 / 3
        val minimum = if (preferredMinimum <= hardEnd) preferredMinimum else start
        var cursor = hardEnd
        while (cursor > minimum) {
          val previous = cursor - 1
          if (isSpace(previous)) return previous
          cursor = previous
        }
        return hardEnd
      }

      var start = 0
      while (start < count) {
        checkCancellation()
        val hardEnd = min(start + maximumCharacters, count)
        val end = preferredBoundary(start, hardEnd)
        val content = DocumentText.trim(normalized.substring(bounds[start], bounds[end]))
        if (content.isNotEmpty()) {
          result += ExtractedDocumentChunk(
            index = result.size,
            content = content,
            pageNumber = section.page,
            isOcrDerived = isOcrDerived,
          )
        }
        if (end >= count) break
        val overlapStart = if (end - overlapCharacters >= start) end - overlapCharacters else end
        var nextWord = overlapStart
        for (index in overlapStart until end) {
          if (isSpace(index)) {
            nextWord = index + 1
            break
          }
        }
        start = if (nextWord > start) nextWord else end
      }
    }
    return result
  }
}

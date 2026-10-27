package com.omergirgin.mosaic.core.documents

import java.security.MessageDigest
import java.text.BreakIterator
import java.util.Locale

/**
 * Unicode helpers that reproduce the Foundation semantics used by iOS ingestion, so lengths,
 * whitespace handling and page-quality metrics match between platforms. "Characters" are
 * extended grapheme clusters (Swift `Character`); metrics count Unicode scalars.
 */
object DocumentText {
  /** Unicode White_Space (Swift `Character.isWhitespace`). */
  fun isWhitespace(codePoint: Int): Boolean = when (codePoint) {
    in 0x09..0x0D, 0x20, 0x85, 0xA0, 0x1680, in 0x2000..0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 -> true
    else -> false
  }

  /** Foundation `CharacterSet.newlines`. */
  fun isNewline(codePoint: Int): Boolean =
    codePoint in 0x0A..0x0D || codePoint == 0x85 || codePoint == 0x2028 || codePoint == 0x2029

  /** Foundation `CharacterSet.whitespacesAndNewlines`: Z*, tab and newlines. */
  fun isWhitespaceOrNewline(codePoint: Int): Boolean {
    if (codePoint == 0x09 || isNewline(codePoint)) return true
    return when (Character.getType(codePoint)) {
      Character.SPACE_SEPARATOR.toInt(), Character.LINE_SEPARATOR.toInt(), Character.PARAGRAPH_SEPARATOR.toInt() -> true
      else -> false
    }
  }

  /** Foundation `CharacterSet.alphanumerics`: letters, marks and numbers. */
  fun isAlphanumeric(codePoint: Int): Boolean = when (Character.getType(codePoint)) {
    Character.UPPERCASE_LETTER.toInt(), Character.LOWERCASE_LETTER.toInt(), Character.TITLECASE_LETTER.toInt(),
    Character.MODIFIER_LETTER.toInt(), Character.OTHER_LETTER.toInt(),
    Character.NON_SPACING_MARK.toInt(), Character.ENCLOSING_MARK.toInt(), Character.COMBINING_SPACING_MARK.toInt(),
    Character.DECIMAL_DIGIT_NUMBER.toInt(), Character.LETTER_NUMBER.toInt(), Character.OTHER_NUMBER.toInt() -> true
    else -> false
  }

  /** Foundation `CharacterSet.controlCharacters`: Cc and Cf. */
  fun isControl(codePoint: Int): Boolean = when (Character.getType(codePoint)) {
    Character.CONTROL.toInt(), Character.FORMAT.toInt() -> true
    else -> false
  }

  /** `trimmingCharacters(in: .whitespacesAndNewlines)`. */
  fun trim(text: String): String {
    var start = 0
    var end = text.length
    while (start < end) {
      val cp = text.codePointAt(start)
      if (!isWhitespaceOrNewline(cp)) break
      start += Character.charCount(cp)
    }
    while (end > start) {
      val cp = text.codePointBefore(end)
      if (!isWhitespaceOrNewline(cp)) break
      end -= Character.charCount(cp)
    }
    return if (start == 0 && end == text.length) text else text.substring(start, end)
  }

  /** `split(whereSeparator: \.isWhitespace).joined(separator: " ")`. */
  fun collapseWhitespace(text: String): String {
    val out = StringBuilder(text.length)
    var pendingSpace = false
    var index = 0
    while (index < text.length) {
      val cp = text.codePointAt(index)
      index += Character.charCount(cp)
      if (isWhitespace(cp)) {
        if (out.isNotEmpty()) pendingSpace = true
      } else {
        if (pendingSpace) out.append(' ')
        pendingSpace = false
        out.appendCodePoint(cp)
      }
    }
    return out.toString()
  }

  /**
   * One stored representation of a page: whitespace collapsed within each line, blank lines
   * dropped, lines joined with "\n" (iOS `PDFPageTextSelector.normalizedForStorage`).
   */
  fun normalizedForStorage(text: String): String {
    val out = StringBuilder(text.length)
    val line = StringBuilder()
    var pendingSpace = false
    fun flushLine() {
      if (line.isNotEmpty()) {
        if (out.isNotEmpty()) out.append('\n')
        out.append(line)
        line.setLength(0)
      }
      pendingSpace = false
    }
    var index = 0
    while (index < text.length) {
      val cp = text.codePointAt(index)
      index += Character.charCount(cp)
      when {
        isNewline(cp) -> flushLine()
        isWhitespace(cp) -> if (line.isNotEmpty()) pendingSpace = true
        else -> {
          if (pendingSpace) line.append(' ')
          pendingSpace = false
          line.appendCodePoint(cp)
        }
      }
    }
    flushLine()
    return trim(out.toString())
  }

  /** Swift `String.count` (extended grapheme clusters). */
  fun characterCount(text: String): Int {
    if (text.isEmpty()) return 0
    if (isSimple(text)) return text.length
    val iterator = BreakIterator.getCharacterInstance(Locale.ROOT)
    iterator.setText(text)
    var count = 0
    while (iterator.next() != BreakIterator.DONE) count++
    return count
  }

  /** UTF-16 offsets of every grapheme boundary, including 0 and `text.length`. */
  internal fun characterBoundaries(text: String): IntArray {
    if (isSimple(text)) return IntArray(text.length + 1) { it }
    val iterator = BreakIterator.getCharacterInstance(Locale.ROOT)
    iterator.setText(text)
    val boundaries = IntArray(text.length + 1)
    var count = 0
    var position = iterator.first()
    while (position != BreakIterator.DONE) {
      boundaries[count++] = position
      position = iterator.next()
    }
    return boundaries.copyOf(count)
  }

  /** Lowercase SHA-256 hex of the UTF-8 bytes (iOS `EmbeddingVectorCodec.fingerprint`). */
  fun fingerprint(text: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
    val hex = CharArray(digest.size * 2)
    val digits = "0123456789abcdef"
    for (i in digest.indices) {
      val value = digest[i].toInt() and 0xFF
      hex[i * 2] = digits[value ushr 4]
      hex[i * 2 + 1] = digits[value and 0x0F]
    }
    return String(hex)
  }

  /**
   * Fast path: Latin text below U+0300 (including Turkish letters) without CR has exactly one
   * grapheme per UTF-16 unit; everything else goes through the break iterator.
   */
  private fun isSimple(text: String): Boolean {
    for (ch in text) {
      if (ch.code >= 0x0300 || ch.code == 0x0D) return false
    }
    return true
  }
}

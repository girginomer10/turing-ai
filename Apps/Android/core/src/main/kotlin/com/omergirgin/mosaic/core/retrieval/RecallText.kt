package com.omergirgin.mosaic.core.retrieval

import java.text.Normalizer
import java.util.Locale

/**
 * Turkish-aware text folding shared by the local retriever, the hash embedding and the recall
 * query builder. Mirrors Swift `lowercased(with: tr_TR).folding([.diacriticInsensitive,
 * .widthInsensitive])`: Turkish casing (`İ` → `i`, `I` → `ı`), combining marks removed (`ş` → `s`,
 * `ğ` → `g`), and full-width ASCII mapped to its normal form. Dotless `ı` is a letter, not a
 * diacritic, so it is kept.
 */
internal object RecallText {
  private val turkish: Locale = Locale.forLanguageTag("tr-TR")
  private val combiningMarks = Regex("\\p{Mn}+")

  fun lowercasedTurkish(value: String): String = value.lowercase(turkish)

  fun folded(value: String): String {
    val decomposed = Normalizer.normalize(value.lowercase(turkish), Normalizer.Form.NFD)
    val stripped = combiningMarks.replace(decomposed, "")
    return foldWidth(Normalizer.normalize(stripped, Normalizer.Form.NFC))
  }

  /** Folded text with every run of non-letter/non-number characters collapsed to one space. */
  fun normalized(value: String): String {
    val folded = folded(value)
    val output = StringBuilder(folded.length)
    var pendingSpace = false
    var index = 0
    while (index < folded.length) {
      val codePoint = folded.codePointAt(index)
      if (isLetterOrNumber(codePoint)) {
        if (pendingSpace && output.isNotEmpty()) output.append(' ')
        pendingSpace = false
        output.appendCodePoint(codePoint)
      } else {
        pendingSpace = true
      }
      index += Character.charCount(codePoint)
    }
    return output.toString()
  }

  fun tokens(value: String): List<String> = normalized(value).split(' ').filter { it.isNotEmpty() }

  /** Words split on any non-letter (no folding), as Swift `split(whereSeparator: !isLetter)`. */
  fun letterWords(value: String): List<String> {
    val words = ArrayList<String>()
    val current = StringBuilder()
    var index = 0
    while (index < value.length) {
      val codePoint = value.codePointAt(index)
      if (Character.isLetter(codePoint)) {
        current.appendCodePoint(codePoint)
      } else if (current.isNotEmpty()) {
        words += current.toString()
        current.setLength(0)
      }
      index += Character.charCount(codePoint)
    }
    if (current.isNotEmpty()) words += current.toString()
    return words
  }

  fun codePointCount(value: String): Int = value.codePointCount(0, value.length)

  /** First [count] code points, never splitting a surrogate pair. */
  fun prefix(value: String, count: Int): String {
    if (count <= 0) return ""
    if (value.length <= count) return value
    val end = runCatching { value.offsetByCodePoints(0, count) }.getOrDefault(value.length)
    return value.substring(0, end)
  }

  private fun isLetterOrNumber(codePoint: Int): Boolean {
    if (Character.isLetter(codePoint)) return true
    return when (Character.getType(codePoint).toByte()) {
      Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
      else -> false
    }
  }

  private fun foldWidth(value: String): String {
    if (value.none { it in '！'..'～' || it == '　' }) return value
    val output = StringBuilder(value.length)
    for (char in value) {
      output.append(
        when (char) {
          in '！'..'～' -> (char.code - 0xFEE0).toChar()
          '　' -> ' '
          else -> char
        }
      )
    }
    return output.toString()
  }
}

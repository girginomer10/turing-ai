package com.omergirgin.mosaic.core.context

/**
 * Deterministic, deliberately conservative token estimate (iOS `ConservativeTokenEstimator`).
 *
 * Providers tokenize differently, so one token per UTF-8 byte is used as an upper bound: it
 * overestimates prose but stays safe for dense code, JSON, base64-like text, emoji and unknown
 * tokenizers. Receipts always label these values as estimates.
 */
class ConservativeTokenEstimator(
  messageFramingTokens: Int = 8,
  systemFramingTokens: Int = 4,
  imageTokens: Int = 4_096,
) {
  val messageFramingTokens: Int = messageFramingTokens.coerceAtLeast(0)
  val systemFramingTokens: Int = systemFramingTokens.coerceAtLeast(0)
  /** Flat reservation per attached photo; photos are normalized to <= 1024 px before sending. */
  val imageTokens: Int = imageTokens.coerceAtLeast(0)

  fun estimate(text: String): Int = utf8Length(text)

  fun estimate(candidate: ContextCandidate): Int =
    saturatingAdd(
      saturatingAdd(messageFramingTokens, estimate(candidate.content)),
      saturatingMultiply(candidate.imageCount.coerceAtLeast(0), imageTokens),
    )

  fun estimateSystemPrompt(systemPrompt: String?): Int =
    if (systemPrompt.isNullOrEmpty()) 0 else saturatingAdd(systemFramingTokens, estimate(systemPrompt))
}

/** UTF-8 byte length without allocating an encoded copy (messages can be hundreds of KiB). */
fun utf8Length(text: String): Int {
  var bytes = 0L
  var index = 0
  val length = text.length
  while (index < length) {
    val char = text[index]
    when {
      char.code < 0x80 -> bytes += 1
      char.code < 0x800 -> bytes += 2
      Character.isHighSurrogate(char) && index + 1 < length && Character.isLowSurrogate(text[index + 1]) -> {
        bytes += 4
        index++
      }
      // Lone surrogates are replaced by a 3-byte U+FFFD when encoded.
      else -> bytes += 3
    }
    index++
  }
  return bytes.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
}

internal fun saturatingAdd(a: Int, b: Int): Int {
  val sum = a.toLong() + b.toLong()
  return sum.coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt()
}

private fun saturatingMultiply(a: Int, b: Int): Int {
  val product = a.toLong() * b.toLong()
  return product.coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt()
}

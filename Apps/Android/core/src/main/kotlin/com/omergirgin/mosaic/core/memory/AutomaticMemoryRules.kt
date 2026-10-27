package com.omergirgin.mosaic.core.memory

import com.omergirgin.mosaic.core.context.MemoryContextScope
import com.omergirgin.mosaic.core.context.utf8Length
import java.security.MessageDigest
import java.text.Normalizer
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/** Deterministic rules shared by consolidation, user edits and lifecycle reconciliation. */
object AutomaticMemoryRules {
  const val MINIMUM_UPSERT_CONFIDENCE = 0.65
  const val MINIMUM_EVENT_CONFIDENCE = 0.75
  const val MINIMUM_MANUAL_OVERRIDE_CONFIDENCE = 0.9

  private val turkish = Locale.forLanguageTag("tr-TR")
  private val combiningMarks = Regex("\\p{M}+")
  private val whitespaceRuns = Regex("\\s+")

  /**
   * Value identity used to decide reinforcement vs. correction (iOS `normalizedValue`): Turkish
   * lowercasing, diacritic/width folding and whitespace collapsing.
   */
  fun normalizedValue(value: String): String {
    val folded = Normalizer.normalize(value.lowercase(turkish), Normalizer.Form.NFKD).replace(combiningMarks, "")
    return folded.trim().split(whitespaceRuns).filter { it.isNotEmpty() }.joinToString(" ")
  }

  /** Lighter normalization used while validating provider output (iOS `normalizedMemoryValue`). */
  fun normalizedMemoryValue(value: String): String =
    value.trim().lowercase().split(whitespaceRuns).filter { it.isNotEmpty() }.joinToString(" ")

  fun reinforcedConfidence(existing: Double, incoming: Double): Double =
    min(0.99, max(existing, 1 - (1 - existing) * (1 - incoming * 0.35)))

  fun moreStable(lhs: MemoryStability, rhs: MemoryStability): MemoryStability = if (lhs.rank >= rhs.rank) lhs else rhs

  fun canonicalPrefix(scope: MemoryContextScope, kind: MemoryTopicKind, conversationId: String?, projectId: String?): String? =
    when (scope) {
      MemoryContextScope.GLOBAL -> "global:${kind.rawValue}:"
      MemoryContextScope.PROJECT -> projectId?.let { "project:${it.lowercase()}:${kind.rawValue}:" }
      MemoryContextScope.CONVERSATION -> conversationId?.let { "conversation:${it.lowercase()}:${kind.rawValue}:" }
    }

  /**
   * Deterministic stored key: the provider proposes only a bare property key; scope, owner and
   * kind are prefixed locally so a proposal can never address another audience's topic.
   * Returns null when the proposal cannot form a valid key.
   */
  fun canonicalKey(
    proposed: String,
    kind: MemoryTopicKind,
    scope: MemoryContextScope,
    conversationId: String,
    projectId: String?,
  ): String? {
    val lowered = proposed.lowercase(Locale.ROOT)
    val mapped = StringBuilder()
    lowered.codePoints().forEach { codePoint ->
      val allowed = isAlphanumeric(codePoint) || (codePoint < 0x80 && codePoint.toChar() in KEY_PUNCTUATION)
      val char = if (allowed) String(Character.toChars(codePoint)) else "_"
      if (char != "_" || !mapped.endsWith("_")) mapped.append(char)
    }
    val normalized = mapped.toString().trim { it in KEY_PUNCTUATION }
    if (normalized.isEmpty()) return null
    val prefix = canonicalPrefix(scope, kind, conversationId, projectId) ?: return null
    if (normalized.startsWith("global:") || normalized.startsWith("project:") || normalized.startsWith("conversation:")) {
      if (!normalized.startsWith(prefix)) return null
    }
    var suffix = normalized.removePrefix(prefix)
    suffix = suffix.removePrefix("${kind.rawValue}.")
    if (suffix.isEmpty()) return null
    val value = prefix + suffix
    return value.takeIf { utf8Length(it) <= AutomaticMemoryLimits.CANONICAL_KEY_BYTES }
  }

  /** Replaces the audience prefix of an existing key, keeping its stable property suffix. */
  fun rekeyed(
    canonicalKey: String,
    kind: MemoryTopicKind,
    fromPrefix: String,
    toScope: MemoryContextScope,
    conversationId: String?,
    projectId: String?,
  ): String? {
    if (!canonicalKey.startsWith(fromPrefix)) return null
    val suffix = canonicalKey.substring(fromPrefix.length)
    if (suffix.isEmpty()) return null
    val prefix = canonicalPrefix(toScope, kind, conversationId, projectId) ?: return null
    return (prefix + suffix).takeIf { utf8Length(it) <= AutomaticMemoryLimits.CANONICAL_KEY_BYTES }
  }

  /** Returns a user-facing problem with a learned title/content pair, or null when valid. */
  fun textProblem(title: String, content: String): String? {
    if (title.isBlank() || title.trim() != title || content.isBlank() || content.trim() != content) {
      return "The automatic-memory title or content is invalid."
    }
    if (codePoints(title) > AutomaticMemoryLimits.TITLE_CHARACTERS) {
      return "A learned-memory title can contain at most ${AutomaticMemoryLimits.TITLE_CHARACTERS} characters. Shorten it and try again."
    }
    if (codePoints(content) > AutomaticMemoryLimits.CONTENT_CHARACTERS) {
      return "A learned memory can contain at most 2,000 characters. Split it into smaller facts and try again."
    }
    if (utf8Length(title) > AutomaticMemoryLimits.TITLE_BYTES) {
      return "The automatic-memory title is larger than Turing AI's safe local limit of 512 bytes."
    }
    if (utf8Length(content) > AutomaticMemoryLimits.CONTENT_BYTES) {
      return "The automatic-memory content is larger than Turing AI's safe local limit of 8 KB."
    }
    return null
  }

  /** Evidence excerpt: trimmed, at most 1,500 characters with a trailing ellipsis. */
  fun boundedExcerpt(value: String): String {
    val normalized = value.trim()
    val limit = AutomaticMemoryLimits.EVIDENCE_EXCERPT_CHARACTERS
    if (codePoints(normalized) <= limit) return normalized
    return normalized.substring(0, normalized.offsetByCodePoints(0, limit - 1)) + "…"
  }

  /** Longest prefix of [value] within [maximumBytes] UTF-8 bytes, never splitting a code point. */
  fun boundedUtf8(value: String, maximumBytes: Int): String {
    if (utf8Length(value) <= maximumBytes) return value
    val builder = StringBuilder()
    var bytes = 0
    var index = 0
    while (index < value.length) {
      val codePoint = value.codePointAt(index)
      val size = when {
        codePoint < 0x80 -> 1
        codePoint < 0x800 -> 2
        codePoint < 0x10000 -> 3
        else -> 4
      }
      if (bytes + size > maximumBytes) break
      builder.appendCodePoint(codePoint)
      bytes += size
      index += Character.charCount(codePoint)
    }
    return builder.toString()
  }

  fun codePoints(value: String): Int = value.codePointCount(0, value.length)

  internal fun isAlphanumeric(codePoint: Int): Boolean =
    Character.isLetterOrDigit(codePoint) || when (Character.getType(codePoint).toByte()) {
      Character.NON_SPACING_MARK, Character.ENCLOSING_MARK, Character.COMBINING_SPACING_MARK,
      Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
      else -> false
    }

  private const val KEY_PUNCTUATION = "._-:/"
}

/** Event recall fades without deleting history or turning the event into a lasting fact. */
object RecentEventMemoryPolicy {
  private const val DAY_MILLIS = 86_400_000.0

  /** Days for the fade factor to halve. */
  const val HALF_LIFE_DAYS = 45.0

  /** The weakest weight an old event can reach. */
  const val FLOOR = 0.4

  /** An event already ranking this high before fading is shielded, so a specific old event is still found. */
  const val PROTECTED_RANKS = 3

  /** Floor weight for a shielded event; below 1 so a newer, equally relevant event still wins. */
  const val PROTECTED_WEIGHT = 0.85

  /** 45-day half-life with a 40% floor (benchmarks/memory; the earlier 14 days / 15% buried month-old events). */
  fun relevanceWeight(lastConfirmedAt: Long, now: Long = System.currentTimeMillis()): Double {
    val ageInDays = max(0.0, (now - lastConfirmedAt) / DAY_MILLIS)
    return max(FLOOR, 0.5.pow(ageInDays / HALF_LIFE_DAYS))
  }

  fun isRecent(lastConfirmedAt: Long, now: Long = System.currentTimeMillis()): Boolean =
    now - lastConfirmedAt <= 30 * DAY_MILLIS
}

/** Lowercase SHA-256 hex of the UTF-8 bytes (iOS `EmbeddingVectorCodec.fingerprint`). */
fun sha256Hex(value: String): String = sha256Hex(value.toByteArray(Charsets.UTF_8))

fun sha256Hex(bytes: ByteArray): String {
  val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
  val hex = StringBuilder(digest.size * 2)
  for (byte in digest) {
    val value = byte.toInt() and 0xff
    hex.append(HEX[value ushr 4]).append(HEX[value and 0x0f])
  }
  return hex.toString()
}

private const val HEX = "0123456789abcdef"

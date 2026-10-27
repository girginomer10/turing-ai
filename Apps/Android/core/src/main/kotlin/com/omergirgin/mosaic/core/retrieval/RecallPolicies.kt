package com.omergirgin.mosaic.core.retrieval

import kotlin.math.pow

/**
 * Lightweight Turkish/English concept groups. A local search feature only (never a neural model);
 * it can raise the relevance of an existing candidate but never creates or alters a memory.
 */
internal object MemoryConcepts {
  private val groups: List<Pair<String, List<String>>> = listOf(
    "pet" to listOf(
      "pet", "pets", "animal", "animals", "hayvan", "hayvanim", "hayvanım", "kedi", "kedim",
      "cat", "cats", "kitten", "kittens", "köpek", "kopek", "dog", "dogs", "puppy",
    ),
    "cat" to listOf("kedi", "kedim", "kediler", "cat", "cats", "kitten", "kittens"),
    "dog" to listOf("köpek", "kopek", "köpeğim", "kopegim", "dog", "dogs", "puppy"),
    "food" to listOf("yemek", "yiyecek", "food", "eat", "eating", "diet", "diyet", "beslenme"),
    "soy" to listOf("soya", "soy"),
    "allergy" to listOf("alerji", "alerjim", "allergy", "allergic", "allergies"),
    "work" to listOf("iş", "işim", "isim", "meslek", "job", "work", "profession", "occupation"),
    "home" to listOf(
      "yaşıyorum", "yasiyorum", "yaşadığım", "yasadigim", "yaşıyorsun", "live", "lives", "living",
      "şehir", "sehir", "city", "ikamet",
    ),
    "preference" to listOf("tercih", "prefer", "prefers", "preference", "seviyorum", "sever", "like", "likes"),
  )

  fun features(text: String): Set<String> {
    val words = RecallText.letterWords(RecallText.lowercasedTurkish(text)).toHashSet()
    if (words.isEmpty()) return emptySet()
    return groups.mapNotNullTo(HashSet()) { (key, aliases) ->
      val matches = aliases.any { alias ->
        alias in words || (RecallText.codePointCount(alias) >= 4 && words.any { it.startsWith(alias) })
      }
      if (matches) key else null
    }
  }

  fun relevance(queryFeatures: Set<String>, content: String): Double {
    if (queryFeatures.isEmpty()) return 0.0
    val contentFeatures = features(content)
    // A specific animal must not match another species solely through the parent category.
    if ("cat" in queryFeatures && "dog" in contentFeatures && "cat" !in contentFeatures) return 0.0
    if ("dog" in queryFeatures && "cat" in contentFeatures && "dog" !in contentFeatures) return 0.0
    return queryFeatures.count { it in contentFeatures }.toDouble() / queryFeatures.size * 0.35
  }
}

/**
 * Event memories fade (14-day half-life, 15% floor) without deleting history. Topic sources use
 * this for `RecallCandidate.weight`; the retriever multiplies the fused score by it.
 */
object RecallEventPolicy {
  private const val DAY_MILLIS = 86_400_000.0

  fun relevanceWeight(lastConfirmedAtMillis: Long, nowMillis: Long = System.currentTimeMillis()): Double {
    val ageDays = maxOf(0.0, (nowMillis - lastConfirmedAtMillis) / DAY_MILLIS)
    return maxOf(0.15, 0.5.pow(ageDays / 14))
  }

  fun isRecent(lastConfirmedAtMillis: Long, nowMillis: Long = System.currentTimeMillis()): Boolean =
    nowMillis - lastConfirmedAtMillis <= 30 * 86_400_000L
}

/**
 * iOS `MemoryRecallQuery`: a short referential question ("what about them?") can borrow its
 * subject from at most two recent user turns. Assistant text never supplies evidence, and
 * self-contained questions keep their own query.
 */
object RecallQuery {
  private val references = setOf(
    "onlar", "onlara", "onlari", "onlarin", "bunlar", "bunlara", "bunlari", "bunlarin",
    "kucukler", "kucuklere", "kucuklerin", "them", "their", "those", "these",
  )

  /** [userTurns] are the request's user messages, oldest first (the current one may be last). */
  fun make(current: String, userTurns: List<String>): String {
    val words = RecallText.letterWords(RecallText.folded(current))
    if (RecallText.codePointCount(current) > 240 || words.none { it in references }) return current
    val previous = if (userTurns.lastOrNull() == current) userTurns.dropLast(1) else userTurns
    val context = previous.takeLast(2).map { RecallText.prefix(it, 450) }
    if (context.isEmpty()) return current
    return current + "\nRecent user context:\n" + context.joinToString("\n")
  }
}

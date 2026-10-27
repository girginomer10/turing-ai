package com.omergirgin.mosaic.core.context.recall

import java.text.Normalizer
import java.util.Locale
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.sqrt

/*
 * Minimal, self-contained port of the local (no-embedding) scoring path of iOS
 * `HybridMemoryRetriever` used by same-chat recall: Turkish-aware BM25, a deterministic character
 * n-gram hash vector, exact phrase matching, a small Turkish/English concept table and a gentle
 * recency term. The cross-chat hybrid retriever lives elsewhere; this stays deliberately small.
 */

internal object SameChatText {
  private val TURKISH: Locale = Locale.forLanguageTag("tr-TR")

  /** tr-TR lowercasing followed by diacritic and width folding (Foundation-style). */
  fun fold(value: String): String {
    val decomposed = Normalizer.normalize(value.lowercase(TURKISH), Normalizer.Form.NFKD)
    val output = StringBuilder(decomposed.length)
    decomposed.codePoints().forEach { codePoint ->
      if (Character.getType(codePoint) != Character.NON_SPACING_MARK.toInt()) output.appendCodePoint(codePoint)
    }
    return Normalizer.normalize(output, Normalizer.Form.NFC)
  }

  /** Folded text with every run of non-letter/non-number characters collapsed to one space. */
  fun normalized(value: String): String = splitWords(fold(value), includeNumbers = true).joinToString(" ")

  fun tokens(value: String): List<String> = splitWords(fold(value), includeNumbers = true)

  fun splitWords(value: String, includeNumbers: Boolean): List<String> {
    val words = ArrayList<String>()
    val current = StringBuilder()
    value.codePoints().forEach { codePoint ->
      if (Character.isLetter(codePoint) || (includeNumbers && isNumber(codePoint))) {
        current.appendCodePoint(codePoint)
      } else if (current.isNotEmpty()) {
        words += current.toString()
        current.setLength(0)
      }
    }
    if (current.isNotEmpty()) words += current.toString()
    return words
  }

  fun lowercaseTurkish(value: String): String = value.lowercase(TURKISH)

  fun codePointCount(value: String): Int = value.codePointCount(0, value.length)

  /** Substring by code-point offsets [start, end). */
  fun substring(value: String, start: Int, end: Int): String {
    val from = value.offsetByCodePoints(0, start)
    val to = value.offsetByCodePoints(from, end - start)
    return value.substring(from, to)
  }

  private fun isNumber(codePoint: Int): Boolean = when (Character.getType(codePoint)) {
    Character.DECIMAL_DIGIT_NUMBER.toInt(), Character.LETTER_NUMBER.toInt(), Character.OTHER_NUMBER.toInt() -> true
    else -> false
  }
}

/** Deterministic 1,024-dimension character 3–5-gram FNV-1a vector (iOS `LocalHashEmbedding`). */
internal object LocalHashVector {
  const val DIMENSIONS = 1_024
  private const val FNV_OFFSET = -3_750_763_034_362_895_579L // 14695981039346656037 as signed 64-bit
  private const val FNV_PRIME = 1_099_511_628_211L

  fun vector(text: String, cancellationCheck: () -> Unit): FloatArray {
    cancellationCheck()
    val vector = FloatArray(DIMENSIONS)
    val normalized = SameChatText.fold(text)
    if (normalized.isEmpty()) return vector
    val scalars = normalized.codePoints().toArray()
    for (length in 3..5) {
      if (scalars.size < length) continue
      for (start in 0..(scalars.size - length)) {
        if (start % 1_024 == 0) cancellationCheck()
        var hash = FNV_OFFSET
        for (index in start until start + length) {
          hash = hash xor scalars[index].toLong()
          hash *= FNV_PRIME
        }
        val bucket = java.lang.Long.remainderUnsigned(hash, DIMENSIONS.toLong()).toInt()
        val sign = if (hash >= 0) 1f else -1f
        vector[bucket] += sign / length
      }
    }
    return normalizedVector(vector)
  }

  fun cosine(lhs: FloatArray, rhs: FloatArray): Double {
    if (lhs.isEmpty() || lhs.size != rhs.size) return 0.0
    var dot = 0f
    var lhsMagnitude = 0f
    var rhsMagnitude = 0f
    for (index in lhs.indices) {
      dot += lhs[index] * rhs[index]
      lhsMagnitude += lhs[index] * lhs[index]
      rhsMagnitude += rhs[index] * rhs[index]
    }
    val denominator = sqrt(lhsMagnitude) * sqrt(rhsMagnitude)
    if (denominator <= 0f || !denominator.isFinite()) return 0.0
    return (dot / denominator).toDouble()
  }

  private fun normalizedVector(vector: FloatArray): FloatArray {
    var sum = 0f
    for (value in vector) sum += value * value
    val magnitude = sqrt(sum)
    if (magnitude <= 0f || !magnitude.isFinite()) return vector
    for (index in vector.indices) vector[index] = vector[index] / magnitude
    return vector
  }
}

/**
 * Lightweight cross-language concepts (iOS `MemoryConcepts`): a fallback feature, not a semantic
 * model. They only contribute ranking signal.
 */
internal object RecallConcepts {
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
    val words = SameChatText.splitWords(SameChatText.lowercaseTurkish(text), includeNumbers = false).toHashSet()
    return groups.mapNotNullTo(HashSet()) { (key, aliases) ->
      val matches = aliases.any { alias ->
        alias in words || (SameChatText.codePointCount(alias) >= 4 && words.any { it.startsWith(alias) })
      }
      if (matches) key else null
    }
  }

  fun relevance(query: String, content: String): Double {
    val queryFeatures = features(query)
    if (queryFeatures.isEmpty()) return 0.0
    val contentFeatures = features(content)
    // A specific animal must not match another species solely through the parent category.
    if ("cat" in queryFeatures && "dog" in contentFeatures && "cat" !in contentFeatures) return 0.0
    if ("dog" in queryFeatures && "cat" in contentFeatures && "dog" !in contentFeatures) return 0.0
    return queryFeatures.count { it in contentFeatures }.toDouble() / queryFeatures.size * 0.35
  }
}

internal data class ScoredRecallItem(val source: SameChatRecallSource, val relevance: Double)

/**
 * The local-only ranking iOS same-chat recall performs (`HybridMemoryRetriever` with no embedding
 * profiles): local score floor 0.15, reciprocal-rank fusion, and a character budget.
 */
internal class SameChatRetriever(
  private val maximumItems: Int = 3,
  private val maximumCharacters: Int = 4_000,
  private val minimumLocalRelevance: Double = 0.15,
) {
  fun retrieve(
    query: String,
    candidates: List<SameChatRecallSource>,
    nowMillis: Long,
    cancellationCheck: () -> Unit,
  ): List<ScoredRecallItem> {
    cancellationCheck()
    if (SameChatText.normalized(query).isEmpty() || maximumItems <= 0 || maximumCharacters <= 0) return emptyList()

    val local = localScores(query, candidates, nowMillis, cancellationCheck)
    val localRanks = HashMap<String, Int>(local.size)
    local.keys
      .sortedWith(compareByDescending<String> { local.getValue(it) }.thenBy { it })
      .forEachIndexed { index, id -> localRanks[id] = index + 1 }

    val combined = HashMap<String, Double>()
    for ((index, candidate) in candidates.withIndex()) {
      if (index % 32 == 0) cancellationCheck()
      val localScore = local[candidate.id] ?: 0.0
      if (localScore < minimumLocalRelevance) continue
      val rank = localRanks[candidate.id]
      // Reciprocal-rank fusion with a single local ranking, normalized so rank 1 maps to 1.
      val normalizedFusion = if (rank == null) 0.0 else 61.0 / (60 + rank)
      combined[candidate.id] = minOf(1.0, localScore * 0.78 + normalizedFusion * 0.22)
    }

    val ordered = candidates.sortedWith(
      compareByDescending<SameChatRecallSource> { combined[it.id] ?: Double.NEGATIVE_INFINITY }
        .thenByDescending { it.createdAt }
        .thenBy { it.id }
    )
    var remainingCharacters = maximumCharacters
    val included = ArrayList<ScoredRecallItem>()
    for ((index, candidate) in ordered.withIndex()) {
      if (index % 32 == 0) cancellationCheck()
      if (included.size >= maximumItems || remainingCharacters <= 0) break
      val relevance = combined[candidate.id] ?: continue
      val trimmed = candidate.content.trim()
      if (trimmed.isEmpty()) continue
      val content = truncated(trimmed, remainingCharacters)
      if (content.isEmpty()) continue
      included += ScoredRecallItem(candidate.copy(content = content), relevance)
      remainingCharacters -= SameChatText.codePointCount(content)
    }
    return included
  }

  private fun localScores(
    query: String,
    candidates: List<SameChatRecallSource>,
    nowMillis: Long,
    cancellationCheck: () -> Unit,
  ): Map<String, Double> {
    cancellationCheck()
    val queryTokens = SameChatText.tokens(query)
    if (queryTokens.isEmpty()) return emptyMap()
    val normalizedQuery = SameChatText.normalized(query)
    val queryVector = LocalHashVector.vector(query, cancellationCheck)

    val documentTokens = HashMap<String, List<String>>(candidates.size)
    for ((index, candidate) in candidates.withIndex()) {
      if (index % 32 == 0) cancellationCheck()
      documentTokens[candidate.id] = SameChatText.tokens(candidate.content)
    }
    val averageLength = maxOf(
      1.0,
      documentTokens.values.sumOf { it.size }.toDouble() / maxOf(1, documentTokens.size),
    )
    val uniqueQueryTokens = queryTokens.toSet()
    val documentTokenSets = documentTokens.mapValues { it.value.toHashSet() }
    val documentFrequency = uniqueQueryTokens.associateWith { token -> documentTokenSets.values.count { token in it } }

    val scores = HashMap<String, Double>(candidates.size)
    val count = maxOf(1, candidates.size).toDouble()
    for ((index, candidate) in candidates.withIndex()) {
      if (index % 16 == 0) cancellationCheck()
      val tokens = documentTokens[candidate.id].orEmpty()
      val frequencies = tokens.groupingBy { it }.eachCount()
      var bm25 = 0.0
      for (token in uniqueQueryTokens) {
        val frequency = (frequencies[token] ?: 0).toDouble()
        if (frequency <= 0) continue
        val documentCount = (documentFrequency[token] ?: 0).toDouble()
        val inverseDocumentFrequency = ln(1 + (count - documentCount + 0.5) / (documentCount + 0.5))
        val lengthNormalization = 1.2 * (0.25 + 0.75 * tokens.size / averageLength)
        bm25 += inverseDocumentFrequency * (frequency * 2.2) / (frequency + lengthNormalization)
      }
      val lexical = 1 - exp(-bm25 / maxOf(1, uniqueQueryTokens.size))
      val hashSimilarity = maxOf(0.0, LocalHashVector.cosine(queryVector, LocalHashVector.vector(candidate.content, cancellationCheck)))
      val phrase = if (
        SameChatText.codePointCount(normalizedQuery) >= 6 &&
        SameChatText.normalized(candidate.content).contains(normalizedQuery)
      ) 1.0 else 0.0
      val daysOld = maxOf(0.0, (nowMillis - candidate.createdAt) / 86_400_000.0)
      val recency = exp(-daysOld / 365)
      scores[candidate.id] = minOf(
        1.0,
        maxOf(lexical * 0.52 + hashSimilarity * 0.30 + phrase * 0.12, RecallConcepts.relevance(query, candidate.content)) +
          recency * 0.06,
      )
    }
    return scores
  }

  private fun truncated(value: String, maximumCharacters: Int): String {
    val count = SameChatText.codePointCount(value)
    if (count <= maximumCharacters) return value
    if (maximumCharacters <= 1) return SameChatText.substring(value, 0, maximumCharacters)
    return SameChatText.substring(value, 0, maximumCharacters - 1) + "…"
  }
}

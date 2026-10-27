package com.omergirgin.mosaic.core.retrieval

import java.security.MessageDigest
import kotlin.math.sqrt

object EmbeddingMath {
  fun normalized(vector: FloatArray): FloatArray {
    var sum = 0f
    for (value in vector) sum += value * value
    val magnitude = sqrt(sum)
    if (magnitude <= 0f || !magnitude.isFinite()) return vector.copyOf()
    return FloatArray(vector.size) { vector[it] / magnitude }
  }

  /** Cosine similarity; 0 for empty, mismatched or degenerate vectors. */
  fun cosineSimilarity(lhs: FloatArray, rhs: FloatArray): Double {
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
}

/**
 * Deterministic character n-gram vector (lengths 3–5, FNV-1a over Unicode scalars, 1,024 signed
 * buckets). A local lexical feature, not a semantic model; never persisted.
 */
object LocalHashEmbedding {
  const val DIMENSIONS: Int = 1_024
  private const val FNV_OFFSET: Long = -0x340d631b7bdddcdbL // 14695981039346656037
  private const val FNV_PRIME: Long = 0x100000001b3L // 1099511628211

  fun vector(text: String): FloatArray {
    val vector = FloatArray(DIMENSIONS)
    accumulate(text, vector) {}
    return EmbeddingMath.normalized(vector)
  }

  /** Writes the unnormalized vector for [text] into [target] (cleared first); allocation-free reuse. */
  internal fun accumulate(text: String, target: FloatArray, checkCancellation: () -> Unit) {
    target.fill(0f)
    val folded = RecallText.folded(text)
    if (folded.isEmpty()) return
    val scalars = folded.codePoints().toArray()
    for (length in 3..5) {
      if (scalars.size < length) continue
      for (start in 0..(scalars.size - length)) {
        if (start % 1_024 == 0) checkCancellation()
        var hash = FNV_OFFSET
        for (offset in 0 until length) {
          hash = hash xor scalars[start + offset].toLong()
          hash *= FNV_PRIME
        }
        val index = (hash and (DIMENSIONS - 1).toLong()).toInt()
        val sign = if (hash < 0) -1f else 1f
        target[index] += sign / length
      }
    }
  }
}

/** Little-endian Float32 cache envelope and SHA-256 content fingerprints. */
object EmbeddingVectorCodec {
  fun encode(vector: FloatArray): ByteArray {
    val bytes = ByteArray(vector.size * 4)
    for (index in vector.indices) {
      val bits = java.lang.Float.floatToRawIntBits(vector[index])
      val offset = index * 4
      bytes[offset] = bits.toByte()
      bytes[offset + 1] = (bits ushr 8).toByte()
      bytes[offset + 2] = (bits ushr 16).toByte()
      bytes[offset + 3] = (bits ushr 24).toByte()
    }
    return bytes
  }

  fun decode(bytes: ByteArray, dimensions: Int): FloatArray? {
    if (!isValidEncoding(bytes.size, dimensions)) return null
    return FloatArray(dimensions) { index ->
      val offset = index * 4
      val bits = (bytes[offset].toInt() and 0xFF) or
        ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
        ((bytes[offset + 2].toInt() and 0xFF) shl 16) or
        ((bytes[offset + 3].toInt() and 0xFF) shl 24)
      java.lang.Float.intBitsToFloat(bits)
    }
  }

  /** Checks the envelope without decoding. */
  fun isValidEncoding(byteCount: Int, dimensions: Int): Boolean {
    if (dimensions <= 0) return false
    val expected = dimensions.toLong() * 4
    return expected <= Int.MAX_VALUE && byteCount.toLong() == expected
  }

  /** Lowercase SHA-256 hex of the UTF-8 text. */
  fun fingerprint(content: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(content.encodeToByteArray())
    val hex = CharArray(digest.size * 2)
    val digits = "0123456789abcdef"
    for (index in digest.indices) {
      val value = digest[index].toInt() and 0xFF
      hex[index * 2] = digits[value ushr 4]
      hex[index * 2 + 1] = digits[value and 0x0F]
    }
    return String(hex)
  }
}

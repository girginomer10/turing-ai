package com.omergirgin.mosaic.core.backup

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.math.BigDecimal
import java.math.MathContext
import java.math.RoundingMode
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Base64
import kotlin.math.abs

/*
 * Minimal JSON tree, writer and streaming reader that reproduce Swift `JSONEncoder` output byte
 * for byte (`.sortedKeys`, optionally `.withoutEscapingSlashes`). The `.mosaicbackup` checksum and
 * the iOS staging read-back compare re-encoded bytes, so number, string and key formatting must
 * match Foundation exactly; kotlinx.serialization's own encoder does not.
 */

sealed interface PJ

class PJObject(val fields: Map<String, PJ>) : PJ {
  operator fun get(key: String): PJ? = fields[key]
}

class PJArray(val items: List<PJ>) : PJ

class PJString(val value: String) : PJ

/** A number whose [literal] is already in Swift `JSONEncoder` form (or as read from a file). */
class PJNumber(val literal: String) : PJ

class PJBool private constructor(val value: Boolean) : PJ {
  companion object {
    val TRUE = PJBool(true)
    val FALSE = PJBool(false)
    fun of(value: Boolean): PJBool = if (value) TRUE else FALSE
  }
}

object PJNull : PJ

/** Builds an object; absent (null) values are omitted like Swift's synthesized `encodeIfPresent`. */
class PJObjectBuilder {
  private val map = HashMap<String, PJ>()

  fun string(key: String, value: String?) = apply { if (value != null) map[key] = PJString(value) }
  fun uuid(key: String, value: String?) = apply { if (value != null) map[key] = PJString(PortableIds.toPortable(value)) }
  fun int(key: String, value: Long?) = apply { if (value != null) map[key] = PJNumber(value.toString()) }
  fun int(key: String, value: Int?) = apply { if (value != null) map[key] = PJNumber(value.toString()) }
  fun double(key: String, value: Double?) = apply { if (value != null) map[key] = PJNumber(SwiftNumber.format(value)) }
  fun date(key: String, value: PortableDate?) = apply { if (value != null) map[key] = PJNumber(value.literal) }
  fun bool(key: String, value: Boolean?) = apply { if (value != null) map[key] = PJBool.of(value) }
  fun data(key: String, value: ByteArray?) = apply { if (value != null) map[key] = PJString(PortableBase64.encode(value)) }
  fun value(key: String, value: PJ?) = apply { if (value != null) map[key] = value }
  fun build(): PJObject = PJObject(map)
}

inline fun pjObject(block: PJObjectBuilder.() -> Unit): PJObject = PJObjectBuilder().apply(block).build()

object PortableBase64 {
  fun encode(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

  /** Strict standard alphabet with padding, like `Data(base64Encoded:)`. */
  fun decode(value: String): ByteArray? {
    if (value.length % 4 != 0) return null
    return runCatching { Base64.getDecoder().decode(value) }.getOrNull()
  }
}

/** Swift `Double.description` with Foundation's trailing ".0" removal (JSONEncoder numbers). */
object SwiftNumber {
  private const val TWO_POW_53 = 9_007_199_254_740_992.0

  fun format(value: Double): String {
    require(value.isFinite()) { "Non-finite numbers cannot be encoded." }
    if (value == 0.0) return if (1.0 / value < 0) "-0" else "0"
    val magnitude = abs(value)
    val (digits, exponent) = shortestDigits(magnitude)
    val sign = if (value < 0) "-" else ""
    val body = if (exponent < -4 || magnitude > TWO_POW_53) {
      val mantissa = if (digits.length == 1) digits else digits[0] + "." + digits.substring(1)
      val exponentText = abs(exponent).toString().padStart(2, '0')
      mantissa + "e" + (if (exponent < 0) "-" else "+") + exponentText
    } else {
      val count = digits.length
      when {
        exponent < 0 -> "0." + "0".repeat(-exponent - 1) + digits
        exponent < count - 1 -> digits.substring(0, exponent + 1) + "." + digits.substring(exponent + 1)
        // Integral values: Swift prints "N.0" and the encoder strips ".0".
        else -> digits + "0".repeat(exponent - (count - 1))
      }
    }
    return sign + body
  }

  /** Shortest round-tripping significant digits (no trailing zeros) and the scientific exponent. */
  private fun shortestDigits(magnitude: Double): Pair<String, Int> {
    val exact = BigDecimal(magnitude)
    for (precision in 1..17) {
      val context = MathContext(precision, RoundingMode.HALF_EVEN)
      val nearest = exact.round(context)
      if (roundTrips(nearest, magnitude)) return digitsOf(nearest)
      // The rounding interval is asymmetric at powers of two: a farther candidate may still fit.
      val candidates = listOf(
        exact.round(MathContext(precision, RoundingMode.UP)),
        exact.round(MathContext(precision, RoundingMode.DOWN)),
      ).filter { roundTrips(it, magnitude) }
      candidates.minByOrNull { (it - exact).abs() }?.let { return digitsOf(it) }
    }
    return digitsOf(exact.round(MathContext(17, RoundingMode.HALF_EVEN)))
  }

  private fun roundTrips(candidate: BigDecimal, target: Double): Boolean =
    java.lang.Double.parseDouble(candidate.toString()) == target

  private fun digitsOf(value: BigDecimal): Pair<String, Int> {
    val unscaled = value.unscaledValue().abs().toString()
    val exponent = unscaled.length - 1 - value.scale()
    return unscaled.trimEnd('0').ifEmpty { "0" } to exponent
  }
}

/**
 * Writes [PJ] values exactly like Foundation's JSONEncoder: compact, keys sorted, control
 * characters escaped with lowercase hex, non-ASCII written raw as UTF-8, and `/` escaped unless
 * [withoutEscapingSlashes] (the outer envelope uses it; nested payloads and fingerprints do not).
 */
class SwiftJsonWriter(private val out: OutputStream, private val withoutEscapingSlashes: Boolean) {
  private val buffer = ByteArray(8_192)
  private var count = 0

  fun write(value: PJ) {
    writeValue(value)
    flush()
  }

  fun writeRaw(bytes: ByteArray) {
    flush()
    out.write(bytes)
  }

  fun writeAscii(text: String) {
    for (char in text) put(char.code)
  }

  fun flush() {
    if (count > 0) {
      out.write(buffer, 0, count)
      count = 0
    }
  }

  private fun put(byte: Int) {
    if (count == buffer.size) flush()
    buffer[count++] = byte.toByte()
  }

  private fun writeValue(value: PJ) {
    when (value) {
      is PJObject -> {
        put('{'.code)
        var first = true
        for (key in value.fields.keys.sortedWith(SwiftKeyOrder)) {
          if (!first) put(','.code)
          first = false
          writeString(key)
          put(':'.code)
          writeValue(value.fields.getValue(key))
        }
        put('}'.code)
      }
      is PJArray -> {
        put('['.code)
        value.items.forEachIndexed { index, item ->
          if (index > 0) put(','.code)
          writeValue(item)
        }
        put(']'.code)
      }
      is PJString -> writeString(value.value)
      is PJNumber -> writeAscii(value.literal)
      is PJBool -> writeAscii(if (value.value) "true" else "false")
      PJNull -> writeAscii("null")
    }
  }

  fun writeString(value: String) {
    put('"'.code)
    var index = 0
    while (index < value.length) {
      val char = value[index]
      val code = char.code
      when {
        char == '"' -> { put('\\'.code); put('"'.code) }
        char == '\\' -> { put('\\'.code); put('\\'.code) }
        char == '/' && !withoutEscapingSlashes -> { put('\\'.code); put('/'.code) }
        code == 0x08 -> { put('\\'.code); put('b'.code) }
        code == 0x0C -> { put('\\'.code); put('f'.code) }
        char == '\n' -> { put('\\'.code); put('n'.code) }
        char == '\r' -> { put('\\'.code); put('r'.code) }
        char == '\t' -> { put('\\'.code); put('t'.code) }
        code < 0x20 -> {
          writeAscii("\\u00")
          put(HEX[code shr 4].code)
          put(HEX[code and 0xF].code)
        }
        code < 0x80 -> put(code)
        code < 0x800 -> {
          put(0xC0 or (code shr 6))
          put(0x80 or (code and 0x3F))
        }
        Character.isHighSurrogate(char) && index + 1 < value.length && Character.isLowSurrogate(value[index + 1]) -> {
          val point = Character.toCodePoint(char, value[index + 1])
          put(0xF0 or (point shr 18))
          put(0x80 or ((point shr 12) and 0x3F))
          put(0x80 or ((point shr 6) and 0x3F))
          put(0x80 or (point and 0x3F))
          index++
        }
        Character.isSurrogate(char) -> {
          // A Swift String cannot hold a lone surrogate; it would have been U+FFFD.
          put(0xEF); put(0xBF); put(0xBD)
        }
        else -> {
          put(0xE0 or (code shr 12))
          put(0x80 or ((code shr 6) and 0x3F))
          put(0x80 or (code and 0x3F))
        }
      }
      index++
    }
    put('"'.code)
  }

  companion object {
    private const val HEX = "0123456789abcdef"

    fun encode(value: PJ, withoutEscapingSlashes: Boolean): ByteArray {
      val bytes = ByteArrayOutputStream()
      SwiftJsonWriter(bytes, withoutEscapingSlashes).write(value)
      return bytes.toByteArray()
    }
  }
}

/** Foundation's `.sortedKeys` order for the ASCII keys this format uses (code-unit order). */
object SwiftKeyOrder : Comparator<String> {
  override fun compare(a: String, b: String): Int = a.compareTo(b)
}

class PortableJsonSyntaxException(message: String) : Exception(message)

/**
 * Pull reader over UTF-8 JSON. Invalid UTF-8, duplicate keys, excessive nesting and oversized
 * strings fail instead of being repaired, so a hostile file cannot exhaust memory through one value.
 */
class PortableJsonReader(input: InputStream, private val maximumStringChars: Int) {
  private val reader = InputStreamReader(
    input,
    StandardCharsets.UTF_8.newDecoder()
      .onMalformedInput(CodingErrorAction.REPORT)
      .onUnmappableCharacter(CodingErrorAction.REPORT),
  )
  private val chars = CharArray(16_384)
  private var position = 0
  private var limit = 0
  private var depth = 0

  private fun fill(): Boolean {
    if (position < limit) return true
    limit = try {
      reader.read(chars, 0, chars.size)
    } catch (error: CharacterCodingException) {
      throw PortableJsonSyntaxException("The file is not valid UTF-8.")
    }
    position = 0
    return limit > 0
  }

  private fun peekChar(): Char? = if (fill()) chars[position] else null

  private fun nextChar(): Char {
    if (!fill()) throw PortableJsonSyntaxException("Unexpected end of file.")
    return chars[position++]
  }

  private fun skipWhitespace() {
    while (true) {
      val char = peekChar() ?: return
      if (char == ' ' || char == '\n' || char == '\r' || char == '\t') position++ else return
    }
  }

  private fun expect(char: Char) {
    skipWhitespace()
    val actual = nextChar()
    if (actual != char) throw PortableJsonSyntaxException("Expected '$char'.")
  }

  fun peekToken(): Char {
    skipWhitespace()
    return peekChar() ?: throw PortableJsonSyntaxException("Unexpected end of file.")
  }

  fun beginObject() {
    expect('{')
    enter()
  }

  fun beginArray() {
    expect('[')
    enter()
  }

  private fun enter() {
    depth++
    if (depth > MAXIMUM_DEPTH) throw PortableJsonSyntaxException("The file is nested too deeply.")
    first = true
  }

  private var first = true

  /** True while the current object/array has another member; consumes separators. */
  fun hasNext(): Boolean {
    val token = peekToken()
    if (token == '}' || token == ']') return false
    if (!first) {
      if (token != ',') throw PortableJsonSyntaxException("Expected ','.")
      position++
    }
    first = false
    return true
  }

  fun endObject() {
    expect('}')
    depth--
    first = false
  }

  fun endArray() {
    expect(']')
    depth--
    first = false
  }

  fun nextName(): String {
    val name = nextString()
    expect(':')
    return name
  }

  fun nextString(): String {
    expect('"')
    val builder = StringBuilder()
    while (true) {
      val char = nextChar()
      when {
        char == '"' -> return builder.toString()
        char == '\\' -> when (val escaped = nextChar()) {
          '"' -> builder.append('"')
          '\\' -> builder.append('\\')
          '/' -> builder.append('/')
          'b' -> builder.append('\b')
          'f' -> builder.append('\u000C')
          'n' -> builder.append('\n')
          'r' -> builder.append('\r')
          't' -> builder.append('\t')
          'u' -> {
            var code = 0
            repeat(4) {
              val digit = Character.digit(nextChar(), 16)
              if (digit < 0) throw PortableJsonSyntaxException("Invalid unicode escape.")
              code = code * 16 + digit
            }
            builder.append(code.toChar())
          }
          else -> throw PortableJsonSyntaxException("Invalid escape '\\$escaped'.")
        }
        char.code < 0x20 -> throw PortableJsonSyntaxException("Unescaped control character in a string.")
        else -> builder.append(char)
      }
      if (builder.length > maximumStringChars) throw PortableValueTooLargeException()
    }
  }

  /** Reads one complete value (object, array or scalar) as a [PJ] tree. */
  fun readValue(): PJ {
    return when (peekToken()) {
      '{' -> {
        beginObject()
        val fields = LinkedHashMap<String, PJ>()
        while (hasNext()) {
          val key = nextName()
          if (fields.put(key, readValue()) != null) throw PortableJsonSyntaxException("Duplicate key.")
        }
        endObject()
        PJObject(fields)
      }
      '[' -> {
        beginArray()
        val items = ArrayList<PJ>()
        while (hasNext()) items += readValue()
        endArray()
        PJArray(items)
      }
      '"' -> PJString(nextString()).also { first = false }
      't', 'f', 'n' -> readLiteral().also { first = false }
      else -> PJNumber(readNumber()).also { first = false }
    }
  }

  private fun readLiteral(): PJ {
    val word = StringBuilder()
    while (true) {
      val char = peekChar() ?: break
      if (!char.isLetter()) break
      word.append(char)
      position++
      if (word.length > 5) break
    }
    return when (word.toString()) {
      "true" -> PJBool.TRUE
      "false" -> PJBool.FALSE
      "null" -> PJNull
      else -> throw PortableJsonSyntaxException("Invalid literal.")
    }
  }

  private fun readNumber(): String {
    skipWhitespace()
    val builder = StringBuilder()
    while (true) {
      val char = peekChar() ?: break
      if (char.isDigit() || char == '-' || char == '+' || char == '.' || char == 'e' || char == 'E') {
        builder.append(char)
        position++
        if (builder.length > 64) throw PortableJsonSyntaxException("Invalid number.")
      } else {
        break
      }
    }
    val literal = builder.toString()
    if (!NUMBER.matches(literal)) throw PortableJsonSyntaxException("Invalid number.")
    return literal
  }

  /** Requires that only whitespace remains. */
  fun finish() {
    skipWhitespace()
    if (peekChar() != null) throw PortableJsonSyntaxException("Unexpected trailing content.")
  }

  companion object {
    private const val MAXIMUM_DEPTH = 64
    private val NUMBER = Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?")

    fun parse(bytes: ByteArray, maximumStringChars: Int = bytes.size + 16): PJ {
      val reader = PortableJsonReader(bytes.inputStream(), maximumStringChars)
      val value = reader.readValue()
      reader.finish()
      return value
    }
  }
}

class PortableValueTooLargeException : Exception("A value in the backup is larger than the record limit.")

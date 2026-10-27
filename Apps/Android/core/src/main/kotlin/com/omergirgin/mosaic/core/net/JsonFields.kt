package com.omergirgin.mosaic.core.net

import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// Typed accessors mirroring Swift's `as?` casts over JSONSerialization output. Each returns null on
// a type mismatch instead of coercing, so a provider cannot pass a string where a number or a
// capability flag is expected.

internal fun JsonElement?.objectOrNull(): JsonObject? = this as? JsonObject

internal fun JsonElement?.stringOrNull(): String? =
  (this as? JsonPrimitive)?.takeIf { it.isString }?.content

internal fun JsonElement?.intOrNull(): Int? {
  val primitive = this as? JsonPrimitive ?: return null
  if (primitive.isString || primitive is JsonNull) return null
  val content = primitive.content
  content.toLongOrNull()?.let { value ->
    return if (value in Int.MIN_VALUE..Int.MAX_VALUE) value.toInt() else null
  }
  // JSONSerialization bridges an integral double such as `5.0` to Int; fractional values do not.
  val value = content.toDoubleOrNull() ?: return null
  if (value.isNaN() || value.isInfinite() || value != Math.floor(value)) return null
  if (value < Int.MIN_VALUE.toDouble() || value > Int.MAX_VALUE.toDouble()) return null
  return value.toInt()
}

internal fun JsonElement?.booleanOrNull(): Boolean? {
  val primitive = this as? JsonPrimitive ?: return null
  if (primitive.isString) return null
  return when (primitive.content) {
    "true" -> true
    "false" -> false
    else -> null
  }
}

/** Like Swift's `as? [[String: Any]]`: null unless every element is an object. */
internal fun JsonElement?.objectListOrNull(): List<JsonObject>? {
  val array = this as? JsonArray ?: return null
  return array.map { it as? JsonObject ?: return null }
}

/** Like Swift's `as? [String]`: null unless every element is a string. */
internal fun JsonElement?.stringListOrNull(): List<String>? {
  val array = this as? JsonArray ?: return null
  return array.map { it.stringOrNull() ?: return null }
}

/** Resolves a dotted path such as `top_provider.max_completion_tokens` through nested objects. */
internal fun JsonObject.at(path: String): JsonElement? {
  var current: JsonElement? = this
  for (key in path.split('.')) {
    current = (current as? JsonObject)?.get(key) ?: return null
  }
  return current
}

internal object ProviderJson {
  private val json = Json

  /** Parses provider JSON. Throws on malformed JSON or invalid UTF-8 (mapped to INVALID_RESPONSE). */
  fun parse(bytes: ByteArray): JsonElement {
    val text = decodeUtf8Strict(bytes, 0, bytes.size) ?: throw ProviderFailures.of(ProviderErrorKind.INVALID_RESPONSE)
    // JSONSerialization tolerates a UTF-8 byte-order mark; kotlinx does not.
    return json.parseToJsonElement(text.removePrefix("﻿"))
  }

  fun parse(text: String): JsonElement = json.parseToJsonElement(text)
}

/** Strict UTF-8 decode; null when the bytes are not valid UTF-8 (Swift `String(bytes:encoding:)`). */
internal fun decodeUtf8Strict(bytes: ByteArray, offset: Int, length: Int): String? =
  try {
    Charsets.UTF_8.newDecoder()
      .onMalformedInput(CodingErrorAction.REPORT)
      .onUnmappableCharacter(CodingErrorAction.REPORT)
      .decode(ByteBuffer.wrap(bytes, offset, length))
      .toString()
  } catch (_: CharacterCodingException) {
    null
  }

/** UTF-8 byte length without allocating an encoded copy. */
internal fun String.utf8Size(): Long {
  var size = 0L
  var index = 0
  while (index < length) {
    val char = this[index]
    when {
      char.code < 0x80 -> size += 1
      char.code < 0x800 -> size += 2
      char.isHighSurrogate() && index + 1 < length && this[index + 1].isLowSurrogate() -> {
        size += 4
        index++
      }
      else -> size += 3
    }
    index++
  }
  return size
}

/** First [count] code points, never splitting a surrogate pair. */
internal fun String.prefixCodePoints(count: Int): String {
  if (length <= count) return this
  val end = runCatching { offsetByCodePoints(0, count) }.getOrDefault(length)
  return substring(0, end)
}

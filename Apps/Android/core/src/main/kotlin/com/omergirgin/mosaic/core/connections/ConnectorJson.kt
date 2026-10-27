package com.omergirgin.mosaic.core.connections

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull

/**
 * Bounded JSON for connector traffic. Service responses are parsed only after a nesting-depth scan
 * so a hostile body can never exhaust the recursive parser's stack.
 */
object ConnectorJson {
  private const val MAXIMUM_DEPTH = 96
  private val json = Json { prettyPrint = false }

  fun parse(bytes: ByteArray): JsonElement {
    val text = utf8(bytes) ?: throw ConnectorException(ConnectorException.Kind.INVALID_RESPONSE)
    return parse(text)
  }

  fun parse(text: String): JsonElement {
    val trimmed = text.removePrefix("﻿")
    if (!depthWithin(trimmed)) throw ConnectorException(ConnectorException.Kind.TOO_LARGE)
    return try {
      json.parseToJsonElement(trimmed)
    } catch (_: Exception) {
      throw ConnectorException(ConnectorException.Kind.INVALID_RESPONSE)
    }
  }

  fun encode(value: JsonElement): String = json.encodeToString(JsonElement.serializer(), value)

  /** Strict UTF-8 decode; null for invalid bytes. */
  fun utf8(bytes: ByteArray): String? = try {
    Charsets.UTF_8.newDecoder()
      .onMalformedInput(CodingErrorAction.REPORT)
      .onUnmappableCharacter(CodingErrorAction.REPORT)
      .decode(ByteBuffer.wrap(bytes))
      .toString()
  } catch (_: CharacterCodingException) {
    null
  }

  private fun depthWithin(text: String): Boolean {
    var depth = 0
    var inString = false
    var escaped = false
    for (char in text) {
      if (inString) {
        when {
          escaped -> escaped = false
          char == '\\' -> escaped = true
          char == '"' -> inString = false
        }
        continue
      }
      when (char) {
        '"' -> inString = true
        '[', '{' -> if (++depth > MAXIMUM_DEPTH) return false
        ']', '}' -> depth--
      }
    }
    return true
  }
}

// Typed accessors mirroring the iOS `ConnectorJSON` enum: a type mismatch reads as null.
operator fun JsonElement?.get(key: String): JsonElement? = (this as? JsonObject)?.get(key)
val JsonElement?.objectValue: JsonObject? get() = this as? JsonObject
val JsonElement?.arrayValue: JsonArray? get() = this as? JsonArray
val JsonElement?.stringValue: String? get() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
val JsonElement?.booleanValue: Boolean? get() = (this as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
val JsonElement?.numberValue: Double?
  get() = (this as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.doubleOrNull?.takeIf { it.isFinite() }
val JsonElement?.isNullOrMissing: Boolean get() = this == null || this is JsonNull
val JsonElement.encoded: String get() = ConnectorJson.encode(this)

fun jsonString(value: String): JsonPrimitive = JsonPrimitive(value)
fun jsonObject(vararg pairs: Pair<String, JsonElement>): JsonObject = JsonObject(linkedMapOf(*pairs))

object ConnectorText {
  private val random = SecureRandom()

  /** UTF-8 prefix of at most [bytes] bytes that never splits a code point. */
  fun bounded(value: String, bytes: Int): String {
    if (bytes <= 0) return ""
    var used = 0
    var index = 0
    while (index < value.length) {
      val codePoint = value.codePointAt(index)
      val size = when {
        codePoint < 0x80 -> 1
        codePoint < 0x800 -> 2
        codePoint < 0x10000 -> 3
        else -> 4
      }
      if (used + size > bytes) break
      used += size
      index += Character.charCount(codePoint)
    }
    return if (index >= value.length) value else value.substring(0, index)
  }

  fun utf8Size(value: String): Int = value.encodeToByteArray().size

  /** 256 random bits as lowercase hex (OAuth state / PKCE verifier). */
  fun randomHex(): String {
    val bytes = ByteArray(32)
    random.nextBytes(bytes)
    return bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }
  }

  fun base64Url(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

  fun sha256(value: String): ByteArray = MessageDigest.getInstance("SHA-256").digest(value.encodeToByteArray())

  /** IDs that may be placed into a fixed URL path (Gmail/Drive/Todoist identifiers). */
  fun validId(id: String): Boolean =
    id.isNotEmpty() && id.length < 256 && id.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '_' || it == '-' }

  /** RFC 3986 unreserved characters stay literal; everything else is percent-encoded per UTF-8 byte. */
  fun percentEncode(value: String, extraAllowed: String = ""): String {
    val output = StringBuilder(value.length)
    for (byte in value.encodeToByteArray()) {
      val unsigned = byte.toInt() and 0xff
      val char = unsigned.toChar()
      if (unsigned < 0x80 && (char.isLetterOrDigit() || char in "-._~" || char in extraAllowed)) {
        output.append(char)
      } else {
        output.append('%').append("0123456789ABCDEF"[unsigned shr 4]).append("0123456789ABCDEF"[unsigned and 0x0f])
      }
    }
    return output.toString()
  }

  /** `application/x-www-form-urlencoded` body with sorted keys (iOS `GoogleWire.form`). */
  fun form(values: Map<String, String>): ByteArray =
    values.entries.sortedBy { it.key }
      .joinToString("&") { percentEncode(it.key) + "=" + percentEncode(it.value) }
      .encodeToByteArray()

  /** Strict percent-decoding without `+` → space (URLComponents semantics). Null on malformed input. */
  fun percentDecode(value: String): String? {
    val bytes = ByteArrayOutputStream(value.length)
    var index = 0
    while (index < value.length) {
      val char = value[index]
      if (char == '%') {
        if (index + 2 > value.lastIndex) return null
        val high = Character.digit(value[index + 1], 16)
        val low = Character.digit(value[index + 2], 16)
        if (high < 0 || low < 0) return null
        bytes.write(high * 16 + low)
        index += 3
      } else {
        val encoded = char.toString().encodeToByteArray()
        bytes.write(encoded, 0, encoded.size)
        index++
      }
    }
    return ConnectorJson.utf8(bytes.toByteArray())
  }

  /** Query items of a raw (still encoded) query string, preserving duplicates. */
  fun queryItems(rawQuery: String?): List<Pair<String, String?>>? {
    if (rawQuery.isNullOrEmpty()) return emptyList()
    return rawQuery.split('&').map { part ->
      val separator = part.indexOf('=')
      val name = percentDecode(if (separator < 0) part else part.substring(0, separator)) ?: return null
      val value = if (separator < 0) null else (percentDecode(part.substring(separator + 1)) ?: return null)
      name to value
    }
  }
}

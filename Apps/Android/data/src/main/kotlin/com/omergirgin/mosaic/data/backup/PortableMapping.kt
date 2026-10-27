package com.omergirgin.mosaic.data.backup

import com.omergirgin.mosaic.core.backup.PortableBackupValidator
import com.omergirgin.mosaic.core.provider.ProviderKind

/** Vocabulary differences between Android rows and the iOS portable records. */
internal object PortableMapping {
  /** Android `MessageStatus.name` → iOS `MessageStatus` raw value. */
  fun messageStatusToPortable(status: String): String = when (status) {
    "COMPLETE" -> "complete"
    "STREAMING" -> "streaming"
    "CANCELLED" -> "cancelled"
    else -> "failed"
  }

  /** iOS status → Android. Unfinished iOS rows cannot resume here, so they become failed attempts. */
  fun messageStatusFromPortable(status: String): String = when (status) {
    "complete" -> "COMPLETE"
    "cancelled" -> "CANCELLED"
    else -> "FAILED"
  }

  /** Android pinned-fact scope (`MemoryScope.name`) ↔ iOS `MemoryScope`. */
  fun factScopeToPortable(scope: String): String = when (scope) {
    "PROJECT" -> "project"
    "CONVERSATION" -> "conversation"
    else -> "global"
  }

  fun factScopeFromPortable(scope: String): String = when (scope) {
    "project" -> "PROJECT"
    "conversation" -> "CONVERSATION"
    else -> "EVERYWHERE"
  }

  fun validProviderKind(raw: String?): String? = raw?.takeIf { ProviderKind.fromRawId(it) != null }

  /** Usage categories iOS recomputes from other records (messages, formation audits). */
  val IOS_DERIVED_USAGE = setOf("Chat", "Memory")

  /** Android usage category → iOS report category. */
  fun usageCategoryToPortable(category: String): String = when (category) {
    "Compaction" -> "Summarization"
    else -> category
  }

  fun usageCategoryFromPortable(category: String): String = when (category) {
    "Summarization" -> "Compaction"
    "Memory formation" -> "Memory"
    else -> category
  }

  fun utf8(value: String): Int = PortableBackupValidator.utf8(value)

  /** Longest prefix within [maximumBytes] UTF-8 bytes, never splitting a code point. */
  fun boundedUtf8(value: String, maximumBytes: Int): String {
    if (utf8(value) <= maximumBytes) return value
    var bytes = 0
    var index = 0
    while (index < value.length) {
      val point = value.codePointAt(index)
      val size = String(Character.toChars(point)).toByteArray(Charsets.UTF_8).size
      if (bytes + size > maximumBytes) break
      bytes += size
      index += Character.charCount(point)
    }
    return value.substring(0, index)
  }

  /** JPEG files start with FF D8 FF. */
  fun isJpeg(bytes: ByteArray): Boolean =
    bytes.size > 3 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte() && bytes[2] == 0xFF.toByte()
}

package com.omergirgin.mosaic.core.backup

import java.math.BigDecimal
import java.math.RoundingMode
import java.security.MessageDigest
import java.util.UUID
import kotlin.math.abs

/** Fixed identity of the iOS-compatible `.mosaicbackup` format (iOS `MosaicPortableBackup`). */
object PortableBackupFormat {
  const val FORMAT_IDENTIFIER = "com.omergirgin.mosaic.backup"
  const val FORMAT_VERSION = 1
  const val READER_VERSION = 1
  /** iOS writes its main-store schema tag; Android writes the same tag it can fully read. */
  const val SOURCE_SCHEMA_VERSION = "mosaic-main-6"
  const val FILE_EXTENSION = "mosaicbackup"
  const val MIME_TYPE = "application/octet-stream"
}

/** Same bounded in-memory envelope as iOS version 1. */
data class PortableBackupLimits(
  val maximumTotalBytes: Long = 256L * 1_024 * 1_024,
  val maximumRecordBytes: Int = 8 * 1_024 * 1_024,
  val maximumRecordCount: Int = 1_000_000,
  /** One normalized request-context payload (iOS `maximumCompactPayloadBytes`). */
  val maximumNormalizedPayloadBytes: Int = 512_000,
) {
  companion object {
    val DEFAULT = PortableBackupLimits()
  }
}

/** User-facing failure; wording follows iOS `MosaicPortableBackupError` where one exists. */
class PortableBackupException(val reason: Reason, message: String) : Exception(message) {
  enum class Reason {
    MALFORMED,
    UNSUPPORTED_FORMAT,
    UNSUPPORTED_VERSION,
    READER_TOO_OLD,
    TOO_LARGE,
    RECORD_TOO_LARGE,
    TOO_MANY_RECORDS,
    CHECKSUM_MISMATCH,
    DUPLICATE,
    MISSING_REFERENCE,
    INVALID_VALUE,
    UNSUPPORTED_EXTENSION,
  }

  companion object {
    fun malformed() = PortableBackupException(Reason.MALFORMED, "The selected file is not a valid Turing AI backup.")
    fun unsupportedFormat() = PortableBackupException(Reason.UNSUPPORTED_FORMAT, "The selected file uses a different backup format.")
    fun unsupportedVersion(found: Int) = PortableBackupException(
      Reason.UNSUPPORTED_VERSION,
      "This backup uses format version $found, but this version of Turing AI supports up to ${PortableBackupFormat.FORMAT_VERSION}.",
    )
    fun readerTooOld(required: Int) = PortableBackupException(
      Reason.READER_TOO_OLD,
      "This backup requires reader version $required; this version of Turing AI provides ${PortableBackupFormat.READER_VERSION}.",
    )
    fun tooLarge() = PortableBackupException(
      Reason.TOO_LARGE,
      "This backup or local library is larger than Turing AI can process safely in one operation.",
    )
    fun recordTooLarge(recordType: String) = PortableBackupException(
      Reason.RECORD_TOO_LARGE,
      "A ${readable(recordType)} record is larger than the configured safety limit.",
    )
    fun tooManyRecords() = PortableBackupException(
      Reason.TOO_MANY_RECORDS,
      "This backup or local library contains more records than Turing AI can process safely in one operation.",
    )
    fun checksumMismatch() = PortableBackupException(Reason.CHECKSUM_MISMATCH, "The backup checksum does not match its contents.")
    fun duplicateId(recordType: String) = PortableBackupException(
      Reason.DUPLICATE,
      "The backup contains a duplicate ${readable(recordType)} identifier.",
    )
    fun duplicateKey(recordType: String) = PortableBackupException(
      Reason.DUPLICATE,
      "The backup contains a duplicate ${readable(recordType)} key.",
    )
    fun missing(recordType: String, field: String) = PortableBackupException(
      Reason.MISSING_REFERENCE,
      "A ${readable(recordType)} record points to a missing ${readable(field)} record.",
    )
    fun invalid(recordType: String, field: String) = PortableBackupException(
      Reason.INVALID_VALUE,
      "A ${readable(recordType)} record contains an invalid ${readable(field)} value.",
    )
    fun unsupportedExtension() = PortableBackupException(
      Reason.UNSUPPORTED_EXTENSION,
      "This backup contains an extension record that this version of Turing AI cannot restore.",
    )

    private fun readable(value: String) = value.replace('_', ' ')
  }
}

/**
 * UUID text rules. Android stores lowercase canonical strings; Swift encodes `UUID` as the
 * uppercase `uuidString` and accepts either case when decoding.
 */
object PortableIds {
  private val CANONICAL = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

  fun isCanonical(value: String): Boolean = CANONICAL.matches(value)

  /** Android form of a decoded Swift UUID, or null when it is not a UUID. */
  fun fromPortable(value: String): String? = if (isCanonical(value)) value.lowercase() else null

  /**
   * Swift form of an Android ID. A non-UUID local ID maps to a stable derived UUID so every
   * reference to it stays consistent inside one backup.
   */
  fun toPortable(value: String): String =
    if (isCanonical(value)) value.uppercase() else deterministic("android-id:$value")

  /** iOS `deterministicUUID` / `ExperienceValue.modelID`: the first 16 SHA-256 bytes, unmodified. */
  fun deterministic(key: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(key.toByteArray(Charsets.UTF_8))
    val hex = digest.copyOf(16).joinToString("") { "%02X".format(it) }
    return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}"
  }

  /** Android form of [deterministic]. */
  fun deterministicLocal(key: String): String = deterministic(key).lowercase()

  fun random(): String = UUID.randomUUID().toString()
}

/**
 * A Swift `Date` encoded with the default strategy: seconds since 2001-01-01 as a JSON number.
 * The exact decoded value is kept so ordering matches iOS; Android rows use epoch millis.
 */
class PortableDate private constructor(
  val seconds: Double,
  private val sourceLiteral: String,
  canonical: String?,
) : Comparable<PortableDate> {
  /** Swift `JSONEncoder` form (computed lazily for decoded values; exact for millisecond values). */
  val literal: String by lazy(LazyThreadSafetyMode.NONE) { canonical ?: SwiftNumber.format(seconds) }

  /** Nearest epoch millisecond. */
  val epochMillis: Long
    get() = BigDecimal(sourceLiteral).movePointRight(3).setScale(0, RoundingMode.HALF_EVEN).toLong() + REFERENCE_EPOCH_MILLIS

  override fun compareTo(other: PortableDate): Int = seconds.compareTo(other.seconds)
  override fun equals(other: Any?): Boolean = other is PortableDate && other.seconds == seconds
  override fun hashCode(): Int = seconds.hashCode()
  override fun toString(): String = literal

  companion object {
    /** 2001-01-01T00:00:00Z in Unix epoch millis. */
    const val REFERENCE_EPOCH_MILLIS = 978_307_200_000L
    /** About +/- 31,000 years: keeps millisecond conversion far from Long overflow. */
    private const val MAXIMUM_SECONDS = 1.0e12

    /**
     * Exact Swift literal for a millisecond timestamp. The quotient has at most three decimals, so
     * that decimal is the shortest representation of the nearest Double, which is what iOS prints.
     */
    fun fromMillis(epochMillis: Long): PortableDate {
      val relative = epochMillis - REFERENCE_EPOCH_MILLIS
      val magnitude = abs(relative)
      val whole = magnitude / 1_000
      val fraction = magnitude % 1_000
      val text = buildString {
        if (relative < 0) append('-')
        append(whole)
        if (fraction != 0L) append('.').append(fraction.toString().padStart(3, '0').trimEnd('0'))
      }
      val canonical = if (relative == 0L) "0" else text
      return PortableDate(relative.toDouble() / 1_000.0, canonical, canonical)
    }

    fun fromLiteral(literal: String): PortableDate? {
      val value = literal.toDoubleOrNull() ?: return null
      if (!value.isFinite() || abs(value) > MAXIMUM_SECONDS) return null
      return PortableDate(value, literal, null)
    }
  }
}

object PortableHashes {
  fun sha256Hex(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

  fun sha256Hex(text: String): String = sha256Hex(text.toByteArray(Charsets.UTF_8))
}

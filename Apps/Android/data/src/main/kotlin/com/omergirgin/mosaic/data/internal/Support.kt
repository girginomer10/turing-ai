package com.omergirgin.mosaic.data.internal

import android.database.SQLException
import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import com.omergirgin.mosaic.core.chat.ProviderException
import com.omergirgin.mosaic.core.context.ContextPlanningException
import com.omergirgin.mosaic.core.context.utf8Length
import com.omergirgin.mosaic.core.net.EndpointPolicy
import com.omergirgin.mosaic.core.net.ProviderErrorSanitizer
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

internal fun newId(): String = UUID.randomUUID().toString()

/**
 * Strictly increasing wall-clock millis within the process. Transcript order is (createdAt, id),
 * so a user message and its assistant row created in the same millisecond must still sort in
 * creation order rather than by random UUID.
 */
internal object MonotonicClock {
  private val last = AtomicLong(0)
  fun now(): Long = last.updateAndGet { previous -> maxOf(previous + 1, System.currentTimeMillis()) }
}

/** Source-field limits shared with iOS `MosaicSourceFieldLimits` so backups stay portable. */
internal object FieldLimits {
  const val CONVERSATION_TITLE_BYTES = 16 * 1_024
  const val SYSTEM_PROMPT_BYTES = 256 * 1_024
  const val DRAFT_BYTES = 512 * 1_024
  const val MESSAGE_CONTENT_BYTES = 512 * 1_024
  const val PROJECT_NAME_BYTES = 4 * 1_024
  const val PROJECT_INSTRUCTIONS_BYTES = 256 * 1_024
  const val MEMORY_TITLE_BYTES = 4 * 1_024
  const val MEMORY_CONTENT_BYTES = 256 * 1_024
  const val MODEL_ID_BYTES = 2_048
  const val ATTACHMENTS_PER_MESSAGE = 4
  /** iOS rejects longer document text and suggests importing it into Memory instead. */
  const val ATTACHMENT_TEXT_BYTES = 800_000
  /** Normalized photos are <= 1 MiB of JPEG; base64 adds 4/3. */
  const val IMAGE_BASE64_CHARS = ((1_048_576 + 2) / 3) * 4

  fun requireWithin(value: String, maximumBytes: Int, label: String) {
    val bytes = utf8Length(value)
    require(bytes <= maximumBytes) {
      "$label is too long (${bytes / 1_024} KB). The limit is ${maximumBytes / 1_024} KB."
    }
  }
}

/** iOS `compactTitle`: whitespace-collapsed, at most 52 characters with a trailing ellipsis. */
internal fun compactTitle(content: String): String {
  val normalized = content.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
  val count = normalized.codePointCount(0, normalized.length)
  if (count <= 52) return normalized
  return normalized.substring(0, normalized.offsetByCodePoints(0, 51)) + "…"
}

/**
 * User-facing error text for the chat transcript and provider editor. Provider and transport
 * failures go through the network layer's `ProviderErrorSanitizer` (iOS parity: key redaction,
 * control characters stripped, <= 2,000 characters); local validation and planning errors keep
 * their own wording.
 */
internal object ErrorSanitizer {
  private const val FALLBACK = "The request failed unexpectedly. Try again."

  fun describe(error: Throwable, secret: String?): String = when (error) {
    is ContextPlanningException, is IllegalArgumentException, is IllegalStateException ->
      sanitize(error.message ?: FALLBACK, secret)
    is SQLException -> "Turing AI could not read or save this chat on the device."
    else -> ProviderErrorSanitizer.describe(error, secret)
  }

  /** Redacts [secret] and normalizes local text with the same rules as provider messages. */
  fun sanitize(raw: String, secret: String?): String =
    ProviderErrorSanitizer.describe(ProviderException(ProviderErrorKind.INVALID_RESPONSE, raw), secret)
      .ifEmpty { FALLBACK }
}

/**
 * Editor-facing endpoint validation on top of the network layer's [EndpointPolicy] (one policy for
 * the editor and the HTTP client), with the more instructive iOS editor wording.
 */
internal object EndpointValidation {
  fun validate(baseUrl: String) {
    try {
      EndpointPolicy.validate(baseUrl)
    } catch (error: ProviderException) {
      throw when (error.kind) {
        ProviderErrorKind.INSECURE_ENDPOINT -> ProviderException(
          ProviderErrorKind.INSECURE_ENDPOINT,
          "For your security, a remote provider must use https://. Plain http:// is allowed only for " +
            "localhost or a private local network address.",
        )
        else -> ProviderException(
          ProviderErrorKind.INVALID_ENDPOINT,
          "Enter a complete base URL beginning with https://, or use http:// only for a local network " +
            "address. URLs cannot contain credentials, a query, or a fragment.",
        )
      }
    }
  }
}

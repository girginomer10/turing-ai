package com.omergirgin.mosaic.core.net

import com.omergirgin.mosaic.core.chat.ProviderErrorKind

internal data class SseEvent(val name: String?, val data: String, val id: String?)

/** Line-level Server-Sent Events parser (`event`, `data`, `id`; comments and `retry` ignored). */
internal class SseParser {
  private var eventName: String? = null
  private var eventId: String? = null
  private val dataLines = ArrayList<String>()

  fun consume(line: String): SseEvent? {
    if (line.isEmpty()) {
      if (eventName == null && eventId == null && dataLines.isEmpty()) return null
      val event = SseEvent(eventName, dataLines.joinToString("\n"), eventId)
      eventName = null
      eventId = null
      dataLines.clear()
      return event
    }
    if (line.startsWith(":")) return null
    val colon = line.indexOf(':')
    val field = if (colon < 0) line else line.substring(0, colon)
    var value = if (colon < 0) "" else line.substring(colon + 1)
    if (value.startsWith(" ")) value = value.substring(1)
    when (field) {
      "event" -> eventName = value
      "data" -> dataLines += value
      "id" -> eventId = value
    }
    return null
  }

  /** Dispatches a trailing event even without a final blank line (some hosts end on `[DONE]`). */
  fun finish(): SseEvent? = consume("")
}

/**
 * Byte-level SSE framing with CR, LF and CRLF line endings. A single line is capped at 256 KiB and
 * one event at 1 MiB, so a hostile or broken stream cannot grow memory without bound; each line
 * must be valid UTF-8.
 */
internal class BoundedSseDecoder {
  private val parser = SseParser()
  private var line = ByteArray(1_024)
  private var lineLength = 0
  private var eventByteCount = 0
  private var previousByteWasCarriageReturn = false

  fun consume(byte: Byte): SseEvent? {
    when (byte) {
      CARRIAGE_RETURN -> {
        previousByteWasCarriageReturn = true
        return consumeBufferedLine()
      }
      LINE_FEED -> {
        if (previousByteWasCarriageReturn) {
          previousByteWasCarriageReturn = false
          return null
        }
        return consumeBufferedLine()
      }
    }
    previousByteWasCarriageReturn = false
    if (lineLength >= LINE_LIMIT || eventByteCount >= EVENT_LIMIT) {
      throw ProviderFailures.of(ProviderErrorKind.RESPONSE_TOO_LARGE)
    }
    if (lineLength == line.size) line = line.copyOf(minOf(line.size * 2, LINE_LIMIT))
    line[lineLength++] = byte
    eventByteCount++
    return null
  }

  fun finish(): List<SseEvent> {
    previousByteWasCarriageReturn = false
    val events = ArrayList<SseEvent>(2)
    if (lineLength > 0) consumeBufferedLine()?.let(events::add)
    parser.finish()?.let(events::add)
    eventByteCount = 0
    return events
  }

  private fun consumeBufferedLine(): SseEvent? {
    val text =
      decodeUtf8Strict(line, 0, lineLength) ?: throw ProviderFailures.of(ProviderErrorKind.INVALID_RESPONSE)
    lineLength = 0
    val event = parser.consume(text)
    if (text.isEmpty()) eventByteCount = 0
    return event
  }

  private companion object {
    const val LINE_LIMIT = 256 * 1_024
    const val EVENT_LIMIT = 1_024 * 1_024
    const val CARRIAGE_RETURN: Byte = 0x0D
    const val LINE_FEED: Byte = 0x0A
  }
}

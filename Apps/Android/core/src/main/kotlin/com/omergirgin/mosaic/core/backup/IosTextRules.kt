package com.omergirgin.mosaic.core.backup

import java.security.MessageDigest
import java.text.BreakIterator

/**
 * Swift/Foundation text semantics that iOS restore validation depends on: `whitespacesAndNewlines`
 * trimming, `Character` (grapheme cluster) counts, evidence excerpts, rendered compaction
 * summaries, attachment markers in canonical message text, and the length-prefixed fingerprints.
 */
object IosTextRules {
  const val DOCUMENT_MARKER = "\n\n[Attached document content]\n"
  const val IMAGE_MARKER = "[Attached photo SHA256:"
  private const val EVIDENCE_EXCERPT_CHARACTERS = 1_500

  /** Unicode Zs, TAB and Foundation's newline set (U+000A-U+000D, U+0085, U+2028, U+2029). */
  fun isWhitespaceOrNewline(char: Char): Boolean = when (char) {
    '\t', '\n', '\u000B', '\u000C', '\r', '\u0085', ' ', ' ' -> true
    else -> Character.getType(char) == Character.SPACE_SEPARATOR.toInt()
  }

  fun trim(value: String): String {
    var start = 0
    var end = value.length
    while (start < end && isWhitespaceOrNewline(value[start])) start++
    while (end > start && isWhitespaceOrNewline(value[end - 1])) end--
    return value.substring(start, end)
  }

  fun characterCount(value: String): Int {
    val iterator = BreakIterator.getCharacterInstance()
    iterator.setText(value)
    var count = 0
    while (iterator.next() != BreakIterator.DONE) count++
    return count
  }

  private fun prefixCharacters(value: String, count: Int): String {
    val iterator = BreakIterator.getCharacterInstance()
    iterator.setText(value)
    var end = 0
    repeat(count) {
      val next = iterator.next()
      if (next == BreakIterator.DONE) return value
      end = next
    }
    return value.substring(0, end)
  }

  /** iOS `AutomaticMemoryPortableArchive.evidenceExcerpt`. */
  fun evidenceExcerpt(content: String): String {
    val normalized = trim(content)
    if (characterCount(normalized) <= EVIDENCE_EXCERPT_CHARACTERS) return normalized
    return prefixCharacters(normalized, EVIDENCE_EXCERPT_CHARACTERS - 1) + "…"
  }

  /** iOS `MosaicPortableBackup.renderedSummary(for:)`. */
  fun renderedSummary(overview: String, items: List<Pair<String, String>>): String? {
    val lines = ArrayList<String>()
    trim(overview).takeIf { it.isNotEmpty() }?.let(lines::add)
    for ((kind, text) in items) {
      val label = when (kind) {
        "goal" -> "Current goal"
        "preference" -> "Preference"
        "fact" -> "Fact"
        "constraint" -> "Constraint"
        "decision" -> "Decision"
        "completed" -> "Completed"
        "correction" -> "Correction"
        "open_loop" -> "Open loop"
        else -> return null
      }
      lines += "- $label: $text"
    }
    return lines.joinToString("\n")
  }

  /** Visible user text of an iOS canonical message (iOS `ChatAttachmentStore.displayText`). */
  fun displayText(content: String): String {
    val document = content.indexOf(DOCUMENT_MARKER).takeIf { it >= 0 } ?: content.length
    val image = content.indexOf("\n\n" + IMAGE_MARKER).takeIf { it >= 0 } ?: content.length
    return content.substring(0, minOf(document, image))
  }

  /** One attachment as embedded by iOS into canonical user message text. */
  sealed interface EmbeddedAttachment {
    class Image(val sha256Hex: String, val filename: String?) : EmbeddedAttachment
    class Document(val filename: String?, val text: String) : EmbeddedAttachment
  }

  /** iOS `ChatAttachmentStore.messageContent(text:attachments:)`. */
  fun canonicalContent(text: String, attachments: List<EmbeddedAttachment>): String {
    val builder = StringBuilder(text)
    for (attachment in attachments) {
      when (attachment) {
        is EmbeddedAttachment.Image ->
          builder.append("\n\n").append(IMAGE_MARKER).append(' ').append(attachment.sha256Hex).append("] ")
            .append(attachment.filename ?: "Photo")
        is EmbeddedAttachment.Document -> {
          val json = pjObject { string("filename", attachment.filename ?: "Document"); string("content", attachment.text) }
          builder.append(DOCUMENT_MARKER)
            .append(String(SwiftJsonWriter.encode(json, withoutEscapingSlashes = false), Charsets.UTF_8))
        }
      }
    }
    return builder.toString()
  }

  /** iOS `AutomaticMemorySourceFingerprint.make` for one user message. */
  fun memorySourceFingerprint(messageId: String, content: String): String {
    val canonical = StringBuilder()
    fun append(value: String) {
      canonical.append(value.toByteArray(Charsets.UTF_8).size).append(':').append(value)
    }
    append("mosaic-memory-source-v1")
    append("1")
    append(messageId.lowercase())
    append("user")
    append(content)
    return PortableHashes.sha256Hex(canonical.toString())
  }

  /** iOS memory-formation job key (`EmbeddingVectorCodec.fingerprint` of the job identity). */
  fun formationJobKey(promptVersion: String, conversationId: String, userMessageId: String, sourceFingerprint: String): String =
    PortableHashes.sha256Hex("$promptVersion|${conversationId.lowercase()}|${userMessageId.lowercase()}|$sourceFingerprint")

  fun evidenceKey(topicId: String, sourceMessageId: String, sourceFingerprint: String): String =
    "${topicId.lowercase()}/${sourceMessageId.lowercase()}/$sourceFingerprint"

  /** Incremental iOS compaction source fingerprint (length-prefixed id, role, status, content). */
  class CompactionFingerprinter {
    private val digest = MessageDigest.getInstance("SHA-256")

    fun add(messageId: String, role: String, content: String) {
      update(messageId.lowercase())
      update(role)
      update("complete")
      update(content)
    }

    /** Hex digest of everything added so far (the running state is kept). */
    fun current(): String =
      (digest.clone() as MessageDigest).digest().joinToString("") { "%02x".format(it) }

    private fun update(value: String) {
      val bytes = value.toByteArray(Charsets.UTF_8)
      digest.update("${bytes.size}:".toByteArray(Charsets.UTF_8))
      digest.update(bytes)
    }
  }
}

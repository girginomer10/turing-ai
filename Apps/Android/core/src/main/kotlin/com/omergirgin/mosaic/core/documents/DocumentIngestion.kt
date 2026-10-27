package com.omergirgin.mosaic.core.documents

import java.util.Locale

/** Import limits shared with iOS (`DocumentIngestor`, `DocumentImportBatchPolicy.standard`). */
object DocumentLimits {
  const val MAXIMUM_FILE_BYTES: Long = 50L * 1_024 * 1_024
  const val MAXIMUM_BATCH_BYTES: Long = 100L * 1_024 * 1_024
  const val MAXIMUM_FILES_PER_BATCH = 8
  /** Extracted characters (grapheme clusters) per document. */
  const val MAXIMUM_CHARACTERS = 3_000_000
  /** OCR budget per imported PDF; blank pages are planned first. */
  const val MAXIMUM_OCR_PAGES = 200
}

/** One chunk with its page provenance (iOS `ExtractedDocumentChunk`). */
data class ExtractedDocumentChunk(
  val index: Int,
  val content: String,
  /** 1-based PDF page; null for text and Markdown. */
  val pageNumber: Int?,
  val isOcrDerived: Boolean = false,
)

/** Selected text of one page (or the whole text file when [page] is null). */
data class DocumentSection(val page: Int?, val text: String)

/** Extraction result for one file, ready to be committed (iOS `ImportedDocumentPayload`). */
data class ImportedDocumentPayload(
  val title: String,
  val sourceFilename: String,
  val mimeType: String,
  /** SHA-256 hex of the extracted source text. */
  val contentFingerprint: String,
  val characterCount: Int,
  val pageCount: Int?,
  val chunks: List<ExtractedDocumentChunk>,
  val ocrPageCount: Int = 0,
  val ocrFallbackPageCount: Int = 0,
  /** Bytes actually read from the source file (counts toward the batch limit). */
  val sourceByteCount: Long = 0,
) {
  /**
   * Chat-attachment text in the iOS `ChatAttachmentStore` format: chunks joined by blank lines,
   * each PDF chunk prefixed with "Page N:".
   */
  fun attachmentText(): String = chunks.joinToString("\n\n") { chunk ->
    (chunk.pageNumber?.let { "Page $it:\n" } ?: "") + chunk.content
  }
}

/** User-facing ingestion failures (iOS `DocumentIngestionError`, same wording). */
sealed class DocumentIngestionException(message: String) : Exception(message) {
  class FileTooLarge(maximumBytes: Long = DocumentLimits.MAXIMUM_FILE_BYTES) : DocumentIngestionException(
    "The document is too large. Turing AI currently accepts files up to ${formatByteCount(maximumBytes)} " +
      "and 3 million extracted characters."
  )

  class UnsupportedType : DocumentIngestionException("Turing AI currently imports text, Markdown, and PDF files.")

  class Unreadable : DocumentIngestionException("Turing AI could not read this document.")

  class LockedPdf : DocumentIngestionException(
    "This PDF is password-protected. Unlock it, save an unprotected copy, and import that copy."
  )

  class NoExtractableText(isPdf: Boolean) : DocumentIngestionException(
    if (isPdf) {
      "Turing AI could not find readable text in this PDF, even after on-device OCR. Try a clearer scan or " +
        "export it as text or Markdown."
    } else {
      "This file has no readable text."
    }
  )

  class NotUtf8Text : DocumentIngestionException(
    "This file isn't UTF-8 text. Save it as UTF-8 plain text or Markdown and try again."
  )

  class OcrPageLimitExceeded(val maximumPages: Int) : DocumentIngestionException(
    "This PDF needs OCR on more than $maximumPages pages. Split the scanned PDF into smaller files and import " +
      "them separately."
  )

  class OcrFailed(val pageNumber: Int) : DocumentIngestionException(
    "On-device OCR could not process page $pageNumber. Try a clearer scan or export that page as a new PDF."
  )

  class TooLongForAttachment : DocumentIngestionException(
    "This document is too long for a chat attachment. Import it into Documents instead, so only relevant " +
      "passages are used."
  )
}

/** Batch-level rejections before any file is read (iOS `DocumentImportBatchPolicyError`). */
class DocumentImportBatchException(message: String) : Exception(message)

/**
 * Bounds one picker result before extraction starts (iOS `DocumentImportBatchPolicy`). Import is
 * sequential, so at most one expanded or OCR-derived payload is held at a time.
 */
class DocumentImportBatchPolicy(
  val maximumFileCount: Int = DocumentLimits.MAXIMUM_FILES_PER_BATCH,
  val maximumFileBytes: Long = DocumentLimits.MAXIMUM_FILE_BYTES,
  val maximumBatchBytes: Long = DocumentLimits.MAXIMUM_BATCH_BYTES,
) {
  data class SelectedFile(val name: String, val sizeBytes: Long?)

  /**
   * Validates count and reported sizes. Unlike iOS, an unknown provider size is accepted here
   * and enforced while streaming (see [remainingBudgetFor]); Android document providers may
   * omit the size column.
   */
  fun validate(files: List<SelectedFile>) {
    if (files.size > maximumFileCount) {
      throw DocumentImportBatchException("Select up to $maximumFileCount documents at a time.")
    }
    var total = 0L
    for (file in files) {
      val bytes = file.sizeBytes ?: continue
      if (bytes < 0) {
        throw DocumentImportBatchException(
          "Turing AI couldn't read a valid size for “${file.name}”. Choose another copy and try again."
        )
      }
      if (bytes > maximumFileBytes) {
        throw DocumentImportBatchException(
          "“${file.name}” is ${formatByteCount(bytes)}. Each file must be ${formatByteCount(maximumFileBytes)} or smaller."
        )
      }
      total += bytes
      if (total > maximumBatchBytes) {
        throw DocumentImportBatchException(
          "The selected documents total ${formatByteCount(total)}. Select at most ${formatByteCount(maximumBatchBytes)} at a time."
        )
      }
    }
  }

  /**
   * Read limit for one file: the per-file cap, further bounded for unknown-size files by what
   * the batch has left after known sizes and bytes already read from earlier unknown files.
   */
  fun remainingBudgetFor(file: SelectedFile, knownTotal: Long, unknownBytesRead: Long): Long =
    if (file.sizeBytes != null) maximumFileBytes
    else minOf(maximumFileBytes, (maximumBatchBytes - knownTotal - unknownBytesRead).coerceAtLeast(0))
}

/** Binary byte counts in the style of Foundation's `ByteCountFormatter(.binary)`. */
fun formatByteCount(bytes: Long): String {
  if (bytes < 1_024) return if (bytes == 1L) "1 byte" else "$bytes bytes"
  val units = arrayOf("KB", "MB", "GB", "TB")
  var value = bytes / 1_024.0
  var unit = 0
  while (value >= 1_024 && unit < units.lastIndex) {
    value /= 1_024
    unit++
  }
  val rounded = if (unit == 0) String.format(Locale.US, "%.0f", value) else String.format(Locale.US, "%.1f", value)
  return "${rounded.removeSuffix(".0")} ${units[unit]}"
}

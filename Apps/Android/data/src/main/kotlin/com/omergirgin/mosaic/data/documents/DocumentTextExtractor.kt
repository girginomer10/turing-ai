package com.omergirgin.mosaic.data.documents

import android.content.Context
import android.net.Uri
import com.omergirgin.mosaic.core.documents.DocumentIngestionException
import com.omergirgin.mosaic.core.documents.DocumentLimits
import com.omergirgin.mosaic.data.model.Attachment
import com.omergirgin.mosaic.data.model.AttachmentKind
import java.util.UUID

/** Text extracted on-device from one PDF, Markdown or plain-text file. */
data class ExtractedDocumentText(
  val fileName: String,
  /** File name without its extension. */
  val title: String,
  val mimeType: String,
  /**
   * Chunked text in the iOS chat-attachment format: chunks separated by blank lines, PDF chunks
   * prefixed with "Page N:". Consecutive chunks overlap by up to 180 characters, as on iOS.
   */
  val text: String,
  /** Extracted characters before chunking (grapheme clusters). */
  val characterCount: Int,
  /** null for text and Markdown. */
  val pageCount: Int?,
  val ocrPageCount: Int,
  val ocrFallbackPageCount: Int,
  /** SHA-256 hex of the extracted source text. */
  val contentFingerprint: String,
) {
  val isPdf: Boolean get() = pageCount != null
}

/**
 * Reusable on-device extractor (same pipeline as document import: PDF text layer, OCR for blank,
 * scanned or weak pages, UTF-8 text validation). Failures throw [DocumentIngestionException]
 * with a user-facing message; cancellation of the calling coroutine stops reading, page
 * preparation and OCR. Never logs document content.
 */
object DocumentTextExtractor {
  /** iOS caps chat-attachment text at 800,000 UTF-8 bytes and suggests importing instead. */
  const val CHAT_ATTACHMENT_TEXT_BYTES = 800_000

  /** Fails with [DocumentIngestionException] for unsupported, unreadable, locked or too-large files. */
  suspend fun extract(
    context: Context,
    uri: Uri,
    maxBytes: Long = DocumentLimits.MAXIMUM_FILE_BYTES,
    /** Stage plus step/stepCount (PDF page, or OCR ordinal/total); called off the main thread. */
    onProgress: ((stage: DocumentImportStage, step: Int?, stepCount: Int?) -> Unit)? = null,
  ): ExtractedDocumentText {
    val source = DocumentSource.describe(context.contentResolver, uri)
    val payload = DocumentReader(context).read(source, maxBytes) { stage, step, stepCount, _ ->
      onProgress?.invoke(stage, step, stepCount)
    }
    return ExtractedDocumentText(
      fileName = payload.sourceFilename,
      title = payload.title,
      mimeType = payload.mimeType,
      text = payload.attachmentText(),
      characterCount = payload.characterCount,
      pageCount = payload.pageCount,
      ocrPageCount = payload.ocrPageCount,
      ocrFallbackPageCount = payload.ocrFallbackPageCount,
      contentFingerprint = payload.contentFingerprint,
    )
  }

  /**
   * Ready-to-send chat attachment (iOS `ChatAttachmentStore.importFile` for documents): PDFs
   * become [AttachmentKind.PDF], text and Markdown [AttachmentKind.TEXT], both carrying the
   * extracted text. Text over [CHAT_ATTACHMENT_TEXT_BYTES] fails with
   * [DocumentIngestionException.TooLongForAttachment].
   */
  suspend fun chatAttachment(
    context: Context,
    uri: Uri,
    onProgress: ((stage: DocumentImportStage, step: Int?, stepCount: Int?) -> Unit)? = null,
  ): Attachment {
    val extracted = extract(context, uri, onProgress = onProgress)
    if (extracted.text.toByteArray(Charsets.UTF_8).size > CHAT_ATTACHMENT_TEXT_BYTES) {
      throw DocumentIngestionException.TooLongForAttachment()
    }
    return Attachment(
      id = UUID.randomUUID().toString(),
      kind = if (extracted.isPdf) AttachmentKind.PDF else AttachmentKind.TEXT,
      fileName = extracted.fileName.take(200),
      mimeType = extracted.mimeType,
      extractedText = extracted.text,
    )
  }
}

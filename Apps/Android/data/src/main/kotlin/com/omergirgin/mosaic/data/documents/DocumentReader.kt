package com.omergirgin.mosaic.data.documents

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import com.omergirgin.mosaic.core.documents.DocumentIngestionException
import com.omergirgin.mosaic.core.documents.DocumentPayloads
import com.omergirgin.mosaic.core.documents.ImportedDocumentPayload
import com.omergirgin.mosaic.core.documents.PdfTextExtraction
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** Picked document metadata from the Storage Access Framework. */
internal data class DocumentSource(
  val uri: Uri,
  val displayName: String,
  /** null when the provider does not report a size; enforced while streaming instead. */
  val sizeBytes: Long?,
  val mimeType: String?,
) {
  companion object {
    fun describe(resolver: ContentResolver, uri: Uri): DocumentSource {
      var name: String? = null
      var size: Long? = null
      runCatching {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
          if (cursor.moveToFirst()) {
            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (nameIndex >= 0 && !cursor.isNull(nameIndex)) name = cursor.getString(nameIndex)
            if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
          }
        }
      }
      val fallbackName = uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: "Document"
      return DocumentSource(
        uri = uri,
        displayName = (name?.takeIf { it.isNotBlank() } ?: fallbackName).take(MAX_NAME_LENGTH),
        sizeBytes = size,
        mimeType = runCatching { resolver.getType(uri) }.getOrNull(),
      )
    }

    private const val MAX_NAME_LENGTH = 255
  }
}

internal enum class DocumentKind { PDF, TEXT }

/** Progress callback from inside one file's extraction. */
internal fun interface ExtractionProgress {
  fun report(stage: DocumentImportStage, step: Int?, stepCount: Int?, pageNumber: Int?)
}

/**
 * Reads one picked document into a commit-ready payload (iOS `DocumentIngestor.importDocument`).
 * PDFs are streamed into a private temporary file (never shared storage) so PdfBox and
 * PdfRenderer get a seekable source and the size limit holds even when the provider omits the
 * size; the copy is deleted before returning. Cancellation is checked between buffers, pages,
 * OCR requests and chunks.
 */
internal class DocumentReader(context: Context) {
  private val appContext = context.applicationContext
  private val resolver = appContext.contentResolver

  suspend fun read(source: DocumentSource, maxBytes: Long, progress: ExtractionProgress): ImportedDocumentPayload =
    withContext(Dispatchers.IO) {
      ensureActive()
      if (source.sizeBytes != null && source.sizeBytes > maxBytes) throw DocumentIngestionException.FileTooLarge(maxBytes)
      when (kindOf(source)) {
        DocumentKind.PDF -> readPdf(source, maxBytes, progress)
        DocumentKind.TEXT -> readText(source, maxBytes, progress)
        null -> throw DocumentIngestionException.UnsupportedType()
      }
    }

  private suspend fun readText(source: DocumentSource, maxBytes: Long, progress: ExtractionProgress): ImportedDocumentPayload {
    progress.report(DocumentImportStage.READING_FILE, null, null, null)
    val job = currentCoroutineContext()[Job]
    val bytes = try {
      openInput(source).use { input ->
        val out = ByteArrayOutputStream(source.sizeBytes?.coerceIn(0, maxBytes)?.toInt() ?: DEFAULT_BUFFER)
        copyBounded(input, out, maxBytes, job)
        out.toByteArray()
      }
    } catch (_: OutOfMemoryError) {
      throw DocumentIngestionException.FileTooLarge(maxBytes)
    }
    progress.report(DocumentImportStage.EXTRACTING_TEXT, null, null, null)
    val text = try {
      DocumentPayloads.decodeText(bytes)
    } catch (_: OutOfMemoryError) {
      throw DocumentIngestionException.FileTooLarge(maxBytes)
    }
    currentCoroutineContext().ensureActive()
    progress.report(DocumentImportStage.PREPARING_CHUNKS, null, null, null)
    return DocumentPayloads.textPayload(
      fileName = source.displayName,
      mimeType = textMimeType(source),
      text = text,
      sourceByteCount = bytes.size.toLong(),
      checkCancellation = { job?.ensureActive() },
    )
  }

  private suspend fun readPdf(source: DocumentSource, maxBytes: Long, progress: ExtractionProgress): ImportedDocumentPayload {
    progress.report(DocumentImportStage.READING_FILE, null, null, null)
    val job = currentCoroutineContext()[Job]
    val directory = DocumentScratch.directory(appContext)
    val file = File.createTempFile("import-", ".pdf", directory)
    try {
      val byteCount = openInput(source).use { input ->
        file.outputStream().use { output -> copyBounded(input, output, maxBytes, job) }
      }
      currentCoroutineContext().ensureActive()

      val embedded = PdfEmbeddedText.read(appContext, file, directory, job) { page, pages ->
        progress.report(DocumentImportStage.EXTRACTING_TEXT, page, pages, page)
      }
      currentCoroutineContext().ensureActive()

      PdfPageRecognizer(file).use { recognizer ->
        val pageTexts = embedded ?: List(recognizer.pageCount()) { "" }
        if (pageTexts.isEmpty()) throw DocumentIngestionException.NoExtractableText(isPdf = true)
        val extraction = PdfTextExtraction.extract(
          embeddedTexts = pageTexts,
          onOcrPage = { ordinal, total, pageNumber ->
            progress.report(DocumentImportStage.RECOGNIZING_TEXT, ordinal, total, pageNumber)
          },
          recognizeText = { pageIndex -> recognizer.recognize(pageIndex) },
        )
        progress.report(DocumentImportStage.PREPARING_CHUNKS, null, null, null)
        return DocumentPayloads.pdfPayload(
          fileName = source.displayName,
          extraction = extraction,
          pageCount = pageTexts.size,
          sourceByteCount = byteCount,
          checkCancellation = { job?.ensureActive() },
        )
      }
    } finally {
      file.delete()
    }
  }

  private fun openInput(source: DocumentSource): InputStream =
    try {
      resolver.openInputStream(source.uri)
    } catch (_: SecurityException) {
      null
    } catch (_: IOException) {
      null
    } ?: throw DocumentIngestionException.Unreadable()

  companion object {
    private const val DEFAULT_BUFFER = 64 * 1_024
    private val TEXT_EXTENSIONS = setOf("txt", "text", "md", "markdown")
    private val MARKDOWN_EXTENSIONS = setOf("md", "markdown")

    fun kindOf(source: DocumentSource): DocumentKind? {
      val extension = source.displayName.substringAfterLast('.', "").lowercase(Locale.ROOT)
      val mime = source.mimeType?.lowercase(Locale.ROOT)
      return when {
        mime == DocumentPayloads.PDF_MIME_TYPE || extension == "pdf" -> DocumentKind.PDF
        mime?.startsWith("text/") == true || extension in TEXT_EXTENSIONS -> DocumentKind.TEXT
        else -> null
      }
    }

    fun textMimeType(source: DocumentSource): String {
      val extension = source.displayName.substringAfterLast('.', "").lowercase(Locale.ROOT)
      val mime = source.mimeType?.lowercase(Locale.ROOT)
      return when {
        extension in MARKDOWN_EXTENSIONS -> "text/markdown"
        mime != null && mime.startsWith("text/") -> mime
        else -> "text/plain"
      }
    }

    /** Copies at most [maxBytes]; one byte more fails with the file-size error. */
    fun copyBounded(input: InputStream, output: OutputStream, maxBytes: Long, job: Job?): Long {
      val buffer = ByteArray(DEFAULT_BUFFER)
      var total = 0L
      while (true) {
        job?.ensureActive()
        val read = input.read(buffer)
        if (read < 0) break
        total += read
        if (total > maxBytes) throw DocumentIngestionException.FileTooLarge(maxBytes)
        output.write(buffer, 0, read)
      }
      return total
    }
  }
}

/** Private scratch space for PDF copies and PdfBox buffers (app cache, never shared storage). */
internal object DocumentScratch {
  private const val DIRECTORY = "document-import"
  private const val STALE_AFTER_MILLIS = 60L * 60 * 1_000

  fun directory(context: Context): File {
    val directory = File(context.cacheDir, DIRECTORY)
    if (!directory.isDirectory) directory.mkdirs()
    // Leftovers from a crashed import; recent files may belong to a concurrent extraction.
    val cutoff = System.currentTimeMillis() - STALE_AFTER_MILLIS
    directory.listFiles()?.forEach { if (it.lastModified() < cutoff) it.delete() }
    return directory
  }
}

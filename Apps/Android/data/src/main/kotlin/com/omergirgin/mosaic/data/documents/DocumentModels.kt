package com.omergirgin.mosaic.data.documents

import com.omergirgin.mosaic.core.documents.DocumentPayloads

/** Library snapshot of one imported document (no chunk bodies). */
data class DocumentSummary(
  val id: String,
  val title: String,
  val sourceFilename: String,
  val mimeType: String,
  val characterCount: Int,
  /** null for text and Markdown. */
  val pageCount: Int?,
  val chunkCount: Int,
  /** Pages whose stored text came from on-device OCR. */
  val ocrPageCount: Int,
  /** Weak-text pages beyond the OCR budget that kept their embedded text. */
  val ocrFallbackPageCount: Int,
  val isEnabled: Boolean,
  /** null = available everywhere; otherwise only in that project. */
  val projectId: String?,
  val projectName: String?,
  val isProjectArchived: Boolean,
  val createdAt: Long,
  val updatedAt: Long,
) {
  val isPdf: Boolean get() = mimeType == DocumentPayloads.PDF_MIME_TYPE
}

/** Read-only preview of one stored chunk. */
data class DocumentChunkPreview(
  val index: Int,
  val content: String,
  val pageNumber: Int?,
  val isOcrDerived: Boolean,
)

data class DocumentImportFailure(val fileName: String, val message: String)

/** Cumulative result of one import batch; every progress event carries the current tally. */
data class DocumentImportTally(
  val importedDocumentIds: List<String> = emptyList(),
  val duplicateCount: Int = 0,
  val ocrPageCount: Int = 0,
  val ocrFallbackPageCount: Int = 0,
  val failures: List<DocumentImportFailure> = emptyList(),
) {
  val importedCount: Int get() = importedDocumentIds.size
}

enum class DocumentImportStage { READING_FILE, EXTRACTING_TEXT, RECOGNIZING_TEXT, PREPARING_CHUNKS, SAVING }

sealed interface DocumentImportProgress {
  val tally: DocumentImportTally

  /** Checking the batch limits and the target project. */
  data class Checking(override val tally: DocumentImportTally = DocumentImportTally()) : DocumentImportProgress

  data class Working(
    /** 0-based position in the batch. */
    val fileIndex: Int,
    val fileCount: Int,
    val fileName: String,
    val stage: DocumentImportStage,
    /** For RECOGNIZING_TEXT: OCR ordinal and planned OCR page total; for EXTRACTING_TEXT: page/pages. */
    val step: Int? = null,
    val stepCount: Int? = null,
    /** 1-based PDF page being recognized. */
    val pageNumber: Int? = null,
    override val tally: DocumentImportTally,
  ) : DocumentImportProgress

  data class Finished(override val tally: DocumentImportTally) : DocumentImportProgress
}

/** Called after a document's source rows are deleted (retrieval drops derived vectors here). */
fun interface DocumentDeletionListener {
  suspend fun onDocumentDeleted(deletion: DocumentDeletion)
}

data class DocumentDeletion(val documentId: String, val chunkIds: Set<String>)

/** Called after an import batch commits at least one document (retrieval can backfill vectors). */
fun interface DocumentImportListener {
  suspend fun onDocumentsImported(documentIds: Set<String>)
}

/**
 * User-facing batch summaries in the iOS wording. [projectName] is the import target (null =
 * Everywhere); [stopped] = the user pressed Stop.
 */
object DocumentImportSummary {
  fun describe(tally: DocumentImportTally, projectName: String?, stopped: Boolean): String {
    val imported = tally.importedCount
    val parts = ArrayList<String>()
    if (stopped) {
      parts += if (imported == 0) {
        "Document import stopped."
      } else {
        "Stopped after importing ${documents(imported)}. Their text is available for recall."
      }
    } else if (imported > 0) {
      parts += "Imported ${documents(imported)}."
      parts += if (projectName != null) "Available only in $projectName." else "Available everywhere."
    }
    if (tally.duplicateCount > 0) {
      parts += "Skipped ${tally.duplicateCount} duplicate ${if (tally.duplicateCount == 1) "file" else "files"}."
    }
    if (tally.ocrPageCount > 0) {
      parts += "Read ${tally.ocrPageCount} scanned ${pages(tally.ocrPageCount)} with on-device OCR."
    }
    if (tally.ocrFallbackPageCount > 0) {
      parts += "Used existing embedded text on ${tally.ocrFallbackPageCount} short " +
        "${pages(tally.ocrFallbackPageCount)} after the OCR safety limit."
    }
    if (tally.failures.isNotEmpty()) {
      parts += "Could not import: " + tally.failures.joinToString("; ") { "${it.fileName}: ${it.message}" }
    }
    return if (parts.isEmpty()) "No documents were selected." else parts.joinToString(" ")
  }

  private fun documents(count: Int) = if (count == 1) "1 document" else "$count documents"

  private fun pages(count: Int) = if (count == 1) "page" else "pages"
}

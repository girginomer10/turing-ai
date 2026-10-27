package com.omergirgin.mosaic.data.documents

import android.content.Context
import android.database.SQLException
import android.net.Uri
import android.util.Log
import androidx.room.withTransaction
import com.omergirgin.mosaic.core.documents.DocumentImportBatchException
import com.omergirgin.mosaic.core.documents.DocumentImportBatchPolicy
import com.omergirgin.mosaic.core.documents.DocumentIngestionException
import com.omergirgin.mosaic.core.documents.ImportedDocumentPayload
import com.omergirgin.mosaic.data.api.DocumentRepository
import com.omergirgin.mosaic.data.db.DocumentChunkEntity
import com.omergirgin.mosaic.data.db.DocumentEntity
import com.omergirgin.mosaic.data.db.DocumentRow
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.internal.FieldLimits
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.internal.newId
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Imported documents (iOS `ImportedDocumentRecord` + `DocumentChunkRecord`). Import is
 * sequential extract-and-commit: each file is read, extracted, chunked and committed in its own
 * transaction before the next file is opened, so cancelling keeps every committed document and
 * at most one expanded payload is held in memory.
 */
internal class DocumentRepositoryImpl(
  context: Context,
  private val db: MosaicDatabase,
  /** Application scope for listener callbacks that must outlive the screen. */
  private val scope: CoroutineScope,
  /** True while a chat request is running; availability changes and deletes wait for it (iOS parity). */
  private val isChatBusy: () -> Boolean,
) : DocumentRepository {
  private val appContext = context.applicationContext
  private val dao = db.documents()
  private val reader = DocumentReader(appContext)
  private val importRunning = AtomicBoolean(false)
  private val deletionListeners = CopyOnWriteArrayList<DocumentDeletionListener>()
  private val importListeners = CopyOnWriteArrayList<DocumentImportListener>()

  override fun observeDocuments(): Flow<List<DocumentSummary>> =
    dao.observeAll().map { rows -> rows.map { it.toSummary() } }.distinctUntilChanged()

  override fun observeDocument(id: String): Flow<DocumentSummary?> =
    dao.observe(id).map { it?.toSummary() }.distinctUntilChanged()

  override suspend fun previewChunks(id: String, limit: Int): List<DocumentChunkPreview> =
    dao.firstChunks(id, limit.coerceIn(1, MAX_PREVIEW_CHUNKS)).map {
      DocumentChunkPreview(it.chunkIndex, it.content, it.pageNumber, it.isOcrDerived)
    }

  override fun importDocuments(uris: List<Uri>, projectId: String?): Flow<DocumentImportProgress> = channelFlow {
    if (!importRunning.compareAndSet(false, true)) {
      throw IllegalStateException("Another document import is already running.")
    }
    var tally = DocumentImportTally()
    try {
      send(DocumentImportProgress.Checking(tally))
      val policy = DocumentImportBatchPolicy()
      if (uris.size > policy.maximumFileCount) {
        throw DocumentImportBatchException("Select up to ${policy.maximumFileCount} documents at a time.")
      }
      if (projectId != null) requireAvailableProject(projectId)
      val sources = uris.map { uri ->
        ensureActive()
        DocumentSource.describe(appContext.contentResolver, uri)
      }
      val selected = sources.map { DocumentImportBatchPolicy.SelectedFile(it.displayName, it.sizeBytes) }
      policy.validate(selected)
      val knownTotal = sources.sumOf { it.sizeBytes ?: 0L }
      var unknownBytesRead = 0L
      val batchFingerprints = HashSet<String>()

      for ((index, source) in sources.withIndex()) {
        ensureActive()
        fun working(stage: DocumentImportStage, step: Int? = null, stepCount: Int? = null, page: Int? = null) =
          DocumentImportProgress.Working(index, sources.size, source.displayName, stage, step, stepCount, page, tally)

        send(working(DocumentImportStage.READING_FILE))
        val budget = policy.remainingBudgetFor(selected[index], knownTotal, unknownBytesRead)
        val payload: ImportedDocumentPayload = try {
          reader.read(source, budget) { stage, step, stepCount, page -> trySend(working(stage, step, stepCount, page)) }
        } catch (cancellation: CancellationException) {
          throw cancellation
        } catch (error: Exception) {
          tally = tally.copy(failures = tally.failures + DocumentImportFailure(source.displayName, describe(error)))
          continue
        } catch (_: OutOfMemoryError) {
          tally = tally.copy(
            failures = tally.failures + DocumentImportFailure(source.displayName, DocumentIngestionException.FileTooLarge().message.orEmpty())
          )
          continue
        }
        if (source.sizeBytes == null) unknownBytesRead += payload.sourceByteCount
        ensureActive()

        if (!batchFingerprints.add(payload.contentFingerprint) || dao.existsWithFingerprint(payload.contentFingerprint)) {
          tally = tally.copy(duplicateCount = tally.duplicateCount + 1)
          continue
        }
        send(working(DocumentImportStage.SAVING))
        ensureActive()
        // Past this point the commit either happens completely or not at all; the tally must
        // reflect it even if Stop arrives while the transaction runs.
        val documentId = withContext(NonCancellable) { commit(payload, projectId) }
        tally = tally.copy(
          importedDocumentIds = tally.importedDocumentIds + documentId,
          ocrPageCount = tally.ocrPageCount + payload.ocrPageCount,
          ocrFallbackPageCount = tally.ocrFallbackPageCount + payload.ocrFallbackPageCount,
        )
        ensureActive()
      }
      send(DocumentImportProgress.Finished(tally))
    } finally {
      importRunning.set(false)
      val imported = tally.importedDocumentIds.toSet()
      if (imported.isNotEmpty()) notifyImported(imported)
    }
  }.conflate().flowOn(Dispatchers.IO)

  override suspend fun rename(id: String, title: String) {
    val trimmed = title.trim()
    require(trimmed.isNotEmpty()) { "Enter a document name." }
    FieldLimits.requireWithin(trimmed, TITLE_BYTES, "The document name")
    check(dao.rename(id, trimmed, MonotonicClock.now()) > 0) { MISSING_MESSAGE }
  }

  override suspend fun setEnabled(id: String, enabled: Boolean) {
    check(dao.setEnabled(id, enabled, MonotonicClock.now()) > 0) { MISSING_MESSAGE }
  }

  override suspend fun moveToProject(id: String, projectId: String?) {
    check(!importRunning.get() && !isChatBusy()) {
      "Finish active requests and data operations before changing availability."
    }
    db.withTransaction {
      val document = dao.get(id) ?: throw IllegalStateException(MISSING_MESSAGE)
      if (document.projectId == projectId) return@withTransaction
      if (projectId != null) requireAvailableProject(projectId)
      dao.setProject(id, projectId, MonotonicClock.now())
    }
  }

  override suspend fun delete(id: String) {
    check(!importRunning.get() && !isChatBusy()) {
      "Finish active requests and imports before deleting this document."
    }
    val chunkIds = withContext(NonCancellable) {
      db.withTransaction {
        val ids = dao.chunkIds(id)
        // Chunks also cascade; deleting them explicitly keeps this independent of FK pragmas.
        dao.deleteChunks(id)
        if (dao.delete(id) > 0) ids.toSet() else null
      }
    } ?: return
    val deletion = DocumentDeletion(id, chunkIds)
    for (listener in deletionListeners) {
      scope.launch {
        try {
          listener.onDocumentDeleted(deletion)
        } catch (cancellation: CancellationException) {
          throw cancellation
        } catch (error: Exception) {
          Log.w(TAG, "Document deletion listener failed (${error.javaClass.simpleName}).")
        }
      }
    }
  }

  override fun addDeletionListener(listener: DocumentDeletionListener) {
    deletionListeners.addIfAbsent(listener)
  }

  override fun addImportListener(listener: DocumentImportListener) {
    importListeners.addIfAbsent(listener)
  }

  private fun notifyImported(documentIds: Set<String>) {
    for (listener in importListeners) {
      scope.launch {
        try {
          listener.onDocumentsImported(documentIds)
        } catch (cancellation: CancellationException) {
          throw cancellation
        } catch (error: Exception) {
          Log.w(TAG, "Document import listener failed (${error.javaClass.simpleName}).")
        }
      }
    }
  }

  private suspend fun requireAvailableProject(projectId: String) {
    val project = db.projects().get(projectId)
    check(project != null && !project.isArchived) {
      "This project is no longer available. Choose another project or make the document available everywhere."
    }
  }

  private suspend fun commit(payload: ImportedDocumentPayload, projectId: String?): String = db.withTransaction {
    if (projectId != null) requireAvailableProject(projectId)
    val now = MonotonicClock.now()
    val documentId = newId()
    dao.insert(
      DocumentEntity(
        id = documentId,
        title = payload.title,
        sourceFilename = payload.sourceFilename,
        mimeType = payload.mimeType,
        contentFingerprint = payload.contentFingerprint,
        characterCount = payload.characterCount,
        pageCount = payload.pageCount,
        ocrPageCount = payload.ocrPageCount,
        ocrFallbackPageCount = payload.ocrFallbackPageCount,
        isEnabled = true,
        projectId = projectId,
        createdAt = now,
        updatedAt = now,
      )
    )
    payload.chunks.chunked(INSERT_BATCH).forEach { batch ->
      dao.insertChunks(
        batch.map { chunk ->
          DocumentChunkEntity(
            id = newId(),
            documentId = documentId,
            chunkIndex = chunk.index,
            content = chunk.content,
            pageNumber = chunk.pageNumber,
            isOcrDerived = chunk.isOcrDerived,
            createdAt = now,
          )
        }
      )
    }
    documentId
  }

  private fun describe(error: Exception): String = when (error) {
    is DocumentIngestionException, is DocumentImportBatchException -> error.message.orEmpty()
    is SQLException -> "Turing AI couldn't save this document on the device."
    is SecurityException -> "Turing AI no longer has permission to read this file. Choose it again."
    else -> DocumentIngestionException.Unreadable().message.orEmpty()
  }

  private fun DocumentRow.toSummary() = DocumentSummary(
    id = document.id,
    title = document.title,
    sourceFilename = document.sourceFilename,
    mimeType = document.mimeType,
    characterCount = document.characterCount,
    pageCount = document.pageCount,
    chunkCount = chunkCount,
    ocrPageCount = document.ocrPageCount,
    ocrFallbackPageCount = document.ocrFallbackPageCount,
    isEnabled = document.isEnabled,
    projectId = document.projectId,
    projectName = projectName,
    isProjectArchived = projectIsArchived == true,
    createdAt = document.createdAt,
    updatedAt = document.updatedAt,
  )

  private companion object {
    const val TAG = "TuringDocuments"
    const val TITLE_BYTES = 4 * 1_024
    const val MAX_PREVIEW_CHUNKS = 50
    const val INSERT_BATCH = 256
    const val MISSING_MESSAGE = "This document no longer exists."
  }
}

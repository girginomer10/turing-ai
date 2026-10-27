package com.omergirgin.mosaic.ui.documents

import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.omergirgin.mosaic.data.api.DocumentRepository
import com.omergirgin.mosaic.data.documents.DocumentImportProgress
import com.omergirgin.mosaic.data.documents.DocumentImportSummary
import com.omergirgin.mosaic.data.documents.DocumentImportTally
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** One import batch as the progress sheet shows it. */
internal data class ImportSheetState(
  val progress: DocumentImportProgress = DocumentImportProgress.Checking(),
  val isStopping: Boolean = false,
  /** Set when the batch has ended (finished, stopped or failed). */
  val resultMessage: String? = null,
  val isError: Boolean = false,
) {
  val isRunning: Boolean get() = resultMessage == null
}

/**
 * Runs imports in the ViewModel scope so rotation keeps the batch alive; leaving the Documents
 * screen ends the scope, which stops the batch exactly like Stop (committed documents remain).
 */
internal class DocumentsViewModel(private val documents: DocumentRepository) : ViewModel() {
  var sheet by mutableStateOf<ImportSheetState?>(null)
    private set

  /** Last batch summary, kept above the list after the sheet closes (iOS import status line). */
  var statusMessage by mutableStateOf<String?>(null)
    private set

  private var job: Job? = null

  fun startImport(uris: List<Uri>, projectId: String?, projectName: String?) {
    if (uris.isEmpty() || job?.isActive == true) return
    sheet = ImportSheetState()
    statusMessage = null
    job = viewModelScope.launch {
      var tally = DocumentImportTally()
      try {
        documents.importDocuments(uris, projectId).collect { progress ->
          tally = progress.tally
          sheet = sheet?.copy(progress = progress)
        }
        finish(DocumentImportSummary.describe(tally, projectName, stopped = false), isError = tally.importedCount == 0 && tally.failures.isNotEmpty())
      } catch (cancellation: CancellationException) {
        finish(DocumentImportSummary.describe(tally, projectName, stopped = true), isError = false)
        throw cancellation
      } catch (error: Exception) {
        val reason = error.message?.takeIf { it.isNotBlank() } ?: "The import couldn't be completed. Please try again."
        val message = if (tally.importedCount == 0) {
          reason
        } else {
          val count = if (tally.importedCount == 1) "1 document" else "${tally.importedCount} documents"
          "Imported $count before the import stopped. $reason"
        }
        finish(message, isError = true)
      }
    }
  }

  fun stop() {
    val current = sheet ?: return
    if (!current.isRunning || current.isStopping) return
    sheet = current.copy(isStopping = true)
    job?.cancel()
  }

  fun dismissSheet() {
    if (sheet?.isRunning == true) return
    sheet = null
  }

  fun clearStatus() {
    statusMessage = null
  }

  /** Short-lived notice for library actions (availability changes). */
  fun showStatus(message: String) {
    statusMessage = message
  }

  private fun finish(message: String, isError: Boolean) {
    sheet = (sheet ?: ImportSheetState()).copy(resultMessage = message, isError = isError, isStopping = false)
    statusMessage = message
  }
}

package com.omergirgin.mosaic.ui.documents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.omergirgin.mosaic.data.documents.DocumentImportProgress
import com.omergirgin.mosaic.data.documents.DocumentImportStage
import com.omergirgin.mosaic.ui.settings.pluralize

/**
 * Modal progress for one import batch. While it runs the sheet can't be swiped away; the only
 * way out is Stop, which keeps every document committed so far.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ImportProgressSheet(state: ImportSheetState, onStop: () -> Unit, onDismiss: () -> Unit) {
  val running by rememberUpdatedState(state.isRunning)
  val sheetState = rememberModalBottomSheetState(
    skipPartiallyExpanded = true,
    confirmValueChange = { value -> value != SheetValue.Hidden || !running },
  )
  ModalBottomSheet(
    onDismissRequest = { if (!state.isRunning) onDismiss() },
    sheetState = sheetState,
  ) {
    Column(
      verticalArrangement = Arrangement.spacedBy(16.dp),
      modifier = Modifier
        .fillMaxWidth()
        .verticalScroll(rememberScrollState())
        .navigationBarsPadding()
        .padding(start = 24.dp, end = 24.dp, bottom = 24.dp),
    ) {
      val result = state.resultMessage
      Text(
        when {
          result != null -> if (state.isError) "Import didn't finish" else "Import finished"
          state.isStopping -> "Stopping import…"
          else -> "Importing documents"
        },
        style = MaterialTheme.typography.titleLarge,
        modifier = Modifier.semantics { heading() },
      )

      if (result == null) {
        val (headline, detail, fraction) = describe(state.progress)
        Column(
          verticalArrangement = Arrangement.spacedBy(6.dp),
          modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        ) {
          Text(headline, style = MaterialTheme.typography.bodyLarge)
          detail?.let {
            Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
          }
        }
        if (fraction == null) {
          LinearProgressIndicator(Modifier.fillMaxWidth())
        } else {
          LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth())
        }
        tallyLine(state.progress)?.let {
          Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(
          "Text is extracted on this device. Stopping keeps documents that were already imported.",
          style = MaterialTheme.typography.bodySmall,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        OutlinedButton(
          onClick = onStop,
          enabled = !state.isStopping,
          modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        ) {
          Icon(Icons.Outlined.Stop, contentDescription = null)
          Spacer(Modifier.width(8.dp))
          Text(if (state.isStopping) "Stopping…" else "Stop")
        }
      } else {
        Text(
          result,
          style = MaterialTheme.typography.bodyMedium,
          color = if (state.isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
          modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        )
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
          Button(onClick = onDismiss, modifier = Modifier.heightIn(min = 48.dp)) { Text("Done") }
        }
      }
    }
  }
}

private data class ProgressText(val headline: String, val detail: String?, val fraction: Float?)

private fun describe(progress: DocumentImportProgress): ProgressText = when (progress) {
  is DocumentImportProgress.Checking -> ProgressText("Checking selected documents…", null, null)
  is DocumentImportProgress.Finished -> ProgressText("Finishing…", null, 1f)
  is DocumentImportProgress.Working -> {
    val headline = "Reading document ${progress.fileIndex + 1} of ${progress.fileCount}…"
    val step = progress.step
    val stepCount = progress.stepCount
    val stage = when (progress.stage) {
      DocumentImportStage.READING_FILE -> "Opening the file"
      DocumentImportStage.EXTRACTING_TEXT ->
        if (step != null && stepCount != null) "Reading the text layer, page $step of $stepCount" else "Reading text"
      DocumentImportStage.RECOGNIZING_TEXT -> {
        val page = progress.pageNumber?.let { " (page $it)" }.orEmpty()
        if (step != null && stepCount != null) "On-device OCR $step of $stepCount$page" else "On-device OCR$page"
      }
      DocumentImportStage.PREPARING_CHUNKS -> "Preparing passages for recall"
      DocumentImportStage.SAVING -> "Saving"
    }
    // Whole files done plus the fraction of OCR inside the current file.
    val within = if (progress.stage == DocumentImportStage.RECOGNIZING_TEXT && step != null && stepCount != null && stepCount > 0) {
      (step - 1).toFloat() / stepCount
    } else 0f
    ProgressText(
      headline = headline,
      detail = "${progress.fileName}\n$stage",
      fraction = ((progress.fileIndex + within) / progress.fileCount.coerceAtLeast(1)).coerceIn(0f, 1f),
    )
  }
}

private fun tallyLine(progress: DocumentImportProgress): String? {
  val tally = progress.tally
  val parts = ArrayList<String>()
  if (tally.importedCount > 0) parts += "${pluralize(tally.importedCount, "document")} imported"
  if (tally.duplicateCount > 0) parts += "${pluralize(tally.duplicateCount, "duplicate")} skipped"
  if (tally.failures.isNotEmpty()) parts += "${pluralize(tally.failures.size, "file")} couldn't be imported"
  return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

package com.omergirgin.mosaic.ui.backup

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.HourglassEmpty
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.PauseCircle
import androidx.compose.material.icons.outlined.PowerSettingsNew
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material.icons.outlined.Upload
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.omergirgin.mosaic.data.backup.BackupContents
import com.omergirgin.mosaic.data.backup.BackupProgress
import com.omergirgin.mosaic.data.backup.LibraryBackupRepository
import com.omergirgin.mosaic.data.backup.PreparedBackup
import com.omergirgin.mosaic.data.backup.RestorePreview
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.ConfirmDialog
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import com.omergirgin.mosaic.ui.settings.StatusLine
import com.omergirgin.mosaic.ui.settings.StatusTone
import com.omergirgin.mosaic.ui.settings.formatCount
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** What the screen is doing; only one backup or restore step runs at a time. */
internal sealed interface DataRecoveryPhase {
  data object Idle : DataRecoveryPhase
  data class PreparingBackup(val progress: BackupProgress?) : DataRecoveryPhase
  /** A verified backup waits for the user to choose where to save it. */
  data class ChoosingDestination(val prepared: PreparedBackup) : DataRecoveryPhase
  data object SavingBackup : DataRecoveryPhase
  data class CheckingRestore(val progress: BackupProgress?) : DataRecoveryPhase
  data class ReviewingRestore(val preview: RestorePreview) : DataRecoveryPhase
  data class Restoring(val progress: BackupProgress?) : DataRecoveryPhase
}

internal class DataRecoveryViewModel(private val backup: LibraryBackupRepository) : ViewModel() {
  private val _phase = MutableStateFlow<DataRecoveryPhase>(DataRecoveryPhase.Idle)
  val phase: StateFlow<DataRecoveryPhase> = _phase.asStateFlow()

  private val _error = MutableStateFlow<String?>(null)
  val error: StateFlow<String?> = _error.asStateFlow()

  /** Details of the last completed operation (what was left out, consequences). */
  private val _lastNotes = MutableStateFlow<List<String>>(emptyList())
  val lastNotes: StateFlow<List<String>> = _lastNotes.asStateFlow()

  private val _busyReason = MutableStateFlow<String?>(null)
  val busyReason: StateFlow<String?> = _busyReason.asStateFlow()

  val lastResult: StateFlow<String?> = backup.lastResult

  private var job: Job? = null

  init {
    // Provider work can start or finish while the screen is open; keep the notice current.
    viewModelScope.launch {
      while (isActive) {
        _busyReason.value = runCatching { backup.busyReason() }.getOrNull()
        delay(BUSY_POLL_MILLIS)
      }
    }
  }

  val isWorking: Boolean
    get() = _phase.value !is DataRecoveryPhase.Idle

  fun createBackup() {
    if (isWorking) return
    _phase.value = DataRecoveryPhase.PreparingBackup(null)
    job = viewModelScope.launch {
      try {
        val prepared = backup.prepareExport { progress -> _phase.value = DataRecoveryPhase.PreparingBackup(progress) }
        _phase.value = DataRecoveryPhase.ChoosingDestination(prepared)
      } catch (cancelled: CancellationException) {
        _phase.value = DataRecoveryPhase.Idle
        throw cancelled
      } catch (failure: Throwable) {
        _phase.value = DataRecoveryPhase.Idle
        _error.value = failure.message ?: "Turing AI could not create the backup."
      }
    }
  }

  fun destinationChosen(prepared: PreparedBackup, destination: Uri?) {
    if (destination == null) {
      backup.discardExport(prepared)
      _phase.value = DataRecoveryPhase.Idle
      return
    }
    _phase.value = DataRecoveryPhase.SavingBackup
    job = viewModelScope.launch {
      try {
        backup.saveExport(prepared, destination)
        _lastNotes.value = listOf(contentsLine(prepared.contents)) + prepared.notes +
          listOfNotNull("The backup could not be re-read on this device for verification because of its size.".takeIf { !prepared.verified })
      } catch (failure: Throwable) {
        if (failure is CancellationException) throw failure
        _error.value = failure.message ?: "The backup could not be saved."
      } finally {
        _phase.value = DataRecoveryPhase.Idle
      }
    }
  }

  fun restoreFileChosen(source: Uri?) {
    if (source == null || isWorking) return
    _phase.value = DataRecoveryPhase.CheckingRestore(null)
    job = viewModelScope.launch {
      try {
        val preview = backup.prepareRestore(source) { progress -> _phase.value = DataRecoveryPhase.CheckingRestore(progress) }
        _phase.value = DataRecoveryPhase.ReviewingRestore(preview)
      } catch (cancelled: CancellationException) {
        _phase.value = DataRecoveryPhase.Idle
        throw cancelled
      } catch (failure: Throwable) {
        _phase.value = DataRecoveryPhase.Idle
        _error.value = failure.message ?: "The selected file is not a valid Turing AI backup."
      }
    }
  }

  fun cancelPreparation() {
    val current = _phase.value
    if (current is DataRecoveryPhase.PreparingBackup || current is DataRecoveryPhase.CheckingRestore) job?.cancel()
  }

  fun dismissRestore() {
    val current = _phase.value as? DataRecoveryPhase.ReviewingRestore ?: return
    backup.discardRestore(current.preview)
    _phase.value = DataRecoveryPhase.Idle
  }

  fun confirmRestore() {
    val current = _phase.value as? DataRecoveryPhase.ReviewingRestore ?: return
    _phase.value = DataRecoveryPhase.Restoring(null)
    job = viewModelScope.launch {
      try {
        val result = backup.applyRestore(current.preview) { progress -> _phase.value = DataRecoveryPhase.Restoring(progress) }
        _lastNotes.value = listOf(contentsLine(result.contents)) + result.notes
        _phase.value = DataRecoveryPhase.Idle
      } catch (failure: Throwable) {
        // The library is unchanged; the staged backup can be reviewed again.
        _phase.value = DataRecoveryPhase.ReviewingRestore(current.preview)
        _error.value = failure.message ?: "Turing AI could not replace the local library."
      }
    }
  }

  fun clearError() {
    _error.value = null
  }

  override fun onCleared() {
    when (val current = _phase.value) {
      is DataRecoveryPhase.ChoosingDestination -> backup.discardExport(current.prepared)
      is DataRecoveryPhase.ReviewingRestore -> backup.discardRestore(current.preview)
      else -> Unit
    }
  }

  private companion object {
    const val BUSY_POLL_MILLIS = 2_000L
  }
}

private fun contentsLine(contents: BackupContents): String = buildList {
  add(countLabel(contents.conversations, "chat", "chats"))
  add(countLabel(contents.messages, "message", "messages"))
  if (contents.pinnedMemories > 0) add(countLabel(contents.pinnedMemories, "pinned memory", "pinned memories"))
  if (contents.learnedTopics > 0) add(countLabel(contents.learnedTopics, "learned topic", "learned topics"))
  if (contents.documents > 0) add(countLabel(contents.documents, "document", "documents"))
  if (contents.automations > 0) add(countLabel(contents.automations, "automation", "automations"))
}.joinToString(", ") + "."

private fun countLabel(value: Int, singular: String, plural: String) = "${formatCount(value)} ${if (value == 1) singular else plural}"

/** Settings → Data & Recovery: portable `.mosaicbackup` export and verified restore (iOS parity). */
@Composable
fun DataRecoveryScreen(onBack: () -> Unit) {
  val container = LocalAppContainer.current
  val vm: DataRecoveryViewModel = viewModel { DataRecoveryViewModel(container.backup) }
  val phase by vm.phase.collectAsStateWithLifecycle()
  val error by vm.error.collectAsStateWithLifecycle()
  val lastResult by vm.lastResult.collectAsStateWithLifecycle()
  val lastNotes by vm.lastNotes.collectAsStateWithLifecycle()
  val busyReason by vm.busyReason.collectAsStateWithLifecycle()
  var confirmingReplace by rememberSaveable { mutableStateOf(false) }

  val saveLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
    (vm.phase.value as? DataRecoveryPhase.ChoosingDestination)?.let { vm.destinationChosen(it.prepared, uri) }
  }
  // A .mosaicbackup has no registered type, so every document is offered; the file is validated anyway.
  val openLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
    vm.restoreFileChosen(uri)
  }
  val destinationRequest = (phase as? DataRecoveryPhase.ChoosingDestination)?.prepared
  // Launch the system "save as" picker once per prepared backup.
  var launchedFor by remember { mutableStateOf<PreparedBackup?>(null) }
  LaunchedEffect(destinationRequest) {
    if (destinationRequest != null && launchedFor !== destinationRequest) {
      launchedFor = destinationRequest
      runCatching { saveLauncher.launch(destinationRequest.suggestedFileName) }
        .onFailure { vm.destinationChosen(destinationRequest, null) }
    }
  }

  val working = phase !is DataRecoveryPhase.Idle
  val restoring = phase is DataRecoveryPhase.Restoring

  SettingsScaffold(title = "Data & Recovery", onBack = onBack, backEnabled = !restoring) { padding ->
    LazyColumn(
      modifier = Modifier.fillMaxSize().padding(padding),
      contentPadding = PaddingValues(bottom = 32.dp),
    ) {
      item(key = "backup-header") { SectionHeader("Portable backup") }
      item(key = "backup-summary") {
        ListItem(
          leadingContent = { Icon(Icons.Outlined.Storage, contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
          headlineContent = { Text("Your Turing AI library") },
          supportingContent = {
            Text(
              "Chats, attachments, pinned and learned memory, projects, documents, provider settings and automations " +
                "in one .mosaicbackup file that also opens in Turing AI on iPhone, iPad and Mac."
            )
          },
        )
      }
      item(key = "backup-action") {
        FilledTonalButton(
          onClick = vm::createBackup,
          enabled = !working && busyReason == null,
          modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp).heightIn(min = 48.dp),
        ) {
          Icon(Icons.Outlined.Upload, contentDescription = null, modifier = Modifier.size(ButtonDefaults.IconSize))
          Spacer(Modifier.width(ButtonDefaults.IconSpacing))
          Text("Create Backup")
        }
      }
      item(key = "backup-footer") {
        SectionFooter("API keys, the rebuildable search index and device preferences are never included.")
      }

      item(key = "restore-header") { SectionHeader("Restore") }
      item(key = "restore-action") {
        OutlinedButton(
          onClick = { openLauncher.launch(arrayOf("*/*")) },
          enabled = !working && busyReason == null,
          modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp).heightIn(min = 48.dp),
        ) {
          Icon(Icons.Outlined.Download, contentDescription = null, modifier = Modifier.size(ButtonDefaults.IconSize))
          Spacer(Modifier.width(ButtonDefaults.IconSpacing))
          Text("Choose Backup to Restore")
        }
      }
      item(key = "restore-footer") {
        SectionFooter(
          "Turing AI verifies the file checksum and checks every record before offering to replace this library. " +
            "Nothing changes until you confirm."
        )
      }

      if (working && phase !is DataRecoveryPhase.ReviewingRestore && phase !is DataRecoveryPhase.ChoosingDestination) {
        item(key = "progress") { ProgressSection(phase, onCancel = vm::cancelPreparation) }
      }

      busyReason?.let { reason ->
        item(key = "busy") {
          ListItem(
            leadingContent = { Icon(Icons.Outlined.HourglassEmpty, contentDescription = null) },
            headlineContent = { Text(reason, color = MaterialTheme.colorScheme.onSurfaceVariant) },
          )
        }
      }

      if (lastResult != null || lastNotes.isNotEmpty()) {
        item(key = "result-header") { SectionHeader("Last result") }
        lastResult?.let { message -> item(key = "result") { StatusLine(message, StatusTone.SUCCESS) } }
        lastNotes.forEachIndexed { index, note -> item(key = "note-$index") { StatusLine(note, StatusTone.NEUTRAL) } }
      }

      item(key = "behavior-header") { SectionHeader("Recovery behavior") }
      item(key = "behavior") {
        Column {
          BehaviorRow(Icons.Outlined.Key, "Imported provider connections receive new local identities.")
          BehaviorRow(Icons.Outlined.PowerSettingsNew, "Restored providers stay disabled until you review them.")
          BehaviorRow(Icons.Outlined.Lock, "Provider API keys must be entered again; they never leave a device.")
          BehaviorRow(Icons.Outlined.PauseCircle, "Imported automations stay paused until you review them.")
          BehaviorRow(Icons.Outlined.Refresh, "Search vectors rebuild from source data when needed.")
          BehaviorRow(Icons.Outlined.Devices, "Context receipts and Apple-only data stay on the device that created them.")
        }
      }
    }
  }

  (phase as? DataRecoveryPhase.ReviewingRestore)?.let { reviewing ->
    RestorePreviewDialog(
      preview = reviewing.preview,
      blockedReason = busyReason,
      onCancel = vm::dismissRestore,
      onContinue = { confirmingReplace = true },
    )
  }
  if (confirmingReplace && phase is DataRecoveryPhase.ReviewingRestore) {
    ConfirmDialog(
      title = "Replace Current Library?",
      message = "Current chats, memories, documents, providers and automations can't be recovered unless you already made a backup.",
      confirmLabel = "Replace Library",
      onConfirm = {
        confirmingReplace = false
        vm.confirmRestore()
      },
      onDismiss = { confirmingReplace = false },
    )
  }
  if (restoring) {
    AlertDialog(
      onDismissRequest = {},
      properties = DialogProperties(dismissOnBackPress = false, dismissOnClickOutside = false),
      title = { Text("Restoring…") },
      text = {
        Row(verticalAlignment = Alignment.CenterVertically) {
          CircularProgressIndicator(modifier = Modifier.size(24.dp))
          Spacer(Modifier.width(16.dp))
          Text("Replacing the local library. Keep Turing AI open.")
        }
      },
      confirmButton = {},
    )
  }
  error?.let { message ->
    MessageDialog(
      title = if (phase is DataRecoveryPhase.ReviewingRestore) "Restore failed" else "Data operation failed",
      message = message,
      onDismiss = vm::clearError,
    )
  }
}

@Composable
private fun ProgressSection(phase: DataRecoveryPhase, onCancel: () -> Unit) {
  val progress = when (phase) {
    is DataRecoveryPhase.PreparingBackup -> phase.progress
    is DataRecoveryPhase.CheckingRestore -> phase.progress
    is DataRecoveryPhase.Restoring -> phase.progress
    else -> null
  }
  val label = when {
    phase is DataRecoveryPhase.SavingBackup -> "Saving backup…"
    progress == null -> if (phase is DataRecoveryPhase.CheckingRestore) "Reading the selected file…" else "Preparing backup…"
    else -> when (progress.stage) {
      BackupProgress.Stage.READING_LIBRARY -> "Preparing backup…"
      BackupProgress.Stage.VERIFYING -> "Verifying the backup file…"
      BackupProgress.Stage.COPYING_FILE -> "Reading the selected file…"
      BackupProgress.Stage.VALIDATING -> "Validating every record…"
      BackupProgress.Stage.RESTORING -> "Replacing the local library…"
      BackupProgress.Stage.CLEANING_UP -> "Finishing restore…"
    }
  }
  val fraction = progress?.takeIf { it.total > 0 }?.let { (it.completed.toFloat() / it.total).coerceIn(0f, 1f) }
  val cancellable = phase is DataRecoveryPhase.PreparingBackup || phase is DataRecoveryPhase.CheckingRestore
  Column(
    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp)
      .semantics { liveRegion = LiveRegionMode.Polite },
    verticalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    Row(verticalAlignment = Alignment.CenterVertically) {
      Text(label, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
      if (cancellable) TextButton(onClick = onCancel) { Text("Cancel") }
    }
    if (fraction != null) LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth())
    else LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
  }
}

@Composable
private fun BehaviorRow(icon: ImageVector, text: String) {
  ListItem(
    leadingContent = { Icon(icon, contentDescription = null) },
    headlineContent = { Text(text, style = MaterialTheme.typography.bodyMedium) },
  )
}

@Composable
private fun RestorePreviewDialog(
  preview: RestorePreview,
  blockedReason: String?,
  onCancel: () -> Unit,
  onContinue: () -> Unit,
) {
  val contents = preview.contents
  AlertDialog(
    onDismissRequest = onCancel,
    title = { Text("Restore Backup?") },
    text = {
      Column(modifier = Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("Verified backup", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
        SummaryLine("Created", DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(preview.backupCreatedAtMillis)))
        SummaryLine("Chats", formatCount(contents.conversations))
        SummaryLine("Messages", formatCount(contents.messages))
        SummaryLine("Attachments", formatCount(contents.attachments))
        SummaryLine("Pinned memories", formatCount(contents.pinnedMemories))
        SummaryLine("Learned topics", formatCount(contents.learnedTopics))
        SummaryLine("Documents", formatCount(contents.documents))
        SummaryLine("Projects", formatCount(contents.projects))
        SummaryLine("Providers", formatCount(contents.providers))
        SummaryLine("Automations", formatCount(contents.automations))
        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
        Text("Before you restore", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
        Text(
          "This replaces the current local library. Provider keys are not in the backup; restored providers stay " +
            "disabled and every restored automation remains paused until you review them.",
          style = MaterialTheme.typography.bodyMedium,
        )
        if (preview.notes.isNotEmpty()) {
          Text("Not restored on Android", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 8.dp))
          preview.notes.forEach { note -> Text("• $note", style = MaterialTheme.typography.bodySmall) }
        }
        blockedReason?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
      }
    },
    confirmButton = {
      TextButton(onClick = onContinue, enabled = blockedReason == null) { Text("Continue") }
    },
    dismissButton = { TextButton(onClick = onCancel) { Text("Cancel") } },
  )
}

@Composable
private fun SummaryLine(label: String, value: String) {
  Row(modifier = Modifier.fillMaxWidth()) {
    Text(label, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
    Text(value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
  }
}

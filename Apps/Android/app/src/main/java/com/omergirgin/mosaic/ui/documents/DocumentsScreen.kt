package com.omergirgin.mosaic.ui.documents

import android.content.ActivityNotFoundException
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.LibraryBooks
import androidx.compose.material.icons.automirrored.outlined.TextSnippet
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.PictureAsPdf
import androidx.compose.material.icons.outlined.UploadFile
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.omergirgin.mosaic.data.api.DocumentRepository
import com.omergirgin.mosaic.data.documents.DocumentSummary
import com.omergirgin.mosaic.data.model.Project
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.Choice
import com.omergirgin.mosaic.ui.settings.EmptyState
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.SearchableChoiceDialog
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import com.omergirgin.mosaic.ui.settings.formatCount
import com.omergirgin.mosaic.ui.settings.pluralize
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Key used by availability choices for "Everywhere" (project IDs are UUIDs). */
internal const val EVERYWHERE_KEY = "everywhere"

/** MIME filters for the system picker; Markdown often arrives as text/plain or text/x-markdown. */
private val PICKER_TYPES = arrayOf("application/pdf", "text/*")

internal const val RECALL_FOOTER =
  "Enabled documents can be searched for relevant excerpts and included in your chats automatically. " +
    "Text is extracted on this device; PDF pages without usable text are read with on-device OCR."

@Composable
internal fun DocumentsScreen(onBack: () -> Unit, onOpenDocument: (String) -> Unit) {
  val container = LocalAppContainer.current
  val scope = rememberCoroutineScope()
  val vm: DocumentsViewModel = viewModel { DocumentsViewModel(container.documents) }
  val documents by remember(container) { container.documents.observeDocuments() }
    .collectAsStateWithLifecycle(initialValue = null)
  val projects by remember(container) { container.projects.observeProjects(includeArchived = true) }
    .collectAsStateWithLifecycle(initialValue = emptyList())
  val activeProjects = projects.filter { !it.isArchived }

  // Survives the trip through the system picker (and activity recreation while it is open).
  var pendingTargetKey by rememberSaveable { mutableStateOf<String?>(null) }
  var choosingTarget by rememberSaveable { mutableStateOf(false) }
  var movingDocument by remember { mutableStateOf<DocumentSummary?>(null) }
  var error by remember { mutableStateOf<String?>(null) }

  val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris: List<Uri> ->
    val key = pendingTargetKey
    pendingTargetKey = null
    if (uris.isEmpty() || key == null) return@rememberLauncherForActivityResult
    val projectId = key.takeUnless { it == EVERYWHERE_KEY }
    vm.startImport(uris, projectId, projects.firstOrNull { it.id == projectId }?.name)
  }
  val openPicker: (String) -> Unit = { key ->
    pendingTargetKey = key
    try {
      picker.launch(PICKER_TYPES)
    } catch (_: ActivityNotFoundException) {
      pendingTargetKey = null
      error = "No file picker is available on this device."
    }
  }
  val requestImport: () -> Unit = {
    if (vm.sheet?.isRunning != true) {
      if (activeProjects.isEmpty()) openPicker(EVERYWHERE_KEY) else choosingTarget = true
    }
  }

  SettingsScaffold(
    title = "Documents",
    onBack = onBack,
    floatingActionButton = {
      if (!documents.isNullOrEmpty()) {
        // Content overload: the icon/text overload's animated label is not exposed to
        // accessibility services, so the button would have no spoken name.
        ExtendedFloatingActionButton(onClick = requestImport) {
          Icon(Icons.Outlined.UploadFile, contentDescription = null)
          Text("Import", modifier = Modifier.padding(start = 12.dp))
        }
      }
    },
  ) { padding ->
    val all = documents
    when {
      all == null -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
      }
      all.isEmpty() -> EmptyState(
        title = "No documents yet",
        message = "Import PDFs, Markdown or text files so relevant passages can be used in your chats. " +
          "Up to 8 files at a time, 50 MB each.",
        icon = Icons.AutoMirrored.Outlined.LibraryBooks,
        modifier = Modifier.padding(padding),
      ) {
        vm.statusMessage?.let { StatusBanner(it, onDismiss = vm::clearStatus) }
        Button(onClick = requestImport, modifier = Modifier.heightIn(min = 48.dp)) {
          Icon(Icons.Outlined.UploadFile, contentDescription = null)
          Spacer(Modifier.width(8.dp))
          Text("Import PDF or text")
        }
      }
      else -> LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 96.dp)) {
        vm.statusMessage?.let { message ->
          item(key = "status") { StatusBanner(message, onDismiss = vm::clearStatus) }
        }
        item(key = "header") { SectionHeader("Imported documents") }
        items(all, key = { it.id }) { document ->
          DocumentRow(
            document = document,
            onOpen = { onOpenDocument(document.id) },
            onToggle = { enabled ->
              scope.launchDocumentWrite(container.documents, { error = it }) { setEnabled(document.id, enabled) }
            },
            onChangeAvailability = { movingDocument = document },
          )
        }
        item(key = "footer") { SectionFooter(RECALL_FOOTER) }
      }
    }
  }

  if (choosingTarget) {
    SearchableChoiceDialog(
      title = "Make documents available in",
      choices = availabilityChoices(activeProjects),
      selectedKey = null,
      onSelect = { key: String ->
        choosingTarget = false
        openPicker(key)
      },
      onDismiss = { choosingTarget = false },
      searchLabel = "Search projects",
    )
  }
  movingDocument?.let { document ->
    SearchableChoiceDialog(
      title = "Available in",
      choices = availabilityChoices(activeProjects),
      selectedKey = document.projectId ?: EVERYWHERE_KEY,
      onSelect = { key: String ->
        movingDocument = null
        val projectId = key.takeUnless { it == EVERYWHERE_KEY }
        if (projectId != document.projectId) {
          scope.launchDocumentWrite(container.documents, { error = it }) {
            moveToProject(document.id, projectId)
            vm.showStatus(availabilityMessage(document.title, projects.firstOrNull { it.id == projectId }))
          }
        }
      },
      onDismiss = { movingDocument = null },
      searchLabel = "Search projects",
    )
  }
  vm.sheet?.let { sheet -> ImportProgressSheet(sheet, onStop = vm::stop, onDismiss = vm::dismissSheet) }
  error?.let { MessageDialog("Document couldn't be updated", it) { error = null } }
}

internal fun availabilityChoices(activeProjects: List<Project>): List<Choice<String>> =
  listOf(Choice(EVERYWHERE_KEY, EVERYWHERE_KEY, "Everywhere", "Every chat, with or without a project")) +
    activeProjects.sortedBy { it.name.lowercase() }.map { Choice(it.id, it.id, it.name, "Only chats in this project") }

internal fun availabilityMessage(title: String, project: Project?): String =
  if (project == null) "$title is now available everywhere." else "$title is now available only in ${project.name}."

/** Scope label: Everywhere or the project (archived projects are labelled as such). */
internal fun availabilityLabel(document: DocumentSummary): String {
  if (document.projectId == null) return "Everywhere"
  val name = document.projectName ?: return "Unavailable project"
  return if (document.isProjectArchived) "$name (archived)" else name
}

/** iOS-style detail line: chunks, pages, OCR and fallback pages, characters. */
internal fun documentDescription(document: DocumentSummary): String {
  val values = ArrayList<String>()
  values += pluralize(document.chunkCount, "chunk")
  document.pageCount?.let { values += pluralize(it, "page") }
  if (document.ocrPageCount > 0) values += pluralize(document.ocrPageCount, "OCR page")
  if (document.ocrFallbackPageCount > 0) values += pluralize(document.ocrFallbackPageCount, "embedded-text fallback")
  values += "${formatCount(document.characterCount)} characters"
  return values.joinToString(" · ")
}

internal fun documentIcon(document: DocumentSummary): ImageVector =
  if (document.isPdf) Icons.Outlined.PictureAsPdf else Icons.AutoMirrored.Outlined.TextSnippet

/** Document writes finish even if the screen leaves composition mid-way. */
internal fun CoroutineScope.launchDocumentWrite(
  repository: DocumentRepository,
  onError: (String) -> Unit,
  action: suspend DocumentRepository.() -> Unit,
) {
  launch {
    try {
      withContext(NonCancellable) { repository.action() }
    } catch (e: Exception) {
      onError(e.message?.takeIf { it.isNotBlank() } ?: "Please try again.")
    }
  }
}

@Composable
private fun DocumentRow(
  document: DocumentSummary,
  onOpen: () -> Unit,
  onToggle: (Boolean) -> Unit,
  onChangeAvailability: () -> Unit,
) {
  Column(Modifier.fillMaxWidth()) {
    Row(
      modifier = Modifier
        .fillMaxWidth()
        .heightIn(min = 56.dp)
        .clickable(role = Role.Button, onClickLabel = "Open document", onClick = onOpen)
        .padding(start = 16.dp, end = 8.dp, top = 10.dp, bottom = 4.dp),
      verticalAlignment = Alignment.Top,
    ) {
      Icon(
        documentIcon(document),
        contentDescription = if (document.isPdf) "PDF" else "Text document",
        tint = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(top = 2.dp).size(24.dp),
      )
      Spacer(Modifier.width(16.dp))
      Column(Modifier.weight(1f)) {
        Text(
          document.title,
          style = MaterialTheme.typography.titleMedium,
          maxLines = 2,
          overflow = TextOverflow.Ellipsis,
        )
        Text(
          documentDescription(document),
          style = MaterialTheme.typography.bodySmall,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
      }
      // A separate control: TalkBack reads the document name with the switch state.
      Switch(
        checked = document.isEnabled,
        onCheckedChange = onToggle,
        modifier = Modifier.semantics {
          contentDescription = "Use ${document.title} in chats"
          stateDescription = if (document.isEnabled) "On" else "Off"
        },
      )
    }
    AvailabilityChip(document, onClick = onChangeAvailability, modifier = Modifier.padding(start = 48.dp, bottom = 6.dp))
    HorizontalDivider(Modifier.padding(start = 56.dp))
  }
}

@Composable
internal fun AvailabilityChip(document: DocumentSummary, onClick: () -> Unit, modifier: Modifier = Modifier) {
  Row(
    modifier = modifier
      .heightIn(min = 48.dp)
      .clickable(role = Role.Button, onClickLabel = "Change where this document can be recalled", onClick = onClick)
      .padding(horizontal = 8.dp),
    verticalAlignment = Alignment.CenterVertically,
  ) {
    Icon(
      if (document.projectId == null) Icons.Outlined.Language else Icons.Outlined.Folder,
      contentDescription = null,
      tint = MaterialTheme.colorScheme.onSurfaceVariant,
      modifier = Modifier.size(18.dp),
    )
    Spacer(Modifier.width(6.dp))
    Text(
      availabilityLabel(document),
      style = MaterialTheme.typography.labelLarge,
      color = MaterialTheme.colorScheme.onSurfaceVariant,
      maxLines = 1,
      overflow = TextOverflow.Ellipsis,
    )
  }
}

@Composable
private fun StatusBanner(message: String, onDismiss: () -> Unit) {
  Row(
    modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 8.dp),
    verticalAlignment = Alignment.Top,
    horizontalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    Text(
      message,
      style = MaterialTheme.typography.bodySmall,
      color = MaterialTheme.colorScheme.onSurfaceVariant,
      modifier = Modifier.weight(1f).padding(top = 12.dp),
    )
    IconButton(onClick = onDismiss) { Icon(Icons.Filled.Close, contentDescription = "Dismiss") }
  }
}

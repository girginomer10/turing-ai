package com.omergirgin.mosaic.ui.documents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.data.documents.DocumentChunkPreview
import com.omergirgin.mosaic.data.documents.DocumentSummary
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.ConfirmDialog
import com.omergirgin.mosaic.ui.settings.EmptyState
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.SearchableChoiceDialog
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsLinkRow
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import com.omergirgin.mosaic.ui.settings.SettingsSwitchRow
import com.omergirgin.mosaic.ui.settings.StatusLine
import com.omergirgin.mosaic.ui.settings.StatusTone
import com.omergirgin.mosaic.ui.settings.formatCount
import com.omergirgin.mosaic.ui.settings.pluralize
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val PREVIEW_CHUNKS = 5

@Composable
internal fun DocumentDetailScreen(documentId: String, onBack: () -> Unit) {
  val container = LocalAppContainer.current
  val scope = rememberCoroutineScope()
  // Sentinel distinguishes "loading" from "deleted".
  val loaded by remember(container, documentId) { container.documents.observeDocument(documentId) }
    .collectAsStateWithLifecycle(initialValue = LoadingDocument)
  val projects by remember(container) { container.projects.observeProjects(includeArchived = true) }
    .collectAsStateWithLifecycle(initialValue = emptyList())
  var preview by remember(documentId) { mutableStateOf<List<DocumentChunkPreview>?>(null) }
  var renaming by rememberSaveable { mutableStateOf(false) }
  var confirmingDelete by rememberSaveable { mutableStateOf(false) }
  var choosingAvailability by rememberSaveable { mutableStateOf(false) }
  var deleting by remember { mutableStateOf(false) }
  var notice by remember { mutableStateOf<String?>(null) }
  var error by remember { mutableStateOf<String?>(null) }

  LaunchedEffect(container, documentId) {
    preview = runCatching { container.documents.previewChunks(documentId, PREVIEW_CHUNKS) }.getOrElse { emptyList() }
  }

  val document = loaded.takeUnless { it === LoadingDocument }
  SettingsScaffold(
    title = document?.title ?: "Document",
    onBack = onBack,
    backEnabled = !deleting,
    actions = {
      if (document != null) {
        IconButton(onClick = { renaming = true }, enabled = !deleting) {
          Icon(Icons.Outlined.Edit, contentDescription = "Rename")
        }
      }
    },
  ) { padding ->
    when {
      loaded === LoadingDocument -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
      }
      document == null -> EmptyState(
        title = "Document not found",
        message = "This document was deleted.",
        modifier = Modifier.padding(padding),
      )
      else -> LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 32.dp)) {
        item(key = "summary") {
          ListItem(
            leadingContent = { Icon(documentIcon(document), contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
            headlineContent = { Text(document.title, style = MaterialTheme.typography.titleLarge) },
            supportingContent = { Text(document.sourceFilename) },
          )
        }
        notice?.let { item(key = "notice") { StatusLine(it, StatusTone.SUCCESS) } }

        item(key = "use-header") { SectionHeader("Recall") }
        item(key = "enabled") {
          SettingsSwitchRow(
            title = "Use in chats",
            subtitle = "Relevant passages can be included automatically.",
            checked = document.isEnabled,
            enabled = !deleting,
            onCheckedChange = { enabled ->
              scope.launchDocumentWrite(container.documents, { error = it }) { setEnabled(document.id, enabled) }
            },
          )
        }
        item(key = "availability") {
          SettingsLinkRow(
            title = "Available in",
            subtitle = availabilityLabel(document),
            icon = if (document.projectId == null) Icons.Outlined.Language else Icons.Outlined.Folder,
            enabled = !deleting,
            onClick = { choosingAvailability = true },
          )
        }
        item(key = "availability-footer") {
          SectionFooter(
            if (document.projectId == null) "Every chat can recall this document, with or without a project."
            else "Only chats in this project can recall this document.",
          )
        }

        item(key = "details-header") { SectionHeader("Details") }
        item(key = "details") { DocumentDetails(document) }
        if (document.ocrPageCount > 0) {
          item(key = "ocr") {
            StatusLine(
              "${pluralize(document.ocrPageCount, "scanned page")} ${if (document.ocrPageCount == 1) "was" else "were"} " +
                "read with on-device OCR. Recalled passages from those pages are marked as OCR text.",
              StatusTone.NEUTRAL,
            )
          }
        }
        if (document.ocrFallbackPageCount > 0) {
          item(key = "fallback") {
            StatusLine(
              "${pluralize(document.ocrFallbackPageCount, "short page")} kept ${if (document.ocrFallbackPageCount == 1) "its" else "their"} " +
                "embedded text after the OCR safety limit of 200 pages. Split the PDF to read those pages with OCR.",
              StatusTone.WARNING,
            )
          }
        }

        item(key = "preview-header") { SectionHeader("Preview") }
        val chunks = preview
        if (chunks == null) {
          item(key = "preview-loading") {
            Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
          }
        } else {
          items(chunks, key = { "chunk-${it.index}" }) { chunk -> ChunkCard(chunk) }
          item(key = "preview-footer") {
            SectionFooter(
              if (chunks.isEmpty()) "This document has no stored passages."
              else "Showing the first ${pluralize(chunks.size, "passage")} of ${formatCount(document.chunkCount)}, " +
                "as stored for recall. The preview is read-only.",
            )
          }
        }

        item(key = "delete") {
          OutlinedButton(
            onClick = { confirmingDelete = true },
            enabled = !deleting,
            colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 24.dp).heightIn(min = 48.dp),
          ) {
            Icon(Icons.Outlined.Delete, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text(if (deleting) "Deleting…" else "Delete document")
          }
        }
      }
    }
  }

  if (renaming && document != null) {
    RenameDialog(
      initial = document.title,
      onDismiss = { renaming = false },
      onSave = { title ->
        renaming = false
        scope.launchDocumentWrite(container.documents, { error = it }) { rename(document.id, title) }
      },
    )
  }
  if (choosingAvailability && document != null) {
    SearchableChoiceDialog(
      title = "Available in",
      choices = availabilityChoices(projects.filter { !it.isArchived }),
      selectedKey = document.projectId ?: EVERYWHERE_KEY,
      onSelect = { key: String ->
        choosingAvailability = false
        val projectId = key.takeUnless { it == EVERYWHERE_KEY }
        if (projectId != document.projectId) {
          scope.launchDocumentWrite(container.documents, { error = it }) {
            moveToProject(document.id, projectId)
            notice = availabilityMessage(document.title, projects.firstOrNull { it.id == projectId })
          }
        }
      },
      onDismiss = { choosingAvailability = false },
      searchLabel = "Search projects",
    )
  }
  if (confirmingDelete && document != null) {
    ConfirmDialog(
      title = "Delete this document?",
      message = "“${document.title}” and its local search index will be removed. Chats that already used " +
        "passages from it keep their history. This can't be undone.",
      confirmLabel = "Delete document",
      onConfirm = {
        confirmingDelete = false
        deleting = true
        scope.launch {
          try {
            withContext(NonCancellable) { container.documents.delete(document.id) }
            onBack()
          } catch (e: Exception) {
            deleting = false
            error = e.message?.takeIf { it.isNotBlank() } ?: "Please try again."
          }
        }
      },
      onDismiss = { confirmingDelete = false },
    )
  }
  error?.let { MessageDialog("Document couldn't be updated", it) { error = null } }
}

/** Placeholder distinguishing "still loading" from "deleted" (null). */
private val LoadingDocument = DocumentSummary(
  id = "", title = "", sourceFilename = "", mimeType = "", characterCount = 0, pageCount = null, chunkCount = 0,
  ocrPageCount = 0, ocrFallbackPageCount = 0, isEnabled = false, projectId = null, projectName = null,
  isProjectArchived = false, createdAt = 0, updatedAt = 0,
)

@Composable
private fun DocumentDetails(document: DocumentSummary) {
  val type = when {
    document.isPdf -> "PDF"
    document.mimeType == "text/markdown" -> "Markdown"
    else -> "Plain text"
  }
  val rows = buildList {
    add("Type" to type)
    document.pageCount?.let { add("Pages" to formatCount(it)) }
    add("Passages" to formatCount(document.chunkCount))
    add("Characters" to formatCount(document.characterCount))
    if (document.isPdf) {
      add("Pages read with OCR" to formatCount(document.ocrPageCount))
      add("Embedded-text fallbacks" to formatCount(document.ocrFallbackPageCount))
    }
    add("Imported" to DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(document.createdAt)))
  }
  Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
    for ((label, value) in rows) {
      Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodyLarge)
      }
    }
  }
}

@Composable
private fun ChunkCard(chunk: DocumentChunkPreview) {
  val label = buildList {
    add("Passage ${chunk.index + 1}")
    chunk.pageNumber?.let { add("Page $it") }
    if (chunk.isOcrDerived) add("OCR text")
  }.joinToString(" · ")
  Card(
    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
  ) {
    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
      Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
      SelectionContainer {
        Text(chunk.content, style = MaterialTheme.typography.bodyMedium)
      }
    }
  }
}

@Composable
private fun RenameDialog(initial: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
  var value by rememberSaveable { mutableStateOf(initial) }
  val trimmed = value.trim()
  AlertDialog(
    onDismissRequest = onDismiss,
    title = { Text("Rename document") },
    text = {
      OutlinedTextField(
        value = value,
        onValueChange = { value = it },
        label = { Text("Name") },
        singleLine = true,
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Done),
        modifier = Modifier.fillMaxWidth(),
      )
    },
    confirmButton = {
      TextButton(onClick = { onSave(trimmed) }, enabled = trimmed.isNotEmpty() && trimmed != initial) { Text("Save") }
    },
    dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
  )
}

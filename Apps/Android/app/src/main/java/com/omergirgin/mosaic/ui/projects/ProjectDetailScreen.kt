package com.omergirgin.mosaic.ui.projects

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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.data.model.ConversationSummary
import com.omergirgin.mosaic.data.model.Project
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.ConfirmDialog
import com.omergirgin.mosaic.ui.settings.EmptyState
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.ModelPickerDialog
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsLinkRow
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import com.omergirgin.mosaic.ui.settings.formatCount
import com.omergirgin.mosaic.ui.settings.formatRelativeTime
import com.omergirgin.mosaic.ui.settings.modelChoiceLabel
import kotlinx.coroutines.flow.map

private sealed interface ProjectLoad {
  data object Loading : ProjectLoad
  data object Missing : ProjectLoad
  data class Loaded(val project: Project) : ProjectLoad
}

@Composable
internal fun ProjectDetailScreen(
  projectId: String,
  onBack: () -> Unit,
  onEdit: () -> Unit,
  onOpenConversation: (String) -> Unit,
  onStartChatInProject: (String) -> Unit,
) {
  val container = LocalAppContainer.current
  val scope = rememberCoroutineScope()
  val load by remember(container, projectId) {
    container.projects.observeProject(projectId)
      .map<Project?, ProjectLoad> { if (it == null) ProjectLoad.Missing else ProjectLoad.Loaded(it) }
  }.collectAsStateWithLifecycle(initialValue = ProjectLoad.Loading)
  val chats by remember(container, projectId) { container.conversations.observeConversations(projectId = projectId) }
    .collectAsStateWithLifecycle(initialValue = null)
  val modelOptions by remember(container) { container.providers.observeModelOptions() }
    .collectAsStateWithLifecycle(initialValue = emptyList())
  var menuOpen by remember { mutableStateOf(false) }
  var confirmDelete by rememberSaveable { mutableStateOf(false) }
  var choosingModel by rememberSaveable { mutableStateOf(false) }
  var deleted by remember { mutableStateOf(false) }
  var error by remember { mutableStateOf<String?>(null) }

  // Leave once our own delete has gone through (the project flow then reports it missing).
  LaunchedEffect(deleted, load) { if (deleted && load == ProjectLoad.Missing) onBack() }

  val project = (load as? ProjectLoad.Loaded)?.project

  SettingsScaffold(
    title = project?.name ?: "Project",
    onBack = onBack,
    actions = {
      if (project != null) {
        Box {
          IconButton(onClick = { menuOpen = true }) {
            Icon(Icons.Filled.MoreVert, contentDescription = "Project actions")
          }
          DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DropdownMenuItem(text = { Text("Edit project") }, onClick = { menuOpen = false; onEdit() })
            DropdownMenuItem(
              text = { Text(if (project.isArchived) "Restore" else "Archive") },
              onClick = {
                menuOpen = false
                scope.launchProjectWrite(container.projects, { setArchived(project.id, !project.isArchived) }) { error = it }
              },
            )
            DropdownMenuItem(
              text = { Text("Delete project", color = MaterialTheme.colorScheme.error) },
              onClick = { menuOpen = false; confirmDelete = true },
            )
          }
        }
      }
    },
  ) { padding ->
    when (val state = load) {
      ProjectLoad.Loading -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
      }
      ProjectLoad.Missing -> EmptyState(
        title = "Project not found",
        message = "This project was deleted.",
        modifier = Modifier.padding(padding),
      ) { OutlinedButton(onClick = onBack) { Text("Go back") } }
      is ProjectLoad.Loaded -> ProjectDetailContent(
        project = state.project,
        chats = chats,
        defaultModelLabel = modelChoiceLabel(state.project.defaultModel, modelOptions, "Use app default"),
        modifier = Modifier.padding(padding),
        onNewChat = { onStartChatInProject(state.project.id) },
        onEdit = onEdit,
        onChooseModel = { choosingModel = true },
        onOpenConversation = onOpenConversation,
      )
    }
  }

  if (choosingModel && project != null) {
    ModelPickerDialog(
      title = "Project default model",
      options = modelOptions,
      selected = project.defaultModel,
      automaticLabel = "Use app default",
      automaticDescription = "New chats in this project use the app's default model.",
      onSelect = { choice ->
        choosingModel = false
        scope.launchProjectWrite(
          container.projects,
          { saveProject(project.id, project.name, project.instructions, choice) },
        ) { error = it }
      },
      onDismiss = { choosingModel = false },
    )
  }
  if (confirmDelete && project != null) {
    ConfirmDialog(
      title = "Delete “${project.name}”?",
      message = PROJECT_DELETE_MESSAGE,
      confirmLabel = "Delete project",
      onConfirm = {
        confirmDelete = false
        deleted = true
        scope.launchProjectWrite(container.projects, { delete(project.id) }) {
          deleted = false
          error = it
        }
      },
      onDismiss = { confirmDelete = false },
    )
  }
  error?.let { MessageDialog("Project couldn't be updated", it) { error = null } }
}

@Composable
private fun ProjectDetailContent(
  project: Project,
  chats: List<ConversationSummary>?,
  defaultModelLabel: String,
  modifier: Modifier,
  onNewChat: () -> Unit,
  onEdit: () -> Unit,
  onChooseModel: () -> Unit,
  onOpenConversation: (String) -> Unit,
) {
  LazyColumn(modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 32.dp)) {
    item(key = "summary") {
      Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(project.name, style = MaterialTheme.typography.headlineSmall, modifier = Modifier.semantics { heading() })
        if (project.isArchived) {
          Text("Archived", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (project.instructions.isBlank()) {
          Text("No project instructions", color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
          SelectionContainer { Text(project.instructions, style = MaterialTheme.typography.bodyMedium) }
        }
      }
    }
    item(key = "settings") {
      SettingsLinkRow(
        title = "Default model",
        subtitle = defaultModelLabel,
        icon = Icons.Outlined.Tune,
        onClick = onChooseModel,
      )
      ListItem(
        leadingContent = { Icon(Icons.Outlined.Lock, contentDescription = null) },
        headlineContent = { Text("Memory boundary") },
        supportingContent = { Text("Project memories stay in this project") },
      )
    }
    item(key = "actions") {
      Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
      ) {
        Button(onClick = onNewChat, enabled = !project.isArchived, modifier = Modifier.heightIn(min = 48.dp)) {
          Icon(Icons.AutoMirrored.Outlined.Chat, contentDescription = null)
          Spacer(Modifier.width(8.dp))
          Text("New chat in project")
        }
        OutlinedButton(onClick = onEdit, modifier = Modifier.heightIn(min = 48.dp)) {
          Icon(Icons.Outlined.Edit, contentDescription = null)
          Spacer(Modifier.width(8.dp))
          Text("Edit")
        }
      }
      SectionFooter(
        if (project.isArchived) {
          "Archived projects keep their existing chats but can't start new ones. Restore the project to add chats."
        } else {
          "Chats in this project use its instructions and default model, plus memories saved for this project " +
            "and memories marked Everywhere."
        },
      )
    }
    item(key = "chats-header") {
      SectionHeader(if (chats == null) "Chats" else "Chats (${formatCount(chats.size)})")
      HorizontalDivider()
    }
    when {
      chats == null -> item(key = "chats-loading") {
        Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
      }
      chats.isEmpty() -> item(key = "chats-empty") {
        Text(
          "No chats in this project yet.",
          color = MaterialTheme.colorScheme.onSurfaceVariant,
          modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
        )
      }
      else -> items(chats, key = { it.id }) { chat ->
        ListItem(
          headlineContent = { Text(chat.title.ifBlank { "New chat" }, maxLines = 1, overflow = TextOverflow.Ellipsis) },
          supportingContent = {
            Text(
              listOf(chat.preview.takeIf { it.isNotBlank() }, formatRelativeTime(chat.updatedAt))
                .filterNotNull()
                .joinToString(" · "),
              maxLines = 2,
              overflow = TextOverflow.Ellipsis,
            )
          },
          modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clickable(role = Role.Button, onClickLabel = "Open chat") { onOpenConversation(chat.id) },
        )
      }
    }
  }
}

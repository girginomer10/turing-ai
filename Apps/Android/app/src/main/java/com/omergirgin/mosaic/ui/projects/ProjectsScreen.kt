package com.omergirgin.mosaic.ui.projects

import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.data.api.ProjectRepository
import com.omergirgin.mosaic.data.model.Project
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.ConfirmDialog
import com.omergirgin.mosaic.ui.settings.EmptyState
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal const val PROJECT_DELETE_MESSAGE =
  "The project and its instructions will be deleted, along with memories pinned to this project. Its chats " +
    "are kept in your history without a project. This can't be undone."

@Composable
internal fun ProjectsScreen(
  onBack: () -> Unit,
  onOpenProject: (String) -> Unit,
  onCreateProject: () -> Unit,
  onEditProject: (String) -> Unit,
  onStartChatInProject: (String) -> Unit,
) {
  val container = LocalAppContainer.current
  val scope = rememberCoroutineScope()
  val projects by remember(container) { container.projects.observeProjects(includeArchived = true) }
    .collectAsStateWithLifecycle(initialValue = null)
  var pendingDeletion by remember { mutableStateOf<Project?>(null) }
  var error by remember { mutableStateOf<String?>(null) }

  val runAction: (suspend ProjectRepository.() -> Unit) -> Unit = { action ->
    scope.launchProjectWrite(container.projects, action) { error = it }
  }

  SettingsScaffold(
    title = "Projects",
    onBack = onBack,
    floatingActionButton = {
      if (!projects.isNullOrEmpty()) {
        ExtendedFloatingActionButton(
          onClick = onCreateProject,
          icon = { Icon(Icons.Filled.Add, contentDescription = null) },
          text = { Text("New project") },
        )
      }
    },
  ) { padding ->
    val all = projects
    when {
      all == null -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
      }
      all.isEmpty() -> EmptyState(
        title = "No projects yet",
        message = "Group related chats under shared instructions, a default model and project-only memories.",
        icon = Icons.Outlined.Folder,
        modifier = Modifier.padding(padding),
      ) {
        Button(onClick = onCreateProject, modifier = Modifier.heightIn(min = 48.dp)) {
          Icon(Icons.Filled.Add, contentDescription = null)
          Spacer(Modifier.width(8.dp))
          Text("New project")
        }
      }
      else -> {
        val active = all.filter { !it.isArchived }.sortedByDescending { it.updatedAt }
        val archived = all.filter { it.isArchived }.sortedByDescending { it.updatedAt }
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 96.dp)) {
          item(key = "active-header") { SectionHeader("Active") }
          if (active.isEmpty()) {
            item(key = "active-empty") {
              Text(
                "All projects are archived. Restore one or create a new project.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
              )
            }
          }
          items(active, key = { it.id }) { project ->
            ActiveProjectRow(
              project = project,
              onOpen = { onOpenProject(project.id) },
              onNewChat = { onStartChatInProject(project.id) },
              onEdit = { onEditProject(project.id) },
              onArchive = { runAction { setArchived(project.id, true) } },
              onDelete = { pendingDeletion = project },
            )
          }
          if (archived.isNotEmpty()) {
            item(key = "archived-header") { SectionHeader("Archived") }
            items(archived, key = { it.id }) { project ->
              ArchivedProjectRow(
                project = project,
                onOpen = { onOpenProject(project.id) },
                onRestore = { runAction { setArchived(project.id, false) } },
                onEdit = { onEditProject(project.id) },
                onDelete = { pendingDeletion = project },
              )
            }
          }
        }
      }
    }
  }

  pendingDeletion?.let { project ->
    ConfirmDialog(
      title = "Delete “${project.name}”?",
      message = PROJECT_DELETE_MESSAGE,
      confirmLabel = "Delete project",
      onConfirm = {
        pendingDeletion = null
        runAction { delete(project.id) }
      },
      onDismiss = { pendingDeletion = null },
    )
  }
  error?.let { MessageDialog("Project couldn't be updated", it) { error = null } }
}

/** Project writes finish even if the screen leaves composition mid-way. */
internal fun CoroutineScope.launchProjectWrite(
  repository: ProjectRepository,
  action: suspend ProjectRepository.() -> Unit,
  onError: (String) -> Unit,
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
private fun ActiveProjectRow(
  project: Project,
  onOpen: () -> Unit,
  onNewChat: () -> Unit,
  onEdit: () -> Unit,
  onArchive: () -> Unit,
  onDelete: () -> Unit,
) {
  var menuOpen by remember { mutableStateOf(false) }
  Column(Modifier.fillMaxWidth()) {
    Row(
      modifier = Modifier
        .fillMaxWidth()
        .heightIn(min = 56.dp)
        .clickable(role = Role.Button, onClickLabel = "Open project", onClick = onOpen)
        .padding(start = 16.dp, top = 8.dp, bottom = 4.dp),
      verticalAlignment = Alignment.Top,
    ) {
      Icon(
        Icons.Filled.Folder,
        contentDescription = null,
        tint = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(top = 12.dp).size(24.dp),
      )
      Spacer(Modifier.width(16.dp))
      Column(Modifier.weight(1f).padding(top = 10.dp)) {
        Text(project.name, style = MaterialTheme.typography.titleMedium)
        Text(
          project.instructions.ifBlank { "No project instructions" },
          style = MaterialTheme.typography.bodyMedium,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
          maxLines = 3,
          overflow = TextOverflow.Ellipsis,
        )
      }
      Box {
        IconButton(onClick = { menuOpen = true }) {
          Icon(Icons.Filled.MoreVert, contentDescription = "Actions for ${project.name}")
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
          DropdownMenuItem(text = { Text("New chat") }, onClick = { menuOpen = false; onNewChat() })
          DropdownMenuItem(text = { Text("Edit") }, onClick = { menuOpen = false; onEdit() })
          DropdownMenuItem(text = { Text("Archive") }, onClick = { menuOpen = false; onArchive() })
          DropdownMenuItem(
            text = { Text("Delete", color = MaterialTheme.colorScheme.error) },
            onClick = { menuOpen = false; onDelete() },
          )
        }
      }
    }
    TextButton(onClick = onNewChat, modifier = Modifier.padding(start = 48.dp).heightIn(min = 48.dp)) {
      Icon(Icons.AutoMirrored.Outlined.Chat, contentDescription = null, modifier = Modifier.size(18.dp))
      Spacer(Modifier.width(8.dp))
      Text("New chat in project")
    }
    HorizontalDivider(Modifier.padding(start = 56.dp))
  }
}

@Composable
private fun ArchivedProjectRow(
  project: Project,
  onOpen: () -> Unit,
  onRestore: () -> Unit,
  onEdit: () -> Unit,
  onDelete: () -> Unit,
) {
  var menuOpen by remember { mutableStateOf(false) }
  Row(
    modifier = Modifier
      .fillMaxWidth()
      .heightIn(min = 56.dp)
      .clickable(role = Role.Button, onClickLabel = "Open project", onClick = onOpen)
      .padding(start = 16.dp),
    verticalAlignment = Alignment.CenterVertically,
  ) {
    Icon(Icons.Outlined.Archive, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    Spacer(Modifier.width(16.dp))
    Text(project.name, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
    TextButton(onClick = onRestore, modifier = Modifier.heightIn(min = 48.dp)) { Text("Restore") }
    Box {
      IconButton(onClick = { menuOpen = true }) {
        Icon(Icons.Filled.MoreVert, contentDescription = "Actions for ${project.name}")
      }
      DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
        DropdownMenuItem(text = { Text("Edit") }, onClick = { menuOpen = false; onEdit() })
        DropdownMenuItem(text = { Text("Restore") }, onClick = { menuOpen = false; onRestore() })
        DropdownMenuItem(
          text = { Text("Delete", color = MaterialTheme.colorScheme.error) },
          onClick = { menuOpen = false; onDelete() },
        )
      }
    }
  }
}

package com.omergirgin.mosaic.ui.root

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.BarChart
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.automirrored.outlined.DriveFileMove
import androidx.compose.material.icons.outlined.DriveFileRenameOutline
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.EditNote
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.MoveToInbox
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material.icons.automirrored.outlined.LibraryBooks
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Unarchive
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.data.model.ConversationSummary
import com.omergirgin.mosaic.ui.components.ConfirmDialog
import com.omergirgin.mosaic.ui.components.ProjectPickerDialog
import com.omergirgin.mosaic.ui.components.TextInputDialog
import com.omergirgin.mosaic.ui.components.relativeTime
import com.omergirgin.mosaic.ui.settings.SettingsDestination

/**
 * Chat history: new chat, search, Chats/Archived, project filter, the conversation list and the
 * entries into the settings area. Used inside the full-width modal drawer on phones and the
 * permanent side sheet on wide screens.
 */
@Composable
fun HistoryDrawerContent(
  vm: HistoryViewModel,
  currentConversationId: String?,
  advancedControls: Boolean,
  onClose: (() -> Unit)?,
  onNewChat: () -> Unit,
  onOpenConversation: (String) -> Unit,
  onOpenSettings: (SettingsDestination) -> Unit,
  onConversationArchived: (String) -> Unit,
  modifier: Modifier = Modifier,
  /** Conversation tools; null hides the entry. */
  onOpenTemporaryChat: (() -> Unit)? = null,
  onOpenSharedItems: (() -> Unit)? = null,
  sharedItemCount: Int = 0,
) {
  val query by vm.query.collectAsStateWithLifecycle()
  val showArchived by vm.showArchived.collectAsStateWithLifecycle()
  val projectFilter by vm.projectFilter.collectAsStateWithLifecycle()
  val projects by vm.projects.collectAsStateWithLifecycle()
  val conversations by vm.conversations.collectAsStateWithLifecycle()
  val focusManager = LocalFocusManager.current

  var renameTarget by remember { mutableStateOf<ConversationSummary?>(null) }
  var moveTarget by remember { mutableStateOf<ConversationSummary?>(null) }
  var deleteTarget by remember { mutableStateOf<ConversationSummary?>(null) }

  Column(modifier.fillMaxSize()) {
    Row(
      verticalAlignment = Alignment.CenterVertically,
      modifier = Modifier.fillMaxWidth().padding(start = 24.dp, end = 8.dp, top = 8.dp, bottom = 4.dp),
    ) {
      Text(
        "Chats",
        style = MaterialTheme.typography.titleLarge,
        modifier = Modifier.weight(1f).semantics { heading() },
      )
      if (onClose != null) {
        IconButton(onClick = onClose) {
          Icon(Icons.Outlined.Close, contentDescription = "Close chat history")
        }
      }
    }

    OutlinedTextField(
      value = query,
      onValueChange = vm::setQuery,
      placeholder = { Text("Search chats") },
      leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
      trailingIcon = {
        if (query.isNotEmpty()) {
          IconButton(onClick = { vm.setQuery("") }) {
            Icon(Icons.Outlined.Close, contentDescription = "Clear search")
          }
        }
      },
      singleLine = true,
      shape = RoundedCornerShape(28.dp),
      keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
      keyboardActions = KeyboardActions(onSearch = { focusManager.clearFocus() }),
      modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
    )

    LazyColumn(
      contentPadding = PaddingValues(vertical = 8.dp),
      modifier = Modifier.weight(1f),
    ) {
      if (query.isBlank()) {
        item(key = "new-chat") {
          DrawerEntry(Icons.Outlined.EditNote, "New chat", onClick = onNewChat)
        }
        if (onOpenTemporaryChat != null) {
          item(key = "temporary-chat") {
            DrawerEntry(Icons.Outlined.VisibilityOff, "Temporary chat", onClick = onOpenTemporaryChat)
          }
        }
        item(key = "projects") {
          DrawerEntry(Icons.Outlined.Folder, "Projects") { onOpenSettings(SettingsDestination.Projects) }
        }
        item(key = "memory") {
          DrawerEntry(Icons.Outlined.Psychology, "Memory") { onOpenSettings(SettingsDestination.Memory) }
        }
        item(key = "documents") {
          DrawerEntry(Icons.AutoMirrored.Outlined.LibraryBooks, "Documents") { onOpenSettings(SettingsDestination.Documents) }
        }
        item(key = "automations") {
          DrawerEntry(Icons.Outlined.Schedule, "Automations") { onOpenSettings(SettingsDestination.Automations) }
        }
        item(key = "providers") {
          DrawerEntry(Icons.Outlined.Dns, if (advancedControls) "Providers" else "AI models & accounts") {
            onOpenSettings(SettingsDestination.Providers)
          }
        }
        if (onOpenSharedItems != null) {
          item(key = "shared-items") {
            NavigationDrawerItem(
              label = { Text("Shared items") },
              icon = { Icon(Icons.Outlined.MoveToInbox, contentDescription = null) },
              badge = { if (sharedItemCount > 0) Text(sharedItemCount.toString()) },
              selected = false,
              onClick = onOpenSharedItems,
              modifier = Modifier.padding(horizontal = 12.dp),
            )
          }
        }
        item(key = "usage") {
          DrawerEntry(Icons.Outlined.BarChart, if (advancedControls) "Usage & cost" else "Usage") {
            onOpenSettings(SettingsDestination.Usage)
          }
        }
        item(key = "divider") {
          HorizontalDivider(Modifier.padding(horizontal = 28.dp, vertical = 8.dp))
        }
      }

      item(key = "segments") {
        SingleChoiceSegmentedButtonRow(
          modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        ) {
          SegmentedButton(
            selected = !showArchived,
            onClick = { vm.setShowArchived(false) },
            shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2),
          ) { Text("Chats") }
          SegmentedButton(
            selected = showArchived,
            onClick = { vm.setShowArchived(true) },
            shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2),
          ) { Text("Archived") }
        }
      }

      if (projects.isNotEmpty()) {
        item(key = "project-filter") {
          LazyRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            contentPadding = PaddingValues(horizontal = 16.dp),
            modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
          ) {
            item(key = "all") {
              FilterChip(
                selected = projectFilter == null,
                onClick = { vm.setProjectFilter(null) },
                label = { Text("All chats") },
              )
            }
            items(projects, key = { it.id }) { project ->
              FilterChip(
                selected = projectFilter == project.id,
                onClick = { vm.setProjectFilter(if (projectFilter == project.id) null else project.id) },
                label = { Text(project.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                leadingIcon = { Icon(Icons.Outlined.Folder, contentDescription = null, modifier = Modifier.size(18.dp)) },
              )
            }
          }
        }
      }

      val list = conversations
      when {
        list == null -> item(key = "loading") {
          Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(Modifier.size(24.dp))
          }
        }
        list.isEmpty() -> item(key = "empty") {
          Text(
            text = when {
              query.isNotBlank() && showArchived -> "No matching archived chats"
              query.isNotBlank() -> "No matching chats"
              showArchived -> "No archived chats"
              projectFilter != null -> "No chats in this project yet"
              else -> "No chats yet. Start one with New chat."
            },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 28.dp, vertical = 16.dp),
          )
        }
        else -> items(list, key = { it.id }) { summary ->
          ConversationRow(
            summary = summary,
            selected = summary.id == currentConversationId,
            onOpen = { onOpenConversation(summary.id) },
            onRename = { renameTarget = summary },
            onMove = { moveTarget = summary },
            onArchiveToggle = {
              val archive = !summary.isArchived
              vm.setArchived(summary.id, archive) { if (archive) onConversationArchived(summary.id) }
            },
            onDelete = { deleteTarget = summary },
          )
        }
      }
    }

    HorizontalDivider()
    DrawerEntry(
      icon = Icons.Outlined.Settings,
      label = "Settings",
      onClick = { onOpenSettings(SettingsDestination.Home) },
      modifier = Modifier.padding(vertical = 8.dp),
    )
  }

  renameTarget?.let { target ->
    TextInputDialog(
      title = "Rename chat",
      label = "Title",
      initialValue = target.title,
      confirmLabel = "Rename",
      onDismiss = { renameTarget = null },
      onConfirm = {
        vm.rename(target.id, it)
        renameTarget = null
      },
    )
  }
  moveTarget?.let { target ->
    ProjectPickerDialog(
      projects = projects,
      currentProjectId = target.projectId,
      onDismiss = { moveTarget = null },
      onSelect = {
        vm.moveToProject(target.id, it)
        moveTarget = null
      },
    )
  }
  deleteTarget?.let { target ->
    ConfirmDialog(
      title = "Delete “${target.title}”?",
      message = "This permanently removes the chat, its messages and its chat-scoped memory. This can't be undone.",
      confirmLabel = "Delete",
      onDismiss = { deleteTarget = null },
      onConfirm = {
        vm.delete(target.id)
        deleteTarget = null
      },
    )
  }
}

@Composable
private fun DrawerEntry(
  icon: ImageVector,
  label: String,
  modifier: Modifier = Modifier,
  onClick: () -> Unit,
) {
  NavigationDrawerItem(
    label = { Text(label) },
    icon = { Icon(icon, contentDescription = null) },
    selected = false,
    onClick = onClick,
    modifier = modifier.padding(horizontal = 12.dp),
  )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ConversationRow(
  summary: ConversationSummary,
  selected: Boolean,
  onOpen: () -> Unit,
  onRename: () -> Unit,
  onMove: () -> Unit,
  onArchiveToggle: () -> Unit,
  onDelete: () -> Unit,
) {
  var menuOpen by rememberSaveable(summary.id) { mutableStateOf(false) }
  val meta = buildList {
    if (summary.hasDraftOnly) add("Draft")
    summary.projectName?.let(::add)
    add(relativeTime(summary.updatedAt))
  }.joinToString(" · ")

  Box(Modifier.padding(horizontal = 12.dp, vertical = 1.dp)) {
    Row(
      verticalAlignment = Alignment.CenterVertically,
      modifier = Modifier
        .fillMaxWidth()
        .heightIn(min = 56.dp)
        .clip(RoundedCornerShape(28.dp))
        .background(if (selected) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent)
        .semantics { this.selected = selected }
        .combinedClickable(
          role = Role.Button,
          onClickLabel = "Open chat",
          onLongClickLabel = "Chat actions",
          onLongClick = { menuOpen = true },
          onClick = onOpen,
        )
        .padding(start = 16.dp, top = 8.dp, bottom = 8.dp),
    ) {
      Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
          summary.title,
          style = MaterialTheme.typography.bodyLarge,
          fontWeight = FontWeight.Medium,
          maxLines = 1,
          overflow = TextOverflow.Ellipsis,
          color = if (selected) MaterialTheme.colorScheme.onSecondaryContainer else MaterialTheme.colorScheme.onSurface,
        )
        val preview = remember(summary.preview) { plainPreview(summary.preview) }
        if (preview.isNotEmpty()) {
          Text(
            preview,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
          )
        }
        Text(
          meta,
          style = MaterialTheme.typography.labelMedium,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
          maxLines = 1,
          overflow = TextOverflow.Ellipsis,
        )
      }
      Box {
        IconButton(onClick = { menuOpen = true }) {
          Icon(Icons.Filled.MoreVert, contentDescription = "More options for ${summary.title}")
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
          DropdownMenuItem(
            text = { Text("Rename") },
            leadingIcon = { Icon(Icons.Outlined.DriveFileRenameOutline, contentDescription = null) },
            onClick = {
              menuOpen = false
              onRename()
            },
          )
          DropdownMenuItem(
            text = { Text("Move to project") },
            leadingIcon = { Icon(Icons.AutoMirrored.Outlined.DriveFileMove, contentDescription = null) },
            onClick = {
              menuOpen = false
              onMove()
            },
          )
          DropdownMenuItem(
            text = { Text(if (summary.isArchived) "Unarchive" else "Archive") },
            leadingIcon = {
              Icon(
                if (summary.isArchived) Icons.Outlined.Unarchive else Icons.Outlined.Archive,
                contentDescription = null,
              )
            },
            onClick = {
              menuOpen = false
              onArchiveToggle()
            },
          )
          HorizontalDivider()
          DropdownMenuItem(
            text = { Text("Delete", color = MaterialTheme.colorScheme.error) },
            leadingIcon = {
              Icon(Icons.Outlined.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error)
            },
            onClick = {
              menuOpen = false
              onDelete()
            },
          )
        }
      }
    }
  }
}

private val CodeFence = Regex("```[\\w+-]*")
private val HeadingMarker = Regex("(^|\\s)#{1,6}\\s")
private val Whitespace = Regex("\\s+")

/** One-line preview without the most common Markdown markers (previews are raw message text). */
private fun plainPreview(raw: String): String =
  raw.replace(CodeFence, " ")
    .replace("**", "")
    .replace("__", "")
    .replace("`", "")
    .replace(HeadingMarker, " ")
    .replace(Whitespace, " ")
    .trim()

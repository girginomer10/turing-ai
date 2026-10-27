package com.omergirgin.mosaic.ui.memory

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
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.data.api.AppContainer
import com.omergirgin.mosaic.data.model.MemoryFact
import com.omergirgin.mosaic.data.model.MemoryScope
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.ConfirmDialog
import com.omergirgin.mosaic.ui.settings.EmptyState
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal fun memoryDisplayTitle(fact: MemoryFact): String = fact.title.trim().ifEmpty { "Untitled memory" }

/** Conversation titles for scope labels, including archived chats. */
internal fun observeConversationTitles(container: AppContainer): Flow<Map<String, String>> =
  combine(
    container.conversations.observeConversations(),
    container.conversations.observeConversations(archived = true),
  ) { active, archived -> (active + archived).associate { it.id to it.title } }

/** Pinned (manual) facts, the two automatic layers, and formation activity. */
private enum class MemoryTab(val label: String) {
  PINNED("Pinned"),
  LASTING("Lasting"),
  EVENTS("Events"),
  ACTIVITY("Activity"),
}

@Composable
internal fun MemoryScreen(
  onBack: () -> Unit,
  onAdd: () -> Unit,
  onEdit: (String) -> Unit,
  onOpenTopic: (String) -> Unit = {},
  onOpenDocuments: (() -> Unit)? = null,
  onOpenEmbeddings: (() -> Unit)? = null,
) {
  val container = LocalAppContainer.current
  // Embedding profiles are an advanced control, like on the Settings home screen.
  val advanced by remember(container) { container.settings.settings.map { it.advancedControls } }
    .collectAsStateWithLifecycle(initialValue = false)
  val related = RelatedLinks(onOpenDocuments, onOpenEmbeddings?.takeIf { advanced })
  var tabIndex by rememberSaveable { mutableIntStateOf(0) }
  val tab = MemoryTab.entries.getOrElse(tabIndex) { MemoryTab.PINNED }
  val facts by remember(container) { container.memory.observeFacts() }
    .collectAsStateWithLifecycle(initialValue = null)
  val failedUpdates by remember(container) { container.automaticMemory.observeActivity().map { it.failedJobCount } }
    .collectAsStateWithLifecycle(initialValue = 0)

  SettingsScaffold(
    title = "Memory",
    onBack = onBack,
    floatingActionButton = {
      if (tab == MemoryTab.PINNED && !facts.isNullOrEmpty()) {
        ExtendedFloatingActionButton(
          onClick = onAdd,
          icon = { Icon(Icons.Filled.Add, contentDescription = null) },
          text = { Text("Add memory") },
        )
      }
    },
  ) { padding ->
    Column(Modifier.fillMaxSize().padding(padding)) {
      PrimaryTabRow(selectedTabIndex = tab.ordinal) {
        MemoryTab.entries.forEach { option ->
          Tab(
            selected = option == tab,
            onClick = { tabIndex = option.ordinal },
            text = {
              if (option == MemoryTab.ACTIVITY && failedUpdates > 0) {
                BadgedBox(
                  badge = { Badge() },
                  modifier = Modifier.semantics { contentDescription = "Activity, failed updates need attention" },
                ) { Text(option.label, maxLines = 1) }
              } else {
                Text(option.label, maxLines = 1)
              }
            },
          )
        }
      }
      when (tab) {
        MemoryTab.PINNED -> PinnedMemoryTab(facts, onAdd, onEdit, related)
        MemoryTab.LASTING -> LearnedTopicsTab(events = false, onOpenTopic = onOpenTopic)
        MemoryTab.EVENTS -> LearnedTopicsTab(events = true, onOpenTopic = onOpenTopic)
        MemoryTab.ACTIVITY -> MemoryActivityTab()
      }
    }
  }
}

/** Manually pinned facts from the memory library. */
@Composable
private fun PinnedMemoryTab(facts: List<MemoryFact>?, onAdd: () -> Unit, onEdit: (String) -> Unit, related: RelatedLinks) {
  val container = LocalAppContainer.current
  val scope = rememberCoroutineScope()
  val projectNames by remember(container) {
    container.projects.observeProjects(includeArchived = true).map { list -> list.associate { it.id to it.name } }
  }.collectAsStateWithLifecycle(initialValue = emptyMap())
  // Only observe the (possibly long) chat list when a fact is actually scoped to a chat.
  val needsConversationTitles = facts.orEmpty().any { it.scope == MemoryScope.CONVERSATION }
  val conversationTitles by remember(container, needsConversationTitles) {
    if (needsConversationTitles) observeConversationTitles(container) else flowOf(emptyMap())
  }.collectAsStateWithLifecycle(initialValue = emptyMap())
  var query by rememberSaveable { mutableStateOf("") }
  var pendingDeletion by remember { mutableStateOf<MemoryFact?>(null) }
  var error by remember { mutableStateOf<String?>(null) }

  val all = facts
  when {
    all == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
      CircularProgressIndicator()
    }
    all.isEmpty() -> Column(Modifier.fillMaxSize()) {
      MemoryIntroCard(related)
      EmptyState(
        title = "No pinned memories yet",
        message = "Pin a preference or fact you want to reuse exactly as written across conversations.",
        icon = Icons.Outlined.Psychology,
      ) {
        Button(onClick = onAdd, modifier = Modifier.heightIn(min = 48.dp)) {
          Icon(Icons.Filled.Add, contentDescription = null)
          Spacer(Modifier.width(8.dp))
          Text("Add memory")
        }
      }
    }
    else -> {
      val normalized = query.trim()
      val visible = remember(all, normalized) {
        all.filter {
          normalized.isEmpty() || it.title.contains(normalized, ignoreCase = true) ||
            it.content.contains(normalized, ignoreCase = true)
        }.sortedByDescending { it.updatedAt }
      }
      LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 96.dp)) {
        item(key = "intro") { MemoryIntroCard(related) }
        item(key = "search") {
          OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            label = { Text("Search memories") },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
          )
        }
        item(key = "header") { SectionHeader("Saved memories") }
        if (visible.isEmpty()) {
          item(key = "no-match") {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
              Text("No matching memories", style = MaterialTheme.typography.titleMedium)
              Text("Try a different title or phrase.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
          }
        }
        items(visible, key = { it.id }) { fact ->
          MemoryRow(
            fact = fact,
            scopeLabel = scopeLabel(fact, projectNames, conversationTitles),
            onEdit = { onEdit(fact.id) },
            onDelete = { pendingDeletion = fact },
            onEnabledChange = { enabled ->
              scope.launchMemoryWrite(onError = { error = it }) {
                container.memory.saveFact(fact.copy(isEnabled = enabled, updatedAt = System.currentTimeMillis()))
              }
            },
          )
        }
      }
    }
  }

  pendingDeletion?.let { fact ->
    ConfirmDialog(
      title = "Delete this memory?",
      message = "“${memoryDisplayTitle(fact)}” will no longer be available to any conversation.",
      confirmLabel = "Delete memory",
      onConfirm = {
        pendingDeletion = null
        scope.launchMemoryWrite(onError = { error = it }) { container.memory.deleteFact(fact.id) }
      },
      onDismiss = { pendingDeletion = null },
    )
  }
  error?.let { MessageDialog("Memory couldn't be updated", it) { error = null } }
}

/** Memory writes finish even if the screen leaves composition mid-way. */
internal fun CoroutineScope.launchMemoryWrite(onError: (String) -> Unit, block: suspend () -> Unit): Job =
  launch {
    try {
      withContext(NonCancellable) { block() }
    } catch (e: Exception) {
      onError(e.message?.takeIf { it.isNotBlank() } ?: "Please try again.")
    }
  }

/** Optional links to the other sources Turing AI can recall from. */
private class RelatedLinks(val documents: (() -> Unit)?, val embeddings: (() -> Unit)?)

@Composable
private fun MemoryIntroCard(related: RelatedLinks) {
  Card(
    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer),
  ) {
    Row(Modifier.padding(16.dp), verticalAlignment = Alignment.Top) {
      Icon(Icons.Outlined.Psychology, contentDescription = null)
      Spacer(Modifier.width(12.dp))
      Column {
        Text("You control what Turing AI remembers", style = MaterialTheme.typography.titleSmall)
        Text(
          "Pin exact facts and preferences. Pinned memories are sent exactly as written in the conversations " +
            "they apply to, and they take precedence over anything Turing AI learns automatically. Learned " +
            "topics and events are under Lasting and Events.",
          style = MaterialTheme.typography.bodyMedium,
        )
        if (related.documents != null || related.embeddings != null) {
          Row {
            related.documents?.let { TextButton(onClick = it) { Text("Imported documents") } }
            related.embeddings?.let { TextButton(onClick = it) { Text("Smart recall & embeddings") } }
          }
        }
      }
    }
  }
}

private fun scopeLabel(
  fact: MemoryFact,
  projectNames: Map<String, String>,
  conversationTitles: Map<String, String>,
): Pair<ImageVector, String> = when (fact.scope) {
  MemoryScope.EVERYWHERE -> Icons.Outlined.Language to "All conversations"
  MemoryScope.PROJECT -> Icons.Outlined.Folder to (fact.projectId?.let(projectNames::get) ?: "Unavailable project")
  MemoryScope.CONVERSATION ->
    Icons.AutoMirrored.Outlined.Chat to
      (fact.conversationId?.let(conversationTitles::get)?.ifBlank { null } ?: "Specific conversation")
}

@Composable
private fun MemoryRow(
  fact: MemoryFact,
  scopeLabel: Pair<ImageVector, String>,
  onEdit: () -> Unit,
  onDelete: () -> Unit,
  onEnabledChange: (Boolean) -> Unit,
) {
  var menuOpen by remember { mutableStateOf(false) }
  val title = memoryDisplayTitle(fact)
  Column(Modifier.fillMaxWidth()) {
    Row(
      modifier = Modifier
        .fillMaxWidth()
        .clickable(role = Role.Button, onClickLabel = "Edit memory", onClick = onEdit)
        .padding(start = 16.dp, top = 8.dp),
      verticalAlignment = Alignment.Top,
    ) {
      Column(Modifier.weight(1f).padding(top = 4.dp, bottom = 4.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(
          fact.content,
          style = MaterialTheme.typography.bodyMedium,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
          maxLines = 3,
          overflow = TextOverflow.Ellipsis,
        )
      }
      Box {
        IconButton(onClick = { menuOpen = true }) {
          Icon(Icons.Filled.MoreVert, contentDescription = "Actions for $title")
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
          DropdownMenuItem(text = { Text("Edit") }, onClick = { menuOpen = false; onEdit() })
          DropdownMenuItem(
            text = { Text("Delete", color = MaterialTheme.colorScheme.error) },
            onClick = { menuOpen = false; onDelete() },
          )
        }
      }
    }
    Row(
      modifier = Modifier
        .fillMaxWidth()
        .heightIn(min = 48.dp)
        .toggleable(value = fact.isEnabled, role = Role.Switch, onValueChange = onEnabledChange)
        .padding(horizontal = 16.dp),
      verticalAlignment = Alignment.CenterVertically,
    ) {
      Icon(scopeLabel.first, contentDescription = null, modifier = Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
      Spacer(Modifier.width(8.dp))
      Text(
        "${scopeLabel.second} · saved manually",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.weight(1f),
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
      )
      Spacer(Modifier.width(8.dp))
      Text("Use in chats", style = MaterialTheme.typography.labelLarge)
      Spacer(Modifier.width(8.dp))
      Switch(checked = fact.isEnabled, onCheckedChange = null)
    }
    HorizontalDivider(Modifier.padding(start = 16.dp, top = 4.dp))
  }
}

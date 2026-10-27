package com.omergirgin.mosaic.ui.memory

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.Badge
import androidx.compose.material.icons.outlined.Flag
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.core.memory.AutomaticMemoryRules
import com.omergirgin.mosaic.core.memory.MemoryFormationJobStatus
import com.omergirgin.mosaic.core.memory.MemoryOrigin
import com.omergirgin.mosaic.core.memory.MemoryRevisionKind
import com.omergirgin.mosaic.core.memory.MemoryTopicKind
import com.omergirgin.mosaic.core.memory.RecentEventMemoryPolicy
import com.omergirgin.mosaic.data.memory.LearnedTopic
import com.omergirgin.mosaic.data.memory.LearnedTopicState
import com.omergirgin.mosaic.data.model.AppSettings
import com.omergirgin.mosaic.data.model.MemoryScope
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.SettingsSwitchRow
import com.omergirgin.mosaic.ui.settings.formatCount
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// region labels

internal fun kindIcon(kind: MemoryTopicKind): ImageVector = when (kind) {
  MemoryTopicKind.EVENT -> Icons.Outlined.Schedule
  MemoryTopicKind.IDENTITY -> Icons.Outlined.Badge
  MemoryTopicKind.PREFERENCE -> Icons.Outlined.Tune
  MemoryTopicKind.RELATIONSHIP -> Icons.Outlined.People
  MemoryTopicKind.PROJECT -> Icons.Outlined.Folder
  MemoryTopicKind.GOAL -> Icons.Outlined.Flag
  MemoryTopicKind.CONSTRAINT -> Icons.Outlined.Shield
  MemoryTopicKind.WORKFLOW -> Icons.Outlined.AccountTree
  MemoryTopicKind.FACT -> Icons.Outlined.Lightbulb
}

internal fun kindLabel(topic: LearnedTopic): String =
  if (topic.isEvent) {
    if (RecentEventMemoryPolicy.isRecent(topic.lastConfirmedAt)) "Recent event" else "Past event"
  } else {
    topic.kind.displayName
  }

internal fun topicScopeIcon(topic: LearnedTopic): ImageVector = when (topic.scope) {
  MemoryScope.EVERYWHERE -> Icons.Outlined.Language
  MemoryScope.PROJECT -> Icons.Outlined.Folder
  MemoryScope.CONVERSATION -> Icons.AutoMirrored.Outlined.Chat
}

internal fun topicScopeLabel(topic: LearnedTopic): String = when (topic.scope) {
  MemoryScope.EVERYWHERE -> "Everywhere"
  MemoryScope.PROJECT -> topic.projectName?.ifBlank { null } ?: "Unavailable project"
  MemoryScope.CONVERSATION -> topic.conversationTitle?.ifBlank { null }?.let { "Only in “$it”" } ?: "This chat only"
}

internal fun evidenceDescription(count: Int): String = when (count) {
  0 -> "Source unavailable"
  1 -> "Learned from 1 message"
  else -> "Confirmed by ${formatCount(count)} messages"
}

internal fun topicStatusDescription(topic: LearnedTopic): String = when (topic.state) {
  LearnedTopicState.FORGOTTEN ->
    if (topic.origin == MemoryOrigin.MANUAL) "Forgotten by you" else "No longer supported by a saved source"
  LearnedTopicState.PAUSED -> "Paused by you"
  LearnedTopicState.ACTIVE -> when {
    topic.origin == MemoryOrigin.MANUAL -> "Corrected by you"
    topic.evidenceCount > 1 -> "Confirmed from multiple messages"
    else -> "Learned automatically"
  }
}

internal fun revisionLabel(kind: MemoryRevisionKind): String = when (kind) {
  MemoryRevisionKind.CREATED -> "Learned"
  MemoryRevisionKind.REINFORCED -> "Confirmed again"
  MemoryRevisionKind.UPDATED -> "Updated"
  MemoryRevisionKind.FORGOTTEN -> "Forgotten"
  MemoryRevisionKind.REACTIVATED -> "Learned again"
  MemoryRevisionKind.USER_EDITED -> "Edited by you"
  MemoryRevisionKind.USER_DISABLED -> "Paused by you"
  MemoryRevisionKind.USER_ENABLED -> "Resumed by you"
}

internal fun runStatusLabel(status: MemoryFormationJobStatus): String = when (status) {
  MemoryFormationJobStatus.PENDING -> "Waiting"
  MemoryFormationJobStatus.GENERATING -> "In progress"
  MemoryFormationJobStatus.COMPLETE -> "Completed"
  MemoryFormationJobStatus.FAILED -> "Failed"
  MemoryFormationJobStatus.REJECTED -> "Not applied"
}

internal fun formatDate(millis: Long): String = DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(millis))

internal fun formatDateTime(millis: Long): String =
  DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(millis))

/** "Provider · model · host", skipping blanks. */
internal fun provenanceLine(vararg values: String?): String? =
  values.mapNotNull { it?.trim()?.ifEmpty { null } }.distinct().takeIf { it.isNotEmpty() }?.joinToString(" · ")

// endregion

/** The global "Learn from new chats" switch with an honest disclosure of what it costs. */
@Composable
internal fun AutomaticMemorySwitchCard(modifier: Modifier = Modifier) {
  val container = LocalAppContainer.current
  val scope = rememberCoroutineScope()
  val settings by remember(container) { container.settings.settings }.collectAsStateWithLifecycle(initialValue = null)
  var error by remember { mutableStateOf<String?>(null) }
  val current = settings ?: AppSettings()
  Card(
    modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer),
  ) {
    Column(Modifier.padding(vertical = 4.dp)) {
      // iOS shows Smart memory above "Learn from new chats" in advanced view only.
      if (current.advancedControls) SmartMemorySwitch(current, enabled = settings != null, onError = { error = it })
      SettingsSwitchRow(
        title = "Learn from new chats",
        subtitle = if (current.automaticMemoryEnabled) "On" else "Off — nothing new is learned",
        checked = current.automaticMemoryEnabled,
        enabled = settings != null,
        onCheckedChange = { enabled ->
          scope.launch {
            runCatching { withContext(NonCancellable) { container.settings.setAutomaticMemoryEnabled(enabled) } }
              .onFailure { error = it.message ?: "The setting couldn't be saved. Please try again." }
          }
        },
      )
      Text(
        "After a reply is saved, Turing AI sends your message to the same AI service and model you chatted " +
          "with in one extra request, so it can propose lasting facts and personal events. It never delays " +
          "or changes the reply, and assistant answers are never used as evidence. This uses your provider " +
          "account and may consume API credits. Learned topics already saved stay available while this is off.",
        style = MaterialTheme.typography.bodySmall,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp),
      )
      error?.let {
        Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
      }
    }
  }
}

/** One learned topic in the Lasting/Events lists. */
@Composable
internal fun LearnedTopicRow(
  topic: LearnedTopic,
  onOpen: () -> Unit,
  onCorrect: () -> Unit,
  onForget: () -> Unit,
  onEnabledChange: (Boolean) -> Unit,
) {
  var menuOpen by remember { mutableStateOf(false) }
  val title = topic.title.ifBlank { "Untitled memory" }
  val forgotten = topic.state == LearnedTopicState.FORGOTTEN
  Column(Modifier.fillMaxWidth()) {
    Row(
      modifier = Modifier
        .fillMaxWidth()
        .clickable(role = Role.Button, onClickLabel = "Show sources and history", onClick = onOpen)
        .padding(start = 16.dp, top = 8.dp),
      verticalAlignment = Alignment.Top,
    ) {
      Icon(
        kindIcon(topic.kind),
        contentDescription = null,
        tint = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(top = 6.dp).size(20.dp),
      )
      Spacer(Modifier.width(12.dp))
      Column(Modifier.weight(1f).padding(vertical = 4.dp)) {
        Text(
          title,
          style = MaterialTheme.typography.titleMedium,
          color = if (forgotten) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
        )
        Text(
          topic.content,
          style = MaterialTheme.typography.bodyMedium,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
          maxLines = 3,
          overflow = TextOverflow.Ellipsis,
        )
        Text(
          buildList {
            add(topicScopeLabel(topic))
            add(kindLabel(topic))
            if (topic.isEvent) add("Reported ${formatDate(topic.lastConfirmedAt)}")
            add(evidenceDescription(topic.evidenceCount))
            if (topic.useCount > 0) add("Used ${formatCount(topic.useCount)}×")
            when (topic.state) {
              LearnedTopicState.PAUSED -> add("Paused")
              LearnedTopicState.FORGOTTEN -> add("Forgotten")
              LearnedTopicState.ACTIVE -> if (topic.origin == MemoryOrigin.MANUAL) add("Corrected by you")
            }
          }.joinToString(" · "),
          style = MaterialTheme.typography.bodySmall,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
          modifier = Modifier.padding(top = 4.dp),
        )
      }
      Box {
        IconButton(onClick = { menuOpen = true }) {
          Icon(Icons.Filled.MoreVert, contentDescription = "Actions for $title")
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
          DropdownMenuItem(text = { Text("Review sources") }, onClick = { menuOpen = false; onOpen() })
          DropdownMenuItem(text = { Text("Correct") }, onClick = { menuOpen = false; onCorrect() })
          if (forgotten) {
            DropdownMenuItem(text = { Text("Remember again") }, onClick = { menuOpen = false; onEnabledChange(true) })
          } else {
            DropdownMenuItem(
              text = { Text("Forget", color = MaterialTheme.colorScheme.error) },
              onClick = { menuOpen = false; onForget() },
            )
          }
        }
      }
    }
    val checked = topic.state == LearnedTopicState.ACTIVE
    Row(
      modifier = Modifier
        .fillMaxWidth()
        .heightIn(min = 48.dp)
        .toggleable(value = checked, role = Role.Switch, onValueChange = onEnabledChange)
        .padding(start = 48.dp, end = 16.dp),
      verticalAlignment = Alignment.CenterVertically,
    ) {
      Text(
        if (forgotten) "Remember again" else "Use in chats",
        style = MaterialTheme.typography.labelLarge,
        modifier = Modifier.weight(1f),
      )
      Switch(checked = checked, onCheckedChange = null)
    }
    HorizontalDivider(Modifier.padding(start = 16.dp, top = 4.dp))
  }
}

/** Correction editor: the new value becomes authoritative; the old one stays in history. */
@Composable
internal fun CorrectTopicDialog(
  topic: LearnedTopic,
  isSaving: Boolean,
  onDismiss: () -> Unit,
  onSave: (title: String, content: String) -> Unit,
) {
  var title by rememberSaveable(topic.id) { mutableStateOf(topic.title) }
  var content by rememberSaveable(topic.id) { mutableStateOf(topic.content) }
  val trimmedTitle = title.trim()
  val trimmedContent = content.trim()
  val problem = when {
    trimmedTitle.isEmpty() -> "Add a title."
    trimmedContent.isEmpty() -> "Add the fact Turing AI should remember."
    else -> AutomaticMemoryRules.textProblem(trimmedTitle, trimmedContent)
  }
  val changed = trimmedTitle != topic.title || trimmedContent != topic.content
  AlertDialog(
    onDismissRequest = { if (!isSaving) onDismiss() },
    title = { Text("Correct memory") },
    text = {
      Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
          value = title,
          onValueChange = { title = it },
          label = { Text("Title") },
          placeholder = { Text("Response language") },
          singleLine = true,
          keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
          modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
          value = content,
          onValueChange = { content = it },
          label = { Text("Current value") },
          minLines = 3,
          maxLines = 8,
          keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
          modifier = Modifier.fillMaxWidth(),
        )
        Text(
          problem ?: "Use a short title and one clear, current fact. Your correction becomes authoritative, " +
            "source messages stay unchanged, and the previous value stays in change history.",
          style = MaterialTheme.typography.bodySmall,
          color = if (problem != null && (title.isNotEmpty() || content.isNotEmpty())) {
            MaterialTheme.colorScheme.error
          } else {
            MaterialTheme.colorScheme.onSurfaceVariant
          },
        )
      }
    },
    confirmButton = {
      TextButton(onClick = { onSave(trimmedTitle, trimmedContent) }, enabled = problem == null && changed && !isSaving) {
        Text("Save correction")
      }
    },
    dismissButton = { TextButton(onClick = onDismiss, enabled = !isSaving) { Text("Cancel") } },
  )
}

/** Intro used when the automatic tabs have nothing to show yet. */
@Composable
internal fun LearnedEmptyState(events: Boolean, enabled: Boolean, modifier: Modifier = Modifier) {
  Column(
    modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 32.dp),
    horizontalAlignment = Alignment.CenterHorizontally,
    verticalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    Icon(
      if (events) Icons.Outlined.Schedule else Icons.Outlined.Psychology,
      contentDescription = null,
      tint = MaterialTheme.colorScheme.primary,
      modifier = Modifier.size(40.dp),
    )
    Text(if (events) "No events yet" else "No lasting information yet", style = MaterialTheme.typography.titleMedium)
    Text(
      when {
        !enabled -> "Turn on Learn from new chats to let Turing AI propose learned memory after successful replies."
        events -> "Personal events you mention, such as a trip or an appointment, appear here with their report dates."
        else -> "Durable preferences, relationships, goals and other facts you state in chats appear here."
      },
      style = MaterialTheme.typography.bodyMedium,
      color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
  }
}

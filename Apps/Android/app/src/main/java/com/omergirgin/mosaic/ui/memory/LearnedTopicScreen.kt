package com.omergirgin.mosaic.ui.memory

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
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.LinkOff
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.core.memory.MemoryOrigin
import com.omergirgin.mosaic.data.memory.LearnedTopic
import com.omergirgin.mosaic.data.memory.LearnedTopicDetail
import com.omergirgin.mosaic.data.memory.LearnedTopicEvidence
import com.omergirgin.mosaic.data.memory.LearnedTopicRevision
import com.omergirgin.mosaic.data.memory.LearnedTopicState
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.ConfirmDialog
import com.omergirgin.mosaic.ui.settings.EmptyState
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsLinkRow
import com.omergirgin.mosaic.ui.settings.SettingsSwitchRow
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import com.omergirgin.mosaic.ui.settings.StatusLine
import com.omergirgin.mosaic.ui.settings.StatusTone
import com.omergirgin.mosaic.ui.settings.formatCount
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * One learned topic: current value, scope and state, the exact user-message sources with the
 * provider/model/host that extracted them, and the full change history. Corrections, pause/resume
 * and forgetting apply immediately without a per-item approval prompt (forgetting is confirmed).
 */
@Composable
internal fun LearnedTopicScreen(topicId: String, onBack: () -> Unit) {
  val container = LocalAppContainer.current
  val scope = rememberCoroutineScope()
  // Wrapped so "loading" (null) differs from "deleted" (Loaded(null)).
  val state by remember(container, topicId) {
    container.automaticMemory.observeTopicDetail(topicId).map { DetailState(it) }
  }.collectAsStateWithLifecycle(initialValue = null)
  var correcting by rememberSaveable { mutableStateOf(false) }
  var isSaving by remember { mutableStateOf(false) }
  var confirmForget by rememberSaveable { mutableStateOf(false) }
  var error by remember { mutableStateOf<String?>(null) }

  val detail = state?.detail
  SettingsScaffold(title = detail?.topic?.title?.ifBlank { null } ?: "Learned memory", onBack = onBack) { padding ->
    when {
      state == null -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
      }
      detail == null -> EmptyState(
        title = "Memory not found",
        message = "This learned topic was removed, for example because its chat was deleted.",
        icon = Icons.Outlined.Psychology,
        modifier = Modifier.padding(padding),
      ) { OutlinedButton(onClick = onBack) { Text("Go back") } }
      else -> TopicDetailList(
        detail = detail,
        modifier = Modifier.padding(padding),
        onCorrect = { correcting = true },
        onForget = { confirmForget = true },
        onEnabledChange = { enabled ->
          scope.launchMemoryWrite(onError = { error = it }) { container.automaticMemory.setTopicEnabled(detail.topic, enabled) }
        },
      )
    }
  }

  val topic = detail?.topic
  if (correcting && topic != null) {
    CorrectTopicDialog(
      topic = topic,
      isSaving = isSaving,
      onDismiss = { correcting = false },
      onSave = { title, content ->
        isSaving = true
        scope.launch {
          scope.launchMemoryWrite(onError = { error = it }) { container.automaticMemory.correctTopic(topic, title, content) }.join()
          isSaving = false
          correcting = false
        }
      },
    )
  }
  if (confirmForget && topic != null) {
    ConfirmDialog(
      title = "Forget this learned topic?",
      message = "“${topic.title}” will stop being recalled. Its sources and change history will remain available.",
      confirmLabel = "Forget topic",
      onConfirm = {
        confirmForget = false
        scope.launchMemoryWrite(onError = { error = it }) { container.automaticMemory.forgetTopic(topic) }
      },
      onDismiss = { confirmForget = false },
    )
  }
  error?.let { MessageDialog("Memory couldn't be updated", it) { error = null } }
}

private data class DetailState(val detail: LearnedTopicDetail?)

@Composable
private fun TopicDetailList(
  detail: LearnedTopicDetail,
  modifier: Modifier,
  onCorrect: () -> Unit,
  onForget: () -> Unit,
  onEnabledChange: (Boolean) -> Unit,
) {
  val topic = detail.topic
  LazyColumn(modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 32.dp)) {
    item(key = "current-header") { SectionHeader("Current memory") }
    item(key = "current") { CurrentValue(topic) }

    item(key = "controls-header") { SectionHeader("Controls") }
    item(key = "correct") {
      SettingsLinkRow(title = "Correct this memory", icon = Icons.Outlined.Edit, onClick = onCorrect, showChevron = false)
    }
    item(key = "toggle") {
      val forgotten = topic.state == LearnedTopicState.FORGOTTEN
      SettingsSwitchRow(
        title = if (forgotten) "Remember again" else "Use in chats",
        subtitle = if (forgotten) "Restores this topic for future chats." else "Paused topics are kept but never sent.",
        checked = topic.state == LearnedTopicState.ACTIVE,
        onCheckedChange = onEnabledChange,
      )
    }
    if (topic.state != LearnedTopicState.FORGOTTEN) {
      item(key = "forget") {
        TextButton(
          onClick = onForget,
          colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
          modifier = Modifier.padding(horizontal = 8.dp).heightIn(min = 48.dp),
        ) {
          Icon(Icons.Outlined.Delete, contentDescription = null)
          Spacer(Modifier.width(8.dp))
          Text("Forget this topic")
        }
      }
    }
    item(key = "controls-footer") {
      SectionFooter("Corrections become the current value. Forgetting keeps an audit trail and can be undone with Remember again.")
    }

    item(key = "sources-header") { SectionHeader("Sources") }
    if (detail.evidence.isEmpty()) {
      item(key = "sources-empty") { StatusLine("No source message is available.", StatusTone.NEUTRAL) }
    } else {
      items(detail.evidence, key = { it.id }) { EvidenceRow(it) }
    }
    item(key = "sources-footer") {
      val explanation = "Only your exact messages can be evidence; assistant replies and attachment contents never become sources."
      SectionFooter(
        if (detail.totalEvidenceCount > detail.evidence.size) {
          "$explanation Showing the newest ${detail.evidence.size} of ${formatCount(detail.totalEvidenceCount)} sources."
        } else {
          explanation
        },
      )
    }

    item(key = "history-header") { SectionHeader("Change history") }
    if (detail.revisions.isEmpty()) {
      item(key = "history-empty") { StatusLine("No history is available.", StatusTone.NEUTRAL) }
    } else {
      items(detail.revisions, key = { it.id }) { RevisionRow(it) }
    }
    if (detail.totalRevisionCount > detail.revisions.size) {
      item(key = "history-footer") {
        SectionFooter("Showing the newest ${detail.revisions.size} of ${formatCount(detail.totalRevisionCount)} changes.")
      }
    }
  }
}

@Composable
private fun CurrentValue(topic: LearnedTopic) {
  Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
    Row(verticalAlignment = Alignment.CenterVertically) {
      Icon(kindIcon(topic.kind), contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
      Spacer(Modifier.width(8.dp))
      Text(kindLabel(topic), style = MaterialTheme.typography.labelLarge)
    }
    if (topic.isEvent) {
      Text(
        "Last reported ${formatDate(topic.lastConfirmedAt)}. A dated report, not a permanent fact. New updates " +
          "replace the current account while earlier versions stay in history.",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
    SelectionContainer { Text(topic.content, style = MaterialTheme.typography.bodyLarge) }
  }
  DetailLine("Status", topicStatusDescription(topic))
  DetailLine("Scope", topicScopeLabel(topic))
  DetailLine(
    "Sources",
    if (topic.evidenceCount == 1) "1 user message" else "${formatCount(topic.evidenceCount)} user messages",
  )
  DetailLine("Origin", if (topic.origin == MemoryOrigin.MANUAL) "Corrected by you" else "Learned automatically")
  if (topic.useCount > 0) DetailLine("Used in requests", formatCount(topic.useCount))
  DetailLine("Last updated", formatDateTime(topic.updatedAt))
}

@Composable
private fun DetailLine(label: String, value: String) {
  ListItem(
    headlineContent = { Text(label, style = MaterialTheme.typography.bodyMedium) },
    trailingContent = { Text(value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) },
  )
}

@Composable
private fun EvidenceRow(evidence: LearnedTopicEvidence) {
  Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
    Row(verticalAlignment = Alignment.CenterVertically) {
      Icon(
        if (evidence.sourceAvailable) Icons.AutoMirrored.Outlined.Chat else Icons.Outlined.LinkOff,
        contentDescription = null,
        tint = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.size(16.dp),
      )
      Spacer(Modifier.width(6.dp))
      Text(
        evidence.conversationTitle?.ifBlank { null } ?: "Conversation no longer available",
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.weight(1f),
        maxLines = 1,
      )
      Text(formatDateTime(evidence.createdAt), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    SelectionContainer { Text(evidence.excerpt, style = MaterialTheme.typography.bodyMedium) }
    if (!evidence.sourceAvailable) {
      Text("The original message was deleted; this excerpt is kept for the audit trail.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    provenanceLine(evidence.providerName, evidence.modelId, evidence.providerHost)?.let {
      Text("Learned with $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
  }
  HorizontalDivider(Modifier.padding(start = 16.dp))
}

@Composable
private fun RevisionRow(revision: LearnedTopicRevision) {
  Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
    Text(revisionLabel(revision.kind), style = MaterialTheme.typography.titleSmall)
    val previousTitle = revision.previousTitle
    if (previousTitle != null && previousTitle != revision.title) {
      Text("Title: $previousTitle → ${revision.title}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    val previous = revision.previousContent
    if (previous != null && previous != revision.content) {
      Text("Previous: $previous", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 3)
    }
    Text("Current: ${revision.content}", style = MaterialTheme.typography.bodySmall, maxLines = 3)
    Text(formatDateTime(revision.createdAt), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
  }
  HorizontalDivider(Modifier.padding(start = 16.dp))
}

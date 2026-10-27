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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.HourglassEmpty
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.RemoveCircleOutline
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.core.memory.MemoryFormationJobStatus
import com.omergirgin.mosaic.data.memory.LearnedTopic
import com.omergirgin.mosaic.data.memory.LearnedTopicState
import com.omergirgin.mosaic.data.memory.MemoryFormationActivity
import com.omergirgin.mosaic.data.memory.MemoryFormationRun
import com.omergirgin.mosaic.data.memory.MemoryRetryOutcome
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.ConfirmDialog
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.StatusLine
import com.omergirgin.mosaic.ui.settings.StatusTone
import com.omergirgin.mosaic.ui.settings.formatCount
import com.omergirgin.mosaic.ui.settings.formatRelativeTime
import com.omergirgin.mosaic.ui.settings.pluralize
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** Lasting information ([events] = false) or personal Events, learned automatically from chats. */
@Composable
internal fun LearnedTopicsTab(events: Boolean, onOpenTopic: (String) -> Unit) {
  val container = LocalAppContainer.current
  val scope = rememberCoroutineScope()
  val topics by remember(container) { container.automaticMemory.observeTopics() }
    .collectAsStateWithLifecycle(initialValue = null)
  val enabled by remember(container) { container.settings.settings }
    .collectAsStateWithLifecycle(initialValue = null)
  var query by rememberSaveable(events) { mutableStateOf("") }
  var correcting by remember { mutableStateOf<LearnedTopic?>(null) }
  var isSaving by remember { mutableStateOf(false) }
  var forgetting by remember { mutableStateOf<LearnedTopic?>(null) }
  var error by remember { mutableStateOf<String?>(null) }

  val all = topics
  if (all == null) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
    return
  }
  val layer = remember(all, events) { all.filter { it.isEvent == events } }
  val normalized = query.trim()
  val visible = remember(layer, normalized) {
    layer.filter {
      normalized.isEmpty() || it.title.contains(normalized, ignoreCase = true) || it.content.contains(normalized, ignoreCase = true)
    }
  }
  val current = visible.filter { it.state != LearnedTopicState.FORGOTTEN }
  val forgotten = visible.filter { it.state == LearnedTopicState.FORGOTTEN }

  val setEnabled: (LearnedTopic, Boolean) -> Unit = { topic, value ->
    scope.launchMemoryWrite(onError = { error = it }) { container.automaticMemory.setTopicEnabled(topic, value) }
  }

  LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 32.dp)) {
    item(key = "switch") { AutomaticMemorySwitchCard() }
    if (layer.isEmpty()) {
      item(key = "empty") { LearnedEmptyState(events = events, enabled = enabled?.automaticMemoryEnabled != false) }
    } else {
      item(key = "search") {
        OutlinedTextField(
          value = query,
          onValueChange = { query = it },
          label = { Text(if (events) "Search events" else "Search learned information") },
          leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
          singleLine = true,
          keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
          modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        )
      }
      if (visible.isEmpty()) {
        item(key = "no-match") {
          Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
            Text("No matching memories", style = MaterialTheme.typography.titleMedium)
            Text("Try a different title or phrase.", color = MaterialTheme.colorScheme.onSurfaceVariant)
          }
        }
      }
      if (current.isNotEmpty()) {
        item(key = "current-header") { SectionHeader(if (events) "Events" else "Lasting information") }
        items(current, key = { it.id }) { topic ->
          LearnedTopicRow(
            topic = topic,
            onOpen = { onOpenTopic(topic.id) },
            onCorrect = { correcting = topic },
            onForget = { forgetting = topic },
            onEnabledChange = { setEnabled(topic, it) },
          )
        }
        item(key = "current-footer") {
          SectionFooter(
            if (events) {
              "Personal events keep their report dates and updates. Their relevance fades over time; they do not " +
                "become permanent facts, and a past event is never treated as proof it still applies."
            } else {
              "Learned topics are consolidated from your own messages instead of copying whole chats. Paused " +
                "topics are kept but never sent. Open a topic to see its exact sources and change history."
            },
          )
        }
      }
      if (forgotten.isNotEmpty()) {
        item(key = "forgotten-header") { SectionHeader("Forgotten") }
        items(forgotten, key = { "forgotten-" + it.id }) { topic ->
          LearnedTopicRow(
            topic = topic,
            onOpen = { onOpenTopic(topic.id) },
            onCorrect = { correcting = topic },
            onForget = {},
            onEnabledChange = { setEnabled(topic, it) },
          )
        }
        item(key = "forgotten-footer") {
          SectionFooter("Forgotten topics are never recalled or sent for later memory updates. Their audit trail stays here.")
        }
      }
    }
  }

  correcting?.let { topic ->
    CorrectTopicDialog(
      topic = topic,
      isSaving = isSaving,
      onDismiss = { correcting = null },
      onSave = { title, content ->
        isSaving = true
        scope.launch {
          scope.launchMemoryWrite(onError = { error = it }) { container.automaticMemory.correctTopic(topic, title, content) }
            .join()
          isSaving = false
          correcting = null
        }
      },
    )
  }
  forgetting?.let { topic ->
    ConfirmDialog(
      title = "Forget this learned topic?",
      message = "“${topic.title}” will stop being recalled. Its sources and change history will remain available, " +
        "and you can choose Remember again later.",
      confirmLabel = "Forget topic",
      onConfirm = {
        forgetting = null
        scope.launchMemoryWrite(onError = { error = it }) { container.automaticMemory.forgetTopic(topic) }
      },
      onDismiss = { forgetting = null },
    )
  }
  error?.let { MessageDialog("Memory couldn't be updated", it) { error = null } }
}

/** Formation requests, reported tokens, failures and the explicit (credit-using) retry. */
@Composable
internal fun MemoryActivityTab() {
  val container = LocalAppContainer.current
  val scope = rememberCoroutineScope()
  val activity by remember(container) { container.automaticMemory.observeActivity() }
    .collectAsStateWithLifecycle(initialValue = null)
  val isRetrying by container.automaticMemory.isRetryingFailedUpdates.collectAsStateWithLifecycle()
  var confirmRetry by remember { mutableStateOf(false) }
  var retryStatus by rememberSaveable { mutableStateOf<String?>(null) }
  var error by remember { mutableStateOf<String?>(null) }

  val data = activity
  if (data == null) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
    return
  }
  LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 32.dp)) {
    item(key = "switch") { AutomaticMemorySwitchCard() }
    item(key = "summary-header") { SectionHeader("Memory activity") }
    item(key = "summary") { ActivitySummary(data) }
    if (data.failedJobCount > 0 || isRetrying || retryStatus != null) {
      item(key = "retry") {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
          if (data.failedJobCount > 0 || isRetrying) {
            Button(
              onClick = { confirmRetry = true },
              enabled = !isRetrying,
              modifier = Modifier.heightIn(min = 48.dp),
            ) {
              if (isRetrying) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(8.dp))
                Text("Retrying memory updates…")
              } else {
                Icon(Icons.Outlined.Refresh, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text(if (data.failedJobCount == 1) "Retry 1 failed memory update" else "Retry ${formatCount(data.failedJobCount)} failed memory updates")
              }
            }
          }
          retryStatus?.let { StatusLine(it, StatusTone.NEUTRAL, Modifier.padding(horizontal = 0.dp)) }
        }
      }
    }
    item(key = "summary-footer") {
      SectionFooter(
        "A durable local receipt records each provider request and the tokens it reported, including failed " +
          "attempts and retries. An interrupted request is never repeated automatically; failed updates run " +
          "again only when you choose Retry.",
      )
    }
    item(key = "runs-header") { SectionHeader("Recent runs") }
    if (data.recentRuns.isEmpty()) {
      item(key = "runs-empty") {
        StatusLine("No automatic memory requests have been made yet.", StatusTone.NEUTRAL)
      }
    } else {
      items(data.recentRuns, key = { it.id }) { run -> FormationRunRow(run) }
    }
  }

  if (confirmRetry) {
    ConfirmDialog(
      title = if (data.failedJobCount == 1) "Retry 1 update?" else "Retry ${formatCount(data.failedJobCount)} updates?",
      message = "Turing AI will contact the AI service and model originally used for each chat. This may use " +
        "provider API credits.",
      confirmLabel = "Retry",
      destructive = false,
      onConfirm = {
        confirmRetry = false
        retryStatus = null
        scope.launch {
          try {
            retryStatus = retryDescription(container.automaticMemory.retryFailedUpdates())
          } catch (e: CancellationException) {
            throw e
          } catch (e: Exception) {
            error = "Turing AI couldn't load the failed memory updates. Try again."
          }
        }
      },
      onDismiss = { confirmRetry = false },
    )
  }
  error?.let { MessageDialog("Retry couldn't start", it) { error = null } }
}

@Composable
private fun ActivitySummary(activity: MemoryFormationActivity) {
  Column {
    ListItem(
      headlineContent = { Text("Provider requests") },
      trailingContent = { Text(formatCount(activity.totalProviderRequests), style = MaterialTheme.typography.bodyLarge) },
    )
    ListItem(
      headlineContent = { Text("Reported tokens") },
      supportingContent = {
        Text("${formatCount(activity.totalInputTokens)} input · ${formatCount(activity.totalOutputTokens)} output")
      },
      trailingContent = {
        Text(formatCount(activity.totalInputTokens + activity.totalOutputTokens), style = MaterialTheme.typography.bodyLarge)
      },
    )
    if (activity.unfinishedJobCount > 0) {
      ListItem(
        headlineContent = { Text("Waiting or running") },
        trailingContent = { Text(formatCount(activity.unfinishedJobCount), style = MaterialTheme.typography.bodyLarge) },
      )
    }
    if (activity.failedJobCount > 0) {
      ListItem(
        headlineContent = { Text("Failed updates") },
        supportingContent = { Text("Nothing was changed. Retry when you're ready.") },
        trailingContent = { Text(formatCount(activity.failedJobCount), style = MaterialTheme.typography.bodyLarge) },
      )
    }
  }
}

@Composable
private fun FormationRunRow(run: MemoryFormationRun) {
  val (icon, tint) = when (run.outcome) {
    MemoryFormationJobStatus.COMPLETE -> Icons.Outlined.CheckCircle to MaterialTheme.colorScheme.primary
    MemoryFormationJobStatus.FAILED -> Icons.Outlined.ErrorOutline to MaterialTheme.colorScheme.error
    MemoryFormationJobStatus.REJECTED -> Icons.Outlined.RemoveCircleOutline to MaterialTheme.colorScheme.onSurfaceVariant
    MemoryFormationJobStatus.GENERATING -> Icons.Outlined.HourglassEmpty to MaterialTheme.colorScheme.onSurfaceVariant
    MemoryFormationJobStatus.PENDING -> Icons.Outlined.Schedule to MaterialTheme.colorScheme.onSurfaceVariant
  }
  Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
    Row(verticalAlignment = Alignment.CenterVertically) {
      Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
      Spacer(Modifier.width(8.dp))
      Text(runStatusLabel(run.outcome), style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
      Text(formatRelativeTime(run.finishedAt), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    provenanceLine(run.providerName, run.modelId, run.providerHost)?.let {
      Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
    }
    Text(
      buildList {
        add("${formatCount(run.cumulativeTotalTokens)} tokens")
        add(pluralize(run.providerRequestCount, "request"))
        if (run.attemptCount > 1) add(pluralize(run.attemptCount, "attempt"))
      }.joinToString(" · "),
      style = MaterialTheme.typography.bodySmall,
      color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    if (run.didDiscardInvalidTelemetry) {
      Text(
        "Some provider usage data was invalid and omitted.",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
    run.errorDescription?.takeIf { it.isNotBlank() }?.let {
      Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 3)
    }
  }
  HorizontalDivider(Modifier.padding(start = 16.dp))
}

private fun retryDescription(outcome: MemoryRetryOutcome): String {
  if (outcome.completed == 0 && outcome.remaining == 0 && outcome.notApplied == 0) return "No failed memory updates remain."
  return buildList {
    if (outcome.completed > 0) add("Completed ${formatCount(outcome.completed)}.")
    if (outcome.remaining > 0) add("${formatCount(outcome.remaining)} still need attention.")
    if (outcome.notApplied > 0) add("${formatCount(outcome.notApplied)} can no longer be applied.")
  }.joinToString(" ")
}

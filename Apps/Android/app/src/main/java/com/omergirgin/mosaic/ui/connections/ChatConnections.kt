package com.omergirgin.mosaic.ui.connections

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.outlined.Hub
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.core.connections.ConnectionActionReceipt
import com.omergirgin.mosaic.core.connections.ConnectorException
import com.omergirgin.mosaic.data.connections.ConnectionActivity
import com.omergirgin.mosaic.data.connections.ConnectorReview
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.StatusLine
import com.omergirgin.mosaic.ui.settings.StatusTone
import java.net.URI
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** "Connections · On" while this chat (or the defaults it follows) has any service enabled. */
@Composable
fun rememberChatConnectionsActive(conversationId: String?): Boolean {
  val repository = LocalAppContainer.current.connections
  if (conversationId == null) return false
  val access by remember(repository, conversationId) { repository.observeChatAccess(conversationId) }
    .collectAsStateWithLifecycle(initialValue = null)
  return access?.selection?.bindings?.isNotEmpty() == true
}

/** Per-chat access (+ → Connections). Choices are device-only and bound to the connected account. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatConnectionsSheet(conversationId: String, providerName: String?, onDismiss: () -> Unit, onManage: () -> Unit) {
  val repository = LocalAppContainer.current.connections
  val scope = rememberCoroutineScope()
  val statuses by remember(repository) { repository.observeStatuses() }.collectAsStateWithLifecycle(initialValue = null)
  val access by remember(repository, conversationId) { repository.observeChatAccess(conversationId) }
    .collectAsStateWithLifecycle(initialValue = null)
  var error by remember { mutableStateOf<String?>(null) }
  val connected = statuses.orEmpty().filter { it.generation != null }
  val bindings = access?.selection?.bindings.orEmpty()
  // Turned on for an account that was since replaced or disconnected: never used silently.
  val stale = bindings.filter { (service, generation) -> connected.none { it.service == service && it.generation == generation && it.isConnected } }

  ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
      Text(
        "Connections",
        style = MaterialTheme.typography.titleLarge,
        modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp).semantics { heading() },
      )
      Text(
        "Use in this chat",
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
      )
      if (statuses != null && connected.isEmpty()) {
        Text(
          "No services are connected on this device yet.",
          style = MaterialTheme.typography.bodyMedium,
          modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
        )
      }
      for (status in connected) {
        val checked = bindings[status.service] == status.generation && status.isConnected
        ListItem(
          colors = ListItemDefaults.colors(containerColor = Color.Transparent),
          leadingContent = { Icon(status.service.icon, contentDescription = null) },
          headlineContent = { Text(status.service.title) },
          supportingContent = when {
            status.permissionNeeded -> ({ Text("Permission needed — open Manage connections") })
            !status.label.isNullOrBlank() && !status.service.isDevice -> ({ Text(status.label!!, maxLines = 1, overflow = TextOverflow.Ellipsis) })
            else -> null
          },
          trailingContent = { Switch(checked = checked, onCheckedChange = null, enabled = status.isConnected) },
          modifier = Modifier.heightIn(min = 56.dp).clickable(enabled = status.isConnected, role = Role.Switch) {
            scope.launch {
              runCatching { withContext(NonCancellable) { repository.setChatAccess(conversationId, status.service, !checked) } }
                .onFailure { error = (it as? ConnectorException)?.message ?: "The choice couldn't be saved." }
            }
          },
        )
      }
      if (stale.isNotEmpty()) {
        StatusLine(
          stale.keys.joinToString(", ") { it.title } + " was reconnected, disconnected or lost its permission. " +
            "Turn it on again to use the current account.",
          StatusTone.WARNING,
          Modifier.padding(horizontal = 8.dp),
        )
      }
      error?.let { StatusLine(it, StatusTone.ERROR, Modifier.padding(horizontal = 8.dp)) }
      Text(
        "When relevant to your message, Turing AI uses the enabled services directly from this device and sends " +
          "selected results to ${providerName ?: "this chat's AI provider"}. Changes always ask for your review first. " +
          "Planner and answer tokens count toward Usage & cost. These choices apply on this device." +
          if (access?.isCustom == true) " This chat has its own choices." else " This chat follows your defaults.",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
      )
      Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (access?.isCustom == true) {
          TextButton(onClick = { scope.launch { withContext(NonCancellable) { repository.resetChatAccess(conversationId) } } }) {
            Text("Use defaults")
          }
        }
        TextButton(onClick = onManage) { Text("Manage connections") }
      }
    }
  }
}

/** Shows the exact pending call for this chat. Dismissing declines; nothing is sent without "Allow once". */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectorReviewHost(conversationId: String?) {
  val repository = LocalAppContainer.current.connections
  val pending by repository.pendingReview.collectAsStateWithLifecycle()
  val review = pending?.takeIf { it.conversationId == conversationId } ?: return
  ModalBottomSheet(
    onDismissRequest = { repository.resolveReview(review.id, false) },
    sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
  ) {
    ReviewContent(
      review,
      onAllow = { repository.resolveReview(review.id, true) },
      onDecline = { repository.resolveReview(review.id, false) },
    )
  }
}

@Composable
private fun ReviewContent(review: ConnectorReview, onAllow: () -> Unit, onDecline: () -> Unit) {
  Column(
    Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(bottom = 24.dp),
    verticalArrangement = Arrangement.spacedBy(10.dp),
  ) {
    Text("Review action", style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
      Icon(review.service.icon, contentDescription = null)
      Column {
        Text(review.service.title, style = MaterialTheme.typography.titleMedium)
        Text(review.toolName.replace('_', ' '), style = MaterialTheme.typography.bodyMedium)
      }
    }
    Text(review.toolDescription, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    HorizontalDivider()
    Text("Request to review", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
    if (review.fields.isEmpty()) Text("No arguments.", style = MaterialTheme.typography.bodyMedium)
    SelectionContainer {
      Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for ((key, value) in review.fields) {
          Column {
            Text(key.replace('_', ' '), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(value, style = MaterialTheme.typography.bodyMedium)
          }
        }
      }
    }
    HorizontalDivider()
    Text(
      "Allow this exact request once. It may change data in your connected account. Check the target and content before continuing.",
      style = MaterialTheme.typography.bodySmall,
    )
    Button(onClick = onAllow, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("Allow once") }
    OutlinedButton(onClick = onDecline, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("Decline") }
  }
}

/**
 * Under an assistant reply: live progress while connected services are used, then a
 * "Connections" chip that opens the activity panel (coverage notice, sources, action receipts).
 */
@Composable
fun ConnectionActivityRow(messageId: String, streaming: Boolean, onOpenLink: (String) -> Unit) {
  val repository = LocalAppContainer.current.connections
  val progress by repository.progress.collectAsStateWithLifecycle()
  val activity by remember(repository, messageId) { repository.observeActivity(messageId) }
    .collectAsStateWithLifecycle(initialValue = null)
  var showing by rememberSaveable(messageId) { mutableStateOf(false) }
  val line = progress[messageId]
  if (streaming && line != null) {
    Row(
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(8.dp),
      modifier = Modifier.semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
    ) {
      CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
      Text(line, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
  }
  val current = activity ?: return
  AssistChip(
    onClick = { showing = true },
    label = { Text(chipLabel(current), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 260.dp)) },
    leadingIcon = { Icon(Icons.Outlined.Hub, contentDescription = null, modifier = Modifier.size(AssistChipDefaults.IconSize)) },
  )
  if (showing) ConnectionActivitySheet(current, onOpenLink) { showing = false }
}

private fun chipLabel(activity: ConnectionActivity): String {
  val parts = mutableListOf("Connections")
  if (activity.sources.isNotEmpty()) parts += "${activity.sources.size} source" + if (activity.sources.size == 1) "" else "s"
  if (activity.receipts.isNotEmpty()) parts += "${activity.receipts.size} action" + if (activity.receipts.size == 1) "" else "s"
  if (activity.sources.isEmpty() && activity.receipts.isEmpty()) parts += "Details"
  return parts.joinToString(" · ")
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConnectionActivitySheet(activity: ConnectionActivity, onOpenLink: (String) -> Unit, onDismiss: () -> Unit) {
  ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
    Column(
      Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(bottom = 24.dp).navigationBarsPadding(),
      verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
      Text("Connected services", style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
      // The coverage notice already names the services used; fall back to the list without one.
      val notice = activity.notice
      if (notice != null) {
        Text(notice, style = MaterialTheme.typography.bodyMedium)
      } else if (activity.services.isNotEmpty()) {
        Text("Used " + activity.services.joinToString(", ") { it.title } + ".", style = MaterialTheme.typography.bodyMedium)
      }
      if (activity.receipts.isNotEmpty()) {
        HorizontalDivider()
        Text("Actions", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
        for (receipt in activity.receipts) ReceiptRow(receipt)
      }
      HorizontalDivider()
      Text("Sources", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
      if (activity.sources.isEmpty()) {
        Text(
          "No public links were returned. Device calendar and contact items have no web link.",
          style = MaterialTheme.typography.bodySmall,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
      }
      for (source in activity.sources) {
        val host = runCatching { URI(source.url).host }.getOrNull()?.removePrefix("www.")
        val openable = source.url.startsWith("https://", true) || source.url.startsWith("http://", true)
        ListItem(
          colors = ListItemDefaults.colors(containerColor = Color.Transparent),
          headlineContent = { Text(source.title?.takeIf { it.isNotBlank() } ?: host ?: source.url, maxLines = 2, overflow = TextOverflow.Ellipsis) },
          supportingContent = host?.let { { Text(it) } },
          trailingContent = if (openable) ({ Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = "Opens in browser") }) else null,
          modifier = Modifier.heightIn(min = 48.dp).clickable(enabled = openable, role = Role.Button) { onOpenLink(source.url) },
        )
      }
    }
  }
}

@Composable
private fun ReceiptRow(receipt: ConnectionActionReceipt) {
  var expanded by rememberSaveable(receipt.id) { mutableStateOf(false) }
  val tone = when (receipt.outcome) {
    ConnectionActionReceipt.Outcome.SUCCEEDED -> StatusTone.SUCCESS
    ConnectionActionReceipt.Outcome.FAILED -> StatusTone.ERROR
    ConnectionActionReceipt.Outcome.DECLINED -> StatusTone.NEUTRAL
    ConnectionActionReceipt.Outcome.STARTED, ConnectionActionReceipt.Outcome.UNCERTAIN -> StatusTone.WARNING
  }
  Column(Modifier.fillMaxWidth().clickable(role = Role.Button) { expanded = !expanded }.padding(vertical = 4.dp)) {
    Text("${receipt.service.title} · ${receipt.tool.replace('_', ' ')}", style = MaterialTheme.typography.bodyMedium)
    StatusLine(receipt.statusTitle, tone, Modifier.padding(start = 0.dp))
    Text(receipt.summary, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (expanded) {
      SelectionContainer {
        Text(
          receipt.arguments.toString(),
          style = MaterialTheme.typography.bodySmall,
          modifier = Modifier.padding(top = 4.dp),
        )
      }
    } else {
      Text("Show request", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
    }
  }
}

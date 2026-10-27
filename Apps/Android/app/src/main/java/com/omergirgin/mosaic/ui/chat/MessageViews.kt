package com.omergirgin.mosaic.ui.chat

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.outlined.BookmarkAdd
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.automirrored.outlined.FactCheck
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.StopCircle
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.automirrored.outlined.AltRoute
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.chat.WebSource
import com.omergirgin.mosaic.data.model.Attachment
import com.omergirgin.mosaic.data.model.ContextReceipt
import com.omergirgin.mosaic.data.model.MemoryScope
import com.omergirgin.mosaic.data.model.Message
import com.omergirgin.mosaic.data.model.MessageStatus
import com.omergirgin.mosaic.ui.connections.ConnectionActivityRow
import java.net.URI
import java.text.NumberFormat

private const val ATTACHED_DOCUMENT_MARKER = "\n\n[Attached document content]\n"
private const val ATTACHED_PHOTO_MARKER = "\n\n[Attached photo SHA256:"

/**
 * Text a person typed, without the attachment payload iOS appends to user content (relevant for
 * chats restored from an iOS backup); Android keeps attachments separate already.
 */
internal fun displayText(content: String): String {
  val document = content.indexOf(ATTACHED_DOCUMENT_MARKER).takeIf { it >= 0 } ?: content.length
  val photo = content.indexOf(ATTACHED_PHOTO_MARKER).takeIf { it >= 0 } ?: content.length
  return content.substring(0, minOf(document, photo))
}

/** Actions shared by user and assistant rows. */
class MessageActions(
  /** Project of the open chat, offered as a memory audience when present. */
  val projectName: String?,
  val onCopy: (Message) -> Unit,
  val onSaveToMemory: (Message, MemoryScope) -> Unit,
  val onDelete: (Message) -> Unit,
  val onOpenAttachment: (Attachment) -> Unit,
  val onShowReceipt: (ContextReceipt) -> Unit,
  val onOpenLink: (String) -> Unit,
  /** "Edit" on a sent message: continue from it in a new alternative (null hides the action). */
  val onEdit: ((Message) -> Unit)? = null,
  /** "Ask another model" on a response: its question in a new alternative (null hides the action). */
  val onAskAnotherModel: ((Message) -> Unit)? = null,
)

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun UserMessageRow(message: Message, actions: MessageActions, actionsEnabled: Boolean) {
  var menuOpen by rememberSaveable(message.id) { mutableStateOf(false) }
  val text = displayText(message.content).trim()
  // Leave a gutter on the start side so user turns read as "mine" (iOS Spacer(minLength: 44)).
  Box(Modifier.fillMaxWidth().padding(start = 48.dp), contentAlignment = Alignment.CenterEnd) {
    Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
      if (message.attachments.isNotEmpty()) {
        SentAttachments(message.attachments, onOpen = actions.onOpenAttachment)
      }
      if (text.isNotEmpty()) {
        Box {
          Surface(
            shape = RoundedCornerShape(20.dp),
            color = MaterialTheme.colorScheme.primaryContainer,
            contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
            modifier = Modifier
              .clip(RoundedCornerShape(20.dp))
              .combinedClickable(
                onClickLabel = "Message actions",
                onLongClickLabel = "Message actions",
                onLongClick = { menuOpen = true },
                onClick = { menuOpen = true },
              ),
          ) {
            Text(
              text,
              style = MaterialTheme.typography.bodyLarge,
              modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            )
          }
          MessageMenu(
            expanded = menuOpen,
            onDismiss = { menuOpen = false },
            message = message,
            actions = actions,
            actionsEnabled = actionsEnabled,
            receipt = null,
          )
        }
      }
    }
  }
}

@Composable
fun AssistantMessageRow(
  item: TranscriptItem.Assistant,
  displayed: Message,
  canRetry: Boolean,
  advancedControls: Boolean,
  actionsEnabled: Boolean,
  actions: MessageActions,
  onSelectAttempt: (String) -> Unit,
  onRetry: () -> Unit,
) {
  val attemptIndex = item.attempts.indexOfFirst { it.id == displayed.id }.coerceAtLeast(0)
  val content = displayed.content
  val streaming = displayed.status == MessageStatus.STREAMING

  Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
    if (item.attempts.size > 1) {
      AttemptSwitcher(
        index = attemptIndex,
        count = item.attempts.size,
        onPrevious = { onSelectAttempt(item.attempts[attemptIndex - 1].id) },
        onNext = { onSelectAttempt(item.attempts[attemptIndex + 1].id) },
      )
    }

    if (content.isEmpty() && streaming) {
      StreamingIndicator("Thinking…")
    } else if (content.isNotEmpty()) {
      SelectionContainer { ChatMarkdown(content, Modifier.fillMaxWidth()) }
      if (streaming) StreamingIndicator("Generating…")
    }

    when (displayed.status) {
      MessageStatus.CANCELLED -> Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
      ) {
        Icon(Icons.Outlined.StopCircle, contentDescription = null, modifier = Modifier.size(18.dp))
        Text("Stopped", style = MaterialTheme.typography.labelLarge)
      }
      MessageStatus.FAILED -> FailureCard(displayed.errorMessage, canRetry, onRetry)
      else -> Unit
    }

    // Connected services: live progress, then the activity chip (sources, coverage, action receipts).
    ConnectionActivityRow(displayed.id, streaming, actions.onOpenLink)

    if (displayed.citations.isNotEmpty()) {
      Citations(displayed.citations, actions.onOpenLink)
    }

    if (!streaming) {
      AssistantActionRow(
        message = displayed,
        advancedControls = advancedControls,
        actionsEnabled = actionsEnabled,
        actions = actions,
        // Failed rows already offer "Try again" in their card.
        canRetry = canRetry && displayed.status != MessageStatus.FAILED,
        onRetry = onRetry,
      )
    }
  }
}

@Composable
private fun StreamingIndicator(label: String) {
  Row(
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(8.dp),
    modifier = Modifier.semantics(mergeDescendants = true) {
      liveRegion = LiveRegionMode.Polite
    },
  ) {
    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
    Text(label, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
  }
}

@Composable
private fun AttemptSwitcher(index: Int, count: Int, onPrevious: () -> Unit, onNext: () -> Unit) {
  Row(verticalAlignment = Alignment.CenterVertically) {
    IconButton(onClick = onPrevious, enabled = index > 0) {
      Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, contentDescription = "Previous attempt")
    }
    Text(
      "Attempt ${index + 1} of $count",
      style = MaterialTheme.typography.labelLarge,
      color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    IconButton(onClick = onNext, enabled = index < count - 1) {
      Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = "Next attempt")
    }
  }
}

@Composable
private fun FailureCard(error: String?, canRetry: Boolean, onRetry: () -> Unit) {
  Surface(
    color = MaterialTheme.colorScheme.errorContainer,
    contentColor = MaterialTheme.colorScheme.onErrorContainer,
    shape = RoundedCornerShape(16.dp),
    modifier = Modifier.fillMaxWidth(),
  ) {
    Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
      Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(Icons.Outlined.ErrorOutline, contentDescription = null)
        Text("Response failed", style = MaterialTheme.typography.titleSmall)
      }
      if (!error.isNullOrBlank()) {
        Text(error, style = MaterialTheme.typography.bodyMedium)
      }
      if (canRetry) {
        FilledTonalButton(onClick = onRetry, modifier = Modifier.heightIn(min = 48.dp)) {
          Icon(Icons.Filled.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
          Text("Try again", modifier = Modifier.padding(start = 8.dp))
        }
      }
    }
  }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Citations(sources: List<WebSource>, onOpen: (String) -> Unit) {
  // Only web links are opened; anything else from a provider is shown but inert.
  val links = sources.distinctBy { it.url }
  Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
    Text("Sources", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
      for (source in links) {
        val host = runCatching { URI(source.url).host }.getOrNull()?.removePrefix("www.")
        val openable = source.url.startsWith("https://", true) || source.url.startsWith("http://", true)
        val label = source.title?.takeIf { it.isNotBlank() } ?: host ?: source.url
        AssistChip(
          onClick = { if (openable) onOpen(source.url) },
          enabled = openable,
          label = { Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 220.dp)) },
          leadingIcon = { Icon(Icons.Outlined.Link, contentDescription = null, modifier = Modifier.size(AssistChipDefaults.IconSize)) },
          modifier = Modifier.semantics { contentDescription = "Source: $label${host?.let { ", $it" }.orEmpty()}" },
        )
      }
    }
  }
}

@Composable
private fun AssistantActionRow(
  message: Message,
  advancedControls: Boolean,
  actionsEnabled: Boolean,
  actions: MessageActions,
  canRetry: Boolean,
  onRetry: () -> Unit,
) {
  var menuOpen by rememberSaveable(message.id) { mutableStateOf(false) }
  var memoryMenuOpen by rememberSaveable(message.id) { mutableStateOf(false) }
  var detailsOpen by rememberSaveable(message.id) { mutableStateOf(false) }
  val provenance = listOfNotNull(message.providerName, message.modelId, message.destinationHost)
    .filter { it.isNotBlank() }
    .joinToString(" · ")
  val tokens = tokenSummary(message.inputTokens, message.outputTokens)
  val hasDetails = provenance.isNotEmpty() || tokens != null || message.receipt != null

  Column {
    Row(verticalAlignment = Alignment.CenterVertically) {
      if (message.content.isNotEmpty()) {
        IconButton(onClick = { actions.onCopy(message) }) {
          Icon(Icons.Outlined.ContentCopy, contentDescription = "Copy response", tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Box {
          IconButton(onClick = { memoryMenuOpen = true }, enabled = actionsEnabled) {
            Icon(Icons.Outlined.BookmarkAdd, contentDescription = "Save to memory", tint = MaterialTheme.colorScheme.onSurfaceVariant)
          }
          DropdownMenu(expanded = memoryMenuOpen, onDismissRequest = { memoryMenuOpen = false }) {
            MemoryScopeItems(actions.projectName) { scope ->
              memoryMenuOpen = false
              actions.onSaveToMemory(message, scope)
            }
          }
        }
      }
      if (canRetry) {
        IconButton(onClick = onRetry) {
          Icon(Icons.Filled.Refresh, contentDescription = "Retry response", tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
      }
      Box {
        IconButton(onClick = { menuOpen = true }) {
          Icon(Icons.Filled.MoreVert, contentDescription = "More response actions", tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        MessageMenu(
          expanded = menuOpen,
          onDismiss = { menuOpen = false },
          message = message,
          actions = actions,
          actionsEnabled = actionsEnabled,
          receipt = message.receipt,
        )
      }
      if (hasDetails && !advancedControls) {
        TextButton(onClick = { detailsOpen = !detailsOpen }) {
          Text("Response details")
          Icon(
            if (detailsOpen) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
            contentDescription = null,
            modifier = Modifier.padding(start = 4.dp).size(18.dp),
          )
        }
      }
    }
    // Simple view collapses provenance and token counts; advanced view always shows them.
    AnimatedVisibility(visible = hasDetails && (advancedControls || detailsOpen)) {
      ResponseDetails(message, provenance, tokens, actions.onShowReceipt)
    }
  }
}

@Composable
private fun ResponseDetails(
  message: Message,
  provenance: String,
  tokens: String?,
  onShowReceipt: (ContextReceipt) -> Unit,
) {
  Column(
    verticalArrangement = Arrangement.spacedBy(6.dp),
    modifier = Modifier.padding(start = 12.dp, bottom = 4.dp),
  ) {
    if (provenance.isNotEmpty()) {
      Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.clearAndSetSemantics { contentDescription = "Generated by $provenance" },
      ) {
        val kind = message.providerKind
        if (kind != null) {
          DecorativeProviderLogo(kind = kind, size = 20.dp)
        } else {
          Icon(Icons.Outlined.Dns, contentDescription = null, modifier = Modifier.size(20.dp))
        }
        Text(provenance, style = MaterialTheme.typography.bodySmall)
      }
    }
    if (tokens != null) {
      Text(tokens, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    message.receipt?.let { receipt ->
      TextButton(onClick = { onShowReceipt(receipt) }, modifier = Modifier.heightIn(min = 48.dp)) {
        Icon(Icons.AutoMirrored.Outlined.FactCheck, contentDescription = null, modifier = Modifier.size(18.dp))
        Text("What was sent", modifier = Modifier.padding(start = 8.dp))
      }
    }
  }
}

private fun tokenSummary(input: Int?, output: Int?): String? {
  val format = NumberFormat.getIntegerInstance()
  return when {
    input != null && output != null -> "${format.format(input)} input · ${format.format(output)} output tokens"
    input != null -> "${format.format(input)} input tokens"
    output != null -> "${format.format(output)} output tokens"
    else -> null
  }
}

@Composable
private fun MessageMenu(
  expanded: Boolean,
  onDismiss: () -> Unit,
  message: Message,
  actions: MessageActions,
  actionsEnabled: Boolean,
  receipt: ContextReceipt?,
) {
  // "Save to memory" swaps the menu to its audience choices instead of nesting a submenu.
  var choosingScope by remember(expanded) { mutableStateOf(false) }
  DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
    if (choosingScope) {
      MemoryScopeItems(actions.projectName) { scope ->
        onDismiss()
        actions.onSaveToMemory(message, scope)
      }
      return@DropdownMenu
    }
    if (message.content.isNotEmpty()) {
      DropdownMenuItem(
        text = { Text("Copy") },
        leadingIcon = { Icon(Icons.Outlined.ContentCopy, contentDescription = null) },
        onClick = {
          onDismiss()
          actions.onCopy(message)
        },
      )
      DropdownMenuItem(
        text = { Text("Save to memory") },
        leadingIcon = { Icon(Icons.Outlined.BookmarkAdd, contentDescription = null) },
        enabled = actionsEnabled,
        onClick = { choosingScope = true },
      )
    }
    // Edit & branch: the original chat stays intact; a new alternative opens as a draft.
    val edit = actions.onEdit
    if (edit != null && message.role == ChatRole.USER) {
      DropdownMenuItem(
        text = { Text("Edit") },
        leadingIcon = { Icon(Icons.Outlined.Edit, contentDescription = null) },
        enabled = actionsEnabled,
        onClick = {
          onDismiss()
          edit(message)
        },
      )
    }
    val askAnotherModel = actions.onAskAnotherModel
    if (askAnotherModel != null && message.role == ChatRole.ASSISTANT) {
      DropdownMenuItem(
        text = { Text("Ask another model") },
        leadingIcon = { Icon(Icons.AutoMirrored.Outlined.AltRoute, contentDescription = null) },
        enabled = actionsEnabled,
        onClick = {
          onDismiss()
          askAnotherModel(message)
        },
      )
    }
    if (receipt != null) {
      DropdownMenuItem(
        text = { Text("What was sent") },
        leadingIcon = { Icon(Icons.AutoMirrored.Outlined.FactCheck, contentDescription = null) },
        onClick = {
          onDismiss()
          actions.onShowReceipt(receipt)
        },
      )
    }
    HorizontalDivider()
    DropdownMenuItem(
      text = { Text("Delete", color = MaterialTheme.colorScheme.error) },
      leadingIcon = { Icon(Icons.Outlined.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
      enabled = actionsEnabled,
      onClick = {
        onDismiss()
        actions.onDelete(message)
      },
    )
  }
}

/** Empty-chat starter (iOS `ConversationStarter`): title plus prompts that fill the draft. */
@Composable
fun ConversationStarter(showSuggestions: Boolean, onSuggestion: (String) -> Unit, modifier: Modifier = Modifier) {
  Column(
    horizontalAlignment = Alignment.CenterHorizontally,
    verticalArrangement = Arrangement.spacedBy(24.dp),
    modifier = modifier.padding(24.dp),
  ) {
    Text(
      "How can I help?",
      style = MaterialTheme.typography.headlineMedium,
      modifier = Modifier.semantics { heading() },
    )
    if (showSuggestions) {
      Column(
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.widthIn(max = 360.dp),
      ) {
        for (suggestion in listOf("Help me plan this week", "Summarize an idea clearly", "Compare two approaches")) {
          Surface(
            onClick = { onSuggestion(suggestion) },
            shape = RoundedCornerShape(16.dp),
            color = MaterialTheme.colorScheme.surfaceContainer,
            modifier = Modifier.fillMaxWidth(),
          ) {
            Text(
              suggestion,
              style = MaterialTheme.typography.bodyLarge,
              modifier = Modifier.heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 14.dp),
            )
          }
        }
      }
    }
  }
}

/** Memory audiences, as on iOS: everywhere, the chat's project (when it has one), or this chat. */
@Composable
private fun MemoryScopeItems(projectName: String?, onChoose: (MemoryScope) -> Unit) {
  Text(
    "Remember for",
    style = MaterialTheme.typography.labelMedium,
    color = MaterialTheme.colorScheme.onSurfaceVariant,
    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp).semantics { heading() },
  )
  DropdownMenuItem(
    text = { Text("All chats") },
    leadingIcon = { Icon(Icons.Outlined.Public, contentDescription = null) },
    onClick = { onChoose(MemoryScope.EVERYWHERE) },
  )
  if (projectName != null) {
    DropdownMenuItem(
      text = { Text("Project: $projectName", maxLines = 1, overflow = TextOverflow.Ellipsis) },
      leadingIcon = { Icon(Icons.Outlined.Folder, contentDescription = null) },
      onClick = { onChoose(MemoryScope.PROJECT) },
    )
  }
  DropdownMenuItem(
    text = { Text("This chat") },
    leadingIcon = { Icon(Icons.AutoMirrored.Outlined.Chat, contentDescription = null) },
    onClick = { onChoose(MemoryScope.CONVERSATION) },
  )
}

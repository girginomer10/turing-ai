package com.omergirgin.mosaic.ui.chat

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.data.model.ContextReceipt
import com.omergirgin.mosaic.data.model.ConversationSummaryReceipt
import com.omergirgin.mosaic.data.model.Message
import com.omergirgin.mosaic.data.model.SameChatRecallOrigin
import com.omergirgin.mosaic.data.model.SummaryStatus
import com.omergirgin.mosaic.data.recall.RecallSourceKind
import com.omergirgin.mosaic.data.recall.RecalledItem
import com.omergirgin.mosaic.data.recall.SmartRankingStatus
import java.text.DateFormat
import java.text.NumberFormat
import java.time.Instant
import java.util.Date

/** Message previews are revealed in pages so a very long chat never builds thousands of rows at once. */
private const val PREVIEW_PAGE = 50

/**
 * "What was sent" for one answer (DESIGN.md AI transparency; iOS `MemoryContextSheet`): project
 * instructions, the rolling history summary, raw/summarized/recalled/omitted turns with
 * inspectable previews, exact same-chat excerpts, pinned facts, recalled memory topics, earlier
 * chats and document passages, the smart-memory relevance check, retrieval engines, embedding
 * destinations and every fallback.
 *
 * Simple view collapses provider provenance and token figures under "Technical details"; advanced
 * controls show them inline. Both views keep every item inspectable.
 *
 * [messages] are the chat's loaded messages; referenced IDs that no longer resolve (deleted turns)
 * keep their exact counts and are disclosed as unavailable.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContextReceiptSheet(
  receipt: ContextReceipt,
  messages: List<Message> = emptyList(),
  advancedControls: Boolean = false,
  onDismiss: () -> Unit,
) {
  val byId = remember(messages) { messages.associateBy { it.id } }
  // List key -> number of previews revealed (absent = collapsed).
  val revealed = remember(receipt) { mutableStateMapOf<String, Int>() }
  val recall = receipt.recall
  val summary = receipt.summary
  val recalledIds = remember(receipt) { receipt.sameChatExcerpts.map { it.messageId }.distinct() }
  val included = receipt.includedMessageIds
  val summarized = receipt.summarizedMessageIds
  val omitted = receipt.omittedMessageIds
  val referenced = remember(receipt) { (included + summarized + omitted + recalledIds).toSet() }
  val unresolved = referenced.count { it !in byId }

  ModalBottomSheet(
    onDismissRequest = onDismiss,
    sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
  ) {
    LazyColumn(
      modifier = Modifier.fillMaxWidth().navigationBarsPadding(),
      contentPadding = PaddingValues(start = 24.dp, end = 24.dp, bottom = 24.dp),
      verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
      item(key = "header") {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(bottom = 8.dp)) {
          Text("What was sent", style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
          Text(
            "The context Turing AI included with this request to the provider. Recalled text was sent as " +
              "reference data, not as instructions.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
          )
        }
      }

      if (receipt.warnings.isNotEmpty()) {
        item(key = "warnings") {
          Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(bottom = 8.dp)) {
            receipt.warnings.forEach { NoticeRow(it, warning = true) }
          }
        }
      }

      // Project ---------------------------------------------------------------------------------
      receipt.projectName?.let { project ->
        section("project", "Project context") {
          IconLine(Icons.Outlined.Folder, project)
          val instructions = receipt.projectInstructions?.takeIf { it.isNotBlank() }
          if (instructions == null) {
            SecondaryText("No project instructions were included.")
          } else {
            Caption("Instructions sent")
            ExpandableQuote(instructions)
          }
        }
      }

      // Rolling summary -------------------------------------------------------------------------
      if (summary != null && summary.status != SummaryStatus.NONE) {
        section("summary", "History summary") {
          LabeledValue("Status", summaryStatusLabel(summary))
          LabeledValue("Extra model requests", formatInt(summary.extraRequestCount))
          TechnicalDetails("summary", advancedControls, label = "Summary model and usage") { SummaryProvenance(summary) }
          summary.text?.takeIf { it.isNotBlank() }?.let {
            Caption(if (summary.status == SummaryStatus.FAILED || summary.status == SummaryStatus.CANCELLED) "Previous summary sent" else "Readable summary sent")
            ExpandableQuote(it)
          }
          summary.error?.let { NoticeRow(it, warning = true) }
        }
      }

      // Conversation history ------------------------------------------------------------------------
      section("history", "Conversation history") {
        val total = included.size + summarized.size + omitted.size
        LabeledValue("Included", "${formatInt(included.size)} raw of ${formatInt(total)} ${if (total == 1) "message" else "messages"}")
        if (summarized.isNotEmpty()) LabeledValue("Represented by summary", formatInt(summarized.size))
        if (recalledIds.isNotEmpty()) LabeledValue("Recalled exactly", formatInt(recalledIds.size))
        if (omitted.isNotEmpty()) LabeledValue("Not sent", formatInt(omitted.size))
        Text(
          when {
            summarized.isNotEmpty() ->
              "${formatInt(summarized.size)} older ${plural(summarized.size, "message was", "messages were")} represented " +
                "by the readable summary; ${formatInt(omitted.size)} remained unsummarized for this request."
            omitted.isNotEmpty() ->
              "${formatInt(omitted.size)} older ${plural(omitted.size, "message", "messages")} stayed in this chat but " +
                "${if (omitted.size == 1) "was" else "were"} not sent or summarized for this request."
            else -> "The complete chat history fit this request."
          },
          style = MaterialTheme.typography.bodyMedium,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        TechnicalDetails("size", advancedControls, label = "Request size estimate") { SizeEstimate(receipt) }
      }
      messageList("included", "Included messages", included, byId, revealed)
      messageList("summarized", "Summarized older messages", summarized, byId, revealed)
      messageList("recalled", "Exactly recalled older messages", recalledIds, byId, revealed)
      messageList("omitted", "Older messages not sent", omitted, byId, revealed)
      if (unresolved > 0) {
        item(key = "unresolved") {
          NoticeRow(
            "${formatInt(unresolved)} referenced ${plural(unresolved, "message is", "messages are")} no longer in this " +
              "chat, so ${if (unresolved == 1) "it" else "they"} can't be previewed. The counts above stay exact.",
            warning = false,
          )
        }
      }

      // Same-chat exact excerpts --------------------------------------------------------------------
      if (receipt.sameChatExcerpts.isNotEmpty()) {
        section("same-chat", "Recalled from this chat") {
          SecondaryText("Exact earlier words from this chat, attached because they matched your message.")
        }
        items(receipt.sameChatExcerpts, key = { "excerpt-${it.messageId}-${it.createdAt}" }) { excerpt ->
          ItemCard {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
              Badge(if (excerpt.origin == SameChatRecallOrigin.SUMMARIZED) "Summary source" else "Omitted source")
              if (excerpt.isTruncated) Badge("Excerpt", description = "Truncated exact excerpt")
            }
            ExpandableText(excerpt.text)
            Caption(formatDate(excerpt.createdAt))
          }
        }
      }

      // Pinned facts ----------------------------------------------------------------------------
      if (receipt.pinnedFacts.isNotEmpty()) {
        section("pinned", "Pinned memory") {
          receipt.pinnedFacts.forEach { fact ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
              Text("•", style = MaterialTheme.typography.bodyLarge)
              Text(fact, style = MaterialTheme.typography.bodyLarge)
            }
          }
        }
      }

      // Smart recall ----------------------------------------------------------------------------
      if (recall != null && recall.items.isNotEmpty()) {
        section("recalled", "Automatically recalled") {
          SecondaryText("Learned memory, earlier chats and document passages ranked as relevant to your message.")
        }
        items(recall.items, key = { "recall-${it.kind.rawValue}-${it.id}" }) { RecalledItemCard(it) }
      }
      if (recall != null && recall.embeddingDestinations.isNotEmpty()) {
        section("destinations", "Embedding destinations") {
          SecondaryText("Your message and candidate excerpts were sent here to compare meaning.")
          recall.embeddingDestinations.forEach { destination ->
            Column(Modifier.padding(vertical = 2.dp)) {
              Text(destination.profileName, style = MaterialTheme.typography.bodyLarge)
              SecondaryText(listOfNotNull(destination.providerName, destination.host, destination.modelId).joinToString(" · "))
            }
          }
        }
      }
      recall?.smartRanking?.let { smart ->
        section("smart-memory", "Smart memory") {
          LabeledValue(
            "Status",
            if (smart.status == SmartRankingStatus.USED) "Ranked recall with the selected chat model"
            else "Unavailable; used local matching or enabled embeddings",
          )
          LabeledValue("Model", smart.modelId)
          LabeledValue("Destination", listOfNotNull(smart.providerName, smart.host).joinToString(" · "))
          LabeledValue("Short excerpts sent", formatInt(smart.candidateCount))
          if (smart.status == SmartRankingStatus.USED) LabeledValue("Selected", formatInt(smart.selectedCount))
          if (smart.inputTokens != null || smart.outputTokens != null) {
            LabeledValue(
              "Usage",
              "${smart.inputTokens?.let(::formatInt) ?: "—"} input · ${smart.outputTokens?.let(::formatInt) ?: "—"} output",
            )
          } else {
            NoticeRow("Token usage was not reported. The relevance check may still incur provider charges.", warning = false)
          }
        }
      }
      if (recall != null && recall.engines.isNotEmpty()) {
        if (advancedControls) {
          section("engines", "Retrieval engines") { recall.engines.forEach { SecondaryText(it) } }
        } else {
          item(key = "engines") {
            Column(Modifier.padding(top = 8.dp)) {
              TechnicalDetails("engines", advancedControls = false, label = "Retrieval engines (${formatInt(recall.engines.size)})") {
                recall.engines.forEach { SecondaryText(it) }
              }
            }
          }
        }
      }
      if (recall != null && recall.warnings.isNotEmpty()) {
        section("fallbacks", "Fallbacks") {
          recall.warnings.forEach { NoticeRow(it, warning = true) }
        }
      }
    }
  }
}

// region sections

private fun LazyListScope.section(key: String, title: String, content: @Composable () -> Unit) {
  item(key = "section-$key") {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(top = 14.dp)) {
      Text(
        title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.semantics { heading() },
      )
      content()
    }
  }
}

/** Collapsible list of message previews, revealed [PREVIEW_PAGE] rows at a time. */
private fun LazyListScope.messageList(
  key: String,
  title: String,
  ids: List<String>,
  byId: Map<String, Message>,
  revealed: MutableMap<String, Int>,
) {
  if (ids.isEmpty()) return
  val shown = revealed[key] ?: 0
  item(key = "list-$key") {
    val expanded = shown > 0
    DisclosureRow("$title (${formatInt(ids.size)})", expanded) {
      if (expanded) revealed.remove(key) else revealed[key] = PREVIEW_PAGE
    }
  }
  if (shown == 0) return
  val page = ids.take(shown)
  items(page, key = { "msg-$key-$it" }) { id ->
    val message = byId[id]
    if (message != null) MessagePreview(message) else SecondaryText("This message is no longer in the chat.")
  }
  if (ids.size > shown) {
    item(key = "more-$key") {
      TextButton(onClick = { revealed[key] = shown + PREVIEW_PAGE }, modifier = Modifier.heightIn(min = 48.dp)) {
        Text("Show ${formatInt(minOf(PREVIEW_PAGE, ids.size - shown))} more")
      }
    }
  }
}

// endregion

// region rows

@Composable
private fun SummaryProvenance(summary: ConversationSummaryReceipt) {
  val attempted = summary.status == SummaryStatus.FAILED || summary.status == SummaryStatus.CANCELLED
  val model = listOfNotNull(summary.providerName, summary.modelId).joinToString(" · ")
  if (model.isNotEmpty()) {
    LabeledValue(if (attempted) "Retained summary model" else "Summary model", model)
  }
  summary.host?.let { LabeledValue(if (attempted) "Retained summary destination" else "Destination", it) }
  if (summary.inputTokens != null || summary.outputTokens != null) {
    LabeledValue(
      if (summary.status == SummaryStatus.REUSED) "Original summary usage" else "Summary request usage",
      "${summary.inputTokens?.let(::formatInt) ?: "—"} input · ${summary.outputTokens?.let(::formatInt) ?: "—"} output",
    )
  } else if (summary.extraRequestCount > 0) {
    NoticeRow("The provider did not report token usage for the extra request. It may still incur provider charges.", warning = false)
  }
  summary.summaryCreatedAt?.let { LabeledValue("Summary created", formatDateTime(it)) }
}

@Composable
private fun SizeEstimate(receipt: ContextReceipt) {
  val budget = receipt.inputBudgetTokens
  val estimate = receipt.estimatedInputTokens
  LabeledValue(
    "Estimated input",
    if (budget > 0) "${formatInt(estimate)} of ${formatInt(budget)} tokens" else "${formatInt(estimate)} tokens",
  )
  if (budget > 0) {
    LinearProgressIndicator(
      progress = { (estimate.toFloat() / budget).coerceIn(0f, 1f) },
      modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    )
  }
  Caption("An estimate made on this device; the provider's own count may differ.")
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun RecalledItemCard(item: RecalledItem) {
  ItemCard {
    val (label, icon) = when (item.kind) {
      RecallSourceKind.MEMORY_TOPIC -> "Memory topic" to Icons.Outlined.Psychology
      RecallSourceKind.CONVERSATION_MESSAGE -> "Earlier chat" to Icons.Outlined.Forum
      RecallSourceKind.DOCUMENT_CHUNK -> "Document" to Icons.Outlined.Description
    }
    FlowRow(
      horizontalArrangement = Arrangement.spacedBy(8.dp),
      verticalArrangement = Arrangement.spacedBy(4.dp),
      itemVerticalAlignment = Alignment.CenterVertically,
    ) {
      Badge(label, icon = icon)
      item.pageNumber?.let { Badge("Page $it") }
      if (item.isOcrDerived) Badge("OCR", description = "Extracted with on-device text recognition")
      if (item.isEvent) Badge("Event", description = "Dated personal report")
    }
    if (item.title.isNotBlank()) {
      Text(item.title, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
    ExpandableText(item.excerpt)
    val reported = item.recordedAt?.let(::parseInstant)
    Caption(
      if (item.isEvent && reported != null) "Reported on ${formatDate(reported)}"
      else formatDate(item.createdAt),
    )
  }
}

@Composable
private fun MessagePreview(message: Message) {
  var expanded by rememberSaveable(message.id) { mutableStateOf(false) }
  val text = if (message.role == ChatRole.USER) displayText(message.content).trim() else message.content.trim()
  val attachments = message.attachments.size
  Column(
    verticalArrangement = Arrangement.spacedBy(2.dp),
    modifier = Modifier
      .fillMaxWidth()
      .clickable(onClickLabel = if (expanded) "Show less" else "Show the whole message") { expanded = !expanded }
      .padding(start = 12.dp, top = 4.dp, bottom = 4.dp)
      .semantics(mergeDescendants = true) {},
  ) {
    Row(verticalAlignment = Alignment.CenterVertically) {
      Text(
        if (message.role == ChatRole.USER) "You" else "Assistant",
        style = MaterialTheme.typography.labelLarge,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.weight(1f),
      )
      Caption(formatDateTime(message.createdAt))
    }
    Text(
      text.ifEmpty { if (attachments > 0) "${plural(attachments, "attachment", "attachments")} only" else "(No text)" },
      style = MaterialTheme.typography.bodySmall,
      color = MaterialTheme.colorScheme.onSurfaceVariant,
      maxLines = if (expanded) Int.MAX_VALUE else 3,
      overflow = TextOverflow.Ellipsis,
    )
    if (attachments > 0 && text.isNotEmpty()) Caption("+ ${formatInt(attachments)} ${plural(attachments, "attachment", "attachments")}")
  }
  HorizontalDivider(Modifier.padding(start = 12.dp))
}

/** Technical figures: inline with advanced controls, behind a [label] disclosure in simple view. */
@Composable
private fun TechnicalDetails(
  key: String,
  advancedControls: Boolean,
  label: String = "Technical details",
  content: @Composable () -> Unit,
) {
  if (advancedControls) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) { content() }
    return
  }
  var open by rememberSaveable(key) { mutableStateOf(false) }
  DisclosureRow(label, open) { open = !open }
  if (open) Column(verticalArrangement = Arrangement.spacedBy(6.dp)) { content() }
}

@Composable
private fun DisclosureRow(label: String, expanded: Boolean, onToggle: () -> Unit) {
  Row(
    verticalAlignment = Alignment.CenterVertically,
    modifier = Modifier
      .fillMaxWidth()
      .heightIn(min = 48.dp)
      .clickable(role = Role.Button, onClickLabel = if (expanded) "Hide" else "Show", onClick = onToggle)
      .semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" },
  ) {
    Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
    Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, contentDescription = null)
  }
}

@Composable
private fun ItemCard(content: @Composable () -> Unit) {
  Surface(
    color = MaterialTheme.colorScheme.surfaceContainer,
    shape = MaterialTheme.shapes.medium,
    modifier = Modifier.fillMaxWidth(),
  ) {
    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) { content() }
  }
}

@Composable
private fun Badge(text: String, icon: ImageVector? = null, description: String? = null) {
  Surface(
    color = MaterialTheme.colorScheme.secondaryContainer,
    contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
    shape = RoundedCornerShape(8.dp),
    modifier = if (description != null) Modifier.semantics { contentDescription = description } else Modifier,
  ) {
    Row(
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(4.dp),
      modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
    ) {
      if (icon != null) Icon(icon, contentDescription = null, modifier = Modifier.size(14.dp))
      Text(text, style = MaterialTheme.typography.labelMedium)
    }
  }
}

@Composable
private fun LabeledValue(label: String, value: String) {
  Row(
    horizontalArrangement = Arrangement.spacedBy(12.dp),
    modifier = Modifier.fillMaxWidth().semantics(mergeDescendants = true) {},
  ) {
    Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
    Text(value, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1.4f), textAlign = TextAlign.End)
  }
}

@Composable
private fun IconLine(icon: ImageVector, text: String) {
  Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
    Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp))
    Text(text, style = MaterialTheme.typography.bodyLarge)
  }
}

@Composable
private fun NoticeRow(text: String, warning: Boolean) {
  Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
    Icon(
      if (warning) Icons.Outlined.Warning else Icons.Outlined.Info,
      contentDescription = if (warning) "Warning" else "Note",
      tint = if (warning) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
      modifier = Modifier.size(18.dp),
    )
    Text(text, style = MaterialTheme.typography.bodyMedium)
  }
}

@Composable
private fun SecondaryText(text: String) {
  Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun Caption(text: String, color: Color = MaterialTheme.colorScheme.onSurfaceVariant) {
  Text(text, style = MaterialTheme.typography.labelMedium, color = color)
}

@Composable
private fun ExpandableText(text: String) {
  var expanded by rememberSaveable(text) { mutableStateOf(false) }
  val long = text.length > 280 || text.lines().size > 4
  SelectionContainer {
    Text(
      text,
      style = MaterialTheme.typography.bodyMedium,
      maxLines = if (expanded || !long) Int.MAX_VALUE else 4,
      overflow = TextOverflow.Ellipsis,
    )
  }
  if (long) {
    TextButton(onClick = { expanded = !expanded }, modifier = Modifier.heightIn(min = 48.dp)) {
      Text(if (expanded) "Show less" else "Show all")
    }
  }
}

@Composable
private fun ExpandableQuote(text: String) {
  var expanded by rememberSaveable(text) { mutableStateOf(false) }
  Surface(
    color = MaterialTheme.colorScheme.surfaceContainer,
    shape = MaterialTheme.shapes.medium,
    modifier = Modifier.fillMaxWidth(),
  ) {
    Column(Modifier.padding(12.dp), horizontalAlignment = Alignment.Start) {
      SelectionContainer {
        Text(
          text,
          style = MaterialTheme.typography.bodyMedium,
          maxLines = if (expanded) Int.MAX_VALUE else 6,
          overflow = TextOverflow.Ellipsis,
        )
      }
      if (text.lines().size > 6 || text.length > 400) {
        TextButton(onClick = { expanded = !expanded }) { Text(if (expanded) "Show less" else "Show all") }
      }
    }
  }
}

// endregion

// region formatting

private fun summaryStatusLabel(summary: ConversationSummaryReceipt): String = when (summary.status) {
  SummaryStatus.GENERATED -> "Generated and used"
  SummaryStatus.REUSED -> "Reused; no extra request"
  SummaryStatus.FAILED ->
    if (summary.text.isNullOrBlank()) "Failed; raw-history fallback used" else "Failed; previous summary reused"
  SummaryStatus.CANCELLED -> "Stopped"
  SummaryStatus.NONE -> "Not used"
}

private fun formatInt(value: Int): String = NumberFormat.getIntegerInstance().format(value)

private fun plural(count: Int, singular: String, plural: String): String = if (count == 1) singular else plural

private fun formatDate(millis: Long): String = DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(millis))

private fun formatDateTime(millis: Long): String =
  DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(millis))

private fun parseInstant(value: String): Long? = runCatching { Instant.parse(value).toEpochMilli() }.getOrNull()

// endregion

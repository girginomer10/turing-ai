package com.omergirgin.mosaic.ui.usage

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.omergirgin.mosaic.data.model.UsageCategorySummary
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.formatCount
import com.omergirgin.mosaic.ui.settings.formatUsd
import com.omergirgin.mosaic.ui.settings.pluralize

/**
 * "By category": the same reported usage split by what each request was for (chat replies,
 * history summaries, learned memory, embeddings, connection tests, ...). Every extra request
 * the app makes on the person's behalf is visible here, not only chat replies.
 */
internal fun LazyListScope.usageCategoryItems(categories: List<UsageCategorySummary>?) {
  if (categories.isNullOrEmpty()) return
  item(key = "by-category") { SectionHeader("By category") }
  items(categories, key = { "category|${it.category}" }) { line ->
    UsageCategoryRow(line)
    HorizontalDivider(Modifier.padding(start = 16.dp))
  }
}

@Composable
private fun UsageCategoryRow(line: UsageCategorySummary) {
  Column(
    Modifier
      .fillMaxWidth()
      .padding(horizontal = 16.dp, vertical = 12.dp)
      .semantics(mergeDescendants = true) {},
    verticalArrangement = Arrangement.spacedBy(2.dp),
  ) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
      Text(line.category, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
      Text(
        line.estimatedCostUsd?.let(::formatUsd) ?: "No verified price",
        style = MaterialTheme.typography.bodyMedium,
        color = if (line.estimatedCostUsd == null) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.padding(start = 12.dp),
      )
    }
    categoryDescription(line.category)?.let {
      Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    Text(
      "${pluralize(line.requests, "request")} · ${formatCount(line.inputTokens)} input · ${formatCount(line.outputTokens)} output",
      style = MaterialTheme.typography.bodySmall,
    )
    if (line.unpricedRequests > 0 && line.estimatedCostUsd != null) {
      Text(
        "${pluralize(line.unpricedRequests, "request")} without a verified price or complete usage " +
          "${if (line.unpricedRequests == 1) "is" else "are"} excluded.",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
  }
}

/** Plain-language explanation of the categories the app records; unknown labels get none. */
private fun categoryDescription(category: String): String? = when (category) {
  "Chat" -> "Replies in your chats and automations"
  "Compaction" -> "Readable summaries of older turns in long chats"
  "Memory" -> "Learning topics from new chats"
  "Smart memory" -> "Relevance ranking of memory before a reply"
  "Embeddings" -> "Smart recall and document indexing"
  "Connection test" -> "Checks when a connection is saved or tested"
  "Connected tools" -> "Planning requests that choose and read connected services"
  else -> null
}

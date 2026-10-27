package com.omergirgin.mosaic.ui.usage

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.core.provider.BundledModelCatalog
import com.omergirgin.mosaic.data.model.UsageSummary
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsParagraph
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import com.omergirgin.mosaic.ui.settings.StatusLine
import com.omergirgin.mosaic.ui.settings.StatusTone
import com.omergirgin.mosaic.ui.settings.formatCount
import com.omergirgin.mosaic.ui.settings.formatUsd
import com.omergirgin.mosaic.ui.settings.pluralize
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import kotlinx.coroutines.flow.map

internal enum class UsagePeriod(val label: String) {
  TODAY("Today"),
  THIS_MONTH("This month"),
  LAST_30_DAYS("Last 30 days");

  /** Start of the period in the device's time zone. */
  fun sinceMillis(now: LocalDate = LocalDate.now(), zone: ZoneId = ZoneId.systemDefault()): Long = when (this) {
    TODAY -> now.atStartOfDay(zone)
    THIS_MONTH -> now.withDayOfMonth(1).atStartOfDay(zone)
    // Today plus the 29 days before it: 30 calendar days.
    LAST_30_DAYS -> now.minus(29, ChronoUnit.DAYS).atStartOfDay(zone)
  }.toInstant().toEpochMilli()
}

@Composable
internal fun UsageScreen(onBack: () -> Unit, onOpenPriceList: () -> Unit = {}) {
  val container = LocalAppContainer.current
  var period by rememberSaveable { mutableStateOf(UsagePeriod.THIS_MONTH) }
  val usage by remember(container, period) { container.usage.observeUsage(period.sinceMillis()) }
    .collectAsStateWithLifecycle(initialValue = null)
  val categories by remember(container, period) { container.usage.observeUsageByCategory(period.sinceMillis()) }
    .collectAsStateWithLifecycle(initialValue = null)
  // Price list and custom rates are advanced controls, like iOS.
  val advanced by remember(container) { container.settings.settings.map { it.advancedControls } }
    .collectAsStateWithLifecycle(initialValue = false)
  val overrides by remember(container) { container.prices.observeOverrides() }
    .collectAsStateWithLifecycle(initialValue = emptyList())
  var editingRates by remember { mutableStateOf<UsageSummary?>(null) }

  SettingsScaffold(title = "Usage & cost", onBack = onBack) { padding ->
    LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 32.dp)) {
      item(key = "period") {
        val periods = UsagePeriod.entries
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
          periods.forEachIndexed { index, option ->
            SegmentedButton(
              selected = period == option,
              onClick = { period = option },
              shape = SegmentedButtonDefaults.itemShape(index, periods.size),
              modifier = Modifier.heightIn(min = 48.dp),
            ) { Text(option.label, maxLines = 1) }
          }
        }
      }
      if (advanced) item(key = "prices") { PriceListSection(onOpenPriceList) }
      val lines = usage
      when {
        lines == null -> item(key = "loading") {
          Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        }
        lines.isEmpty() -> item(key = "empty") {
          SettingsParagraph("No reported usage for this period.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        else -> {
          item(key = "totals") { UsageTotals(lines) }
          usageCategoryItems(categories)
          item(key = "by-model") { SectionHeader("By model") }
          val sorted = lines.sortedWith(
            compareByDescending<UsageSummary> { it.estimatedCostUsd ?: -1.0 }
              .thenByDescending { it.inputTokens + it.outputTokens },
          )
          items(sorted, key = { "${it.providerId}|${it.providerName}|${it.modelId}" }) { line ->
            UsageRow(
              line,
              advanced = advanced,
              onEditRates = if (advanced && line.providerId != null) ({ editingRates = line }) else null,
            )
            HorizontalDivider(Modifier.padding(start = 16.dp))
          }
        }
      }
      item(key = "disclaimer") {
        SectionFooter(
          (
            if (advanced) {
              "Estimated from retained usage and published standard paid-tier rates, or your custom rates. " +
                "Discounts, tax and separate search, embedding or request fees are excluded, and estimates do not " +
                "adjust for cached tokens. Changing rates recalculates the estimate for retained history. This is " +
                "not your provider bill. Temporary chats leave no usage history."
            } else {
              "An estimate from saved chats using published or custom prices. Missing usage, taxes and extra " +
                "service fees are excluded. Temporary chats leave no usage history. Your provider's bill is the " +
                "final amount."
            }
            ) + BundledModelCatalog.pricesVerifiedAt.takeIf { it.isNotBlank() }?.let { " Prices verified $it." }.orEmpty(),
        )
      }
      if (!advanced && BundledModelCatalog.isPriceCatalogOutdated) {
        item(key = "outdated") {
          StatusLine("Update the app to refresh prices. Some estimates are unavailable.", StatusTone.WARNING)
        }
      }
    }
    editingRates?.let { line ->
      ModelRatesSheet(
        line = line,
        existing = overrides.firstOrNull { it.providerId == line.providerId && it.modelId == line.modelId },
        onDismiss = { editingRates = null },
      )
    }
  }
}

@Composable
private fun UsageTotals(lines: List<UsageSummary>) {
  val requests = lines.sumOf { it.requests }
  val input = lines.sumOf { it.inputTokens }
  val output = lines.sumOf { it.outputTokens }
  val priced = lines.mapNotNull { it.estimatedCostUsd }
  val unpriced = lines.sumOf { it.unpricedRequests }
  Card(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
      Text("Estimated spending", style = MaterialTheme.typography.titleSmall, modifier = Modifier.semantics { heading() })
      Text(
        if (priced.isEmpty()) "No verified price" else formatUsd(priced.sum()),
        style = MaterialTheme.typography.headlineMedium,
      )
      TotalLine("Requests", formatCount(requests))
      TotalLine("Input tokens", formatCount(input))
      TotalLine("Output tokens", formatCount(output))
    }
  }
  if (unpriced > 0) {
    // Unpriced and unreported usage stays explicit instead of silently counting as $0.
    StatusLine(
      "${pluralize(unpriced, "request")} without a price or complete usage ${if (unpriced == 1) "is" else "are"} " +
        "excluded. The subtotal may be lower than your bill.",
      StatusTone.WARNING,
    )
  }
}

@Composable
private fun TotalLine(label: String, value: String) {
  Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
    Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Text(value, style = MaterialTheme.typography.bodyMedium)
  }
}

@Composable
private fun UsageRow(line: UsageSummary, advanced: Boolean, onEditRates: (() -> Unit)?) {
  Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
      Text(line.modelId, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
      Text(
        line.estimatedCostUsd?.let(::formatUsd) ?: "No verified price",
        style = MaterialTheme.typography.bodyMedium,
        color = if (line.estimatedCostUsd == null) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.padding(start = 12.dp),
      )
    }
    Text(line.providerName, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Text(
      "${pluralize(line.requests, "request")} · ${formatCount(line.inputTokens)} input · ${formatCount(line.outputTokens)} output",
      style = MaterialTheme.typography.bodySmall,
    )
    if (advanced) {
      UsageLinePricing(line, onEditRates)
    } else if (line.unpricedRequests > 0 || line.unreportedRequests > 0) {
      Text(
        "Some usage is incomplete or unpriced. The subtotal may be lower than your bill.",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
  }
}

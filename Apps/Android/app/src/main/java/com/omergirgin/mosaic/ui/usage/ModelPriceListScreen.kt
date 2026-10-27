package com.omergirgin.mosaic.ui.usage

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.omergirgin.mosaic.core.provider.BundledModelCatalog
import com.omergirgin.mosaic.core.provider.ModelPrice
import com.omergirgin.mosaic.core.provider.PricedModel
import com.omergirgin.mosaic.core.provider.displayName
import com.omergirgin.mosaic.ui.settings.ExternalLinkRow
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SettingsParagraph
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import com.omergirgin.mosaic.ui.settings.StatusLine
import com.omergirgin.mosaic.ui.settings.StatusTone
import com.omergirgin.mosaic.ui.settings.formatCount
import com.omergirgin.mosaic.ui.settings.pluralize
import java.text.NumberFormat
import java.util.Locale

/**
 * iOS `ModelPriceListView`: every bundled official price (USD per million tokens), searchable by
 * model or provider, with conditions, the official source and the list's review date.
 */
@Composable
internal fun ModelPriceListScreen(onBack: () -> Unit) {
  var query by rememberSaveable { mutableStateOf("") }
  var expanded by rememberSaveable { mutableStateOf<String?>(null) }
  val all = remember {
    BundledModelCatalog.allPrices().sortedWith(
      compareBy(String.CASE_INSENSITIVE_ORDER) { item: PricedModel -> item.kind.displayName }
        .thenBy(String.CASE_INSENSITIVE_ORDER) { it.modelId },
    )
  }
  val needle = query.trim()
  val visible = remember(all, needle) {
    if (needle.isEmpty()) all
    else all.filter { "${it.modelId} ${it.kind.displayName}".contains(needle, ignoreCase = true) }
  }
  val verifiedAt = BundledModelCatalog.pricesVerifiedAt.ifBlank { "unavailable" }

  SettingsScaffold(title = "Model prices", onBack = onBack) { padding ->
    LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 32.dp)) {
      item(key = "search") {
        OutlinedTextField(
          value = query,
          onValueChange = { query = it },
          label = { Text("Model or provider") },
          leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
          singleLine = true,
          keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
          modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        )
      }
      item(key = "intro") {
        Column {
          SettingsParagraph("USD per million tokens · verified $verifiedAt")
          SectionFooter(
            "Published standard paid-tier prices. Your account may have free usage or discounts. Unlisted " +
              "models and custom endpoints stay unpriced. Prices are updated with the app; older history is " +
              "estimated using this list.",
          )
          if (BundledModelCatalog.isPriceCatalogOutdated) {
            StatusLine(OUTDATED_PRICE_LIST, StatusTone.WARNING)
          }
        }
      }
      if (all.isEmpty()) {
        item(key = "unavailable") {
          StatusLine("The bundled price list could not be read. Automatic estimates are unavailable.", StatusTone.WARNING)
        }
      } else if (visible.isEmpty()) {
        item(key = "no-match") {
          Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            Text("No matching models", style = MaterialTheme.typography.titleMedium)
            Text("Try a different model ID or provider name.", color = MaterialTheme.colorScheme.onSurfaceVariant)
          }
        }
      } else {
        item(key = "count") { SectionFooter(pluralize(visible.size, "model")) }
      }
      items(visible, key = { "${it.kind.rawId}/${it.modelId}" }) { item ->
        val key = "${item.kind.rawId}/${item.modelId}"
        PriceRow(item, expanded = expanded == key, onToggle = { expanded = if (expanded == key) null else key })
        HorizontalDivider(Modifier.padding(start = 16.dp))
      }
    }
  }
}

@Composable
private fun PriceRow(item: PricedModel, expanded: Boolean, onToggle: () -> Unit) {
  Column(Modifier.fillMaxWidth()) {
    Row(
      verticalAlignment = Alignment.CenterVertically,
      modifier = Modifier
        .fillMaxWidth()
        .heightIn(min = 56.dp)
        .clickable(role = Role.Button, onClick = onToggle)
        .semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" }
        .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
      Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(item.modelId, style = MaterialTheme.typography.titleSmall)
        Text(item.kind.displayName, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(
          "Input ${formatRate(item.price.inputPerMillion)} · Output ${formatRate(item.price.outputPerMillion)}",
          style = MaterialTheme.typography.bodySmall,
        )
      }
      Icon(if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, contentDescription = null)
    }
    if (expanded) PriceDetails(item.price)
  }
}

/** Official rate conditions (iOS `ModelPriceDetails`). Shared with the model rates sheet. */
@Composable
internal fun PriceDetails(price: ModelPrice) {
  Column(Modifier.fillMaxWidth().padding(bottom = 8.dp)) {
    DetailLine("Input / 1M", formatRate(price.inputPerMillion))
    DetailLine("Output / 1M", formatRate(price.outputPerMillion))
    for (tier in price.tiers) {
      SectionFooter(
        "From ${formatCount(tier.fromInputTokens)} input tokens per request: ${formatRate(tier.inputPerMillion)} " +
          "input / ${formatRate(tier.outputPerMillion)} output per 1M.",
      )
    }
    price.maximumInputTokens?.let {
      SectionFooter("Automatic estimates require no more than ${formatCount(it)} input tokens per request.")
    }
    price.weekdayPeakMultiplier?.let { multiplier ->
      val factor = if (multiplier == 2.0) "double" else "${formatMultiplier(multiplier)}×"
      SectionFooter("Weekdays 01:00–04:00 and 06:00–10:00 UTC: $factor the displayed off-peak rates.")
    }
    price.validUntil?.let { SectionFooter("Automatic estimates with this rate stop after $it unless the app is updated.") }
    price.source?.let { ExternalLinkRow("Official pricing source", it) }
  }
}

@Composable
private fun DetailLine(label: String, value: String) {
  Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), horizontalArrangement = Arrangement.SpaceBetween) {
    Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Text(value, style = MaterialTheme.typography.bodyMedium)
  }
}

internal const val OUTDATED_PRICE_LIST =
  "The bundled price list needs an app update. Automatic estimates are paused; custom rates still work."

/** USD per million tokens with 2–5 decimals (iOS precision). */
internal fun formatRate(value: Double): String =
  NumberFormat.getCurrencyInstance(Locale.US).apply {
    minimumFractionDigits = 2
    maximumFractionDigits = 5
  }.format(value)

private fun formatMultiplier(value: Double): String =
  NumberFormat.getNumberInstance(Locale.US).apply { maximumFractionDigits = 2 }.format(value)

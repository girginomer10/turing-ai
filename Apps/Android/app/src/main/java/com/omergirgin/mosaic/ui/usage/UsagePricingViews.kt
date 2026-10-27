package com.omergirgin.mosaic.ui.usage

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.RequestQuote
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.omergirgin.mosaic.core.provider.BundledModelCatalog
import com.omergirgin.mosaic.core.provider.ModelPrice
import com.omergirgin.mosaic.data.model.UsageSummary
import com.omergirgin.mosaic.data.pricing.ModelPriceOverride
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsLinkRow
import com.omergirgin.mosaic.ui.settings.StatusLine
import com.omergirgin.mosaic.ui.settings.StatusTone
import com.omergirgin.mosaic.ui.settings.pluralize
import java.math.BigDecimal
import java.time.Instant
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Advanced Usage & cost: entry to the official price list (iOS "Model price list" section). */
@Composable
internal fun PriceListSection(onOpenPriceList: () -> Unit) {
  Column {
    SectionHeader("Prices")
    SettingsLinkRow(
      title = "Model price list",
      subtitle = "Official list prices are included. Special account rates can be overridden per model.",
      icon = Icons.Outlined.RequestQuote,
      onClick = onOpenPriceList,
    )
    if (BundledModelCatalog.isPriceCatalogOutdated) StatusLine(OUTDATED_PRICE_LIST, StatusTone.WARNING)
  }
}

/** The bundled rate that applies to this line now (official host and exact model only). */
internal fun officialPrice(line: UsageSummary): ModelPrice? {
  val kind = line.providerKind ?: return null
  return BundledModelCatalog.price(kind, line.modelId, line.destinationHost, Instant.now())
}

/** Advanced per-line pricing: rate provenance, exclusions and the "Model rates" action. */
@Composable
internal fun UsageLinePricing(line: UsageSummary, onEditRates: (() -> Unit)?) {
  Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
    if (line.unreportedRequests > 0) {
      Caption("${pluralize(line.unreportedRequests, "request")} ${if (line.unreportedRequests == 1) "has" else "have"} incomplete usage reports")
    }
    if (line.usesCustomRate) {
      Caption("Custom rates")
    } else {
      val official = remember(line) { officialPrice(line) }
      if (official != null) {
        Caption("Official rates · verified ${BundledModelCatalog.pricesVerifiedAt}")
      }
      if (line.unpricedRequests > 0) {
        Caption("${pluralize(line.unpricedRequests, "request")} excluded: price or complete usage unavailable")
      }
    }
    if (onEditRates != null) {
      TextButton(onClick = onEditRates, modifier = Modifier.heightIn(min = 48.dp)) { Text("Model rates") }
    }
  }
}

@Composable
private fun Caption(text: String) {
  Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/**
 * iOS `ModelRateView`: official rates for reference, two custom rates for a special tariff
 * (zero allowed), and "Return to default". Changing rates reprices retained history.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ModelRatesSheet(line: UsageSummary, existing: ModelPriceOverride?, onDismiss: () -> Unit) {
  val container = LocalAppContainer.current
  val scope = rememberCoroutineScope()
  val providerId = line.providerId ?: return
  val official = remember(line) { officialPrice(line) }
  var input by rememberSaveable { mutableStateOf((existing?.inputPerMillion ?: official?.inputPerMillion)?.let(::plain).orEmpty()) }
  var output by rememberSaveable { mutableStateOf((existing?.outputPerMillion ?: official?.outputPerMillion)?.let(::plain).orEmpty()) }
  var error by remember { mutableStateOf<String?>(null) }
  var saving by remember { mutableStateOf(false) }

  fun write(action: suspend () -> Unit) {
    if (saving) return
    saving = true
    scope.launch {
      try {
        withContext(NonCancellable) { action() }
        onDismiss()
      } catch (failure: CancellationException) {
        throw failure
      } catch (failure: Exception) {
        error = failure.message ?: "The rates couldn't be saved. Please try again."
      } finally {
        saving = false
      }
    }
  }

  ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
    Column(
      verticalArrangement = Arrangement.spacedBy(8.dp),
      modifier = Modifier
        .fillMaxWidth()
        .verticalScroll(rememberScrollState())
        .navigationBarsPadding()
        .padding(bottom = 24.dp),
    ) {
      Column(Modifier.padding(horizontal = 16.dp)) {
        Text("Model rates", style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
        Text(line.modelId, style = MaterialTheme.typography.titleSmall)
        Text(line.providerName, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
      }
      if (official != null) {
        SectionHeader("Official standard rates")
        PriceDetails(official)
      } else {
        SectionFooter(
          "No bundled price applies to this model and endpoint. Custom endpoints and unlisted models stay " +
            "unpriced unless you enter your account's rates.",
        )
      }
      if (existing != null) {
        StatusLine("Custom rates are in use for this model.", StatusTone.NEUTRAL)
        OutlinedButton(
          onClick = { write { container.prices.resetOverride(providerId, line.modelId) } },
          enabled = !saving,
          modifier = Modifier.padding(horizontal = 16.dp).heightIn(min = 48.dp),
        ) { Text("Return to default") }
      }
      SectionHeader("Custom rates")
      OutlinedTextField(
        value = input,
        onValueChange = { input = it; error = null },
        label = { Text("USD per 1M input tokens") },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Next),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
      )
      OutlinedTextField(
        value = output,
        onValueChange = { output = it; error = null },
        label = { Text("USD per 1M output tokens") },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
      )
      SectionFooter(
        "Enter your account's standard rates. Discounts and non-token fees are not included. Changing rates " +
          "recalculates the estimate for retained history.",
      )
      error?.let { StatusLine(it, StatusTone.ERROR) }
      Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
      ) {
        TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = 48.dp)) { Text("Cancel") }
        Button(
          enabled = !saving,
          onClick = {
            val inputRate = parseRate(input)
            val outputRate = parseRate(output)
            if (inputRate == null || outputRate == null) {
              error = "Enter valid nonnegative USD rates."
            } else {
              write { container.prices.setOverride(providerId, line.modelId, inputRate, outputRate) }
            }
          },
          modifier = Modifier.heightIn(min = 48.dp),
        ) { Text("Save") }
      }
    }
  }
}

/** Accepts "1.25" or "1,25"; finite, nonnegative, at most 1,000,000 USD per million tokens. */
private fun parseRate(text: String): Double? =
  text.trim().replace(',', '.').toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 && it <= 1_000_000 }

/** Plain decimal for editing (no grouping, no exponent). */
private fun plain(value: Double): String = BigDecimal.valueOf(value).stripTrailingZeros().toPlainString()

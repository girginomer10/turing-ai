package com.omergirgin.mosaic.ui.memory

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.omergirgin.mosaic.data.model.AppSettings
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.SettingsSwitchRow
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * iOS "Smart memory" toggle (advanced controls): one bounded relevance request with the selected
 * chat model before recall. Off = local matching and embedding profiles only.
 */
@Composable
internal fun SmartMemorySwitch(current: AppSettings, enabled: Boolean, onError: (String) -> Unit) {
  val container = LocalAppContainer.current
  val scope = rememberCoroutineScope()
  Column {
    SettingsSwitchRow(
      title = "Smart memory",
      subtitle = if (current.smartMemoryEnabled) "On" else "Off — local matching and embeddings only",
      checked = current.smartMemoryEnabled,
      enabled = enabled,
      onCheckedChange = { value ->
        scope.launch {
          runCatching { withContext(NonCancellable) { container.settings.setSmartMemoryEnabled(value) } }
            .onFailure { onError(it.message ?: "The setting couldn't be saved. Please try again.") }
        }
      },
    )
    Text(
      "Checks a limited set of eligible memories with your selected chat model, including across languages. " +
        "This uses an additional API request. Turn off to use local matching and your embedding profiles only.",
      style = MaterialTheme.typography.bodySmall,
      modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp),
    )
    HorizontalDivider(Modifier.padding(horizontal = 16.dp))
  }
}

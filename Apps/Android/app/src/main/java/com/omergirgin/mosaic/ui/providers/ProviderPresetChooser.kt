package com.omergirgin.mosaic.ui.providers

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.omergirgin.mosaic.core.provider.ProviderCategory
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.profile
import com.omergirgin.mosaic.core.provider.supportsChat
import com.omergirgin.mosaic.ui.components.ProviderIdentity
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsParagraph
import com.omergirgin.mosaic.ui.settings.SettingsScaffold

/**
 * Presets offered on Android. Embedding-only services (Voyage AI, Jina AI) are left out because
 * Android has no embedding-based memory yet, so such a connection could never be used.
 */
internal fun chooserPresets(category: ProviderCategory): List<ProviderKind> =
  ProviderKind.inCategory(category).filter { it.supportsChat }

/** Searchable list of presets grouped by category, each with its logo and service summary. */
@Composable
internal fun ProviderPresetList(
  selected: ProviderKind?,
  onSelect: (ProviderKind) -> Unit,
  modifier: Modifier = Modifier,
) {
  var query by rememberSaveable { mutableStateOf("") }
  val normalized = query.trim()
  val groups = remember(normalized) {
    ProviderCategory.entries.mapNotNull { category ->
      val kinds = chooserPresets(category).filter { kind ->
        normalized.isEmpty() || listOf(kind.profile.displayName, kind.profile.serviceSummary, category.displayName)
          .any { it.contains(normalized, ignoreCase = true) }
      }
      if (kinds.isEmpty()) null else category to kinds
    }
  }

  Column(modifier.fillMaxSize().imePadding()) {
    OutlinedTextField(
      value = query,
      onValueChange = { query = it },
      label = { Text("Search services") },
      leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
      singleLine = true,
      keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Search),
      modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
    )
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
      if (groups.isEmpty()) {
        item(key = "empty") {
          SettingsParagraph("No services match “$normalized”.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
      }
      groups.forEach { (category, kinds) ->
        item(key = "header-${category.name}") { SectionHeader(category.displayName) }
        items(kinds, key = { it.rawId }) { kind ->
          val isSelected = kind == selected
          Row(
            modifier = Modifier
              .fillMaxWidth()
              .heightIn(min = 56.dp)
              .selectable(selected = isSelected, role = Role.Button) { onSelect(kind) }
              .semantics { if (isSelected) stateDescription = "Selected" }
              .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
          ) {
            ProviderIdentity(
              kind = kind,
              subtitle = kind.profile.serviceSummary,
              logoSize = 36.dp,
              modifier = Modifier.weight(1f),
            )
            if (isSelected) {
              Spacer(Modifier.width(8.dp))
              Icon(Icons.Filled.Check, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            }
          }
        }
      }
    }
  }
}

/** Route used by "Add AI service": choosing a preset continues to the editor. */
@Composable
internal fun ProviderPresetChooserScreen(onBack: () -> Unit, onSelect: (ProviderKind) -> Unit) {
  SettingsScaffold(title = "Choose AI service", onBack = onBack) { padding ->
    ProviderPresetList(selected = null, onSelect = onSelect, modifier = Modifier.padding(padding))
  }
}

/** Full-screen dialog used by the editor's "Service" row to change the connection type. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ProviderPresetDialog(
  selected: ProviderKind,
  onSelect: (ProviderKind) -> Unit,
  onDismiss: () -> Unit,
) {
  Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
    Surface(Modifier.fillMaxSize()) {
      Scaffold(
        topBar = {
          TopAppBar(
            title = { Text("Choose AI service") },
            navigationIcon = {
              IconButton(onClick = onDismiss) { Icon(Icons.Filled.Close, contentDescription = "Close") }
            },
          )
        },
      ) { padding ->
        ProviderPresetList(selected = selected, onSelect = onSelect, modifier = Modifier.padding(padding))
      }
    }
  }
}

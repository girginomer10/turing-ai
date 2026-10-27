package com.omergirgin.mosaic.ui.settings

import androidx.compose.foundation.layout.Column
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
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.omergirgin.mosaic.data.model.ModelChoice
import com.omergirgin.mosaic.data.model.ModelOption
import com.omergirgin.mosaic.ui.components.ProviderLogo

/**
 * Full-screen, searchable chooser over enabled models. Catalogs can hold thousands of
 * account-visible IDs, so this is a lazy list rather than a menu (DESIGN.md: searchable drill-down).
 *
 * [automaticLabel] is the "no explicit choice" row (null result), e.g. "Use the most recently used model".
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ModelPickerDialog(
  title: String,
  options: List<ModelOption>,
  selected: ModelChoice?,
  automaticLabel: String,
  automaticDescription: String,
  onSelect: (ModelChoice?) -> Unit,
  onDismiss: () -> Unit,
) {
  var query by rememberSaveable { mutableStateOf("") }
  val normalized = query.trim()
  val filtered = remember(options, normalized) {
    if (normalized.isEmpty()) options
    else options.filter {
      it.modelId.contains(normalized, ignoreCase = true) || it.providerName.contains(normalized, ignoreCase = true)
    }
  }
  val selectedIsUnavailable = selected != null && options.none { it.choice == selected }

  Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
    Surface(Modifier.fillMaxSize()) {
      Scaffold(
        topBar = {
          TopAppBar(
            title = { Text(title) },
            navigationIcon = {
              IconButton(onClick = onDismiss) { Icon(Icons.Filled.Close, contentDescription = "Close") }
            },
          )
        },
      ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().imePadding()) {
          OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            label = { Text("Search models or services") },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Search),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
          )
          LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
            if (selectedIsUnavailable) {
              item(key = "unavailable") {
                StatusLine(
                  "The saved choice (${selected.modelId}) is no longer enabled, so it isn't used. Choose another model or keep the automatic option.",
                  StatusTone.WARNING,
                )
              }
            }
            item(key = "automatic") {
              ListItem(
                headlineContent = { Text(automaticLabel) },
                supportingContent = { Text(automaticDescription) },
                leadingContent = { RadioButton(selected = selected == null, onClick = null) },
                modifier = Modifier
                  .fillMaxWidth()
                  .heightIn(min = 56.dp)
                  .selectable(selected = selected == null, role = Role.RadioButton) { onSelect(null) },
              )
              HorizontalDivider()
            }
            if (options.isEmpty()) {
              item(key = "empty") {
                SettingsParagraph(
                  "No models are enabled yet. Add an AI service and enable its models in AI models & accounts.",
                  color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
              }
            } else if (filtered.isEmpty()) {
              item(key = "no-match") {
                SettingsParagraph(
                  "No enabled models match “$normalized”.",
                  color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
              }
            }
            items(filtered, key = { "${it.choice.providerId}|${it.choice.modelId}" }) { option ->
              val isSelected = option.choice == selected
              ListItem(
                headlineContent = { Text(option.modelId) },
                supportingContent = {
                  Text(if (option.supportsImages) "${option.providerName} · Photos" else option.providerName)
                },
                leadingContent = { ProviderLogo(option.providerKind, size = 28.dp) },
                trailingContent = { RadioButton(selected = isSelected, onClick = null) },
                modifier = Modifier
                  .fillMaxWidth()
                  .heightIn(min = 56.dp)
                  .selectable(selected = isSelected, role = Role.RadioButton) { onSelect(option.choice) },
              )
            }
          }
        }
      }
    }
  }
}

/** Short label for a model choice, flagging choices that are no longer enabled. */
internal fun modelChoiceLabel(choice: ModelChoice?, options: List<ModelOption>, automatic: String): String {
  if (choice == null) return automatic
  val option = options.firstOrNull { it.choice == choice } ?: return "${choice.modelId} · no longer enabled"
  return "${option.modelId} · ${option.providerName}"
}

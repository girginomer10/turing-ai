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

/** One row in [SearchableChoiceDialog]; [key] must be unique and stable. */
internal data class Choice<T>(val key: String, val value: T, val title: String, val subtitle: String? = null)

/**
 * Full-screen single-choice list with local search, for lists that can be long (enabled models,
 * projects). Filtering is a cheap substring match over already-loaded rows.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun <T> SearchableChoiceDialog(
  title: String,
  choices: List<Choice<T>>,
  selectedKey: String?,
  onSelect: (T) -> Unit,
  onDismiss: () -> Unit,
  searchLabel: String = "Search",
  emptyMessage: String = "Nothing to choose yet.",
  header: (@Composable () -> Unit)? = null,
) {
  var query by rememberSaveable { mutableStateOf("") }
  val normalized = query.trim()
  val filtered = remember(choices, normalized) {
    if (normalized.isEmpty()) choices
    else choices.filter {
      it.title.contains(normalized, ignoreCase = true) || it.subtitle?.contains(normalized, ignoreCase = true) == true
    }
  }
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
          if (choices.size > 8) {
            OutlinedTextField(
              value = query,
              onValueChange = { query = it },
              label = { Text(searchLabel) },
              leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
              singleLine = true,
              keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Search),
              modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            )
          }
          LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
            header?.let { item(key = "__header") { it() } }
            if (choices.isEmpty()) {
              item(key = "__empty") {
                SettingsParagraph(emptyMessage, color = MaterialTheme.colorScheme.onSurfaceVariant)
              }
            } else if (filtered.isEmpty()) {
              item(key = "__nomatch") {
                SettingsParagraph("Nothing matches “$normalized”.", color = MaterialTheme.colorScheme.onSurfaceVariant)
              }
            }
            items(filtered, key = { it.key }) { choice ->
              val isSelected = choice.key == selectedKey
              ListItem(
                headlineContent = { Text(choice.title) },
                supportingContent = choice.subtitle?.let { { Text(it) } },
                leadingContent = { RadioButton(selected = isSelected, onClick = null) },
                modifier = Modifier
                  .fillMaxWidth()
                  .heightIn(min = 56.dp)
                  .selectable(selected = isSelected, role = Role.RadioButton) { onSelect(choice.value) },
              )
            }
          }
        }
      }
    }
  }
}

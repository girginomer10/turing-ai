package com.omergirgin.mosaic.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.omergirgin.mosaic.data.model.Project

/** Single text value editor (rename, system prompt). [onConfirm] receives the raw text. */
@Composable
fun TextInputDialog(
  title: String,
  label: String,
  initialValue: String,
  confirmLabel: String,
  onDismiss: () -> Unit,
  onConfirm: (String) -> Unit,
  supportingText: String? = null,
  singleLine: Boolean = true,
  allowBlank: Boolean = false,
  extraAction: Pair<String, () -> Unit>? = null,
) {
  var value by rememberSaveable { mutableStateOf(initialValue) }
  val focusRequester = remember { FocusRequester() }
  LaunchedEffect(Unit) { runCatching { focusRequester.requestFocus() } }
  AlertDialog(
    onDismissRequest = onDismiss,
    title = { Text(title) },
    text = {
      Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (supportingText != null) {
          Text(supportingText, style = MaterialTheme.typography.bodyMedium)
        }
        OutlinedTextField(
          value = value,
          onValueChange = { value = it },
          label = { Text(label) },
          singleLine = singleLine,
          minLines = if (singleLine) 1 else 4,
          maxLines = if (singleLine) 1 else 10,
          keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
          modifier = Modifier.fillMaxWidth().focusRequester(focusRequester),
        )
      }
    },
    confirmButton = {
      TextButton(
        onClick = { onConfirm(value) },
        enabled = allowBlank || value.isNotBlank(),
      ) { Text(confirmLabel) }
    },
    dismissButton = {
      Row {
        if (extraAction != null) {
          TextButton(onClick = extraAction.second) { Text(extraAction.first) }
        }
        TextButton(onClick = onDismiss) { Text("Cancel") }
      }
    },
  )
}

@Composable
fun ConfirmDialog(
  title: String,
  message: String,
  confirmLabel: String,
  onDismiss: () -> Unit,
  onConfirm: () -> Unit,
  destructive: Boolean = true,
) {
  AlertDialog(
    onDismissRequest = onDismiss,
    title = { Text(title) },
    text = { Text(message) },
    confirmButton = {
      TextButton(onClick = onConfirm) {
        Text(
          confirmLabel,
          color = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
        )
      }
    },
    dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
  )
}

/** Chooses a project (or none) for a chat. Archived projects are not offered. */
@Composable
fun ProjectPickerDialog(
  projects: List<Project>,
  currentProjectId: String?,
  onDismiss: () -> Unit,
  onSelect: (projectId: String?) -> Unit,
) {
  var selected by rememberSaveable { mutableStateOf(currentProjectId) }
  AlertDialog(
    onDismissRequest = onDismiss,
    title = { Text("Move to project") },
    text = {
      if (projects.isEmpty()) {
        Text("You don't have any projects yet. Create one from Projects in the chat history.")
      } else {
        LazyColumn(Modifier.heightIn(max = 360.dp).selectableGroup()) {
          item(key = "none") {
            ProjectOptionRow("No project", selected == null) { selected = null }
          }
          items(projects, key = { it.id }) { project ->
            ProjectOptionRow(project.name, selected == project.id) { selected = project.id }
          }
        }
      }
    },
    confirmButton = {
      TextButton(
        onClick = { onSelect(selected) },
        enabled = projects.isNotEmpty() && selected != currentProjectId,
      ) { Text("Move") }
    },
    dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
  )
}

@Composable
private fun ProjectOptionRow(label: String, selected: Boolean, onClick: () -> Unit) {
  Row(
    verticalAlignment = Alignment.CenterVertically,
    modifier = Modifier
      .fillMaxWidth()
      .heightIn(min = 48.dp)
      .selectable(selected = selected, onClick = onClick, role = Role.RadioButton),
  ) {
    RadioButton(selected = selected, onClick = null)
    Text(
      label,
      maxLines = 2,
      overflow = TextOverflow.Ellipsis,
      modifier = Modifier.padding(start = 12.dp),
    )
  }
}

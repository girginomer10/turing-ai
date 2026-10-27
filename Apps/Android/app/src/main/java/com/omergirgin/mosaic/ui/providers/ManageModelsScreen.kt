package com.omergirgin.mosaic.ui.providers

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.omergirgin.mosaic.core.provider.BundledModelCatalog
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.profile
import com.omergirgin.mosaic.core.provider.supportsModelDiscovery
import com.omergirgin.mosaic.data.model.AppSettings
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.DiscardChangesDialog
import com.omergirgin.mosaic.ui.settings.EmptyState
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsParagraph
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import com.omergirgin.mosaic.ui.settings.StatusLine
import com.omergirgin.mosaic.ui.settings.StatusTone
import com.omergirgin.mosaic.ui.settings.formatCount

@Composable
internal fun ManageModelsScreen(providerId: String, onBack: () -> Unit) {
  val container = LocalAppContainer.current
  val vm: ManageModelsViewModel = viewModel { ManageModelsViewModel(container.providers, providerId) }
  val settings by remember(container) { container.settings.settings }
    .collectAsStateWithLifecycle(initialValue = AppSettings())
  val advanced = settings.advancedControls
  var confirmDiscard by rememberSaveable { mutableStateOf(false) }
  var editingModel by rememberSaveable { mutableStateOf<String?>(null) }

  LaunchedEffect(vm.saved) { if (vm.saved) onBack() }

  val requestBack: () -> Unit = {
    if (!vm.isSaving) {
      if (vm.isDirty) confirmDiscard = true else onBack()
    }
  }
  BackHandler(enabled = vm.isSaving || vm.isDirty) { requestBack() }

  SettingsScaffold(
    title = "Manage models",
    onBack = requestBack,
    actions = {
      if (vm.isSaving) {
        CircularProgressIndicator(Modifier.padding(horizontal = 16.dp).size(24.dp), strokeWidth = 2.dp)
      } else if (vm.config != null) {
        TextButton(onClick = vm::save) { Text("Save") }
      }
    },
  ) { padding ->
    when {
      vm.isLoading -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
      }
      vm.notFound || vm.config == null -> EmptyState(
        title = "Connection not found",
        message = "This connection was deleted.",
        modifier = Modifier.padding(padding),
      ) { OutlinedButton(onClick = onBack) { Text("Go back") } }
      else -> ModelList(vm, advanced, Modifier.padding(padding), onEditLimits = { editingModel = it })
    }
  }

  val kind = vm.kind
  val editing = editingModel
  if (editing != null && kind != null) {
    ModelSettingsDialog(
      kind = kind,
      providerName = vm.config?.displayName ?: kind.profile.displayName,
      modelId = editing,
      current = vm.overrides[editing] ?: ModelOverride(),
      onApply = {
        vm.applyOverride(editing, it)
        editingModel = null
      },
      onDismiss = { editingModel = null },
    )
  }
  if (confirmDiscard) {
    DiscardChangesDialog(
      message = "Your model changes haven't been saved.",
      onDiscard = {
        confirmDiscard = false
        onBack()
      },
      onKeepEditing = { confirmDiscard = false },
    )
  }
  vm.errorMessage?.let { MessageDialog("Couldn't save models", it) { vm.errorMessage = null } }
}

@Composable
private fun ModelList(
  vm: ManageModelsViewModel,
  advanced: Boolean,
  modifier: Modifier,
  onEditLimits: (String) -> Unit,
) {
  val kind = vm.kind ?: return
  val listState = rememberLazyListState()
  LaunchedEffect(vm.scrollToTopRequests) { if (vm.scrollToTopRequests > 0) listState.animateScrollToItem(0) }
  val showsAddField = advanced || vm.catalogUnavailable || !kind.supportsModelDiscovery || vm.orderedIds.isEmpty()
  val visible = vm.visibleIds

  LazyColumn(
    state = listState,
    modifier = modifier.fillMaxSize().imePadding(),
    contentPadding = PaddingValues(bottom = 32.dp),
  ) {
    item(key = "controls") {
      Column {
        OutlinedTextField(
          value = vm.query,
          onValueChange = { vm.query = it },
          label = { Text("Search models") },
          leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
          trailingIcon = if (vm.query.isNotEmpty()) {
            { IconButton(onClick = { vm.query = "" }) { Icon(Icons.Filled.Close, contentDescription = "Clear search") } }
          } else null,
          singleLine = true,
          keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Search),
          modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        )
        Row(
          Modifier.fillMaxWidth().padding(horizontal = 16.dp),
          verticalAlignment = Alignment.CenterVertically,
          horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
          FilterChip(
            selected = vm.enabledOnly,
            onClick = { vm.enabledOnly = !vm.enabledOnly },
            label = { Text("Enabled only") },
            leadingIcon = if (vm.enabledOnly) {
              { Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(FilterChipDefaults.IconSize)) }
            } else null,
            modifier = Modifier.heightIn(min = 48.dp),
          )
          if (kind.supportsModelDiscovery) {
            val refreshing = vm.refreshState == RefreshState.Refreshing
            TextButton(onClick = vm::refresh, enabled = !refreshing, modifier = Modifier.heightIn(min = 48.dp)) {
              if (refreshing) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
              } else {
                Icon(Icons.Filled.Refresh, contentDescription = null)
              }
              Spacer(Modifier.width(8.dp))
              Text(
                when {
                  vm.usesPublicCatalog -> if (refreshing) "Loading public models…" else "Load public models"
                  else -> if (refreshing) "Loading models…" else "Refresh models"
                },
              )
            }
          }
        }
        when (val state = vm.refreshState) {
          is RefreshState.Success -> StatusLine(state.message, StatusTone.SUCCESS)
          is RefreshState.Failure -> StatusLine(state.message, StatusTone.ERROR)
          else -> Unit
        }
        SectionFooter(
          if (vm.usesPublicCatalog) {
            "Suggestions are starting points. Loading the public catalog lists current model IDs without sending " +
              "your API key; it does not verify the key or your access to a model."
          } else if (kind.supportsModelDiscovery) {
            "Suggestions may require account or regional access. Refresh to load the models your saved connection can list."
          } else {
            "This service does not publish a compatible live catalog here. Enable suggestions or add an exact model ID from its current documentation."
          },
        )
      }
    }

    if (showsAddField) {
      item(key = "add") { AddModelField(vm, kind) }
    }

    item(key = "header") {
      SectionHeader("${formatCount(vm.enabled.size)} enabled · ${formatCount(vm.orderedIds.size)} available")
      HorizontalDivider()
    }

    if (visible.isEmpty()) {
      item(key = "empty") {
        SettingsParagraph(
          when {
            vm.orderedIds.isEmpty() -> "No models yet. Refresh the catalog or add an exact model ID."
            vm.enabledOnly && vm.query.isBlank() -> "No models are enabled."
            else -> "No models match “${vm.query.trim()}”."
          },
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
      }
    }

    items(visible, key = { it }) { id ->
      ModelRow(
        id = id,
        info = vm.infos[id],
        enabled = id in vm.enabled,
        override = vm.overrides[id],
        limitsFromAccount = id in vm.accountLimitIds,
        advanced = advanced,
        onToggle = { vm.setEnabled(id, it) },
        onEditLimits = { onEditLimits(id) },
      )
    }

    item(key = "footer") {
      SectionFooter(
        "Enabled models appear in your chats. New catalog entries stay disabled until you enable them. " +
          "Save to apply changes.",
      )
    }
  }
}

@Composable
private fun AddModelField(vm: ManageModelsViewModel, kind: ProviderKind) {
  Column {
    SectionHeader("Add an exact model ID")
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.Top) {
      OutlinedTextField(
        value = vm.customModelText,
        onValueChange = {
          vm.customModelText = it
          vm.clearCustomModelIssue()
        },
        label = { Text(if (kind == ProviderKind.MICROSOFT_FOUNDRY) "Deployment name" else "Exact model ID") },
        singleLine = true,
        isError = vm.customModelIssue != null,
        supportingText = vm.customModelIssue?.let { { Text(it) } },
        keyboardOptions = KeyboardOptions(
          capitalization = KeyboardCapitalization.None,
          autoCorrectEnabled = false,
          imeAction = ImeAction.Done,
        ),
        keyboardActions = KeyboardActions(onDone = { vm.addCustomModel() }),
        modifier = Modifier.weight(1f),
      )
      Spacer(Modifier.width(8.dp))
      OutlinedButton(
        onClick = vm::addCustomModel,
        enabled = vm.customModelText.isNotBlank(),
        modifier = Modifier.padding(top = 8.dp).heightIn(min = 48.dp),
      ) { Text("Add and enable") }
    }
  }
}

@Composable
private fun ModelRow(
  id: String,
  info: ModelRowInfo?,
  enabled: Boolean,
  override: ModelOverride?,
  limitsFromAccount: Boolean,
  advanced: Boolean,
  onToggle: (Boolean) -> Unit,
  onEditLimits: () -> Unit,
) {
  val details = buildList {
    info?.displayName?.takeIf { it.isNotBlank() && it != id }?.let(::add)
    when {
      info == null -> Unit
      info.isCustom -> add("Added by you")
      info.isSuggested -> add("Suggested")
      info.isDiscovered -> add("From your account")
    }
    if (override?.hasLimits == true) add(if (limitsFromAccount) "Limits from your account" else "Custom limits")
    if (override?.supportsImages != null) add(if (override.supportsImages) "Photos on" else "Photos off")
  }.joinToString(" · ")

  Column(Modifier.fillMaxWidth()) {
    Row(
      modifier = Modifier
        .fillMaxWidth()
        .heightIn(min = 56.dp)
        .toggleable(value = enabled, role = Role.Switch, onValueChange = onToggle)
        .padding(horizontal = 16.dp, vertical = 8.dp),
      verticalAlignment = Alignment.CenterVertically,
    ) {
      Column(Modifier.weight(1f)) {
        Text(id, style = MaterialTheme.typography.bodyLarge)
        if (details.isNotEmpty()) {
          Text(details, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
      }
      Spacer(Modifier.width(12.dp))
      Switch(checked = enabled, onCheckedChange = null)
    }
    if (advanced) {
      TextButton(
        onClick = onEditLimits,
        modifier = Modifier.padding(start = 4.dp).heightIn(min = 48.dp),
      ) {
        Icon(Icons.Outlined.Tune, contentDescription = null, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text("Request limits for this model")
      }
    }
    HorizontalDivider(Modifier.padding(start = 16.dp))
  }
}

/**
 * Per-model overrides (advanced): context window, maximum output and photo capability. Values equal
 * to the resolved default are stored as "no override" so later catalog updates still apply.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ModelSettingsDialog(
  kind: ProviderKind,
  providerName: String,
  modelId: String,
  current: ModelOverride,
  onApply: (ModelOverride) -> Unit,
  onDismiss: () -> Unit,
) {
  val defaults = remember(kind, modelId) { BundledModelCatalog.resolvedLimits(kind, modelId) }
  val documented = remember(kind, modelId) { BundledModelCatalog.documentedLimits(kind, modelId) != null }
  val catalogPhotos = remember(kind, modelId) { BundledModelCatalog.supportsImages(kind, modelId) }
  var contextText by rememberSaveable { mutableStateOf((current.contextWindow ?: defaults.contextWindowTokens).toString()) }
  var outputText by rememberSaveable { mutableStateOf((current.maximumOutput ?: defaults.maximumOutputTokens).toString()) }
  // 0 = automatic, 1 = supports photos, 2 = text only (rememberSaveable-friendly).
  var photoMode by rememberSaveable {
    mutableIntStateOf(when (current.supportsImages) { null -> 0; true -> 1; false -> 2 })
  }

  val contextValue = contextText.trim().toIntOrNull()
  val outputValue = outputText.trim().toIntOrNull()
  val issue = RequestLimitPolicy.validationIssue(contextValue, outputValue)
  val budget = RequestLimitPolicy.estimatedInputBudget(contextValue, outputValue)
  val source = if (documented) "published limit" else "conservative estimate"

  Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
    Surface(Modifier.fillMaxSize()) {
      Scaffold(
        topBar = {
          TopAppBar(
            title = { Text("Model settings") },
            navigationIcon = {
              IconButton(onClick = onDismiss) { Icon(Icons.Filled.Close, contentDescription = "Cancel") }
            },
            actions = {
              TextButton(
                enabled = issue == null,
                onClick = {
                  onApply(
                    ModelOverride(
                      contextWindow = contextValue?.takeIf { it != defaults.contextWindowTokens },
                      maximumOutput = outputValue?.takeIf { it != defaults.maximumOutputTokens },
                      supportsImages = when (photoMode) { 1 -> true; 2 -> false; else -> null },
                    ),
                  )
                },
              ) { Text("Done") }
            },
          )
        },
      ) { padding ->
        Column(
          Modifier
            .padding(padding)
            .fillMaxSize()
            .imePadding()
            .verticalScroll(rememberScrollState())
            .padding(bottom = 24.dp),
        ) {
          Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
            SelectionContainer { Text(modelId, style = MaterialTheme.typography.titleMedium) }
            Text(providerName, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
          }

          SectionHeader("Request limits")
          OutlinedTextField(
            value = contextText,
            onValueChange = { contextText = it.filter(Char::isDigit).take(9) },
            label = { Text("Context window (tokens)") },
            supportingText = { Text("Default: ${formatCount(defaults.contextWindowTokens)} · $source") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Next),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
          )
          OutlinedTextField(
            value = outputText,
            onValueChange = { outputText = it.filter(Char::isDigit).take(9) },
            label = { Text("Maximum output (tokens)") },
            supportingText = { Text("Default: ${formatCount(defaults.maximumOutputTokens)} · $source") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
          )
          if (issue != null) {
            StatusLine(issue, StatusTone.ERROR)
          } else if (budget != null) {
            // Read-only: derived from the two limits above, never edited directly.
            StatusLine(
              "Input budget: about ${formatCount(budget)} tokens for messages, instructions and memory " +
                "(context window minus maximum output and a safety margin).",
              StatusTone.NEUTRAL,
            )
          }
          TextButton(
            onClick = {
              contextText = defaults.contextWindowTokens.toString()
              outputText = defaults.maximumOutputTokens.toString()
            },
            modifier = Modifier.padding(horizontal = 8.dp).heightIn(min = 48.dp),
          ) { Text("Use suggested limits") }

          SectionHeader("Photos")
          PhotoOption(
            title = "Automatic",
            subtitle = if (catalogPhotos) "The catalog lists photo input for this model." else "The catalog doesn't list photo input for this model.",
            selected = photoMode == 0,
            onClick = { photoMode = 0 },
          )
          PhotoOption("Supports photos", "Send attached photos to this model.", photoMode == 1) { photoMode = 1 }
          PhotoOption("Text only", "Never send photos to this model.", photoMode == 2) { photoMode = 2 }
          SectionFooter(
            "Use an override for custom deployments whose photo support the catalog can't know. These limits " +
              "apply only to this model. Suggested values are estimates; use the model's published limits when available.",
          )
        }
      }
    }
  }
}

@Composable
private fun PhotoOption(title: String, subtitle: String, selected: Boolean, onClick: () -> Unit) {
  Row(
    modifier = Modifier
      .fillMaxWidth()
      .heightIn(min = 56.dp)
      .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
      .padding(horizontal = 16.dp, vertical = 8.dp),
    verticalAlignment = Alignment.CenterVertically,
  ) {
    RadioButton(selected = selected, onClick = null)
    Spacer(Modifier.width(12.dp))
    Column {
      Text(title, style = MaterialTheme.typography.bodyLarge)
      Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
  }
}

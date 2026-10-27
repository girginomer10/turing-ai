package com.omergirgin.mosaic.ui.providers

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.KeyOff
import androidx.compose.material.icons.outlined.NetworkCheck
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.isLocalRuntime
import com.omergirgin.mosaic.core.provider.profile
import com.omergirgin.mosaic.core.provider.supportsChat
import com.omergirgin.mosaic.core.provider.supportsEmbeddings
import com.omergirgin.mosaic.core.provider.supportsModelDiscovery
import com.omergirgin.mosaic.data.model.AppSettings
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.components.ProviderLogo
import com.omergirgin.mosaic.ui.settings.Choice
import com.omergirgin.mosaic.ui.settings.ConfirmDialog
import com.omergirgin.mosaic.ui.settings.DiscardChangesDialog
import com.omergirgin.mosaic.ui.settings.EmptyState
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.SearchableChoiceDialog
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsLinkRow
import com.omergirgin.mosaic.ui.settings.SettingsParagraph
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import com.omergirgin.mosaic.ui.settings.SettingsSwitchRow
import com.omergirgin.mosaic.ui.settings.StatusLine
import com.omergirgin.mosaic.ui.settings.StatusTone
import com.omergirgin.mosaic.ui.settings.pluralize
import com.omergirgin.mosaic.ui.settings.successColor

/** Collapsed suggestion lists keep the form short; everything stays reachable via "Show all". */
private const val COLLAPSED_MODEL_COUNT = 8
private const val MAX_EXPANDED_MODEL_ROWS = 60

@Composable
internal fun ProviderEditorScreen(
  providerId: String?,
  initialKind: ProviderKind?,
  suggestedModel: String?,
  onBack: () -> Unit,
  onManageModels: (String) -> Unit,
  onSaved: (providerId: String, openModels: Boolean) -> Unit,
  onDeleted: () -> Unit,
) {
  val container = LocalAppContainer.current
  val vm: ProviderEditorViewModel = viewModel {
    ProviderEditorViewModel(container.providers, providerId, initialKind, suggestedModel)
  }
  val settings by remember(container) { container.settings.settings }
    .collectAsStateWithLifecycle(initialValue = AppSettings())
  val advanced = settings.advancedControls

  var confirmDiscard by rememberSaveable { mutableStateOf(false) }
  var confirmDelete by rememberSaveable { mutableStateOf(false) }
  var confirmRemoveKey by rememberSaveable { mutableStateOf(false) }
  var choosingKind by rememberSaveable { mutableStateOf(false) }
  var choosingTestModel by rememberSaveable { mutableStateOf(false) }

  LaunchedEffect(vm.event) {
    when (val event = vm.event) {
      is EditorEvent.Saved -> {
        vm.consumeEvent()
        onSaved(event.providerId, event.openModels)
      }
      EditorEvent.Deleted -> {
        vm.consumeEvent()
        onDeleted()
      }
      null -> Unit
    }
  }

  val requestBack: () -> Unit = {
    // While a write is in flight, leaving would hide its outcome, so back waits.
    if (!vm.isBusy) {
      if (vm.isDirty) confirmDiscard = true else onBack()
    }
  }
  BackHandler(enabled = vm.isBusy || vm.isDirty) { requestBack() }

  SettingsScaffold(
    title = if (vm.isNew) "Add AI service" else "Edit connection",
    onBack = requestBack,
    actions = {
      if (vm.isSaving) {
        CircularProgressIndicator(Modifier.padding(horizontal = 16.dp).size(24.dp), strokeWidth = 2.dp)
      } else if (!vm.isLoading && !vm.notFound) {
        TextButton(onClick = vm::save, enabled = !vm.isBusy) { Text("Save") }
      }
    },
  ) { padding ->
    when {
      vm.isLoading -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
      }
      vm.notFound -> EmptyState(
        title = "Connection not found",
        message = "This connection was deleted.",
        modifier = Modifier.padding(padding),
      ) { OutlinedButton(onClick = onBack) { Text("Go back") } }
      else -> EditorForm(
        vm = vm,
        advanced = advanced,
        modifier = Modifier.padding(padding),
        onChooseKind = { choosingKind = true },
        onManageModels = { vm.providerId?.let(onManageModels) },
        onChooseTestModel = { choosingTestModel = true },
        onRemoveKey = { confirmRemoveKey = true },
        onDelete = { confirmDelete = true },
      )
    }
  }

  if (choosingKind) {
    ProviderPresetDialog(
      selected = vm.kind,
      onSelect = {
        vm.changeKind(it)
        choosingKind = false
      },
      onDismiss = { choosingKind = false },
    )
  }
  if (choosingTestModel) {
    SearchableChoiceDialog(
      title = "Model to test",
      choices = vm.enabledModelIds.map { Choice(it, it, it) },
      selectedKey = vm.testModel,
      onSelect = {
        vm.testModel = it
        choosingTestModel = false
      },
      onDismiss = { choosingTestModel = false },
      searchLabel = "Search models",
      emptyMessage = "Enable a model in Manage models first.",
    )
  }
  if (confirmDiscard) {
    DiscardChangesDialog(
      message = "Your changes to this connection haven't been saved.",
      onDiscard = {
        confirmDiscard = false
        onBack()
      },
      onKeepEditing = { confirmDiscard = false },
    )
  }
  if (confirmRemoveKey) {
    ConfirmDialog(
      title = "Remove saved API key?",
      message = if (vm.kind.profile.requiresApiKey) {
        "This connection will stop working until you save a new key. The connection settings will remain."
      } else {
        "The saved key will be removed. This connection can keep working if its server does not require authentication."
      },
      confirmLabel = "Remove API key",
      onConfirm = {
        confirmRemoveKey = false
        vm.removeSavedKey()
      },
      onDismiss = { confirmRemoveKey = false },
    )
  }
  if (confirmDelete) {
    ConfirmDialog(
      title = "Delete ${vm.original?.displayName ?: "connection"}?",
      message = "The connection and its saved API key will be removed from this device. Conversations remain available.",
      confirmLabel = "Delete connection",
      onConfirm = {
        confirmDelete = false
        vm.delete()
      },
      onDismiss = { confirmDelete = false },
    )
  }
  vm.errorMessage?.let { MessageDialog("Couldn't complete action", it) { vm.errorMessage = null } }
}

@Composable
private fun EditorForm(
  vm: ProviderEditorViewModel,
  advanced: Boolean,
  modifier: Modifier,
  onChooseKind: () -> Unit,
  onManageModels: () -> Unit,
  onChooseTestModel: () -> Unit,
  onRemoveKey: () -> Unit,
  onDelete: () -> Unit,
) {
  val kind = vm.kind
  val profile = kind.profile
  Column(
    modifier
      .fillMaxSize()
      .imePadding()
      .verticalScroll(rememberScrollState())
      .padding(bottom = 32.dp),
  ) {
    EditorHeader(vm, advanced)

    if (vm.isNew && !advanced) {
      Card(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer),
      ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
          Text("Start chatting", style = MaterialTheme.typography.titleSmall)
          Text(
            "1. Choose your AI service below.\n" +
              (if (vm.kind.profile.requiresApiKey) "2. Add your API key.\n" else "2. Add an API key if your server requires one.\n") +
              "3. Save, then choose a model in your chat.",
          )
          Text(
            "Your key stays on this device, protected by Android Keystore. Messages go directly to your " +
              "selected service, which may charge for API use.",
            style = MaterialTheme.typography.bodySmall,
          )
        }
      }
    }

    SectionHeader("Service")
    ListItem(
      headlineContent = { Text("Service type") },
      supportingContent = { Text(profile.displayName) },
      leadingContent = { ProviderLogo(kind, size = 32.dp) },
      trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
      modifier = Modifier
        .fillMaxWidth()
        .heightIn(min = 56.dp)
        .clickable(enabled = !vm.isBusy, role = Role.Button, onClickLabel = "Choose a different service", onClick = onChooseKind)
        .semantics { contentDescription = "Service type, ${profile.displayName}" },
    )
    if (DisplayNamePolicy.usesCustomName(kind, advanced)) {
      OutlinedTextField(
        value = vm.displayName,
        onValueChange = { vm.displayName = it },
        label = { Text("Display name") },
        singleLine = true,
        isError = kind == ProviderKind.CUSTOM && vm.displayName.isBlank(),
        supportingText = if (kind == ProviderKind.CUSTOM && vm.displayName.isBlank()) {
          { Text("Enter a display name.") }
        } else null,
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Next),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
      )
    }
    SettingsSwitchRow(
      title = "Enabled",
      subtitle = "Disabled connections keep their settings but don't appear in model choices.",
      checked = vm.isEnabled,
      onCheckedChange = { vm.isEnabled = it },
    )

    ConnectionSection(vm, advanced, onRemoveKey)
    ModelsSection(vm, advanced, onManageModels)

    if (!vm.isNew && kind.supportsChat && !vm.kindChanged) {
      TestSection(vm, onChooseTestModel)
    }

    if (!vm.isNew) {
      HorizontalDivider(Modifier.padding(top = 24.dp))
      TextButton(
        onClick = onDelete,
        enabled = !vm.isBusy,
        colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
        modifier = Modifier.padding(horizontal = 8.dp, vertical = 8.dp).heightIn(min = 48.dp),
      ) {
        Icon(Icons.Outlined.Delete, contentDescription = null)
        Spacer(Modifier.width(8.dp))
        Text("Delete connection")
      }
    }
  }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun EditorHeader(vm: ProviderEditorViewModel, advanced: Boolean) {
  val profile = vm.kind.profile
  Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
    Row(verticalAlignment = Alignment.CenterVertically) {
      ProviderLogo(vm.kind, size = 52.dp)
      Spacer(Modifier.width(16.dp))
      Column(Modifier.weight(1f)) {
        Text(
          if (vm.isNew) "Connect ${profile.displayName}" else DisplayNamePolicy.resolved(vm.kind, vm.displayName),
          style = MaterialTheme.typography.titleLarge,
        )
        if (profile.serviceSummary.isNotBlank()) {
          Text(
            profile.serviceSummary,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
          )
        }
      }
    }
    if (advanced) {
      FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (vm.kind.supportsChat) CapabilityBadge("Chat")
        if (vm.kind.supportsEmbeddings) CapabilityBadge("Embeddings")
        if (vm.kind.supportsModelDiscovery) CapabilityBadge("Model catalog")
        CapabilityBadge(if (profile.requiresApiKey) "API key" else "Key optional")
      }
    }
  }
}

@Composable
private fun CapabilityBadge(title: String) {
  Text(
    title,
    style = MaterialTheme.typography.labelMedium,
    color = MaterialTheme.colorScheme.onSurfaceVariant,
    modifier = Modifier
      .background(MaterialTheme.colorScheme.surfaceVariant, CircleShape)
      .padding(horizontal = 10.dp, vertical = 6.dp),
  )
}

@Composable
private fun ConnectionSection(vm: ProviderEditorViewModel, advanced: Boolean, onRemoveKey: () -> Unit) {
  val kind = vm.kind
  val profile = kind.profile
  val defaultHost = EndpointForm.host(profile.baseUrl)
  val endpointIssue = vm.endpointIssue ?: vm.endpointServerIssue
  // Standard addresses stay visible but read-only in simple view; custom, local, resource-specific
  // or invalid endpoints are always editable so the simple presentation can't trap a connection.
  val endpointEditable = advanced || vm.endpointUnlocked || profile.baseUrl == null ||
    kind == ProviderKind.CUSTOM || kind.isLocalRuntime || EndpointForm.isLoopback(defaultHost) ||
    endpointIssue != null || EndpointForm.draftValue(kind, vm.endpoint) != null

  SectionHeader("Connection")
  if (endpointEditable) {
    OutlinedTextField(
      value = vm.endpoint,
      onValueChange = {
        vm.endpoint = it
        vm.endpointServerIssue = null
      },
      label = { Text(if (profile.baseUrl == null) "Service address (required)" else "Base URL") },
      placeholder = profile.baseUrl?.let { { Text(it) } },
      singleLine = true,
      isError = endpointIssue != null,
      supportingText = {
        Text(endpointIssue ?: "Include http or https and any API path prefix, such as /v1.")
      },
      keyboardOptions = KeyboardOptions(
        capitalization = KeyboardCapitalization.None,
        autoCorrectEnabled = false,
        keyboardType = KeyboardType.Uri,
        imeAction = ImeAction.Next,
      ),
      modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
    )
  } else {
    ListItem(
      headlineContent = { Text("Service address") },
      supportingContent = { Text(vm.endpoint) },
      trailingContent = {
        TextButton(onClick = { vm.endpointUnlocked = true }, enabled = !vm.isBusy) { Text("Change") }
      },
    )
  }
  if (EndpointForm.isLoopback(EndpointForm.host(EndpointForm.effective(kind, vm.endpoint)))) {
    StatusLine(
      "On a phone, localhost and 127.0.0.1 refer to the phone itself. To reach a server on your computer, " +
        "use the computer's local network address and allow the server to accept local connections. " +
        "The Android Emulator reaches your computer at 10.0.2.2.",
      StatusTone.WARNING,
    )
  }

  ApiKeyArea(vm, onRemoveKey)

  SectionFooter(connectionFooter(kind))
}

@Composable
private fun ApiKeyArea(vm: ProviderEditorViewModel, onRemoveKey: () -> Unit) {
  val profile = vm.kind.profile
  if (vm.savedKeyUsable && !vm.replacingKey) {
    // The stored value is never read back into the UI; only its presence is shown.
    ListItem(
      leadingContent = { Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = successColor()) },
      headlineContent = { Text("Key saved") },
      supportingContent = { Text("An API key is saved on this device. For your security it is never shown.") },
    )
    Row(Modifier.padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
      TextButton(onClick = { vm.replacingKey = true }, enabled = !vm.isBusy, modifier = Modifier.heightIn(min = 48.dp)) {
        Icon(Icons.Outlined.Key, contentDescription = null)
        Spacer(Modifier.width(8.dp))
        Text("Replace key")
      }
      TextButton(
        onClick = onRemoveKey,
        enabled = !vm.isBusy,
        colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
        modifier = Modifier.heightIn(min = 48.dp),
      ) {
        if (vm.isRemovingKey) {
          CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
        } else {
          Icon(Icons.Outlined.KeyOff, contentDescription = null)
        }
        Spacer(Modifier.width(8.dp))
        Text("Remove key")
      }
    }
    return
  }

  val supporting = when {
    vm.keyServerIssue != null -> vm.keyServerIssue.orEmpty()
    // Keys are bound to the exact service and address, so a new address needs the key again.
    vm.hasSavedKey && vm.destinationChanged && profile.requiresApiKey ->
      "Enter the key again for the new address. The saved key is bound to the previous address and is never sent to a different one."
    vm.hasSavedKey && vm.destinationChanged ->
      "Enter the key again for the new address. The saved key is bound to the previous address; if you save without a key, it is removed."
    vm.replacingKey -> "Leave empty to keep the saved key."
    profile.requiresApiKey -> "Required. Stored only on this device, protected by Android Keystore."
    else -> "Optional for ${profile.displayName}. If entered, it's stored only on this device."
  }
  OutlinedTextField(
    value = vm.apiKey,
    onValueChange = {
      vm.apiKey = it
      vm.keyServerIssue = null
    },
    label = { Text("API key") },
    singleLine = true,
    isError = vm.keyServerIssue != null,
    visualTransformation = PasswordVisualTransformation(),
    supportingText = { Text(supporting) },
    keyboardOptions = KeyboardOptions(
      capitalization = KeyboardCapitalization.None,
      autoCorrectEnabled = false,
      keyboardType = KeyboardType.Password,
      imeAction = ImeAction.Done,
    ),
    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
  )
  if (vm.replacingKey) {
    TextButton(
      onClick = {
        vm.replacingKey = false
        vm.apiKey = ""
      },
      modifier = Modifier.padding(horizontal = 8.dp).heightIn(min = 48.dp),
    ) { Text("Keep saved key") }
  }
}

@Composable
private fun ModelsSection(vm: ProviderEditorViewModel, advanced: Boolean, onManageModels: () -> Unit) {
  val kind = vm.kind
  SectionHeader("Models")
  when {
    !kind.supportsChat -> {
      SettingsParagraph(
        "This service provides embeddings only. Embedding-based memory arrives in a later Android update, " +
          "so this connection isn't used for chats.",
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
    vm.needsModelSelection -> InitialModelSelection(vm, advanced)
    else -> {
      SettingsLinkRow(
        title = "Manage models",
        subtitle = "${pluralize(vm.enabledModelCount, "model")} enabled",
        onClick = onManageModels,
        enabled = !vm.isBusy,
      )
      SectionFooter(
        if (kind.supportsModelDiscovery) {
          "Choose which models appear in your chats, or refresh to load the models available to your account. " +
            "Suggested models may need separate account access."
        } else {
          "This service does not publish a compatible live catalog here. Enable suggestions or add an exact " +
            "model ID from its current documentation."
        },
      )
    }
  }
}

@Composable
private fun InitialModelSelection(vm: ProviderEditorViewModel, advanced: Boolean) {
  var showAll by rememberSaveable(vm.kind) { mutableStateOf(false) }
  var filter by rememberSaveable(vm.kind) { mutableStateOf("") }
  val candidates = vm.modelCandidates
  val selected = vm.selectedModels
  val filterText = filter.trim()
  // Gateways ship hundreds of suggestions and this form isn't lazy, so the expanded view is
  // filtered and capped; selected models always stay visible.
  val matches = remember(candidates, filterText) {
    candidates.filter { filterText.isEmpty() || it.contains(filterText, ignoreCase = true) }
  }
  val visible = if (!showAll) {
    val head = candidates.take(COLLAPSED_MODEL_COUNT)
    head + candidates.filter { it in selected && it !in head }
  } else {
    (candidates.filter { it in selected } + matches.take(MAX_EXPANDED_MODEL_ROWS)).distinct()
  }
  val hiddenMatches = if (showAll) matches.size - MAX_EXPANDED_MODEL_ROWS else 0
  if (vm.kindChanged) {
    StatusLine(
      "Changing the service type replaces this connection's model list when you save.",
      StatusTone.NEUTRAL,
    )
  }
  if (showAll && candidates.size > COLLAPSED_MODEL_COUNT) {
    OutlinedTextField(
      value = filter,
      onValueChange = { filter = it },
      label = { Text("Filter suggestions") },
      singleLine = true,
      keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Search),
      modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
    )
  }
  visible.forEach { modelId ->
    val checked = modelId in selected
    Row(
      modifier = Modifier
        .fillMaxWidth()
        .heightIn(min = 48.dp)
        .toggleable(value = checked, role = Role.Checkbox, onValueChange = { vm.toggleModel(modelId, it) })
        .padding(horizontal = 16.dp),
      verticalAlignment = Alignment.CenterVertically,
    ) {
      Checkbox(checked = checked, onCheckedChange = null)
      Spacer(Modifier.width(12.dp))
      Text(modelId, style = MaterialTheme.typography.bodyLarge)
    }
  }
  if (hiddenMatches > 0) {
    SectionFooter("$hiddenMatches more match. Refine the filter, or enable more models in Manage models after saving.")
  }
  if (candidates.size > COLLAPSED_MODEL_COUNT) {
    TextButton(onClick = { showAll = !showAll }, modifier = Modifier.padding(horizontal = 8.dp).heightIn(min = 48.dp)) {
      Text(if (showAll) "Show fewer" else "Show all ${candidates.size} suggestions")
    }
  }
  // Exact IDs are an advanced control, but presets without suggestions (custom, local, Foundry,
  // Bedrock) can't be set up without one, so the field is always offered there.
  if (advanced || candidates.isEmpty()) {
    Row(
      modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
      verticalAlignment = Alignment.Top,
    ) {
      OutlinedTextField(
        value = vm.customModelText,
        onValueChange = {
          vm.customModelText = it
          vm.clearCustomModelIssue()
        },
        label = { Text(if (vm.kind == ProviderKind.MICROSOFT_FOUNDRY) "Deployment name" else "Exact model ID") },
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
      ) { Text("Add") }
    }
  }
  SectionFooter(
    when {
      vm.selectedModels.isEmpty() && vm.kind.supportsModelDiscovery ->
        "No model selected. After saving, Manage models opens so you can choose from the models available to your account."
      else ->
        "Choose which models appear in your chats. Suggested models may need separate account access; " +
          "after saving you can load the full catalog from your account."
    },
  )
}

@Composable
private fun TestSection(vm: ProviderEditorViewModel, onChooseTestModel: () -> Unit) {
  SectionHeader("Test connection")
  val hasModels = vm.enabledModelIds.isNotEmpty()
  ListItem(
    leadingContent = { Icon(Icons.Outlined.NetworkCheck, contentDescription = null) },
    headlineContent = { Text("Model") },
    supportingContent = { Text(vm.testModel ?: "Enable a model in Manage models first.") },
    trailingContent = if (hasModels) {
      { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) }
    } else null,
    modifier = Modifier
      .fillMaxWidth()
      .heightIn(min = 56.dp)
      .clickable(enabled = hasModels && !vm.isBusy, role = Role.Button, onClickLabel = "Choose model to test", onClick = onChooseTestModel),
  )
  OutlinedButton(
    onClick = vm::testConnection,
    enabled = hasModels && vm.testModel != null && vm.testState != ConnectionTestState.Testing && !vm.isBusy,
    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp).heightIn(min = 48.dp),
    shape = RoundedCornerShape(24.dp),
  ) {
    if (vm.testState == ConnectionTestState.Testing) {
      CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
      Spacer(Modifier.width(8.dp))
      Text("Testing…")
    } else {
      Text("Test connection")
    }
  }
  when (val state = vm.testState) {
    is ConnectionTestState.Success -> StatusLine(
      // A public catalog check proves reachability only, so it isn't called a connection success.
      if (vm.usesPublicCatalog) state.message else "Connection test succeeded. ${state.message}",
      StatusTone.SUCCESS,
    )
    is ConnectionTestState.Failure -> StatusLine("Connection test failed. ${state.message}", StatusTone.ERROR)
    else -> Unit
  }
  SectionFooter(
    if (vm.isDirty) {
      "Tests use the saved settings. Save your changes first to test them."
    } else {
      when {
        vm.usesPublicCatalog ->
          "Checks AI/ML API's public model catalog. The API key is not sent, so the key itself is not verified."
        vm.kind.supportsModelDiscovery ->
          "Checks the service's model list with your saved key; no prompt is sent. If no catalog is available, " +
            "one small request is sent to the selected model instead, which may use a small amount of provider credit."
        else ->
          "Sends one small request to the selected model. It may use a small amount of provider credit and " +
            "appears in Usage & cost as “Connection test”."
      }
    },
  )
}

private fun connectionFooter(kind: ProviderKind): String = when {
  kind == ProviderKind.MICROSOFT_FOUNDRY ->
    "Paste the resource endpoint ending in /openai/v1 and use the deployment name as the model ID. " +
      "The API key is stored only on this device."
  kind == ProviderKind.AMAZON_BEDROCK ->
    "Paste the regional Amazon Bedrock OpenAI-compatible endpoint ending in /openai/v1 and use a Bedrock " +
      "API key. The key is stored only on this device."
  kind == ProviderKind.TINFOIL ->
    "This preset uses Tinfoil's direct HTTPS-compatible API. Enclave attestation verification through " +
      "Tinfoil's SDK is not integrated yet. The key is stored only on this device."
  kind.profile.requiresApiKey ->
    "The key is stored only on this device, protected by Android Keystore. Remote addresses must use " +
      "HTTPS; HTTP is limited to local network addresses."
  else ->
    "An API key is optional for ${kind.profile.displayName}. Remote addresses must use HTTPS; HTTP is " +
      "limited to local network addresses."
}

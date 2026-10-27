package com.omergirgin.mosaic.ui.embeddings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.omergirgin.mosaic.core.provider.BundledModelCatalog
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.displayName
import com.omergirgin.mosaic.core.provider.isLocalRuntime
import com.omergirgin.mosaic.core.provider.profile
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfile
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfileDraft
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfilePolicy
import com.omergirgin.mosaic.data.model.ProviderConfig
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.Choice
import com.omergirgin.mosaic.ui.settings.ConfirmDialog
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.SearchableChoiceDialog
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsParagraph
import com.omergirgin.mosaic.ui.settings.SettingsSwitchRow
import java.util.Locale
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * iOS `EmbeddingProfileEditor`: one provider connection + one embedding model. Changing the
 * connection resets the model to the new preset's default unless the user typed a custom ID.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun EmbeddingProfileEditor(
  profile: EmbeddingProfile?,
  allProfiles: List<EmbeddingProfile>,
  providers: List<ProviderConfig>,
  busy: Boolean,
  onDismiss: () -> Unit,
  onDeleted: (warning: String?) -> Unit,
) {
  val repository = LocalAppContainer.current.embeddingProfiles
  val scope = rememberCoroutineScope()
  val initialProvider = providers.firstOrNull { it.id == profile?.providerId } ?: providers.firstOrNull().takeIf { profile == null }

  var displayName by rememberSaveable {
    mutableStateOf(profile?.displayName ?: initialProvider?.let { "${it.displayName} Embeddings" } ?: "Embedding Model")
  }
  var providerId by rememberSaveable { mutableStateOf(profile?.providerId ?: initialProvider?.id) }
  var modelId by rememberSaveable {
    mutableStateOf(profile?.modelId ?: initialProvider?.kind?.profile?.defaultEmbeddingModel.orEmpty())
  }
  var weight by rememberSaveable { mutableFloatStateOf((profile?.weight ?: 1.0).toFloat()) }
  var isEnabled by rememberSaveable { mutableStateOf(profile?.isEnabled ?: true) }
  var indexesConversations by rememberSaveable { mutableStateOf(profile?.indexesConversations ?: true) }
  var indexesDocuments by rememberSaveable { mutableStateOf(profile?.indexesDocuments ?: true) }
  var choosingProvider by rememberSaveable { mutableStateOf(false) }
  var suggestionsOpen by remember { mutableStateOf(false) }
  var confirmingDelete by rememberSaveable { mutableStateOf(false) }
  var saving by remember { mutableStateOf(false) }
  var error by remember { mutableStateOf<String?>(null) }

  val selectedProvider = providers.firstOrNull { it.id == providerId }
  val canSave = displayName.isNotBlank() && selectedProvider != null && modelId.isNotBlank() &&
    (indexesConversations || indexesDocuments) && !saving && !busy

  fun selectProvider(next: ProviderConfig) {
    val previousKind = selectedProvider?.kind
    val kindChanged = providerId != null && previousKind != next.kind
    val previousDefault = previousKind?.profile?.defaultEmbeddingModel
    if (kindChanged || modelId.isBlank() || modelId == previousDefault) {
      modelId = next.kind.profile.defaultEmbeddingModel.orEmpty()
    }
    if (displayName.isBlank() || displayName.endsWith(" Embeddings")) displayName = "${next.displayName} Embeddings"
    providerId = next.id
  }

  fun save() {
    val provider = selectedProvider ?: return
    if (isEnabled && allProfiles.count { it.isEnabled && it.id != profile?.id } >= EmbeddingProfilePolicy.MAXIMUM_ENABLED_PROFILES) {
      error = EmbeddingProfilePolicy.LIMIT_DESCRIPTION
      return
    }
    saving = true
    scope.launch {
      try {
        withContext(NonCancellable) {
          repository.saveProfile(
            EmbeddingProfileDraft(
              id = profile?.id,
              displayName = displayName,
              providerId = provider.id,
              modelId = modelId,
              weight = weight.toDouble(),
              isEnabled = isEnabled,
              indexesConversations = indexesConversations,
              indexesDocuments = indexesDocuments,
            )
          )
        }
        onDismiss()
      } catch (e: Exception) {
        error = e.message ?: "The embedding model couldn't be saved. Please try again."
      } finally {
        saving = false
      }
    }
  }

  Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
    Surface(Modifier.fillMaxSize()) {
      Scaffold(
        topBar = {
          TopAppBar(
            title = { Text(if (profile == null) "Add embedding model" else "Edit embedding model") },
            navigationIcon = {
              IconButton(onClick = onDismiss) { Icon(Icons.Filled.Close, contentDescription = "Cancel") }
            },
            actions = { TextButton(onClick = ::save, enabled = canSave) { Text("Save") } },
          )
        },
      ) { padding ->
        Column(
          Modifier.padding(padding).fillMaxSize().imePadding().verticalScroll(rememberScrollState()).padding(bottom = 32.dp)
        ) {
          SectionHeader("Model")
          OutlinedTextField(
            value = displayName,
            onValueChange = { displayName = it },
            label = { Text("Name") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Next),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
          )
          ListItem(
            headlineContent = { Text("Provider connection") },
            supportingContent = {
              Text(selectedProvider?.let { "${it.displayName} · ${it.kind.displayName}" } ?: "Choose a provider")
            },
            trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
            modifier = Modifier
              .fillMaxWidth()
              .heightIn(min = 56.dp)
              .clickable(role = Role.Button) { choosingProvider = true },
          )
          OutlinedTextField(
            value = modelId,
            onValueChange = { modelId = it.replace("\n", "") },
            label = { Text("Embedding model ID") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(
              capitalization = KeyboardCapitalization.None,
              autoCorrectEnabled = false,
              keyboardType = KeyboardType.Uri,
              imeAction = ImeAction.Done,
            ),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
          )
          val suggestions = selectedProvider?.let { BundledModelCatalog.embeddingModels(it.kind) }.orEmpty()
          if (suggestions.isNotEmpty()) {
            Box(Modifier.padding(horizontal = 8.dp)) {
              TextButton(onClick = { suggestionsOpen = true }) { Text("Choose a suggested model") }
              DropdownMenu(expanded = suggestionsOpen, onDismissRequest = { suggestionsOpen = false }) {
                for (identifier in suggestions) {
                  DropdownMenuItem(
                    text = { Text(identifier) },
                    onClick = {
                      modelId = identifier
                      suggestionsOpen = false
                    },
                  )
                }
              }
            }
          }

          SectionHeader("Sources")
          SettingsSwitchRow(
            title = "Previous conversations",
            checked = indexesConversations,
            onCheckedChange = { indexesConversations = it },
          )
          SettingsSwitchRow(
            title = "Imported documents",
            checked = indexesDocuments,
            onCheckedChange = { indexesDocuments = it },
          )
          SettingsSwitchRow(title = "Enabled", checked = isEnabled, onCheckedChange = { isEnabled = it })
          SectionFooter("At least one source must be enabled.")

          SectionHeader("Ensemble weight")
          Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
          ) {
            Slider(
              value = weight,
              onValueChange = { weight = (Math.round(it * 4) / 4f).coerceIn(0.25f, 2f) },
              valueRange = EmbeddingProfilePolicy.MINIMUM_WEIGHT.toFloat()..EmbeddingProfilePolicy.MAXIMUM_WEIGHT.toFloat(),
              steps = 6,
              modifier = Modifier.weight(1f).semantics { contentDescription = "Ensemble weight" },
            )
            Text(String.format(Locale.ROOT, "%.2f", weight), style = MaterialTheme.typography.bodyMedium)
          }
          SectionFooter("Higher weight gives this model more influence when rankings are combined.")

          selectedProvider?.let { provider ->
            SectionHeader("Suggested setup")
            SettingsParagraph(
              suggestion(provider.kind),
              color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            SettingsParagraph(
              "Recall sends the current query and selected chat or document excerpts to " +
                "${provider.displayName}. Remote calls may incur usage charges.",
              color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
          }

          if (profile != null) {
            SectionHeader("Danger zone")
            OutlinedButton(
              onClick = { confirmingDelete = true },
              enabled = !busy && !saving,
              colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
              modifier = Modifier.padding(horizontal = 16.dp),
            ) {
              Icon(Icons.Outlined.Delete, contentDescription = null)
              Text("Delete model", modifier = Modifier.padding(start = 8.dp))
            }
          }
        }
      }
    }
  }

  if (choosingProvider) {
    SearchableChoiceDialog(
      title = "Provider connection",
      choices = providers.map { Choice(it.id, it, it.displayName, it.kind.displayName) },
      selectedKey = providerId,
      onSelect = { provider ->
        choosingProvider = false
        selectProvider(provider)
      },
      onDismiss = { choosingProvider = false },
      emptyMessage = "Add and enable an embedding-capable connection in AI models & accounts first.",
    )
  }
  if (confirmingDelete && profile != null) {
    ConfirmDialog(
      title = "Delete this embedding model?",
      message = "Cached vectors for ${profile.displayName} will also be removed.",
      confirmLabel = "Delete model",
      onConfirm = {
        confirmingDelete = false
        saving = true
        scope.launch {
          try {
            val warning = withContext(NonCancellable) { repository.deleteProfile(profile.id) }
            onDeleted(warning)
          } catch (e: Exception) {
            error = "The embedding model could not be deleted: ${e.message ?: "please try again."}"
          } finally {
            saving = false
          }
        }
      },
      onDismiss = { confirmingDelete = false },
    )
  }
  error?.let { MessageDialog(title = "Embedding model couldn't be saved", message = it, onDismiss = { error = null }) }
}

private fun suggestion(kind: ProviderKind): String = when {
  kind == ProviderKind.TINFOIL ->
    "Tinfoil exposes nomic-embed-text here through direct HTTPS. Turing AI does not yet verify enclave attestation with Tinfoil’s SDK."
  kind.isLocalRuntime ->
    "Enter a model installed in this runtime, such as embeddinggemma. Each model keeps an independent vector space."
  else -> kind.profile.defaultEmbeddingModel?.let {
    "Start with $it, or enter any compatible embedding model ID available to this connection."
  } ?: "Enter an embedding model ID supported by this provider connection."
}

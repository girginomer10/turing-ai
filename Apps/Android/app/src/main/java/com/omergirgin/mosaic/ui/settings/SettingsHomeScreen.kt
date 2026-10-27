package com.omergirgin.mosaic.ui.settings

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.LibraryBooks
import androidx.compose.material.icons.outlined.Backup
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Hub
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Insights
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.BuildConfig
import com.omergirgin.mosaic.data.model.AppSettings
import com.omergirgin.mosaic.ui.LocalAppContainer
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val AUTOMATIC_DEFAULT_LABEL = "Use the most recently used model"

@Composable
internal fun SettingsHomeScreen(
  onBack: () -> Unit,
  onOpenProviders: () -> Unit,
  onOpenProjects: () -> Unit,
  onOpenMemory: () -> Unit,
  onOpenUsage: () -> Unit,
  onOpenNotices: () -> Unit,
  onOpenDocuments: () -> Unit = {},
  onOpenAutomations: () -> Unit = {},
  onOpenEmbeddings: () -> Unit = {},
  onOpenConnections: () -> Unit = {},
  onOpenDataRecovery: () -> Unit = {},
) {
  val container = LocalAppContainer.current
  val scope = rememberCoroutineScope()
  val settings by remember(container) { container.settings.settings }
    .collectAsStateWithLifecycle(initialValue = AppSettings())
  val providers by remember(container) { container.providers.observeProviders() }
    .collectAsStateWithLifecycle(initialValue = emptyList())
  val modelOptions by remember(container) { container.providers.observeModelOptions() }
    .collectAsStateWithLifecycle(initialValue = emptyList())
  var choosingDefault by rememberSaveable { mutableStateOf(false) }
  var error by remember { mutableStateOf<String?>(null) }

  SettingsScaffold(title = "Settings", onBack = onBack) { padding ->
    LazyColumn(
      modifier = Modifier.fillMaxSize().padding(padding),
      contentPadding = PaddingValues(bottom = 32.dp),
    ) {
      item(key = "ai-header") { SectionHeader("AI") }
      item(key = "providers") {
        SettingsLinkRow(
          title = "AI models & accounts",
          subtitle = when (providers.size) {
            0 -> "No AI services connected"
            1 -> "1 connection"
            else -> "${providers.size} connections"
          },
          icon = Icons.Outlined.Hub,
          onClick = onOpenProviders,
        )
      }
      item(key = "connections") {
        SettingsLinkRow(
          title = "Connections",
          subtitle = "Accounts, apps and on-device calendar and contacts",
          icon = Icons.Outlined.Link,
          onClick = onOpenConnections,
        )
      }
      item(key = "default-model") {
        SettingsLinkRow(
          title = "Default model for new chats",
          subtitle = modelChoiceLabel(settings.defaultModel, modelOptions, "Most recently used model"),
          icon = Icons.Outlined.Tune,
          onClick = { choosingDefault = true },
        )
      }

      item(key = "library-header") { SectionHeader("Library") }
      item(key = "projects") {
        SettingsLinkRow(
          title = "Projects",
          subtitle = "Shared instructions for related chats",
          icon = Icons.Outlined.Folder,
          onClick = onOpenProjects,
        )
      }
      item(key = "memory") {
        SettingsLinkRow(
          title = "Memory",
          subtitle = "Pinned facts, learned topics and events",
          icon = Icons.Outlined.Psychology,
          onClick = onOpenMemory,
        )
      }
      item(key = "documents") {
        SettingsLinkRow(
          title = "Documents",
          subtitle = "PDFs and text files your chats can draw on",
          icon = Icons.AutoMirrored.Outlined.LibraryBooks,
          onClick = onOpenDocuments,
        )
      }
      // Embedding settings are an advanced control (iOS parity); local recall is always on.
      if (settings.advancedControls) {
        item(key = "embeddings") {
          SettingsLinkRow(
            title = "Smart recall & embeddings",
            subtitle = "Local hybrid recall plus up to four embedding models",
            icon = Icons.Outlined.Hub,
            onClick = onOpenEmbeddings,
          )
        }
      }
      item(key = "usage") {
        SettingsLinkRow(
          title = "Usage & cost",
          subtitle = "Reported tokens and estimated spending",
          icon = Icons.Outlined.Insights,
          onClick = onOpenUsage,
        )
      }
      item(key = "automations") {
        SettingsLinkRow(
          title = "Automations",
          subtitle = "Scheduled prompts that run on this device",
          icon = Icons.Outlined.Schedule,
          onClick = onOpenAutomations,
        )
      }
      item(key = "data-recovery") {
        SettingsLinkRow(
          title = "Data & Recovery",
          subtitle = "Back up or restore your library (works with iOS)",
          icon = Icons.Outlined.Backup,
          onClick = onOpenDataRecovery,
        )
      }

      item(key = "controls-header") { SectionHeader("Appearance & controls") }
      item(key = "advanced") {
        SettingsSwitchRow(
          title = "Show advanced controls",
          checked = settings.advancedControls,
          onCheckedChange = { enabled ->
            scope.launch {
              runCatching { withContext(NonCancellable) { container.settings.setAdvancedControls(enabled) } }
                .onFailure { error = it.message ?: "The setting couldn't be saved. Please try again." }
            }
          },
        )
      }
      item(key = "advanced-footer") {
        SectionFooter(
          "Simple view keeps everyday features easy to find. Advanced controls add exact model IDs, " +
            "model limits, photo-capability overrides and service details. Switching views keeps your " +
            "chats, memory, connections and saved settings unchanged. This choice applies to this device.",
        )
      }

      item(key = "privacy-header") { SectionHeader("Privacy") }
      item(key = "privacy") {
        ListItem(
          leadingContent = { Icon(Icons.Outlined.Shield, contentDescription = null) },
          headlineContent = { Text("Your keys, your services") },
          supportingContent = {
            Text(
              "API keys stay on this device, protected by Android Keystore. Messages go directly from " +
                "this device to the AI service you choose, under that service's terms and billing. " +
                "There is no Turing AI server or account in between.",
            )
          },
        )
      }

      item(key = "about-header") { SectionHeader("About") }
      item(key = "version") {
        ListItem(
          leadingContent = { Icon(Icons.Outlined.Info, contentDescription = null) },
          headlineContent = { Text("Turing AI for Android") },
          supportingContent = { Text("Version ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})") },
        )
      }
      item(key = "notices") {
        HorizontalDivider()
        SettingsLinkRow(
          title = "Third-party notices",
          icon = Icons.Outlined.Description,
          onClick = onOpenNotices,
        )
      }
    }
  }

  if (choosingDefault) {
    ModelPickerDialog(
      title = "Default model",
      options = modelOptions,
      selected = settings.defaultModel,
      automaticLabel = AUTOMATIC_DEFAULT_LABEL,
      automaticDescription = "New chats start with the model you used most recently.",
      onSelect = { choice ->
        choosingDefault = false
        scope.launch {
          runCatching { withContext(NonCancellable) { container.settings.setDefaultModel(choice) } }
            .onFailure { error = it.message ?: "The default model couldn't be saved. Please try again." }
        }
      },
      onDismiss = { choosingDefault = false },
    )
  }
  error?.let { MessageDialog(title = "Couldn't save setting", message = it, onDismiss = { error = null }) }
}

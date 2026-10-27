package com.omergirgin.mosaic.ui.connections

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.Cloud
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Contacts
import androidx.compose.material.icons.outlined.Email
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.TableChart
import androidx.compose.material.icons.outlined.Workspaces
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.core.connections.ConnectorId
import com.omergirgin.mosaic.core.connections.ConnectorKind
import com.omergirgin.mosaic.data.connections.ConnectionStatus
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsLinkRow
import com.omergirgin.mosaic.ui.settings.SettingsScaffold

internal val ConnectorId.icon: ImageVector
  get() = when (kind) {
    ConnectorKind.CALENDAR -> Icons.Outlined.CalendarMonth
    ConnectorKind.TASKS -> Icons.Outlined.Checklist
    ConnectorKind.CONTACTS -> Icons.Outlined.Contacts
    ConnectorKind.MAIL -> Icons.Outlined.Email
    ConnectorKind.FILES -> Icons.Outlined.Folder
    ConnectorKind.CODE -> Icons.Outlined.Code
    ConnectorKind.CLOUD -> Icons.Outlined.Cloud
    ConnectorKind.BOOKMARKS -> Icons.Outlined.BookmarkBorder
    ConnectorKind.TABLE -> Icons.Outlined.TableChart
    ConnectorKind.WORKSPACE -> Icons.Outlined.Workspaces
  }

/** One-line state for catalog rows; always spelled out in text. */
internal fun ConnectionStatus?.summary(needsSetup: Boolean): String = when {
  this == null -> "Not connected"
  permissionNeeded -> "Permission needed"
  generation != null -> "Connected"
  needsSetup -> "Not available in this build"
  else -> "Not connected"
}

/**
 * Settings → Connections: the catalog (with its own small back stack into a connector's detail).
 * Each entry connects this device directly to the service; there is no Turing relay server.
 */
@Composable
fun ConnectionsHost(onBack: () -> Unit, initialService: ConnectorId? = null) {
  var selected by rememberSaveable { mutableStateOf(initialService?.rawId) }
  val service = selected?.let(ConnectorId::fromRawId)
  if (service != null) {
    BackHandler { selected = null }
    ConnectorDetailScreen(service, onBack = { if (initialService != null) onBack() else selected = null })
  } else {
    ConnectionsCatalogScreen(onBack = onBack, onOpen = { selected = it.rawId })
  }
}

@Composable
private fun ConnectionsCatalogScreen(onBack: () -> Unit, onOpen: (ConnectorId) -> Unit) {
  val repository = LocalAppContainer.current.connections
  val statuses by remember(repository) { repository.observeStatuses() }.collectAsStateWithLifecycle(initialValue = emptyList())
  var query by rememberSaveable { mutableStateOf("") }
  // Permissions can change in system settings while the app is in the background.
  LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { repository.refreshStatuses() }
  val visible = ConnectorId.entries.filter { query.isBlank() || it.title.contains(query.trim(), ignoreCase = true) }
  val byService = statuses.associateBy { it.service }
  val googleVisible = query.isBlank() || listOf("Google", "Gmail", "Drive").any { it.contains(query.trim(), ignoreCase = true) }

  SettingsScaffold(title = "Connections", onBack = onBack) { padding ->
    LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 32.dp)) {
      item(key = "search") {
        OutlinedTextField(
          value = query,
          onValueChange = { query = it },
          singleLine = true,
          leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
          placeholder = { Text("Find a connection") },
          modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        )
      }
      val device = visible.filter { it.isDevice }
      if (device.isNotEmpty()) {
        item(key = "device-header") { SectionHeader("On this device") }
        items(device, key = { it.rawId }) { service -> CatalogRow(service, byService[service], onOpen) }
      }
      val accounts = visible.filter { !it.isDevice }
      if (accounts.isNotEmpty()) {
        item(key = "accounts-header") { SectionHeader("Accounts & apps") }
        items(accounts, key = { it.rawId }) { service -> CatalogRow(service, byService[service], onOpen) }
      }
      if (googleVisible) {
        item(key = "google-header") { SectionHeader("Google") }
        item(key = "google") {
          ListItem(
            leadingContent = { Icon(Icons.Outlined.Email, contentDescription = null) },
            headlineContent = { Text("Gmail, Google Drive, Calendar & Tasks") },
            supportingContent = { Text("Not available on Android yet") },
          )
        }
      }
      item(key = "footer") {
        SectionFooter(
          "Connections go directly from this device to the service. Relevant results are shared with the model " +
            "you choose only when chat access is on. Account credentials stay on this device, protected by Android " +
            "Keystore. Connecting does not import an entire account into memory.",
        )
      }
    }
  }
}

@Composable
private fun CatalogRow(service: ConnectorId, status: ConnectionStatus?, onOpen: (ConnectorId) -> Unit) {
  val repository = LocalAppContainer.current.connections
  val needsSetup = service.needsClientRegistration && repository.effectiveClientId(service).isBlank()
  SettingsLinkRow(
    title = service.title,
    subtitle = status.summary(needsSetup),
    icon = service.icon,
    onClick = { onOpen(service) },
  )
}

package com.omergirgin.mosaic.ui.providers

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PauseCircle
import androidx.compose.material.icons.outlined.Redeem
import androidx.compose.material.icons.outlined.VerifiedUser
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.profile
import com.omergirgin.mosaic.data.api.ProviderRepository
import com.omergirgin.mosaic.data.model.AppSettings
import com.omergirgin.mosaic.data.model.ProviderConfig
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.components.ProviderLogo
import com.omergirgin.mosaic.ui.settings.ConfirmDialog
import com.omergirgin.mosaic.ui.settings.EmptyState
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsLinkRow
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import com.omergirgin.mosaic.ui.settings.pluralize
import com.omergirgin.mosaic.ui.settings.successColor
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal data class ProviderRowState(val config: ProviderConfig, val enabledModelCount: Int)

/** Saved connections joined with their enabled-model counts (per-provider catalog flows). */
@OptIn(ExperimentalCoroutinesApi::class)
internal fun observeProviderRows(repository: ProviderRepository): Flow<List<ProviderRowState>> =
  repository.observeProviders().flatMapLatest { providers ->
    if (providers.isEmpty()) {
      flowOf(emptyList())
    } else {
      combine(
        providers.map { config ->
          repository.observeModels(config.id).map { models ->
            ProviderRowState(config, models.count { it.isEnabled })
          }
        },
      ) { it.toList() }
    }
  }

@Composable
internal fun ProviderLibraryScreen(
  onBack: () -> Unit,
  onAddService: () -> Unit,
  onEditProvider: (String) -> Unit,
  onOpenFreeGuide: () -> Unit,
) {
  val container = LocalAppContainer.current
  val scope = rememberCoroutineScope()
  val rows by remember(container) { observeProviderRows(container.providers) }
    .collectAsStateWithLifecycle(initialValue = null)
  val settings by remember(container) { container.settings.settings }
    .collectAsStateWithLifecycle(initialValue = AppSettings())
  var pendingDeletion by remember { mutableStateOf<ProviderConfig?>(null) }
  var isDeleting by remember { mutableStateOf(false) }
  var error by remember { mutableStateOf<String?>(null) }

  SettingsScaffold(
    title = if (settings.advancedControls) "Providers" else "AI models & accounts",
    onBack = onBack,
    floatingActionButton = {
      if (!rows.isNullOrEmpty()) {
        ExtendedFloatingActionButton(
          onClick = onAddService,
          icon = { Icon(Icons.Filled.Add, contentDescription = null) },
          text = { Text("Add AI service") },
        )
      }
    },
  ) { padding ->
    val current = rows
    when {
      current == null -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
      }
      current.isEmpty() -> EmptyState(
        title = "No AI services yet",
        message = "Choose your AI service, add its API key, then start chatting. Requests are billed by " +
          "that service; a chat subscription may not include API access.",
        modifier = Modifier.padding(padding),
        header = { ProviderLogoCluster() },
      ) {
        Button(onClick = onAddService, modifier = Modifier.heightIn(min = 48.dp)) {
          Icon(Icons.Filled.Add, contentDescription = null)
          Spacer(Modifier.width(8.dp))
          Text("Add AI service")
        }
        OutlinedButton(onClick = onOpenFreeGuide, modifier = Modifier.heightIn(min = 48.dp)) {
          Icon(Icons.Outlined.Redeem, contentDescription = null)
          Spacer(Modifier.width(8.dp))
          Text("Explore free options")
        }
      }
      else -> LazyColumn(
        modifier = Modifier.fillMaxSize().padding(padding),
        contentPadding = PaddingValues(bottom = 96.dp),
      ) {
        item(key = "free") {
          SettingsLinkRow(
            title = "Explore free options",
            subtitle = "Services with a free API plan, and how to get a key",
            icon = Icons.Outlined.Redeem,
            onClick = onOpenFreeGuide,
          )
          HorizontalDivider()
        }
        item(key = "header") { SectionHeader("Connected services") }
        items(current, key = { it.config.id }) { row ->
          ProviderRow(
            row = row,
            enabled = !isDeleting,
            onOpen = { onEditProvider(row.config.id) },
            onDelete = { pendingDeletion = row.config },
          )
        }
        item(key = "footer") {
          Row(Modifier.padding(top = 8.dp), verticalAlignment = Alignment.Top) {
            Icon(
              Icons.Outlined.VerifiedUser,
              contentDescription = null,
              modifier = Modifier.padding(start = 16.dp, top = 8.dp).size(18.dp),
              tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            SectionFooter(
              "API keys stay on this device, protected by Android Keystore. Requests go directly from " +
                "this device to the selected service.",
            )
          }
        }
      }
    }
  }

  pendingDeletion?.let { config ->
    ConfirmDialog(
      title = "Delete ${config.displayName}?",
      message = "The connection and its saved API key will be removed from this device. Conversations remain available.",
      confirmLabel = "Delete connection",
      onConfirm = {
        pendingDeletion = null
        isDeleting = true
        scope.launch {
          try {
            // Deletion must finish even if the user leaves this screen mid-way.
            withContext(NonCancellable) { container.providers.deleteProvider(config.id) }
          } catch (e: Exception) {
            error = providerErrorMessage(e)
          } finally {
            isDeleting = false
          }
        }
      },
      onDismiss = { pendingDeletion = null },
    )
  }
  error?.let { MessageDialog(title = "Couldn't delete connection", message = it, onDismiss = { error = null }) }
}

@Composable
private fun ProviderRow(row: ProviderRowState, enabled: Boolean, onOpen: () -> Unit, onDelete: () -> Unit) {
  val config = row.config
  val profile = config.kind.profile
  var menuOpen by remember { mutableStateOf(false) }
  val modelSummary = pluralize(row.enabledModelCount, "model") + " enabled"
  val keyStatus = when {
    config.hasApiKey -> "Key saved"
    profile.requiresApiKey -> "API key missing"
    else -> "No key needed"
  }
  val serviceLine = if (config.displayName == profile.displayName) "" else "${profile.displayName} · "

  ListItem(
    leadingContent = { ProviderLogo(config.kind, size = 40.dp) },
    headlineContent = { Text(config.displayName) },
    supportingContent = {
      Text("$serviceLine$modelSummary\n$keyStatus")
    },
    trailingContent = {
      Row(verticalAlignment = Alignment.CenterVertically) {
        ProviderStatusBadge(config.isEnabled)
        Box {
          IconButton(onClick = { menuOpen = true }, enabled = enabled) {
            Icon(Icons.Filled.MoreVert, contentDescription = "More options for ${config.displayName}")
          }
          DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DropdownMenuItem(text = { Text("Edit connection") }, onClick = { menuOpen = false; onOpen() })
            DropdownMenuItem(
              text = { Text("Delete connection", color = MaterialTheme.colorScheme.error) },
              onClick = { menuOpen = false; onDelete() },
            )
          }
        }
      }
    },
    modifier = Modifier
      .fillMaxWidth()
      .heightIn(min = 72.dp)
      .clickable(enabled = enabled, role = Role.Button, onClickLabel = "Open settings", onClick = onOpen),
  )
}

/** Enabled state as words plus a symbol, never color alone. */
@Composable
internal fun ProviderStatusBadge(isEnabled: Boolean) {
  Row(
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(4.dp),
    modifier = Modifier
      .background(MaterialTheme.colorScheme.surfaceVariant, CircleShape)
      .padding(horizontal = 8.dp, vertical = 4.dp),
  ) {
    Icon(
      if (isEnabled) Icons.Filled.CheckCircle else Icons.Filled.PauseCircle,
      contentDescription = null,
      tint = if (isEnabled) successColor() else MaterialTheme.colorScheme.onSurfaceVariant,
      modifier = Modifier.size(14.dp),
    )
    Text(
      if (isEnabled) "Enabled" else "Disabled",
      style = MaterialTheme.typography.labelMedium,
      color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
  }
}

@Composable
private fun ProviderLogoCluster() {
  Row(
    horizontalArrangement = Arrangement.spacedBy((-6).dp),
    verticalAlignment = Alignment.CenterVertically,
    modifier = Modifier.clearAndSetSemantics { },
  ) {
    ProviderLogo(ProviderKind.OPENAI, modifier = Modifier.rotate(-7f), size = 42.dp)
    ProviderLogo(ProviderKind.ANTHROPIC, size = 48.dp)
    ProviderLogo(ProviderKind.DEEPINFRA, modifier = Modifier.rotate(7f), size = 42.dp)
  }
}

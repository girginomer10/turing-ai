package com.omergirgin.mosaic.ui.embeddings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Hub
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.core.provider.supportsEmbeddings
import com.omergirgin.mosaic.data.embeddings.DocumentIndexHealth
import com.omergirgin.mosaic.data.embeddings.DocumentIndexingOutcome
import com.omergirgin.mosaic.data.embeddings.DocumentProfileHealth
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfile
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfileAvailability
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfilePolicy
import com.omergirgin.mosaic.data.model.ProviderConfig
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsParagraph
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import com.omergirgin.mosaic.ui.settings.StatusLine
import com.omergirgin.mosaic.ui.settings.StatusTone
import com.omergirgin.mosaic.ui.settings.formatCount
import com.omergirgin.mosaic.ui.settings.successColor
import com.omergirgin.mosaic.ui.settings.warningColor
import java.util.Locale
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Editor target saved across configuration changes: "" = new profile, else the profile ID. */
private const val NEW_PROFILE = ""

/**
 * Smart recall settings (iOS `EmbeddingProfilesView`): the always-on local hybrid index, up to
 * four embedding profiles, and the rebuildable document-vector index health.
 */
@Composable
fun EmbeddingProfilesScreen(onBack: () -> Unit) {
  val container = LocalAppContainer.current
  val repository = container.embeddingProfiles
  val scope = rememberCoroutineScope()
  val profiles by remember(repository) { repository.observeProfiles() }
    .collectAsStateWithLifecycle(initialValue = null)
  val providers by remember(container) { container.providers.observeProviders() }
    .collectAsStateWithLifecycle(initialValue = emptyList())
  val indexing by repository.documentIndexing.collectAsStateWithLifecycle()

  var health by remember { mutableStateOf<DocumentIndexHealth?>(null) }
  var healthError by remember { mutableStateOf<String?>(null) }
  var healthRefresh by remember { mutableIntStateOf(0) }
  var editing by rememberSaveable { mutableStateOf<String?>(null) }
  var error by remember { mutableStateOf<String?>(null) }

  val compatibleProviders = providers.filter { it.isEnabled && it.kind.supportsEmbeddings }
  val busy = indexing.isRunning

  // Re-read health whenever profiles change, an indexing run finishes, or a refresh is requested.
  LaunchedEffect(repository, profiles, busy, healthRefresh) {
    if (busy) return@LaunchedEffect
    try {
      health = repository.documentIndexHealth()
      healthError = null
    } catch (e: CancellationException) {
      throw e
    } catch (e: Exception) {
      health = null
      healthError = "Document index health could not be read. Local lexical recall remains available."
    }
  }

  SettingsScaffold(
    title = "Embedding models",
    onBack = onBack,
    actions = {
      IconButton(onClick = { editing = NEW_PROFILE }, enabled = compatibleProviders.isNotEmpty() && !busy) {
        Icon(Icons.Filled.Add, contentDescription = "Add embedding model")
      }
    },
  ) { padding ->
    LazyColumn(
      modifier = Modifier.fillMaxSize().padding(padding),
      contentPadding = PaddingValues(bottom = 32.dp),
    ) {
      item(key = "builtin-header") { SectionHeader("Built in") }
      item(key = "builtin") {
        ListItem(
          leadingContent = { Icon(Icons.Outlined.Memory, contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
          headlineContent = { Text("Local hybrid index") },
          supportingContent = { Text("Always available · Turkish-aware lexical and character retrieval") },
        )
      }
      item(key = "builtin-footer") {
        SectionFooter(
          "This fallback runs entirely on the device and keeps recall working when an embedding model is offline."
        )
      }

      item(key = "ensemble-header") { SectionHeader("Embedding ensemble") }
      val rows = profiles
      when {
        rows == null -> item(key = "profiles-loading") { LoadingRow("Loading embedding models…") }
        rows.isEmpty() -> item(key = "profiles-empty") {
          Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("No embedding models", style = MaterialTheme.typography.titleMedium)
            Text(
              if (compatibleProviders.isEmpty()) {
                "Add and enable an embedding-capable connection in AI models & accounts first."
              } else {
                "Add Qwen, Nomic, or another compatible model to improve semantic recall."
              },
              style = MaterialTheme.typography.bodyMedium,
              color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (compatibleProviders.isNotEmpty()) {
              FilledTonalButton(onClick = { editing = NEW_PROFILE }, enabled = !busy) { Text("Add embedding model") }
            }
          }
        }
        else -> items(rows, key = { it.id }) { profile ->
          ProfileRow(
            profile = profile,
            providerName = providers.firstOrNull { it.id == profile.providerId }?.displayName,
            enabled = !busy,
            onEdit = { editing = profile.id },
            onToggle = { enabled ->
              if (enabled && rows.count { it.isEnabled && it.id != profile.id } >= EmbeddingProfilePolicy.MAXIMUM_ENABLED_PROFILES) {
                error = EmbeddingProfilePolicy.LIMIT_DESCRIPTION
              } else {
                scope.launch {
                  runCatching { withContext(NonCancellable) { repository.setProfileEnabled(profile.id, enabled) } }
                    .onFailure { error = it.message ?: "The embedding model couldn't be updated." }
                }
              }
            },
          )
        }
      }
      item(key = "ensemble-footer") {
        SectionFooter(
          "Up to four enabled models run in parallel. Turing AI keeps vector spaces separate and combines " +
            "rankings, so you can mix a local Qwen model with DeepInfra or Tinfoil. Enabling a profile sends " +
            "the current query and its selected chat or document excerpts to that connection; remote calls may " +
            "incur usage charges."
        )
      }

      item(key = "health-header") { SectionHeader("Document index health") }
      item(key = "health") {
        DocumentHealthSection(health = health, error = healthError, busy = busy)
      }
      item(key = "rebuild") {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
          OutlinedButton(
            onClick = { repository.rebuildDocumentIndex() },
            enabled = !busy && health?.canRebuild == true,
          ) {
            Icon(Icons.Outlined.Sync, contentDescription = null, modifier = Modifier.size(18.dp))
            Text("Rebuild all document vectors", modifier = Modifier.padding(start = 8.dp))
          }
        }
      }
      item(key = "indexing-status") {
        when {
          busy -> LoadingRow("Indexing enabled documents…")
          indexing.message != null -> StatusLine(
            text = indexing.message.orEmpty(),
            tone = when (indexing.outcome) {
              DocumentIndexingOutcome.FAILURE -> StatusTone.ERROR
              DocumentIndexingOutcome.WARNING -> StatusTone.WARNING
              else -> StatusTone.NEUTRAL
            },
          )
        }
      }
      item(key = "health-footer") {
        SectionFooter(
          "Rebuild clears document vectors for the active embedding models, then regenerates every enabled " +
            "document. Source text and local lexical recall remain available if a provider fails; remote models " +
            "may incur usage charges."
        )
      }
    }
  }

  editing?.let { target ->
    val existing = profiles?.firstOrNull { it.id == target }
    if (target != NEW_PROFILE && existing == null) {
      // Deleted elsewhere (or still loading): close once the list confirms it is gone.
      if (profiles != null) LaunchedEffect(target) { editing = null }
    } else {
      EmbeddingProfileEditor(
        profile = existing,
        allProfiles = profiles.orEmpty(),
        providers = editorProviders(compatibleProviders, providers, existing),
        busy = busy,
        onDismiss = { editing = null },
        onDeleted = { warning ->
          editing = null
          healthRefresh += 1
          if (warning != null) error = warning
        },
      )
    }
  }
  error?.let { MessageDialog(title = "Embedding models couldn't be updated", message = it, onDismiss = { error = null }) }
}

/** Compatible connections, plus the profile's current one even if it was disabled meanwhile. */
private fun editorProviders(
  compatible: List<ProviderConfig>,
  all: List<ProviderConfig>,
  profile: EmbeddingProfile?,
): List<ProviderConfig> {
  val current = profile?.providerId?.let { id -> all.firstOrNull { it.id == id && it.kind.supportsEmbeddings } }
  return if (current == null || compatible.any { it.id == current.id }) compatible else compatible + current
}

@Composable
private fun ProfileRow(
  profile: EmbeddingProfile,
  providerName: String?,
  enabled: Boolean,
  onEdit: () -> Unit,
  onToggle: (Boolean) -> Unit,
) {
  val description = buildList {
    add(providerName ?: "Missing provider")
    if (profile.indexesConversations) add("chats")
    if (profile.indexesDocuments) add("documents")
    add("weight " + String.format(Locale.ROOT, "%.2f", profile.weight))
  }.joinToString(" · ")
  ListItem(
    leadingContent = { Icon(Icons.Outlined.Hub, contentDescription = null) },
    headlineContent = { Text(profile.displayName) },
    supportingContent = {
      Column {
        Text(profile.modelId, style = MaterialTheme.typography.bodyMedium)
        Text(description, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
      }
    },
    trailingContent = {
      Switch(
        checked = profile.isEnabled,
        onCheckedChange = onToggle,
        enabled = enabled,
        modifier = Modifier.semantics { contentDescription = "Use ${profile.displayName}" },
      )
    },
    modifier = Modifier
      .fillMaxWidth()
      .heightIn(min = 56.dp)
      .clickable(enabled = enabled, role = Role.Button, onClick = onEdit),
  )
}

@Composable
private fun DocumentHealthSection(health: DocumentIndexHealth?, error: String?, busy: Boolean) {
  when {
    health != null -> Column {
      HealthValue("Enabled documents", formatCount(health.enabledDocumentCount))
      HealthValue("Text chunks", formatCount(health.chunkCount))
      HealthValue("Stored vectors", formatCount(health.storedVectorCount))
      HealthValue(
        "Current vectors",
        "${formatCount(health.validVectorCount)} / ${formatCount(health.expectedVectorCount)}",
        attention = health.needsAttention,
      )
      if (health.profiles.isEmpty()) {
        StatusLine("Enable an embedding model for imported documents to add vector recall.", StatusTone.NEUTRAL)
      } else {
        for (profile in health.profiles) ProfileHealthRow(profile, health.enabledDocumentCount)
      }
      if (health.orphanVectorCount > 0) {
        StatusLine(
          "${formatCount(health.orphanVectorCount)} orphaned document vectors can be removed by rebuilding.",
          StatusTone.WARNING,
        )
      }
      if (health.isTemporary) {
        StatusLine(
          "The persistent vector cache is unavailable. This index lasts only for the current session.",
          StatusTone.WARNING,
        )
      }
    }
    error != null -> StatusLine(error, StatusTone.WARNING)
    busy -> SettingsParagraph("Document vector health updates when indexing finishes.")
    else -> LoadingRow("Checking document vectors…")
  }
}

@Composable
private fun HealthValue(label: String, value: String, attention: Boolean = false) {
  Row(
    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
    horizontalArrangement = Arrangement.SpaceBetween,
  ) {
    Text(label, style = MaterialTheme.typography.bodyMedium)
    Text(
      value,
      style = MaterialTheme.typography.bodyMedium,
      color = if (attention) warningColor() else MaterialTheme.colorScheme.onSurfaceVariant,
    )
  }
}

@Composable
private fun ProfileHealthRow(profile: DocumentProfileHealth, documentCount: Int) {
  val status = when (profile.availability) {
    EmbeddingProfileAvailability.AVAILABLE -> if (profile.needsAttention) "Needs repair" else "Ready"
    EmbeddingProfileAvailability.PROVIDER_UNAVAILABLE -> "Provider unavailable"
    EmbeddingProfileAvailability.PROFILE_LIMIT_EXCEEDED -> "Outside four-model limit"
  }
  val expected = profile.expectedVectorCount
  Column(
    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
    verticalArrangement = Arrangement.spacedBy(6.dp),
  ) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
      Text(profile.displayName, style = MaterialTheme.typography.titleSmall)
      Text(
        status,
        style = MaterialTheme.typography.labelMedium,
        color = if (profile.needsAttention) warningColor() else successColor(),
      )
    }
    LinearProgressIndicator(
      progress = { if (expected == 0) 0f else profile.validVectorCount.toFloat() / expected },
      modifier = Modifier.fillMaxWidth().semantics {
        contentDescription = "${profile.displayName} document vector coverage"
        stateDescription = "${formatCount(profile.validVectorCount)} of ${formatCount(expected)} current"
      },
    )
    Text(
      "${formatCount(profile.indexedDocumentCount)} / ${formatCount(documentCount)} documents · " +
        "${formatCount(profile.validVectorCount)} / ${formatCount(expected)} current vectors",
      style = MaterialTheme.typography.bodySmall,
      color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    if (profile.missingVectorCount > 0 || profile.staleVectorCount > 0) {
      Text(
        "${formatCount(profile.missingVectorCount)} missing · ${formatCount(profile.staleVectorCount)} stale",
        style = MaterialTheme.typography.bodySmall,
        color = warningColor(),
      )
    }
  }
}

@Composable
private fun LoadingRow(text: String) {
  Row(
    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(10.dp),
  ) {
    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
    Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
  }
}

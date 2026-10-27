package com.omergirgin.mosaic.ui.root

import androidx.compose.runtime.saveable.Saver
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.ui.settings.SettingsDestination

/**
 * Keeps the open settings entry point across rotation and process recreation. Encoded as a
 * string list because [SettingsDestination] is a sealed contract owned by the settings UI.
 */
internal val SettingsDestinationSaver: Saver<SettingsDestination?, ArrayList<String>> = Saver(
  save = { destination ->
    when (destination) {
      null -> null
      SettingsDestination.Home -> arrayListOf("home")
      SettingsDestination.Providers -> arrayListOf("providers")
      SettingsDestination.FreeProviderGuide -> arrayListOf("free")
      is SettingsDestination.AddProvider -> arrayListOf("add", destination.kind?.rawId.orEmpty(), destination.suggestedModel.orEmpty())
      is SettingsDestination.EditProvider -> arrayListOf("edit", destination.providerId)
      SettingsDestination.Projects -> arrayListOf("projects")
      is SettingsDestination.Project -> arrayListOf("project", destination.projectId)
      SettingsDestination.Memory -> arrayListOf("memory")
      SettingsDestination.Usage -> arrayListOf("usage")
      SettingsDestination.Documents -> arrayListOf("documents")
      SettingsDestination.Automations -> arrayListOf("automations")
      SettingsDestination.Connections -> arrayListOf("connections")
      SettingsDestination.DataRecovery -> arrayListOf("data-recovery")
    }
  },
  restore = { saved ->
    when (saved.firstOrNull()) {
      "home" -> SettingsDestination.Home
      "providers" -> SettingsDestination.Providers
      "free" -> SettingsDestination.FreeProviderGuide
      "add" -> SettingsDestination.AddProvider(
        kind = saved.getOrNull(1)?.takeIf { it.isNotEmpty() }?.let(ProviderKind::fromRawId),
        suggestedModel = saved.getOrNull(2)?.takeIf { it.isNotEmpty() },
      )
      "edit" -> saved.getOrNull(1)?.let(SettingsDestination::EditProvider)
      "projects" -> SettingsDestination.Projects
      "project" -> saved.getOrNull(1)?.let(SettingsDestination::Project)
      "memory" -> SettingsDestination.Memory
      "usage" -> SettingsDestination.Usage
      "documents" -> SettingsDestination.Documents
      "automations" -> SettingsDestination.Automations
      "connections" -> SettingsDestination.Connections
      "data-recovery" -> SettingsDestination.DataRecovery
      else -> null
    }
  },
)

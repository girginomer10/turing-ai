package com.omergirgin.mosaic.ui.settings

import com.omergirgin.mosaic.core.provider.ProviderKind

/** Entry points into the settings area (owned by the settings/providers UI). */
sealed interface SettingsDestination {
  data object Home : SettingsDestination
  data object Providers : SettingsDestination
  data object FreeProviderGuide : SettingsDestination
  /** Opens the provider editor for a new connection, optionally preset to a kind and model. */
  data class AddProvider(val kind: ProviderKind? = null, val suggestedModel: String? = null) : SettingsDestination
  data class EditProvider(val providerId: String) : SettingsDestination
  data object Projects : SettingsDestination
  data class Project(val projectId: String) : SettingsDestination
  data object Memory : SettingsDestination
  data object Usage : SettingsDestination
  /** Imported documents library (PDF/Markdown/text import, OCR, availability). */
  data object Documents : SettingsDestination
  /** Scheduled prompts (one-time, daily, weekly) that run on this device. */
  data object Automations : SettingsDestination
  /** Device-direct connections catalog (accounts, apps and on-device calendar/contacts). */
  data object Connections : SettingsDestination
  /** Portable backup export and verified restore (`.mosaicbackup`, iOS-compatible). */
  data object DataRecovery : SettingsDestination
}

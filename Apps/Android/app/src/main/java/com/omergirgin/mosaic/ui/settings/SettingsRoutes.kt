package com.omergirgin.mosaic.ui.settings

import kotlinx.serialization.Serializable

/*
 * Type-safe navigation routes for the settings back stack. Provider kinds travel as their stable
 * raw IDs (same values as iOS) so routes stay plain strings and survive process death.
 */

@Serializable internal data object HomeRoute

@Serializable internal data object ProvidersRoute

@Serializable internal data object PresetChooserRoute

@Serializable
internal data class ProviderEditorRoute(
  val providerId: String? = null,
  val kindRawId: String? = null,
  val suggestedModel: String? = null,
)

@Serializable internal data class ManageModelsRoute(val providerId: String)

@Serializable internal data object FreeGuideRoute

@Serializable internal data class FreeGuideDetailRoute(val kindRawId: String)

@Serializable internal data object ProjectsRoute

@Serializable internal data class ProjectDetailRoute(val projectId: String)

@Serializable internal data class ProjectEditorRoute(val projectId: String? = null)

@Serializable internal data object MemoryRoute

@Serializable internal data class MemoryEditorRoute(val factId: String? = null)

/** One automatically learned topic: sources, provenance and change history. */
@Serializable internal data class LearnedTopicRoute(val topicId: String)

@Serializable internal data object UsageRoute

/** Searchable bundled price list with sources and review date (advanced Usage & cost). */
@Serializable internal data object ModelPricesRoute

@Serializable internal data object NoticesRoute

/** Device-direct connections catalog and connector details (own small back stack). */
@Serializable internal data object ConnectionsRoute

@Serializable internal data object DocumentsRoute

@Serializable internal data class DocumentDetailRoute(val documentId: String)

@Serializable internal data object AutomationsRoute

@Serializable internal data class AutomationEditorRoute(val taskId: String? = null)

/** Smart recall: embedding profiles and document index health (advanced controls). */
@Serializable internal data object EmbeddingsRoute

/** Portable backup export and restore. */
@Serializable internal data object DataRecoveryRoute

internal fun SettingsDestination.toRoute(): Any = when (this) {
  SettingsDestination.Home -> HomeRoute
  SettingsDestination.Providers -> ProvidersRoute
  SettingsDestination.FreeProviderGuide -> FreeGuideRoute
  // Without a preset the user picks one first; the chooser then replaces itself with the editor.
  is SettingsDestination.AddProvider ->
    if (kind == null) PresetChooserRoute
    else ProviderEditorRoute(kindRawId = kind.rawId, suggestedModel = suggestedModel)
  is SettingsDestination.EditProvider -> ProviderEditorRoute(providerId = providerId)
  SettingsDestination.Projects -> ProjectsRoute
  is SettingsDestination.Project -> ProjectDetailRoute(projectId)
  SettingsDestination.Memory -> MemoryRoute
  SettingsDestination.Usage -> UsageRoute
  SettingsDestination.Documents -> DocumentsRoute
  SettingsDestination.Automations -> AutomationsRoute
  SettingsDestination.Connections -> ConnectionsRoute
  SettingsDestination.DataRecovery -> DataRecoveryRoute
}

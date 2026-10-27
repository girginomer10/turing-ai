package com.omergirgin.mosaic.ui.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.lifecycle.Lifecycle
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavHostController
import androidx.navigation.NavOptionsBuilder
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.ui.backup.DataRecoveryScreen
import com.omergirgin.mosaic.ui.connections.ConnectionsHost
import com.omergirgin.mosaic.ui.documents.DocumentDetailScreen
import com.omergirgin.mosaic.ui.documents.DocumentsScreen
import com.omergirgin.mosaic.ui.embeddings.EmbeddingProfilesScreen
import com.omergirgin.mosaic.ui.memory.LearnedTopicScreen
import com.omergirgin.mosaic.ui.memory.MemoryEditorScreen
import com.omergirgin.mosaic.ui.memory.MemoryScreen
import com.omergirgin.mosaic.ui.projects.ProjectDetailScreen
import com.omergirgin.mosaic.ui.projects.ProjectEditorScreen
import com.omergirgin.mosaic.ui.projects.ProjectsScreen
import com.omergirgin.mosaic.ui.providers.FreeProviderDetailScreen
import com.omergirgin.mosaic.ui.providers.FreeProviderGuideScreen
import com.omergirgin.mosaic.ui.providers.ManageModelsScreen
import com.omergirgin.mosaic.ui.providers.ProviderEditorScreen
import com.omergirgin.mosaic.ui.providers.ProviderLibraryScreen
import com.omergirgin.mosaic.ui.providers.ProviderPresetChooserScreen
import com.omergirgin.mosaic.ui.usage.ModelPriceListScreen
import com.omergirgin.mosaic.ui.usage.UsageScreen
import com.omergirgin.mosaic.ui.tasks.AutomationEditorScreen
import com.omergirgin.mosaic.ui.tasks.AutomationsScreen

/**
 * Full-screen host with its own back stack. [onClose] returns to chat; [onOpenConversation] and
 * [onStartChatInProject] hand control back to the chat UI (closing settings first).
 */
@Composable
fun SettingsHost(
  start: SettingsDestination,
  onClose: () -> Unit,
  onOpenConversation: (conversationId: String) -> Unit,
  onStartChatInProject: (projectId: String) -> Unit,
) {
  // A different entry point is a different flow: rebuild the stack instead of stacking on top.
  key(start) {
    val navController = rememberNavController()
    val currentEntry by navController.currentBackStackEntryAsState()
    // NavHost consumes system back while it can pop; at the root, back leaves settings.
    val atRoot = currentEntry != null && navController.previousBackStackEntry == null
    BackHandler(enabled = atRoot) { onClose() }

    val nav = remember(navController, onClose) { SettingsNavigator(navController, onClose) }
    val startRoute = remember { start.toRoute() }

    NavHost(navController = navController, startDestination = startRoute, modifier = Modifier.fillMaxSize()) {
      composable<HomeRoute> { entry ->
        SettingsHomeScreen(
          onBack = { nav.back(entry) },
          onOpenProviders = { nav.go(entry, ProvidersRoute) },
          onOpenProjects = { nav.go(entry, ProjectsRoute) },
          onOpenMemory = { nav.go(entry, MemoryRoute) },
          onOpenUsage = { nav.go(entry, UsageRoute) },
          onOpenNotices = { nav.go(entry, NoticesRoute) },
          onOpenDocuments = { nav.go(entry, DocumentsRoute) },
          onOpenAutomations = { nav.go(entry, AutomationsRoute) },
          onOpenEmbeddings = { nav.go(entry, EmbeddingsRoute) },
          onOpenConnections = { nav.go(entry, ConnectionsRoute) },
          onOpenDataRecovery = { nav.go(entry, DataRecoveryRoute) },
        )
      }
      composable<DataRecoveryRoute> { entry ->
        DataRecoveryScreen(onBack = { nav.back(entry) })
      }
      composable<ConnectionsRoute> { entry ->
        ConnectionsHost(onBack = { nav.back(entry) })
      }
      composable<EmbeddingsRoute> { entry ->
        EmbeddingProfilesScreen(onBack = { nav.back(entry) })
      }
      composable<NoticesRoute> { entry -> ThirdPartyNoticesScreen(onBack = { nav.back(entry) }) }

      composable<ProvidersRoute> { entry ->
        ProviderLibraryScreen(
          onBack = { nav.back(entry) },
          onAddService = { nav.go(entry, PresetChooserRoute) },
          onEditProvider = { id -> nav.go(entry, ProviderEditorRoute(providerId = id)) },
          onOpenFreeGuide = { nav.go(entry, FreeGuideRoute) },
        )
      }
      composable<PresetChooserRoute> { entry ->
        ProviderPresetChooserScreen(
          onBack = { nav.back(entry) },
          onSelect = { kind ->
            // The chooser is only a step: back from the editor returns to where "Add" was tapped.
            nav.go(entry, ProviderEditorRoute(kindRawId = kind.rawId)) {
              popUpTo<PresetChooserRoute> { inclusive = true }
            }
          },
        )
      }
      composable<ProviderEditorRoute> { entry ->
        val route = entry.toRoute<ProviderEditorRoute>()
        ProviderEditorScreen(
          providerId = route.providerId,
          initialKind = route.kindRawId?.let { ProviderKind.fromRawId(it) },
          suggestedModel = route.suggestedModel,
          onBack = { nav.back(entry) },
          onManageModels = { id -> nav.go(entry, ManageModelsRoute(id)) },
          onSaved = { savedId, openModels ->
            if (openModels) {
              nav.go(entry, ManageModelsRoute(savedId)) { popUpTo<ProviderEditorRoute> { inclusive = true } }
            } else {
              nav.back(entry)
            }
          },
          onDeleted = { nav.back(entry) },
        )
      }
      composable<ManageModelsRoute> { entry ->
        val route = entry.toRoute<ManageModelsRoute>()
        ManageModelsScreen(providerId = route.providerId, onBack = { nav.back(entry) })
      }
      composable<FreeGuideRoute> { entry ->
        FreeProviderGuideScreen(
          onBack = { nav.back(entry) },
          onOpenOption = { kind -> nav.go(entry, FreeGuideDetailRoute(kind.rawId)) },
        )
      }
      composable<FreeGuideDetailRoute> { entry ->
        val route = entry.toRoute<FreeGuideDetailRoute>()
        FreeProviderDetailScreen(
          kind = ProviderKind.fromRawId(route.kindRawId),
          onBack = { nav.back(entry) },
          onAddKey = { kind, model ->
            nav.go(entry, ProviderEditorRoute(kindRawId = kind.rawId, suggestedModel = model))
          },
        )
      }

      composable<ProjectsRoute> { entry ->
        ProjectsScreen(
          onBack = { nav.back(entry) },
          onOpenProject = { id -> nav.go(entry, ProjectDetailRoute(id)) },
          onCreateProject = { nav.go(entry, ProjectEditorRoute()) },
          onEditProject = { id -> nav.go(entry, ProjectEditorRoute(id)) },
          onStartChatInProject = onStartChatInProject,
        )
      }
      composable<ProjectDetailRoute> { entry ->
        val route = entry.toRoute<ProjectDetailRoute>()
        ProjectDetailScreen(
          projectId = route.projectId,
          onBack = { nav.back(entry) },
          onEdit = { nav.go(entry, ProjectEditorRoute(route.projectId)) },
          onOpenConversation = onOpenConversation,
          onStartChatInProject = onStartChatInProject,
        )
      }
      composable<ProjectEditorRoute> { entry ->
        val route = entry.toRoute<ProjectEditorRoute>()
        ProjectEditorScreen(projectId = route.projectId, onBack = { nav.back(entry) })
      }

      composable<MemoryRoute> { entry ->
        MemoryScreen(
          onBack = { nav.back(entry) },
          onAdd = { nav.go(entry, MemoryEditorRoute()) },
          onEdit = { id -> nav.go(entry, MemoryEditorRoute(id)) },
          onOpenTopic = { id -> nav.go(entry, LearnedTopicRoute(id)) },
          onOpenDocuments = { nav.go(entry, DocumentsRoute) },
          onOpenEmbeddings = { nav.go(entry, EmbeddingsRoute) },
        )
      }
      composable<MemoryEditorRoute> { entry ->
        val route = entry.toRoute<MemoryEditorRoute>()
        MemoryEditorScreen(factId = route.factId, onBack = { nav.back(entry) })
      }
      composable<LearnedTopicRoute> { entry ->
        val route = entry.toRoute<LearnedTopicRoute>()
        LearnedTopicScreen(topicId = route.topicId, onBack = { nav.back(entry) })
      }

      composable<UsageRoute> { entry ->
        UsageScreen(onBack = { nav.back(entry) }, onOpenPriceList = { nav.go(entry, ModelPricesRoute) })
      }
      composable<ModelPricesRoute> { entry ->
        ModelPriceListScreen(onBack = { nav.back(entry) })
      }

      composable<AutomationsRoute> { entry ->
        AutomationsScreen(
          onBack = { nav.back(entry) },
          onCreate = { nav.go(entry, AutomationEditorRoute()) },
          onEdit = { id -> nav.go(entry, AutomationEditorRoute(id)) },
          onOpenConversation = onOpenConversation,
          onOpenProviders = { nav.go(entry, ProvidersRoute) },
        )
      }
      composable<AutomationEditorRoute> { entry ->
        val route = entry.toRoute<AutomationEditorRoute>()
        AutomationEditorScreen(
          taskId = route.taskId,
          onBack = { nav.back(entry) },
          onOpenConversation = onOpenConversation,
        )
      }

      composable<DocumentsRoute> { entry ->
        DocumentsScreen(
          onBack = { nav.back(entry) },
          onOpenDocument = { id -> nav.go(entry, DocumentDetailRoute(id)) },
        )
      }
      composable<DocumentDetailRoute> { entry ->
        val route = entry.toRoute<DocumentDetailRoute>()
        DocumentDetailScreen(documentId = route.documentId, onBack = { nav.back(entry) })
      }
    }
  }
}

/**
 * Navigation guarded by the calling entry's lifecycle: a second tap during a transition (when the
 * entry is no longer RESUMED) is dropped, so double taps never pop or push twice.
 */
private class SettingsNavigator(
  private val navController: NavHostController,
  private val onClose: () -> Unit,
) {
  fun back(from: NavBackStackEntry) {
    if (from.lifecycle.currentState != Lifecycle.State.RESUMED) return
    if (navController.previousBackStackEntry != null) navController.popBackStack() else onClose()
  }

  fun go(from: NavBackStackEntry, route: Any, builder: NavOptionsBuilder.() -> Unit = {}) {
    if (from.lifecycle.currentState != Lifecycle.State.RESUMED) return
    navController.navigate(route, builder)
  }
}

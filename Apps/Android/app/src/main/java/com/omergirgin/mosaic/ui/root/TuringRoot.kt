package com.omergirgin.mosaic.ui.root

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.PermanentDrawerSheet
import androidx.compose.material3.PermanentNavigationDrawer
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.chat.ChatViewModel
import com.omergirgin.mosaic.ui.chat.ConversationScreen
import com.omergirgin.mosaic.ui.components.show
import com.omergirgin.mosaic.ui.settings.SettingsDestination
import com.omergirgin.mosaic.ui.settings.SettingsHost
import com.omergirgin.mosaic.ui.tasks.AutomationLaunchRequests
import com.omergirgin.mosaic.ui.chat.temporary.TemporaryChatScreen
import com.omergirgin.mosaic.ui.chat.temporary.TemporaryChatViewModel
import com.omergirgin.mosaic.ui.share.SharedItemsLaunchRequests
import com.omergirgin.mosaic.ui.share.SharedItemsScreen
import androidx.compose.ui.semantics.clearAndSetSemantics
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/** Width at which chat history becomes a permanent side list instead of a modal drawer. */
private val PermanentHistoryBreakpoint = 840.dp

/**
 * App shell. Chat is the main surface; the settings area (projects, memory, providers, usage,
 * settings) is a full-screen destination with its own back stack that hands control back to chat.
 */
@Composable
fun TuringRoot() {
  val container = LocalAppContainer.current
  val chatVm: ChatViewModel = viewModel { ChatViewModel(container, createSavedStateHandle()) }
  val historyVm: HistoryViewModel = viewModel { HistoryViewModel(container) }
  var settingsRoute by rememberSaveable(stateSaver = SettingsDestinationSaver) {
    mutableStateOf<SettingsDestination?>(null)
  }

  // Fallback only: SettingsHost's own back handlers are registered later and win while it can pop.
  BackHandler(enabled = settingsRoute != null) { settingsRoute = null }

  // Scheduled-prompt notification taps (MainActivity): open the result chat, or Automations.
  LaunchedEffect(chatVm) {
    AutomationLaunchRequests.pending.collect { request ->
      request ?: return@collect
      AutomationLaunchRequests.consume(request)
      when (request) {
        is AutomationLaunchRequests.Request.OpenConversation -> {
          settingsRoute = null
          chatVm.openConversation(request.conversationId)
        }
        AutomationLaunchRequests.Request.OpenAutomations -> settingsRoute = SettingsDestination.Automations
      }
    }
  }

  // Conversation tools: full-screen overlays above chat and settings. Temporary Chat's open state
  // lives in its view model, so it survives rotation but never process death.
  val temporaryChatVm: TemporaryChatViewModel = viewModel { TemporaryChatViewModel(container) }
  var sharedItemsOpen by rememberSaveable { mutableStateOf(false) }
  val sharedItemCount by remember(container) {
    container.sharedItems.observeItems().map { it.size }.catch { emit(0) }
  }.collectAsStateWithLifecycle(initialValue = 0)
  val toolOpen = sharedItemsOpen || temporaryChatVm.isOpen
  // Share screen "Save and open Turing AI". Only a started activity consumes the request, so a
  // second instance hidden in the back stack never takes it.
  val lifecycleOwner = LocalLifecycleOwner.current
  LaunchedEffect(lifecycleOwner) {
    lifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
      SharedItemsLaunchRequests.pending.collect { pending ->
        if (!pending) return@collect
        SharedItemsLaunchRequests.consume()
        settingsRoute = null
        temporaryChatVm.close()
        sharedItemsOpen = true
      }
    }
  }
  val openTemporaryChat = { temporaryChatVm.open() }
  val openSharedItems = { sharedItemsOpen = true }

  AnimatedContent(
    targetState = settingsRoute,
    contentKey = { it != null },
    transitionSpec = {
      if (targetState != null) {
        (slideInHorizontally { it / 4 } + fadeIn()) togetherWith fadeOut()
      } else {
        fadeIn() togetherWith (slideOutHorizontally { it / 4 } + fadeOut())
      }
    },
    modifier = Modifier
      .fillMaxSize()
      .background(MaterialTheme.colorScheme.background)
      // Covered by a conversation tool: keep TalkBack out of the hidden shell.
      .then(if (toolOpen) Modifier.clearAndSetSemantics {} else Modifier),
    label = "settings",
  ) { route ->
    if (route == null) {
      ChatShell(
        chatVm = chatVm,
        historyVm = historyVm,
        openSettings = { settingsRoute = it },
        openTemporaryChat = openTemporaryChat,
        openSharedItems = openSharedItems,
        sharedItemCount = sharedItemCount,
      )
    } else {
      SettingsHost(
        start = route,
        onClose = { settingsRoute = null },
        onOpenConversation = { id ->
          settingsRoute = null
          chatVm.openConversation(id)
        },
        onStartChatInProject = { projectId ->
          settingsRoute = null
          chatVm.newChat(projectId)
        },
      )
    }
  }

  // Both are opaque full-screen surfaces stacked above the shell (Surface blocks touches below).
  if (sharedItemsOpen) {
    SharedItemsScreen(
      onBack = { sharedItemsOpen = false },
      onOpenDraft = { draft ->
        sharedItemsOpen = false
        settingsRoute = null
        chatVm.openDraft(draft.conversationId, draft.attachments)
      },
    )
  }
  if (temporaryChatVm.isOpen) TemporaryChatScreen(temporaryChatVm)
}

@Composable
private fun ChatShell(
  chatVm: ChatViewModel,
  historyVm: HistoryViewModel,
  openSettings: (SettingsDestination) -> Unit,
  openTemporaryChat: () -> Unit,
  openSharedItems: () -> Unit,
  sharedItemCount: Int,
) {
  val chatSnackbar = remember { SnackbarHostState() }
  // Drawer actions get their own host above the drawer; the chat host sits under it.
  val historySnackbar = remember { SnackbarHostState() }
  LaunchedEffect(chatVm) { chatVm.notices.collect { chatSnackbar.show(it) } }
  LaunchedEffect(historyVm) { historyVm.notices.collect { historySnackbar.show(it) } }

  val currentId by chatVm.conversationId.collectAsStateWithLifecycle()
  val settings by chatVm.settings.collectAsStateWithLifecycle()
  val focusManager = LocalFocusManager.current
  val scope = rememberCoroutineScope()
  val drawerState = rememberDrawerState(DrawerValue.Closed)

  // However the drawer opens (button or edge swipe), the keyboard shouldn't stay up behind it.
  LaunchedEffect(drawerState.targetValue) {
    if (drawerState.targetValue == DrawerValue.Open) focusManager.clearFocus()
  }

  BoxWithConstraints(Modifier.fillMaxSize()) {
    val wide = maxWidth >= PermanentHistoryBreakpoint

    @Composable
    fun History(modal: Boolean) {
      fun closeDrawer() {
        if (modal) scope.launch { drawerState.close() }
      }
      HistoryDrawerContent(
        vm = historyVm,
        currentConversationId = currentId,
        advancedControls = settings.advancedControls,
        onClose = if (modal) ({ closeDrawer() }) else null,
        onNewChat = {
          chatVm.newChat()
          closeDrawer()
        },
        onOpenConversation = { id ->
          chatVm.openConversation(id)
          closeDrawer()
        },
        onOpenSettings = { destination ->
          if (modal) scope.launch { drawerState.snapTo(DrawerValue.Closed) }
          openSettings(destination)
        },
        onConversationArchived = chatVm::onConversationArchived,
        onOpenTemporaryChat = {
          if (modal) scope.launch { drawerState.snapTo(DrawerValue.Closed) }
          openTemporaryChat()
        },
        onOpenSharedItems = {
          if (modal) scope.launch { drawerState.snapTo(DrawerValue.Closed) }
          openSharedItems()
        },
        sharedItemCount = sharedItemCount,
      )
    }

    @Composable
    fun Chat(onOpenHistory: (() -> Unit)?) {
      ChatSurface(
        chatVm = chatVm,
        snackbarHostState = chatSnackbar,
        onOpenHistory = onOpenHistory,
        openSettings = openSettings,
        openTemporaryChat = openTemporaryChat,
      )
    }

    if (wide) {
      PermanentNavigationDrawer(
        drawerContent = {
          PermanentDrawerSheet(Modifier.width(340.dp)) { History(modal = false) }
        },
      ) {
        Chat(onOpenHistory = null)
      }
    } else {
      ModalNavigationDrawer(
        drawerState = drawerState,
        drawerContent = {
          // Full width (PRODUCT.md: the former width cap left a strip of the chat visible).
          ModalDrawerSheet(
            drawerState = drawerState,
            modifier = Modifier.fillMaxWidth(),
            drawerShape = RectangleShape,
          ) {
            History(modal = true)
          }
        },
      ) {
        Chat(onOpenHistory = { scope.launch { drawerState.open() } })
      }
    }

    SnackbarHost(
      hostState = historySnackbar,
      modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().imePadding(),
    )
  }
}

/** Provider-free welcome when no chat model is enabled and the open chat has no history. */
@Composable
private fun ChatSurface(
  chatVm: ChatViewModel,
  snackbarHostState: SnackbarHostState,
  onOpenHistory: (() -> Unit)?,
  openSettings: (SettingsDestination) -> Unit,
  openTemporaryChat: () -> Unit,
) {
  val options by chatVm.modelOptions.collectAsStateWithLifecycle()
  val transcript by chatVm.transcript.collectAsStateWithLifecycle()
  val currentId by chatVm.conversationId.collectAsStateWithLifecycle()
  val loadedForCurrent = transcript.conversationId == currentId && transcript.loaded
  val loadedOptions = options

  when {
    // Brief: models or the open chat are still loading. A blank surface avoids a welcome flash.
    loadedOptions == null || (loadedOptions.isEmpty() && !loadedForCurrent) ->
      Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background))
    loadedOptions.isEmpty() && transcript.messages.isEmpty() -> WelcomeScreen(
      snackbarHostState = snackbarHostState,
      onOpenHistory = onOpenHistory,
      onAddService = { openSettings(SettingsDestination.Providers) },
      onExploreFreeOptions = { openSettings(SettingsDestination.FreeProviderGuide) },
    )
    else -> ConversationScreen(
      vm = chatVm,
      snackbarHostState = snackbarHostState,
      onOpenHistory = onOpenHistory,
      onOpenSettings = openSettings,
      onOpenTemporaryChat = openTemporaryChat,
    )
  }
}

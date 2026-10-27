package com.omergirgin.mosaic.ui.chat

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.automirrored.outlined.DriveFileMove
import androidx.compose.material.icons.outlined.DriveFileRenameOutline
import androidx.compose.material.icons.outlined.EditNote
import androidx.compose.material.icons.automirrored.outlined.FactCheck
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.Unarchive
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material.icons.automirrored.outlined.AltRoute
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SmallFloatingActionButton
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.net.WebSearchSupport
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.data.model.Attachment
import com.omergirgin.mosaic.data.model.AttachmentKind
import com.omergirgin.mosaic.data.model.ContextReceipt
import com.omergirgin.mosaic.data.model.Message
import com.omergirgin.mosaic.data.model.MessageStatus
import com.omergirgin.mosaic.ui.chat.branching.AlternativesSheet
import com.omergirgin.mosaic.ui.components.ConfirmDialog
import com.omergirgin.mosaic.ui.components.ProjectPickerDialog
import com.omergirgin.mosaic.ui.components.TextInputDialog
import com.omergirgin.mosaic.ui.components.UiNotice
import com.omergirgin.mosaic.ui.connections.ChatConnectionsSheet
import com.omergirgin.mosaic.ui.connections.ConnectorReviewHost
import com.omergirgin.mosaic.ui.connections.rememberChatConnectionsActive
import com.omergirgin.mosaic.ui.settings.SettingsDestination
import com.omergirgin.mosaic.ui.voice.DictationButton
import com.omergirgin.mosaic.ui.voice.DictationEffects
import com.omergirgin.mosaic.ui.voice.DictationStatus
import kotlinx.coroutines.launch

private enum class ChatDialog { None, Rename, SystemPrompt, MoveToProject, DeleteChat }

/** PDF, text and Markdown files; octet-stream too because many file managers report `.md` that way. */
private val TEXT_DOCUMENT_TYPES = arrayOf("application/pdf", "text/*", "application/octet-stream")

/**
 * The chat surface: model-aware top bar, transcript, composer, model chooser and context receipt.
 * State lives in [ChatViewModel]; this composable only maps it to UI and routes intents.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConversationScreen(
  vm: ChatViewModel,
  snackbarHostState: SnackbarHostState,
  onOpenHistory: (() -> Unit)?,
  onOpenSettings: (SettingsDestination) -> Unit,
  /** Opens Temporary Chat (offered in the new-chat menu); null hides the entry. */
  onOpenTemporaryChat: (() -> Unit)? = null,
) {
  val conversationId by vm.conversationId.collectAsStateWithLifecycle()
  val conversation by vm.conversation.collectAsStateWithLifecycle()
  val transcript by vm.transcript.collectAsStateWithLifecycle()
  val options by vm.modelOptions.collectAsStateWithLifecycle()
  val settings by vm.settings.collectAsStateWithLifecycle()
  val projects by vm.projects.collectAsStateWithLifecycle()
  val generating by vm.isGenerating.collectAsStateWithLifecycle()
  val selectedOption by vm.selectedOption.collectAsStateWithLifecycle()

  val context = LocalContext.current
  val clipboard = LocalClipboard.current
  val uriHandler = LocalUriHandler.current
  val keyboard = LocalSoftwareKeyboardController.current
  val focusManager = LocalFocusManager.current
  val scope = rememberCoroutineScope()

  var showPicker by rememberSaveable { mutableStateOf(false) }
  var overflowOpen by remember { mutableStateOf(false) }
  var dialog by rememberSaveable { mutableStateOf(ChatDialog.None) }
  var messagePendingDeletion by rememberSaveable { mutableStateOf<String?>(null) }
  var inspectedAttachment by remember { mutableStateOf<Attachment?>(null) }
  var shownReceipt by remember { mutableStateOf<ContextReceipt?>(null) }
  // Follow the newest text until the person scrolls back; reset for every chat.
  var followLatest by rememberSaveable(conversationId) { mutableStateOf(true) }
  // Edit & branch: the message being edited, and the Alternatives list.
  var editingMessageId by rememberSaveable { mutableStateOf<String?>(null) }
  var showAlternatives by rememberSaveable { mutableStateOf(false) }
  // + → Connections: per-chat access to connected services.
  var showConnections by rememberSaveable { mutableStateOf(false) }
  // "Ask another model" opens its new draft in the model chooser.
  LaunchedEffect(vm.modelChoiceRequest, conversationId) {
    if (vm.modelChoiceRequest != null && vm.modelChoiceRequest == conversationId) {
      vm.consumeModelChoiceRequest()
      showPicker = true
    }
  }

  // Drafts are debounced; never lose the tail of one when the app is backgrounded or left.
  LifecycleEventEffect(Lifecycle.Event.ON_STOP) { vm.flushDraft() }
  DisposableEffect(vm) { onDispose { vm.flushDraft() } }
  // Gemini Live dictation: permission request, stop on background/leave, explanatory dialog.
  DictationEffects(vm.dictation, onOpenProviders = { onOpenSettings(SettingsDestination.Providers) })

  val currentTranscript = transcript.takeIf { it.conversationId == conversationId && it.loaded }
  val items = remember(currentTranscript) { buildTranscript(currentTranscript?.messages.orEmpty()) }
  val attachments = vm.attachmentsFor(conversationId)
  val remainingSlots = (AttachmentImporter.MAX_ATTACHMENTS - attachments.size - vm.importingCount).coerceAtLeast(0)
  val webSearchSupported = selectedOption?.let { WebSearchSupport.isSupported(it.providerKind, it.modelId) } == true
  val webSearchEnabled = conversation?.webSearchEnabled == true
  val hasContent = items.isNotEmpty() || vm.draft.isNotBlank()
  val latestReceipt = currentTranscript?.messages?.lastOrNull { it.receipt != null }?.receipt

  fun notice(text: String) = vm.post(UiNotice(text))

  val pickPhotos = rememberLauncherForActivityResult(
    // The contract requires at least 2; the view model trims to the remaining slots anyway.
    ActivityResultContracts.PickMultipleVisualMedia(maxItems = remainingSlots.coerceAtLeast(2)),
  ) { uris -> vm.addPhotos(context, uris) }
  val pickPhoto = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
    if (uri != null) vm.addPhotos(context, listOf(uri))
  }
  val pickTextFile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
    if (uri != null) vm.addDocument(context, uri)
  }
  val importProgress by vm.attachmentProgress.collectAsStateWithLifecycle()

  fun copy(text: String) {
    scope.launch {
      clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("Message", text)))
      // Android 13+ shows its own clipboard confirmation.
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) notice("Copied.")
    }
  }

  val projectName = projects.firstOrNull { it.id == conversation?.projectId }?.name
  val messageActions = remember(vm, projectName) {
    MessageActions(
      projectName = projectName,
      onCopy = { message -> copy(if (message.role == ChatRole.USER) displayText(message.content).trim() else message.content) },
      onSaveToMemory = { message, scope -> vm.saveToMemory(message.id, scope) },
      onDelete = { message -> messagePendingDeletion = message.id },
      onOpenAttachment = { inspectedAttachment = it },
      onShowReceipt = { shownReceipt = it },
      onOpenLink = { url ->
        try {
          uriHandler.openUri(url)
        } catch (e: ActivityNotFoundException) {
          vm.post(UiNotice("No app can open this link."))
        } catch (e: IllegalArgumentException) {
          vm.post(UiNotice("This link can't be opened."))
        }
      },
      onEdit = { message -> editingMessageId = message.id },
      onAskAnotherModel = { message -> vm.askAnotherModel(message.id) },
    )
  }

  BoxWithConstraints(Modifier.fillMaxSize()) {
    val density = LocalDensity.current
    val imeHeight = with(density) { WindowInsets.ime.getBottom(density).toDp() }
    // Grow with the text, then scroll inside the field, leaving room for the transcript even in a
    // short landscape viewport with the keyboard up.
    val maxTextHeight = ((maxHeight - imeHeight) * 0.3f).coerceIn(48.dp, 240.dp)
    val composerState = ComposerState(
      // Interim dictation words render here but are never persisted.
      text = vm.dictation.composerText(vm.draft, conversationId),
      attachments = attachments,
      importingCount = vm.importingCount,
      generating = generating,
      modelReady = selectedOption != null,
      showChooseModel = conversation != null && options != null && selectedOption == null,
      canAddAttachments = remainingSlots > 0 && conversation != null,
      webSearchToggleVisible = webSearchSupported || webSearchEnabled,
      webSearchEnabled = webSearchEnabled,
      webSearchSupported = webSearchSupported,
      photosUnsupported = selectedOption?.supportsImages == false && attachments.any { it.kind == AttachmentKind.IMAGE },
      importProgress = importProgress,
      dictating = vm.dictation.isActiveFor(conversationId),
      connectionsActive = rememberChatConnectionsActive(conversationId),
    )

    Scaffold(
      // While the chooser covers the chat, keep TalkBack out of the hidden content.
      modifier = if (showPicker) Modifier.clearAndSetSemantics {} else Modifier,
      topBar = {
        TopAppBar(
          navigationIcon = {
            if (onOpenHistory != null) {
              IconButton(onClick = onOpenHistory) {
                Icon(Icons.Filled.Menu, contentDescription = "Open chat history and settings")
              }
            }
          },
          title = {
            ConversationTitle(
              title = if (items.isEmpty()) "Turing AI" else conversation?.title.orEmpty(),
              modelLine = selectedOption?.let { "${it.providerName} · ${it.modelId}" }
                ?: conversation?.model?.let { "${it.modelId} · unavailable" }
                ?: "Choose a model",
              providerKind = selectedOption?.providerKind,
              enabled = conversation != null && !generating,
              onClick = {
                focusManager.clearFocus()
                showPicker = true
              },
            )
          },
          actions = {
            IconButton(onClick = { vm.newChat() }) {
              Icon(Icons.Outlined.EditNote, contentDescription = "New chat")
            }
            Box {
              IconButton(onClick = { overflowOpen = true }, enabled = conversation != null) {
                Icon(Icons.Filled.MoreVert, contentDescription = "More chat options")
              }
              DropdownMenu(expanded = overflowOpen, onDismissRequest = { overflowOpen = false }) {
                fun close() {
                  overflowOpen = false
                }
                MenuItem("New chat", Icons.Outlined.EditNote) { close(); vm.newChat() }
                if (onOpenTemporaryChat != null) {
                  MenuItem("Temporary chat", Icons.Outlined.VisibilityOff) { close(); onOpenTemporaryChat() }
                }
                MenuItem("Alternatives", Icons.AutoMirrored.Outlined.AltRoute, enabled = !generating && !vm.branching) {
                  close(); showAlternatives = true
                }
                MenuItem("Rename", Icons.Outlined.DriveFileRenameOutline, enabled = items.isNotEmpty()) {
                  close(); dialog = ChatDialog.Rename
                }
                MenuItem("System prompt", Icons.Outlined.Tune) { close(); dialog = ChatDialog.SystemPrompt }
                if (webSearchSupported || webSearchEnabled) {
                  DropdownMenuItem(
                    text = { Text("Web search") },
                    leadingIcon = { Icon(Icons.Outlined.Language, contentDescription = null) },
                    trailingIcon = { Checkbox(checked = webSearchEnabled, onCheckedChange = null) },
                    onClick = {
                      close()
                      vm.setWebSearch(!webSearchEnabled)
                    },
                  )
                }
                MenuItem("Move to project", Icons.AutoMirrored.Outlined.DriveFileMove, enabled = !generating) {
                  close(); dialog = ChatDialog.MoveToProject
                }
                if (latestReceipt != null) {
                  MenuItem("What was sent", Icons.AutoMirrored.Outlined.FactCheck) { close(); shownReceipt = latestReceipt }
                }
                val archived = conversation?.isArchived == true
                MenuItem(
                  if (archived) "Unarchive" else "Archive",
                  if (archived) Icons.Outlined.Unarchive else Icons.Outlined.Archive,
                  enabled = hasContent && !generating,
                ) { close(); vm.setArchived(!archived) }
                HorizontalDivider()
                DropdownMenuItem(
                  text = { Text("Delete chat", color = MaterialTheme.colorScheme.error) },
                  leadingIcon = {
                    Icon(Icons.Outlined.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error)
                  },
                  enabled = hasContent && !generating,
                  onClick = {
                    close()
                    dialog = ChatDialog.DeleteChat
                  },
                )
              }
            }
          },
        )
      },
      bottomBar = {
        Composer(
          state = composerState,
          maxTextHeight = maxTextHeight,
          onTextChange = vm::onDraftChange,
          onAddPhotos = {
            try {
              val request = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
              if (remainingSlots >= 2) pickPhotos.launch(request) else if (remainingSlots == 1) pickPhoto.launch(request)
            } catch (e: ActivityNotFoundException) {
              notice("No photo picker is available on this device.")
            }
          },
          onAddFile = {
            try {
              pickTextFile.launch(TEXT_DOCUMENT_TYPES)
            } catch (e: ActivityNotFoundException) {
              notice("No file picker is available on this device.")
            }
          },
          onToggleWebSearch = vm::setWebSearch,
          onRemoveAttachment = vm::removeAttachment,
          onSend = {
            if (vm.send()) {
              keyboard?.hide()
              focusManager.clearFocus()
              followLatest = true
            }
          },
          onStop = vm::stop,
          onChooseModel = { showPicker = true },
          onCancelImport = vm::cancelAttachmentImports,
          voiceControl = {
            DictationButton(vm.dictation, conversationId, enabled = conversation != null)
          },
          voiceStatus = { DictationStatus(vm.dictation, conversationId) },
          onOpenConnections = if (conversation != null) ({ showConnections = true }) else null,
        )
      },
      snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
      Box(
        Modifier
          .fillMaxSize()
          .padding(padding)
          .consumeWindowInsets(padding)
          .windowInsetsPadding(WindowInsets.displayCutout.only(WindowInsetsSides.Horizontal)),
      ) {
        when {
          currentTranscript == null -> Unit
          items.isEmpty() -> ConversationStarter(
            showSuggestions = vm.draft.isBlank() && imeHeight == 0.dp && conversation != null,
            onSuggestion = vm::onDraftChange,
            modifier = Modifier.align(Alignment.Center).verticalScroll(rememberScrollState()),
          )
          else -> key(conversationId) {
            TranscriptList(
              items = items,
              selectedAttempts = vm.selectedAttempts,
              generating = generating,
              modelReady = selectedOption != null,
              advancedControls = settings.advancedControls,
              followLatest = followLatest,
              onFollowLatestChange = { followLatest = it },
              actions = messageActions,
              onSelectAttempt = { item, id -> vm.selectedAttempts[item.rootId] = id },
              onRetry = { item, message -> followLatest = true; vm.retry(item, message.id) },
            )
          }
        }
      }
    }

    AnimatedVisibility(
      visible = showPicker,
      enter = slideInVertically { it / 6 } + fadeIn(),
      exit = slideOutVertically { it / 6 } + fadeOut(),
    ) {
      ChatModelPicker(
        options = options.orEmpty(),
        recent = settings.recentModels,
        selected = conversation?.model,
        onSelect = {
          vm.selectModel(it)
          showPicker = false
        },
        onToggleFavorite = vm::toggleFavorite,
        onManageModels = {
          showPicker = false
          onOpenSettings(SettingsDestination.Providers)
        },
        onDismiss = { showPicker = false },
      )
    }
  }

  val current = conversation
  when (dialog) {
    ChatDialog.None -> Unit
    ChatDialog.Rename -> TextInputDialog(
      title = "Rename chat",
      label = "Title",
      initialValue = current?.title.orEmpty(),
      confirmLabel = "Rename",
      onDismiss = { dialog = ChatDialog.None },
      onConfirm = {
        vm.rename(it)
        dialog = ChatDialog.None
      },
    )
    ChatDialog.SystemPrompt -> TextInputDialog(
      title = "System prompt",
      label = "Instructions for this chat",
      supportingText = "Sent with every message in this chat. Project instructions stay separate and are never overwritten.",
      initialValue = current?.systemPrompt.orEmpty(),
      confirmLabel = "Save",
      singleLine = false,
      allowBlank = true,
      extraAction = if (current?.systemPrompt.isNullOrBlank()) null else "Clear" to {
        vm.setSystemPrompt(null)
        dialog = ChatDialog.None
      },
      onDismiss = { dialog = ChatDialog.None },
      onConfirm = {
        vm.setSystemPrompt(it)
        dialog = ChatDialog.None
      },
    )
    ChatDialog.MoveToProject -> ProjectPickerDialog(
      projects = projects,
      currentProjectId = current?.projectId,
      onDismiss = { dialog = ChatDialog.None },
      onSelect = {
        vm.moveToProject(it)
        dialog = ChatDialog.None
      },
    )
    ChatDialog.DeleteChat -> ConfirmDialog(
      title = "Delete this chat?",
      message = "This permanently removes the chat, its messages and its chat-scoped memory. This can't be undone.",
      confirmLabel = "Delete",
      onDismiss = { dialog = ChatDialog.None },
      onConfirm = {
        vm.deleteConversation()
        dialog = ChatDialog.None
      },
    )
  }

  messagePendingDeletion?.let { messageId ->
    ConfirmDialog(
      title = "Delete this message?",
      message = "It's removed from this chat and won't be sent as context again. This can't be undone.",
      confirmLabel = "Delete",
      onDismiss = { messagePendingDeletion = null },
      onConfirm = {
        vm.deleteMessage(messageId)
        messagePendingDeletion = null
      },
    )
  }
  inspectedAttachment?.let { AttachmentPreviewDialog(it) { inspectedAttachment = null } }
  if (showConnections) {
    conversationId?.let { id ->
      ChatConnectionsSheet(
        conversationId = id,
        providerName = selectedOption?.providerName,
        onDismiss = { showConnections = false },
        onManage = {
          showConnections = false
          onOpenSettings(SettingsDestination.Connections)
        },
      )
    }
  }
  // Exact review of a non-read connection action requested by this chat's reply.
  ConnectorReviewHost(conversationId)
  // iOS `MessageEditView`: the edited text becomes the draft of a new alternative.
  editingMessageId?.let { messageId ->
    val message = currentTranscript?.messages?.firstOrNull { it.id == messageId }
    if (message == null) {
      editingMessageId = null
    } else {
      TextInputDialog(
        title = "Edit message",
        label = "Edited message",
        supportingText = "Your original conversation is preserved. Continue from this message in a new alternative.",
        initialValue = displayText(message.content).trim(),
        confirmLabel = "Continue",
        singleLine = false,
        onDismiss = { editingMessageId = null },
        onConfirm = { text ->
          editingMessageId = null
          vm.editAndBranch(message.id, text)
        },
      )
    }
  }
  if (showAlternatives) {
    conversationId?.let { id ->
      AlternativesSheet(
        conversationId = id,
        onOpen = vm::openConversation,
        onDismiss = { showAlternatives = false },
      )
    }
  }
  shownReceipt?.let {
    ContextReceiptSheet(it, currentTranscript?.messages.orEmpty(), settings.advancedControls) { shownReceipt = null }
  }
}

@Composable
private fun MenuItem(
  label: String,
  icon: ImageVector,
  enabled: Boolean = true,
  onClick: () -> Unit,
) {
  DropdownMenuItem(
    text = { Text(label) },
    leadingIcon = { Icon(icon, contentDescription = null) },
    enabled = enabled,
    onClick = onClick,
  )
}

/** Title plus the active provider/model beneath it; tapping opens the model chooser. */
@Composable
private fun ConversationTitle(
  title: String,
  modelLine: String,
  providerKind: ProviderKind?,
  enabled: Boolean,
  onClick: () -> Unit,
) {
  Column(
    verticalArrangement = Arrangement.Center,
    modifier = Modifier
      .heightIn(min = 48.dp)
      .clip(RoundedCornerShape(12.dp))
      .clickable(enabled = enabled, role = Role.Button, onClickLabel = "Choose model", onClick = onClick)
      .padding(horizontal = 8.dp, vertical = 2.dp)
      .semantics(mergeDescendants = true) {},
  ) {
    Text(title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
      if (providerKind != null) DecorativeProviderLogo(kind = providerKind, size = 16.dp)
      Text(
        modelLine,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.weight(1f, fill = false),
      )
      Icon(
        Icons.Filled.ArrowDropDown,
        contentDescription = null,
        tint = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.size(18.dp),
      )
    }
  }
}

/**
 * Transcript in natural order. While [followLatest] is on, each new row or streamed chunk scrolls
 * to the end; any drag toward older messages turns it off so streaming never pulls the reader
 * away, and reaching the end again (or "Latest") turns it back on. Only user input passes through
 * the nested-scroll connection, so our own programmatic scrolls never toggle the mode.
 */
@Composable
private fun TranscriptList(
  items: List<TranscriptItem>,
  selectedAttempts: Map<String, String>,
  generating: Boolean,
  modelReady: Boolean,
  advancedControls: Boolean,
  followLatest: Boolean,
  onFollowLatestChange: (Boolean) -> Unit,
  actions: MessageActions,
  onSelectAttempt: (TranscriptItem.Assistant, String) -> Unit,
  onRetry: (TranscriptItem.Assistant, Message) -> Unit,
) {
  // Open at the newest turn instead of scrolling there visibly after the first frame.
  val listState = rememberLazyListState(initialFirstVisibleItemIndex = (items.size - 1).coerceAtLeast(0))
  val scope = rememberCoroutineScope()
  val currentOnFollowChange by rememberUpdatedState(onFollowLatestChange)

  val userScrollConnection = remember(listState) {
    object : NestedScrollConnection {
      override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
        if (available.y > 0f) currentOnFollowChange(false)
        return Offset.Zero
      }

      override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
        if ((consumed.y < 0f || available.y < 0f) && !listState.canScrollForward) currentOnFollowChange(true)
        return Offset.Zero
      }
    }
  }

  fun displayed(item: TranscriptItem.Assistant): Message =
    selectedAttempts[item.rootId]?.let { id -> item.attempts.firstOrNull { it.id == id } } ?: item.attempts.last()

  val last = items.lastOrNull()
  val lastSignature = when (last) {
    null -> ""
    is TranscriptItem.User -> last.key
    is TranscriptItem.Assistant -> displayed(last).let { "${it.id}:${it.content.length}:${it.status}:${it.citations.size}" }
  }
  LaunchedEffect(lastSignature, followLatest) {
    if (followLatest) listState.scrollToEnd(items.lastIndex)
  }

  val lastAssistantKey = items.lastOrNull { it is TranscriptItem.Assistant }?.key
  val showJump by remember(listState) { derivedStateOf { listState.canScrollForward } }

  Box(Modifier.fillMaxSize()) {
    LazyColumn(
      state = listState,
      contentPadding = PaddingValues(horizontal = 16.dp, vertical = 16.dp),
      verticalArrangement = Arrangement.spacedBy(20.dp),
      modifier = Modifier.fillMaxSize().nestedScroll(userScrollConnection),
    ) {
      items(items, key = { it.key }, contentType = { if (it is TranscriptItem.User) "user" else "assistant" }) { item ->
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
          Box(Modifier.widthIn(max = 820.dp).fillMaxWidth()) {
            when (item) {
              is TranscriptItem.User -> UserMessageRow(item.message, actions, actionsEnabled = !generating)
              is TranscriptItem.Assistant -> {
                val message = displayed(item)
                AssistantMessageRow(
                  item = item,
                  displayed = message,
                  // The engine retries only the latest assistant reply, once it has finished.
                  canRetry = item.key == lastAssistantKey && message.id == item.attempts.last().id &&
                    message.status != MessageStatus.STREAMING && !generating && modelReady,
                  advancedControls = advancedControls,
                  actionsEnabled = !generating,
                  actions = actions,
                  onSelectAttempt = { onSelectAttempt(item, it) },
                  onRetry = { onRetry(item, message) },
                )
              }
            }
          }
        }
      }
    }

    AnimatedVisibility(
      visible = !followLatest && showJump,
      enter = fadeIn(),
      exit = fadeOut(),
      modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp),
    ) {
      SmallFloatingActionButton(onClick = {
        currentOnFollowChange(true)
        scope.launch { listState.scrollToEnd(items.lastIndex) }
      }) {
        Icon(Icons.Filled.ArrowDownward, contentDescription = "Scroll to latest message")
      }
    }
  }
}

/** Scrolls so the end of the last row is visible, even when that row is taller than the viewport. */
private suspend fun LazyListState.scrollToEnd(lastIndex: Int) {
  if (lastIndex < 0) return
  scrollToItem(lastIndex)
  val info = layoutInfo.visibleItemsInfo.lastOrNull { it.index == lastIndex } ?: return
  val overflow = info.offset + info.size - (layoutInfo.viewportEndOffset - layoutInfo.afterContentPadding)
  if (overflow > 0) scrollBy(overflow.toFloat())
}

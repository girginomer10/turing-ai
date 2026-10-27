package com.omergirgin.mosaic.ui.chat.temporary

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.ContextWrapper
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.FactCheck
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.StopCircle
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.data.model.Attachment
import com.omergirgin.mosaic.data.model.AttachmentKind
import com.omergirgin.mosaic.data.model.ModelChoice
import com.omergirgin.mosaic.data.temporary.TemporaryRequestReceipt
import com.omergirgin.mosaic.ui.chat.AttachmentPreviewDialog
import com.omergirgin.mosaic.ui.chat.ChatMarkdown
import com.omergirgin.mosaic.ui.chat.ChatModelPicker
import com.omergirgin.mosaic.ui.chat.Composer
import com.omergirgin.mosaic.ui.chat.ComposerState
import com.omergirgin.mosaic.ui.chat.DecorativeProviderLogo
import com.omergirgin.mosaic.ui.chat.SentAttachments
import com.omergirgin.mosaic.ui.components.ConfirmDialog
import java.text.NumberFormat
import kotlinx.coroutines.launch

/** PDF, Markdown and plain text; octet-stream because many file managers report `.md` that way. */
private val DOCUMENT_TYPES = arrayOf("application/pdf", "text/*", "application/octet-stream")

/**
 * Full-screen Temporary Chat (iOS `TemporaryChatView`). Shown above the app shell while
 * [TemporaryChatViewModel.isOpen]; leaving it, or the app going to the background, clears the
 * session. The Recents thumbnail is hidden while it is open (iOS covers the app switcher too).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TemporaryChatScreen(vm: TemporaryChatViewModel) {
  val options by vm.modelOptions.collectAsStateWithLifecycle()
  val context = LocalContext.current
  val clipboard = LocalClipboard.current
  val keyboard = LocalSoftwareKeyboardController.current
  val focusManager = LocalFocusManager.current
  val scope = rememberCoroutineScope()

  var showPicker by rememberSaveable { mutableStateOf(false) }
  var confirmClose by rememberSaveable { mutableStateOf(false) }
  var shownReceipt by remember { mutableStateOf<TurnReceipt?>(null) }
  var inspectedAttachment by remember { mutableStateOf<Attachment?>(null) }
  val selected = options?.firstOrNull { it.choice == vm.choice }
  val hasContent = vm.turns.isNotEmpty() || vm.draft.isNotBlank() || vm.attachments.isNotEmpty()

  // Backgrounding the app ends the session (process-level stop, so rotation does not).
  val currentVm by rememberUpdatedState(vm)
  DisposableEffect(Unit) {
    val observer = LifecycleEventObserver { _, event ->
      if (event == Lifecycle.Event.ON_STOP) currentVm.close()
    }
    val lifecycle = ProcessLifecycleOwner.get().lifecycle
    lifecycle.addObserver(observer)
    onDispose { lifecycle.removeObserver(observer) }
  }
  HideFromRecents()

  BackHandler(enabled = !showPicker) {
    if (hasContent) confirmClose = true else vm.close()
  }

  val pickPhotos = rememberLauncherForActivityResult(
    ActivityResultContracts.PickMultipleVisualMedia(maxItems = vm.remainingAttachmentSlots.coerceAtLeast(2)),
  ) { uris -> vm.addPhotos(context, uris) }
  val pickPhoto = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
    if (uri != null) vm.addPhotos(context, listOf(uri))
  }
  val pickFile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
    if (uri != null) vm.addFile(context, uri)
  }

  BoxWithConstraints(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
    val density = LocalDensity.current
    val imeHeight = with(density) { WindowInsets.ime.getBottom(density).toDp() }
    val maxTextHeight = ((maxHeight - imeHeight) * 0.3f).coerceIn(48.dp, 240.dp)
    val photosUnsupported = selected?.supportsImages == false &&
      (vm.attachments + vm.turns.flatMap { it.attachments }).any { it.kind == AttachmentKind.IMAGE }

    Scaffold(
      modifier = if (showPicker) Modifier.clearAndSetSemantics {} else Modifier,
      topBar = {
        TopAppBar(
          navigationIcon = {
            IconButton(onClick = { if (hasContent) confirmClose = true else vm.close() }) {
              Icon(Icons.Outlined.Close, contentDescription = "Close temporary chat")
            }
          },
          title = {
            Column(
              verticalArrangement = Arrangement.Center,
              modifier = Modifier
                .heightIn(min = 48.dp)
                .clip(RoundedCornerShape(12.dp))
                .clickable(enabled = !vm.isGenerating, role = Role.Button, onClickLabel = "Choose model") {
                  focusManager.clearFocus()
                  showPicker = true
                }
                .padding(horizontal = 8.dp, vertical = 2.dp)
                .semantics(mergeDescendants = true) {},
            ) {
              Text("Temporary chat", style = MaterialTheme.typography.titleMedium)
              Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                selected?.let { DecorativeProviderLogo(kind = it.providerKind, size = 16.dp) }
                Text(
                  selected?.let { "${it.providerName} · ${it.modelId}" } ?: "Choose a model",
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
          },
        )
      },
      bottomBar = {
        Composer(
          state = ComposerState(
            text = vm.draft,
            attachments = vm.attachments,
            importingCount = vm.importingCount,
            generating = vm.isGenerating,
            modelReady = selected != null,
            showChooseModel = options != null && selected == null,
            canAddAttachments = vm.remainingAttachmentSlots > 0,
            webSearchToggleVisible = false,
            webSearchEnabled = false,
            webSearchSupported = false,
            photosUnsupported = photosUnsupported,
          ),
          maxTextHeight = maxTextHeight,
          onTextChange = vm::onDraftChange,
          onAddPhotos = {
            try {
              val request = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
              val remaining = vm.remainingAttachmentSlots
              if (remaining >= 2) pickPhotos.launch(request) else if (remaining == 1) pickPhoto.launch(request)
            } catch (_: ActivityNotFoundException) {
              // No picker on this device; the menu simply does nothing.
            }
          },
          onAddFile = {
            try {
              pickFile.launch(DOCUMENT_TYPES)
            } catch (_: ActivityNotFoundException) {
              // No document picker on this device.
            }
          },
          onToggleWebSearch = {},
          onRemoveAttachment = vm::removeAttachment,
          onSend = {
            vm.send()
            keyboard?.hide()
            focusManager.clearFocus()
          },
          onStop = vm::stop,
          onChooseModel = { showPicker = true },
          onCancelImport = vm::cancelImports,
        )
      },
    ) { padding ->
      TemporaryTranscript(
        vm = vm,
        providerLine = selected?.providerName,
        contentPadding = padding,
        onCopy = { text ->
          scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("Message", text))) }
        },
        onShowReceipt = { shownReceipt = it },
        onOpenAttachment = { inspectedAttachment = it },
      )
    }

    AnimatedVisibility(
      visible = showPicker,
      enter = slideInVertically { it / 6 } + fadeIn(),
      exit = slideOutVertically { it / 6 } + fadeOut(),
    ) {
      // Private chooser (iOS privateMode): no recents are recorded and favorites stay unchanged.
      ChatModelPicker(
        options = options.orEmpty(),
        recent = emptyList(),
        selected = vm.choice,
        onSelect = {
          vm.selectModel(it)
          showPicker = false
        },
        onToggleFavorite = { _: ModelChoice -> },
        onManageModels = { showPicker = false },
        onDismiss = { showPicker = false },
      )
    }
  }

  if (confirmClose) {
    ConfirmDialog(
      title = "Close temporary chat?",
      message = "This chat isn't saved. Closing it clears every message and attachment.",
      confirmLabel = "Close and clear",
      onDismiss = { confirmClose = false },
      onConfirm = {
        confirmClose = false
        vm.close()
      },
    )
  }
  shownReceipt?.let { TemporaryReceiptSheet(it) { shownReceipt = null } }
  inspectedAttachment?.let { AttachmentPreviewDialog(it) { inspectedAttachment = null } }
}

/** Receipt plus the usage the provider reported for that answer. */
private data class TurnReceipt(val receipt: TemporaryRequestReceipt, val inputTokens: Int?, val outputTokens: Int?)

@Composable
private fun TemporaryTranscript(
  vm: TemporaryChatViewModel,
  providerLine: String?,
  contentPadding: PaddingValues,
  onCopy: (String) -> Unit,
  onShowReceipt: (TurnReceipt) -> Unit,
  onOpenAttachment: (Attachment) -> Unit,
) {
  val listState = rememberLazyListState()
  val streaming = vm.streaming
  val itemCount = vm.turns.size + 1 + (if (streaming != null) 1 else 0) + (if (vm.error != null) 1 else 0)
  LaunchedEffect(itemCount, streaming?.text?.length) {
    if (itemCount > 0) listState.scrollToItem(itemCount - 1)
  }

  LazyColumn(
    state = listState,
    contentPadding = PaddingValues(
      start = 16.dp,
      end = 16.dp,
      top = contentPadding.calculateTopPadding() + 12.dp,
      bottom = contentPadding.calculateBottomPadding() + 16.dp,
    ),
    verticalArrangement = Arrangement.spacedBy(20.dp),
    modifier = Modifier.fillMaxSize(),
  ) {
    item(key = "notice") { TemporaryNotice(providerLine) }
    items(vm.turns, key = { it.id }) { turn ->
      Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        Box(Modifier.widthIn(max = 820.dp).fillMaxWidth()) {
          if (turn.role == ChatRole.USER) {
            UserTurn(turn, onOpenAttachment)
          } else {
            AssistantTurn(
              text = turn.text,
              stopped = turn.stopped,
              onCopy = { onCopy(turn.text) },
              onShowReceipt = turn.receipt?.let { receipt ->
                { onShowReceipt(TurnReceipt(receipt, turn.inputTokens, turn.outputTokens)) }
              },
            )
          }
        }
      }
    }
    if (streaming != null) {
      item(key = "streaming") {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
          if (streaming.text.isNotEmpty()) SelectionContainer { ChatMarkdown(streaming.text, Modifier.fillMaxWidth()) }
          Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
          ) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            Text(
              if (streaming.text.isEmpty()) "Thinking…" else "Generating…",
              style = MaterialTheme.typography.labelLarge,
              color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
          }
        }
      }
    }
    vm.error?.let { message ->
      item(key = "error") {
        Surface(
          color = MaterialTheme.colorScheme.errorContainer,
          contentColor = MaterialTheme.colorScheme.onErrorContainer,
          shape = RoundedCornerShape(16.dp),
          modifier = Modifier.fillMaxWidth().semantics { liveRegion = LiveRegionMode.Polite },
        ) {
          Row(Modifier.padding(14.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Outlined.ErrorOutline, contentDescription = null)
            Text(message, style = MaterialTheme.typography.bodyMedium)
          }
        }
      }
    }
  }
}

@Composable
private fun TemporaryNotice(providerName: String?) {
  Surface(
    color = MaterialTheme.colorScheme.surfaceContainer,
    shape = RoundedCornerShape(16.dp),
    modifier = Modifier.fillMaxWidth(),
  ) {
    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
      Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(Icons.Outlined.VisibilityOff, contentDescription = null)
        Text("Temporary chat", style = MaterialTheme.typography.titleSmall, modifier = Modifier.semantics { heading() })
      }
      Text(
        "Nothing here is saved: no chat history, memory, usage records or recall. This chat clears " +
          "when you close it or leave the app.",
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
      Text(
        (providerName?.let { "Your messages are still sent to $it" } ?: "Your messages are still sent to the selected provider") +
          ", whose own data retention policy applies.",
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
  }
}

@Composable
private fun UserTurn(turn: TemporaryTurnUi, onOpenAttachment: (Attachment) -> Unit) {
  Box(Modifier.fillMaxWidth().padding(start = 48.dp), contentAlignment = Alignment.CenterEnd) {
    Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
      if (turn.attachments.isNotEmpty()) SentAttachments(turn.attachments, onOpen = onOpenAttachment)
      if (turn.text.isNotEmpty()) {
        Surface(
          shape = RoundedCornerShape(20.dp),
          color = MaterialTheme.colorScheme.primaryContainer,
          contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
        ) {
          SelectionContainer {
            Text(
              turn.text,
              style = MaterialTheme.typography.bodyLarge,
              modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            )
          }
        }
      }
    }
  }
}

@Composable
private fun AssistantTurn(text: String, stopped: Boolean, onCopy: () -> Unit, onShowReceipt: (() -> Unit)?) {
  Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
    SelectionContainer { ChatMarkdown(text, Modifier.fillMaxWidth()) }
    if (stopped) {
      Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(Icons.Outlined.StopCircle, contentDescription = null, modifier = Modifier.size(18.dp))
        Text("Stopped · not sent with later messages", style = MaterialTheme.typography.labelLarge)
      }
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
      IconButton(onClick = onCopy) {
        Icon(Icons.Outlined.ContentCopy, contentDescription = "Copy response", tint = MaterialTheme.colorScheme.onSurfaceVariant)
      }
      if (onShowReceipt != null) {
        TextButton(onClick = onShowReceipt, modifier = Modifier.heightIn(min = 48.dp)) {
          Icon(Icons.AutoMirrored.Outlined.FactCheck, contentDescription = null, modifier = Modifier.size(18.dp))
          Text("What was sent", modifier = Modifier.padding(start = 8.dp))
        }
      }
    }
  }
}

/** In-session receipt: what this request sent and where. Never stored. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TemporaryReceiptSheet(turn: TurnReceipt, onDismiss: () -> Unit) {
  val receipt = turn.receipt
  val numbers = NumberFormat.getIntegerInstance()
  ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
    Column(
      verticalArrangement = Arrangement.spacedBy(16.dp),
      modifier = Modifier
        .fillMaxWidth()
        .verticalScroll(rememberScrollState())
        .navigationBarsPadding()
        .padding(start = 24.dp, end = 24.dp, bottom = 24.dp),
    ) {
      Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("What was sent", style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
        Text(
          "This temporary request is shown only for this session and isn't saved.",
          style = MaterialTheme.typography.bodyMedium,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
      }
      ReceiptLine("Provider", listOfNotNull(receipt.providerName, receipt.destinationHost).joinToString(" · "))
      ReceiptLine("Model", receipt.modelId)
      ReceiptLine(
        "Messages",
        buildString {
          append("${receipt.messageCount} from this temporary chat, sent in full")
          if (receipt.attachmentCount > 0) {
            append(" · ${receipt.attachmentCount} attachment${if (receipt.attachmentCount == 1) "" else "s"}")
          }
        },
      )
      ReceiptLine(
        "Size estimate",
        "About ${numbers.format(receipt.estimatedInputTokens)} of ${numbers.format(receipt.inputBudgetTokens)} input tokens " +
          "(reply up to ${numbers.format(receipt.maximumOutputTokens)})",
      )
      if (turn.inputTokens != null || turn.outputTokens != null) {
        ReceiptLine(
          "Reported usage",
          listOfNotNull(
            turn.inputTokens?.let { "${numbers.format(it)} input" },
            turn.outputTokens?.let { "${numbers.format(it)} output tokens" },
          ).joinToString(" · ") + " (not added to Usage)",
        )
      }
      ReceiptLine("Not included", "No system prompt, project, memory, earlier chats or documents.")
      for (warning in receipt.warnings) {
        Text(warning, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error)
      }
    }
  }
}

@Composable
private fun ReceiptLine(label: String, value: String) {
  Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.semantics(mergeDescendants = true) {}) {
    Text(label, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Text(value, style = MaterialTheme.typography.bodyLarge)
  }
}

/** Hides the Recents thumbnail while a temporary chat is open (Android 13+). */
@Composable
private fun HideFromRecents() {
  val activity = LocalContext.current.findActivity()
  DisposableEffect(activity) {
    if (activity != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      activity.setRecentsScreenshotEnabled(false)
    }
    onDispose {
      if (activity != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        activity.setRecentsScreenshotEnabled(true)
      }
    }
  }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
  is Activity -> this
  is ContextWrapper -> baseContext.findActivity()
  else -> null
}

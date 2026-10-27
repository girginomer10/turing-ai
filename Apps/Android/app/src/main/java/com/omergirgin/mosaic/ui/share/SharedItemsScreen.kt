package com.omergirgin.mosaic.ui.share

import android.content.Context
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.MoveToInbox
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.omergirgin.mosaic.data.api.AppContainer
import com.omergirgin.mosaic.data.documents.DocumentTextExtractor
import com.omergirgin.mosaic.data.model.Attachment
import com.omergirgin.mosaic.data.share.SharedFileKind
import com.omergirgin.mosaic.data.share.SharedItem
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.chat.AttachmentImporter
import com.omergirgin.mosaic.ui.components.ConfirmDialog
import com.omergirgin.mosaic.ui.components.relativeTime
import com.omergirgin.mosaic.ui.components.userMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** A draft created from a shared item: open [conversationId] with [attachments] in the composer. */
data class SharedDraft(val conversationId: String, val attachments: List<Attachment>)

class SharedItemsViewModel(private val container: AppContainer) : ViewModel() {
  val items: StateFlow<List<SharedItem>?> = container.sharedItems.observeItems()
    .catch {
      error = "Turing AI couldn't read Shared items on this device."
      emit(emptyList())
    }
    .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

  /** Item whose draft is being prepared (photos normalized, documents read on-device). */
  var preparingId by mutableStateOf<String?>(null)
    private set
  var error by mutableStateOf<String?>(null)
    private set

  /**
   * iOS `SharedInboxView.prepare`: attachments are prepared first, so a file that can't be used
   * leaves the item queued; then the draft chat is created and the item removed.
   */
  fun openAsDraft(context: Context, item: SharedItem, onOpened: (SharedDraft) -> Unit) {
    if (preparingId != null) return
    preparingId = item.id
    error = null
    val appContext = context.applicationContext
    viewModelScope.launch {
      try {
        val attachments = item.files.map { shared ->
          val uri = Uri.fromFile(shared.file)
          when (shared.kind) {
            SharedFileKind.IMAGE -> AttachmentImporter.photo(appContext, uri)
              .copy(fileName = jpegName(shared.displayName))
            SharedFileKind.PDF, SharedFileKind.TEXT -> DocumentTextExtractor.chatAttachment(appContext, uri)
              .copy(fileName = shared.displayName.take(200))
          }
        }
        val conversationId = container.sharedItems.createDraft(item.id)
        onOpened(SharedDraft(conversationId, attachments))
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        error = e.userMessage("This shared item couldn't be opened as a draft.")
      } finally {
        preparingId = null
      }
    }
  }

  fun delete(item: SharedItem) {
    viewModelScope.launch {
      try {
        container.sharedItems.delete(item.id)
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        error = e.userMessage("This shared item couldn't be removed.")
      }
    }
  }

  private fun jpegName(name: String): String =
    "${name.substringBeforeLast('.').ifBlank { "Photo" }.take(196)}.jpg"
}

/**
 * Shared items (iOS `SharedInboxView`): what other apps shared, waiting for review. Opening one
 * creates a new draft chat; nothing is sent until the person taps Send there.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SharedItemsScreen(onBack: () -> Unit, onOpenDraft: (SharedDraft) -> Unit) {
  val container = LocalAppContainer.current
  val vm: SharedItemsViewModel = viewModel { SharedItemsViewModel(container) }
  val items by vm.items.collectAsStateWithLifecycle()
  val context = LocalContext.current
  var pendingRemoval by rememberSaveable { mutableStateOf<String?>(null) }

  BackHandler(onBack = onBack)
  Scaffold(
    modifier = Modifier.background(MaterialTheme.colorScheme.background),
    topBar = {
      TopAppBar(
        title = { Text("Shared items") },
        navigationIcon = {
          IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
        },
      )
    },
  ) { padding ->
    LazyColumn(
      contentPadding = PaddingValues(
        start = 16.dp,
        end = 16.dp,
        top = padding.calculateTopPadding() + 4.dp,
        bottom = padding.calculateBottomPadding() + 24.dp,
      ),
      verticalArrangement = Arrangement.spacedBy(16.dp),
      modifier = Modifier.fillMaxSize(),
    ) {
      item(key = "intro") {
        Text(
          "Items you share to Turing AI from other apps wait here until you review them. Nothing is " +
            "sent to a provider automatically.",
          style = MaterialTheme.typography.bodyMedium,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
          modifier = Modifier.padding(horizontal = 4.dp),
        )
      }
      vm.error?.let { message ->
        item(key = "error") {
          Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
          ) {
            Icon(Icons.Outlined.ErrorOutline, contentDescription = null, tint = MaterialTheme.colorScheme.error)
            Text(message, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
          }
        }
      }
      val list = items
      when {
        list == null -> item(key = "loading") {
          Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(Modifier.size(24.dp))
          }
        }
        list.isEmpty() -> item(key = "empty") { EmptySharedItems() }
        else -> items(list, key = { it.id }) { item ->
          SharedItemCard(
            item = item,
            preparing = vm.preparingId == item.id,
            enabled = vm.preparingId == null,
            onOpen = { vm.openAsDraft(context, item, onOpenDraft) },
            onRemove = { pendingRemoval = item.id },
          )
        }
      }
    }
  }

  pendingRemoval?.let { id ->
    ConfirmDialog(
      title = "Remove this shared item?",
      message = "Its copied text and files are deleted from Turing AI. The original stays in the app you shared it from.",
      confirmLabel = "Remove",
      onDismiss = { pendingRemoval = null },
      onConfirm = {
        items?.firstOrNull { it.id == id }?.let(vm::delete)
        pendingRemoval = null
      },
    )
  }
}

@Composable
private fun SharedItemCard(
  item: SharedItem,
  preparing: Boolean,
  enabled: Boolean,
  onOpen: () -> Unit,
  onRemove: () -> Unit,
) {
  Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
    Surface(
      shape = RoundedCornerShape(20.dp),
      color = MaterialTheme.colorScheme.surfaceContainer,
      modifier = Modifier.widthIn(max = 820.dp).fillMaxWidth(),
    ) {
      Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(
          "Shared ${relativeTime(item.createdAt).let { if (it == "Just now") "just now" else it }}",
          style = MaterialTheme.typography.titleSmall,
          modifier = Modifier.semantics { heading() },
        )
        SharedItemPreview(item)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
          Button(onClick = onOpen, enabled = enabled, modifier = Modifier.heightIn(min = 48.dp)) {
            if (preparing) {
              CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
              Text("Preparing draft…", modifier = Modifier.padding(start = 8.dp))
            } else {
              Text("Open as new draft")
            }
          }
          TextButton(onClick = onRemove, enabled = enabled, modifier = Modifier.heightIn(min = 48.dp)) {
            Text("Remove", color = MaterialTheme.colorScheme.error)
          }
        }
      }
    }
  }
}

@Composable
private fun EmptySharedItems() {
  Column(
    horizontalAlignment = Alignment.CenterHorizontally,
    verticalArrangement = Arrangement.spacedBy(8.dp),
    modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp, horizontal = 24.dp),
  ) {
    Icon(
      Icons.Outlined.MoveToInbox,
      contentDescription = null,
      tint = MaterialTheme.colorScheme.onSurfaceVariant,
      modifier = Modifier.size(40.dp),
    )
    Text("No shared items", style = MaterialTheme.typography.titleMedium)
    Text(
      "Use Share → Turing AI in your browser, Photos or Files.",
      style = MaterialTheme.typography.bodyMedium,
      color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
  }
}

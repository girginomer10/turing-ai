package com.omergirgin.mosaic.ui.share

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.core.content.IntentCompat
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.omergirgin.mosaic.TuringApplication
import com.omergirgin.mosaic.data.api.AppContainer
import com.omergirgin.mosaic.data.share.IncomingShare
import com.omergirgin.mosaic.data.share.IncomingStream
import com.omergirgin.mosaic.data.share.SharedItem
import com.omergirgin.mosaic.data.share.SharedItemException
import com.omergirgin.mosaic.ui.theme.TuringTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * System share target (iOS Share Extension "Send to Turing AI"). Everything shared is copied
 * into app-private storage while the share grant is alive, then queued under Shared items with
 * an optional question. Nothing is sent to a provider from here.
 */
class ShareReceiverActivity : ComponentActivity() {
  private val viewModel: ShareReceiverViewModel by viewModels {
    val container = (application as TuringApplication).container
    val incoming = intent.toIncomingShare()
    object : ViewModelProvider.Factory {
      @Suppress("UNCHECKED_CAST")
      override fun <T : ViewModel> create(modelClass: Class<T>): T = ShareReceiverViewModel(container, incoming) as T
    }
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    enableEdgeToEdge()
    super.onCreate(savedInstanceState)
    // Created here, while the sender's read grant is valid, so copying starts immediately.
    val vm = viewModel
    setContent {
      TuringTheme {
        ShareReceiverScreen(
          vm = vm,
          onCancel = { finish() },
          onSaved = { openApp ->
            if (openApp) {
              startActivity(SharedItemsLaunchRequests.openIntent(this))
            } else {
              Toast.makeText(this, "Saved to Shared items in Turing AI.", Toast.LENGTH_SHORT).show()
            }
            finish()
          },
        )
      }
    }
  }
}

/** Reads ACTION_SEND / ACTION_SEND_MULTIPLE extras; null when the intent is not a share. */
private fun Intent.toIncomingShare(): IncomingShare? {
  if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return null
  val uris = LinkedHashSet<Uri>()
  if (action == Intent.ACTION_SEND) {
    IntentCompat.getParcelableExtra(this, Intent.EXTRA_STREAM, Uri::class.java)?.let(uris::add)
  } else {
    IntentCompat.getParcelableArrayListExtra(this, Intent.EXTRA_STREAM, Uri::class.java)?.let(uris::addAll)
  }
  // Some senders only attach their files as ClipData.
  if (uris.isEmpty()) {
    clipData?.let { clip -> for (index in 0 until clip.itemCount) clip.getItemAt(index).uri?.let(uris::add) }
  }
  return IncomingShare(
    text = getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString(),
    subject = getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString(),
    streams = uris.map { IncomingStream(it, type) },
  )
}

class ShareReceiverViewModel(private val container: AppContainer, incoming: IncomingShare?) : ViewModel() {
  sealed interface State {
    data object Preparing : State
    data class Ready(val item: SharedItem) : State
    data class Failed(val message: String) : State
  }

  var state by mutableStateOf<State>(State.Preparing)
    private set
  var note by mutableStateOf("")
  var saving by mutableStateOf(false)
    private set
  var saveError by mutableStateOf<String?>(null)
    private set

  private var stagedId: String? = null
  private var committed = false

  init {
    if (incoming == null) {
      state = State.Failed("Turing AI didn't receive anything to save.")
    } else {
      viewModelScope.launch {
        state = try {
          container.sharedItems.stage(incoming).also { stagedId = it.id }.let(State::Ready)
        } catch (e: CancellationException) {
          throw e
        } catch (e: SharedItemException) {
          State.Failed(e.message ?: GENERIC_FAILURE)
        } catch (e: Exception) {
          State.Failed(GENERIC_FAILURE)
        }
      }
    }
  }

  /** Set once the item is queued; true when the app should open on Shared items. */
  var savedAndOpen by mutableStateOf<Boolean?>(null)
    private set

  fun save(openApp: Boolean) {
    val id = stagedId ?: return
    if (saving || committed) return
    saving = true
    saveError = null
    viewModelScope.launch {
      try {
        withContext(NonCancellable) { container.sharedItems.commit(id, note) }
        committed = true
        savedAndOpen = openApp
      } catch (e: SharedItemException) {
        saveError = e.message ?: GENERIC_FAILURE
      } catch (e: Exception) {
        saveError = GENERIC_FAILURE
      } finally {
        saving = false
      }
    }
  }

  override fun onCleared() {
    // Cancelled or abandoned shares leave no copied files behind.
    val id = stagedId
    if (!committed && id != null) cleanupScope.launch { runCatching { container.sharedItems.discard(id) } }
  }

  private companion object {
    const val GENERIC_FAILURE = "Turing AI couldn't save what you shared. Try sharing it again."
    val cleanupScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ShareReceiverScreen(vm: ShareReceiverViewModel, onCancel: () -> Unit, onSaved: (openApp: Boolean) -> Unit) {
  BackHandler(onBack = onCancel)
  // Observed rather than called back, so a rotation during the save still finishes the screen.
  vm.savedAndOpen?.let { openApp -> LaunchedEffect(openApp) { onSaved(openApp) } }
  Scaffold(
    topBar = {
      TopAppBar(
        title = { Text("Send to Turing AI") },
        navigationIcon = {
          IconButton(onClick = onCancel) { Icon(Icons.Outlined.Close, contentDescription = "Cancel") }
        },
      )
    },
  ) { padding ->
    Column(
      verticalArrangement = Arrangement.spacedBy(16.dp),
      modifier = Modifier
        .fillMaxSize()
        .padding(padding)
        .imePadding()
        .verticalScroll(rememberScrollState())
        .padding(horizontal = 20.dp, vertical = 12.dp),
    ) {
      when (val state = vm.state) {
        ShareReceiverViewModel.State.Preparing -> Row(
          verticalAlignment = Alignment.CenterVertically,
          horizontalArrangement = Arrangement.spacedBy(12.dp),
          modifier = Modifier.semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        ) {
          CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
          Text("Preparing shared items…", style = MaterialTheme.typography.bodyLarge)
        }
        is ShareReceiverViewModel.State.Failed -> {
          ErrorText(state.message)
          OutlinedButton(onClick = onCancel, modifier = Modifier.heightIn(min = 48.dp)) { Text("Close") }
        }
        is ShareReceiverViewModel.State.Ready -> {
          Text(
            "Review it later in Turing AI → Shared items, then open it as a draft. Nothing is sent to " +
              "a provider until you choose a model and tap Send.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
          )
          Surface(
            shape = RoundedCornerShape(16.dp),
            color = MaterialTheme.colorScheme.surfaceContainer,
            modifier = Modifier.widthIn(max = 720.dp).fillMaxWidth(),
          ) {
            Column(Modifier.padding(16.dp)) { SharedItemPreview(state.item, showNote = false) }
          }
          OutlinedTextField(
            value = vm.note,
            onValueChange = { vm.note = it },
            label = { Text("Question (optional)") },
            minLines = 3,
            enabled = !vm.saving,
            modifier = Modifier.widthIn(max = 720.dp).fillMaxWidth(),
          )
          vm.saveError?.let { ErrorText(it) }
          Button(
            onClick = { vm.save(openApp = false) },
            enabled = !vm.saving,
            modifier = Modifier.widthIn(max = 720.dp).fillMaxWidth().heightIn(min = 48.dp),
          ) { Text("Save to Shared items") }
          OutlinedButton(
            onClick = { vm.save(openApp = true) },
            enabled = !vm.saving,
            modifier = Modifier.widthIn(max = 720.dp).fillMaxWidth().heightIn(min = 48.dp),
          ) { Text("Save and open Turing AI") }
        }
      }
    }
  }
}

@Composable
private fun ErrorText(message: String) {
  Row(
    horizontalArrangement = Arrangement.spacedBy(8.dp),
    modifier = Modifier.semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
  ) {
    Icon(Icons.Outlined.ErrorOutline, contentDescription = null, tint = MaterialTheme.colorScheme.error)
    Text(message, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.error)
  }
}

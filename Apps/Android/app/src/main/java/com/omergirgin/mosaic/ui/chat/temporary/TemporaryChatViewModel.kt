package com.omergirgin.mosaic.ui.chat.temporary

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.data.api.AppContainer
import com.omergirgin.mosaic.data.documents.DocumentTextExtractor
import com.omergirgin.mosaic.data.model.AppSettings
import com.omergirgin.mosaic.data.model.Attachment
import com.omergirgin.mosaic.data.model.AttachmentKind
import com.omergirgin.mosaic.data.model.ModelChoice
import com.omergirgin.mosaic.data.model.ModelOption
import com.omergirgin.mosaic.data.temporary.TemporaryChatEvent
import com.omergirgin.mosaic.data.temporary.TemporaryChatTurn
import com.omergirgin.mosaic.data.temporary.TemporaryRequestReceipt
import com.omergirgin.mosaic.ui.chat.AttachmentImporter
import com.omergirgin.mosaic.ui.components.userMessage
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** One visible turn. Stopped replies stay visible but are never sent again (as in saved chats). */
data class TemporaryTurnUi(
  val id: String,
  val role: ChatRole,
  val text: String,
  val attachments: List<Attachment> = emptyList(),
  val stopped: Boolean = false,
  /** Assistant turns: what their request sent, and the usage the provider reported. */
  val receipt: TemporaryRequestReceipt? = null,
  val inputTokens: Int? = null,
  val outputTokens: Int? = null,
)

/**
 * Temporary Chat (iOS `TemporaryChatView`): the entire session lives in this view model. Nothing
 * is written to the conversation database, usage ledger, receipts, recall index, memory, model
 * recents or drafts. [close] — or the app going to the background — clears everything. The
 * session survives rotation (activity-scoped view model) but never process death.
 */
class TemporaryChatViewModel(private val container: AppContainer) : ViewModel() {

  var isOpen by mutableStateOf(false)
    private set

  val turns = mutableStateListOf<TemporaryTurnUi>()
  var draft by mutableStateOf("")
    private set
  var attachments by mutableStateOf<List<Attachment>>(emptyList())
    private set
  var importingCount by mutableIntStateOf(0)
    private set
  var choice by mutableStateOf<ModelChoice?>(null)
    private set
  var error by mutableStateOf<String?>(null)
    private set

  /** The reply being streamed; null while idle. */
  var streaming by mutableStateOf<StreamingReply?>(null)
    private set

  data class StreamingReply(val text: String, val receipt: TemporaryRequestReceipt?)

  val modelOptions: StateFlow<List<ModelOption>?> = container.providers.observeModelOptions()
    .catch { emit(emptyList()) }
    .stateIn(viewModelScope, SharingStarted.Eagerly, null)

  private val settings: StateFlow<AppSettings> = container.settings.settings
    .catch { emit(AppSettings()) }
    .stateIn(viewModelScope, SharingStarted.Eagerly, AppSettings())

  private var generation: Job? = null
  private val importJobs = HashSet<Job>()

  val isGenerating: Boolean get() = streaming != null

  /** Opens a fresh session with the usual default model (app default → recent → first). */
  fun open() {
    clear()
    isOpen = true
    viewModelScope.launch {
      val options = modelOptions.first { it != null }.orEmpty()
      if (choice == null) choice = defaultChoice(options, settings.value)
    }
  }

  /** Ends the session: cancels any request or import and drops every turn, draft and attachment. */
  fun close() {
    clear()
    isOpen = false
  }

  private fun clear() {
    generation?.cancel()
    generation = null
    importJobs.toList().forEach { it.cancel() }
    importJobs.clear()
    importingCount = 0
    turns.clear()
    draft = ""
    attachments = emptyList()
    streaming = null
    error = null
    choice = null
  }

  fun onDraftChange(text: String) {
    draft = text
  }

  /** Model choice is private here: it is not recorded as a recent model. */
  fun selectModel(option: ModelOption) {
    if (isGenerating) return
    choice = option.choice
  }

  fun send() {
    if (isGenerating || importingCount > 0) return
    val selected = choice ?: run {
      error = "Choose a model for this temporary chat."
      return
    }
    val text = draft.trim()
    val pending = attachments
    if (text.isEmpty() && pending.isEmpty()) return
    val option = modelOptions.value?.firstOrNull { it.choice == selected }
    if (option == null) {
      error = "This model is disabled or unavailable. Choose another model."
      return
    }
    if (!option.supportsImages && (pending + turns.flatMap { it.attachments }).any { it.kind == AttachmentKind.IMAGE }) {
      error = "Choose a photo-capable model for this temporary chat."
      return
    }

    val userTurn = TemporaryTurnUi(UUID.randomUUID().toString(), ChatRole.USER, text, pending)
    // Stopped replies are shown but, like cancelled rows in saved chats, never sent back.
    val history = turns.filterNot { it.stopped }.map { TemporaryChatTurn(it.id, it.role, it.text, it.attachments) }
    val request = history + TemporaryChatTurn(userTurn.id, userTurn.role, userTurn.text, userTurn.attachments)
    val priorDraft = draft

    error = null
    turns += userTurn
    draft = ""
    attachments = emptyList()
    streaming = StreamingReply("", null)

    lateinit var job: Job
    job = viewModelScope.launch(start = CoroutineStart.LAZY) {
      val reply = StringBuilder()
      var receipt: TemporaryRequestReceipt? = null
      var inputTokens: Int? = null
      var outputTokens: Int? = null
      var completed = false
      try {
        container.temporaryChat.stream(selected, request).collect { event ->
          when (event) {
            is TemporaryChatEvent.Started -> {
              receipt = event.receipt
              streaming = StreamingReply(reply.toString(), receipt)
            }
            is TemporaryChatEvent.TextDelta -> {
              reply.append(event.text)
              streaming = StreamingReply(reply.toString(), receipt)
            }
            is TemporaryChatEvent.Usage -> {
              event.inputTokens?.let { inputTokens = it }
              event.outputTokens?.let { outputTokens = it }
            }
            TemporaryChatEvent.Completed -> completed = true
          }
        }
        if (!completed || reply.isEmpty()) {
          throw IllegalStateException(
            if (reply.isEmpty()) "The provider completed without visible text." else "The connection ended before the provider confirmed completion."
          )
        }
        turns += TemporaryTurnUi(
          id = UUID.randomUUID().toString(),
          role = ChatRole.ASSISTANT,
          text = reply.toString(),
          receipt = receipt,
          inputTokens = inputTokens,
          outputTokens = outputTokens,
        )
      } catch (stop: CancellationException) {
        // Stop keeps the partial reply on screen; a cleared session discards it with everything else.
        if (isOpen && generation === job && reply.isNotEmpty()) {
          turns += TemporaryTurnUi(UUID.randomUUID().toString(), ChatRole.ASSISTANT, reply.toString(), stopped = true, receipt = receipt)
        }
        throw stop
      } catch (failure: Exception) {
        // iOS: the turn is withdrawn and the draft restored so nothing typed is lost.
        turns.removeAll { it.id == userTurn.id }
        if (draft.isBlank()) draft = priorDraft
        if (attachments.isEmpty()) attachments = pending
        error = failure.userMessage("The request failed. Try again.")
      } finally {
        if (generation === job) {
          generation = null
          streaming = null
        }
      }
    }
    generation = job
    job.start()
  }

  fun stop() {
    generation?.cancel()
  }

  // Attachments (same normalization as saved chats; kept in memory only) ------------------------

  val remainingAttachmentSlots: Int
    get() = (AttachmentImporter.MAX_ATTACHMENTS - attachments.size - importingCount).coerceAtLeast(0)

  fun addPhotos(context: Context, uris: List<Uri>) = import(context, uris) { appContext, uri ->
    AttachmentImporter.photo(appContext, uri)
  }

  fun addFile(context: Context, uri: Uri) = import(context, listOf(uri)) { appContext, picked ->
    DocumentTextExtractor.chatAttachment(appContext, picked)
  }

  fun removeAttachment(id: String) {
    attachments = attachments.filterNot { it.id == id }
  }

  fun cancelImports() {
    importJobs.toList().forEach { it.cancel() }
  }

  private fun import(context: Context, uris: List<Uri>, importer: suspend (Context, Uri) -> Attachment) {
    if (uris.isEmpty() || isGenerating) return
    val accepted = uris.take(remainingAttachmentSlots)
    if (accepted.isEmpty()) {
      error = "A message can contain four attachments. Remove one to add another."
      return
    }
    val appContext = context.applicationContext
    importingCount += accepted.size
    val job = viewModelScope.launch(start = CoroutineStart.LAZY) {
      var pending = accepted.size
      try {
        for (uri in accepted) {
          try {
            val attachment = importer(appContext, uri)
            attachments = attachments + attachment
          } catch (e: CancellationException) {
            throw e
          } catch (e: Exception) {
            error = e.userMessage("This attachment could not be opened.")
          } finally {
            pending -= 1
            importingCount -= 1
          }
        }
      } finally {
        importingCount = (importingCount - pending).coerceAtLeast(0)
      }
    }
    importJobs += job
    job.invokeOnCompletion { importJobs -= job }
    job.start()
  }

  override fun onCleared() {
    clear()
  }

  private companion object {
    fun defaultChoice(options: List<ModelOption>, settings: AppSettings): ModelChoice? {
      val enabled = options.mapTo(HashSet()) { it.choice }
      return settings.defaultModel?.takeIf { it in enabled }
        ?: settings.recentModels.firstOrNull { it in enabled }
        ?: options.firstOrNull()?.choice
    }
  }
}

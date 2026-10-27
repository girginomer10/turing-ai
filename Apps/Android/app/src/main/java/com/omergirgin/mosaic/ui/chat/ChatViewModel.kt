package com.omergirgin.mosaic.ui.chat

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.omergirgin.mosaic.core.documents.DocumentIngestionException
import com.omergirgin.mosaic.core.net.WebSearchSupport
import com.omergirgin.mosaic.data.api.AppContainer
import com.omergirgin.mosaic.data.branching.CreatedAlternative
import com.omergirgin.mosaic.data.documents.DocumentImportStage
import com.omergirgin.mosaic.data.documents.DocumentTextExtractor
import com.omergirgin.mosaic.data.model.AppSettings
import com.omergirgin.mosaic.data.model.Attachment
import com.omergirgin.mosaic.data.model.AttachmentKind
import com.omergirgin.mosaic.data.model.Conversation
import com.omergirgin.mosaic.data.model.MemoryScope
import com.omergirgin.mosaic.data.model.ModelChoice
import com.omergirgin.mosaic.data.model.ModelOption
import com.omergirgin.mosaic.data.model.Project
import com.omergirgin.mosaic.ui.components.NoticeChannel
import com.omergirgin.mosaic.ui.components.UiNotice
import com.omergirgin.mosaic.ui.components.userMessage
import com.omergirgin.mosaic.ui.voice.ChatDictationHost
import com.omergirgin.mosaic.ui.voice.DictationController
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/*
 * Draft writes must outlive the screen: a flush on leave/stop would otherwise be cancelled with
 * viewModelScope (onCleared) or lost when the process is backgrounded mid-debounce. The writes
 * are tiny and idempotent, so a process-lifetime scope is appropriate.
 */
private val draftWriteScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

private const val KEY_CONVERSATION_ID = "chat.conversationId"
private const val DRAFT_DEBOUNCE_MS = 900L

/** Loaded state of the open conversation; [loaded] distinguishes "loading" from "deleted". */
private data class ConversationLoad(val id: String?, val conversation: Conversation?, val loaded: Boolean)

/**
 * Activity-scoped state for the chat surface: which conversation is open, its transcript, the
 * composer draft (debounced persistence) and pending attachments. Switching conversations
 * changes [conversationId] instead of creating a view model per chat, so nothing leaks while a
 * person browses hundreds of chats.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModel(
  private val container: AppContainer,
  private val savedState: SavedStateHandle,
) : ViewModel() {

  private val noticeChannel = NoticeChannel()
  val notices: Flow<UiNotice> = noticeChannel.notices

  val conversationId: StateFlow<String?> = savedState.getStateFlow(KEY_CONVERSATION_ID, null)

  private val conversationLoad: StateFlow<ConversationLoad> = conversationId
    .flatMapLatest { id ->
      if (id == null) {
        flowOf(ConversationLoad(null, null, loaded = true))
      } else {
        container.conversations.observeConversation(id)
          .map { ConversationLoad(id, it, loaded = true) }
          .onStart { emit(ConversationLoad(id, null, loaded = false)) }
          .catch { error ->
            noticeChannel.post("Turing AI couldn't open this chat. ${error.userMessage()}")
            emit(ConversationLoad(id, null, loaded = false))
          }
      }
    }
    .stateIn(viewModelScope, SharingStarted.Eagerly, ConversationLoad(conversationId.value, null, false))

  val conversation: StateFlow<Conversation?> = conversationLoad
    .map { it.conversation }
    .stateIn(viewModelScope, SharingStarted.Eagerly, null)

  val transcript: StateFlow<TranscriptState> = conversationId
    .flatMapLatest { id ->
      if (id == null) {
        flowOf(TranscriptState(null, emptyList(), loaded = true))
      } else {
        container.conversations.observeMessages(id)
          .map { TranscriptState(id, it, loaded = true) }
          .onStart { emit(TranscriptState(id, emptyList(), loaded = false)) }
          .catch { error ->
            noticeChannel.post("Turing AI couldn't load this chat's messages. ${error.userMessage()}")
          }
      }
    }
    .stateIn(viewModelScope, SharingStarted.Eagerly, TranscriptState(conversationId.value, emptyList(), false))

  /** null until the first emission, so the UI can tell "loading" from "no models". */
  val modelOptions: StateFlow<List<ModelOption>?> = container.providers.observeModelOptions()
    .catch { error ->
      noticeChannel.post("Turing AI couldn't load your models. ${error.userMessage()}")
      emit(emptyList())
    }
    .stateIn(viewModelScope, SharingStarted.Eagerly, null)

  val settings: StateFlow<AppSettings> = container.settings.settings
    .catch { emit(AppSettings()) }
    .stateIn(viewModelScope, SharingStarted.Eagerly, AppSettings())

  val projects: StateFlow<List<Project>> = container.projects.observeProjects(includeArchived = false)
    .catch { emit(emptyList()) }
    .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

  val isGenerating: StateFlow<Boolean> = combine(conversationId, container.chat.activeGenerations) { id, active ->
    id != null && id in active
  }.stateIn(viewModelScope, SharingStarted.Eagerly, false)

  /** The enabled model the open chat will use for its next turn, or null when unavailable. */
  val selectedOption: StateFlow<ModelOption?> = combine(conversation, modelOptions) { conversation, options ->
    val model = conversation?.model ?: return@combine null
    options?.firstOrNull { it.choice == model }
  }.stateIn(viewModelScope, SharingStarted.Eagerly, null)

  // Composer -----------------------------------------------------------------------------------

  var draft by mutableStateOf("")
    private set

  /** Conversation the in-memory [draft] belongs to. */
  private var draftOwnerId: String? = conversationId.value
  private var draftLoaded = false
  private var draftJob: Job? = null

  /** Gemini Live dictation into this composer (ui/voice); it blocks Send/Retry in its chat. */
  val dictation = DictationController(
    container, viewModelScope, ChatDictationHost(this, container),
  )

  /** Unsent attachments per chat, kept for the session so switching chats doesn't drop them. */
  private val attachmentsByConversation = mutableStateMapOf<String, List<Attachment>>()

  var importingCount by mutableIntStateOf(0)
    private set

  /** Retry group root → attempt the person chose to view. Absent = newest attempt. */
  val selectedAttempts = mutableStateMapOf<String, String>()

  private var creatingConversation = false

  /** What the composer last handed to the engine, kept until the user turn shows up in the transcript. */
  private data class Submission(
    val conversationId: String,
    val text: String,
    val attachments: List<Attachment>,
    val messageCountBefore: Int,
  )

  private var lastSubmission: Submission? = null
  private val modelRepairAttempted = HashSet<String>()

  init {
    viewModelScope.launch {
      if (conversationId.value == null) openHome(excluding = null)
    }
    viewModelScope.launch {
      conversationLoad.collect { load ->
        val conversation = load.conversation
        if (conversation != null && conversation.id == draftOwnerId && !draftLoaded) {
          draft = conversation.draft
          draftLoaded = true
        }
        if (load.loaded && load.id != null && conversation == null) onConversationGone(load.id)
      }
    }
    viewModelScope.launch {
      combine(conversation, transcript, modelOptions, settings, projects) { c, t, o, s, p ->
        repairEmptyChatModel(c, t, o, s, p)
      }.collect {}
    }
    viewModelScope.launch {
      // Requests the engine rejected before anything was persisted: show them for the open chat
      // and give back the text and attachments the composer already cleared.
      container.chat.notices.collect { notice ->
        restoreRejectedSubmission(notice.conversationId)
        if (notice.conversationId == conversationId.value) noticeChannel.post(UiNotice(notice.message, long = true))
      }
    }
    viewModelScope.launch {
      transcript.collect { state ->
        val pending = lastSubmission ?: return@collect
        if (state.conversationId == pending.conversationId && state.loaded && state.messages.size > pending.messageCountBefore) {
          lastSubmission = null
        }
      }
    }
    viewModelScope.launch {
      combine(modelOptions, settings) { options, appSettings -> !options.isNullOrEmpty() && !appSettings.hasCompletedOnboarding }
        .collect { finishedSetup ->
          // The first enabled model ends the provider-free welcome; the engine also marks it on first send.
          if (finishedSetup) runCatching { container.settings.setOnboardingCompleted(true) }
        }
    }
  }

  fun attachmentsFor(conversationId: String?): List<Attachment> =
    conversationId?.let { attachmentsByConversation[it] }.orEmpty()

  fun onDraftChange(text: String) {
    draft = text
    // Typing before the stored draft arrives wins over the stored value.
    draftLoaded = true
    val id = draftOwnerId ?: return
    draftJob?.cancel()
    var job: Job? = null
    job = viewModelScope.launch {
      delay(DRAFT_DEBOUNCE_MS)
      persistDraft(id, text)
      // Only clear our own reference; a newer keystroke may already own the slot.
      if (draftJob === job) draftJob = null
    }
    draftJob = job
  }

  /** Writes a pending debounced draft immediately (screen stop, chat switch, leaving). */
  fun flushDraft() {
    val job = draftJob ?: return
    val id = draftOwnerId ?: return
    job.cancel()
    draftJob = null
    val text = draft
    draftWriteScope.launch { persistDraft(id, text) }
  }

  private suspend fun persistDraft(id: String, text: String) {
    try {
      container.conversations.updateDraft(id, text)
    } catch (e: CancellationException) {
      throw e
    } catch (e: Exception) {
      noticeChannel.post("Turing AI couldn't save your draft. ${e.userMessage()}")
    }
  }

  // Navigation ---------------------------------------------------------------------------------

  fun openConversation(id: String) {
    if (id == conversationId.value) return
    flushDraft()
    switchTo(id)
  }

  /**
   * Starts a chat (optionally inside a project). An already-empty open chat in the same project is
   * reused so repeated taps don't create hidden rows (empty chats never appear in history).
   */
  fun newChat(projectId: String? = null) {
    val current = conversation.value
    val loadedTranscript = transcript.value
    if (current != null && current.projectId == projectId && !current.isArchived &&
      loadedTranscript.conversationId == current.id && loadedTranscript.loaded &&
      loadedTranscript.messages.isEmpty() && draft.isBlank() && attachmentsFor(current.id).isEmpty()
    ) {
      return
    }
    createAndOpen(projectId)
  }

  /** Called when the open chat was archived elsewhere (history drawer); iOS returns home then. */
  fun onConversationArchived(id: String) {
    if (id == conversationId.value) createAndOpen(projectId = null)
  }

  private fun createAndOpen(projectId: String?) {
    if (creatingConversation) return
    creatingConversation = true
    viewModelScope.launch {
      try {
        val created = container.conversations.createConversation(projectId, null)
        flushDraft()
        switchTo(created.id)
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        noticeChannel.post("Turing AI couldn't start a new chat. ${e.userMessage()}")
      } finally {
        creatingConversation = false
      }
    }
  }

  private fun switchTo(id: String?) {
    draftJob?.cancel()
    draftJob = null
    draftOwnerId = id
    draft = ""
    draftLoaded = false
    selectedAttempts.clear()
    savedState[KEY_CONVERSATION_ID] = id
  }

  /** Opens the most recent active chat, or a fresh one when history is empty. */
  private suspend fun openHome(excluding: String?) {
    val recent = try {
      container.conversations.observeConversations().first().firstOrNull { it.id != excluding }
    } catch (e: CancellationException) {
      throw e
    } catch (e: Exception) {
      null
    }
    if (recent != null) {
      switchTo(recent.id)
    } else {
      switchTo(null)
      createAndOpen(projectId = null)
    }
  }

  private fun onConversationGone(id: String) {
    if (id != conversationId.value) return
    // Never write a debounced draft into a deleted chat.
    draftJob?.cancel()
    draftJob = null
    attachmentsByConversation.remove(id)
    viewModelScope.launch { openHome(excluding = id) }
  }

  /**
   * A brand-new chat created before any model was enabled (or whose model was later disabled)
   * has nothing to preserve, so it adopts the same default the repository uses for new chats:
   * project override → app default → most recent → first enabled model. Chats with history are
   * never switched silently; they show "Choose a model" instead.
   */
  private suspend fun repairEmptyChatModel(
    conversation: Conversation?,
    transcript: TranscriptState,
    options: List<ModelOption>?,
    settings: AppSettings,
    projects: List<Project>,
  ) {
    if (conversation == null || options.isNullOrEmpty()) return
    if (transcript.conversationId != conversation.id || !transcript.loaded || transcript.messages.isNotEmpty()) return
    val choices = options.map { it.choice }.toSet()
    if (conversation.model != null && conversation.model in choices) return
    if (!modelRepairAttempted.add(conversation.id)) return
    val projectDefault = projects.firstOrNull { it.id == conversation.projectId }?.defaultModel
    val choice = listOfNotNull(projectDefault, settings.defaultModel).firstOrNull { it in choices }
      ?: settings.recentModels.firstOrNull { it in choices }
      ?: options.first().choice
    try {
      container.conversations.setModel(conversation.id, choice)
    } catch (e: CancellationException) {
      throw e
    } catch (e: Exception) {
      noticeChannel.post("Turing AI couldn't choose a model for this chat. ${e.userMessage()}")
    }
  }

  // Sending ------------------------------------------------------------------------------------

  /** Returns true when the message was handed to the chat engine. */
  fun send(): Boolean {
    val conversation = conversation.value ?: return false
    if (isGenerating.value) return false
    // A response must not race live dictation into the same chat (iOS operation coordinator).
    if (dictation.isActiveFor(conversation.id)) return false
    val option = selectedOption.value
    if (option == null) {
      noticeChannel.post("Choose an enabled model before sending.")
      return false
    }
    val text = draft.trim()
    val attachments = attachmentsFor(conversation.id)
    if (text.isEmpty() && attachments.isEmpty()) return false
    if (importingCount > 0) {
      noticeChannel.post("Wait for the attachment to finish preparing.")
      return false
    }
    if (attachments.any { it.kind == AttachmentKind.IMAGE } && !option.supportsImages) {
      noticeChannel.post(
        UiNotice("${option.modelId} doesn't accept photos. Choose a photo-capable model or remove the photos.", long = true)
      )
      return false
    }
    // Principle: no silent capability downgrade. Ask instead of quietly sending without search.
    if (conversation.webSearchEnabled && !WebSearchSupport.isSupported(option.providerKind, option.modelId)) {
      noticeChannel.post(
        UiNotice(
          text = "Web search isn't available for ${option.modelId}.",
          actionLabel = "Turn off",
          onAction = { setWebSearch(false) },
        )
      )
      return false
    }
    draftJob?.cancel()
    draftJob = null
    try {
      container.chat.send(conversation.id, text, attachments)
    } catch (e: Exception) {
      noticeChannel.post("Turing AI couldn't send this message. ${e.userMessage()}")
      return false
    }
    lastSubmission = Submission(
      conversationId = conversation.id,
      text = draft,
      attachments = attachments,
      messageCountBefore = transcript.value.takeIf { it.conversationId == conversation.id }?.messages?.size ?: 0,
    )
    draft = ""
    attachmentsByConversation.remove(conversation.id)
    draftWriteScope.launch { persistDraft(conversation.id, "") }
    return true
  }

  /**
   * The engine rejected the last send before persisting anything: put the text and attachments
   * back unless the person already started typing something else.
   */
  private fun restoreRejectedSubmission(conversationId: String) {
    val pending = lastSubmission?.takeIf { it.conversationId == conversationId } ?: return
    lastSubmission = null
    if (attachmentsFor(conversationId).isEmpty() && pending.attachments.isNotEmpty()) {
      attachmentsByConversation[conversationId] = pending.attachments
    }
    if (conversationId == draftOwnerId && draft.isBlank() && pending.text.isNotBlank()) {
      onDraftChange(pending.text)
    } else if (conversationId != draftOwnerId) {
      draftWriteScope.launch { persistDraft(conversationId, pending.text) }
    }
  }

  fun stop() {
    val id = conversationId.value ?: return
    container.chat.stop(id)
  }

  fun retry(item: TranscriptItem.Assistant, attempt: String) {
    val id = conversationId.value ?: return
    if (isGenerating.value || dictation.isActiveFor(id)) return
    try {
      container.chat.retry(id, attempt)
      // Show the new attempt as soon as it appears.
      selectedAttempts.remove(item.rootId)
    } catch (e: Exception) {
      noticeChannel.post("Turing AI couldn't retry. ${e.userMessage()}")
    }
  }

  // Attachments --------------------------------------------------------------------------------

  fun remainingAttachmentSlots(): Int {
    val id = conversationId.value ?: return 0
    return (AttachmentImporter.MAX_ATTACHMENTS - attachmentsFor(id).size - importingCount).coerceAtLeast(0)
  }

  fun addPhotos(context: Context, uris: List<Uri>) = import(context, uris) { appContext, uri ->
    AttachmentImporter.photo(appContext, uri)
  }

  fun addTextFile(context: Context, uri: Uri) = import(context, listOf(uri)) { appContext, picked ->
    AttachmentImporter.textFile(appContext, picked)
  }

  /**
   * PDF, Markdown or plain-text file extracted on-device (PDF text layer plus OCR for scanned
   * pages), sent as a document attachment like iOS. Progress is shown in the composer chip.
   */
  fun addDocument(context: Context, uri: Uri) = import(context, listOf(uri)) { appContext, picked ->
    attachmentProgress.value = "Opening file…"
    DocumentTextExtractor.chatAttachment(appContext, picked) { stage, step, stepCount ->
      attachmentProgress.value = documentProgressLabel(stage, step, stepCount)
    }
  }

  /** Label of the running document extraction; null while nothing reports progress. */
  val attachmentProgress = MutableStateFlow<String?>(null)
  private val importJobs = HashSet<Job>()

  /** Stops every attachment that is still being prepared; nothing is added for them. */
  fun cancelAttachmentImports() {
    importJobs.toList().forEach { it.cancel() }
  }

  private fun documentProgressLabel(stage: DocumentImportStage, step: Int?, stepCount: Int?): String {
    val counted = step != null && stepCount != null && stepCount > 0
    return when (stage) {
      DocumentImportStage.READING_FILE -> "Opening file…"
      DocumentImportStage.EXTRACTING_TEXT -> if (counted) "Reading page $step of $stepCount…" else "Reading text…"
      DocumentImportStage.RECOGNIZING_TEXT ->
        if (counted) "Recognizing text ($step of $stepCount)…" else "Recognizing text…"
      DocumentImportStage.PREPARING_CHUNKS, DocumentImportStage.SAVING -> "Preparing text…"
    }
  }

  private fun import(
    context: Context,
    uris: List<Uri>,
    importer: suspend (Context, Uri) -> Attachment,
  ) {
    val id = conversationId.value ?: return
    if (uris.isEmpty()) return
    val remaining = remainingAttachmentSlots()
    if (remaining == 0) {
      noticeChannel.post("A message can contain four attachments. Remove one to add another.")
      return
    }
    val accepted = uris.take(remaining)
    if (accepted.size < uris.size) {
      noticeChannel.post("Added ${accepted.size} of ${uris.size}. A message can contain four attachments.")
    }
    val appContext = context.applicationContext
    importingCount += accepted.size
    val job = viewModelScope.launch {
      var pending = accepted.size
      try {
        for (uri in accepted) {
          try {
            val attachment = importer(appContext, uri)
            attachmentsByConversation[id] = attachmentsFor(id) + attachment
          } catch (e: CancellationException) {
            throw e
          } catch (e: AttachmentImportException) {
            noticeChannel.post(UiNotice(e.userMessage(), long = true))
          } catch (e: DocumentIngestionException) {
            noticeChannel.post(UiNotice(e.userMessage(), long = true))
          } catch (e: Exception) {
            noticeChannel.post("This attachment could not be opened. ${e.userMessage()}")
          } finally {
            pending -= 1
            importingCount -= 1
          }
        }
      } finally {
        // A cancelled batch releases the slots of the files it never reached.
        importingCount -= pending
      }
    }
    importJobs += job
    job.invokeOnCompletion {
      importJobs -= job
      if (importJobs.isEmpty()) attachmentProgress.value = null
    }
  }

  fun removeAttachment(attachmentId: String) {
    val id = conversationId.value ?: return
    attachmentsByConversation[id] = attachmentsFor(id).filterNot { it.id == attachmentId }
  }

  // Model --------------------------------------------------------------------------------------

  fun selectModel(option: ModelOption) {
    val id = conversationId.value ?: return
    viewModelScope.launch {
      try {
        container.conversations.setModel(id, option.choice)
        container.settings.recordRecent(option.choice)
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        noticeChannel.post("Turing AI couldn't change the model. ${e.userMessage()}")
      }
    }
  }

  fun toggleFavorite(choice: ModelChoice) = launchSafely("Turing AI couldn't update favorites.") {
    container.settings.toggleFavorite(choice)
  }

  // Conversation actions -----------------------------------------------------------------------

  fun rename(title: String) {
    val id = conversationId.value ?: return
    val trimmed = title.trim()
    if (trimmed.isEmpty()) return
    launchSafely("Turing AI couldn't rename this chat.") { container.conversations.rename(id, trimmed) }
  }

  fun setSystemPrompt(prompt: String?) {
    val id = conversationId.value ?: return
    launchSafely("Turing AI couldn't save the instructions.") {
      container.conversations.setSystemPrompt(id, prompt?.trim()?.takeIf { it.isNotEmpty() })
    }
  }

  fun setWebSearch(enabled: Boolean) {
    val id = conversationId.value ?: return
    launchSafely("Turing AI couldn't change web search.") { container.conversations.setWebSearch(id, enabled) }
  }

  fun moveToProject(projectId: String?) {
    val id = conversationId.value ?: return
    viewModelScope.launch {
      try {
        container.conversations.moveToProject(id, projectId)
        val name = projects.value.firstOrNull { it.id == projectId }?.name
        noticeChannel.post(if (name != null) "Moved to $name." else "Removed from project.")
      } catch (e: CancellationException) {
        throw e
      } catch (e: IllegalStateException) {
        noticeChannel.post("Stop the response before moving this chat to another project.")
      } catch (e: Exception) {
        noticeChannel.post("Turing AI couldn't move this chat. ${e.userMessage()}")
      }
    }
  }

  fun setArchived(archived: Boolean) {
    val id = conversationId.value ?: return
    viewModelScope.launch {
      try {
        flushDraft()
        container.conversations.setArchived(id, archived)
        if (archived) {
          noticeChannel.post(
            UiNotice("Chat archived.", actionLabel = "Undo", onAction = {
              launchSafely("Turing AI couldn't restore this chat.") {
                container.conversations.setArchived(id, false)
                openConversation(id)
              }
            })
          )
          createAndOpen(projectId = null)
        } else {
          noticeChannel.post("Chat restored from the archive.")
        }
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        noticeChannel.post("Turing AI couldn't update this chat. ${e.userMessage()}")
      }
    }
  }

  fun deleteConversation() {
    val id = conversationId.value ?: return
    draftJob?.cancel()
    draftJob = null
    viewModelScope.launch {
      try {
        container.conversations.delete(id)
        noticeChannel.post("Chat deleted.")
        onConversationGone(id)
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        noticeChannel.post("Turing AI couldn't delete this chat. ${e.userMessage()}")
      }
    }
  }

  // Message actions ----------------------------------------------------------------------------

  fun saveToMemory(messageId: String, scope: MemoryScope) = viewModelScope.launch {
    try {
      container.memory.saveFromMessage(messageId, scope)
      noticeChannel.post(
        when (scope) {
          MemoryScope.EVERYWHERE -> "Saved to memory for all chats."
          MemoryScope.PROJECT -> "Saved to this project's memory."
          MemoryScope.CONVERSATION -> "Saved to this chat's memory."
        }
      )
    } catch (e: CancellationException) {
      throw e
    } catch (e: Exception) {
      noticeChannel.post("Turing AI couldn't save this to memory. ${e.userMessage()}")
    }
  }

  fun deleteMessage(messageId: String) = launchSafely("Turing AI couldn't delete this message.") {
    container.conversations.deleteMessage(messageId)
  }

  // Alternatives and prepared drafts (conversation tools) ---------------------------------------

  /** True while an alternative is being created; message actions stay disabled meanwhile. */
  var branching by mutableStateOf(false)
    private set

  /** Conversation whose newly opened draft should start in the model chooser ("Ask another model"). */
  var modelChoiceRequest by mutableStateOf<String?>(null)
    private set

  fun consumeModelChoiceRequest() {
    modelChoiceRequest = null
  }

  /** "Edit": a new alternative continues from [userMessageId] with [text] as its unsent draft. */
  fun editAndBranch(userMessageId: String, text: String) = branch(chooseModel = false) { sourceId ->
    container.alternatives.editAndBranch(sourceId, userMessageId, text)
  }

  /** "Ask another model": a new alternative with the same question unsent; choose a model, then Send. */
  fun askAnotherModel(assistantMessageId: String) = branch(chooseModel = true) { sourceId ->
    container.alternatives.askAnotherModel(sourceId, assistantMessageId)
  }

  private fun branch(
    chooseModel: Boolean,
    create: suspend (sourceId: String) -> CreatedAlternative,
  ) {
    val sourceId = conversationId.value ?: return
    if (branching || isGenerating.value) return
    branching = true
    flushDraft()
    viewModelScope.launch {
      try {
        val created = create(sourceId)
        openDraft(created.conversationId, created.draftAttachments, chooseModel)
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        noticeChannel.post("Turing AI couldn't create an alternative. ${e.userMessage()}")
      } finally {
        branching = false
      }
    }
  }

  /**
   * Opens a draft prepared elsewhere (an alternative or a shared item). Its text is already stored
   * on the conversation; [attachments] join the composer like freshly picked ones.
   */
  fun openDraft(conversationId: String, attachments: List<Attachment>, chooseModel: Boolean = false) {
    if (attachments.isNotEmpty()) {
      attachmentsByConversation[conversationId] = attachments.take(AttachmentImporter.MAX_ATTACHMENTS)
    }
    if (chooseModel) modelChoiceRequest = conversationId
    openConversation(conversationId)
  }

  fun post(notice: UiNotice) = noticeChannel.post(notice)

  private fun launchSafely(failure: String, block: suspend () -> Unit) = viewModelScope.launch {
    try {
      block()
    } catch (e: CancellationException) {
      throw e
    } catch (e: Exception) {
      noticeChannel.post("$failure ${e.userMessage()}")
    }
  }

  override fun onCleared() {
    flushDraft()
  }
}

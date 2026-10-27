package com.omergirgin.mosaic.data.chat

import android.util.Log
import androidx.room.withTransaction
import com.omergirgin.mosaic.core.chat.ChatImageInput
import com.omergirgin.mosaic.core.chat.ChatMessage
import com.omergirgin.mosaic.core.chat.ChatRequest
import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.chat.ProviderClientFactory
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import com.omergirgin.mosaic.core.chat.ProviderException
import com.omergirgin.mosaic.core.chat.StreamEvent
import com.omergirgin.mosaic.core.chat.WebSource
import com.omergirgin.mosaic.core.context.AttachmentText
import com.omergirgin.mosaic.core.context.ContextCandidate
import com.omergirgin.mosaic.core.context.ContextLimitsResolver
import com.omergirgin.mosaic.core.context.MemoryContextBuilder
import com.omergirgin.mosaic.core.context.MemoryContextScope
import com.omergirgin.mosaic.core.context.MemoryFactSnapshot
import com.omergirgin.mosaic.core.context.ProjectContextSnapshot
import com.omergirgin.mosaic.core.context.PromptLayers
import com.omergirgin.mosaic.core.context.utf8Length
import com.omergirgin.mosaic.core.net.WebSearchSupport
import com.omergirgin.mosaic.core.provider.profile
import com.omergirgin.mosaic.data.api.ChatEngine
import com.omergirgin.mosaic.data.api.SettingsRepository
import com.omergirgin.mosaic.data.compaction.ContextPlanningInput
import com.omergirgin.mosaic.data.connections.ConnectorChatContext
import com.omergirgin.mosaic.data.connections.ConnectorChatHook
import com.omergirgin.mosaic.data.memory.AutomaticMemoryFormation
import com.omergirgin.mosaic.data.recall.PreparedRecall
import com.omergirgin.mosaic.data.recall.RecallCoordinator
import com.omergirgin.mosaic.data.recall.RecallSourceKind
import com.omergirgin.mosaic.data.recall.planWithRecall
import com.omergirgin.mosaic.data.compaction.ConversationContextCoordinator
import com.omergirgin.mosaic.data.db.AttachmentEntity
import com.omergirgin.mosaic.data.db.CanonicalMessageRow
import com.omergirgin.mosaic.data.db.Codecs
import com.omergirgin.mosaic.data.db.ContextReceiptEntity
import com.omergirgin.mosaic.data.db.ConversationEntity
import com.omergirgin.mosaic.data.db.MemoryFactEntity
import com.omergirgin.mosaic.data.db.MessageEntity
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.UsageRecordEntity
import com.omergirgin.mosaic.data.db.choiceOf
import com.omergirgin.mosaic.data.db.roleOf
import com.omergirgin.mosaic.data.db.scopeOf
import com.omergirgin.mosaic.data.db.statusOf
import com.omergirgin.mosaic.data.internal.ErrorSanitizer
import com.omergirgin.mosaic.data.internal.FieldLimits
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.internal.compactTitle
import com.omergirgin.mosaic.data.internal.newId
import com.omergirgin.mosaic.data.model.Attachment
import com.omergirgin.mosaic.data.model.AttachmentKind
import com.omergirgin.mosaic.data.model.ChatNotice
import com.omergirgin.mosaic.data.model.ContextReceipt
import com.omergirgin.mosaic.data.model.GenerationOutcome
import com.omergirgin.mosaic.data.model.MemoryScope
import com.omergirgin.mosaic.data.model.MessageStatus
import com.omergirgin.mosaic.data.repo.NEW_CONVERSATION_TITLE
import com.omergirgin.mosaic.data.repo.ProviderRepositoryImpl
import com.omergirgin.mosaic.data.repo.ResolvedModel
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Port of the essentials of the iOS send path (`ConversationView.send/retry/startGeneration`):
 * persist the turn, assemble project + pinned-memory layers, plan context within the model's
 * limits, stream with checkpointed persistence, and record a receipt and usage.
 *
 * Work runs in the application scope so leaving a screen never cancels a paid request; only
 * [stop] (or deleting the chat) does. One generation per conversation is enforced by
 * [GenerationRegistry].
 */
internal class ChatEngineImpl(
  private val db: MosaicDatabase,
  private val providers: ProviderRepositoryImpl,
  private val settings: SettingsRepository,
  private val registry: GenerationRegistry,
  private val scope: CoroutineScope,
  /** Startup repair of interrupted rows; generations wait so they are never marked as orphans. */
  private val ready: Job,
  /** Cross-chat/document/topic recall; null disables it (e.g. unattended callers in tests). */
  private val recall: RecallCoordinator? = null,
  /** Automatic memory formation, started only after a reply is durably COMPLETE. */
  private val automaticMemory: AutomaticMemoryFormation? = null,
  /** Learned-topic usage counters ("Used N×"), bumped once a reply that used them completes. */
  private val recordTopicUse: (suspend (Collection<String>) -> Unit)? = null,
  /** Device-direct connections research (interactive sends only); null disables it. */
  private val connectors: ConnectorChatHook? = null,
) : ChatEngine {

  override val activeGenerations: StateFlow<Set<String>> = registry.active

  private val _notices = MutableSharedFlow<ChatNotice>(
    extraBufferCapacity = 16,
    onBufferOverflow = BufferOverflow.DROP_OLDEST,
  )
  override val notices: Flow<ChatNotice> = _notices.asSharedFlow()

  private val memoryBuilder = MemoryContextBuilder()
  private val contextCoordinator = ConversationContextCoordinator(db)

  override fun send(conversationId: String, text: String, attachments: List<Attachment>) =
    launchGeneration(conversationId) { prepareSend(conversationId, text, attachments) }

  override fun retry(conversationId: String, assistantMessageId: String) =
    launchGeneration(conversationId) { prepareRetry(conversationId, assistantMessageId) }

  override fun stop(conversationId: String) = registry.cancel(conversationId)

  // region scheduling

  /** Immutable plan for one assistant attempt, captured when its row is persisted. */
  private class Generation(
    val conversationId: String,
    val assistantId: String,
    /** History is every completed row strictly before this (createdAt, id) boundary. */
    val boundaryCreatedAt: Long,
    val boundaryId: String,
    val model: ResolvedModel,
    /** Interactive sends may use smart memory; unattended runs never do (iOS parity). */
    val interactive: Boolean = true,
  )

  private fun launchGeneration(conversationId: String, prepare: suspend () -> Generation) {
    val job = scope.launch(start = CoroutineStart.LAZY) {
      ready.join()
      val generation = try {
        prepare()
      } catch (error: CancellationException) {
        throw error
      } catch (error: Exception) {
        notify(conversationId, describePreflight(error))
        return@launch
      }
      run(generation)
    }
    // Released on completion, including a job cancelled before it ever started.
    job.invokeOnCompletion { registry.release(conversationId, job) }
    if (registry.register(conversationId, job)) {
      job.start()
    } else {
      job.cancel()
      notify(conversationId, "A reply is already being generated in this chat. Wait for it to finish, or stop it first.")
    }
  }

  private fun notify(conversationId: String, message: String) {
    _notices.tryEmit(ChatNotice(conversationId, message))
  }

  /**
   * [launchGeneration] for unattended callers: the same prepare/run path, but the preflight error
   * is returned instead of posted, and the caller suspends until the row is terminal. Joining a
   * job in the application scope means a cancelled caller never cancels the paid request.
   */
  override suspend fun runAndAwait(conversationId: String, text: String): GenerationOutcome {
    var assistantId: String? = null
    var preflightError: String? = null
    val job = scope.launch(start = CoroutineStart.LAZY) {
      ready.join()
      val generation = try {
        prepareSend(conversationId, text, emptyList(), interactive = false)
      } catch (error: CancellationException) {
        throw error
      } catch (error: Exception) {
        preflightError = describePreflight(error)
        return@launch
      }
      assistantId = generation.assistantId
      run(generation)
    }
    job.invokeOnCompletion { registry.release(conversationId, job) }
    if (!registry.register(conversationId, job)) {
      job.cancel()
      return GenerationOutcome(MessageStatus.FAILED, null, "A reply is already being generated in this chat.")
    }
    job.start()
    job.join()
    val id = assistantId
      ?: return GenerationOutcome(MessageStatus.FAILED, null, preflightError ?: "The request could not start.")
    val row = db.messages().get(id)
      ?: return GenerationOutcome(MessageStatus.CANCELLED, id, "The chat was deleted before the reply finished.")
    return GenerationOutcome(statusOf(row.status), id, row.errorMessage)
  }

  // endregion

  // region preparation (nothing is sent to a provider here)

  private suspend fun prepareSend(
    conversationId: String,
    text: String,
    attachments: List<Attachment>,
    interactive: Boolean = true,
  ): Generation {
    val typed = text.trim()
    validateInput(typed, attachments)
    val conversation = requireNotNull(db.conversations().get(conversationId)) { "This chat no longer exists." }
    val model = resolveModel(conversation)
    if (attachments.any { it.kind == AttachmentKind.IMAGE } && !model.supportsImages) {
      throw IllegalArgumentException(
        "Choose a model that supports photos, or mark its photo capability in the model picker."
      )
    }
    checkWebSearch(conversation, model)

    val hadMessages = db.messages().hasMessages(conversationId)
    val title = if (!hadMessages || conversation.title == NEW_CONVERSATION_TITLE) {
      compactTitle(typed.ifEmpty { attachments.firstOrNull()?.fileName ?: "Attachment" }).ifEmpty { "Attachment" }
    } else {
      conversation.title
    }

    val userId = newId()
    val userCreatedAt = MonotonicClock.now()
    val assistant = streamingRow(conversationId, model, retryOf = null)
    // Not cancellable: once the STREAMING row commits, `run` must own it so a stop always ends
    // in a terminal state (a cancelled withTransaction could commit and still throw).
    withContext(NonCancellable) {
      db.withTransaction {
        db.messages().insert(userRow(userId, conversationId, typed, userCreatedAt))
        if (attachments.isNotEmpty()) {
          db.attachments().insertAll(
            attachments.mapIndexed { index, attachment -> attachment.toEntity(userId, conversationId, index, userCreatedAt) }
          )
        }
        db.messages().insert(assistant)
        db.conversations().recordSend(conversationId, title, model.provider.id, model.modelId, assistant.createdAt)
      }
      afterRequestPersisted(model)
    }
    return Generation(conversationId, assistant.id, assistant.createdAt, assistant.id, model, interactive)
  }

  private suspend fun prepareRetry(conversationId: String, assistantMessageId: String): Generation {
    val conversation = requireNotNull(db.conversations().get(conversationId)) { "This chat no longer exists." }
    val target = db.messages().get(assistantMessageId)?.takeIf { it.conversationId == conversationId }
    requireNotNull(target) { "This reply no longer exists." }
    require(roleOf(target.role) == ChatRole.ASSISTANT) { "Only replies can be retried." }
    // A new attempt is appended at the end of the transcript, so it must answer the latest turn.
    require(!db.messages().hasUserMessageAfter(conversationId, target.createdAt, target.id)) {
      "Only the latest reply can be retried."
    }
    val model = resolveModel(conversation)
    checkWebSearch(conversation, model)

    val assistant = streamingRow(conversationId, model, retryOf = target.id)
    withContext(NonCancellable) {
      db.withTransaction {
        db.messages().insert(assistant)
        db.conversations().setModel(conversationId, model.provider.id, model.modelId)
        db.conversations().touch(conversationId, assistant.createdAt)
      }
      afterRequestPersisted(model)
    }
    // The new attempt answers the same user turn: history ends before the attempt it replaces.
    return Generation(conversationId, assistant.id, target.createdAt, target.id, model)
  }

  private fun validateInput(typed: String, attachments: List<Attachment>) {
    require(typed.isNotEmpty() || attachments.isNotEmpty()) { "Type a message or attach a file." }
    FieldLimits.requireWithin(typed, FieldLimits.MESSAGE_CONTENT_BYTES, "The message")
    require(attachments.size <= FieldLimits.ATTACHMENTS_PER_MESSAGE) {
      "A message can contain ${FieldLimits.ATTACHMENTS_PER_MESSAGE} attachments."
    }
    for (attachment in attachments) {
      when (attachment.kind) {
        AttachmentKind.IMAGE -> {
          val data = attachment.imageBase64
          require(!data.isNullOrEmpty()) { "The photo ${attachment.fileName} could not be prepared." }
          require(data.length <= FieldLimits.IMAGE_BASE64_CHARS) { "This photo is too large. Choose a smaller image." }
        }
        AttachmentKind.PDF, AttachmentKind.TEXT -> {
          val text = attachment.extractedText
          require(!text.isNullOrBlank()) { "No text could be read from ${attachment.fileName}." }
          require(utf8Length(text) <= FieldLimits.ATTACHMENT_TEXT_BYTES) {
            "${attachment.fileName} is too long for a chat attachment."
          }
        }
      }
    }
  }

  /** The chat's model, or the default chain when the chat has none yet. */
  private suspend fun resolveModel(conversation: ConversationEntity): ResolvedModel {
    val projectDefault = conversation.projectId
      ?.let { db.projects().get(it) }
      ?.let { choiceOf(it.defaultProviderId, it.defaultModelId) }
    val choice = choiceOf(conversation.modelProviderId, conversation.modelId)
      ?: providers.defaultChoice(null, projectDefault)
      ?: throw IllegalArgumentException("Choose a model before sending. Add a provider in Settings if none is available.")
    return providers.resolveModel(choice)
  }

  private fun checkWebSearch(conversation: ConversationEntity, model: ResolvedModel) {
    // Connection-aware check: a custom base URL never receives a vendor-native search tool.
    if (conversation.webSearchEnabled && !WebSearchSupport.isSupported(model.connectionWithoutKey())) {
      throw IllegalArgumentException("Turn off Web search, or choose a model that supports it.")
    }
  }

  private fun userRow(id: String, conversationId: String, content: String, createdAt: Long) = MessageEntity(
    id = id,
    conversationId = conversationId,
    role = ChatRole.USER.rawValue,
    content = content,
    status = MessageStatus.COMPLETE.name,
    errorMessage = null,
    providerId = null,
    providerKind = null,
    providerName = null,
    modelId = null,
    destinationHost = null,
    inputTokens = null,
    outputTokens = null,
    responseId = null,
    retryOfMessageId = null,
    citationsJson = null,
    createdAt = createdAt,
    updatedAt = createdAt,
  )

  private fun streamingRow(conversationId: String, model: ResolvedModel, retryOf: String?): MessageEntity {
    val now = MonotonicClock.now()
    return MessageEntity(
      id = newId(),
      conversationId = conversationId,
      role = ChatRole.ASSISTANT.rawValue,
      content = "",
      status = MessageStatus.STREAMING.name,
      errorMessage = null,
      // Provenance snapshot: later provider edits never rewrite which host received the request.
      providerId = model.provider.id,
      providerKind = model.kind.rawId,
      providerName = model.provider.displayName,
      modelId = model.modelId,
      destinationHost = model.destinationHost,
      inputTokens = null,
      outputTokens = null,
      responseId = null,
      retryOfMessageId = retryOf,
      citationsJson = null,
      createdAt = now,
      updatedAt = now,
    )
  }

  /**
   * Bookkeeping that must never fail a request. Onboarding is also marked complete here as a
   * safety net; the onboarding UI is still expected to call `setOnboardingCompleted(true)`.
   */
  private suspend fun afterRequestPersisted(model: ResolvedModel) {
    runCatching {
      settings.recordRecent(model.choice)
      if (!settings.settings.first().hasCompletedOnboarding) settings.setOnboardingCompleted(true)
    }
  }

  private fun describePreflight(error: Exception): String = when (error) {
    is ProviderException, is IllegalArgumentException, is IllegalStateException ->
      ErrorSanitizer.sanitize(error.message ?: GENERIC_FAILURE, null)
    else -> GENERIC_FAILURE
  }

  // endregion

  // region generation

  /** Mutable accumulation for one stream; confined to the generation coroutine. */
  private class StreamState {
    val content = StringBuilder()
    var contentBytes = 0
    var inputTokens: Int? = null
    var outputTokens: Int? = null
    var usageReported = false
    var responseId: String? = null
    var completed = false
    val citations = LinkedHashSet<WebSource>()
    /** Learned topics included in the committed request (from its receipt). */
    var usedTopicIds: List<String> = emptyList()
  }

  private suspend fun run(generation: Generation) {
    val state = StreamState()
    var apiKey: String? = null
    var connection: ProviderConnection? = null
    val failure: String?
    try {
      val conversation = requireNotNull(db.conversations().get(generation.conversationId)) { "This chat no longer exists." }
      val model = generation.model
      apiKey = providers.keyFor(model.provider, model.kind, required = model.kind.profile.requiresApiKey)
      val resolvedConnection = model.connectionWithoutKey().copy(apiKey = apiKey)
      connection = resolvedConnection

      val history = loadHistory(generation)
      // Connected services run before the answer request; their sources join the reply's citations.
      val connected = if (generation.interactive) prepareConnections(generation, history, resolvedConnection) else null
      if (connected != null && connected.sources.isNotEmpty()) {
        for (source in connected.sources) if (state.citations.size < MAX_CITATIONS) state.citations += source
        db.messages().setCitations(generation.assistantId, Codecs.encodeCitations(state.citations.toList()))
      }
      val (request, receipt) = buildRequest(conversation, model, history, generation, resolvedConnection, connected?.prompt)
      // Receipt is committed before the stream opens, so even an interrupted request is auditable.
      db.receipts().upsert(
        ContextReceiptEntity(
          messageId = generation.assistantId,
          conversationId = generation.conversationId,
          json = Codecs.encodeReceipt(receipt),
          createdAt = MonotonicClock.now(),
        )
      )
      state.usedTopicIds = receipt.recall?.items.orEmpty()
        .filter { it.kind == RecallSourceKind.MEMORY_TOPIC }
        .map { it.id }

      val checkpoint = CheckpointPolicy()
      ProviderClientFactory.make(resolvedConnection).stream(request).collect { event ->
        when (event) {
          is StreamEvent.TextDelta -> {
            if (event.text.isEmpty()) return@collect
            val bytes = utf8Length(event.text)
            if (state.contentBytes.toLong() + bytes > FieldLimits.MESSAGE_CONTENT_BYTES) {
              throw ProviderException(
                ProviderErrorKind.RESPONSE_TOO_LARGE,
                "The reply exceeded Turing AI's 512 KB message limit. The text received so far was kept.",
              )
            }
            state.content.append(event.text)
            state.contentBytes += bytes
            if (checkpoint.shouldPersist(bytes)) {
              db.messages().checkpoint(generation.assistantId, state.content.toString(), MonotonicClock.now())
              checkpoint.didPersist()
            }
          }
          is StreamEvent.Citations -> {
            val before = state.citations.size
            for (source in event.sources) {
              if (state.citations.size >= MAX_CITATIONS) break
              state.citations += source
            }
            if (state.citations.size != before) {
              db.messages().setCitations(generation.assistantId, Codecs.encodeCitations(state.citations.toList()))
            }
          }
          is StreamEvent.Usage -> {
            state.usageReported = true
            event.usage.inputTokens?.let { state.inputTokens = it }
            event.usage.outputTokens?.let { state.outputTokens = it }
          }
          is StreamEvent.Completed -> {
            state.responseId = event.responseId
            state.completed = true
          }
        }
      }

      failure = when {
        state.completed && state.content.isNotEmpty() -> null
        state.content.isEmpty() -> "The provider completed without visible text."
        else -> "The connection ended before the provider confirmed completion."
      }
    } catch (error: CancellationException) {
      if (!currentCoroutineContext().isActive) {
        // User stop (or chat deletion): keep the partial text and record usage already incurred.
        finish(generation, MessageStatus.CANCELLED, null, state, connection)
        throw error
      }
      // A cancellation that did not come from this job is an abnormal stream end, not a stop.
      finish(generation, MessageStatus.FAILED, "The request was interrupted. You can try again.", state, connection)
      return
    } catch (error: Exception) {
      finish(generation, MessageStatus.FAILED, ErrorSanitizer.describe(error, apiKey), state, connection)
      return
    }
    finish(generation, if (failure == null) MessageStatus.COMPLETE else MessageStatus.FAILED, failure, state, connection)
  }

  /**
   * Canonical provider-facing history before the boundary, bounded like iOS (20,000 rows /
   * 16 MiB) so a pathological chat fails visibly instead of exhausting memory.
   */
  private suspend fun loadHistory(generation: Generation): List<CanonicalMessageRow> {
    val rows = db.messages().canonicalBefore(
      generation.conversationId,
      generation.boundaryCreatedAt,
      generation.boundaryId,
      MAX_HISTORY_ROWS + 1,
    )
    var bytes = 0L
    for (row in rows) bytes += utf8Length(row.content)
    if (rows.size > MAX_HISTORY_ROWS || bytes > MAX_HISTORY_BYTES) {
      throw IllegalStateException(
        "This chat is too long to prepare safely (more than 20,000 messages or 16 MB of text). " +
          "Start a new chat to continue. No request was sent."
      )
    }
    // A retried answer that had completed leaves two consecutive completed replies for one user
    // turn; only the newest one represents the conversation going forward.
    val collapsed = ArrayList<CanonicalMessageRow>(rows.size)
    for (row in rows) {
      val previous = collapsed.lastOrNull()
      if (row.role == ChatRole.ASSISTANT.rawValue && previous?.role == ChatRole.ASSISTANT.rawValue) {
        collapsed[collapsed.lastIndex] = row
      } else {
        collapsed += row
      }
    }
    return collapsed
  }

  /** The current user turn's text drives connector routing; attachments are not sent to services. */
  private suspend fun prepareConnections(
    generation: Generation,
    history: List<CanonicalMessageRow>,
    connection: ProviderConnection,
  ): ConnectorChatContext? {
    val hook = connectors ?: return null
    val question = history.lastOrNull { it.role == ChatRole.USER.rawValue }?.content?.trim().orEmpty()
    val limits = ContextLimitsResolver.resolve(
      generation.model.limits.contextWindowTokens,
      generation.model.limits.maximumOutputTokens,
      generation.model.limitsSource,
    )
    return hook.prepare(generation.conversationId, generation.assistantId, question, connection, limits.policy.availableInputTokens)
  }

  private suspend fun buildRequest(
    conversation: ConversationEntity,
    model: ResolvedModel,
    history: List<CanonicalMessageRow>,
    generation: Generation,
    connection: ProviderConnection,
    /** Untrusted connected-service evidence appended after the other system layers. */
    connectedContext: String? = null,
  ): Pair<ChatRequest, ContextReceipt> {
    val project = conversation.projectId
      ?.let { db.projects().get(it) }
      ?.let { ProjectContextSnapshot(it.id, it.name, it.instructions.trim()) }
    val facts = db.memory().visibleTo(conversation.id, conversation.projectId).map(::snapshot)
    val memory = memoryBuilder.build(facts, conversation.id, conversation.projectId)
    // Cross-chat/document/topic recall for the current turn. Never blocks sending: failures fall
    // back to local lexical recall (or none) with receipt warnings. Smart memory (bounded by its
    // own timeout) uses this chat's connection for interactive sends only.
    val recalled = recall?.prepare(
      conversation.id, conversation.projectId, history,
      rankingConnection = connection.takeIf { generation.interactive },
    ) ?: PreparedRecall.NONE
    val composeSystemPrompt = { layer: PreparedRecall ->
      PromptLayers.composeSystemPrompt(conversation.systemPrompt, project, layer.appendTo(memory.systemContent))
        .let { base -> if (connectedContext == null) base else listOfNotNull(base, connectedContext).joinToString("\n\n") }
    }

    val attachmentRows = db.attachments().textRows(conversation.id).groupBy { it.messageId }
    val candidates = history.map { row ->
      val attachments = attachmentRows[row.id].orEmpty()
      val texts = attachments.mapNotNull { attachment ->
        val text = attachment.extractedText
        if (attachment.hasImage || text.isNullOrBlank()) null
        else AttachmentText(attachment.fileName, attachment.mimeType, text)
      }
      ContextCandidate(
        id = row.id,
        role = roleOf(row.role),
        content = PromptLayers.userContent(row.content, texts),
        imageCount = attachments.count { it.hasImage },
      )
    }

    val limits = ContextLimitsResolver.resolve(
      model.limits.contextWindowTokens,
      model.limits.maximumOutputTokens,
      model.limitsSource,
    )
    // Rolling compaction + same-chat recall (compaction/). Falls back visibly to the recent-raw
    // planner, which throws before any answer request when the protected content cannot fit.
    // Recall is optional: dropped if it cannot fit, and revalidated right before the request.
    val recallPlanned = recall.planWithRecall(recalled, composeSystemPrompt) { recallSystemPrompt ->
      contextCoordinator.plan(
        ContextPlanningInput(
          conversationId = conversation.id,
          conversationTitle = conversation.title,
          assistantMessageId = generation.assistantId,
          // An exact retry never starts a new paid summary request (it may reuse one).
          allowNewCompaction = generation.boundaryId == generation.assistantId,
          connection = connection,
          policy = limits.policy,
          limitWarnings = limits.warnings,
          systemPrompt = recallSystemPrompt,
          rows = history,
          candidates = candidates,
          reloadRows = { loadHistory(generation) },
        )
      )
    }
    val planned = recallPlanned.plan
    val systemPrompt = recallPlanned.systemPrompt
    val plan = planned.plan

    val photoMessageIds = plan.messages.filter { it.imageCount > 0 }.map { it.id }
    if (photoMessageIds.isNotEmpty() && !model.supportsImages) {
      throw IllegalArgumentException("This chat contains photos. Choose a photo-capable model before continuing.")
    }
    val images = loadImages(photoMessageIds)

    val request = ChatRequest(
      messages = plan.messages.map { ChatMessage(it.id, it.role, it.content, images[it.id].orEmpty()) },
      systemPrompt = systemPrompt,
      maxOutputTokens = limits.policy.maximumOutputTokens,
      webSearch = conversation.webSearchEnabled,
    )
    val receipt = ContextReceipt(
      projectName = project?.name,
      projectInstructions = project?.instructions?.takeIf { it.isNotEmpty() },
      pinnedFacts = memory.includedMemories.map { it.title },
      includedMessageIds = plan.receipt.includedMessageIds,
      omittedMessageIds = plan.receipt.omittedMessageIds,
      estimatedInputTokens = plan.receipt.estimatedInputTokens,
      inputBudgetTokens = plan.receipt.inputBudgetTokens,
      warnings = plan.receipt.warnings,
    ).let(planned::applyTo).copy(recall = recallPlanned.recall.receipt)
    return request to receipt
  }

  private suspend fun loadImages(messageIds: List<String>): Map<String, List<ChatImageInput>> {
    if (messageIds.isEmpty()) return emptyMap()
    // SQLite bounds bound parameters per statement; chunk well below the limit.
    return messageIds.chunked(500)
      .flatMap { db.attachments().images(it) }
      .groupBy({ it.messageId }, { ChatImageInput(it.mimeType, it.imageBase64) })
  }

  private suspend fun finish(
    generation: Generation,
    status: MessageStatus,
    errorMessage: String?,
    state: StreamState,
    connection: ProviderConnection?,
  ) = withContext(NonCancellable) {
    try {
      val now = MonotonicClock.now()
      db.withTransaction {
        db.messages().finish(
          id = generation.assistantId,
          status = status.name,
          content = state.content.toString(),
          errorMessage = errorMessage,
          inputTokens = state.inputTokens,
          outputTokens = state.outputTokens,
          responseId = state.responseId,
          citationsJson = Codecs.encodeCitations(state.citations.toList()),
          now = now,
        )
        db.conversations().touch(generation.conversationId, now)
        // Failed and cancelled requests may still have been billed; record whatever was reported.
        if (state.usageReported && connection != null) {
          db.usage().insert(
            UsageRecordEntity(
              id = newId(),
              providerId = connection.id,
              providerKind = connection.provider.rawId,
              providerName = connection.displayName,
              modelId = connection.modelId,
              destinationHost = connection.destinationHost,
              category = "Chat",
              inputTokens = state.inputTokens,
              outputTokens = state.outputTokens,
              conversationId = generation.conversationId,
              messageId = generation.assistantId,
              createdAt = now,
            )
          )
        }
      }
      // Topic usage bookkeeping (iOS: after a completed reply) must never fail the reply.
      if (status == MessageStatus.COMPLETE && state.usedTopicIds.isNotEmpty()) {
        try {
          recordTopicUse?.invoke(state.usedTopicIds)
        } catch (error: Exception) {
          Log.w(TAG, "Could not record learned-topic use (${error.javaClass.simpleName}).")
        }
      }
      // Only after the COMPLETE state committed; never delays or changes the reply.
      if (status == MessageStatus.COMPLETE && connection != null) {
        automaticMemory?.afterCompletedReply(
          generation.conversationId, generation.assistantId, generation.boundaryCreatedAt, generation.boundaryId, connection,
        )
      }
    } catch (error: Exception) {
      // The row stays STREAMING and is repaired as interrupted on the next launch. Only the type
      // is logged; messages could contain request content.
      Log.w(TAG, "Could not persist the final reply state (${error.javaClass.simpleName}).")
    }
  }

  private fun snapshot(entity: MemoryFactEntity) = MemoryFactSnapshot(
    id = entity.id,
    title = entity.title,
    content = entity.content,
    scope = when (scopeOf(entity.scope)) {
      MemoryScope.EVERYWHERE -> MemoryContextScope.GLOBAL
      MemoryScope.PROJECT -> MemoryContextScope.PROJECT
      MemoryScope.CONVERSATION -> MemoryContextScope.CONVERSATION
    },
    projectId = entity.projectId,
    conversationId = entity.conversationId,
    isEnabled = entity.isEnabled,
    updatedAt = entity.updatedAt,
  )

  private fun Attachment.toEntity(messageId: String, conversationId: String, position: Int, createdAt: Long) =
    AttachmentEntity(
      // Fresh row IDs: draft attachment IDs are UI-local and may be reused across sends.
      id = newId(),
      messageId = messageId,
      conversationId = conversationId,
      kind = kind.name,
      fileName = fileName.trim().take(200).ifEmpty { if (kind == AttachmentKind.IMAGE) "Photo" else "Document" },
      mimeType = mimeType.trim().take(255).ifEmpty { if (kind == AttachmentKind.IMAGE) "image/jpeg" else "text/plain" },
      extractedText = if (kind == AttachmentKind.IMAGE) null else extractedText,
      imageBase64 = if (kind == AttachmentKind.IMAGE) imageBase64 else null,
      position = position,
      createdAt = createdAt,
    )

  // endregion

  /**
   * iOS `ConversationStreamPersistencePolicy`: bound the text that exists only in memory without
   * writing every token. Terminal states are always persisted separately.
   */
  private class CheckpointPolicy {
    private var unpersistedBytes = 0
    private var lastPersistedAt = System.nanoTime()

    fun shouldPersist(appendedBytes: Int): Boolean {
      unpersistedBytes += appendedBytes
      return unpersistedBytes >= MAX_UNPERSISTED_BYTES ||
        System.nanoTime() - lastPersistedAt >= MAX_UNPERSISTED_NANOS
    }

    fun didPersist() {
      unpersistedBytes = 0
      lastPersistedAt = System.nanoTime()
    }
  }

  private companion object {
    const val TAG = "TuringChat"
    const val GENERIC_FAILURE = "Turing AI could not save this message. Try again."
    const val MAX_HISTORY_ROWS = 20_000
    const val MAX_HISTORY_BYTES = 16L * 1_024 * 1_024
    const val MAX_CITATIONS = 100
    const val MAX_UNPERSISTED_BYTES = 8 * 1_024
    const val MAX_UNPERSISTED_NANOS = 250_000_000L
  }
}

package com.omergirgin.mosaic.data.repo

import android.util.Log
import androidx.room.withTransaction
import com.omergirgin.mosaic.data.api.ConversationRepository
import com.omergirgin.mosaic.data.chat.GenerationRegistry
import com.omergirgin.mosaic.data.db.Codecs
import com.omergirgin.mosaic.data.db.ConversationEntity
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.choiceOf
import com.omergirgin.mosaic.data.db.statusOf
import com.omergirgin.mosaic.data.db.toModel
import com.omergirgin.mosaic.data.internal.FieldLimits
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.internal.newId
import com.omergirgin.mosaic.data.memory.AutomaticMemoryLifecycle
import com.omergirgin.mosaic.data.model.Conversation
import com.omergirgin.mosaic.data.model.ConversationSummary
import com.omergirgin.mosaic.data.model.Message
import com.omergirgin.mosaic.data.model.MessageStatus
import com.omergirgin.mosaic.data.model.ModelChoice
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map

internal const val NEW_CONVERSATION_TITLE = "New conversation"

internal class ConversationRepositoryImpl(
  private val db: MosaicDatabase,
  private val providers: ProviderRepositoryImpl,
  private val registry: GenerationRegistry,
  /**
   * Best-effort cleanup of derived data (message and chat-scoped topic vectors) after a chat's
   * source rows are deleted. Vectors are a rebuildable cache, so a failure here never fails the
   * deletion (iOS semantics).
   */
  private val afterConversationDeleted: suspend (messageIds: List<String>, topicIds: List<String>) -> Unit = { _, _ -> },
) : ConversationRepository {
  private val dao = db.conversations()

  override fun observeConversations(query: String, archived: Boolean, projectId: String?): Flow<List<ConversationSummary>> {
    val trimmed = query.trim()
    val pattern = if (trimmed.isEmpty()) "" else "%" + escapeLike(trimmed) + "%"
    return dao.observeSummaries(pattern, archived, projectId)
      .map { rows -> rows.map { it.toModel() } }
      .distinctUntilChanged()
      .flowOn(Dispatchers.Default)
  }

  override fun observeConversation(id: String): Flow<Conversation?> =
    dao.observe(id).map { it?.toModel() }.distinctUntilChanged()

  /**
   * Messages, attachments and receipts are observed as three queries over three tables. Room
   * invalidates per table, so a streaming checkpoint (messages only) re-reads message rows but
   * neither photo payloads nor receipts, and never re-decodes them.
   */
  override fun observeMessages(conversationId: String): Flow<List<Message>> {
    val attachments = db.attachments().observe(conversationId)
      .map { rows -> rows.groupBy({ it.messageId }, { it.toModel() }) }
      .distinctUntilChanged()
    val receipts = db.receipts().observe(conversationId)
      .map { rows -> rows.associate { it.messageId to Codecs.decodeReceipt(it.json) } }
      .distinctUntilChanged()
    return combine(db.messages().observe(conversationId), attachments, receipts) { messages, byMessage, receiptByMessage ->
      messages.map { it.toModel(byMessage[it.id].orEmpty(), receiptByMessage[it.id]) }
    }
      .distinctUntilChanged()
      .flowOn(Dispatchers.Default)
  }

  override suspend fun createConversation(projectId: String?, model: ModelChoice?): Conversation {
    val project = projectId?.let { requireNotNull(db.projects().get(it)) { "This project no longer exists." } }
    val choice = providers.defaultChoice(model, project?.let { choiceOf(it.defaultProviderId, it.defaultModelId) })
    val now = MonotonicClock.now()
    val entity = ConversationEntity(
      id = newId(),
      title = NEW_CONVERSATION_TITLE,
      projectId = project?.id,
      systemPrompt = null,
      modelProviderId = choice?.providerId,
      modelId = choice?.modelId,
      draft = "",
      isArchived = false,
      webSearchEnabled = false,
      createdAt = now,
      updatedAt = now,
    )
    dao.insert(entity)
    return entity.toModel()
  }

  override suspend fun updateDraft(id: String, draft: String) {
    FieldLimits.requireWithin(draft, FieldLimits.DRAFT_BYTES, "The draft")
    // Drafts do not bump updatedAt, so typing never reorders the history list.
    dao.setDraft(id, draft)
  }

  override suspend fun rename(id: String, title: String) {
    val trimmed = title.trim()
    require(trimmed.isNotEmpty()) { "Enter a title." }
    FieldLimits.requireWithin(trimmed, FieldLimits.CONVERSATION_TITLE_BYTES, "The title")
    dao.setTitle(id, trimmed, MonotonicClock.now())
  }

  override suspend fun setModel(id: String, choice: ModelChoice) {
    dao.setModel(id, choice.providerId, choice.modelId)
  }

  override suspend fun setSystemPrompt(id: String, prompt: String?) {
    val value = prompt?.takeIf { it.isNotBlank() }
    if (value != null) FieldLimits.requireWithin(value, FieldLimits.SYSTEM_PROMPT_BYTES, "The system prompt")
    dao.setSystemPrompt(id, value)
  }

  override suspend fun setWebSearch(id: String, enabled: Boolean) {
    dao.setWebSearch(id, enabled)
  }

  override suspend fun moveToProject(id: String, projectId: String?) {
    // A running request captured the old project's instructions and facts; moving it mid-flight
    // would make its receipt disagree with the chat's audience.
    check(!registry.isActive(id)) { "Wait for the current reply to finish before moving this chat." }
    if (projectId != null) requireNotNull(db.projects().get(projectId)) { "This project no longer exists." }
    val now = MonotonicClock.now()
    db.withTransaction {
      val current = dao.get(id) ?: return@withTransaction
      // Learned memory supported only by this chat moves with it; mixed-audience memory rejects the move.
      AutomaticMemoryLifecycle.reconcileConversationMove(db, id, current.projectId, projectId, now)
      dao.setProject(id, projectId, now)
    }
  }

  override suspend fun setArchived(id: String, archived: Boolean) {
    dao.setArchived(id, archived, MonotonicClock.now())
  }

  override suspend fun delete(id: String) {
    // Stop first so the generation finishes its terminal write before its rows disappear.
    registry.cancelAndJoin(id)
    val (messageIds, topicIds) = db.withTransaction {
      val messageIds = db.messages().idsIn(id)
      val topicIds = db.automaticMemory().conversationScopedTopics(id).map { it.id }
      // Shared learned memory is reconciled before its source rows disappear.
      AutomaticMemoryLifecycle.beforeConversationDeletion(db, id, MonotonicClock.now())
      dao.delete(id)
      messageIds to topicIds
    }
    // Only after the source deletion committed.
    try {
      afterConversationDeleted(messageIds, topicIds)
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      // Type only; the stale vectors are unreachable (recall revalidates sources) and rebuildable.
      Log.w("TuringData", "Vector cleanup after chat deletion failed (${error.javaClass.simpleName}).")
    }
  }

  override suspend fun deleteMessage(messageId: String) {
    val message = db.messages().get(messageId) ?: return
    check(!(statusOf(message.status) == MessageStatus.STREAMING && registry.isActive(message.conversationId))) {
      "Stop the reply before deleting it."
    }
    db.withTransaction {
      db.messages().relinkRetries(message.id, message.retryOfMessageId)
      db.messages().delete(message.id)
    }
  }

  private fun escapeLike(value: String): String =
    value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
}

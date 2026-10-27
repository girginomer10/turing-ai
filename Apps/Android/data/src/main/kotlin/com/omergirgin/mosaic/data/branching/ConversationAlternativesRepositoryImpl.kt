package com.omergirgin.mosaic.data.branching

import androidx.room.withTransaction
import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.data.db.AttachmentEntity
import com.omergirgin.mosaic.data.db.ConversationEntity
import com.omergirgin.mosaic.data.db.MessageEntity
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.toModel
import com.omergirgin.mosaic.data.internal.FieldLimits
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.internal.newId
import com.omergirgin.mosaic.data.model.MessageStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map

internal class ConversationAlternativesRepositoryImpl(private val db: MosaicDatabase) : ConversationAlternativesRepository {
  private val dao = db.conversationBranches()

  override fun observeAlternatives(conversationId: String): Flow<List<ConversationAlternative>> =
    dao.observeGroup(conversationId)
      .map { rows ->
        rows.map {
          ConversationAlternative(
            conversationId = it.conversationId,
            title = it.title,
            providerName = it.providerName,
            modelId = it.modelId,
            isOriginal = it.originalConversationId == null,
            isArchived = it.isArchived,
            createdAt = it.createdAt,
            updatedAt = it.updatedAt,
          )
        }
      }
      .distinctUntilChanged()
      .flowOn(Dispatchers.Default)

  override suspend fun editAndBranch(sourceId: String, userMessageId: String, draft: String): CreatedAlternative {
    require(draft.isNotBlank()) { "Enter the message to continue with." }
    FieldLimits.requireWithin(draft, FieldLimits.MESSAGE_CONTENT_BYTES, "The edited message")
    return create(sourceId, userMessageId, draft)
  }

  override suspend fun askAnotherModel(sourceId: String, assistantMessageId: String): CreatedAlternative {
    val response = db.messages().get(assistantMessageId)
      ?.takeIf { it.conversationId == sourceId && it.role == ChatRole.ASSISTANT.rawValue }
      ?: throw IllegalStateException(STALE_SOURCE)
    val question = dao.userTurnBefore(sourceId, response.createdAt, response.id)
      ?: throw IllegalStateException("This response has no question to ask again.")
    return create(sourceId, question.id, typedText(question.content))
  }

  /**
   * iOS `ConversationBranchStore.create`: one transaction inserts the new chat, the group links,
   * and copies of every completed message before the branch point with their attachments.
   */
  private suspend fun create(sourceId: String, userMessageId: String, draft: String): CreatedAlternative =
    db.withTransaction {
      val source = db.conversations().get(sourceId) ?: throw IllegalStateException(STALE_SOURCE)
      val anchor = db.messages().get(userMessageId)?.takeIf {
        it.conversationId == sourceId && it.role == ChatRole.USER.rawValue && it.status == MessageStatus.COMPLETE.name
      } ?: throw IllegalStateException(STALE_SOURCE)

      val now = MonotonicClock.now()
      val alternativeId = newId()
      db.conversations().insert(
        ConversationEntity(
          id = alternativeId,
          title = prefixCodePoints(source.title + " · Alternative", MAX_TITLE_CODE_POINTS),
          projectId = source.projectId,
          systemPrompt = source.systemPrompt,
          modelProviderId = source.modelProviderId,
          modelId = source.modelId,
          draft = draft,
          isArchived = false,
          // Search is chosen per request; the new draft starts without it, as on iOS.
          webSearchEnabled = false,
          createdAt = now,
          updatedAt = now,
        )
      )
      val sourceLink = dao.linkFor(sourceId)
      val groupId = sourceLink?.branchGroupId ?: sourceId
      if (sourceLink == null) {
        dao.insert(ConversationBranchEntity(newId(), sourceId, groupId, originalConversationId = null, updatedAt = now))
      }
      dao.insert(ConversationBranchEntity(newId(), alternativeId, groupId, originalConversationId = sourceId, updatedAt = now))

      copyPrefix(sourceId, anchor, alternativeId)

      CreatedAlternative(
        conversationId = alternativeId,
        // Fresh IDs: draft attachment IDs are UI-local.
        draftAttachments = dao.attachments(anchor.id).map { it.toModel().copy(id = newId()) },
      )
    }

  private suspend fun copyPrefix(sourceId: String, anchor: MessageEntity, targetId: String) {
    val copiedIds = HashMap<String, String>()
    var previousCreatedAt: Long? = null
    var offset = 0
    var reachedAnchor = false
    while (!reachedAnchor) {
      val rows = dao.messagePage(sourceId, PAGE_SIZE, offset)
      if (rows.isEmpty()) throw IllegalStateException(STALE_SOURCE)
      val copies = ArrayList<Pair<MessageEntity, MessageEntity>>(rows.size)
      for (row in rows) {
        if (row.id == anchor.id) {
          reachedAnchor = true
          break
        }
        // Failed, stopped and still-streaming attempts never reach a provider again; skip them.
        if (row.status != MessageStatus.COMPLETE.name) continue
        // Fresh IDs must not reorder a prefix whose timestamps tie.
        val createdAt = previousCreatedAt?.let { maxOf(row.createdAt, it + 1) } ?: row.createdAt
        previousCreatedAt = createdAt
        val copyId = newId()
        copiedIds[row.id] = copyId
        copies += row to row.copy(
          id = copyId,
          conversationId = targetId,
          // No request ran for the copy: no usage counters, response ID, receipt or citations.
          inputTokens = null,
          outputTokens = null,
          responseId = null,
          citationsJson = null,
          retryOfMessageId = row.retryOfMessageId?.let(copiedIds::get),
          createdAt = createdAt,
          updatedAt = maxOf(createdAt, row.updatedAt),
        )
      }
      if (copies.isNotEmpty()) {
        dao.insertMessages(copies.map { it.second })
        val attachments = ArrayList<AttachmentEntity>()
        for ((original, copy) in copies) {
          dao.attachments(original.id).mapTo(attachments) {
            it.copy(id = newId(), messageId = copy.id, conversationId = targetId)
          }
        }
        if (attachments.isNotEmpty()) dao.insertAttachments(attachments)
      }
      offset += rows.size
    }
  }

  private companion object {
    const val STALE_SOURCE = "This message changed or was deleted. Reopen the chat and try again."
    const val PAGE_SIZE = 64
    /** iOS caps the alternative title at 160 characters. */
    const val MAX_TITLE_CODE_POINTS = 160
    const val ATTACHED_DOCUMENT_MARKER = "\n\n[Attached document content]\n"
    const val ATTACHED_PHOTO_MARKER = "\n\n[Attached photo SHA256:"

    /** iOS `ChatAttachmentStore.displayText`: the typed text without an inlined attachment payload. */
    fun typedText(content: String): String {
      val document = content.indexOf(ATTACHED_DOCUMENT_MARKER).takeIf { it >= 0 } ?: content.length
      val photo = content.indexOf(ATTACHED_PHOTO_MARKER).takeIf { it >= 0 } ?: content.length
      return content.substring(0, minOf(document, photo))
    }

    fun prefixCodePoints(value: String, limit: Int): String {
      if (value.codePointCount(0, value.length) <= limit) return value
      return value.substring(0, value.offsetByCodePoints(0, limit))
    }
  }
}

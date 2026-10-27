package com.omergirgin.mosaic.data.repo

import com.omergirgin.mosaic.data.api.MemoryRepository
import com.omergirgin.mosaic.data.db.MemoryFactEntity
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.toModel
import com.omergirgin.mosaic.data.internal.FieldLimits
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.internal.compactTitle
import com.omergirgin.mosaic.data.internal.newId
import com.omergirgin.mosaic.data.model.MemoryFact
import com.omergirgin.mosaic.data.model.MemoryScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

internal class MemoryRepositoryImpl(private val db: MosaicDatabase) : MemoryRepository {
  private val dao = db.memory()

  override fun observeFacts(): Flow<List<MemoryFact>> =
    dao.observeAll().map { rows -> rows.map { it.toModel() } }.distinctUntilChanged()

  override suspend fun saveFact(fact: MemoryFact) {
    val title = fact.title.trim()
    val content = fact.content.trim()
    require(content.isNotEmpty()) { "Enter the fact to remember." }
    FieldLimits.requireWithin(title, FieldLimits.MEMORY_TITLE_BYTES, "The memory title")
    FieldLimits.requireWithin(content, FieldLimits.MEMORY_CONTENT_BYTES, "The memory")

    // Only the owner matching the scope is kept, so a fact can never leak into a wider audience
    // through a stale project/conversation ID.
    val projectId = if (fact.scope == MemoryScope.PROJECT) {
      requireNotNull(fact.projectId) { "Choose a project for this memory." }
        .also { requireNotNull(db.projects().get(it)) { "This project no longer exists." } }
    } else {
      null
    }
    val conversationId = if (fact.scope == MemoryScope.CONVERSATION) {
      requireNotNull(fact.conversationId) { "Choose a chat for this memory." }
        .also { requireNotNull(db.conversations().get(it)) { "This chat no longer exists." } }
    } else {
      null
    }

    val existing = fact.id.takeIf { it.isNotBlank() }?.let { dao.get(it) }
    val now = MonotonicClock.now()
    dao.upsert(
      MemoryFactEntity(
        id = existing?.id ?: fact.id.ifBlank { newId() },
        title = title.ifEmpty { compactTitle(content) },
        content = content,
        scope = fact.scope.name,
        projectId = projectId,
        conversationId = conversationId,
        isEnabled = fact.isEnabled,
        createdAt = existing?.createdAt ?: now,
        updatedAt = now,
      )
    )
  }

  override suspend fun deleteFact(id: String) {
    dao.delete(id)
  }

  /** Without an explicit audience, a saved message applies everywhere (the iOS default action). */
  override suspend fun saveFromMessage(messageId: String) = saveFromMessage(messageId, MemoryScope.EVERYWHERE)

  override suspend fun saveFromMessage(messageId: String, scope: MemoryScope) {
    val message = requireNotNull(db.messages().get(messageId)) { "This message no longer exists." }
    require(message.content.isNotBlank()) { "This message has no text to remember." }
    val conversation = requireNotNull(db.conversations().get(message.conversationId)) { "This chat no longer exists." }
    val now = MonotonicClock.now()
    saveFact(
      MemoryFact(
        id = "",
        title = compactTitle(message.content),
        content = message.content,
        scope = scope,
        projectId = if (scope == MemoryScope.PROJECT) {
          checkNotNull(conversation.projectId) { "This chat is not in a project." }
        } else {
          null
        },
        conversationId = if (scope == MemoryScope.CONVERSATION) conversation.id else null,
        isEnabled = true,
        createdAt = now,
        updatedAt = now,
      )
    )
  }

  override suspend fun factsFor(conversationId: String, projectId: String?): List<MemoryFact> =
    dao.visibleTo(conversationId, projectId).map { it.toModel() }
}

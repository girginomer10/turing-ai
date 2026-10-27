package com.omergirgin.mosaic.data.recall

import androidx.room.Dao
import androidx.room.Query

internal data class RecallMessageKey(val id: String, val createdAt: Long)

internal data class RecallMessageRow(
  val id: String,
  val conversationId: String,
  val content: String,
  val createdAt: Long,
  val conversationTitle: String,
)

internal data class RecallDocumentRow(val id: String, val title: String, val updatedAt: Long)

internal data class RecallChunkRow(
  val id: String,
  val documentId: String,
  val chunkIndex: Int,
  val content: String,
  val pageNumber: Int?,
  val isOcrDerived: Boolean,
  val createdAt: Long,
)

internal data class RecallConversationScopeRow(val id: String, val projectId: String?)

internal data class MessageValidationRow(
  val id: String,
  val conversationId: String,
  val role: String,
  val status: String,
  val content: String,
  val projectId: String?,
)

internal data class ChunkValidationRow(
  val id: String,
  val documentId: String,
  val content: String,
  val isEnabled: Boolean,
  val projectId: String?,
)

/**
 * Read-only recall queries over the main database. Project scope (iOS): a project chat reads
 * same-project chats; an unassigned chat reads unassigned chats; documents are global unless
 * linked to a project, and linked documents are visible only inside that project.
 */
@Dao
internal interface RecallDao {
  @Query("SELECT id, projectId FROM conversations WHERE id = :conversationId")
  suspend fun conversationScope(conversationId: String): RecallConversationScopeRow?

  /** Newest-first keys of accessible completed user messages from other chats (no content). */
  @Query(
    """
    SELECT m.id AS id, m.createdAt AS createdAt FROM messages m
    INNER JOIN conversations c ON c.id = m.conversationId
    WHERE m.role = 'user' AND m.status = 'COMPLETE' AND m.conversationId != :excludedConversationId
      AND ((:projectId IS NULL AND c.projectId IS NULL) OR c.projectId = :projectId)
    ORDER BY m.createdAt DESC, m.id
    LIMIT :limit
    """
  )
  suspend fun messageKeys(excludedConversationId: String, projectId: String?, limit: Int): List<RecallMessageKey>

  @Query(
    """
    SELECT m.id AS id, m.conversationId AS conversationId, m.content AS content, m.createdAt AS createdAt,
      c.title AS conversationTitle
    FROM messages m INNER JOIN conversations c ON c.id = m.conversationId
    WHERE m.id IN (:ids) AND m.role = 'user' AND m.status = 'COMPLETE'
      AND m.conversationId != :excludedConversationId
      AND ((:projectId IS NULL AND c.projectId IS NULL) OR c.projectId = :projectId)
    """
  )
  suspend fun messages(ids: List<String>, excludedConversationId: String, projectId: String?): List<RecallMessageRow>

  @Query(
    """
    SELECT m.id AS id, m.conversationId AS conversationId, m.role AS role, m.status AS status,
      m.content AS content, c.projectId AS projectId
    FROM messages m INNER JOIN conversations c ON c.id = m.conversationId
    WHERE m.id IN (:ids)
    """
  )
  suspend fun messageValidation(ids: List<String>): List<MessageValidationRow>

  @Query(
    """
    SELECT id, title, updatedAt FROM documents
    WHERE isEnabled = 1 AND (projectId IS NULL OR projectId = :projectId)
    ORDER BY updatedAt DESC, id
    LIMIT :limit
    """
  )
  suspend fun accessibleDocuments(projectId: String?, limit: Int): List<RecallDocumentRow>

  @Query(
    """
    SELECT id, documentId, chunkIndex, content, pageNumber, isOcrDerived, createdAt FROM document_chunks
    WHERE documentId = :documentId AND chunkIndex > :afterChunkIndex
    ORDER BY chunkIndex
    LIMIT :limit
    """
  )
  suspend fun chunkPage(documentId: String, afterChunkIndex: Int, limit: Int): List<RecallChunkRow>

  @Query(
    """
    SELECT ch.id AS id, ch.documentId AS documentId, ch.content AS content, d.isEnabled AS isEnabled,
      d.projectId AS projectId
    FROM document_chunks ch INNER JOIN documents d ON d.id = ch.documentId
    WHERE ch.id IN (:ids)
    """
  )
  suspend fun chunkValidation(ids: List<String>): List<ChunkValidationRow>

  // region document index maintenance

  @Query("SELECT id FROM documents WHERE isEnabled = 1 ORDER BY updatedAt DESC, id LIMIT :limit OFFSET :offset")
  suspend fun enabledDocumentIds(offset: Int, limit: Int): List<String>

  @Query("SELECT id, title, updatedAt FROM documents WHERE id = :id AND isEnabled = 1")
  suspend fun enabledDocument(id: String): RecallDocumentRow?

  @Query("SELECT id FROM document_chunks WHERE id IN (:ids)")
  suspend fun existingChunkIds(ids: List<String>): List<String>

  @Query("SELECT id FROM messages WHERE id IN (:ids)")
  suspend fun existingMessageIds(ids: List<String>): List<String>

  // endregion
}

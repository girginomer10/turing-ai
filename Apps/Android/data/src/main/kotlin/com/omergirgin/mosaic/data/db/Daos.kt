package com.omergirgin.mosaic.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

@Dao
internal interface ProviderDao {
  @Query("SELECT * FROM providers ORDER BY displayName COLLATE NOCASE, createdAt")
  fun observeAll(): Flow<List<ProviderEntity>>

  @Query("SELECT * FROM providers WHERE id = :id")
  fun observe(id: String): Flow<ProviderEntity?>

  @Query("SELECT * FROM providers WHERE id = :id")
  suspend fun get(id: String): ProviderEntity?

  @Query("SELECT COUNT(*) FROM providers")
  suspend fun count(): Int

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insert(entity: ProviderEntity)

  @Upsert
  suspend fun upsert(entity: ProviderEntity)

  @Query("UPDATE providers SET isEnabled = :enabled, updatedAt = :now WHERE id = :id")
  suspend fun setEnabled(id: String, enabled: Boolean, now: Long): Int

  @Query("DELETE FROM providers WHERE id = :id")
  suspend fun delete(id: String): Int

  @Query("SELECT * FROM provider_models WHERE providerId = :providerId ORDER BY modelId")
  fun observeModels(providerId: String): Flow<List<ProviderModelEntity>>

  @Query("SELECT * FROM provider_models WHERE isEnabled = 1")
  fun observeEnabledModels(): Flow<List<ProviderModelEntity>>

  @Query("SELECT * FROM provider_models WHERE providerId = :providerId ORDER BY modelId")
  suspend fun models(providerId: String): List<ProviderModelEntity>

  @Query("SELECT * FROM provider_models WHERE providerId = :providerId AND modelId = :modelId")
  suspend fun model(providerId: String, modelId: String): ProviderModelEntity?

  @Query("DELETE FROM provider_models WHERE providerId = :providerId")
  suspend fun deleteModels(providerId: String)

  @Upsert
  suspend fun upsertModels(models: List<ProviderModelEntity>)

  /** Model choices are plain columns; clear them so no chat or project points at a dead provider. */
  @Query("UPDATE conversations SET modelProviderId = NULL, modelId = NULL WHERE modelProviderId = :providerId")
  suspend fun clearConversationChoices(providerId: String)

  @Query("UPDATE projects SET defaultProviderId = NULL, defaultModelId = NULL WHERE defaultProviderId = :providerId")
  suspend fun clearProjectChoices(providerId: String)
}

@Dao
internal interface ProjectDao {
  @Query("SELECT * FROM projects WHERE (:includeArchived OR isArchived = 0) ORDER BY name COLLATE NOCASE, createdAt")
  fun observeAll(includeArchived: Boolean): Flow<List<ProjectEntity>>

  @Query("SELECT * FROM projects WHERE id = :id")
  fun observe(id: String): Flow<ProjectEntity?>

  @Query("SELECT * FROM projects WHERE id = :id")
  suspend fun get(id: String): ProjectEntity?

  @Upsert
  suspend fun upsert(entity: ProjectEntity)

  @Query("UPDATE projects SET isArchived = :archived, updatedAt = :now WHERE id = :id")
  suspend fun setArchived(id: String, archived: Boolean, now: Long): Int

  @Query("DELETE FROM projects WHERE id = :id")
  suspend fun delete(id: String): Int
}

/** Sidebar row; previews are bounded in SQL so long messages are never materialized here. */
internal data class ConversationSummaryRow(
  val id: String,
  val title: String,
  val projectId: String?,
  val projectName: String?,
  val updatedAt: Long,
  val isArchived: Boolean,
  val draftPreview: String,
  val lastMessagePreview: String?,
  val hasMessages: Boolean,
)

@Dao
internal interface ConversationDao {
  /**
   * Only chats with messages or a nonblank draft are history entries. [pattern] is an escaped
   * LIKE pattern ('' = no search) matched against the title and every message's text.
   */
  @Query(
    """
    SELECT c.id AS id, c.title AS title, c.projectId AS projectId, p.name AS projectName,
      c.updatedAt AS updatedAt, c.isArchived AS isArchived,
      substr(c.draft, 1, 280) AS draftPreview,
      (SELECT substr(m.content, 1, 280) FROM messages m
        WHERE m.conversationId = c.id AND m.content != ''
        ORDER BY m.createdAt DESC, m.id DESC LIMIT 1) AS lastMessagePreview,
      EXISTS(SELECT 1 FROM messages m WHERE m.conversationId = c.id) AS hasMessages
    FROM conversations c
    LEFT JOIN projects p ON p.id = c.projectId
    WHERE c.isArchived = :archived
      AND (:projectId IS NULL OR c.projectId = :projectId)
      AND (EXISTS(SELECT 1 FROM messages m WHERE m.conversationId = c.id)
        OR length(trim(c.draft, ' ' || char(9) || char(10) || char(13))) > 0)
      AND (:pattern = '' OR c.title LIKE :pattern ESCAPE '\'
        OR EXISTS(SELECT 1 FROM messages m WHERE m.conversationId = c.id AND m.content LIKE :pattern ESCAPE '\'))
    ORDER BY c.updatedAt DESC, c.id
    """
  )
  fun observeSummaries(pattern: String, archived: Boolean, projectId: String?): Flow<List<ConversationSummaryRow>>

  @Query("SELECT * FROM conversations WHERE id = :id")
  fun observe(id: String): Flow<ConversationEntity?>

  @Query("SELECT * FROM conversations WHERE id = :id")
  suspend fun get(id: String): ConversationEntity?

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insert(entity: ConversationEntity)

  @Query("UPDATE conversations SET draft = :draft WHERE id = :id")
  suspend fun setDraft(id: String, draft: String): Int

  @Query("UPDATE conversations SET title = :title, updatedAt = :now WHERE id = :id")
  suspend fun setTitle(id: String, title: String, now: Long): Int

  @Query("UPDATE conversations SET modelProviderId = :providerId, modelId = :modelId WHERE id = :id")
  suspend fun setModel(id: String, providerId: String, modelId: String): Int

  @Query("UPDATE conversations SET systemPrompt = :prompt WHERE id = :id")
  suspend fun setSystemPrompt(id: String, prompt: String?): Int

  @Query("UPDATE conversations SET webSearchEnabled = :enabled WHERE id = :id")
  suspend fun setWebSearch(id: String, enabled: Boolean): Int

  @Query("UPDATE conversations SET projectId = :projectId, updatedAt = :now WHERE id = :id")
  suspend fun setProject(id: String, projectId: String?, now: Long): Int

  @Query("UPDATE conversations SET isArchived = :archived, updatedAt = :now WHERE id = :id")
  suspend fun setArchived(id: String, archived: Boolean, now: Long): Int

  @Query("UPDATE conversations SET updatedAt = :now WHERE id = :id")
  suspend fun touch(id: String, now: Long)

  /** Applied atomically with the user message insert on send. */
  @Query(
    """
    UPDATE conversations SET title = :title, modelProviderId = :providerId, modelId = :modelId,
      draft = '', updatedAt = :now WHERE id = :id
    """
  )
  suspend fun recordSend(id: String, title: String, providerId: String?, modelId: String?, now: Long): Int

  @Query("DELETE FROM conversations WHERE id = :id")
  suspend fun delete(id: String): Int

  /**
   * Removes blank chats left behind by earlier sessions (created but never used). Only rows last
   * touched before [before] are eligible so a chat opened in this process is never swept away.
   */
  @Query(
    """
    DELETE FROM conversations
    WHERE updatedAt < :before
      AND length(trim(draft, ' ' || char(9) || char(10) || char(13))) = 0
      AND systemPrompt IS NULL
      AND NOT EXISTS(SELECT 1 FROM messages m WHERE m.conversationId = conversations.id)
      AND NOT EXISTS(SELECT 1 FROM memory_facts f WHERE f.conversationId = conversations.id)
    """
  )
  suspend fun deleteAbandoned(before: Long): Int
}

/** Provider-facing history row (no provenance or payload columns). */
internal data class CanonicalMessageRow(
  val id: String,
  val role: String,
  val content: String,
  val createdAt: Long,
)

@Dao
internal interface MessageDao {
  @Query("SELECT * FROM messages WHERE conversationId = :conversationId ORDER BY createdAt, id")
  fun observe(conversationId: String): Flow<List<MessageEntity>>

  @Query("SELECT * FROM messages WHERE id = :id")
  suspend fun get(id: String): MessageEntity?

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insert(entity: MessageEntity)

  /**
   * Completed user/assistant rows that canonically precede (createdAt, id) bound, oldest first.
   * Failed, cancelled and streaming attempts are never sent back to a provider.
   */
  @Query(
    """
    SELECT id, role, content, createdAt FROM messages
    WHERE conversationId = :conversationId AND status = 'COMPLETE' AND role IN ('user', 'assistant')
      AND (createdAt < :beforeCreatedAt OR (createdAt = :beforeCreatedAt AND id < :beforeId))
    ORDER BY createdAt, id
    LIMIT :limit
    """
  )
  suspend fun canonicalBefore(
    conversationId: String,
    beforeCreatedAt: Long,
    beforeId: String,
    limit: Int,
  ): List<CanonicalMessageRow>

  @Query(
    """
    SELECT EXISTS(SELECT 1 FROM messages WHERE conversationId = :conversationId AND role = 'user'
      AND (createdAt > :createdAt OR (createdAt = :createdAt AND id > :id)))
    """
  )
  suspend fun hasUserMessageAfter(conversationId: String, createdAt: Long, id: String): Boolean

  @Query("SELECT EXISTS(SELECT 1 FROM messages WHERE conversationId = :conversationId)")
  suspend fun hasMessages(conversationId: String): Boolean

  /** IDs only (no content), e.g. to drop derived vectors after a chat is deleted. */
  @Query("SELECT id FROM messages WHERE conversationId = :conversationId")
  suspend fun idsIn(conversationId: String): List<String>

  @Query("UPDATE messages SET content = :content, updatedAt = :now WHERE id = :id")
  suspend fun checkpoint(id: String, content: String, now: Long)

  @Query("UPDATE messages SET citationsJson = :citationsJson WHERE id = :id")
  suspend fun setCitations(id: String, citationsJson: String?)

  @Query(
    """
    UPDATE messages SET status = :status, content = :content, errorMessage = :errorMessage,
      inputTokens = :inputTokens, outputTokens = :outputTokens, responseId = :responseId,
      citationsJson = :citationsJson, updatedAt = :now
    WHERE id = :id
    """
  )
  suspend fun finish(
    id: String,
    status: String,
    content: String,
    errorMessage: String?,
    inputTokens: Int?,
    outputTokens: Int?,
    responseId: String?,
    citationsJson: String?,
    now: Long,
  )

  /** Process-death repair: no generation can be running when the container is created. */
  @Query("UPDATE messages SET status = 'FAILED', errorMessage = :message, updatedAt = :now WHERE status = 'STREAMING'")
  suspend fun failInterrupted(message: String, now: Long): Int

  /** Keeps a retry chain intact when one attempt in the middle is deleted. */
  @Query("UPDATE messages SET retryOfMessageId = :replacement WHERE retryOfMessageId = :deletedId")
  suspend fun relinkRetries(deletedId: String, replacement: String?)

  @Query("DELETE FROM messages WHERE id = :id")
  suspend fun delete(id: String): Int
}

/** Planning projection: text payloads plus whether a photo exists, without photo bytes. */
internal data class AttachmentTextRow(
  val messageId: String,
  val kind: String,
  val fileName: String,
  val mimeType: String,
  val extractedText: String?,
  val hasImage: Boolean,
  val position: Int,
)

internal data class AttachmentImageRow(
  val messageId: String,
  val mimeType: String,
  val imageBase64: String,
  val position: Int,
)

@Dao
internal interface AttachmentDao {
  @Query("SELECT * FROM attachments WHERE conversationId = :conversationId ORDER BY messageId, position")
  fun observe(conversationId: String): Flow<List<AttachmentEntity>>

  @Query("SELECT * FROM attachments WHERE messageId = :messageId ORDER BY position")
  suspend fun forMessage(messageId: String): List<AttachmentEntity>

  @Query(
    """
    SELECT messageId, kind, fileName, mimeType, extractedText,
      (imageBase64 IS NOT NULL) AS hasImage, position
    FROM attachments WHERE conversationId = :conversationId ORDER BY messageId, position
    """
  )
  suspend fun textRows(conversationId: String): List<AttachmentTextRow>

  @Query(
    """
    SELECT messageId, mimeType, imageBase64, position FROM attachments
    WHERE messageId IN (:messageIds) AND imageBase64 IS NOT NULL ORDER BY messageId, position
    """
  )
  suspend fun images(messageIds: List<String>): List<AttachmentImageRow>

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insertAll(entities: List<AttachmentEntity>)
}

@Dao
internal interface ContextReceiptDao {
  @Query("SELECT * FROM context_receipts WHERE conversationId = :conversationId")
  fun observe(conversationId: String): Flow<List<ContextReceiptEntity>>

  @Upsert
  suspend fun upsert(entity: ContextReceiptEntity)
}

@Dao
internal interface MemoryDao {
  @Query("SELECT * FROM memory_facts ORDER BY updatedAt DESC, id")
  fun observeAll(): Flow<List<MemoryFactEntity>>

  @Query("SELECT * FROM memory_facts WHERE id = :id")
  suspend fun get(id: String): MemoryFactEntity?

  @Upsert
  suspend fun upsert(entity: MemoryFactEntity)

  @Query("DELETE FROM memory_facts WHERE id = :id")
  suspend fun delete(id: String): Int

  /** Facts visible to one chat: Everywhere + its project + itself. Bounded like iOS (4,096 rows). */
  @Query(
    """
    SELECT * FROM memory_facts
    WHERE isEnabled = 1 AND (
      scope = 'EVERYWHERE'
      OR (scope = 'PROJECT' AND projectId = :projectId)
      OR (scope = 'CONVERSATION' AND conversationId = :conversationId))
    ORDER BY updatedAt DESC, id
    LIMIT 4096
    """
  )
  suspend fun visibleTo(conversationId: String, projectId: String?): List<MemoryFactEntity>
}

@Dao
internal interface UsageDao {
  @Query("SELECT * FROM usage_records WHERE createdAt >= :since ORDER BY createdAt")
  fun observeSince(since: Long): Flow<List<UsageRecordEntity>>

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insert(entity: UsageRecordEntity)

  /** Completes a row recorded before its request started (e.g. smart memory ranking). */
  @Query("UPDATE usage_records SET inputTokens = :inputTokens, outputTokens = :outputTokens WHERE id = :id")
  suspend fun reportTokens(id: String, inputTokens: Int?, outputTokens: Int?)
}

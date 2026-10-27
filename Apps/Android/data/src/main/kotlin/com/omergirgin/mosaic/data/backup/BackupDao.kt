package com.omergirgin.mosaic.data.backup

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.omergirgin.mosaic.data.db.AttachmentEntity
import com.omergirgin.mosaic.data.db.CompactionArtifactEntity
import com.omergirgin.mosaic.data.db.CompactionHeadEntity
import com.omergirgin.mosaic.data.db.ConversationEntity
import com.omergirgin.mosaic.data.db.DocumentChunkEntity
import com.omergirgin.mosaic.data.db.DocumentEntity
import com.omergirgin.mosaic.data.db.MemoryEvidenceEntity
import com.omergirgin.mosaic.data.db.MemoryFactEntity
import com.omergirgin.mosaic.data.db.MemoryFormationAuditEntity
import com.omergirgin.mosaic.data.db.MemoryFormationJobEntity
import com.omergirgin.mosaic.data.db.MemoryRevisionEntity
import com.omergirgin.mosaic.data.db.MemoryTopicEntity
import com.omergirgin.mosaic.data.db.MessageEntity
import com.omergirgin.mosaic.data.db.ProjectEntity
import com.omergirgin.mosaic.data.db.ProviderEntity
import com.omergirgin.mosaic.data.db.ProviderModelEntity
import com.omergirgin.mosaic.data.db.ScheduledTaskEntity
import com.omergirgin.mosaic.data.db.UsageRecordEntity
import com.omergirgin.mosaic.data.branching.ConversationBranchEntity
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfileEntity
import com.omergirgin.mosaic.data.pricing.ModelPriceOverrideEntity

/** Light transcript row used to build export indexes without loading message text. */
internal data class MessageFactRow(
  val id: String,
  val conversationId: String,
  val role: String,
  val status: String,
  val createdAt: Long,
)

internal data class ConversationFactRow(val id: String, val projectId: String?)

internal data class CitationRow(val id: String, val conversationId: String, val citationsJson: String)

internal data class AttachmentFactRow(
  val id: String,
  val messageId: String,
  val conversationId: String,
  val kind: String,
  val mimeType: String,
  val hasImage: Boolean,
)

/**
 * Bulk access for portable backup and restore. Every growing table is read in bounded keyset
 * pages (`id > :after ORDER BY id`), and restore replaces logical records inside one transaction.
 */
@Dao
internal interface BackupDao {
  // region export reads

  @Query("SELECT * FROM providers ORDER BY id")
  suspend fun providers(): List<ProviderEntity>

  @Query("SELECT * FROM provider_models ORDER BY providerId, modelId")
  suspend fun providerModels(): List<ProviderModelEntity>

  @Query("SELECT * FROM projects ORDER BY id")
  suspend fun projects(): List<ProjectEntity>

  @Query("SELECT id, projectId FROM conversations ORDER BY id")
  suspend fun conversationFacts(): List<ConversationFactRow>

  @Query("SELECT * FROM conversations WHERE id > :after ORDER BY id LIMIT :limit")
  suspend fun conversationsAfter(after: String, limit: Int): List<ConversationEntity>

  @Query("SELECT id, conversationId, role, status, createdAt FROM messages WHERE id > :after ORDER BY id LIMIT :limit")
  suspend fun messageFactsAfter(after: String, limit: Int): List<MessageFactRow>

  @Query("SELECT * FROM messages WHERE id > :after ORDER BY id LIMIT :limit")
  suspend fun messagesAfter(after: String, limit: Int): List<MessageEntity>

  @Query("SELECT content FROM messages WHERE id = :id")
  suspend fun messageContent(id: String): String?

  @Query(
    """
    SELECT id, role, status, createdAt, conversationId, content FROM messages
    WHERE conversationId = :conversationId AND status = 'COMPLETE' AND role IN ('user', 'assistant')
    """
  )
  suspend fun canonicalMessages(conversationId: String): List<CanonicalRow>

  @Query("SELECT id, conversationId, citationsJson FROM messages WHERE citationsJson IS NOT NULL ORDER BY id")
  suspend fun citations(): List<CitationRow>

  @Query(
    """
    SELECT id, messageId, conversationId, kind, mimeType, (imageBase64 IS NOT NULL) AS hasImage
    FROM attachments ORDER BY id
    """
  )
  suspend fun attachmentFacts(): List<AttachmentFactRow>

  @Query("SELECT * FROM attachments WHERE id = :id")
  suspend fun attachment(id: String): AttachmentEntity?

  @Query("SELECT * FROM attachments WHERE messageId = :messageId ORDER BY position, id")
  suspend fun attachmentsFor(messageId: String): List<AttachmentEntity>

  @Query("SELECT * FROM memory_facts ORDER BY id")
  suspend fun memoryFacts(): List<MemoryFactEntity>

  @Query("SELECT * FROM usage_records WHERE id > :after ORDER BY id LIMIT :limit")
  suspend fun usageAfter(after: String, limit: Int): List<UsageRecordEntity>

  @Query("SELECT * FROM documents ORDER BY id")
  suspend fun documents(): List<DocumentEntity>

  @Query("SELECT * FROM document_chunks WHERE id > :after ORDER BY id LIMIT :limit")
  suspend fun chunksAfter(after: String, limit: Int): List<DocumentChunkEntity>

  @Query("SELECT * FROM compaction_artifacts ORDER BY id")
  suspend fun compactionArtifacts(): List<CompactionArtifactEntity>

  @Query("SELECT * FROM compaction_heads ORDER BY conversationId")
  suspend fun compactionHeads(): List<CompactionHeadEntity>

  @Query("SELECT * FROM scheduled_tasks ORDER BY id")
  suspend fun scheduledTasks(): List<ScheduledTaskEntity>

  @Query("SELECT * FROM embedding_profiles ORDER BY id")
  suspend fun embeddingProfiles(): List<EmbeddingProfileEntity>

  @Query("SELECT * FROM memory_topics ORDER BY id")
  suspend fun memoryTopics(): List<MemoryTopicEntity>

  @Query("SELECT * FROM memory_evidence ORDER BY id")
  suspend fun memoryEvidence(): List<MemoryEvidenceEntity>

  @Query("SELECT * FROM memory_revisions ORDER BY id")
  suspend fun memoryRevisions(): List<MemoryRevisionEntity>

  @Query("SELECT * FROM memory_formation_jobs ORDER BY id")
  suspend fun memoryJobs(): List<MemoryFormationJobEntity>

  @Query("SELECT * FROM memory_formation_audits ORDER BY id")
  suspend fun memoryAudits(): List<MemoryFormationAuditEntity>

  @Query("SELECT COUNT(*) FROM messages")
  suspend fun messageCount(): Int

  @Query("SELECT COUNT(*) FROM conversations")
  suspend fun conversationCount(): Int

  @Query("SELECT COUNT(*) FROM document_chunks")
  suspend fun chunkCount(): Int

  @Query("SELECT COUNT(*) FROM usage_records")
  suspend fun usageCount(): Int

  @Query("SELECT COUNT(*) FROM context_receipts")
  suspend fun receiptCount(): Int

  @Query("SELECT COUNT(*) FROM request_context_events")
  suspend fun requestEventCount(): Int

  @Query("SELECT COUNT(*) FROM scheduled_task_runs")
  suspend fun taskRunCount(): Int

  @Query("SELECT COUNT(*) FROM connection_activity")
  suspend fun connectionActivityCount(): Int

  @Query("SELECT * FROM model_price_overrides ORDER BY providerId, modelId")
  suspend fun priceOverrides(): List<ModelPriceOverrideEntity>

  @Query("SELECT * FROM conversation_branches ORDER BY id")
  suspend fun branches(): List<ConversationBranchEntity>

  // endregion

  // region restore

  @Query("DELETE FROM memory_formation_audits") suspend fun clearMemoryAudits()
  @Query("DELETE FROM memory_formation_jobs") suspend fun clearMemoryJobs()
  @Query("DELETE FROM memory_revisions") suspend fun clearMemoryRevisions()
  @Query("DELETE FROM memory_evidence") suspend fun clearMemoryEvidence()
  @Query("DELETE FROM memory_topics") suspend fun clearMemoryTopics()
  @Query("DELETE FROM request_context_events") suspend fun clearRequestEvents()
  @Query("DELETE FROM compaction_heads") suspend fun clearCompactionHeads()
  @Query("DELETE FROM compaction_artifacts") suspend fun clearCompactionArtifacts()
  @Query("DELETE FROM context_receipts") suspend fun clearReceipts()
  @Query("DELETE FROM attachments") suspend fun clearAttachments()
  @Query("DELETE FROM scheduled_task_runs") suspend fun clearTaskRuns()
  @Query("DELETE FROM scheduled_tasks") suspend fun clearTasks()
  @Query("DELETE FROM usage_records") suspend fun clearUsage()
  @Query("DELETE FROM memory_facts") suspend fun clearMemoryFacts()
  @Query("DELETE FROM document_chunks") suspend fun clearChunks()
  @Query("DELETE FROM documents") suspend fun clearDocuments()
  @Query("DELETE FROM embedding_profiles") suspend fun clearEmbeddingProfiles()
  @Query("DELETE FROM messages") suspend fun clearMessages()
  @Query("DELETE FROM conversations") suspend fun clearConversations()
  @Query("DELETE FROM projects") suspend fun clearProjects()
  @Query("DELETE FROM provider_models") suspend fun clearProviderModels()
  @Query("DELETE FROM providers") suspend fun clearProviders()
  @Query("DELETE FROM model_price_overrides") suspend fun clearPriceOverrides()
  @Query("DELETE FROM conversation_branches") suspend fun clearBranches()
  @Query("DELETE FROM connection_action_receipts") suspend fun clearConnectionReceipts()
  @Query("DELETE FROM connection_activity") suspend fun clearConnectionActivity()

  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertProviders(rows: List<ProviderEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertProviderModels(rows: List<ProviderModelEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertProjects(rows: List<ProjectEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertConversations(rows: List<ConversationEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertMessages(rows: List<MessageEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertAttachment(row: AttachmentEntity)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertMemoryFacts(rows: List<MemoryFactEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertUsage(rows: List<UsageRecordEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertDocuments(rows: List<DocumentEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertChunks(rows: List<DocumentChunkEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertCompactionArtifacts(rows: List<CompactionArtifactEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertCompactionHeads(rows: List<CompactionHeadEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertTasks(rows: List<ScheduledTaskEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertEmbeddingProfiles(rows: List<EmbeddingProfileEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertMemoryTopics(rows: List<MemoryTopicEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertMemoryEvidence(rows: List<MemoryEvidenceEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertMemoryRevisions(rows: List<MemoryRevisionEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertMemoryJobs(rows: List<MemoryFormationJobEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertMemoryAudits(rows: List<MemoryFormationAuditEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertPriceOverrides(rows: List<ModelPriceOverrideEntity>)
  @Insert(onConflict = OnConflictStrategy.ABORT) suspend fun insertBranches(rows: List<ConversationBranchEntity>)

  // endregion
}

/** Complete user/assistant row for compaction coverage checks. */
internal data class CanonicalRow(
  val id: String,
  val role: String,
  val status: String,
  val createdAt: Long,
  val conversationId: String,
  val content: String,
)

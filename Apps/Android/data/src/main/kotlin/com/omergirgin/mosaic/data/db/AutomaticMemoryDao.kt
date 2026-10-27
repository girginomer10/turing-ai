package com.omergirgin.mosaic.data.db

import androidx.room.Dao
import androidx.room.Embedded
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

/** Library row: a topic with the names needed for its scope label. */
internal data class MemoryTopicListRow(
  @Embedded val topic: MemoryTopicEntity,
  val projectName: String?,
  val conversationTitle: String?,
)

internal data class MemoryEvidenceDetailRow(
  @Embedded val evidence: MemoryEvidenceEntity,
  val conversationTitle: String?,
  /** False once the exact source message was deleted (the excerpt copy remains). */
  val sourceAvailable: Boolean,
)

internal data class MemoryAuditTotalsRow(
  val requests: Long,
  val inputTokens: Long,
  val outputTokens: Long,
)

/** Source message projection used to validate a formation boundary. */
internal data class MemorySourceMessageRow(
  val id: String,
  val conversationId: String,
  val role: String,
  val content: String,
  val status: String,
  val createdAt: Long,
)

@Dao
internal interface AutomaticMemoryDao {

  // region topics

  @Query("SELECT * FROM memory_topics WHERE id = :id")
  suspend fun topic(id: String): MemoryTopicEntity?

  @Query("SELECT * FROM memory_topics WHERE canonicalKey = :key LIMIT 1")
  suspend fun topicByKey(key: String): MemoryTopicEntity?

  @Query("SELECT * FROM memory_topics WHERE id IN (:ids)")
  suspend fun topics(ids: List<String>): List<MemoryTopicEntity>

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insertTopic(entity: MemoryTopicEntity)

  @Update
  suspend fun updateTopic(entity: MemoryTopicEntity): Int

  @Query("DELETE FROM memory_topics WHERE id IN (:ids)")
  suspend fun deleteTopics(ids: List<String>): Int

  @Query("SELECT * FROM memory_topics WHERE conversationId = :conversationId")
  suspend fun conversationScopedTopics(conversationId: String): List<MemoryTopicEntity>

  /* Exact audience partitions, each bounded before merging (iOS: query every partition before
   * applying result limits, so unrelated project volume cannot starve an eligible topic). */

  @Query(
    """
    SELECT * FROM memory_topics
    WHERE scope = 'global' AND conversationId IS NULL AND projectId IS NULL AND status = 'active' AND isEnabled = 1
    ORDER BY updatedAt DESC, id LIMIT :limit
    """
  )
  suspend fun activeGlobalTopicsByRecency(limit: Int): List<MemoryTopicEntity>

  @Query(
    """
    SELECT * FROM memory_topics
    WHERE scope = 'conversation' AND conversationId = :conversationId AND projectId IS NULL
      AND status = 'active' AND isEnabled = 1
    ORDER BY updatedAt DESC, id LIMIT :limit
    """
  )
  suspend fun activeConversationTopicsByRecency(conversationId: String, limit: Int): List<MemoryTopicEntity>

  @Query(
    """
    SELECT * FROM memory_topics
    WHERE scope = 'project' AND projectId = :projectId AND conversationId IS NULL AND status = 'active' AND isEnabled = 1
    ORDER BY updatedAt DESC, id LIMIT :limit
    """
  )
  suspend fun activeProjectTopicsByRecency(projectId: String, limit: Int): List<MemoryTopicEntity>

  @Query(
    """
    SELECT * FROM memory_topics
    WHERE scope = 'global' AND conversationId IS NULL AND projectId IS NULL AND status = 'active' AND isEnabled = 1
    ORDER BY importance DESC, updatedAt DESC, id LIMIT :limit
    """
  )
  suspend fun recallGlobalTopics(limit: Int): List<MemoryTopicEntity>

  @Query(
    """
    SELECT * FROM memory_topics
    WHERE scope = 'conversation' AND conversationId = :conversationId AND projectId IS NULL
      AND status = 'active' AND isEnabled = 1
    ORDER BY importance DESC, updatedAt DESC, id LIMIT :limit
    """
  )
  suspend fun recallConversationTopics(conversationId: String, limit: Int): List<MemoryTopicEntity>

  @Query(
    """
    SELECT * FROM memory_topics
    WHERE scope = 'project' AND projectId = :projectId AND conversationId IS NULL AND status = 'active' AND isEnabled = 1
    ORDER BY importance DESC, updatedAt DESC, id LIMIT :limit
    """
  )
  suspend fun recallProjectTopics(projectId: String, limit: Int): List<MemoryTopicEntity>

  @Query(
    """
    UPDATE memory_topics SET useCount = useCount + 1, lastUsedAt = :now
    WHERE id IN (:ids) AND status = 'active' AND isEnabled = 1 AND useCount < 2147483647
    """
  )
  suspend fun recordUse(ids: List<String>, now: Long): Int

  /** [pattern] is an escaped LIKE pattern ('' = everything). */
  @Query(
    """
    SELECT t.*, p.name AS projectName, c.title AS conversationTitle
    FROM memory_topics t
    LEFT JOIN projects p ON p.id = t.projectId
    LEFT JOIN conversations c ON c.id = t.conversationId
    WHERE (:pattern = '' OR t.title LIKE :pattern ESCAPE '\' OR t.content LIKE :pattern ESCAPE '\')
    ORDER BY t.updatedAt DESC, t.id
    LIMIT :limit
    """
  )
  fun observeTopicRows(pattern: String, limit: Int): Flow<List<MemoryTopicListRow>>

  @Query(
    """
    SELECT t.*, p.name AS projectName, c.title AS conversationTitle
    FROM memory_topics t
    LEFT JOIN projects p ON p.id = t.projectId
    LEFT JOIN conversations c ON c.id = t.conversationId
    WHERE t.id = :id
    """
  )
  fun observeTopicRow(id: String): Flow<MemoryTopicListRow?>

  // endregion

  // region evidence

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insertEvidence(entity: MemoryEvidenceEntity)

  @Query("SELECT EXISTS(SELECT 1 FROM memory_evidence WHERE evidenceKey = :key)")
  suspend fun evidenceKeyExists(key: String): Boolean

  @Query("SELECT * FROM memory_evidence WHERE conversationId = :conversationId")
  suspend fun evidenceForConversation(conversationId: String): List<MemoryEvidenceEntity>

  @Query("SELECT * FROM memory_evidence WHERE topicId IN (:topicIds)")
  suspend fun evidenceForTopics(topicIds: List<String>): List<MemoryEvidenceEntity>

  @Query("DELETE FROM memory_evidence WHERE id IN (:ids)")
  suspend fun deleteEvidence(ids: List<String>): Int

  @Query("SELECT DISTINCT sourceMessageId FROM memory_evidence WHERE sourceMessageId IN (:messageIds)")
  suspend fun consolidatedMessageIds(messageIds: List<String>): List<String>

  @Query(
    """
    SELECT e.*, c.title AS conversationTitle,
      EXISTS(SELECT 1 FROM messages m WHERE m.id = e.sourceMessageId) AS sourceAvailable
    FROM memory_evidence e
    LEFT JOIN conversations c ON c.id = e.conversationId
    WHERE e.topicId = :topicId
    ORDER BY e.createdAt DESC, e.id
    LIMIT :limit
    """
  )
  fun observeEvidenceRows(topicId: String, limit: Int): Flow<List<MemoryEvidenceDetailRow>>

  @Query("SELECT COUNT(*) FROM memory_evidence WHERE topicId = :topicId")
  fun observeEvidenceCount(topicId: String): Flow<Int>

  // endregion

  // region revisions

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insertRevision(entity: MemoryRevisionEntity)

  @Query("SELECT * FROM memory_revisions WHERE topicId = :topicId")
  suspend fun revisionsForTopic(topicId: String): List<MemoryRevisionEntity>

  @Query("UPDATE memory_revisions SET sourceEvidenceId = NULL WHERE sourceEvidenceId IN (:evidenceIds)")
  suspend fun detachEvidence(evidenceIds: List<String>): Int

  @Query("SELECT * FROM memory_revisions WHERE topicId = :topicId ORDER BY sequence DESC, id LIMIT :limit")
  fun observeRevisions(topicId: String, limit: Int): Flow<List<MemoryRevisionEntity>>

  @Query("SELECT COUNT(*) FROM memory_revisions WHERE topicId = :topicId")
  fun observeRevisionCount(topicId: String): Flow<Int>

  // endregion

  // region formation jobs and audits

  @Query("SELECT * FROM memory_formation_jobs WHERE id = :id")
  suspend fun job(id: String): MemoryFormationJobEntity?

  @Query("SELECT * FROM memory_formation_jobs WHERE jobKey = :key LIMIT 1")
  suspend fun jobByKey(key: String): MemoryFormationJobEntity?

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insertJob(entity: MemoryFormationJobEntity)

  @Update
  suspend fun updateJob(entity: MemoryFormationJobEntity): Int

  @Query("SELECT * FROM memory_formation_jobs WHERE status IN ('pending', 'generating') ORDER BY updatedAt, id LIMIT :limit")
  suspend fun unfinishedJobs(limit: Int): List<MemoryFormationJobEntity>

  @Query("SELECT * FROM memory_formation_jobs WHERE status = 'failed' ORDER BY updatedAt DESC, id DESC LIMIT 1")
  suspend fun newestFailedJob(): MemoryFormationJobEntity?

  /** Failed jobs strictly after the cursor and at or before the boundary, oldest first. */
  @Query(
    """
    SELECT * FROM memory_formation_jobs
    WHERE status = 'failed'
      AND (updatedAt > :afterUpdatedAt OR (updatedAt = :afterUpdatedAt AND id > :afterId))
      AND (updatedAt < :boundaryUpdatedAt OR (updatedAt = :boundaryUpdatedAt AND id <= :boundaryId))
    ORDER BY updatedAt, id
    LIMIT :limit
    """
  )
  suspend fun failedJobsPage(
    afterUpdatedAt: Long,
    afterId: String,
    boundaryUpdatedAt: Long,
    boundaryId: String,
    limit: Int,
  ): List<MemoryFormationJobEntity>

  @Query("SELECT * FROM memory_formation_audits WHERE jobId = :jobId")
  suspend fun audit(jobId: String): MemoryFormationAuditEntity?

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insertAudit(entity: MemoryFormationAuditEntity)

  @Update
  suspend fun updateAudit(entity: MemoryFormationAuditEntity): Int

  @Query("SELECT COUNT(*) FROM memory_formation_jobs WHERE status = 'failed'")
  fun observeFailedJobCount(): Flow<Int>

  @Query("SELECT COUNT(*) FROM memory_formation_jobs WHERE status IN ('pending', 'generating')")
  fun observeUnfinishedJobCount(): Flow<Int>

  @Query("SELECT * FROM memory_formation_audits ORDER BY finishedAt DESC, id DESC LIMIT :limit")
  fun observeRecentAudits(limit: Int): Flow<List<MemoryFormationAuditEntity>>

  @Query(
    """
    SELECT COALESCE(SUM(providerRequestCount), 0) AS requests,
      COALESCE(SUM(cumulativeInputTokenCount), 0) AS inputTokens,
      COALESCE(SUM(cumulativeOutputTokenCount), 0) AS outputTokens
    FROM memory_formation_audits
    """
  )
  fun observeAuditTotals(): Flow<MemoryAuditTotalsRow>

  // endregion

  // region source messages

  @Query("SELECT id, conversationId, role, content, status, createdAt FROM messages WHERE id = :id")
  suspend fun sourceMessage(id: String): MemorySourceMessageRow?

  /** The user turn a reply answered: the newest completed user row before the reply boundary. */
  @Query(
    """
    SELECT id FROM messages
    WHERE conversationId = :conversationId AND role = 'user' AND status = 'COMPLETE'
      AND (createdAt < :beforeCreatedAt OR (createdAt = :beforeCreatedAt AND id < :beforeId))
    ORDER BY createdAt DESC, id DESC
    LIMIT 1
    """
  )
  suspend fun lastUserMessageBefore(conversationId: String, beforeCreatedAt: Long, beforeId: String): String?

  // endregion
}

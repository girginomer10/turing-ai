package com.omergirgin.mosaic.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Upsert

/** Coverage-only projection so walking a long lineage never loads every summary's text. */
internal data class CompactionCoverageRow(
  val id: String,
  val conversationId: String,
  val coverageParentArtifactId: String?,
  val coverageDeltaJson: String,
  val coveredMessageCount: Int,
)

@Dao
internal interface CompactionDao {
  @Query("SELECT * FROM compaction_heads WHERE conversationId = :conversationId")
  suspend fun head(conversationId: String): CompactionHeadEntity?

  @Upsert
  suspend fun upsertHead(entity: CompactionHeadEntity)

  @Query("SELECT * FROM compaction_artifacts WHERE id = :id")
  suspend fun artifact(id: String): CompactionArtifactEntity?

  @Query(
    """
    SELECT id, conversationId, coverageParentArtifactId, coverageDeltaJson, coveredMessageCount
    FROM compaction_artifacts WHERE id = :id
    """
  )
  suspend fun coverage(id: String): CompactionCoverageRow?

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insertArtifact(entity: CompactionArtifactEntity)

  /** IGNORE + the unique (assistantMessageId, eventSequence) key makes appends idempotent. */
  @Insert(onConflict = OnConflictStrategy.IGNORE)
  suspend fun insertEvent(entity: RequestContextEventEntity): Long

  @Query("SELECT COALESCE(MAX(eventSequence), -1) FROM request_context_events WHERE assistantMessageId = :assistantMessageId")
  suspend fun lastEventSequence(assistantMessageId: String): Int

  @Query("SELECT EXISTS(SELECT 1 FROM request_context_events WHERE attemptId = :attemptId AND status != 'generating')")
  suspend fun hasTerminal(attemptId: String): Boolean

  /**
   * Newest `generating` events whose attempt never reached a terminal event. Bounded so launch
   * recovery never walks an unbounded audit history.
   */
  @Query(
    """
    SELECT * FROM request_context_events e
    WHERE e.status = 'generating'
      AND NOT EXISTS(SELECT 1 FROM request_context_events t
        WHERE t.attemptId = e.attemptId AND t.status != 'generating')
    ORDER BY e.createdAt DESC, e.id DESC
    LIMIT :limit
    """
  )
  suspend fun danglingGenerating(limit: Int): List<RequestContextEventEntity>
}

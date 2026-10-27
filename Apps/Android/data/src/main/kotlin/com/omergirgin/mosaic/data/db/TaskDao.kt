package com.omergirgin.mosaic.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
internal interface ScheduledTaskDao {
  @Query("SELECT * FROM scheduled_tasks ORDER BY createdAt, id")
  fun observeAll(): Flow<List<ScheduledTaskEntity>>

  @Query("SELECT * FROM scheduled_tasks WHERE id = :id")
  fun observe(id: String): Flow<ScheduledTaskEntity?>

  @Query("SELECT * FROM scheduled_tasks WHERE id = :id")
  suspend fun get(id: String): ScheduledTaskEntity?

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insert(entity: ScheduledTaskEntity)

  @Update
  suspend fun update(entity: ScheduledTaskEntity): Int

  @Query("DELETE FROM scheduled_tasks WHERE id = :id")
  suspend fun delete(id: String): Int

  /** Active tasks whose next run is due, oldest first (iOS sweep order). */
  @Query(
    """
    SELECT id FROM scheduled_tasks
    WHERE status = 'active' AND nextRunAt IS NOT NULL AND nextRunAt <= :now
    ORDER BY nextRunAt, id
    """
  )
  suspend fun dueIds(now: Long): List<String>

  @Query("SELECT MIN(nextRunAt) FROM scheduled_tasks WHERE status = 'active' AND nextRunAt IS NOT NULL")
  suspend fun earliestNextRun(): Long?

  @Query("UPDATE scheduled_tasks SET lastConversationId = :conversationId WHERE id = :id")
  suspend fun setLastConversation(id: String, conversationId: String?)

  // Runs ---------------------------------------------------------------------------------------

  @Query("SELECT * FROM scheduled_task_runs WHERE taskId = :taskId ORDER BY startedAt DESC, id LIMIT :limit")
  fun observeRuns(taskId: String, limit: Int): Flow<List<ScheduledTaskRunEntity>>

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insertRun(entity: ScheduledTaskRunEntity)

  @Query("SELECT EXISTS(SELECT 1 FROM scheduled_task_runs WHERE requestId = :requestId)")
  suspend fun hasRunForRequest(requestId: String): Boolean

  @Query("UPDATE scheduled_task_runs SET conversationId = :conversationId WHERE id = :id")
  suspend fun setRunConversation(id: String, conversationId: String?)

  @Query(
    """
    UPDATE scheduled_task_runs
    SET status = :status, finishedAt = :finishedAt, conversationId = :conversationId, errorMessage = :errorMessage
    WHERE id = :id
    """
  )
  suspend fun finishRun(id: String, status: String, finishedAt: Long, conversationId: String?, errorMessage: String?)

  /** Process-death repair: no run survives its process, so every running row is an orphan. */
  @Query("UPDATE scheduled_task_runs SET status = 'interrupted', finishedAt = :now, errorMessage = :message WHERE status = 'running'")
  suspend fun interruptOrphans(message: String, now: Long): Int

  @Query(
    """
    DELETE FROM scheduled_task_runs
    WHERE taskId = :taskId AND id NOT IN (
      SELECT id FROM scheduled_task_runs WHERE taskId = :taskId ORDER BY startedAt DESC, id LIMIT :keep
    )
    """
  )
  suspend fun pruneRuns(taskId: String, keep: Int)
}

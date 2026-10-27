package com.omergirgin.mosaic.data.db

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

/*
 * Scheduled prompts (iOS `ScheduledTaskRecord` + `ScheduledTaskModelRecord`, folded into one row).
 * Recurrence and status keep the iOS raw values so a portable backup can map them one-to-one.
 *
 * The exact provider/model choice and the project are plain columns without foreign keys: a
 * deleted provider, model or project must surface as a visible run error that asks for a new
 * choice, never silently switch the model or move the prompt into a different memory audience.
 */

@Entity(
  tableName = "scheduled_tasks",
  foreignKeys = [
    // Deleting the latest result chat only clears the link; the automation stays.
    ForeignKey(
      entity = ConversationEntity::class,
      parentColumns = ["id"],
      childColumns = ["lastConversationId"],
      onDelete = ForeignKey.SET_NULL,
    ),
  ],
  indices = [Index("status", "nextRunAt"), Index("lastConversationId")],
)
internal data class ScheduledTaskEntity(
  @PrimaryKey val id: String,
  val title: String,
  val prompt: String,
  /** `ScheduleRecurrence.rawValue`: once, daily, weekly. */
  val recurrence: String,
  /** iOS `ScheduledTaskStatus` raw value: active, paused, completed, failed. */
  val status: String,
  /** First allowed occurrence; its local time in [timeZoneId] is kept by every recurrence. */
  val scheduledAt: Long,
  /** Weekly only: ISO weekday bits (Monday = bit 0). 0 = the weekday of [scheduledAt] (iOS). */
  val weekdayMask: Int,
  /** IANA identifier saved with the schedule; recurrences stay anchored to it. */
  val timeZoneId: String,
  val providerId: String?,
  val modelId: String?,
  val projectId: String?,
  val nextRunAt: Long?,
  val lastRunAt: Long?,
  val lastError: String?,
  val lastConversationId: String?,
  val createdAt: Long,
  val updatedAt: Long,
)

/**
 * One execution attempt. The row is written in the same transaction as the task's claim, before
 * any provider request, so an interrupted run is always visible and never silently retried.
 */
@Entity(
  tableName = "scheduled_task_runs",
  foreignKeys = [
    ForeignKey(
      entity = ScheduledTaskEntity::class,
      parentColumns = ["id"],
      childColumns = ["taskId"],
      onDelete = ForeignKey.CASCADE,
    ),
    ForeignKey(
      entity = ConversationEntity::class,
      parentColumns = ["id"],
      childColumns = ["conversationId"],
      onDelete = ForeignKey.SET_NULL,
    ),
  ],
  indices = [
    Index("taskId", "startedAt"),
    Index("status"),
    Index("conversationId"),
    Index(value = ["requestId"], unique = true),
  ],
)
internal data class ScheduledTaskRunEntity(
  @PrimaryKey val id: String,
  val taskId: String,
  /**
   * The Run now request that claimed this run. WorkManager re-executes a worker whose process
   * died; a request that already claimed a run must never send a second paid request.
   */
  val requestId: String?,
  /** `TaskRunTrigger.rawValue`: scheduled, manual. */
  val trigger: String,
  /** `TaskRunStatus.rawValue`: running, succeeded, failed, interrupted. */
  val status: String,
  val startedAt: Long,
  val finishedAt: Long?,
  val conversationId: String?,
  val errorMessage: String?,
)

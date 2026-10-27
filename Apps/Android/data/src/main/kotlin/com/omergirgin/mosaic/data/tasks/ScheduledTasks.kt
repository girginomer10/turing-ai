package com.omergirgin.mosaic.data.tasks

import com.omergirgin.mosaic.core.scheduling.ScheduleRecurrence
import com.omergirgin.mosaic.core.scheduling.TaskSchedule
import com.omergirgin.mosaic.data.model.ModelChoice
import java.time.DayOfWeek
import kotlinx.coroutines.flow.Flow

/** Raw values match iOS `ScheduledTaskStatus`. */
enum class ScheduledTaskStatus(val rawValue: String) {
  ACTIVE("active"),
  PAUSED("paused"),
  /** A one-time prompt that ran successfully. */
  COMPLETED("completed"),
  /** Needs attention: a one-time run failed or was interrupted, and is never retried automatically. */
  FAILED("failed");

  companion object {
    fun fromRaw(raw: String): ScheduledTaskStatus = entries.firstOrNull { it.rawValue == raw } ?: PAUSED
  }
}

enum class TaskRunTrigger(val rawValue: String) {
  SCHEDULED("scheduled"),
  MANUAL("manual");

  companion object {
    fun fromRaw(raw: String): TaskRunTrigger = entries.firstOrNull { it.rawValue == raw } ?: SCHEDULED
  }
}

enum class TaskRunStatus(val rawValue: String) {
  RUNNING("running"),
  SUCCEEDED("succeeded"),
  FAILED("failed"),
  /** The process ended after the run was claimed; the request may already have been billed. */
  INTERRUPTED("interrupted");

  companion object {
    fun fromRaw(raw: String): TaskRunStatus = entries.firstOrNull { it.rawValue == raw } ?: FAILED
  }
}

/** What a task is doing right now in this process. */
enum class TaskActivity { QUEUED, RUNNING }

/** A scheduled prompt that runs on this device with one exact provider/model choice. */
data class ScheduledTask(
  val id: String,
  val title: String,
  val prompt: String,
  val schedule: TaskSchedule,
  /** null only for a damaged or imported row; such a task fails visibly until a model is chosen. */
  val model: ModelChoice?,
  /** Result chats are created in this project (its instructions and memory boundary apply). */
  val projectId: String?,
  val status: ScheduledTaskStatus,
  val nextRunAt: Long?,
  val lastRunAt: Long?,
  val lastError: String?,
  /** Latest result chat; null when none exists or it was deleted. */
  val lastConversationId: String?,
  val createdAt: Long,
  val updatedAt: Long,
) {
  val recurrence: ScheduleRecurrence get() = schedule.recurrence
}

/**
 * Create ([id] null) or update a task. Text, model and project edits keep the execution state;
 * only a schedule change creates a new next occurrence (iOS `updateSchedule`), re-anchored to
 * [timeZoneId], without un-pausing a paused task.
 */
data class ScheduledTaskDraft(
  val id: String?,
  val title: String,
  val prompt: String,
  val recurrence: ScheduleRecurrence,
  /** First allowed occurrence (one-time: the run time). */
  val startAt: Long,
  /** Weekly only; must not be empty for weekly schedules. */
  val weekdays: Set<DayOfWeek>,
  /** Normally the device zone at edit time; kept as-is when the schedule did not change. */
  val timeZoneId: String,
  val model: ModelChoice,
  val projectId: String?,
)

data class ScheduledTaskRun(
  val id: String,
  val taskId: String,
  val trigger: TaskRunTrigger,
  val status: TaskRunStatus,
  val startedAt: Long,
  val finishedAt: Long?,
  /** Result chat; null when the run failed before one was created, or the chat was deleted. */
  val conversationId: String?,
  val errorMessage: String?,
)

/**
 * Scheduled prompts ("Automations"). Runs happen on this device only: WorkManager executes due
 * prompts in the background when Android allows it, and a 30-second sweep runs them while the
 * app is in the foreground. Every run reserves the task, persists an execution claim before the
 * provider request, and goes through the normal chat pipeline in a new chat.
 */
interface ScheduledTaskRepository {
  fun observeTasks(): Flow<List<ScheduledTask>>
  fun observeTask(id: String): Flow<ScheduledTask?>
  fun observeRuns(taskId: String, limit: Int = 10): Flow<List<ScheduledTaskRun>>

  /** Queued (Run now requested) and running tasks, by task ID. */
  val activity: Flow<Map<String, TaskActivity>>

  /** Validates title, prompt, schedule, exact enabled model and project. */
  suspend fun save(draft: ScheduledTaskDraft): ScheduledTask

  /**
   * Pause an active task, or resume a paused/failed one at its next occurrence. A one-time task
   * whose time has passed is not resumed (that would run it immediately); edit its time or use
   * Run now instead.
   */
  suspend fun setPaused(id: String, paused: Boolean)

  /** Existing result chats stay in history. Blocked while the task is running. */
  suspend fun delete(id: String)

  /**
   * Synchronously reserves an immediate run (expedited background work, so it can finish after
   * the app is left). Returns false when the task is already queued or running. A paused task
   * stays paused afterwards.
   */
  fun runNow(id: String): Boolean

  /** Starts/stops the foreground sweep (every 30 s while the app is visible). */
  fun setAppInForeground(foreground: Boolean)
}

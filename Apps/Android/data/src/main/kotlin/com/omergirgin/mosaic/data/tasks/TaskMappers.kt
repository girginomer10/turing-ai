package com.omergirgin.mosaic.data.tasks

import com.omergirgin.mosaic.core.scheduling.ScheduleCalculator
import com.omergirgin.mosaic.core.scheduling.ScheduleRecurrence
import com.omergirgin.mosaic.core.scheduling.TaskSchedule
import com.omergirgin.mosaic.data.db.ScheduledTaskEntity
import com.omergirgin.mosaic.data.db.ScheduledTaskRunEntity
import com.omergirgin.mosaic.data.db.choiceOf

internal fun ScheduledTaskEntity.schedule(): TaskSchedule {
  val recurrence = ScheduleRecurrence.fromRaw(recurrence)
  return TaskSchedule(
    recurrence = recurrence,
    startAt = scheduledAt,
    timeZoneId = timeZoneId,
    weekdays = if (recurrence == ScheduleRecurrence.WEEKLY) ScheduleCalculator.weekdaysOf(weekdayMask) else emptySet(),
  )
}

internal val ScheduledTaskEntity.statusValue: ScheduledTaskStatus get() = ScheduledTaskStatus.fromRaw(status)

/** Everything that defines occurrences; a change means the user re-scheduled the task. */
internal fun ScheduledTaskEntity.scheduleKey(): List<Any> = listOf(recurrence, scheduledAt, weekdayMask, timeZoneId)

internal fun ScheduledTaskEntity.toModel() = ScheduledTask(
  id = id,
  title = title,
  prompt = prompt,
  schedule = schedule(),
  model = choiceOf(providerId, modelId),
  projectId = projectId,
  status = statusValue,
  nextRunAt = nextRunAt,
  lastRunAt = lastRunAt,
  lastError = lastError,
  lastConversationId = lastConversationId,
  createdAt = createdAt,
  updatedAt = updatedAt,
)

internal fun ScheduledTaskRunEntity.toModel() = ScheduledTaskRun(
  id = id,
  taskId = taskId,
  trigger = TaskRunTrigger.fromRaw(trigger),
  status = TaskRunStatus.fromRaw(status),
  startedAt = startedAt,
  finishedAt = finishedAt,
  conversationId = conversationId,
  errorMessage = errorMessage,
)

/** iOS `normalizedTitle(_, fallback: "Scheduled task")`. */
internal fun displayTaskTitle(title: String): String = title.trim().ifEmpty { "Scheduled prompt" }

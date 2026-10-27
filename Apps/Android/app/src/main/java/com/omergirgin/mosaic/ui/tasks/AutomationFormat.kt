package com.omergirgin.mosaic.ui.tasks

import android.content.Context
import android.text.format.DateFormat
import android.text.format.DateUtils
import com.omergirgin.mosaic.core.scheduling.ScheduleCalculator
import com.omergirgin.mosaic.core.scheduling.ScheduleRecurrence
import com.omergirgin.mosaic.core.scheduling.TaskSchedule
import com.omergirgin.mosaic.data.model.ModelChoice
import com.omergirgin.mosaic.data.model.ModelOption
import com.omergirgin.mosaic.data.tasks.ScheduledTask
import com.omergirgin.mosaic.data.tasks.ScheduledTaskStatus
import com.omergirgin.mosaic.data.tasks.TaskActivity
import java.time.DayOfWeek
import java.time.ZoneId
import java.time.format.TextStyle
import java.time.temporal.WeekFields
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** Weekdays in the user's locale order (Monday or Sunday first). */
internal fun localeWeekdays(locale: Locale = Locale.getDefault()): List<DayOfWeek> {
  val first = WeekFields.of(locale).firstDayOfWeek
  return (0L until 7L).map { first.plus(it) }
}

internal fun DayOfWeek.shortLabel(locale: Locale = Locale.getDefault()): String = getDisplayName(TextStyle.SHORT, locale)

internal fun deviceZoneId(): String = ZoneId.systemDefault().id

/** Time of day of the schedule in its own (stored) time zone, in the user's 12/24-hour format. */
internal fun scheduleTimeLabel(context: Context, schedule: TaskSchedule): String =
  DateFormat.getTimeFormat(context)
    .apply { timeZone = TimeZone.getTimeZone(ScheduleCalculator.zoneOf(schedule.timeZoneId)) }
    .format(Date(schedule.startAt))

/** "Daily at 08:00", "Mon, Wed and Fri at 08:00", "Once on Oct 9, 2026 at 08:00". */
internal fun scheduleSummary(context: Context, schedule: TaskSchedule): String {
  val time = scheduleTimeLabel(context, schedule)
  val summary = when (schedule.recurrence) {
    ScheduleRecurrence.ONCE -> {
      val date = DateFormat.getMediumDateFormat(context)
        .apply { timeZone = TimeZone.getTimeZone(ScheduleCalculator.zoneOf(schedule.timeZoneId)) }
        .format(Date(schedule.startAt))
      "Once on $date at $time"
    }
    ScheduleRecurrence.DAILY -> "Daily at $time"
    ScheduleRecurrence.WEEKLY -> {
      val days = ScheduleCalculator.runDays(schedule)
      val ordered = localeWeekdays().filter { it in days }
      val label = when {
        ordered.size == 7 -> "Every day"
        ordered.size == 5 && DayOfWeek.SATURDAY !in days && DayOfWeek.SUNDAY !in days -> "Weekdays"
        else -> "Every " + joinWithAnd(ordered.map { it.shortLabel() })
      }
      "$label at $time"
    }
  }
  val zone = ScheduleCalculator.zoneOf(schedule.timeZoneId).id
  return if (zone == deviceZoneId()) summary else "$summary ($zone time)"
}

/** Absolute date and time on this device's clock, e.g. "Thu, Oct 10, 8:00 AM". */
internal fun deviceDateTime(context: Context, millis: Long): String =
  DateUtils.formatDateTime(
    context,
    millis,
    DateUtils.FORMAT_SHOW_WEEKDAY or DateUtils.FORMAT_ABBREV_WEEKDAY or DateUtils.FORMAT_SHOW_DATE or
      DateUtils.FORMAT_ABBREV_MONTH or DateUtils.FORMAT_SHOW_TIME,
  )

internal fun statusLabel(task: ScheduledTask, activity: TaskActivity?): String = when (activity) {
  TaskActivity.RUNNING -> "Running"
  TaskActivity.QUEUED -> "Starting"
  null -> when (task.status) {
    ScheduledTaskStatus.ACTIVE -> "Active"
    ScheduledTaskStatus.PAUSED -> "Paused"
    ScheduledTaskStatus.COMPLETED -> "Completed"
    ScheduledTaskStatus.FAILED -> "Needs attention"
  }
}

internal fun modelLabel(choice: ModelChoice?, options: List<ModelOption>): String {
  if (choice == null) return "No model chosen"
  val option = options.firstOrNull { it.choice == choice } ?: return "${choice.modelId} · unavailable"
  return "${option.modelId} · ${option.providerName}"
}

/** A one-time task whose time has passed cannot be resumed; it needs a new time or Run now. */
internal fun ScheduledTask.canResume(now: Long = System.currentTimeMillis()): Boolean = when (status) {
  ScheduledTaskStatus.PAUSED, ScheduledTaskStatus.FAILED ->
    recurrence != ScheduleRecurrence.ONCE || schedule.startAt > now
  else -> false
}

private fun joinWithAnd(parts: List<String>): String = when (parts.size) {
  0 -> ""
  1 -> parts[0]
  else -> parts.dropLast(1).joinToString(", ") + " and " + parts.last()
}

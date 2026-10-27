package com.omergirgin.mosaic.core.scheduling

import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime

/** Raw values match iOS `ScheduleRecurrence` so portable backups stay interchangeable. */
enum class ScheduleRecurrence(val rawValue: String) {
  ONCE("once"),
  DAILY("daily"),
  WEEKLY("weekly");

  companion object {
    fun fromRaw(raw: String): ScheduleRecurrence = entries.firstOrNull { it.rawValue == raw } ?: ONCE
  }
}

/**
 * One task's schedule. [startAt] is the first allowed occurrence; its local wall-clock time in
 * [timeZoneId] is the time every recurring occurrence keeps, so a daily 08:00 prompt stays at
 * 08:00 local time across DST changes and device time-zone changes until the task is edited.
 *
 * [weekdays] applies to weekly schedules only. Empty means the weekday of [startAt], which is
 * exactly the iOS representation (one weekday derived from the start date).
 */
data class TaskSchedule(
  val recurrence: ScheduleRecurrence,
  val startAt: Long,
  val timeZoneId: String,
  val weekdays: Set<DayOfWeek> = emptySet(),
)

/**
 * Port of iOS `ScheduleCalculator` (occurrences strictly after a reference instant, local wall
 * time preserved) with the same DST policies as Foundation's `.nextTime` / `.first`:
 * a wall time skipped by a spring-forward gap runs at the first instant after the gap, and a
 * wall time repeated by a fall-back overlap runs at its first occurrence only.
 */
object ScheduleCalculator {

  /** The first occurrence strictly after [afterMillis], or null when none remains (one-time). */
  fun nextOccurrence(schedule: TaskSchedule, afterMillis: Long): Long? {
    if (schedule.recurrence == ScheduleRecurrence.ONCE) {
      return schedule.startAt.takeIf { it > afterMillis }
    }
    val zone = zoneOf(schedule.timeZoneId)
    val start = Instant.ofEpochMilli(schedule.startAt)
    val after = Instant.ofEpochMilli(afterMillis)
    val startLocal = LocalDateTime.ofInstant(start, zone)
    val time = startLocal.toLocalTime()
    val days = allowedDays(schedule, startLocal.dayOfWeek)
    // One day earlier than the reference date: a zone offset can move the next match across midnight.
    var date = maxOf(startLocal.toLocalDate(), LocalDateTime.ofInstant(after, zone).toLocalDate().minusDays(1))
    repeat(MAX_SCAN_DAYS) {
      if (date.dayOfWeek in days) {
        val candidate = resolve(date.atTime(time), zone)
        if (candidate.isAfter(after) && !candidate.isBefore(start)) return candidate.toEpochMilli()
      }
      date = date.plusDays(1)
    }
    return null
  }

  /**
   * iOS `ForegroundTaskRunner.nextRunDate`: after a claimed or finished run. A one-time task has
   * no further run once it succeeded (or once its time has passed); recurring tasks continue at
   * the next occurrence after the attempt, even after a failure.
   */
  fun nextRunAfterAttempt(schedule: TaskSchedule, attemptedAt: Long, succeeded: Boolean): Long? {
    if (schedule.recurrence == ScheduleRecurrence.ONCE) {
      if (succeeded) return null
      return schedule.startAt.takeIf { it > attemptedAt }
    }
    return nextOccurrence(schedule, attemptedAt)
  }

  /** Next run for a newly saved or resumed task: a one-time task keeps its exact time. */
  fun initialNextRun(schedule: TaskSchedule, now: Long): Long? =
    if (schedule.recurrence == ScheduleRecurrence.ONCE) schedule.startAt else nextOccurrence(schedule, now)

  /** The instant of [date] at [time] in [timeZoneId], with the same DST policies as occurrences. */
  fun instantOf(date: LocalDate, time: LocalTime, timeZoneId: String): Long =
    resolve(date.atTime(time), zoneOf(timeZoneId)).toEpochMilli()

  /** Weekdays a schedule runs on (all days for daily, the start weekday for one-time). */
  fun runDays(schedule: TaskSchedule): Set<DayOfWeek> {
    val startDay = LocalDateTime.ofInstant(Instant.ofEpochMilli(schedule.startAt), zoneOf(schedule.timeZoneId)).dayOfWeek
    return allowedDays(schedule, startDay)
  }

  /** A stored IANA identifier, or the device zone when the identifier is unknown on this device. */
  fun zoneOf(timeZoneId: String): ZoneId =
    runCatching { ZoneId.of(timeZoneId) }.getOrElse { ZoneId.systemDefault() }

  /** Weekday set encoded as ISO bits (Monday = bit 0 ... Sunday = bit 6) for storage. */
  fun weekdayMask(days: Set<DayOfWeek>): Int = days.fold(0) { mask, day -> mask or (1 shl (day.value - 1)) }

  fun weekdaysOf(mask: Int): Set<DayOfWeek> =
    DayOfWeek.entries.filterTo(LinkedHashSet()) { mask and (1 shl (it.value - 1)) != 0 }

  private fun allowedDays(schedule: TaskSchedule, startDay: DayOfWeek): Set<DayOfWeek> = when (schedule.recurrence) {
    ScheduleRecurrence.DAILY -> DayOfWeek.entries.toSet()
    ScheduleRecurrence.WEEKLY -> schedule.weekdays.ifEmpty { setOf(startDay) }
    ScheduleRecurrence.ONCE -> setOf(startDay)
  }

  private fun resolve(local: LocalDateTime, zone: ZoneId): Instant {
    val transition = zone.rules.getTransition(local)
    if (transition != null && transition.isGap) return transition.instant
    // A null preferred offset selects the earlier offset in an overlap: the first occurrence.
    return ZonedDateTime.ofLocal(local, zone, null).toInstant()
  }

  /** Weekly matches need at most 8 days from the scan start; the margin covers offset shifts. */
  private const val MAX_SCAN_DAYS = 16
}

import Foundation

extension ScheduledTaskRecord {
  /// Text/provider edits preserve execution state. Only an explicit schedule change
  /// creates a new occurrence, without unpausing a task the user has paused.
  func updateSchedule(
    recurrence: ScheduleRecurrence,
    scheduledAt: Date,
    timeZone: TimeZone = .current,
    now: Date = .now
  ) {
    guard self.recurrence != recurrence || self.scheduledAt != scheduledAt else { return }
    self.recurrence = recurrence
    self.scheduledAt = scheduledAt
    timeZoneIdentifier = timeZone.identifier
    var calendar = Calendar.current
    calendar.timeZone = timeZone
    nextRunAt =
      recurrence == .once
      ? scheduledAt
      : ScheduleCalculator.nextDate(
        after: now, startingAt: scheduledAt, recurrence: recurrence, calendar: calendar
      )
    if status == .completed || status == .failed {
      status = .active
      lastError = nil
    }
  }
}

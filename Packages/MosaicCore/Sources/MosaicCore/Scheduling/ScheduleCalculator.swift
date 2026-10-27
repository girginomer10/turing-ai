import Foundation

/// Computes occurrences strictly after a reference date while preserving local wall-clock time.
public struct ScheduleCalculator: Sendable {
  public init() {}

  public static func nextDate(
    after referenceDate: Date,
    startingAt startDate: Date,
    recurrence: ScheduleRecurrence,
    calendar: Calendar = .current
  ) -> Date? {
    ScheduleCalculator().nextDate(
      after: referenceDate,
      startingAt: startDate,
      recurrence: recurrence,
      calendar: calendar
    )
  }

  public func nextDate(
    after referenceDate: Date,
    startingAt startDate: Date,
    recurrence: ScheduleRecurrence,
    calendar: Calendar = .current
  ) -> Date? {
    if startDate > referenceDate {
      return startDate
    }

    switch recurrence {
    case .once:
      return nil
    case .daily:
      let components = calendar.dateComponents(
        [.hour, .minute, .second, .nanosecond],
        from: startDate
      )
      return calendar.nextDate(
        after: referenceDate,
        matching: components,
        matchingPolicy: .nextTime,
        repeatedTimePolicy: .first,
        direction: .forward
      )
    case .weekly:
      let components = calendar.dateComponents(
        [.weekday, .hour, .minute, .second, .nanosecond],
        from: startDate
      )
      return calendar.nextDate(
        after: referenceDate,
        matching: components,
        matchingPolicy: .nextTime,
        repeatedTimePolicy: .first,
        direction: .forward
      )
    }
  }

  public func nextDate(
    after referenceDate: Date,
    for task: ScheduledTaskRecord,
    calendar: Calendar = .current
  ) -> Date? {
    nextDate(
      after: referenceDate,
      startingAt: task.scheduledAt,
      recurrence: task.recurrence,
      calendar: calendar
    )
  }
}

import Foundation
import XCTest

@testable import MosaicCore

final class ScheduleCalculatorTests: XCTestCase {
  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  func testOnceReturnsStartOnlyWhenItIsStillInTheFuture() throws {
    let calculator = ScheduleCalculator()
    let start = try date(2026, 8, 28, 9, 30)
    let beforeStart = try date(2026, 8, 27, 12, 0)

    XCTAssertEqual(
      calculator.nextDate(
        after: beforeStart,
        startingAt: start,
        recurrence: .once,
        calendar: utcCalendar
      ),
      start
    )
    XCTAssertNil(
      calculator.nextDate(
        after: start,
        startingAt: start,
        recurrence: .once,
        calendar: utcCalendar
      )
    )
  }

  func testDailyReturnsNextMatchingWallClockTime() throws {
    let calculator = ScheduleCalculator()
    let start = try date(2026, 8, 27, 9, 30)
    let expected = try date(2026, 8, 28, 9, 30)

    XCTAssertEqual(
      calculator.nextDate(
        after: start,
        startingAt: start,
        recurrence: .daily,
        calendar: utcCalendar
      ),
      expected
    )
  }

  func testWeeklyReturnsSameWeekdayAndTime() throws {
    let calculator = ScheduleCalculator()
    let start = try date(2026, 8, 24, 18, 15)
    let reference = try date(2026, 8, 27, 12, 0)
    let expected = try date(2026, 8, 31, 18, 15)

    XCTAssertEqual(
      calculator.nextDate(
        after: reference,
        startingAt: start,
        recurrence: .weekly,
        calendar: utcCalendar
      ),
      expected
    )
  }

  func testDailyPreservesLocalTimeAcrossDaylightSavingTransition() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let start = try date(2026, 3, 7, 9, 0, calendar: calendar)
    let reference = try date(2026, 3, 7, 10, 0, calendar: calendar)
    let expected = try date(2026, 3, 8, 9, 0, calendar: calendar)

    XCTAssertEqual(
      ScheduleCalculator().nextDate(
        after: reference,
        startingAt: start,
        recurrence: .daily,
        calendar: calendar
      ),
      expected
    )
  }

  private func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int,
    calendar: Calendar? = nil
  ) throws -> Date {
    let calendar = calendar ?? utcCalendar
    return try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: year,
          month: month,
          day: day,
          hour: hour,
          minute: minute
        )
      )
    )
  }
}

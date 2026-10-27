import Foundation
import Testing

@testable import MosaicCore

@Suite("Scheduled task editing")
@MainActor
struct ScheduledTaskEditingTests {
  @Test(arguments: [ScheduledTaskStatus.completed, .failed, .paused])
  func textOnlyEditPreservesExecutionState(status: ScheduledTaskStatus) {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let task = ScheduledTaskRecord(title: "Before", prompt: "Original", scheduledAt: date)
    task.status = status
    task.nextRunAt = nil
    task.timeZoneIdentifier = "Europe/Istanbul"
    task.lastError = status == .failed ? "Previous failure" : nil
    task.title = "After"
    task.prompt = "Revised prompt"
    task.updateSchedule(
      recurrence: task.recurrence, scheduledAt: date, timeZone: TimeZone(secondsFromGMT: 0)!)
    #expect(task.status == status)
    #expect(task.nextRunAt == nil)
    #expect(task.timeZoneIdentifier == "Europe/Istanbul")
    #expect(task.lastError == (status == .failed ? "Previous failure" : nil))
  }

  @Test(arguments: [ScheduledTaskStatus.completed, .failed, .paused])
  func explicitNewDateCreatesOccurrenceWithoutUnpausing(status: ScheduledTaskStatus) {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let next = date.addingTimeInterval(86_400)
    let task = ScheduledTaskRecord(title: "Task", prompt: "Prompt", scheduledAt: date)
    task.status = status
    task.nextRunAt = nil
    task.updateSchedule(recurrence: .once, scheduledAt: next)
    #expect(task.nextRunAt == next)
    #expect(task.status == (status == .paused ? .paused : .active))
  }
}

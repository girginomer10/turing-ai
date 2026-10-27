import Foundation
@preconcurrency import UserNotifications
import XCTest

@testable import MosaicCore

final class LocalNotificationServiceTests: XCTestCase {
  func testFutureActiveTaskSchedulesDeterministicCalendarReminderWithoutPrompting() async throws {
    let center = RecordingNotificationCenter(authorizationState: .authorized)
    let service = LocalNotificationService(notificationCenterClient: center)
    let now = Date.now
    let nextRunAt = now.addingTimeInterval(3_600)
    let taskID = UUID()
    let schedule = reminder(
      taskID: taskID,
      title: "Morning briefing",
      nextRunAt: nextRunAt,
      timeZoneIdentifier: "America/Los_Angeles"
    )

    let scheduled = try await service.synchronizeTaskReminder(schedule, now: now)

    XCTAssertTrue(scheduled)
    let requests = center.pendingRequests()
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(
      request.identifier,
      LocalNotificationService.taskReminderIdentifier(for: taskID)
    )
    XCTAssertEqual(request.content.title, "Scheduled task is due")
    XCTAssertEqual(
      request.content.body, "Morning briefing is ready to run when you open Turing AI.")
    XCTAssertEqual(request.content.userInfo["kind"] as? String, "due")

    let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
    XCTAssertFalse(trigger.repeats)
    XCTAssertEqual(trigger.dateComponents.timeZone?.identifier, "America/Los_Angeles")
    let triggerDate = try XCTUnwrap(trigger.nextTriggerDate())
    XCTAssertLessThan(abs(triggerDate.timeIntervalSince(nextRunAt)), 1)
    XCTAssertEqual(center.authorizationRequestCount(), 0)
  }

  func testSynchronizeIsIdempotentAndReplacesChangedSchedule() async throws {
    let center = RecordingNotificationCenter(authorizationState: .authorized)
    let service = LocalNotificationService(notificationCenterClient: center)
    let now = Date.now
    let taskID = UUID()
    let initial = reminder(
      taskID: taskID,
      title: "Initial",
      nextRunAt: now.addingTimeInterval(3_600)
    )

    _ = try await service.synchronizeTaskReminder(initial, now: now)
    _ = try await service.synchronizeTaskReminder(initial, now: now)
    XCTAssertEqual(center.addCount(), 1)

    let changed = reminder(
      taskID: taskID,
      title: "Changed",
      nextRunAt: now.addingTimeInterval(7_200)
    )
    _ = try await service.synchronizeTaskReminder(changed, now: now)

    XCTAssertEqual(center.addCount(), 2)
    let requests = center.pendingRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.content.body, "Changed is ready to run when you open Turing AI.")
  }

  func testNewerCancellationWinsWhileOlderSchedulingCallIsSuspended() async throws {
    let readBarrier = PendingNotificationReadBarrier()
    let center = RecordingNotificationCenter(
      authorizationState: .authorized,
      pendingReadBarrier: readBarrier
    )
    let mutationGate = LocalNotificationMutationGate()
    let service = LocalNotificationService(
      notificationCenterClient: center,
      mutationGate: mutationGate
    )
    let now = Date.now
    let taskID = UUID()
    let schedule = reminder(
      taskID: taskID,
      nextRunAt: now.addingTimeInterval(3_600)
    )

    let staleScheduling = Task {
      try await service.synchronizeTaskReminder(schedule, now: now)
    }
    await readBarrier.waitUntilPaused()
    let newerCancellation = Task {
      await service.cancelTaskReminder(taskID: taskID)
    }

    await mutationGate.waitUntilMutationIsQueued()
    let queuedMutations = await mutationGate.waitingCount
    XCTAssertEqual(queuedMutations, 1)

    await readBarrier.resume()
    let didSchedule = try await staleScheduling.value
    XCTAssertTrue(didSchedule)
    await newerCancellation.value
    XCTAssertTrue(center.pendingRequests().isEmpty)
  }

  func testPausedOrPastTaskCancelsReminderWithoutRequestingAuthorization() async throws {
    let center = RecordingNotificationCenter(authorizationState: .authorized)
    let service = LocalNotificationService(notificationCenterClient: center)
    let now = Date.now
    let taskID = UUID()
    let active = reminder(
      taskID: taskID,
      title: "Task",
      nextRunAt: now.addingTimeInterval(3_600)
    )
    _ = try await service.synchronizeTaskReminder(active, now: now)

    let paused = ScheduledTaskReminderSchedule(
      taskID: taskID,
      taskTitle: "Task",
      status: .paused,
      nextRunAt: now.addingTimeInterval(3_600),
      timeZoneIdentifier: TimeZone.current.identifier
    )
    let scheduled = try await service.synchronizeTaskReminder(paused, now: now)

    XCTAssertFalse(scheduled)
    XCTAssertTrue(center.pendingRequests().isEmpty)
    XCTAssertTrue(
      center.removedDeliveredIdentifiers().contains(
        LocalNotificationService.taskReminderIdentifier(for: taskID)
      )
    )
    XCTAssertEqual(center.authorizationRequestCount(), 0)

    let past = reminder(
      taskID: taskID,
      title: "Task",
      nextRunAt: now.addingTimeInterval(-60)
    )
    let pastScheduled = try await service.synchronizeTaskReminder(past, now: now)
    XCTAssertFalse(pastScheduled)
    XCTAssertTrue(center.pendingRequests().isEmpty)
  }

  func testUnauthorizedStateRemovesExistingReminderAndNeverPrompts() async throws {
    let center = RecordingNotificationCenter(authorizationState: .authorized)
    let service = LocalNotificationService(notificationCenterClient: center)
    let now = Date.now
    let schedule = reminder(nextRunAt: now.addingTimeInterval(3_600))
    _ = try await service.synchronizeTaskReminder(schedule, now: now)
    center.setAuthorizationState(.denied)

    let scheduled = try await service.synchronizeTaskReminder(schedule, now: now)

    XCTAssertFalse(scheduled)
    XCTAssertTrue(center.pendingRequests().isEmpty)
    XCTAssertEqual(center.authorizationRequestCount(), 0)
  }

  func testReconcileRemovesDeletedTaskAddsCurrentTaskAndPreservesCompletion() async throws {
    let center = RecordingNotificationCenter(authorizationState: .authorized)
    let service = LocalNotificationService(notificationCenterClient: center)
    let now = Date.now
    let deletedTaskID = UUID()
    let currentTaskID = UUID()
    let staleRequest = try XCTUnwrap(
      LocalNotificationService.taskReminderRequest(
        for: reminder(
          taskID: deletedTaskID,
          nextRunAt: now.addingTimeInterval(3_600)
        ),
        now: now
      )
    )
    let completionContent = UNMutableNotificationContent()
    completionContent.title = "Task finished"
    let completionRequest = UNNotificationRequest(
      identifier: "\(LocalNotificationService.completionIdentifierPrefix)\(deletedTaskID)",
      content: completionContent,
      trigger: nil
    )
    center.seed([staleRequest, completionRequest])
    center.seedDeliveredIdentifiers([staleRequest.identifier])

    let count = try await service.reconcileTaskReminders(
      [
        reminder(
          taskID: currentTaskID,
          nextRunAt: now.addingTimeInterval(7_200)
        )
      ],
      now: now
    )

    XCTAssertEqual(count, 1)
    let identifiers = Set(center.pendingRequests().map(\.identifier))
    XCTAssertEqual(
      identifiers,
      [
        completionRequest.identifier,
        LocalNotificationService.taskReminderIdentifier(for: currentTaskID),
      ]
    )
    XCTAssertTrue(center.deliveredIdentifiers().isEmpty)
  }

  func testCompletionNotificationIsImmediateAndContainsNoPrompt() async throws {
    let center = RecordingNotificationCenter(authorizationState: .authorized)
    let service = LocalNotificationService(notificationCenterClient: center)
    let taskID = UUID()

    let scheduled = try await service.scheduleCompletionReminder(
      taskID: taskID,
      taskTitle: "Daily summary",
      succeeded: true
    )

    XCTAssertTrue(scheduled)
    let request = try XCTUnwrap(center.pendingRequests().first)
    XCTAssertNil(request.trigger)
    XCTAssertTrue(request.identifier.hasPrefix(LocalNotificationService.completionIdentifierPrefix))
    XCTAssertEqual(request.content.body, "Daily summary is ready in Turing AI.")
    XCTAssertEqual(request.content.userInfo["kind"] as? String, "completion")
  }

  func testExplicitPermissionRequestIsTheOnlyAuthorizationPath() async throws {
    let center = RecordingNotificationCenter(
      authorizationState: .notDetermined,
      stateAfterAuthorizationRequest: .authorized
    )
    let service = LocalNotificationService(notificationCenterClient: center)

    let state = try await service.requestAuthorization()

    XCTAssertEqual(state, .authorized)
    XCTAssertEqual(center.authorizationRequestCount(), 1)
  }

  func testForegroundPresentationIncludesVisibleBannerListAndSound() {
    let options = MosaicNotificationCenterDelegate.foregroundPresentationOptions
    XCTAssertTrue(options.contains(.banner))
    XCTAssertTrue(options.contains(.list))
    XCTAssertTrue(options.contains(.sound))
  }

  private func reminder(
    taskID: UUID = UUID(),
    title: String = "Task",
    status: ScheduledTaskStatus = .active,
    nextRunAt: Date,
    timeZoneIdentifier: String = TimeZone.current.identifier
  ) -> ScheduledTaskReminderSchedule {
    ScheduledTaskReminderSchedule(
      taskID: taskID,
      taskTitle: title,
      status: status,
      nextRunAt: nextRunAt,
      timeZoneIdentifier: timeZoneIdentifier
    )
  }
}

private final class RecordingNotificationCenter: LocalNotificationCenterClient, @unchecked Sendable
{
  private let lock = NSLock()
  private var state: NotificationAuthorizationState
  private let stateAfterAuthorizationRequest: NotificationAuthorizationState
  private var requestsByID: [String: UNNotificationRequest] = [:]
  private var delivered: Set<String> = []
  private var authorizationRequests = 0
  private var additions = 0
  private var removedDelivered: Set<String> = []
  private let pendingReadBarrier: PendingNotificationReadBarrier?

  init(
    authorizationState: NotificationAuthorizationState,
    stateAfterAuthorizationRequest: NotificationAuthorizationState? = nil,
    pendingReadBarrier: PendingNotificationReadBarrier? = nil
  ) {
    state = authorizationState
    self.stateAfterAuthorizationRequest = stateAfterAuthorizationRequest ?? authorizationState
    self.pendingReadBarrier = pendingReadBarrier
  }

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    lock.withLock {
      authorizationRequests += 1
      state = stateAfterAuthorizationRequest
      return state.canNotify
    }
  }

  func authorizationState() async -> NotificationAuthorizationState {
    lock.withLock { state }
  }

  func add(_ request: UNNotificationRequest) async throws {
    lock.withLock {
      additions += 1
      requestsByID[request.identifier] = request
    }
  }

  func pendingNotificationRequests() async -> [UNNotificationRequest] {
    if let pendingReadBarrier { await pendingReadBarrier.pauseFirstRead() }
    return lock.withLock { Array(requestsByID.values) }
  }

  func deliveredNotificationIdentifiers() async -> [String] {
    lock.withLock { Array(delivered) }
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
    lock.withLock {
      for identifier in identifiers {
        requestsByID.removeValue(forKey: identifier)
      }
    }
  }

  func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {
    lock.withLock {
      removedDelivered.formUnion(identifiers)
      delivered.subtract(identifiers)
    }
  }

  func seed(_ requests: [UNNotificationRequest]) {
    lock.withLock {
      for request in requests {
        requestsByID[request.identifier] = request
      }
    }
  }

  func seedDeliveredIdentifiers(_ identifiers: Set<String>) {
    lock.withLock {
      delivered.formUnion(identifiers)
    }
  }

  func pendingRequests() -> [UNNotificationRequest] {
    lock.withLock { Array(requestsByID.values) }
  }

  func authorizationRequestCount() -> Int {
    lock.withLock { authorizationRequests }
  }

  func addCount() -> Int {
    lock.withLock { additions }
  }

  func removedDeliveredIdentifiers() -> Set<String> {
    lock.withLock { removedDelivered }
  }

  func deliveredIdentifiers() -> Set<String> {
    lock.withLock { delivered }
  }

  func setAuthorizationState(_ state: NotificationAuthorizationState) {
    lock.withLock {
      self.state = state
    }
  }
}

private actor PendingNotificationReadBarrier {
  private var didPause = false
  private var didResume = false
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var resumeContinuation: CheckedContinuation<Void, Never>?

  func pauseFirstRead() async {
    guard !didPause else { return }
    didPause = true
    let waiters = pauseWaiters
    pauseWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    guard !didResume else { return }
    await withCheckedContinuation { continuation in
      resumeContinuation = continuation
    }
  }

  func waitUntilPaused() async {
    guard !didPause else { return }
    await withCheckedContinuation { continuation in
      pauseWaiters.append(continuation)
    }
  }

  func resume() {
    didResume = true
    resumeContinuation?.resume()
    resumeContinuation = nil
  }
}

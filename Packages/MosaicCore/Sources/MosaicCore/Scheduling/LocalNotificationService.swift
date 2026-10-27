import Foundation
@preconcurrency import UserNotifications

public enum NotificationAuthorizationState: String, Sendable {
  case notDetermined
  case denied
  case authorized
  case provisional
  case ephemeral

  public var canNotify: Bool {
    switch self {
    case .authorized, .provisional, .ephemeral:
      true
    case .notDetermined, .denied:
      false
    }
  }

  fileprivate init(_ status: UNAuthorizationStatus) {
    switch status {
    case .notDetermined:
      self = .notDetermined
    case .denied:
      self = .denied
    case .authorized:
      self = .authorized
    case .provisional:
      self = .provisional
    case .ephemeral:
      self = .ephemeral
    @unknown default:
      self = .notDetermined
    }
  }
}

/// A value-only projection of the durable task state used to maintain its local reminder.
public struct ScheduledTaskReminderSchedule: Equatable, Sendable {
  public let taskID: UUID
  public let taskTitle: String
  public let status: ScheduledTaskStatus
  public let nextRunAt: Date?
  public let timeZoneIdentifier: String

  public init(
    taskID: UUID,
    taskTitle: String,
    status: ScheduledTaskStatus,
    nextRunAt: Date?,
    timeZoneIdentifier: String
  ) {
    self.taskID = taskID
    self.taskTitle = taskTitle
    self.status = status
    self.nextRunAt = nextRunAt
    self.timeZoneIdentifier = timeZoneIdentifier
  }
}

protocol LocalNotificationCenterClient: Sendable {
  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
  func authorizationState() async -> NotificationAuthorizationState
  func add(_ request: UNNotificationRequest) async throws
  func pendingNotificationRequests() async -> [UNNotificationRequest]
  func deliveredNotificationIdentifiers() async -> [String]
  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async
  func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async
}

private final class SystemLocalNotificationCenterClient: LocalNotificationCenterClient,
  @unchecked Sendable
{
  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter) {
    self.center = center
  }

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    try await center.requestAuthorization(options: options)
  }

  func authorizationState() async -> NotificationAuthorizationState {
    NotificationAuthorizationState(await center.notificationSettings().authorizationStatus)
  }

  func add(_ request: UNNotificationRequest) async throws {
    try await center.add(request)
  }

  func pendingNotificationRequests() async -> [UNNotificationRequest] {
    await center.pendingNotificationRequests()
  }

  func deliveredNotificationIdentifiers() async -> [String] {
    await center.deliveredNotifications().map(\.request.identifier)
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
  }

  func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {
    center.removeDeliveredNotifications(withIdentifiers: identifiers)
  }
}

/// Prevents actor reentrancy at UserNotifications suspension points from allowing an older
/// reminder mutation to land after a newer edit, pause, delete, or full reconciliation.
actor LocalNotificationMutationGate {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
  }

  private var isHeld = false
  private var waiters: [Waiter] = []
  private var waitingObservers: [CheckedContinuation<Void, Never>] = []

  var waitingCount: Int { waiters.count }

  func waitUntilMutationIsQueued() async {
    guard waiters.isEmpty else { return }
    await withCheckedContinuation { continuation in
      waitingObservers.append(continuation)
    }
  }

  func acquire() async throws {
    try Task.checkCancellation()
    guard isHeld else {
      isHeld = true
      return
    }

    let waiterID = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiters.append(Waiter(id: waiterID, continuation: continuation))
          let observers = waitingObservers
          waitingObservers.removeAll()
          for observer in observers { observer.resume() }
        }
      }
    } onCancel: {
      Task { await self.cancel(waiterID: waiterID) }
    }
  }

  func release() {
    guard !waiters.isEmpty else {
      isHeld = false
      return
    }
    let next = waiters.removeFirst()
    next.continuation.resume()
  }

  private func cancel(waiterID: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }
}

/// Keeps Mosaic notifications visible when their trigger fires while the app is in front.
public final class MosaicNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate,
  @unchecked Sendable
{
  public static let shared = MosaicNotificationCenterDelegate()

  public static let foregroundPresentationOptions: UNNotificationPresentationOptions = [
    .banner, .list, .sound,
  ]

  private override init() {
    super.init()
  }

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    Self.foregroundPresentationOptions
  }
}

/// Maintains privacy-conscious due-time and completion notifications for scheduled tasks.
///
/// Creating or reconciling a task never calls `requestAuthorization()`. The UI must invoke
/// that method from an explicit user action before any reminder can be delivered.
public actor LocalNotificationService {
  public static let shared = LocalNotificationService()

  static let taskReminderIdentifierPrefix = "mosaic.task-reminder."
  static let completionIdentifierPrefix = "mosaic.task-completion."

  private let notificationCenter: any LocalNotificationCenterClient
  private let mutationGate: LocalNotificationMutationGate

  public init(notificationCenter: UNUserNotificationCenter = .current()) {
    self.notificationCenter = SystemLocalNotificationCenterClient(center: notificationCenter)
    self.mutationGate = LocalNotificationMutationGate()
  }

  init(
    notificationCenterClient: any LocalNotificationCenterClient,
    mutationGate: LocalNotificationMutationGate = LocalNotificationMutationGate()
  ) {
    self.notificationCenter = notificationCenterClient
    self.mutationGate = mutationGate
  }

  /// Installs the retained delegate used to present banners while Mosaic is in the foreground.
  @MainActor
  public static func installForegroundPresentationDelegate(
    notificationCenter: UNUserNotificationCenter = .current()
  ) {
    notificationCenter.delegate = MosaicNotificationCenterDelegate.shared
  }

  /// Requests notification access. Call only in direct response to a visible user action.
  @discardableResult
  public func requestAuthorization() async throws -> NotificationAuthorizationState {
    try await withNotificationMutation {
      _ = try await notificationCenter.requestAuthorization(options: [.alert, .badge, .sound])
      return await authorizationState()
    }
  }

  public func authorizationState() async -> NotificationAuthorizationState {
    await notificationCenter.authorizationState()
  }

  /// Creates, updates, or removes one deterministic reminder to match the durable task state.
  /// This method never prompts for permission.
  @discardableResult
  public func synchronizeTaskReminder(
    _ schedule: ScheduledTaskReminderSchedule,
    now: Date = .now
  ) async throws -> Bool {
    try await withNotificationMutation {
      let identifier = Self.taskReminderIdentifier(for: schedule.taskID)
      let pending = await notificationCenter.pendingNotificationRequests()
      let existing = pending.first { $0.identifier == identifier }

      guard let desired = Self.taskReminderRequest(for: schedule, now: now),
        await authorizationState().canNotify
      else {
        await removeTaskReminder(identifier: identifier)
        return false
      }

      await notificationCenter.removeDeliveredNotifications(withIdentifiers: [identifier])
      if let existing, Self.requestsMatch(existing, desired) {
        return true
      }

      if existing != nil {
        await notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
      }
      try await notificationCenter.add(desired)
      return true
    }
  }

  /// Reconciles every pending Mosaic due-time reminder against the complete durable task list.
  /// Completion notifications use a separate prefix and are intentionally left untouched.
  @discardableResult
  public func reconcileTaskReminders(
    _ schedules: [ScheduledTaskReminderSchedule],
    now: Date = .now
  ) async throws -> Int {
    try await withNotificationMutation {
      var schedulesByID: [UUID: ScheduledTaskReminderSchedule] = [:]
      for schedule in schedules {
        schedulesByID[schedule.taskID] = schedule
      }

      let pending = await notificationCenter.pendingNotificationRequests()
      let deliveredReminderIdentifiers =
        await notificationCenter
        .deliveredNotificationIdentifiers()
        .filter { $0.hasPrefix(Self.taskReminderIdentifierPrefix) }
      let existingReminders = pending.filter {
        $0.identifier.hasPrefix(Self.taskReminderIdentifierPrefix)
      }
      let desiredRequests = Dictionary(
        uniqueKeysWithValues: schedulesByID.values.compactMap { schedule in
          Self.taskReminderRequest(for: schedule, now: now).map { ($0.identifier, $0) }
        }
      )
      let existingByID = Dictionary(
        uniqueKeysWithValues: existingReminders.map { ($0.identifier, $0) }
      )
      let canNotify = await authorizationState().canNotify
      let desiredIdentifiers = canNotify ? Set(desiredRequests.keys) : []
      let staleIdentifiers = Set(existingByID.keys).subtracting(desiredIdentifiers)

      if !deliveredReminderIdentifiers.isEmpty {
        await notificationCenter.removeDeliveredNotifications(
          withIdentifiers: deliveredReminderIdentifiers
        )
      }
      if !staleIdentifiers.isEmpty {
        let identifiers = staleIdentifiers.sorted()
        await notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        await notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
      }

      guard canNotify else { return 0 }

      var scheduledCount = 0
      for identifier in desiredIdentifiers.sorted() {
        guard let desired = desiredRequests[identifier] else { continue }
        await notificationCenter.removeDeliveredNotifications(withIdentifiers: [identifier])
        if let existing = existingByID[identifier], Self.requestsMatch(existing, desired) {
          scheduledCount += 1
          continue
        }

        if existingByID[identifier] != nil {
          await notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
        }
        try await notificationCenter.add(desired)
        scheduledCount += 1
      }
      return scheduledCount
    }
  }

  /// Removes both pending and already-delivered copies of one task's due-time reminder.
  public func cancelTaskReminder(taskID: UUID) async {
    try? await withNotificationMutation {
      await removeTaskReminder(identifier: Self.taskReminderIdentifier(for: taskID))
    }
  }

  /// Posts a local completion notification only if access has already been granted.
  /// The prompt and generated response are intentionally excluded.
  @discardableResult
  public func scheduleCompletionReminder(
    taskID: UUID,
    taskTitle: String,
    succeeded: Bool
  ) async throws -> Bool {
    try await withNotificationMutation {
      guard await authorizationState().canNotify else { return false }

      let displayTitle = Self.displayTitle(taskTitle)
      let content = UNMutableNotificationContent()
      content.title = succeeded ? "Task finished" : "Task needs attention"
      content.body =
        succeeded
        ? "\(displayTitle) is ready in Turing AI."
        : "\(displayTitle) couldn’t finish. Open Turing AI to review the error."
      content.sound = .default
      content.interruptionLevel = .active
      content.threadIdentifier = "mosaic.scheduled-tasks"
      content.userInfo = ["taskID": taskID.uuidString, "kind": "completion"]

      let request = UNNotificationRequest(
        identifier: "\(Self.completionIdentifierPrefix)\(taskID.uuidString).\(UUID().uuidString)",
        content: content,
        trigger: nil
      )
      try await notificationCenter.add(request)
      return true
    }
  }

  static func taskReminderIdentifier(for taskID: UUID) -> String {
    "\(taskReminderIdentifierPrefix)\(taskID.uuidString)"
  }

  static func taskReminderRequest(
    for schedule: ScheduledTaskReminderSchedule,
    now: Date
  ) -> UNNotificationRequest? {
    guard schedule.status == .active,
      let nextRunAt = schedule.nextRunAt,
      nextRunAt > now
    else {
      return nil
    }

    let timeZone = TimeZone(identifier: schedule.timeZoneIdentifier) ?? .current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    var components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: nextRunAt
    )
    components.calendar = calendar
    components.timeZone = timeZone

    let content = UNMutableNotificationContent()
    content.title = "Scheduled task is due"
    content.body = "\(displayTitle(schedule.taskTitle)) is ready to run when you open Turing AI."
    content.sound = .default
    content.interruptionLevel = .active
    content.threadIdentifier = "mosaic.scheduled-tasks"
    content.userInfo = ["taskID": schedule.taskID.uuidString, "kind": "due"]

    return UNNotificationRequest(
      identifier: taskReminderIdentifier(for: schedule.taskID),
      content: content,
      trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    )
  }

  private static func displayTitle(_ taskTitle: String) -> String {
    let normalizedTitle = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalizedTitle.isEmpty ? "Scheduled task" : normalizedTitle
  }

  private static func requestsMatch(
    _ existing: UNNotificationRequest,
    _ desired: UNNotificationRequest
  ) -> Bool {
    guard existing.identifier == desired.identifier,
      existing.content.title == desired.content.title,
      existing.content.body == desired.content.body,
      existing.content.threadIdentifier == desired.content.threadIdentifier,
      existing.content.userInfo["taskID"] as? String
        == desired.content.userInfo["taskID"] as? String,
      existing.content.userInfo["kind"] as? String
        == desired.content.userInfo["kind"] as? String,
      let existingTrigger = existing.trigger as? UNCalendarNotificationTrigger,
      let desiredTrigger = desired.trigger as? UNCalendarNotificationTrigger,
      let existingDate = existingTrigger.nextTriggerDate(),
      let desiredDate = desiredTrigger.nextTriggerDate()
    else {
      return false
    }

    return abs(existingDate.timeIntervalSince(desiredDate)) < 1
  }

  private func removeTaskReminder(identifier: String) async {
    await notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
    await notificationCenter.removeDeliveredNotifications(withIdentifiers: [identifier])
  }

  private func withNotificationMutation<T: Sendable>(
    _ operation: () async throws -> T
  ) async throws -> T {
    try await mutationGate.acquire()
    do {
      try Task.checkCancellation()
      let result = try await operation()
      await mutationGate.release()
      return result
    } catch {
      await mutationGate.release()
      throw error
    }
  }
}

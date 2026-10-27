import Foundation
import SwiftData
import Testing
@preconcurrency import UserNotifications

@testable import MosaicCore

@Suite("Foreground task runner")
@MainActor
struct ForegroundTaskRunnerTests {
  @Test("Run Now reserves running state before asynchronous provider work starts")
  func startRunNowReservesSynchronously() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let operationCoordinator = MosaicOperationCoordinator()
    let provider = ProviderConfigurationRecord(
      displayName: "Test provider",
      provider: .openAI,
      modelIdentifier: "test-model"
    )
    let task = ScheduledTaskRecord(
      title: "Immediate run",
      prompt: "Return a short response.",
      providerConfigurationID: provider.id,
      scheduledAt: .now
    )
    context.insert(provider)
    context.insert(task)
    try operationCoordinator.saveSourceChanges(in: context)

    let notifications = LocalNotificationService(
      notificationCenterClient: TaskRunnerNotificationCenter()
    )
    let runner = ForegroundTaskRunner(
      credentialStore: TaskRunnerCredentialStore(),
      notificationService: notifications,
      operationCoordinator: operationCoordinator,
      clientFactory: { _ in TaskRunnerProviderClient() },
      automaticMemoryIsEnabled: { false }
    )

    #expect(runner.startRunNow(task, in: context))
    #expect(runner.isRunning(taskID: task.id))
    #expect(operationCoordinator.activeOperations.contains(.scheduledTask(task.id)))
    #expect(!runner.startRunNow(task, in: context))

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while runner.isRunning(taskID: task.id), clock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(!runner.isRunning(taskID: task.id))
    #expect(operationCoordinator.activeOperations.isEmpty)
    #expect(task.status == .completed)
    #expect(task.lastError == nil)
    #expect(task.conversationID != nil)

    let messages = try context.fetch(FetchDescriptor<MessageRecord>())
    let assistant = try #require(messages.first(where: { $0.role == .assistant }))
    #expect(assistant.status == .complete)
    #expect(assistant.content == "Scheduled response")
  }

  @Test("a foreground sweep stops before opening another paid request")
  func sweepChecksLifecycleBetweenDueTasks() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let operationCoordinator = MosaicOperationCoordinator()
    let now = Date.now
    let provider = ProviderConfigurationRecord(
      displayName: "Test provider",
      provider: .openAI,
      modelIdentifier: "test-model"
    )
    let first = ScheduledTaskRecord(
      title: "First",
      prompt: "First prompt",
      providerConfigurationID: provider.id,
      scheduledAt: now.addingTimeInterval(-120)
    )
    let second = ScheduledTaskRecord(
      title: "Second",
      prompt: "Second prompt",
      providerConfigurationID: provider.id,
      scheduledAt: now.addingTimeInterval(-60)
    )
    context.insert(provider)
    context.insert(first)
    context.insert(second)
    try operationCoordinator.saveSourceChanges(in: context)

    let runner = ForegroundTaskRunner(
      credentialStore: TaskRunnerCredentialStore(),
      notificationService: LocalNotificationService(
        notificationCenterClient: TaskRunnerNotificationCenter()
      ),
      operationCoordinator: operationCoordinator,
      clientFactory: { _ in TaskRunnerProviderClient() },
      automaticMemoryIsEnabled: { false }
    )
    var continuationChecks = 0

    await runner.runDueTasks(in: context, now: now) {
      continuationChecks += 1
      return continuationChecks <= 2
    }

    #expect(first.status == .completed)
    #expect(first.conversationID != nil)
    #expect(second.status == .active)
    #expect(second.conversationID == nil)
    #expect(continuationChecks == 3)
  }
}

private actor TaskRunnerCredentialStore: ProviderCredentialStoring {
  func setAPIKey(
    _ apiKey: String,
    for configurationID: UUID,
    binding: ProviderCredentialBinding
  ) async throws {}

  func apiKey(
    for configurationID: UUID,
    expectedBinding: ProviderCredentialBinding
  ) async throws -> String? {
    "test-key"
  }

  func removeAPIKey(for configurationID: UUID) async throws {}
}

private struct TaskRunnerProviderClient: AIProviderClient {
  func listModels() async throws -> [String] { ["test-model"] }

  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.textDelta("Scheduled response"))
      continuation.yield(.completed(responseID: "test-response"))
      continuation.finish()
    }
  }
}

private final class TaskRunnerNotificationCenter: LocalNotificationCenterClient,
  @unchecked Sendable
{
  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { false }
  func authorizationState() async -> NotificationAuthorizationState { .denied }
  func add(_ request: UNNotificationRequest) async throws {}
  func pendingNotificationRequests() async -> [UNNotificationRequest] { [] }
  func deliveredNotificationIdentifiers() async -> [String] { [] }
  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {}
  func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {}
}

extension ForegroundTaskRunnerTests {
  @Test(
    "a queued task paused, rescheduled or deleted during an earlier run must not execute",
    arguments: ["pause", "reschedule", "delete"])
  func sweepRevalidatesDueTask(change: String) async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let operationCoordinator = MosaicOperationCoordinator()
    let now = Date.now
    let provider = ProviderConfigurationRecord(
      displayName: "Test provider",
      provider: .openAI,
      modelIdentifier: "test-model"
    )
    let first = ScheduledTaskRecord(
      title: "First",
      prompt: "First prompt",
      providerConfigurationID: provider.id,
      scheduledAt: now.addingTimeInterval(-120)
    )
    let second = ScheduledTaskRecord(
      title: "Second",
      prompt: "Second prompt",
      providerConfigurationID: provider.id,
      scheduledAt: now.addingTimeInterval(-60)
    )
    context.insert(provider)
    context.insert(first)
    context.insert(second)
    try operationCoordinator.saveSourceChanges(in: context)

    let runner = ForegroundTaskRunner(
      credentialStore: TaskRunnerCredentialStore(),
      notificationService: LocalNotificationService(
        notificationCenterClient: TaskRunnerNotificationCenter()
      ),
      operationCoordinator: operationCoordinator,
      clientFactory: { _ in TaskRunnerProviderClient() },
      automaticMemoryIsEnabled: { false }
    )
    var continuationChecks = 0

    await runner.runDueTasks(in: context, now: now) {
      continuationChecks += 1
      if continuationChecks == 3 {
        if change == "reschedule" {
          second.scheduledAt = now.addingTimeInterval(3600)
          second.nextRunAt = second.scheduledAt
        } else if change == "delete" {
          context.delete(second)
        } else {
          second.status = .paused
        }
        try! operationCoordinator.saveSourceChanges(in: context)
      }
      return true
    }

    #expect(first.status == .completed)
    #expect(first.conversationID != nil)
    if change == "delete" {
      #expect(try context.fetch(FetchDescriptor<ScheduledTaskRecord>()).count == 1)
      #expect(try context.fetch(FetchDescriptor<ConversationRecord>()).count == 1)
    } else {
      #expect(second.status == (change == "reschedule" ? .active : .paused))
      #expect(second.conversationID == nil)
    }
  }
}

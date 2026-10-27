import Foundation
import Observation
import SwiftData

public enum ForegroundTaskRunnerError: Error, Equatable, Sendable {
  case missingProvider
  case providerNotFound
  case providerDisabled
  case providerCannotChat
  case incompleteStream
  case emptyResponse
  case staleContext
}

extension ForegroundTaskRunnerError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .missingProvider:
      "Choose a provider before running this task."
    case .providerNotFound:
      "The selected provider no longer exists. Choose another provider."
    case .providerDisabled:
      "The selected provider is disabled. Enable it or choose another provider."
    case .providerCannotChat:
      "The selected provider is for embeddings. Choose a chat-capable provider."
    case .incompleteStream:
      "The provider connection ended before the response completed."
    case .emptyResponse:
      "The provider completed the request without returning visible text."
    case .staleContext:
      "The task's memory or source context changed before the provider request started. Run it again to use the current context."
    }
  }
}

/// Runs scheduled prompts while Mosaic is active.
///
/// All SwiftData access stays on the main actor. This type deliberately makes
/// no claim of exact iOS background execution; app activation should call
/// `runDueTasks(in:)`, and people can explicitly invoke `runNow(_:in:)`.
@Observable
@MainActor
public final class ForegroundTaskRunner {
  public static let shared = ForegroundTaskRunner()

  public private(set) var runningTaskIDs: Set<UUID> = []
  public private(set) var lastSweepError: String?

  private let credentialStore: any ProviderCredentialStoring
  private let notificationService: LocalNotificationService
  private let calendar: Calendar?
  private let memoryContextBuilder: MemoryContextBuilder
  private let operationCoordinator: MosaicOperationCoordinator
  private let clientFactory: @MainActor (ProviderConnection) -> any AIProviderClient
  private let automaticMemoryIsEnabled: @MainActor () -> Bool

  public init(
    credentialStore: any ProviderCredentialStoring = SecurityKeychain.shared,
    notificationService: LocalNotificationService = .shared,
    calendar: Calendar? = nil,
    memoryContextBuilder: MemoryContextBuilder = MemoryContextBuilder(),
    operationCoordinator: MosaicOperationCoordinator = .shared,
    clientFactory: @escaping @MainActor (ProviderConnection) -> any AIProviderClient = {
      ProviderClientFactory.make(connection: $0)
    },
    automaticMemoryIsEnabled: @escaping @MainActor () -> Bool = {
      (UserDefaults.standard.object(forKey: AutomaticMemorySettings.enabledKey) as? Bool) ?? true
    }
  ) {
    self.credentialStore = credentialStore
    self.notificationService = notificationService
    self.calendar = calendar
    self.memoryContextBuilder = memoryContextBuilder
    self.operationCoordinator = operationCoordinator
    self.clientFactory = clientFactory
    self.automaticMemoryIsEnabled = automaticMemoryIsEnabled
  }

  public func isRunning(taskID: UUID) -> Bool {
    runningTaskIDs.contains(taskID)
  }

  /// Scans active records and runs each due task once, in chronological order.
  public func runDueTasks(
    in modelContext: ModelContext,
    now: Date = .now,
    shouldContinue: @MainActor () -> Bool = { true }
  ) async {
    let sweepOperation = MosaicOperationID.scheduledTaskSweep
    guard operationCoordinator.begin(sweepOperation) else { return }
    defer { operationCoordinator.end(sweepOperation) }
    do {
      let records = try modelContext.fetch(FetchDescriptor<ScheduledTaskRecord>())
      let reminderSchedules = records.map(reminderSchedule)
      do {
        _ = try await notificationService.reconcileTaskReminders(
          reminderSchedules,
          now: now
        )
        lastSweepError = nil
      } catch {
        lastSweepError = reminderFailureDescription(error)
      }
      guard shouldContinue() else { return }
      let dueTaskIDs =
        try modelContext.fetch(FetchDescriptor<ScheduledTaskRecord>())
        .filter { task in
          guard task.status == .active else { return false }
          let nextRun = task.nextRunAt ?? task.scheduledAt
          return nextRun <= now
        }
        .sorted { lhs, rhs in
          (lhs.nextRunAt ?? lhs.scheduledAt) < (rhs.nextRunAt ?? rhs.scheduledAt)
        }
        .map(\.id)

      for taskID in dueTaskIDs {
        guard shouldContinue() else { return }
        // Earlier requests suspend this sweep. A queued task may have been edited or
        // deleted meanwhile; never retain a model instance across those suspensions.
        var descriptor = FetchDescriptor<ScheduledTaskRecord>(
          predicate: #Predicate { $0.id == taskID }
        )
        descriptor.fetchLimit = 1
        guard let task = try modelContext.fetch(descriptor).first, !task.isDeleted else { continue }
        _ = await execute(task, trigger: .scheduled, in: modelContext, attemptedAt: now)
      }
    } catch {
      lastSweepError = error.localizedDescription
    }
  }

  /// Reconciles reminders immediately after launch or a live-store generation replacement without
  /// executing provider work. Scheduling failures remain visible in the Automations screen.
  public func reconcileTaskReminders(
    in modelContext: ModelContext,
    now: Date = .now
  ) async {
    do {
      let records = try modelContext.fetch(FetchDescriptor<ScheduledTaskRecord>())
      _ = try await notificationService.reconcileTaskReminders(
        records.map(reminderSchedule),
        now: now
      )
      lastSweepError = nil
    } catch {
      lastSweepError = reminderFailureDescription(error)
    }
  }

  /// Runs a task immediately without silently changing a paused recurring
  /// task back to active.
  @discardableResult
  public func runNow(
    _ task: ScheduledTaskRecord,
    in modelContext: ModelContext,
    now: Date = .now
  ) async -> Bool {
    await execute(task, trigger: .manual, in: modelContext, attemptedAt: now)
  }

  /// Reserves the task synchronously before creating an asynchronous job. Views use this surface
  /// so an exclusive restore cannot slip between a button action and the task's first turn.
  @discardableResult
  public func startRunNow(
    _ task: ScheduledTaskRecord,
    in modelContext: ModelContext,
    now: Date = .now
  ) -> Bool {
    let taskID = task.id
    let operationID = MosaicOperationID.scheduledTask(taskID)
    guard operationCoordinator.begin(operationID) else { return false }
    guard runningTaskIDs.insert(taskID).inserted else {
      operationCoordinator.end(operationID)
      return false
    }
    Task { @MainActor in
      defer {
        runningTaskIDs.remove(taskID)
        operationCoordinator.end(operationID)
      }
      _ = await execute(
        task,
        trigger: .manual,
        in: modelContext,
        attemptedAt: now,
        operationIsReserved: true,
        runningStateIsReserved: true
      )
    }
    return true
  }

  @discardableResult
  private func execute(
    _ task: ScheduledTaskRecord,
    trigger: RunTrigger,
    in modelContext: ModelContext,
    attemptedAt: Date,
    operationIsReserved: Bool = false,
    runningStateIsReserved: Bool = false
  ) async -> Bool {
    if trigger == .scheduled {
      guard task.status == .active,
        (task.nextRunAt ?? task.scheduledAt) <= attemptedAt
      else { return false }
    }
    let operationID = MosaicOperationID.scheduledTask(task.id)
    if !operationIsReserved,
      !operationCoordinator.begin(operationID)
    {
      return false
    }
    defer {
      if !operationIsReserved { operationCoordinator.end(operationID) }
    }
    if !runningStateIsReserved {
      guard runningTaskIDs.insert(task.id).inserted else { return false }
    }
    defer {
      if !runningStateIsReserved { runningTaskIDs.remove(task.id) }
    }

    let snapshot = ScheduledTaskExecutionSnapshot(task: task)
    let statusBeforeRun = snapshot.status
    var assistantMessage: MessageRecord?
    var apiKeyForRedaction: String?

    // Claim the run before awaiting the provider. A crash then cannot leave a
    // due task ready to issue the same paid request automatically again.
    task.lastRunAt = attemptedAt
    task.lastError = "The previous run was interrupted before completion."
    task.nextRunAt = nextRunDate(
      recurrence: snapshot.recurrence,
      scheduledAt: snapshot.scheduledAt,
      timeZoneIdentifier: snapshot.timeZoneIdentifier,
      after: attemptedAt,
      succeeded: false
    )
    if snapshot.recurrence == .once {
      task.status = .failed
    }
    task.updatedAt = attemptedAt

    do {
      try operationCoordinator.saveSourceChanges(in: modelContext)
      await synchronizeReminder(for: task, now: attemptedAt)
      let providerRecord = try providerConfiguration(
        for: snapshot.providerConfigurationID,
        in: modelContext
      )
      let selectedModel = try ProviderModelStore.taskModel(
        taskID: task.id, provider: providerRecord, in: modelContext)
      let provider = try ProviderModelStore.connection(
        provider: providerRecord, modelIdentifier: selectedModel,
        models: ProviderModelStore.records(providerID: providerRecord.id, in: modelContext))
      let apiKey = try await credentialStore.apiKey(
        for: provider.id,
        expectedBinding: provider.credentialBinding
      )
      apiKeyForRedaction = apiKey

      if provider.provider.requiresAPIKey,
        apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
      {
        throw ProviderClientError.missingAPIKey
      }

      let connection = provider.authenticated(with: apiKey)
      let client = clientFactory(connection)

      try MosaicSourceFieldLimits.validateMessageContent(snapshot.prompt)
      let conversation = ConversationRecord(
        title: normalizedTitle(snapshot.title, fallback: "Scheduled task"),
        providerConfigurationID: provider.id,
        modelIdentifier: provider.modelIdentifier
      )
      let providerHost = provider.resolvedBaseURL?.host
      let userMessage = MessageRecord(
        conversationID: conversation.id,
        role: .user,
        content: snapshot.prompt,
        status: .complete,
        providerConfigurationID: provider.id,
        providerKind: provider.provider,
        providerDisplayName: provider.displayName,
        providerHost: providerHost,
        modelIdentifier: provider.modelIdentifier
      )
      let responseMessage = MessageRecord(
        conversationID: conversation.id,
        role: .assistant,
        content: "",
        status: .streaming,
        providerConfigurationID: provider.id,
        providerKind: provider.provider,
        providerDisplayName: provider.displayName,
        providerHost: providerHost,
        modelIdentifier: provider.modelIdentifier
      )
      assistantMessage = responseMessage

      modelContext.insert(conversation)
      modelContext.insert(userMessage)
      modelContext.insert(responseMessage)
      task.conversationID = conversation.id
      try operationCoordinator.saveSourceChanges(in: modelContext)

      let readRepository = MosaicConversationReadRepository(
        modelContainer: modelContext.container
      )
      let requestProjectContext = try await readRepository.projectContextSnapshot(
        conversationID: conversation.id
      )
      let memoryContext = try await readRepository.curatedMemoryContext(
        conversationID: conversation.id,
        builder: memoryContextBuilder
      )
      let retrievedContext = await SemanticMemoryCoordinator.retrieve(
        query: snapshot.prompt,
        excluding: conversation.id,
        in: modelContext
      )
      try Task.checkCancellation()
      let baseContextReceipt = RequestContextReceipt(
        curatedContext: memoryContext,
        retrievedContext: retrievedContext,
        projectContext: requestProjectContext.receipt
      )
      let systemContext = [
        baseContextReceipt.curatedContext.systemContent,
        baseContextReceipt.retrievedContext.systemContent,
      ]
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
      let providerLimits = ProviderConversationContextLimits(configuration: provider)
      let contextPlanner = ConversationContextPlanner(
        policy: providerLimits.policy,
        warnings: providerLimits.warnings
      )
      let contextPlan = try contextPlanner.plan(
        messages: [
          AIChatMessage(id: userMessage.id, role: .user, content: snapshot.prompt)
        ],
        systemPrompt: systemContext.isEmpty ? nil : systemContext
      )
      let contextReceipt = RequestContextReceipt(
        curatedContext: baseContextReceipt.curatedContext,
        retrievedContext: baseContextReceipt.retrievedContext,
        projectContext: baseContextReceipt.projectContext,
        conversationContext: contextPlan.receipt
      )
      try NormalizedContextStore(modelContext: modelContext).appendRequestEvent(
        assistantMessageID: responseMessage.id,
        conversationID: conversation.id,
        sourceThroughMessageID: userMessage.id,
        eventSequence: 0,
        receipt: contextReceipt,
        canonicalMessages: [
          AIChatMessage(id: userMessage.id, role: .user, content: userMessage.content)
        ]
      )

      let request = AIChatRequest(
        messages: contextPlan.messages,
        systemPrompt: systemContext.isEmpty ? nil : systemContext,
        maxOutputTokens: contextPlanner.policy.maximumOutputTokens
      )

      guard
        try await readRepository.canonicalState(conversationID: conversation.id).messages
          .starts(with: [
            AIChatMessage(id: userMessage.id, role: .user, content: userMessage.content)
          ]),
        try await readRepository.curatedMemoryContextIsCurrent(
          memoryContext,
          conversationID: conversation.id,
          projectID: requestProjectContext.receipt?.projectID
        ),
        await SemanticMemoryCoordinator.isCurrent(
          retrievedContext,
          audienceScope: requestProjectContext.audienceScope,
          in: modelContext
        ),
        try await readRepository.projectContextSnapshot(conversationID: conversation.id)
          == requestProjectContext
      else {
        throw ForegroundTaskRunnerError.staleContext
      }
      try Task.checkCancellation()

      var responseText = ""
      var responseUTF8Bytes = 0
      var providerResponseID: String?
      var inputTokens: Int?
      var outputTokens: Int?
      var receivedCompletion = false

      for try await event in client.stream(request) {
        switch event {
        case .citations: break
        case .textDelta(let delta):
          let (nextByteCount, overflow) = responseUTF8Bytes.addingReportingOverflow(
            delta.utf8.count
          )
          guard !overflow,
            nextByteCount <= MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes
          else {
            throw MosaicSourceFieldLimitError.messageContent(
              actual: overflow ? .max : nextByteCount,
              maximum: MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes
            )
          }
          responseText += delta
          responseUTF8Bytes = nextByteCount
          responseMessage.content = responseText
          responseMessage.updatedAt = .now
        case .usage(let usage):
          if let value = usage.inputTokens { inputTokens = value }
          if let value = usage.outputTokens { outputTokens = value }
        case .completed(let responseID):
          receivedCompletion = true
          if let responseID { providerResponseID = responseID }
        }
      }

      guard receivedCompletion else {
        throw ForegroundTaskRunnerError.incompleteStream
      }
      guard !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ForegroundTaskRunnerError.emptyResponse
      }

      let completedAt = Date.now
      responseMessage.content = responseText
      responseMessage.status = .complete
      responseMessage.providerMessageID = providerResponseID
      responseMessage.inputTokenCount = inputTokens
      responseMessage.outputTokenCount = outputTokens
      responseMessage.errorDescription = nil
      responseMessage.updatedAt = completedAt
      conversation.updatedAt = completedAt

      task.lastRunAt = completedAt
      task.lastError = nil
      task.nextRunAt = nextRunDate(
        recurrence: snapshot.recurrence,
        scheduledAt: snapshot.scheduledAt,
        timeZoneIdentifier: snapshot.timeZoneIdentifier,
        after: attemptedAt,
        succeeded: true
      )
      task.status = resultingStatus(
        recurrence: snapshot.recurrence,
        currentStatus: task.status,
        previousStatus: statusBeforeRun,
        trigger: trigger
      )
      task.updatedAt = completedAt
      try operationCoordinator.saveSourceChanges(in: modelContext)
      await synchronizeReminder(for: task, now: completedAt)

      let usedMemoryTopicIDs = Set(
        retrievedContext.items.compactMap { item in
          item.source == .memoryTopic ? item.id : nil
        }
      )
      if !usedMemoryTopicIDs.isEmpty {
        do {
          try await AutomaticMemoryStore(modelContainer: modelContext.container).recordUse(
            topicIDs: usedMemoryTopicIDs
          )
          operationCoordinator.markMemoryLibraryChanged()
        } catch {
          // Usage bookkeeping must not turn a completed paid request into a failed task run.
        }
      }
      if automaticMemoryIsEnabled() {
        scheduleAutomaticMemoryFormation(
          conversationID: conversation.id,
          provider: connection,
          client: client,
          sourceUserMessageID: userMessage.id,
          assistantMessageID: responseMessage.id,
          modelContainer: modelContext.container
        )
      }

      _ = try? await notificationService.scheduleCompletionReminder(
        taskID: task.id,
        taskTitle: snapshot.title,
        succeeded: true
      )
      return true
    } catch {
      let failedAt = Date.now
      let message = sanitizedDescription(for: error, redacting: apiKeyForRedaction)

      if let assistantMessage {
        assistantMessage.status = .failed
        assistantMessage.errorDescription = message
        assistantMessage.updatedAt = failedAt
      }

      task.status = resultingFailureStatus(
        recurrence: snapshot.recurrence,
        currentStatus: task.status,
        previousStatus: statusBeforeRun
      )
      task.lastRunAt = failedAt
      task.lastError = message
      task.nextRunAt = nextRunDate(
        recurrence: snapshot.recurrence,
        scheduledAt: snapshot.scheduledAt,
        timeZoneIdentifier: snapshot.timeZoneIdentifier,
        after: attemptedAt,
        succeeded: false
      )
      task.updatedAt = failedAt

      do {
        try operationCoordinator.saveSourceChanges(in: modelContext)
        await synchronizeReminder(for: task, now: failedAt)
      } catch {
        lastSweepError = error.localizedDescription
      }

      _ = try? await notificationService.scheduleCompletionReminder(
        taskID: task.id,
        taskTitle: snapshot.title,
        succeeded: false
      )
      return false
    }
  }

  private func providerConfiguration(
    for providerID: UUID?,
    in modelContext: ModelContext
  ) throws -> ProviderConfigurationRecord {
    guard let providerID else {
      throw ForegroundTaskRunnerError.missingProvider
    }

    let providers = try modelContext.fetch(FetchDescriptor<ProviderConfigurationRecord>())
    guard let provider = providers.first(where: { $0.id == providerID }) else {
      throw ForegroundTaskRunnerError.providerNotFound
    }
    guard provider.isEnabled else {
      throw ForegroundTaskRunnerError.providerDisabled
    }
    guard provider.provider.supportsChat else {
      throw ForegroundTaskRunnerError.providerCannotChat
    }
    return provider
  }

  private func scheduleAutomaticMemoryFormation(
    conversationID: UUID,
    provider: ProviderConnection,
    client: any AIProviderClient,
    sourceUserMessageID: UUID,
    assistantMessageID: UUID,
    modelContainer: ModelContainer
  ) {
    let operationID = MosaicOperationID.memoryFormation(sourceUserMessageID)
    Task { @MainActor in
      guard operationCoordinator.begin(operationID) else { return }
      defer { operationCoordinator.end(operationID) }
      do {
        let result = try await AutomaticMemoryFormationCoordinator.shared.formMemory(
          conversationID: conversationID,
          throughUserMessageID: sourceUserMessageID,
          assistantMessageID: assistantMessageID,
          provider: provider,
          client: client,
          modelContainer: modelContainer
        )
        if result.changedCount > 0 {
          operationCoordinator.markMemoryLibraryChanged()
        }
      } catch {
        // The durable job keeps a bounded failure for explicit retry. A completed scheduled reply
        // remains successful even when its isolated memory update cannot finish.
      }
    }
  }

  private func nextRunDate(
    recurrence: ScheduleRecurrence,
    scheduledAt: Date,
    timeZoneIdentifier: String,
    after attemptedAt: Date,
    succeeded: Bool
  ) -> Date? {
    if recurrence == .once {
      if succeeded { return nil }
      return scheduledAt > attemptedAt ? scheduledAt : nil
    }
    return ScheduleCalculator().nextDate(
      after: attemptedAt,
      startingAt: scheduledAt,
      recurrence: recurrence,
      calendar: schedulingCalendar(timeZoneIdentifier: timeZoneIdentifier)
    )
  }

  private func schedulingCalendar(timeZoneIdentifier: String) -> Calendar {
    if let calendar { return calendar }
    var current = Calendar.current
    if let timeZone = TimeZone(identifier: timeZoneIdentifier) {
      current.timeZone = timeZone
    }
    return current
  }

  private func reminderSchedule(
    for task: ScheduledTaskRecord
  ) -> ScheduledTaskReminderSchedule {
    ScheduledTaskReminderSchedule(
      taskID: task.id,
      taskTitle: task.title,
      status: task.status,
      nextRunAt: task.nextRunAt,
      timeZoneIdentifier: task.timeZoneIdentifier
    )
  }

  private func synchronizeReminder(
    for task: ScheduledTaskRecord,
    now: Date
  ) async {
    let schedule = reminderSchedule(for: task)
    do {
      _ = try await notificationService.synchronizeTaskReminder(schedule, now: now)
    } catch {
      lastSweepError = reminderFailureDescription(error)
    }
  }

  private func reminderFailureDescription(_ error: Error) -> String {
    "Task reminders could not be updated. \(error.localizedDescription)"
  }

  private func resultingStatus(
    recurrence: ScheduleRecurrence,
    currentStatus: ScheduledTaskStatus,
    previousStatus: ScheduledTaskStatus,
    trigger: RunTrigger
  ) -> ScheduledTaskStatus {
    if recurrence == .once { return .completed }
    if currentStatus == .paused { return .paused }
    if trigger == .manual, previousStatus == .paused { return .paused }
    return .active
  }

  private func resultingFailureStatus(
    recurrence: ScheduleRecurrence,
    currentStatus: ScheduledTaskStatus,
    previousStatus: ScheduledTaskStatus
  ) -> ScheduledTaskStatus {
    guard recurrence != .once else { return .failed }
    if currentStatus == .paused { return .paused }
    switch previousStatus {
    case .active:
      // A transient provider failure must not permanently disable a recurring task.
      return .active
    case .paused:
      return .paused
    case .completed, .failed:
      return .failed
    }
  }

  private func normalizedTitle(_ value: String, fallback: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  private func sanitizedDescription(for error: Error, redacting apiKey: String?) -> String {
    ProviderErrorSanitizer.description(for: error, redacting: apiKey)
  }
}

extension ForegroundTaskRunner {
  fileprivate enum RunTrigger: Sendable {
    case scheduled
    case manual
  }
}

private struct ScheduledTaskExecutionSnapshot {
  let title: String
  let prompt: String
  let providerConfigurationID: UUID?
  let recurrence: ScheduleRecurrence
  let status: ScheduledTaskStatus
  let scheduledAt: Date
  let timeZoneIdentifier: String

  init(task: ScheduledTaskRecord) {
    title = task.title
    prompt = task.prompt
    providerConfigurationID = task.providerConfigurationID
    recurrence = task.recurrence
    status = task.status
    scheduledAt = task.scheduledAt
    timeZoneIdentifier = task.timeZoneIdentifier
  }
}

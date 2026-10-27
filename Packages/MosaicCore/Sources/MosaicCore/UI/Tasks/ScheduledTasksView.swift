import SwiftData
import SwiftUI

@MainActor
public struct ScheduledTasksView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.scenePhase) private var scenePhase
  @Query(sort: \ScheduledTaskRecord.scheduledAt, order: .forward) private var tasks:
    [ScheduledTaskRecord]
  @Query(sort: \ProviderConfigurationRecord.displayName) private var providers:
    [ProviderConfigurationRecord]

  @Query private var providerModels: [ProviderModelRecord]
  @Query private var taskModels: [ScheduledTaskModelRecord]
  @State private var runner: ForegroundTaskRunner
  @State private var searchText = ""
  @State private var isAddingTask = false
  @State private var editingTask: ScheduledTaskRecord?
  @State private var pendingDeletion: ScheduledTaskRecord?
  @State private var notificationState: NotificationAuthorizationState = .notDetermined
  @State private var errorMessage: String?

  private let notificationService: LocalNotificationService

  public init(
    runner: ForegroundTaskRunner = .shared,
    notificationService: LocalNotificationService = .shared
  ) {
    _runner = State(initialValue: runner)
    self.notificationService = notificationService
  }

  public var body: some View {
    List {
      #if os(macOS)
        Section {
          TextField("Search scheduled tasks", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Search scheduled tasks")
        }
      #endif
      executionLimitationsSection
      notificationSection

      if filteredTasks.isEmpty {
        Section {
          ContentUnavailableView {
            Label(
              emptyTitle,
              systemImage: searchText.isEmpty ? "calendar.badge.plus" : "magnifyingglass")
          } description: {
            Text(emptyDescription)
          } actions: {
            if searchText.isEmpty {
              Button("New Task") {
                isAddingTask = true
              }
              .buttonStyle(.borderedProminent)
              .disabled(enabledModelChoices.isEmpty)
            }
          }
        }
      } else {
        Section("Scheduled prompts") {
          ForEach(filteredTasks) { task in
            ScheduledTaskRow(
              task: task,
              providerDescription: providerDescription(for: task),
              isRunning: runner.isRunning(taskID: task.id),
              onRunNow: { runNow(task) },
              onTogglePause: { togglePause(for: task) },
              onEdit: { editingTask = task },
              onDelete: { pendingDeletion = task }
            )
            .swipeActions(edge: .trailing) {
              Button("Delete", role: .destructive) {
                pendingDeletion = task
              }
              .disabled(runner.isRunning(taskID: task.id))
            }
            .swipeActions(edge: .leading) {
              if task.status == .active || task.status == .paused || task.status == .failed {
                Button(task.status == .active ? "Pause" : "Resume") {
                  togglePause(for: task)
                }
                .tint(task.status == .active ? .orange : .green)
                .disabled(runner.isRunning(taskID: task.id))
              }
            }
          }
          .onDelete(perform: deleteTasks)
        }
      }

      if let lastSweepError = runner.lastSweepError {
        Section("Runner status") {
          Label(lastSweepError, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle("Scheduled Tasks")
    #if os(iOS)
      .searchable(text: $searchText, prompt: "Search scheduled tasks")
    #endif
    .toolbar {
      #if os(iOS)
        ToolbarItem(id: "tasks-edit", placement: .secondaryAction) {
          EditButton()
        }
      #endif
      ToolbarItem(id: "task-add", placement: .primaryAction) {
        Button {
          isAddingTask = true
        } label: {
          Label("New Task", systemImage: "plus")
        }
        .disabled(enabledModelChoices.isEmpty)
        .keyboardShortcut("n", modifiers: [.command, .option])
        .accessibilityHint(
          enabledModelChoices.isEmpty
            ? "Enable a model in Providers before creating a task"
            : "Opens the scheduled task editor")
      }
    }
    .sheet(isPresented: $isAddingTask) {
      ScheduledTaskEditorView(
        task: nil,
        providers: enabledProviders,
        runner: runner,
        notificationService: notificationService
      )
    }
    .sheet(item: $editingTask) { task in
      ScheduledTaskEditorView(
        task: task,
        providers: providersAvailableForEditing(task),
        runner: runner,
        notificationService: notificationService
      )
    }
    .confirmationDialog(
      "Delete this scheduled task?",
      isPresented: deletionDialogIsPresented,
      titleVisibility: .visible,
      presenting: pendingDeletion
    ) { task in
      Button("Delete Task", role: .destructive) {
        delete(task)
      }
      .disabled(runner.isRunning(taskID: task.id))
      Button("Cancel", role: .cancel) {}
    } message: { task in
      Text(
        "“\(displayTitle(for: task))” and its schedule will be removed. Existing result conversations stay in your history."
      )
    }
    .alert("Scheduled tasks couldn’t be updated", isPresented: errorIsPresented) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "Please try again.")
    }
    .task {
      await refreshNotificationStateAndReminders()
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active else { return }
      Task {
        await refreshNotificationStateAndReminders()
      }
    }
  }

  private var executionLimitationsSection: some View {
    Section("How tasks run") {
      Label {
        Text("Turing AI runs due prompts on this device while the app is active.")
      } icon: {
        Image(systemName: "iphone.and.arrow.forward")
      }

      Label {
        Text(
          "iOS can suspend or terminate apps, so Turing AI cannot guarantee an exact background execution time. Turing AI schedules an on-device reminder for the due time; the prompt runs at the next foreground opportunity."
        )
      } icon: {
        Image(systemName: "exclamationmark.shield")
      }
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)

      if enabledModelChoices.isEmpty {
        Label(
          "Enable a model in Providers before creating a task.", systemImage: "person.badge.key"
        )
        .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var notificationSection: some View {
    Section("Task notifications") {
      switch notificationState {
      case .notDetermined:
        Button {
          requestNotificationPermission()
        } label: {
          Label("Enable Task Notifications", systemImage: "bell.badge")
        }
        .accessibilityHint("Shows the system notification permission request")
      case .denied:
        Label(
          "Notifications are off. You can enable them in System Settings.",
          systemImage: "bell.slash"
        )
        .foregroundStyle(.secondary)
      case .authorized, .provisional, .ephemeral:
        Label(
          "Due-time reminders and completion notifications are enabled.",
          systemImage: "bell.badge.fill"
        )
        .foregroundStyle(.secondary)
      }

      Text(
        "Turing AI asks for notification access only when you choose the button above, never when you create a task."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
  }
  private var enabledModelChoices: [ChatModelChoice] {
    ProviderModelStore.choices(providers: providers, models: providerModels)
  }

  private var enabledProviders: [ProviderConfigurationRecord] {
    providers.filter { $0.isEnabled && $0.provider.supportsChat }
  }

  private var filteredTasks: [ScheduledTaskRecord] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return tasks }
    return tasks.filter {
      $0.title.localizedStandardContains(query)
        || $0.prompt.localizedStandardContains(query)
    }
  }

  private var emptyTitle: String {
    searchText.isEmpty ? "No scheduled tasks" : "No matching tasks"
  }

  private var emptyDescription: String {
    searchText.isEmpty
      ? "Create a one-time, daily, or weekly prompt."
      : "Try a different title or phrase."
  }

  private var deletionDialogIsPresented: Binding<Bool> {
    Binding(
      get: { pendingDeletion != nil },
      set: { if !$0 { pendingDeletion = nil } }
    )
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private func providersAvailableForEditing(
    _ task: ScheduledTaskRecord
  ) -> [ProviderConfigurationRecord] {
    providers.filter {
      $0.provider.supportsChat && ($0.isEnabled || $0.id == task.providerConfigurationID)
    }
  }

  private func providerDescription(for task: ScheduledTaskRecord) -> String {
    guard let providerID = task.providerConfigurationID,
      let provider = providers.first(where: { $0.id == providerID })
    else {
      return "Provider unavailable"
    }
    let identifier =
      taskModels.first { $0.taskID == task.id }?.modelIdentifier ?? provider.modelIdentifier
    return "\(identifier) · \(provider.displayName)"
  }

  private func displayTitle(for task: ScheduledTaskRecord) -> String {
    let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Untitled task" : title
  }

  private func runNow(_ task: ScheduledTaskRecord) {
    guard runner.startRunNow(task, in: modelContext) else {
      errorMessage =
        "This task is already running, or Turing AI is finishing another data operation. Try again when it finishes."
      return
    }
  }

  private func togglePause(for task: ScheduledTaskRecord) {
    let now = Date.now
    switch task.status {
    case .active:
      task.status = .paused
    case .paused, .failed:
      task.status = .active
      task.lastError = nil
      if task.recurrence == .once {
        task.nextRunAt = task.scheduledAt > now ? task.scheduledAt : now
      } else {
        task.nextRunAt = ScheduleCalculator().nextDate(
          after: now,
          startingAt: task.scheduledAt,
          recurrence: task.recurrence,
          calendar: calendar(for: task.timeZoneIdentifier)
        )
      }
    case .completed:
      return
    }
    task.updatedAt = now
    if saveChanges() {
      synchronizeReminder(for: task)
    }
  }

  private func deleteTasks(at offsets: IndexSet) {
    guard let offset = offsets.first, filteredTasks.indices.contains(offset) else { return }
    let task = filteredTasks[offset]
    guard !runner.isRunning(taskID: task.id) else { return }
    pendingDeletion = task
  }

  private func calendar(for timeZoneIdentifier: String) -> Calendar {
    var calendar = Calendar.current
    if let timeZone = TimeZone(identifier: timeZoneIdentifier) {
      calendar.timeZone = timeZone
    }
    return calendar
  }

  private func delete(_ task: ScheduledTaskRecord) {
    guard !runner.isRunning(taskID: task.id) else { return }
    let taskID = task.id
    do {
      let id = task.id
      try modelContext.fetch(
        FetchDescriptor<ScheduledTaskModelRecord>(predicate: #Predicate { $0.taskID == id })
      ).forEach(modelContext.delete)
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    modelContext.delete(task)
    pendingDeletion = nil
    if saveChanges() {
      Task {
        await notificationService.cancelTaskReminder(taskID: taskID)
      }
    }
  }

  @discardableResult
  private func saveChanges() -> Bool {
    do {
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
      return true
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func requestNotificationPermission() {
    Task {
      do {
        notificationState = try await notificationService.requestAuthorization()
        let schedules = reminderSchedules
        _ = try await notificationService.reconcileTaskReminders(schedules)
      } catch {
        errorMessage = error.localizedDescription
        notificationState = await notificationService.authorizationState()
      }
    }
  }

  private var reminderSchedules: [ScheduledTaskReminderSchedule] {
    tasks.map(reminderSchedule)
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

  private func synchronizeReminder(for task: ScheduledTaskRecord) {
    let schedule = reminderSchedule(for: task)
    Task {
      do {
        _ = try await notificationService.synchronizeTaskReminder(schedule)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func refreshNotificationStateAndReminders() async {
    notificationState = await notificationService.authorizationState()
    let schedules = reminderSchedules
    do {
      _ = try await notificationService.reconcileTaskReminders(schedules)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

@MainActor
private struct ScheduledTaskRow: View {
  let task: ScheduledTaskRecord
  let providerDescription: String
  let isRunning: Bool
  let onRunNow: () -> Void
  let onTogglePause: () -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button(action: onEdit) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline) {
            Text(displayTitle)
              .font(.headline)
              .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Label(statusText, systemImage: statusSymbol)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Text(task.prompt)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isRunning)
      .accessibilityLabel("Edit \(displayTitle)")
      .accessibilityHint("Opens this scheduled prompt for editing")

      VStack(alignment: .leading, spacing: 5) {
        Label(recurrenceDescription, systemImage: "repeat")
        Label(providerDescription, systemImage: "cpu")
        if task.recurrence != .once {
          Label(task.timeZoneIdentifier, systemImage: "globe")
        }
        if let nextRunAt = task.nextRunAt {
          Label {
            Text(nextRunAt, format: .dateTime.weekday(.abbreviated).day().month().hour().minute())
          } icon: {
            Image(systemName: "clock")
          }
        } else if task.status == .completed {
          Label("No future run", systemImage: "checkmark.circle")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      if !isRunning, let lastError = task.lastError, !lastError.isEmpty {
        Label(lastError, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityLabel("Last run error: \(lastError)")
      }

      HStack(spacing: 12) {
        Button(action: onRunNow) {
          if isRunning {
            Label("Running", systemImage: "hourglass")
          } else {
            Label("Run Now", systemImage: "play.fill")
          }
        }
        .buttonStyle(.bordered)
        .disabled(isRunning)
        .frame(minHeight: 44)
        .accessibilityHint("Runs this prompt immediately on the selected provider")

        Spacer(minLength: 8)

        Menu {
          if task.status == .active || task.status == .paused || task.status == .failed {
            Button(
              task.status == .active ? "Pause" : "Resume",
              systemImage: task.status == .active ? "pause" : "play",
              action: onTogglePause
            )
            .disabled(isRunning)
          }
          Button("Edit", systemImage: "pencil", action: onEdit)
            .disabled(isRunning)
          Divider()
          Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            .disabled(isRunning)
        } label: {
          Label("Task Actions", systemImage: "ellipsis.circle")
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Actions for \(displayTitle)")
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
  }

  private var displayTitle: String {
    let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Untitled task" : title
  }

  private var recurrenceDescription: String {
    switch task.recurrence {
    case .once: "Once"
    case .daily: "Daily"
    case .weekly: "Weekly"
    }
  }

  private var statusText: String {
    if isRunning { return "Running" }
    return switch task.status {
    case .active: "Active"
    case .paused: "Paused"
    case .completed: "Completed"
    case .failed: "Needs attention"
    }
  }

  private var statusSymbol: String {
    if isRunning { return "hourglass" }
    return switch task.status {
    case .active: "calendar.badge.clock"
    case .paused: "pause.circle"
    case .completed: "checkmark.circle"
    case .failed: "exclamationmark.triangle"
    }
  }
}

@MainActor
private struct ScheduledTaskEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  let task: ScheduledTaskRecord?
  let providers: [ProviderConfigurationRecord]
  let runner: ForegroundTaskRunner
  let notificationService: LocalNotificationService

  @State private var title: String
  @State private var prompt: String
  @State private var recurrence: ScheduleRecurrence
  @State private var scheduledAt: Date
  @Query private var providerModels: [ProviderModelRecord]
  @State private var modelIdentifier = ""
  @State private var showModelSelection = false
  @State private var providerID: UUID?
  @State private var persistedTask: ScheduledTaskRecord?
  @State private var errorTitle = "Task couldn’t be saved"
  @State private var errorMessage: String?
  @State private var isSaving = false

  init(
    task: ScheduledTaskRecord?,
    providers: [ProviderConfigurationRecord],
    runner: ForegroundTaskRunner,
    notificationService: LocalNotificationService
  ) {
    self.task = task
    self.providers = providers
    self.runner = runner
    self.notificationService = notificationService
    _title = State(initialValue: task?.title ?? "")
    _prompt = State(initialValue: task?.prompt ?? "")
    _recurrence = State(initialValue: task?.recurrence ?? .once)
    _scheduledAt = State(initialValue: task?.scheduledAt ?? Date.now.addingTimeInterval(300))
    _providerID = State(initialValue: task?.providerConfigurationID ?? providers.first?.id)
    _persistedTask = State(initialValue: task)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Prompt") {
          TextField("Title", text: $title, prompt: Text("Morning briefing"))
          TextEditor(text: $prompt)
            .frame(minHeight: 150)
            .accessibilityLabel("Task prompt")
            .accessibilityHint("Enter the prompt Turing AI will send to the selected provider")
        }

        Section("Schedule") {
          Picker("Repeats", selection: $recurrence) {
            Text("Once").tag(ScheduleRecurrence.once)
            Text("Daily").tag(ScheduleRecurrence.daily)
            Text("Weekly").tag(ScheduleRecurrence.weekly)
          }
          .pickerStyle(.segmented)

          DatePicker(
            datePickerLabel,
            selection: $scheduledAt,
            displayedComponents: [.date, .hourAndMinute]
          )

          Text(scheduleExplanation)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        Section("Model") {
          Button {
            showModelSelection = true
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(modelIdentifier.isEmpty ? "Choose Model" : modelIdentifier)
              if let provider = providers.first(where: { $0.id == providerID }) {
                Text(provider.displayName).font(.caption).foregroundStyle(.secondary)
              }
            }.frame(minHeight: 44)
          }
          Text(
            "Uses this exact model for each run. Enable models in Providers to make them available here."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }

        Section("On-device execution") {
          Label("Runs while Turing AI is active", systemImage: "app.badge.clock")
          Label("Time zone: \(TimeZone.current.identifier)", systemImage: "globe")
          Text(
            "Recurring times stay anchored to this time zone until you edit the task. Saving does not request notification permission. On iOS, the scheduled time is a target for the next foreground opportunity, not a guaranteed background execution deadline."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }
      .navigationTitle(persistedTask == nil ? "New Task" : "Edit Task")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            Task { await save() }
          }
          .disabled(!canSave || isRunning || isSaving)
          .keyboardShortcut(.defaultAction)
        }
      }
      .alert(errorTitle, isPresented: errorIsPresented) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "Please try again.")
      }
    }
    .task {
      guard modelIdentifier.isEmpty else { return }
      if let task, let provider = providers.first(where: { $0.id == providerID }) {
        do {
          modelIdentifier = try ProviderModelStore.taskModel(
            taskID: task.id, provider: provider, in: modelContext)
        } catch { errorMessage = error.localizedDescription }
      } else if let choice = ProviderModelStore.choices(
        providers: providers, models: providerModels
      ).first {
        providerID = choice.providerID
        modelIdentifier = choice.modelIdentifier
      }
    }
    .sheet(isPresented: $showModelSelection) {
      ChatModelSelectionView(
        choices: ProviderModelStore.choices(providers: providers, models: providerModels),
        selectedID: providerID.map {
          ProviderModelRecord.key(providerID: $0, model: modelIdentifier)
        }
      ) { choice in
        providerID = choice.providerID
        modelIdentifier = choice.modelIdentifier
      }
    }
  }

  private var canSave: Bool {
    !trimmedTitle.isEmpty && !trimmedPrompt.isEmpty
      && ProviderModelStore.choices(providers: providers, models: providerModels).contains {
        $0.providerID == providerID && $0.modelIdentifier == modelIdentifier
      }
  }

  private var isRunning: Bool {
    guard let task = persistedTask ?? task else { return false }
    return runner.isRunning(taskID: task.id)
  }

  private var trimmedTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedPrompt: String {
    prompt.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var datePickerLabel: String {
    switch recurrence {
    case .once: "Run date"
    case .daily: "Start date and time"
    case .weekly: "Weekday and time"
    }
  }

  private var scheduleExplanation: String {
    if let task = persistedTask ?? task,
      task.status == .completed || task.status == .failed,
      task.recurrence == recurrence, task.scheduledAt == scheduledAt
    {
      return
        "Editing the title or prompt keeps this task’s current status. Change the schedule to run it again automatically, or use Run Now."
    }
    return switch recurrence {
    case .once:
      "Runs once at the next foreground opportunity on or after this time."
    case .daily:
      "Runs every day at this local time while Turing AI is active."
    case .weekly:
      "Runs every week on this weekday and local time while Turing AI is active."
    }
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private func save() async {
    guard canSave, !isRunning, !isSaving else { return }
    isSaving = true
    defer { isSaving = false }
    let now = Date.now
    let nextRunAt: Date?
    if recurrence == .once {
      nextRunAt = scheduledAt
    } else {
      nextRunAt = ScheduleCalculator().nextDate(
        after: now,
        startingAt: scheduledAt,
        recurrence: recurrence
      )
    }

    let savedTask: ScheduledTaskRecord
    if let task = persistedTask ?? task {
      task.title = trimmedTitle
      task.prompt = trimmedPrompt
      task.providerConfigurationID = providerID
      task.updateSchedule(recurrence: recurrence, scheduledAt: scheduledAt, now: now)
      task.updatedAt = now
      savedTask = task
    } else {
      let task = ScheduledTaskRecord(
        title: trimmedTitle,
        prompt: trimmedPrompt,
        providerConfigurationID: providerID,
        recurrence: recurrence,
        status: .active,
        scheduledAt: scheduledAt,
        timeZoneIdentifier: TimeZone.current.identifier,
        nextRunAt: nextRunAt
      )
      modelContext.insert(task)
      savedTask = task
    }

    do {
      guard let providerID else { throw ProviderModelSelectionError.unavailable }
      try ProviderModelStore.setTaskModel(
        taskID: savedTask.id, providerID: providerID,
        modelIdentifier: modelIdentifier, in: modelContext)
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
      persistedTask = savedTask
      let schedule = ScheduledTaskReminderSchedule(
        taskID: savedTask.id,
        taskTitle: savedTask.title,
        status: savedTask.status,
        nextRunAt: savedTask.nextRunAt,
        timeZoneIdentifier: savedTask.timeZoneIdentifier
      )
      do {
        _ = try await notificationService.synchronizeTaskReminder(schedule)
        dismiss()
      } catch {
        errorTitle = "Task reminder couldn’t be updated"
        errorMessage =
          "The task was saved, but its on-device reminder could not be scheduled. \(error.localizedDescription)"
      }
    } catch {
      modelContext.rollback()
      errorTitle = "Task couldn’t be saved"
      errorMessage = error.localizedDescription
    }
  }
}

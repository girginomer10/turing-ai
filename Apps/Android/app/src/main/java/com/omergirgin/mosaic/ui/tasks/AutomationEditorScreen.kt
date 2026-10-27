package com.omergirgin.mosaic.ui.tasks

import android.text.format.DateFormat
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Event
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.HourglassTop
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.omergirgin.mosaic.core.scheduling.ScheduleCalculator
import com.omergirgin.mosaic.core.scheduling.ScheduleRecurrence
import com.omergirgin.mosaic.core.scheduling.TaskSchedule
import com.omergirgin.mosaic.data.api.AppContainer
import com.omergirgin.mosaic.data.model.ModelChoice
import com.omergirgin.mosaic.data.model.ModelOption
import com.omergirgin.mosaic.data.tasks.ScheduledTask
import com.omergirgin.mosaic.data.tasks.ScheduledTaskDraft
import com.omergirgin.mosaic.data.tasks.ScheduledTaskRun
import com.omergirgin.mosaic.data.tasks.ScheduledTaskStatus
import com.omergirgin.mosaic.data.tasks.TaskRunStatus
import com.omergirgin.mosaic.data.tasks.TaskRunTrigger
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.components.relativeTime
import com.omergirgin.mosaic.ui.components.userMessage
import com.omergirgin.mosaic.ui.settings.Choice
import com.omergirgin.mosaic.ui.settings.DiscardChangesDialog
import com.omergirgin.mosaic.ui.settings.EmptyState
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.SearchableChoiceDialog
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsLinkRow
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import com.omergirgin.mosaic.ui.settings.StatusLine
import com.omergirgin.mosaic.ui.settings.StatusTone
import com.omergirgin.mosaic.ui.settings.utf8Size
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.Date
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** iOS MosaicSourceFieldLimits: the title is stored like a chat title, the prompt like a message. */
private const val MAX_TITLE_BYTES = 16 * 1_024
private const val MAX_PROMPT_BYTES = 512 * 1_024

/** The schedule as edited (device-local wall time); compared to detect a real re-schedule. */
private data class ScheduleFields(
  val recurrence: ScheduleRecurrence,
  val date: LocalDate,
  val time: LocalTime,
  val weekdays: Set<DayOfWeek>,
)

internal class AutomationEditorViewModel(private val container: AppContainer, val taskId: String?) : ViewModel() {
  var isLoading by mutableStateOf(taskId != null)
    private set
  var notFound by mutableStateOf(false)
    private set
  var title by mutableStateOf("")
  var prompt by mutableStateOf("")
  var recurrence by mutableStateOf(ScheduleRecurrence.ONCE)
  var date by mutableStateOf(LocalDate.now())
  var time by mutableStateOf(defaultTime())
  var weekdays by mutableStateOf(setOf(LocalDate.now().dayOfWeek))
  var model by mutableStateOf<ModelChoice?>(null)
  var projectId by mutableStateOf<String?>(null)
  var isSaving by mutableStateOf(false)
    private set
  var saved by mutableStateOf(false)
    private set
  var errorMessage by mutableStateOf<String?>(null)

  var original by mutableStateOf<ScheduledTask?>(null)
    private set
  private var originalFields: ScheduleFields? = null

  val runs: Flow<List<ScheduledTaskRun>> = taskId?.let { container.tasks.observeRuns(it, limit = 10) } ?: emptyFlow()

  init {
    viewModelScope.launch {
      try {
        if (taskId != null) {
          val task = container.tasks.observeTask(taskId).first()
          if (task == null) notFound = true else load(task)
        } else {
          // Same default chain as a new chat: app default, then most recent, then first enabled.
          val options = container.providers.observeModelOptions().first()
          val settings = container.settings.settings.first()
          model = sequenceOf(settings.defaultModel)
            .plus(settings.recentModels)
            .firstOrNull { choice -> choice != null && options.any { it.choice == choice } }
            ?: options.firstOrNull()?.choice
          if (date == LocalDate.now() && time <= LocalTime.now()) date = date.plusDays(1)
        }
      } catch (error: CancellationException) {
        throw error
      } catch (error: Exception) {
        errorMessage = "The automation couldn't be loaded. ${error.userMessage()}"
      } finally {
        isLoading = false
      }
    }
  }

  private fun load(task: ScheduledTask) {
    original = task
    title = task.title
    prompt = task.prompt
    model = task.model
    projectId = task.projectId
    recurrence = task.recurrence
    val local = Instant.ofEpochMilli(task.schedule.startAt).atZone(ZoneId.systemDefault())
    date = local.toLocalDate()
    time = local.toLocalTime().withSecond(0).withNano(0)
    weekdays = if (task.recurrence == ScheduleRecurrence.WEEKLY) ScheduleCalculator.runDays(task.schedule) else setOf(local.dayOfWeek)
    originalFields = currentFields()
  }

  private fun currentFields() = ScheduleFields(recurrence, date, time, weekdays)

  /** Only a real schedule edit re-anchors the task (iOS `updateSchedule`). */
  val scheduleChanged: Boolean get() = originalFields == null || currentFields() != originalFields

  /** The schedule as it would be saved now. */
  val schedule: TaskSchedule
    get() {
      val existing = original
      if (existing != null && !scheduleChanged) return existing.schedule
      val zone = deviceZoneId()
      val anchorDate = if (recurrence == ScheduleRecurrence.ONCE) date else LocalDate.now()
      return TaskSchedule(
        recurrence = recurrence,
        startAt = ScheduleCalculator.instantOf(anchorDate, time, zone),
        timeZoneId = zone,
        weekdays = if (recurrence == ScheduleRecurrence.WEEKLY) weekdays else emptySet(),
      )
    }

  fun validationIssue(options: List<ModelOption>): String? = when {
    title.isBlank() -> "Enter a title."
    prompt.isBlank() -> "Enter the prompt to send."
    utf8Size(title.trim()) > MAX_TITLE_BYTES -> "The title is too long."
    utf8Size(prompt.trim()) > MAX_PROMPT_BYTES -> "The prompt is too long (the limit is 512 KB)."
    model == null || options.none { it.choice == model } -> "Choose an enabled model."
    recurrence == ScheduleRecurrence.WEEKLY && weekdays.isEmpty() -> "Choose at least one weekday."
    recurrence == ScheduleRecurrence.ONCE && scheduleChanged && schedule.startAt <= System.currentTimeMillis() ->
      "Choose a time in the future, or use Run now."
    else -> null
  }

  val isDirty: Boolean
    get() {
      val task = original ?: return title.isNotBlank() || prompt.isNotBlank()
      return title != task.title || prompt != task.prompt || model != task.model || projectId != task.projectId || scheduleChanged
    }

  fun save(options: List<ModelOption>) {
    validationIssue(options)?.let {
      errorMessage = it
      return
    }
    if (isSaving) return
    val choice = model ?: return
    val plan = schedule
    val draft = ScheduledTaskDraft(
      id = taskId,
      title = title.trim(),
      prompt = prompt.trim(),
      recurrence = plan.recurrence,
      startAt = plan.startAt,
      weekdays = if (plan.recurrence == ScheduleRecurrence.WEEKLY) ScheduleCalculator.runDays(plan) else emptySet(),
      timeZoneId = plan.timeZoneId,
      model = choice,
      projectId = projectId,
    )
    isSaving = true
    viewModelScope.launch {
      try {
        withContext(NonCancellable) { container.tasks.save(draft) }
        saved = true
      } catch (error: CancellationException) {
        throw error
      } catch (error: Exception) {
        errorMessage = error.userMessage()
      } finally {
        isSaving = false
      }
    }
  }

  private companion object {
    /** The next full hour: a sensible first suggestion that is always in the future. */
    fun defaultTime(): LocalTime = LocalTime.now().withMinute(0).withSecond(0).withNano(0).plusHours(1)
  }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
internal fun AutomationEditorScreen(
  taskId: String?,
  onBack: () -> Unit,
  onOpenConversation: (conversationId: String) -> Unit,
) {
  val container = LocalAppContainer.current
  val context = LocalContext.current
  val vm: AutomationEditorViewModel = viewModel { AutomationEditorViewModel(container, taskId) }
  val modelOptions by remember(container) { container.providers.observeModelOptions() }
    .collectAsStateWithLifecycle(initialValue = emptyList())
  val projects by remember(container) { container.projects.observeProjects(includeArchived = true) }
    .collectAsStateWithLifecycle(initialValue = emptyList())
  val activity by remember(container) { container.tasks.activity }.collectAsStateWithLifecycle(initialValue = emptyMap())
  val runs by remember(vm) { vm.runs }.collectAsStateWithLifecycle(initialValue = emptyList())
  var choosingModel by rememberSaveable { mutableStateOf(false) }
  var choosingProject by rememberSaveable { mutableStateOf(false) }
  var choosingDate by rememberSaveable { mutableStateOf(false) }
  var choosingTime by rememberSaveable { mutableStateOf(false) }
  var confirmDiscard by rememberSaveable { mutableStateOf(false) }
  val isRunning = taskId != null && activity[taskId] != null
  val issue = vm.validationIssue(modelOptions)

  LaunchedEffect(vm.saved) { if (vm.saved) onBack() }

  val requestBack: () -> Unit = {
    if (!vm.isSaving) {
      if (vm.isDirty) confirmDiscard = true else onBack()
    }
  }
  BackHandler(enabled = vm.isSaving || vm.isDirty) { requestBack() }

  SettingsScaffold(
    title = if (taskId == null) "New automation" else "Edit automation",
    onBack = requestBack,
    actions = {
      if (vm.isSaving) {
        CircularProgressIndicator(Modifier.padding(horizontal = 16.dp).size(24.dp), strokeWidth = 2.dp)
      } else if (!vm.isLoading && !vm.notFound) {
        TextButton(onClick = { vm.save(modelOptions) }, enabled = issue == null && !isRunning) { Text("Save") }
      }
    },
  ) { padding ->
    when {
      vm.isLoading -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
      }
      vm.notFound -> EmptyState(
        title = "Automation not found",
        message = "This automation was deleted.",
        modifier = Modifier.padding(padding),
      ) { OutlinedButton(onClick = onBack) { Text("Go back") } }
      else -> Column(
        Modifier
          .padding(padding)
          .fillMaxSize()
          .imePadding()
          .verticalScroll(rememberScrollState())
          .padding(bottom = 32.dp),
      ) {
        if (isRunning) StatusLine("This automation is running. You can save changes when it finishes.", StatusTone.NEUTRAL)

        SectionHeader("Prompt")
        OutlinedTextField(
          value = vm.title,
          onValueChange = { vm.title = it },
          label = { Text("Title") },
          placeholder = { Text("Morning briefing") },
          singleLine = true,
          keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Next),
          modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        )
        OutlinedTextField(
          value = vm.prompt,
          onValueChange = { vm.prompt = it },
          label = { Text("Prompt") },
          placeholder = { Text("Summarize what I should focus on today.") },
          supportingText = { Text("Sent as the first message of a new chat each time this automation runs.") },
          minLines = 5,
          keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
          modifier = Modifier.fillMaxWidth().heightIn(min = 140.dp).padding(horizontal = 16.dp, vertical = 4.dp),
        )

        SectionHeader("Schedule")
        val recurrences = ScheduleRecurrence.entries
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
          recurrences.forEachIndexed { index, option ->
            SegmentedButton(
              selected = vm.recurrence == option,
              onClick = { vm.recurrence = option },
              shape = SegmentedButtonDefaults.itemShape(index, recurrences.size),
            ) {
              Text(
                when (option) {
                  ScheduleRecurrence.ONCE -> "Once"
                  ScheduleRecurrence.DAILY -> "Daily"
                  ScheduleRecurrence.WEEKLY -> "Weekly"
                }
              )
            }
          }
        }
        if (vm.recurrence == ScheduleRecurrence.ONCE) {
          SettingsLinkRow(
            title = "Date",
            subtitle = DateFormat.getLongDateFormat(context)
              .format(Date(vm.date.atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli())),
            icon = Icons.Outlined.Event,
            onClick = { choosingDate = true },
          )
        }
        if (vm.recurrence == ScheduleRecurrence.WEEKLY) {
          FlowRow(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
          ) {
            localeWeekdays().forEach { day ->
              val selected = day in vm.weekdays
              FilterChip(
                selected = selected,
                onClick = { vm.weekdays = if (selected) vm.weekdays - day else vm.weekdays + day },
                label = { Text(day.shortLabel()) },
              )
            }
          }
        }
        SettingsLinkRow(
          title = "Time",
          subtitle = DateFormat.getTimeFormat(context)
            .format(Date(vm.date.atTime(vm.time).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli())),
          icon = Icons.Outlined.Schedule,
          onClick = { choosingTime = true },
        )
        ScheduleExplanation(vm)

        SectionHeader("Model")
        SettingsLinkRow(
          title = "Model",
          subtitle = modelLabel(vm.model, modelOptions),
          icon = Icons.Outlined.Memory,
          onClick = { choosingModel = true },
        )
        val savedModel = vm.model
        if (savedModel != null && modelOptions.isNotEmpty() && modelOptions.none { it.choice == savedModel }) {
          StatusLine(
            "The saved model (${savedModel.modelId}) is no longer enabled, so this automation can't run. Choose another model.",
            StatusTone.WARNING,
          )
        }
        SectionFooter("Every run uses this exact model. Turing AI never switches to another model on its own.")

        SectionHeader("Project")
        val project = vm.projectId?.let { id -> projects.firstOrNull { it.id == id } }
        SettingsLinkRow(
          title = "Project",
          subtitle = when {
            vm.projectId == null -> "No project"
            project == null -> "Deleted project · choose another"
            project.isArchived -> "${project.name} (archived)"
            else -> project.name
          },
          icon = Icons.Outlined.Folder,
          onClick = { choosingProject = true },
        )
        SectionFooter(
          "Result chats are created in this project and use its instructions and project memory. " +
            "Without a project they use only memory marked Everywhere.",
        )

        SectionHeader("How it runs")
        ListItem(
          leadingContent = { Icon(Icons.Outlined.PhoneAndroid, contentDescription = null) },
          headlineContent = { Text("On-device run") },
          supportingContent = {
            Text(
              "Runs on this phone with your key for the chosen service. Android may delay background runs, but " +
                "never starts them early. Saving doesn't ask for notification access.",
            )
          },
        )

        if (issue != null && vm.isDirty) StatusLine("To save: $issue", StatusTone.NEUTRAL)

        if (taskId != null && runs.isNotEmpty()) {
          SectionHeader("Recent runs")
          runs.forEach { run -> RunRow(run, onOpenConversation) }
        }
      }
    }
  }

  if (choosingModel) {
    SearchableChoiceDialog(
      title = "Model",
      choices = modelOptions.map { option ->
        Choice(
          key = option.choice.providerId + "\u0000" + option.choice.modelId,
          value = option.choice,
          title = option.modelId,
          subtitle = option.providerName,
        )
      },
      selectedKey = vm.model?.let { it.providerId + "\u0000" + it.modelId },
      onSelect = {
        vm.model = it
        choosingModel = false
      },
      onDismiss = { choosingModel = false },
      searchLabel = "Search models or services",
      emptyMessage = "No models are enabled yet. Enable models in AI models & accounts.",
    )
  }
  if (choosingProject) {
    val noProject = Choice<String?>(key = "none", value = null, title = "No project", subtitle = "General memory only")
    SearchableChoiceDialog(
      title = "Project",
      choices = listOf(noProject) + projects.filterNot { it.isArchived }.map { Choice<String?>(it.id, it.id, it.name) },
      selectedKey = vm.projectId ?: "none",
      onSelect = {
        vm.projectId = it
        choosingProject = false
      },
      onDismiss = { choosingProject = false },
      searchLabel = "Search projects",
    )
  }
  if (choosingDate) {
    val today = LocalDate.now()
    val state = rememberDatePickerState(
      initialSelectedDateMillis = vm.date.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
      selectableDates = object : SelectableDates {
        override fun isSelectableDate(utcTimeMillis: Long): Boolean =
          !Instant.ofEpochMilli(utcTimeMillis).atZone(ZoneOffset.UTC).toLocalDate().isBefore(today)

        override fun isSelectableYear(year: Int): Boolean = year >= today.year
      },
    )
    DatePickerDialog(
      onDismissRequest = { choosingDate = false },
      confirmButton = {
        TextButton(
          onClick = {
            state.selectedDateMillis?.let { vm.date = Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate() }
            choosingDate = false
          },
        ) { Text("OK") }
      },
      dismissButton = { TextButton(onClick = { choosingDate = false }) { Text("Cancel") } },
    ) { DatePicker(state = state) }
  }
  if (choosingTime) {
    val state = rememberTimePickerState(
      initialHour = vm.time.hour,
      initialMinute = vm.time.minute,
      is24Hour = DateFormat.is24HourFormat(context),
    )
    AlertDialog(
      onDismissRequest = { choosingTime = false },
      title = { Text("Time") },
      text = { TimePicker(state = state) },
      confirmButton = {
        TextButton(
          onClick = {
            vm.time = LocalTime.of(state.hour, state.minute)
            choosingTime = false
          },
        ) { Text("OK") }
      },
      dismissButton = { TextButton(onClick = { choosingTime = false }) { Text("Cancel") } },
    )
  }
  if (confirmDiscard) {
    DiscardChangesDialog(
      message = "Your changes to this automation haven't been saved.",
      onDiscard = {
        confirmDiscard = false
        onBack()
      },
      onKeepEditing = { confirmDiscard = false },
    )
  }
  vm.errorMessage?.let { MessageDialog("Automation couldn't be saved", it) { vm.errorMessage = null } }
}

@Composable
private fun ScheduleExplanation(vm: AutomationEditorViewModel) {
  val context = LocalContext.current
  val existing = vm.original
  val device = deviceZoneId()
  val text = when {
    existing != null && !vm.scheduleChanged &&
      (existing.status == ScheduledTaskStatus.COMPLETED || existing.status == ScheduledTaskStatus.FAILED) ->
      "Editing the title, prompt, model or project keeps this automation's current status. Change the schedule to " +
        "run it again automatically, or use Run now."
    vm.recurrence == ScheduleRecurrence.ONCE -> "Runs once at this time, or as soon as Android allows after it."
    vm.recurrence == ScheduleRecurrence.DAILY -> "Runs every day at this local time."
    else -> "Runs every week on the chosen days at this local time."
  }
  SectionFooter(text)

  val schedule = vm.schedule
  val zone = ScheduleCalculator.zoneOf(schedule.timeZoneId).id
  if (existing != null && !vm.scheduleChanged && zone != device) {
    StatusLine(
      "Saved as ${scheduleSummary(context, schedule)}. Changing the schedule anchors it to this device's time zone ($device).",
      StatusTone.NEUTRAL,
    )
  } else {
    SectionFooter("Time zone: $zone. Recurring times stay anchored to it until you change the schedule, even when you travel.")
  }
  if (existing == null || vm.scheduleChanged) {
    val next = ScheduleCalculator.initialNextRun(schedule, System.currentTimeMillis())
    if (next != null && next > System.currentTimeMillis()) {
      SectionFooter("First run: ${deviceDateTime(context, next)}")
    }
  }
}

@Composable
private fun RunRow(run: ScheduledTaskRun, onOpenConversation: (String) -> Unit) {
  val (icon, label) = when (run.status) {
    TaskRunStatus.RUNNING -> Icons.Outlined.HourglassTop to "Running"
    TaskRunStatus.SUCCEEDED -> Icons.Outlined.CheckCircle to "Finished"
    TaskRunStatus.FAILED -> Icons.Outlined.ErrorOutline to "Failed"
    TaskRunStatus.INTERRUPTED -> Icons.Outlined.ErrorOutline to "Interrupted"
  }
  val trigger = if (run.trigger == TaskRunTrigger.MANUAL) "Run now" else "Scheduled"
  val conversationId = run.conversationId
  ListItem(
    leadingContent = {
      Icon(
        icon,
        contentDescription = null,
        tint = if (run.status == TaskRunStatus.FAILED || run.status == TaskRunStatus.INTERRUPTED) {
          MaterialTheme.colorScheme.error
        } else {
          MaterialTheme.colorScheme.onSurfaceVariant
        },
      )
    },
    headlineContent = { Text("$label · $trigger · ${relativeTime(run.startedAt)}") },
    supportingContent = run.errorMessage?.let { { Text(it, maxLines = 3) } },
    trailingContent = if (conversationId != null) {
      { Text("Open", color = MaterialTheme.colorScheme.primary) }
    } else null,
    modifier = if (conversationId != null) {
      Modifier.clickable(role = Role.Button, onClickLabel = "Open result chat") { onOpenConversation(conversationId) }
    } else Modifier,
  )
}

package com.omergirgin.mosaic.ui.tasks

import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Pause
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.omergirgin.mosaic.core.scheduling.ScheduleRecurrence
import com.omergirgin.mosaic.data.api.AppContainer
import com.omergirgin.mosaic.data.model.ModelOption
import com.omergirgin.mosaic.data.model.Project
import com.omergirgin.mosaic.data.tasks.ScheduledTask
import com.omergirgin.mosaic.data.tasks.ScheduledTaskNotifications
import com.omergirgin.mosaic.data.tasks.ScheduledTaskStatus
import com.omergirgin.mosaic.data.tasks.TaskActivity
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.components.relativeTime
import com.omergirgin.mosaic.ui.components.userMessage
import com.omergirgin.mosaic.ui.settings.ConfirmDialog
import com.omergirgin.mosaic.ui.settings.EmptyState
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsParagraph
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import com.omergirgin.mosaic.ui.settings.StatusLine
import com.omergirgin.mosaic.ui.settings.StatusTone
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal class AutomationsViewModel(private val container: AppContainer) : ViewModel() {
  private val repository = container.tasks

  /** null until the first emission, so the UI can tell "loading" from "none". */
  val tasks: StateFlow<List<ScheduledTask>?> = repository.observeTasks()
    .map { list -> list.sortedWith(displayOrder) }
    .catch { error ->
      errorMessage = "Turing AI couldn't load your automations. ${error.userMessage()}"
      emit(emptyList())
    }
    .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

  val activity: StateFlow<Map<String, TaskActivity>> = repository.activity
    .catch { emit(emptyMap()) }
    .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyMap())

  val modelOptions: StateFlow<List<ModelOption>> = container.providers.observeModelOptions()
    .catch { emit(emptyList()) }
    .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

  val projects: StateFlow<List<Project>> = container.projects.observeProjects(includeArchived = true)
    .catch { emit(emptyList()) }
    .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

  var errorMessage by mutableStateOf<String?>(null)

  /** Returns false (with a message) when the task is already queued or running. */
  fun runNow(task: ScheduledTask): Boolean = try {
    repository.runNow(task.id).also { started ->
      if (!started) errorMessage = "This automation is already running. Try again when it finishes."
    }
  } catch (error: Exception) {
    errorMessage = error.userMessage()
    false
  }

  fun setPaused(task: ScheduledTask, paused: Boolean) = mutate { repository.setPaused(task.id, paused) }

  fun delete(task: ScheduledTask) = mutate { repository.delete(task.id) }

  private fun mutate(action: suspend () -> Unit) {
    viewModelScope.launch {
      try {
        withContext(NonCancellable) { action() }
      } catch (error: CancellationException) {
        throw error
      } catch (error: Exception) {
        errorMessage = error.userMessage()
      }
    }
  }

  private companion object {
    fun rank(status: ScheduledTaskStatus) = when (status) {
      ScheduledTaskStatus.FAILED -> 0
      ScheduledTaskStatus.ACTIVE -> 1
      ScheduledTaskStatus.PAUSED -> 2
      ScheduledTaskStatus.COMPLETED -> 3
    }

    val displayOrder: Comparator<ScheduledTask> = compareBy<ScheduledTask> { rank(it.status) }
      .thenBy { it.nextRunAt ?: Long.MAX_VALUE }
      .thenByDescending { it.updatedAt }
  }
}

@Composable
internal fun AutomationsScreen(
  onBack: () -> Unit,
  onCreate: () -> Unit,
  onEdit: (taskId: String) -> Unit,
  onOpenConversation: (conversationId: String) -> Unit,
  onOpenProviders: () -> Unit,
) {
  val container = LocalAppContainer.current
  val vm: AutomationsViewModel = viewModel { AutomationsViewModel(container) }
  val tasks by vm.tasks.collectAsStateWithLifecycle()
  val activity by vm.activity.collectAsStateWithLifecycle()
  val modelOptions by vm.modelOptions.collectAsStateWithLifecycle()
  val projects by vm.projects.collectAsStateWithLifecycle()
  val background = rememberOnResume(::readBackgroundRunStatus)
  val canNotify = rememberOnResume(ScheduledTaskNotifications::canNotify)
  val snackbar = remember { SnackbarHostState() }
  val scope = rememberCoroutineScope()
  var pendingDeletion by remember { mutableStateOf<ScheduledTask?>(null) }
  val hasModels = modelOptions.isNotEmpty()

  SettingsScaffold(
    title = "Automations",
    onBack = onBack,
    snackbarHostState = snackbar,
    floatingActionButton = {
      if (hasModels && !tasks.isNullOrEmpty()) {
        ExtendedFloatingActionButton(
          onClick = onCreate,
          icon = { Icon(Icons.Outlined.Add, contentDescription = null) },
          text = { Text("New automation") },
        )
      }
    },
  ) { padding ->
    val list = tasks
    if (list == null) {
      Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
      return@SettingsScaffold
    }
    LazyColumn(
      modifier = Modifier.fillMaxSize().padding(padding),
      contentPadding = PaddingValues(bottom = 96.dp),
    ) {
      item(key = "how-header") { SectionHeader("How automations run") }
      item(key = "on-device") {
        ListItem(
          leadingContent = { Icon(Icons.Outlined.PhoneAndroid, contentDescription = null) },
          headlineContent = { Text("On-device runs") },
          supportingContent = {
            Text(
              "Each prompt is sent from this phone to the model you chose, with your own key, and the reply is " +
                "saved as a new chat. There is no cloud runner. Background runs wait for an internet connection; " +
                "while Turing AI is open, due prompts run within about 30 seconds.",
            )
          },
        )
      }
      item(key = "background") { BackgroundRunStatusSection(background) }

      item(key = "notifications-header") { SectionHeader("Notifications") }
      item(key = "notifications") { NotificationAccessSection(canNotify) }

      item(key = "tasks-header") { SectionHeader("Scheduled prompts") }
      if (!hasModels) {
        item(key = "no-models") {
          StatusLine("Enable a model in AI models & accounts before creating an automation.", StatusTone.WARNING)
          TextButton(onClick = onOpenProviders, modifier = Modifier.padding(horizontal = 8.dp)) { Text("AI models & accounts") }
        }
      }
      if (list.isEmpty()) {
        item(key = "empty") {
          EmptyState(
            title = "No automations yet",
            message = "Create a one-time, daily or weekly prompt. It runs on this device with the exact model you choose.",
            icon = Icons.Outlined.CalendarMonth,
            modifier = Modifier.padding(vertical = 8.dp),
          ) {
            Button(onClick = onCreate, enabled = hasModels) { Text("New automation") }
          }
        }
      }
      items(list, key = { it.id }) { task ->
        AutomationCard(
          task = task,
          activity = activity[task.id],
          modelOptions = modelOptions,
          projects = projects,
          onEdit = { onEdit(task.id) },
          onRunNow = {
            if (vm.runNow(task)) {
              scope.launch {
                snackbar.showSnackbar("“${task.title}” is starting. It keeps running if you leave the app.")
              }
            }
          },
          onTogglePause = { vm.setPaused(task, paused = task.status == ScheduledTaskStatus.ACTIVE) },
          onDelete = { pendingDeletion = task },
          onOpenResult = { id -> onOpenConversation(id) },
        )
      }
    }
  }

  pendingDeletion?.let { task ->
    ConfirmDialog(
      title = "Delete this automation?",
      message = "“${task.title}” and its schedule will be removed. Existing result chats stay in your history.",
      confirmLabel = "Delete",
      onConfirm = {
        pendingDeletion = null
        vm.delete(task)
      },
      onDismiss = { pendingDeletion = null },
    )
  }
  vm.errorMessage?.let { MessageDialog("Automation couldn't be updated", it) { vm.errorMessage = null } }
}

@Composable
private fun AutomationCard(
  task: ScheduledTask,
  activity: TaskActivity?,
  modelOptions: List<ModelOption>,
  projects: List<Project>,
  onEdit: () -> Unit,
  onRunNow: () -> Unit,
  onTogglePause: () -> Unit,
  onDelete: () -> Unit,
  onOpenResult: (String) -> Unit,
) {
  val context = LocalContext.current
  val busy = activity != null
  val now = System.currentTimeMillis()
  var menuOpen by remember { mutableStateOf(false) }
  val project = task.projectId?.let { id -> projects.firstOrNull { it.id == id } }

  OutlinedCard(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)) {
    Column(
      Modifier
        .fillMaxWidth()
        .clickable(enabled = !busy, role = Role.Button, onClickLabel = "Edit automation", onClick = onEdit)
        .padding(start = 16.dp, top = 12.dp, end = 4.dp),
    ) {
      Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
          Text(task.title, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
          Text(
            statusLabel(task, activity) + " · On-device run",
            style = MaterialTheme.typography.labelMedium,
            color = when {
              busy -> MaterialTheme.colorScheme.primary
              task.status == ScheduledTaskStatus.FAILED -> MaterialTheme.colorScheme.error
              else -> MaterialTheme.colorScheme.onSurfaceVariant
            },
          )
        }
        Box {
          IconButton(onClick = { menuOpen = true }, modifier = Modifier.semantics { contentDescription = "Actions for ${task.title}" }) {
            Icon(Icons.Outlined.MoreVert, contentDescription = null)
          }
          DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            if (task.status == ScheduledTaskStatus.ACTIVE) {
              DropdownMenuItem(
                text = { Text("Pause") },
                leadingIcon = { Icon(Icons.Outlined.Pause, contentDescription = null) },
                enabled = !busy,
                onClick = { menuOpen = false; onTogglePause() },
              )
            } else if (task.canResume(now)) {
              DropdownMenuItem(
                text = { Text("Resume") },
                leadingIcon = { Icon(Icons.Outlined.PlayArrow, contentDescription = null) },
                enabled = !busy,
                onClick = { menuOpen = false; onTogglePause() },
              )
            }
            DropdownMenuItem(
              text = { Text("Edit") },
              leadingIcon = { Icon(Icons.Outlined.Edit, contentDescription = null) },
              enabled = !busy,
              onClick = { menuOpen = false; onEdit() },
            )
            DropdownMenuItem(
              text = { Text("Delete") },
              leadingIcon = { Icon(Icons.Outlined.Delete, contentDescription = null) },
              enabled = activity != TaskActivity.RUNNING,
              onClick = { menuOpen = false; onDelete() },
            )
          }
        }
      }
      Text(
        task.prompt,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 3,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.padding(top = 6.dp, end = 12.dp),
      )
      Column(Modifier.padding(top = 8.dp, end = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        DetailLine(Icons.Outlined.Schedule, scheduleSummary(context, task.schedule))
        DetailLine(Icons.Outlined.Memory, modelLabel(task.model, modelOptions))
        if (task.projectId != null) {
          DetailLine(
            Icons.Outlined.Folder,
            when {
              project == null -> "Project deleted · edit to choose another"
              project.isArchived -> "${project.name} (archived)"
              else -> project.name
            },
          )
        }
        DetailLine(Icons.Outlined.CalendarMonth, nextRunText(context, task, now))
        task.lastRunAt?.let { DetailLine(null, "Last run ${relativeTime(it, now)}") }
      }
    }
    if (!busy) {
      task.lastError?.takeIf { it.isNotBlank() }?.let { StatusLine(it, StatusTone.ERROR) }
      if (task.status == ScheduledTaskStatus.FAILED && task.recurrence == ScheduleRecurrence.ONCE) {
        SettingsParagraph(
          "One-time prompts are never retried automatically, because the request may already have been sent. " +
            "Use Run now, or edit the time.",
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
      }
    }
    Row(
      Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 4.dp, bottom = 8.dp),
      verticalAlignment = Alignment.CenterVertically,
    ) {
      OutlinedButton(onClick = onRunNow, enabled = !busy) {
        if (busy) {
          CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
          Spacer(Modifier.width(8.dp))
          Text(if (activity == TaskActivity.RUNNING) "Running" else "Starting")
        } else {
          Icon(Icons.Outlined.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
          Spacer(Modifier.width(6.dp))
          Text("Run now")
        }
      }
      Spacer(Modifier.weight(1f))
      task.lastConversationId?.let { conversationId ->
        TextButton(onClick = { onOpenResult(conversationId) }) {
          Text("Open result")
          Spacer(Modifier.width(4.dp))
          Icon(Icons.AutoMirrored.Outlined.OpenInNew, contentDescription = null, modifier = Modifier.size(16.dp))
        }
      }
    }
  }
}

@Composable
private fun DetailLine(icon: ImageVector?, text: String) {
  Row(verticalAlignment = Alignment.CenterVertically) {
    if (icon != null) {
      Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
    } else {
      Spacer(Modifier.size(16.dp))
    }
    Spacer(Modifier.width(8.dp))
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
  }
}

private fun nextRunText(context: Context, task: ScheduledTask, now: Long): String {
  val next = task.nextRunAt
  return when (task.status) {
    ScheduledTaskStatus.COMPLETED -> "Completed · no future run"
    ScheduledTaskStatus.FAILED -> if (next != null && next > now) "Was scheduled for ${deviceDateTime(context, next)}" else "No scheduled run"
    ScheduledTaskStatus.PAUSED -> "Paused · resume to schedule the next run"
    ScheduledTaskStatus.ACTIVE -> when {
      next == null -> "No future run"
      next <= now -> "Due now · waiting to run"
      else -> "Next run ${deviceDateTime(context, next)}"
    }
  }
}

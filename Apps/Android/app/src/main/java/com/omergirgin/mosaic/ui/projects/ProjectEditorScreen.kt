package com.omergirgin.mosaic.ui.projects

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.omergirgin.mosaic.data.api.ProjectRepository
import com.omergirgin.mosaic.data.model.ModelChoice
import com.omergirgin.mosaic.data.model.Project
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.DiscardChangesDialog
import com.omergirgin.mosaic.ui.settings.EmptyState
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.ModelPickerDialog
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsLinkRow
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import com.omergirgin.mosaic.ui.settings.modelChoiceLabel
import com.omergirgin.mosaic.ui.settings.utf8Size
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Same bounds as iOS MosaicSourceFieldLimits for portable backups. */
private const val MAX_PROJECT_NAME_BYTES = 4 * 1_024
private const val MAX_PROJECT_INSTRUCTIONS_BYTES = 256 * 1_024

internal class ProjectEditorViewModel(
  private val projects: ProjectRepository,
  val projectId: String?,
) : ViewModel() {
  var isLoading by mutableStateOf(projectId != null)
    private set
  var notFound by mutableStateOf(false)
    private set
  var name by mutableStateOf("")
  var instructions by mutableStateOf("")
  var defaultModel by mutableStateOf<ModelChoice?>(null)
  var isSaving by mutableStateOf(false)
    private set
  var saved by mutableStateOf(false)
    private set
  var errorMessage by mutableStateOf<String?>(null)

  private var original: Project? = null

  init {
    if (projectId != null) {
      viewModelScope.launch {
        try {
          val project = projects.observeProject(projectId).first()
          if (project == null) {
            notFound = true
          } else {
            original = project
            name = project.name
            instructions = project.instructions
            defaultModel = project.defaultModel
          }
        } catch (e: CancellationException) {
          throw e
        } catch (e: Exception) {
          errorMessage = e.message ?: "The project couldn't be loaded."
        } finally {
          isLoading = false
        }
      }
    }
  }

  val validationIssue: String?
    get() = when {
      name.isBlank() -> "Enter a project name."
      utf8Size(name.trim()) > MAX_PROJECT_NAME_BYTES -> "The project name is too long."
      utf8Size(instructions.trim()) > MAX_PROJECT_INSTRUCTIONS_BYTES -> "The project instructions are too long."
      else -> null
    }

  val isDirty: Boolean
    get() = name != (original?.name ?: "") ||
      instructions != (original?.instructions ?: "") ||
      defaultModel != original?.defaultModel

  fun save() {
    validationIssue?.let {
      errorMessage = it
      return
    }
    if (isSaving) return
    isSaving = true
    val trimmedName = name.trim()
    val trimmedInstructions = instructions.trim()
    val model = defaultModel
    viewModelScope.launch {
      try {
        withContext(NonCancellable) { projects.saveProject(projectId, trimmedName, trimmedInstructions, model) }
        saved = true
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        errorMessage = e.message?.takeIf { it.isNotBlank() } ?: "Please try again."
      } finally {
        isSaving = false
      }
    }
  }
}

@Composable
internal fun ProjectEditorScreen(projectId: String?, onBack: () -> Unit) {
  val container = LocalAppContainer.current
  val vm: ProjectEditorViewModel = viewModel { ProjectEditorViewModel(container.projects, projectId) }
  val modelOptions by remember(container) { container.providers.observeModelOptions() }
    .collectAsStateWithLifecycle(initialValue = emptyList())
  var choosingModel by rememberSaveable { mutableStateOf(false) }
  var confirmDiscard by rememberSaveable { mutableStateOf(false) }

  LaunchedEffect(vm.saved) { if (vm.saved) onBack() }

  val requestBack: () -> Unit = {
    if (!vm.isSaving) {
      if (vm.isDirty) confirmDiscard = true else onBack()
    }
  }
  BackHandler(enabled = vm.isSaving || vm.isDirty) { requestBack() }

  SettingsScaffold(
    title = if (projectId == null) "New project" else "Edit project",
    onBack = requestBack,
    actions = {
      if (vm.isSaving) {
        CircularProgressIndicator(Modifier.padding(horizontal = 16.dp).size(24.dp), strokeWidth = 2.dp)
      } else if (!vm.isLoading && !vm.notFound) {
        TextButton(onClick = vm::save, enabled = vm.validationIssue == null) { Text("Save") }
      }
    },
  ) { padding ->
    when {
      vm.isLoading -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
      }
      vm.notFound -> EmptyState(
        title = "Project not found",
        message = "This project was deleted.",
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
        SectionHeader("Project")
        OutlinedTextField(
          value = vm.name,
          onValueChange = { vm.name = it },
          label = { Text("Name") },
          placeholder = { Text("Product launch") },
          singleLine = true,
          keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Next),
          modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        )
        OutlinedTextField(
          value = vm.instructions,
          onValueChange = { vm.instructions = it },
          label = { Text("Project instructions") },
          placeholder = { Text("How should the assistant work in this project?") },
          supportingText = { Text("Sent with every chat in this project, in addition to the chat's own instructions.") },
          minLines = 5,
          keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
          modifier = Modifier.fillMaxWidth().heightIn(min = 140.dp).padding(horizontal = 16.dp, vertical = 4.dp),
        )

        SectionHeader("Default model")
        SettingsLinkRow(
          title = "Default model for new chats",
          subtitle = modelChoiceLabel(vm.defaultModel, modelOptions, "Use app default"),
          icon = Icons.Outlined.Tune,
          onClick = { choosingModel = true },
        )

        SectionHeader("Memory boundary")
        ListItem(
          leadingContent = { Icon(Icons.Outlined.Lock, contentDescription = null) },
          headlineContent = { Text("Project-only memory") },
          supportingContent = {
            Text(
              "Memories saved for this project are available only to chats in this project, never to a " +
                "different project. Memories marked Everywhere remain available.",
            )
          },
        )
        SectionFooter("Archived projects keep their chats but can't start new ones.")
      }
    }
  }

  if (choosingModel) {
    ModelPickerDialog(
      title = "Project default model",
      options = modelOptions,
      selected = vm.defaultModel,
      automaticLabel = "Use app default",
      automaticDescription = "New chats in this project use the app's default model.",
      onSelect = {
        vm.defaultModel = it
        choosingModel = false
      },
      onDismiss = { choosingModel = false },
    )
  }
  if (confirmDiscard) {
    DiscardChangesDialog(
      message = "Your changes to this project haven't been saved.",
      onDiscard = {
        confirmDiscard = false
        onBack()
      },
      onKeepEditing = { confirmDiscard = false },
    )
  }
  vm.errorMessage?.let { MessageDialog("Project couldn't be saved", it) { vm.errorMessage = null } }
}

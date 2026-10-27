package com.omergirgin.mosaic.ui.memory

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.TouchApp
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.omergirgin.mosaic.data.api.MemoryRepository
import com.omergirgin.mosaic.data.model.ConversationSummary
import com.omergirgin.mosaic.data.model.MemoryFact
import com.omergirgin.mosaic.data.model.MemoryScope
import com.omergirgin.mosaic.data.model.Project
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.Choice
import com.omergirgin.mosaic.ui.settings.ConfirmDialog
import com.omergirgin.mosaic.ui.settings.DiscardChangesDialog
import com.omergirgin.mosaic.ui.settings.EmptyState
import com.omergirgin.mosaic.ui.settings.MessageDialog
import com.omergirgin.mosaic.ui.settings.SearchableChoiceDialog
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsLinkRow
import com.omergirgin.mosaic.ui.settings.SettingsParagraph
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import com.omergirgin.mosaic.ui.settings.SettingsSwitchRow
import com.omergirgin.mosaic.ui.settings.StatusLine
import com.omergirgin.mosaic.ui.settings.StatusTone
import com.omergirgin.mosaic.ui.settings.formatRelativeTime
import com.omergirgin.mosaic.ui.settings.utf8Size
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Same bounds as iOS MosaicSourceFieldLimits for portable backups. */
private const val MAX_MEMORY_TITLE_BYTES = 4 * 1_024
private const val MAX_MEMORY_CONTENT_BYTES = 256 * 1_024

internal class MemoryEditorViewModel(
  private val memory: MemoryRepository,
  val factId: String?,
) : ViewModel() {
  var isLoading by mutableStateOf(factId != null)
    private set
  var notFound by mutableStateOf(false)
    private set
  var title by mutableStateOf("")
  var content by mutableStateOf("")
  var scope by mutableStateOf(MemoryScope.EVERYWHERE)
    private set
  var projectId by mutableStateOf<String?>(null)
  var conversationId by mutableStateOf<String?>(null)
  var isEnabled by mutableStateOf(true)
  var isBusy by mutableStateOf(false)
    private set
  var finished by mutableStateOf(false)
    private set
  var errorMessage by mutableStateOf<String?>(null)

  var original: MemoryFact? = null
    private set

  init {
    if (factId != null) {
      viewModelScope.launch {
        try {
          val fact = memory.observeFacts().first().firstOrNull { it.id == factId }
          if (fact == null) {
            notFound = true
          } else {
            original = fact
            title = fact.title
            content = fact.content
            scope = fact.scope
            projectId = fact.projectId
            conversationId = fact.conversationId
            isEnabled = fact.isEnabled
          }
        } catch (e: CancellationException) {
          throw e
        } catch (e: Exception) {
          errorMessage = e.message ?: "The memory couldn't be loaded."
        } finally {
          isLoading = false
        }
      }
    }
  }

  fun changeScope(newScope: MemoryScope, firstActiveProjectId: String?) {
    scope = newScope
    when (newScope) {
      MemoryScope.EVERYWHERE -> {
        projectId = null
        conversationId = null
      }
      MemoryScope.PROJECT -> {
        conversationId = null
        if (projectId == null) projectId = firstActiveProjectId
      }
      MemoryScope.CONVERSATION -> projectId = null
    }
  }

  val validationIssue: String?
    get() = when {
      content.isBlank() -> "Enter the fact or preference to remember."
      utf8Size(title.trim()) > MAX_MEMORY_TITLE_BYTES -> "The title is too long."
      utf8Size(content.trim()) > MAX_MEMORY_CONTENT_BYTES -> "The memory details are too long."
      scope == MemoryScope.PROJECT && projectId == null -> "Choose a project."
      scope == MemoryScope.CONVERSATION && conversationId == null -> "Choose a conversation."
      else -> null
    }

  val isDirty: Boolean
    get() = title != (original?.title ?: "") ||
      content != (original?.content ?: "") ||
      scope != (original?.scope ?: MemoryScope.EVERYWHERE) ||
      projectId != original?.projectId ||
      conversationId != original?.conversationId ||
      isEnabled != (original?.isEnabled ?: true)

  fun save() {
    validationIssue?.let {
      errorMessage = it
      return
    }
    if (isBusy) return
    isBusy = true
    val now = System.currentTimeMillis()
    val fact = MemoryFact(
      id = original?.id ?: UUID.randomUUID().toString(),
      title = title.trim(),
      content = content.trim(),
      scope = scope,
      projectId = projectId.takeIf { scope == MemoryScope.PROJECT },
      conversationId = conversationId.takeIf { scope == MemoryScope.CONVERSATION },
      isEnabled = isEnabled,
      createdAt = original?.createdAt ?: now,
      updatedAt = now,
    )
    write { memory.saveFact(fact) }
  }

  fun delete() {
    val id = original?.id ?: return
    if (isBusy) return
    isBusy = true
    write { memory.deleteFact(id) }
  }

  private fun write(block: suspend () -> Unit) {
    viewModelScope.launch {
      try {
        withContext(NonCancellable) { block() }
        finished = true
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        errorMessage = e.message?.takeIf { it.isNotBlank() } ?: "Please try again."
      } finally {
        isBusy = false
      }
    }
  }
}

@Composable
internal fun MemoryEditorScreen(factId: String?, onBack: () -> Unit) {
  val container = LocalAppContainer.current
  val vm: MemoryEditorViewModel = viewModel { MemoryEditorViewModel(container.memory, factId) }
  val projects by remember(container) { container.projects.observeProjects(includeArchived = true) }
    .collectAsStateWithLifecycle(initialValue = emptyList())
  val conversationTitles by remember(container) { observeConversationTitles(container) }
    .collectAsStateWithLifecycle(initialValue = emptyMap())
  var choosingProject by rememberSaveable { mutableStateOf(false) }
  var choosingConversation by rememberSaveable { mutableStateOf(false) }
  var confirmDiscard by rememberSaveable { mutableStateOf(false) }
  var confirmDelete by rememberSaveable { mutableStateOf(false) }

  LaunchedEffect(vm.finished) { if (vm.finished) onBack() }

  val requestBack: () -> Unit = {
    if (!vm.isBusy) {
      if (vm.isDirty) confirmDiscard = true else onBack()
    }
  }
  BackHandler(enabled = vm.isBusy || vm.isDirty) { requestBack() }

  val activeProjects = projects.filter { !it.isArchived }

  SettingsScaffold(
    title = if (factId == null) "New memory" else "Edit memory",
    onBack = requestBack,
    actions = {
      if (vm.isBusy) {
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
        title = "Memory not found",
        message = "This memory was deleted.",
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
        SectionHeader("Memory")
        OutlinedTextField(
          value = vm.title,
          onValueChange = { vm.title = it },
          label = { Text("Title") },
          placeholder = { Text("Preferred response style") },
          singleLine = true,
          keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Next),
          modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        )
        OutlinedTextField(
          value = vm.content,
          onValueChange = { vm.content = it },
          label = { Text("Memory details") },
          supportingText = { Text("The exact fact or preference Turing AI may send to your AI service.") },
          minLines = 5,
          keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
          modifier = Modifier.fillMaxWidth().heightIn(min = 140.dp).padding(horizontal = 16.dp, vertical = 4.dp),
        )

        SectionHeader("Availability")
        val scopes = MemoryScope.entries
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
          scopes.forEachIndexed { index, option ->
            SegmentedButton(
              selected = vm.scope == option,
              onClick = { vm.changeScope(option, activeProjects.firstOrNull()?.id) },
              shape = SegmentedButtonDefaults.itemShape(index, scopes.size),
              modifier = Modifier.heightIn(min = 48.dp),
            ) {
              Text(
                when (option) {
                  MemoryScope.EVERYWHERE -> "Everywhere"
                  MemoryScope.PROJECT -> "Project"
                  MemoryScope.CONVERSATION -> "Chat"
                },
                maxLines = 1,
              )
            }
          }
        }
        when (vm.scope) {
          MemoryScope.PROJECT -> {
            val selected = projects.firstOrNull { it.id == vm.projectId }
            if (activeProjects.isEmpty() && selected == null) {
              StatusLine("Create an active project before saving project-scoped memory.", StatusTone.NEUTRAL)
            } else {
              SettingsLinkRow(
                title = "Project",
                subtitle = selected?.let { if (it.isArchived) "${it.name} (Archived)" else it.name }
                  ?: vm.projectId?.let { "Unavailable project" }
                  ?: "Choose a project",
                icon = Icons.Outlined.Folder,
                onClick = { choosingProject = true },
              )
            }
          }
          MemoryScope.CONVERSATION -> SettingsLinkRow(
            title = "Conversation",
            subtitle = vm.conversationId?.let { conversationTitles[it]?.ifBlank { null } ?: "Specific conversation" }
              ?: "Choose a conversation",
            icon = Icons.AutoMirrored.Outlined.Chat,
            onClick = { choosingConversation = true },
          )
          MemoryScope.EVERYWHERE -> Unit
        }
        SettingsSwitchRow(
          title = "Use in AI requests",
          subtitle = "Turn off to keep this memory without sending it.",
          checked = vm.isEnabled,
          onCheckedChange = { vm.isEnabled = it },
        )
        SectionFooter(
          when (vm.scope) {
            MemoryScope.EVERYWHERE -> "Available in every conversation."
            MemoryScope.PROJECT -> "Available only to conversations in the selected project."
            MemoryScope.CONVERSATION -> "Available only when the selected conversation is active."
          },
        )

        SectionHeader("Provenance")
        ListItem(
          leadingContent = { Icon(Icons.Outlined.TouchApp, contentDescription = null) },
          headlineContent = { Text("Saved manually by you") },
          supportingContent = { Text("Saving pins this fact for future requests in the conversations it applies to.") },
        )
        SettingsParagraph(
          "A pinned memory is sent exactly as written and takes precedence over topics Turing AI learns " +
            "automatically from chats.",
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        if (vm.original != null) {
          HorizontalDivider(Modifier.padding(top = 16.dp))
          TextButton(
            onClick = { confirmDelete = true },
            enabled = !vm.isBusy,
            colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
            modifier = Modifier.padding(8.dp).heightIn(min = 48.dp),
          ) {
            Icon(Icons.Outlined.Delete, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text("Delete memory")
          }
        }
      }
    }
  }

  if (choosingProject) {
    // Archived projects can't receive new items; only the current (archived) choice stays listed.
    val choices = projects.filter { !it.isArchived || it.id == vm.projectId }.sortedBy { it.name.lowercase() }
    SearchableChoiceDialog(
      title = "Choose a project",
      choices = choices.map { Choice(it.id, it, if (it.isArchived) "${it.name} (Archived)" else it.name) },
      selectedKey = vm.projectId,
      onSelect = { project: Project ->
        vm.projectId = project.id
        choosingProject = false
      },
      onDismiss = { choosingProject = false },
      searchLabel = "Search projects",
      emptyMessage = "Create an active project before saving project-scoped memory.",
    )
  }
  if (choosingConversation) {
    ConversationPickerDialog(
      selectedId = vm.conversationId,
      onSelect = {
        vm.conversationId = it
        choosingConversation = false
      },
      onDismiss = { choosingConversation = false },
    )
  }
  if (confirmDiscard) {
    DiscardChangesDialog(
      message = "Your changes to this memory haven't been saved.",
      onDiscard = {
        confirmDiscard = false
        onBack()
      },
      onKeepEditing = { confirmDiscard = false },
    )
  }
  if (confirmDelete) {
    ConfirmDialog(
      title = "Delete this memory?",
      message = "“${vm.original?.let(::memoryDisplayTitle) ?: "This memory"}” will no longer be available to any conversation.",
      confirmLabel = "Delete memory",
      onConfirm = {
        confirmDelete = false
        vm.delete()
      },
      onDismiss = { confirmDelete = false },
    )
  }
  vm.errorMessage?.let { MessageDialog("Memory couldn't be saved", it) { vm.errorMessage = null } }
}

/** Searches the chat library through the repository, so it scales to thousands of chats. */
@OptIn(ExperimentalMaterial3Api::class, FlowPreview::class, ExperimentalCoroutinesApi::class)
@Composable
private fun ConversationPickerDialog(
  selectedId: String?,
  onSelect: (String) -> Unit,
  onDismiss: () -> Unit,
) {
  val container = LocalAppContainer.current
  var query by rememberSaveable { mutableStateOf("") }
  val results by remember(container) {
    snapshotFlow { query.trim() }
      .debounce(250)
      .flatMapLatest { text -> container.conversations.observeConversations(query = text) }
      .map<List<ConversationSummary>, List<ConversationSummary>?> { it }
  }.collectAsStateWithLifecycle(initialValue = null)

  Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
    Surface(Modifier.fillMaxSize()) {
      Scaffold(
        topBar = {
          TopAppBar(
            title = { Text("Choose a conversation") },
            navigationIcon = {
              IconButton(onClick = onDismiss) { Icon(Icons.Filled.Close, contentDescription = "Close") }
            },
          )
        },
      ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().imePadding()) {
          OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            label = { Text("Search conversations") },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
          )
          val list = results
          when {
            list == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            list.isEmpty() -> SettingsParagraph(
              if (query.isBlank()) "Create a conversation before saving conversation-scoped memory."
              else "No conversations match “${query.trim()}”.",
              color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            else -> LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
              items(list, key = { it.id }) { chat ->
                val isSelected = chat.id == selectedId
                ListItem(
                  headlineContent = { Text(chat.title.ifBlank { "New chat" }, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                  supportingContent = {
                    Text(
                      listOfNotNull(chat.projectName, formatRelativeTime(chat.updatedAt)).joinToString(" · "),
                      maxLines = 1,
                    )
                  },
                  leadingContent = { RadioButton(selected = isSelected, onClick = null) },
                  modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 56.dp)
                    .selectable(selected = isSelected, role = Role.RadioButton) { onSelect(chat.id) },
                )
              }
            }
          }
        }
      }
    }
  }
}

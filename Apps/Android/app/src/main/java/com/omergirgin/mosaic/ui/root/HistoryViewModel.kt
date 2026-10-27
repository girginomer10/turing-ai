package com.omergirgin.mosaic.ui.root

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.omergirgin.mosaic.data.api.AppContainer
import com.omergirgin.mosaic.data.model.ConversationSummary
import com.omergirgin.mosaic.data.model.Project
import com.omergirgin.mosaic.ui.components.NoticeChannel
import com.omergirgin.mosaic.ui.components.UiNotice
import com.omergirgin.mosaic.ui.components.userMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** Filters that select which chats the history drawer lists. */
data class HistoryFilter(val query: String, val archived: Boolean, val projectId: String?)

/** Chat history drawer state: search, archived toggle, project filter and per-chat actions. */
@OptIn(FlowPreview::class, ExperimentalCoroutinesApi::class)
class HistoryViewModel(private val container: AppContainer) : ViewModel() {

  private val noticeChannel = NoticeChannel()
  val notices: Flow<UiNotice> = noticeChannel.notices

  private val _query = MutableStateFlow("")
  val query: StateFlow<String> = _query.asStateFlow()

  private val _showArchived = MutableStateFlow(false)
  val showArchived: StateFlow<Boolean> = _showArchived.asStateFlow()

  private val _projectFilter = MutableStateFlow<String?>(null)
  val projectFilter: StateFlow<String?> = _projectFilter.asStateFlow()

  val projects: StateFlow<List<Project>> = container.projects.observeProjects(includeArchived = false)
    .catch { emit(emptyList()) }
    .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

  /** null while the first page loads; the previous list stays visible while a new search runs. */
  val conversations: StateFlow<List<ConversationSummary>?> = combine(
    // Searching scans message text, so wait for a typing pause; clearing the field is instant.
    _query.debounce { if (it.isBlank()) 0L else 200L }.map { it.trim() }.distinctUntilChanged(),
    _showArchived,
    _projectFilter,
  ) { query, archived, projectId -> HistoryFilter(query, archived, projectId) }
    .flatMapLatest { filter ->
      container.conversations.observeConversations(filter.query, filter.archived, filter.projectId)
        .catch { error ->
          noticeChannel.post("Turing AI couldn't load your chats. ${error.userMessage()}")
          emit(emptyList())
        }
    }
    .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

  init {
    // A filter pointing at a project that was archived or deleted would show an empty list forever.
    viewModelScope.launch {
      projects.collect { list ->
        val filter = _projectFilter.value
        if (filter != null && list.none { it.id == filter }) _projectFilter.value = null
      }
    }
  }

  fun setQuery(value: String) {
    _query.value = value
  }

  fun setShowArchived(value: Boolean) {
    _showArchived.value = value
  }

  fun setProjectFilter(projectId: String?) {
    _projectFilter.value = projectId
  }

  fun rename(id: String, title: String) {
    val trimmed = title.trim()
    if (trimmed.isEmpty()) return
    launchSafely("Turing AI couldn't rename this chat.") { container.conversations.rename(id, trimmed) }
  }

  fun moveToProject(id: String, projectId: String?) {
    viewModelScope.launch {
      try {
        container.conversations.moveToProject(id, projectId)
        val name = projects.value.firstOrNull { it.id == projectId }?.name
        noticeChannel.post(if (name != null) "Moved to $name." else "Removed from project.")
      } catch (e: CancellationException) {
        throw e
      } catch (e: IllegalStateException) {
        noticeChannel.post("Stop the response before moving this chat to another project.")
      } catch (e: Exception) {
        noticeChannel.post("Turing AI couldn't move this chat. ${e.userMessage()}")
      }
    }
  }

  fun setArchived(id: String, archived: Boolean, onDone: () -> Unit = {}) {
    viewModelScope.launch {
      try {
        container.conversations.setArchived(id, archived)
        onDone()
        noticeChannel.post(
          if (archived) {
            UiNotice("Chat archived.", actionLabel = "Undo", onAction = { setArchived(id, false) })
          } else {
            UiNotice("Chat restored from the archive.")
          }
        )
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        noticeChannel.post("Turing AI couldn't update this chat. ${e.userMessage()}")
      }
    }
  }

  fun delete(id: String) {
    viewModelScope.launch {
      try {
        container.conversations.delete(id)
        noticeChannel.post("Chat deleted.")
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        noticeChannel.post("Turing AI couldn't delete this chat. ${e.userMessage()}")
      }
    }
  }

  private fun launchSafely(failure: String, block: suspend () -> Unit) = viewModelScope.launch {
    try {
      block()
    } catch (e: CancellationException) {
      throw e
    } catch (e: Exception) {
      noticeChannel.post("$failure ${e.userMessage()}")
    }
  }
}

package com.omergirgin.mosaic.ui.voice

import com.omergirgin.mosaic.data.api.AppContainer
import com.omergirgin.mosaic.ui.chat.ChatViewModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/*
 * Detached drafts are written after the person left the dictating chat, so they must outlive the
 * screen; one serial lane keeps successive finalized segments in order.
 */
@OptIn(ExperimentalCoroutinesApi::class)
private val detachedDraftScope = CoroutineScope(SupervisorJob() + Dispatchers.IO.limitedParallelism(1))

/** [DictationHost] over the chat view model's public composer API. */
class ChatDictationHost(private val vm: ChatViewModel, private val container: AppContainer) : DictationHost {
  override val openConversationId: StateFlow<String?> get() = vm.conversationId
  override val isGenerating: StateFlow<Boolean> get() = vm.isGenerating
  override val chatProviderId: String? get() = vm.selectedOption.value?.choice?.providerId
  override val draft: String get() = vm.draft

  override fun replaceDraft(text: String) = vm.onDraftChange(text)

  override fun flushDraft() = vm.flushDraft()

  override fun writeDetachedDraft(conversationId: String, previous: String, text: String) {
    // Back in that chat already: update the visible composer (it persists with its debounce).
    if (vm.conversationId.value == conversationId && vm.draft == previous) {
      vm.onDraftChange(text)
      return
    }
    detachedDraftScope.launch { runCatching { container.conversations.updateDraft(conversationId, text) } }
  }
}

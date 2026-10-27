package com.omergirgin.mosaic.ui.tasks

import android.content.Intent
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.omergirgin.mosaic.data.tasks.ScheduledTaskNotifications
import com.omergirgin.mosaic.data.tasks.ScheduledTaskRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Hand-off from a tapped scheduled-prompt notification (MainActivity) to the app shell
 * (TuringRoot), which consumes each request once.
 */
object AutomationLaunchRequests {
  sealed interface Request {
    data class OpenConversation(val conversationId: String) : Request
    data object OpenAutomations : Request
  }

  private val _pending = MutableStateFlow<Request?>(null)
  val pending: StateFlow<Request?> = _pending.asStateFlow()

  /** Reads and removes the notification extras, so a recreated activity never replays them. */
  fun handle(intent: Intent?) {
    intent ?: return
    val conversationId = intent.getStringExtra(ScheduledTaskNotifications.EXTRA_CONVERSATION_ID)?.takeIf { it.isNotBlank() }
    val openAutomations = intent.getBooleanExtra(ScheduledTaskNotifications.EXTRA_OPEN_AUTOMATIONS, false)
    intent.removeExtra(ScheduledTaskNotifications.EXTRA_CONVERSATION_ID)
    intent.removeExtra(ScheduledTaskNotifications.EXTRA_OPEN_AUTOMATIONS)
    _pending.value = when {
      conversationId != null -> Request.OpenConversation(conversationId)
      openAutomations -> Request.OpenAutomations
      else -> return
    }
  }

  fun consume(request: Request) {
    _pending.compareAndSet(request, null)
  }
}

/**
 * iOS app-scoped foreground sweep: while any app UI is visible, due prompts run every 30 seconds.
 * Call once from `Application.onCreate`; the repository is resolved lazily on the first start.
 */
fun installAutomationForegroundSweep(tasks: () -> ScheduledTaskRepository) {
  ProcessLifecycleOwner.get().lifecycle.addObserver(
    object : DefaultLifecycleObserver {
      override fun onStart(owner: LifecycleOwner) = tasks().setAppInForeground(true)
      override fun onStop(owner: LifecycleOwner) = tasks().setAppInForeground(false)
    }
  )
}

package com.omergirgin.mosaic.ui.components

import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow

/** One-shot user feedback (errors, confirmations) emitted by view models and shown as a snackbar. */
data class UiNotice(
  val text: String,
  val actionLabel: String? = null,
  val onAction: (() -> Unit)? = null,
  val long: Boolean = false,
)

/** Buffered so notices emitted while no snackbar host is collecting (e.g. during rotation) survive. */
class NoticeChannel {
  private val channel = Channel<UiNotice>(capacity = Channel.BUFFERED)
  val notices: Flow<UiNotice> = channel.receiveAsFlow()

  fun post(notice: UiNotice) {
    channel.trySend(notice)
  }

  fun post(text: String) = post(UiNotice(text))
}

suspend fun SnackbarHostState.show(notice: UiNotice) {
  val result = showSnackbar(
    message = notice.text,
    actionLabel = notice.actionLabel,
    withDismissAction = notice.actionLabel == null && notice.long,
    duration = when {
      notice.actionLabel != null -> SnackbarDuration.Long
      notice.long -> SnackbarDuration.Long
      else -> SnackbarDuration.Short
    },
  )
  if (result == SnackbarResult.ActionPerformed) notice.onAction?.invoke()
}

/** Human-readable failure text that never leaks a bare exception class name. */
fun Throwable.userMessage(fallback: String = "Please try again."): String =
  message?.takeIf { it.isNotBlank() } ?: fallback

package com.omergirgin.mosaic.ui.share

import android.content.Context
import android.content.Intent
import com.omergirgin.mosaic.MainActivity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Hand-off from the share screen ("Save and open Turing AI") to the app shell, which opens
 * Shared items once per request.
 */
object SharedItemsLaunchRequests {
  private const val EXTRA_OPEN_SHARED_ITEMS = "com.omergirgin.mosaic.extra.OPEN_SHARED_ITEMS"

  private val _pending = MutableStateFlow(false)
  val pending: StateFlow<Boolean> = _pending.asStateFlow()

  /** Brings the app's own task forward (or starts it) on the Shared items screen. */
  fun openIntent(context: Context): Intent =
    Intent(context, MainActivity::class.java)
      .putExtra(EXTRA_OPEN_SHARED_ITEMS, true)
      .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)

  /** Reads and removes the extra, so a recreated activity never replays it. */
  fun handle(intent: Intent?) {
    if (intent?.getBooleanExtra(EXTRA_OPEN_SHARED_ITEMS, false) != true) return
    intent.removeExtra(EXTRA_OPEN_SHARED_ITEMS)
    _pending.value = true
  }

  fun consume() {
    _pending.value = false
  }
}

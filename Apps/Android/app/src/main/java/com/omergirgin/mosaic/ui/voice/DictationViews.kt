package com.omergirgin.mosaic.ui.voice

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.HourglassTop
import androidx.compose.material.icons.outlined.MicOff
import androidx.compose.material.icons.outlined.PrivacyTip
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.core.app.ActivityCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect

/**
 * The microphone control beside Send (DESIGN.md "Voice input"): a standard microphone symbol when
 * idle; while active it becomes the single stop/cancel control, and its accessibility label
 * follows the state. Shown disabled while another chat is still finishing its dictation.
 */
@Composable
fun DictationButton(controller: DictationController, openConversationId: String?, enabled: Boolean) {
  val context = LocalContext.current
  val focusManager = LocalFocusManager.current
  val phase = controller.phase
  val here = controller.isActiveFor(openConversationId)
  val busyElsewhere = phase.isActive && !here

  if (!here) {
    val label = if (busyElsewhere) "Live transcription is finishing in another chat" else "Start live transcription"
    IconButton(
      onClick = {
        focusManager.clearFocus()
        controller.toggle(context)
      },
      enabled = enabled && !busyElsewhere && openConversationId != null,
      modifier = Modifier.semantics {
        contentDescription = label
      },
    ) {
      Icon(Icons.Filled.Mic, contentDescription = null)
    }
    return
  }

  val label = when (phase) {
    DictationPhase.REQUESTING_PERMISSION -> "Cancel microphone permission request"
    DictationPhase.CONNECTING -> "Cancel live transcription"
    DictationPhase.LISTENING -> "Finish live transcription"
    DictationPhase.FINISHING -> "Cancel finishing transcription"
    DictationPhase.IDLE -> "Stop live transcription"
  }
  FilledTonalIconButton(
    onClick = { controller.toggle(context) },
    modifier = Modifier.semantics {
      contentDescription = label
      stateDescription = statusText(controller)
    },
  ) {
    when (phase) {
      DictationPhase.CONNECTING, DictationPhase.FINISHING ->
        CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
      else -> Icon(Icons.Filled.Stop, contentDescription = null)
    }
  }
}

/**
 * Status line under the composer while this chat is dictating: a distinct symbol plus text per
 * state (never color alone), naming the Google destination and that nothing reaches the chat
 * model before Send. Announced politely to screen readers as it changes.
 */
@Composable
fun DictationStatus(controller: DictationController, openConversationId: String?) {
  if (!controller.isActiveFor(openConversationId)) return
  val icon: ImageVector = when (controller.phase) {
    DictationPhase.REQUESTING_PERMISSION -> Icons.Outlined.PrivacyTip
    DictationPhase.CONNECTING -> Icons.Outlined.Sync
    DictationPhase.LISTENING -> Icons.Outlined.GraphicEq
    DictationPhase.FINISHING -> Icons.Outlined.HourglassTop
    DictationPhase.IDLE -> Icons.Outlined.MicOff
  }
  val text = statusText(controller)
  Row(
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(6.dp),
    modifier = Modifier
      .padding(horizontal = 12.dp, vertical = 4.dp)
      .semantics(mergeDescendants = true) {
        liveRegion = LiveRegionMode.Polite
        contentDescription = text
      },
  ) {
    Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
      Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
    }
    Text(text, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
  }
}

private fun statusText(controller: DictationController): String {
  val destination = controller.destination.ifEmpty { "Google Gemini" }
  val language = controller.languageCode?.let { " · $it" }.orEmpty()
  return when (controller.phase) {
    DictationPhase.IDLE -> ""
    DictationPhase.REQUESTING_PERMISSION -> "Waiting for microphone permission…"
    DictationPhase.CONNECTING -> "Connecting to $destination…"
    DictationPhase.LISTENING ->
      "Listening · audio goes to $destination. Text stays in your draft and reaches the chat model only when you send it.$language"
    DictationPhase.FINISHING -> "Finishing transcription with $destination…"
  }
}

/**
 * Screen-level dictation plumbing for the conversation screen: the in-context RECORD_AUDIO
 * request, graceful stop when the app is backgrounded or the chat screen is left (not on a
 * configuration change), and the explanatory dialog.
 */
@Composable
fun DictationEffects(controller: DictationController, onOpenProviders: () -> Unit) {
  val context = LocalContext.current
  val activity = LocalActivity.current
  val currentActivity by rememberUpdatedState(activity)

  val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
    val canAskAgain = currentActivity?.let {
      ActivityCompat.shouldShowRequestPermissionRationale(it, Manifest.permission.RECORD_AUDIO)
    } ?: true
    controller.onPermissionResult(granted, canAskAgain = granted || canAskAgain)
  }
  LaunchedEffect(controller.permissionRequestPending) {
    if (!controller.permissionRequestPending) return@LaunchedEffect
    controller.consumePermissionRequest()
    try {
      permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
    } catch (error: ActivityNotFoundException) {
      controller.onPermissionResult(granted = false, canAskAgain = false)
    }
  }

  // No recording in the background: leaving the visible app ends capture with the final-result drain.
  LifecycleEventEffect(Lifecycle.Event.ON_STOP) {
    if (currentActivity?.isChangingConfigurations != true) controller.stopForLifecycle()
  }
  DisposableEffect(controller) {
    onDispose { if (currentActivity?.isChangingConfigurations != true) controller.stopForLifecycle() }
  }

  controller.alert?.let { alert ->
    AlertDialog(
      onDismissRequest = controller::dismissAlert,
      title = { Text("Live transcription") },
      text = { Text(alert.message) },
      confirmButton = {
        when (alert.action) {
          DictationAlert.Action.OPEN_APP_SETTINGS -> TextButton(onClick = {
            controller.dismissAlert()
            try {
              context.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                  .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
              )
            } catch (error: ActivityNotFoundException) {
              // No settings screen on this device; the message already explains what to change.
            }
          }) { Text("Open settings") }
          DictationAlert.Action.OPEN_PROVIDERS -> TextButton(onClick = {
            controller.dismissAlert()
            onOpenProviders()
          }) { Text("Providers") }
          null -> TextButton(onClick = controller::dismissAlert) { Text("OK") }
        }
      },
      dismissButton = if (alert.action != null) {
        { TextButton(onClick = controller::dismissAlert) { Text("Not now") } }
      } else {
        null
      },
    )
  }
}

package com.omergirgin.mosaic.ui.tasks

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.NotificationsActive
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.omergirgin.mosaic.data.tasks.ScheduledTaskNotifications
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.StatusLine
import com.omergirgin.mosaic.ui.settings.StatusTone

/** What Android currently allows for background runs; re-read whenever the screen resumes. */
internal data class BackgroundRunStatus(
  /** The user restricted background activity: work runs only while the app is open. */
  val restricted: Boolean,
  /** Default for every app: Doze and app standby may defer work. */
  val batteryOptimized: Boolean,
  val powerSaveMode: Boolean,
)

internal fun readBackgroundRunStatus(context: Context): BackgroundRunStatus {
  val power = context.getSystemService(PowerManager::class.java)
  val activity = context.getSystemService(ActivityManager::class.java)
  return BackgroundRunStatus(
    restricted = Build.VERSION.SDK_INT >= 28 && activity?.isBackgroundRestricted == true,
    batteryOptimized = power?.isIgnoringBatteryOptimizations(context.packageName) != true,
    powerSaveMode = power?.isPowerSaveMode == true,
  )
}

/** Re-evaluates [read] on every resume (returning from system settings or the permission sheet). */
@Composable
internal fun <T> rememberOnResume(read: (Context) -> T): T {
  val context = LocalContext.current
  var generation by remember { mutableIntStateOf(0) }
  LifecycleResumeEffect(Unit) {
    generation++
    onPauseOrDispose { }
  }
  return remember(generation) { read(context) }
}

/**
 * Honest background-execution status (PRODUCT principle "No ambiguous automation"): runs are
 * on-device, may be delayed by Android, and never start early.
 */
@Composable
internal fun BackgroundRunStatusSection(status: BackgroundRunStatus) {
  val context = LocalContext.current
  when {
    status.restricted -> {
      StatusLine(
        "Background activity is restricted for Turing AI, so scheduled prompts run only while the app is open. " +
          "Allow background activity in the app's battery settings to run them in the background.",
        StatusTone.ERROR,
      )
      SettingsButton("Open app settings") { openAppDetails(context) }
    }
    status.batteryOptimized -> {
      StatusLine(
        "Android may delay background runs to save battery, especially while the phone is idle. " +
          "A run can be late but never starts early.",
        StatusTone.WARNING,
      )
      SettingsButton("Battery optimization settings") {
        openSettings(context, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
      }
    }
    else -> StatusLine(
      "Battery optimization is off for Turing AI. Android can still delay runs in some situations, such as Doze.",
      StatusTone.SUCCESS,
    )
  }
  if (status.powerSaveMode) {
    StatusLine("Battery Saver is on. Background runs may wait until it's off or the app is open.", StatusTone.WARNING)
  }
}

@Composable
internal fun NotificationAccessSection(canNotify: Boolean) {
  val context = LocalContext.current
  var askedAndDenied by rememberSaveable { mutableStateOf(false) }
  val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
    if (!granted) askedAndDenied = true
  }
  if (canNotify) {
    StatusLine("You'll get a notification when a scheduled prompt finishes or needs attention.", StatusTone.SUCCESS)
    return
  }
  StatusLine("Notifications are off. You won't be told when a scheduled prompt finishes.", StatusTone.NEUTRAL)
  Row(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
    OutlinedButton(
      onClick = {
        val permissionPending = Build.VERSION.SDK_INT >= 33 &&
          !hasPostPermission(context) &&
          (!askedAndDenied || context.findActivity()?.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS) == true)
        if (permissionPending) {
          launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
          // Permanently denied, app-level switch off, or the channel is muted: only Settings can change it.
          ScheduledTaskNotifications.ensureChannel(context)
          openSettings(
            context,
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName),
          )
        }
      },
    ) {
      Icon(Icons.Outlined.NotificationsActive, contentDescription = null)
      Spacer(Modifier.width(8.dp))
      Text("Turn on notifications")
    }
  }
  SectionFooter("Turing AI asks for notification access only when you tap this button, never when you create an automation.")
}

private fun hasPostPermission(context: Context): Boolean =
  Build.VERSION.SDK_INT < 33 ||
    context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

@Composable
private fun SettingsButton(label: String, onClick: () -> Unit) {
  TextButton(onClick = onClick, modifier = Modifier.padding(horizontal = 8.dp)) { Text(label) }
}

private fun openAppDetails(context: Context) {
  openSettings(context, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)))
}

private fun openSettings(context: Context, intent: Intent) {
  if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
  try {
    context.startActivity(intent)
  } catch (_: ActivityNotFoundException) {
    try {
      context.startActivity(
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
          .apply { if (context !is Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) },
      )
    } catch (_: ActivityNotFoundException) {
      Toast.makeText(context, "Open Settings to change this for Turing AI.", Toast.LENGTH_LONG).show()
    }
  }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
  is Activity -> this
  is ContextWrapper -> baseContext.findActivity()
  else -> null
}

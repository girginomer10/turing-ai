package com.omergirgin.mosaic.data.tasks

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.ForegroundInfo
import com.omergirgin.mosaic.data.R

/**
 * Local notifications for scheduled prompts. Only the task title is shown, never the prompt or the
 * reply (iOS parity), and the lock-screen version hides the title as well. Nothing here ever asks
 * for permission; the Automations screen requests it in context.
 */
object ScheduledTaskNotifications {
  const val CHANNEL_ID = "scheduled_prompts"

  /** String extra on the launch intent: the result chat to open. */
  const val EXTRA_CONVERSATION_ID = "conversationId"

  /** Boolean extra on the launch intent: open Automations (a run failed before a chat existed). */
  const val EXTRA_OPEN_AUTOMATIONS = "openAutomations"

  internal const val ACTION_OPEN_RESULT = "com.omergirgin.mosaic.action.OPEN_SCHEDULED_PROMPT_RESULT"

  /** True when a completion notification would actually be shown. */
  fun canNotify(context: Context): Boolean {
    if (Build.VERSION.SDK_INT >= 33 &&
      ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
    ) {
      return false
    }
    val manager = NotificationManagerCompat.from(context)
    if (!manager.areNotificationsEnabled()) return false
    val channel = manager.getNotificationChannelCompat(CHANNEL_ID)
    return channel == null || channel.importance != NotificationManagerCompat.IMPORTANCE_NONE
  }

  fun ensureChannel(context: Context) {
    NotificationManagerCompat.from(context).createNotificationChannel(
      NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_DEFAULT)
        .setName("Scheduled prompts")
        .setDescription("Results of scheduled prompts that ran on this device.")
        .build()
    )
  }
}

internal class TaskNotifier(private val context: Context) {

  @SuppressLint("MissingPermission") // canNotify checks POST_NOTIFICATIONS first.
  fun notifyRunFinished(taskId: String, title: String, succeeded: Boolean, conversationId: String?) {
    if (!ScheduledTaskNotifications.canNotify(context)) return
    runCatching {
      ScheduledTaskNotifications.ensureChannel(context)
      val heading = if (succeeded) "Scheduled prompt finished" else "Scheduled prompt needs attention"
      val name = displayTaskTitle(title)
      val body = if (succeeded) "$name is ready in Turing AI." else "$name couldn't finish. Open Turing AI to review the error."
      val publicVersion = NotificationCompat.Builder(context, ScheduledTaskNotifications.CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_stat_scheduled_prompt)
        .setContentTitle(heading)
        .build()
      val notification = NotificationCompat.Builder(context, ScheduledTaskNotifications.CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_stat_scheduled_prompt)
        .setContentTitle(heading)
        .setContentText(body)
        .setStyle(NotificationCompat.BigTextStyle().bigText(body))
        .setCategory(NotificationCompat.CATEGORY_STATUS)
        .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        .setPublicVersion(publicVersion)
        .setAutoCancel(true)
        .setContentIntent(openIntent(taskId, conversationId))
        .build()
      // One notification per task: a newer result replaces the previous one.
      NotificationManagerCompat.from(context).notify(tagFor(taskId), RESULT_ID, notification)
    }
  }

  fun cancel(taskId: String) {
    runCatching { NotificationManagerCompat.from(context).cancel(tagFor(taskId), RESULT_ID) }
  }

  /** Shown only where expedited work falls back to a foreground service (Android 11 and older). */
  fun foregroundInfo(): ForegroundInfo {
    ScheduledTaskNotifications.ensureChannel(context)
    val notification = NotificationCompat.Builder(context, ScheduledTaskNotifications.CHANNEL_ID)
      .setSmallIcon(R.drawable.ic_stat_scheduled_prompt)
      .setContentTitle("Running a scheduled prompt")
      .setPriority(NotificationCompat.PRIORITY_LOW)
      .setSilent(true)
      .setOngoing(true)
      .build()
    return ForegroundInfo(FOREGROUND_ID, notification)
  }

  private fun openIntent(taskId: String, conversationId: String?): PendingIntent {
    val component = context.packageManager.getLaunchIntentForPackage(context.packageName)?.component
    val intent = Intent(ScheduledTaskNotifications.ACTION_OPEN_RESULT)
      .setPackage(context.packageName)
      // Distinct data per task, so two tasks never share (and overwrite) one PendingIntent.
      .setData(Uri.parse("turing-scheduled-prompt://task/" + Uri.encode(taskId)))
      .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    if (component != null) intent.component = component
    if (conversationId != null) {
      intent.putExtra(ScheduledTaskNotifications.EXTRA_CONVERSATION_ID, conversationId)
    } else {
      intent.putExtra(ScheduledTaskNotifications.EXTRA_OPEN_AUTOMATIONS, true)
    }
    return PendingIntent.getActivity(
      context,
      taskId.hashCode(),
      intent,
      PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
  }

  private fun tagFor(taskId: String) = "scheduled-prompt:$taskId"

  private companion object {
    const val RESULT_ID = 1
    const val FOREGROUND_ID = 0x7A5C
  }
}

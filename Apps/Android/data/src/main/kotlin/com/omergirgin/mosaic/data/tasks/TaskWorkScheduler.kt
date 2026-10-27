package com.omergirgin.mosaic.data.tasks

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.workDataOf
import com.omergirgin.mosaic.data.db.ScheduledTaskDao
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * WorkManager glue. Background execution has three parts:
 * - one "due" request for the earliest next run (initial delay, needs a network; expedited when
 *   it is already due). It is tagged with its target time and replaced only while it is still
 *   pending, so a running sweep is never cancelled by its own rescheduling;
 * - an hourly periodic sweep as a safety net (for example after a time change);
 * - an expedited request per Run now.
 *
 * Android decides when this work actually starts (Doze, battery saver, app standby), so a run can
 * be late but never early; the UI says so.
 */
internal class TaskWorkScheduler(private val context: Context, private val dao: ScheduledTaskDao) {
  private val mutex = Mutex()
  private val workManager: WorkManager get() = WorkManager.getInstance(context)

  suspend fun reconcile() = mutex.withLock {
    val manager = workManager
    val earliest = dao.earliestNextRun()
    val pending = manager.getWorkInfosByTagFlow(TAG_DUE).first().filterNot { it.state.isFinished }
    if (earliest == null) {
      pending.filter { it.state != WorkInfo.State.RUNNING }.forEach { manager.cancelWorkById(it.id) }
      manager.cancelUniqueWork(SWEEP_WORK)
      return@withLock
    }
    manager.enqueueUniquePeriodicWork(SWEEP_WORK, ExistingPeriodicWorkPolicy.KEEP, sweepRequest())
    val target = DUE_AT_PREFIX + earliest
    var alreadyScheduled = false
    for (info in pending) {
      when {
        target in info.tags -> alreadyScheduled = true
        info.state != WorkInfo.State.RUNNING -> manager.cancelWorkById(info.id)
      }
    }
    if (!alreadyScheduled) manager.enqueue(dueRequest(earliest))
  }

  /** KEEP: a second tap while the first request is pending never enqueues a second paid run. */
  fun enqueueRunNow(taskId: String) {
    val request = OneTimeWorkRequestBuilder<ScheduledTaskWorker>()
      .setInputData(
        workDataOf(
          ScheduledTaskWorker.KEY_KIND to ScheduledTaskWorker.KIND_RUN,
          ScheduledTaskWorker.KEY_TASK_ID to taskId,
          // One ID per request: a re-executed worker must not claim (and pay for) a second run.
          ScheduledTaskWorker.KEY_REQUEST_ID to UUID.randomUUID().toString(),
        )
      )
      // No network constraint: a local-network provider must still work, and an offline run
      // fails visibly instead of starting unexpectedly hours later.
      .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
      .addTag(TAG_RUN_NOW)
      .addTag(TASK_PREFIX + taskId)
      .build()
    workManager.enqueueUniqueWork(RUN_NOW_PREFIX + taskId, ExistingWorkPolicy.KEEP, request)
  }

  fun cancelRunNow(taskId: String) {
    workManager.cancelUniqueWork(RUN_NOW_PREFIX + taskId)
  }

  /**
   * Task IDs with a Run now request that has not started yet (survives process death). Running
   * requests are reported by the runner itself, which knows when the run actually ends.
   */
  fun observePendingRunNow(): Flow<Set<String>> =
    workManager.getWorkInfosByTagFlow(TAG_RUN_NOW).map { infos ->
      infos.asSequence()
        .filter { it.state == WorkInfo.State.ENQUEUED || it.state == WorkInfo.State.BLOCKED }
        .mapNotNull { info -> info.tags.firstOrNull { it.startsWith(TASK_PREFIX) }?.removePrefix(TASK_PREFIX) }
        .toSet()
    }

  private fun dueRequest(at: Long) = OneTimeWorkRequestBuilder<ScheduledTaskWorker>()
    .setInputData(workDataOf(ScheduledTaskWorker.KEY_KIND to ScheduledTaskWorker.KIND_DUE))
    .setConstraints(networkConstraint())
    .addTag(TAG_DUE)
    .addTag(DUE_AT_PREFIX + at)
    .apply {
      val delay = at - System.currentTimeMillis()
      // Expedited work cannot have an initial delay; it is used only once the run is due.
      if (delay > 0) setInitialDelay(delay, TimeUnit.MILLISECONDS)
      else setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
    }
    .build()

  private fun sweepRequest() = PeriodicWorkRequestBuilder<ScheduledTaskWorker>(1, TimeUnit.HOURS)
    .setInputData(workDataOf(ScheduledTaskWorker.KEY_KIND to ScheduledTaskWorker.KIND_SWEEP))
    .setConstraints(networkConstraint())
    .addTag(TAG_SWEEP)
    .build()

  private fun networkConstraint() = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

  private companion object {
    const val SWEEP_WORK = "turing.scheduled-prompts.sweep"
    const val RUN_NOW_PREFIX = "turing.scheduled-prompts.run."
    const val TAG_DUE = "turing.scheduled-prompts.due"
    const val TAG_SWEEP = "turing.scheduled-prompts.sweep"
    const val TAG_RUN_NOW = "turing.scheduled-prompts.run-now"
    const val DUE_AT_PREFIX = "turing.scheduled-prompts.due-at:"
    const val TASK_PREFIX = "turing.scheduled-prompts.task:"
  }
}

package com.omergirgin.mosaic.data.tasks

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import com.omergirgin.mosaic.data.DataContainer

/**
 * Background entry point for scheduled prompts (instantiated by WorkManager's default factory).
 * Run results, including failures, are recorded on the task itself, so the work always succeeds;
 * WorkManager retries would only risk a second paid request.
 */
class ScheduledTaskWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

  override suspend fun doWork(): Result {
    val tasks = DataContainer.create(applicationContext).tasks as? ScheduledTaskRepositoryImpl ?: return Result.success()
    when (inputData.getString(KEY_KIND)) {
      KIND_RUN -> inputData.getString(KEY_TASK_ID)?.let { tasks.runner.runManual(it, inputData.getString(KEY_REQUEST_ID)) }
      // A sweep may already be running in the foreground; wait for it rather than skipping.
      else -> tasks.runner.runDueTasks(waitForOtherSweep = true)
    }
    tasks.reconcileSchedule()
    return Result.success()
  }

  override suspend fun getForegroundInfo(): ForegroundInfo = TaskNotifier(applicationContext).foregroundInfo()

  internal companion object {
    const val KEY_KIND = "kind"
    const val KEY_TASK_ID = "taskId"
    const val KEY_REQUEST_ID = "requestId"
    const val KIND_DUE = "due"
    const val KIND_SWEEP = "sweep"
    const val KIND_RUN = "run"
  }
}

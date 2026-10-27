package com.omergirgin.mosaic.data.tasks

import android.util.Log
import androidx.room.withTransaction
import com.omergirgin.mosaic.core.scheduling.ScheduleCalculator
import com.omergirgin.mosaic.core.scheduling.ScheduleRecurrence
import com.omergirgin.mosaic.data.api.ChatEngine
import com.omergirgin.mosaic.data.api.ConversationRepository
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.ScheduledTaskEntity
import com.omergirgin.mosaic.data.db.ScheduledTaskRunEntity
import com.omergirgin.mosaic.data.db.choiceOf
import com.omergirgin.mosaic.data.internal.ErrorSanitizer
import com.omergirgin.mosaic.data.internal.FieldLimits
import com.omergirgin.mosaic.data.internal.newId
import com.omergirgin.mosaic.data.model.MessageStatus
import com.omergirgin.mosaic.data.repo.ProviderRepositoryImpl
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext

/**
 * Port of iOS `ForegroundTaskRunner.execute`, shared by the foreground sweep, the WorkManager
 * workers and Run now:
 * 1. reserve the task in this process (no concurrent double run);
 * 2. persist the execution claim (last run, "interrupted" error, advanced next run, one-time
 *    status failed) together with a run row, before any provider request. A process that dies
 *    mid-run therefore never leaves a due task that would be charged again automatically;
 * 3. create a chat in the task's project with the exact model and run the prompt through the
 *    normal chat pipeline (project + memory context, receipt, usage);
 * 4. record the result and advance the schedule in the task's stored time zone.
 *
 * Execution runs in the application scope: a stopped worker or a backgrounded app does not
 * cancel a paid request that already started; it still records its terminal state.
 */
internal class TaskRunner(
  private val db: MosaicDatabase,
  private val providers: ProviderRepositoryImpl,
  private val conversations: ConversationRepository,
  private val chat: ChatEngine,
  private val notifier: TaskNotifier,
  private val scope: CoroutineScope,
  /** Orphan-run repair; nothing runs before it finished. */
  private val ready: Job,
  private val onScheduleChanged: suspend () -> Unit,
) {
  private val dao = db.scheduledTasks()
  private val lock = Any()
  private val running = HashSet<String>()
  /** Run now requests waiting for their worker, with the request time. */
  private val queued = HashMap<String, Long>()
  private val _running = MutableStateFlow<Set<String>>(emptySet())
  private val _queued = MutableStateFlow<Set<String>>(emptySet())
  val runningIds: StateFlow<Set<String>> = _running.asStateFlow()
  val queuedIds: StateFlow<Set<String>> = _queued.asStateFlow()
  private val sweep = Mutex()

  fun isRunning(taskId: String): Boolean = synchronized(lock) { taskId in running }

  /** Synchronous Run now reservation; false when the task is already queued or running. */
  fun requestManual(taskId: String): Boolean = synchronized(lock) {
    if (taskId in running || isQueued(taskId, System.currentTimeMillis())) return false
    queued[taskId] = System.currentTimeMillis()
    publish()
    true
  }

  fun withdrawManual(taskId: String) = synchronized(lock) {
    queued.remove(taskId)
    publish()
  }

  /** Runs every due active task once, oldest first. Returns without work if another sweep runs. */
  suspend fun runDueTasks(waitForOtherSweep: Boolean, shouldContinue: () -> Boolean = { true }) {
    ready.join()
    if (waitForOtherSweep) sweep.lock() else if (!sweep.tryLock()) return
    try {
      // A queued task may have been edited or deleted while an earlier one ran; each run re-reads it.
      for (taskId in dao.dueIds(System.currentTimeMillis())) {
        if (!shouldContinue()) return
        execute(taskId, TaskRunTrigger.SCHEDULED, requestId = null)
      }
    } finally {
      sweep.unlock()
    }
  }

  /**
   * Run now. [requestId] identifies one request: a worker re-executed after its process died
   * finds the run it already claimed and does nothing, instead of sending a second request.
   */
  suspend fun runManual(taskId: String, requestId: String?): Boolean = execute(taskId, TaskRunTrigger.MANUAL, requestId)

  // region execution

  private class Claim(val task: ScheduledTaskEntity, val runId: String, val attemptedAt: Long, val trigger: TaskRunTrigger)

  private suspend fun execute(taskId: String, trigger: TaskRunTrigger, requestId: String?): Boolean {
    ready.join()
    if (!reserve(taskId, manual = trigger == TaskRunTrigger.MANUAL)) return false
    val work = scope.async {
      try {
        perform(taskId, trigger, requestId)
      } finally {
        release(taskId)
      }
    }
    return work.await()
  }

  private suspend fun perform(taskId: String, trigger: TaskRunTrigger, requestId: String?): Boolean {
    val claim: Claim? = try {
      claim(taskId, trigger, requestId)
    } catch (error: Exception) {
      Log.w(TAG, "Could not claim a scheduled prompt (${error.javaClass.simpleName}).")
      null
    }
    if (claim == null) return false
    // The next occurrence is scheduled before the request, so it survives this process dying.
    runCatching { onScheduleChanged() }

    var conversationId: String? = null
    var failure: String? = INTERRUPTED_MESSAGE
    try {
      failure = runPrompt(claim) { conversationId = it }
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      failure = ErrorSanitizer.describe(error, null)
    } finally {
      withContext(NonCancellable) {
        val linked = record(claim, failure, conversationId)
        notifier.notifyRunFinished(claim.task.id, claim.task.title, succeeded = failure == null, conversationId = linked)
        runCatching { onScheduleChanged() }
      }
    }
    return true
  }

  /** Returns null on success, else the user-facing failure. */
  private suspend fun runPrompt(claim: Claim, onConversation: (String?) -> Unit): String? {
    val task = claim.task
    val choice = choiceOf(task.providerId, task.modelId)
      ?: throw IllegalStateException("Choose a model for this automation before it can run.")
    // Exact enabled model on an enabled chat connection; never a silent fallback to another model.
    providers.resolveModel(choice)
    task.projectId?.let { projectId ->
      val project = db.projects().get(projectId)
        ?: throw IllegalStateException("This automation's project was deleted. Edit the automation to choose a project.")
      check(!project.isArchived) { "This automation's project is archived. Restore the project or choose another one." }
    }
    FieldLimits.requireWithin(task.prompt, FieldLimits.MESSAGE_CONTENT_BYTES, "The prompt")

    val conversation = conversations.createConversation(task.projectId, choice)
    onConversation(conversation.id)
    db.withTransaction {
      dao.setLastConversation(task.id, conversation.id)
      dao.setRunConversation(claim.runId, conversation.id)
    }

    val outcome = chat.runAndAwait(conversation.id, task.prompt)
    if (outcome.assistantMessageId == null) {
      // Rejected before anything was persisted or sent: do not leave a blank chat behind.
      onConversation(null)
      runCatching { conversations.delete(conversation.id) }
    } else {
      runCatching { conversations.rename(conversation.id, displayTaskTitle(task.title)) }
    }
    return when (outcome.status) {
      MessageStatus.COMPLETE -> null
      MessageStatus.CANCELLED -> "The run was stopped before the reply finished."
      else -> outcome.errorMessage?.takeIf { it.isNotBlank() } ?: "The run didn't finish. Open the result chat for details."
    }
  }

  private suspend fun claim(taskId: String, trigger: TaskRunTrigger, requestId: String?): Claim? = db.withTransaction {
    if (requestId != null && dao.hasRunForRequest(requestId)) return@withTransaction null
    val task = dao.get(taskId) ?: return@withTransaction null
    val now = System.currentTimeMillis()
    if (trigger == TaskRunTrigger.SCHEDULED) {
      val nextRunAt = task.nextRunAt
      if (task.statusValue != ScheduledTaskStatus.ACTIVE || nextRunAt == null || nextRunAt > now) return@withTransaction null
    }
    val schedule = task.schedule()
    dao.update(
      task.copy(
        lastRunAt = now,
        lastError = INTERRUPTED_MESSAGE,
        nextRunAt = ScheduleCalculator.nextRunAfterAttempt(schedule, now, succeeded = false),
        status = if (schedule.recurrence == ScheduleRecurrence.ONCE) ScheduledTaskStatus.FAILED.rawValue else task.status,
        updatedAt = now,
      )
    )
    val runId = newId()
    dao.insertRun(
      ScheduledTaskRunEntity(
        id = runId,
        taskId = taskId,
        requestId = requestId,
        trigger = trigger.rawValue,
        status = TaskRunStatus.RUNNING.rawValue,
        startedAt = now,
        finishedAt = null,
        conversationId = null,
        errorMessage = null,
      )
    )
    Claim(task, runId, now, trigger)
  }

  /** Records the terminal state; returns the result chat that still exists, if any. */
  private suspend fun record(claim: Claim, failure: String?, conversationId: String?): String? = try {
    val finishedAt = System.currentTimeMillis()
    db.withTransaction {
      // The chat may have been deleted meanwhile; linking it would violate the foreign key.
      val linked = conversationId?.takeIf { db.conversations().get(it) != null }
      val current = dao.get(claim.task.id)
      if (current != null) dao.update(resultRow(claim, current, failure, linked, finishedAt))
      dao.finishRun(
        id = claim.runId,
        status = (if (failure == null) TaskRunStatus.SUCCEEDED else TaskRunStatus.FAILED).rawValue,
        finishedAt = finishedAt,
        conversationId = linked,
        errorMessage = failure,
      )
      dao.pruneRuns(claim.task.id, KEPT_RUNS)
      linked
    }
  } catch (error: Exception) {
    // The claim already marked the task as interrupted, which stays visible.
    Log.w(TAG, "Could not record a scheduled prompt result (${error.javaClass.simpleName}).")
    null
  }

  private fun resultRow(
    claim: Claim,
    current: ScheduledTaskEntity,
    failure: String?,
    conversationId: String?,
    finishedAt: Long,
  ): ScheduledTaskEntity {
    val snapshot = claim.task
    val schedule = snapshot.schedule()
    // Re-scheduled while running: the edit already defined the next occurrence and status.
    val sameSchedule = current.scheduleKey() == snapshot.scheduleKey()
    val succeeded = failure == null
    val status = when {
      !sameSchedule -> current.statusValue
      succeeded -> successStatus(schedule.recurrence, current.statusValue, snapshot.statusValue, claim.trigger)
      else -> failureStatus(schedule.recurrence, current.statusValue, snapshot.statusValue)
    }
    return current.copy(
      status = status.rawValue,
      lastRunAt = finishedAt,
      lastError = failure,
      nextRunAt = if (sameSchedule) {
        ScheduleCalculator.nextRunAfterAttempt(schedule, claim.attemptedAt, succeeded)
      } else {
        current.nextRunAt
      },
      lastConversationId = conversationId ?: current.lastConversationId,
      updatedAt = finishedAt,
    )
  }

  /** iOS `resultingStatus`: Run now never silently un-pauses a paused recurring task. */
  private fun successStatus(
    recurrence: ScheduleRecurrence,
    current: ScheduledTaskStatus,
    previous: ScheduledTaskStatus,
    trigger: TaskRunTrigger,
  ): ScheduledTaskStatus = when {
    recurrence == ScheduleRecurrence.ONCE -> ScheduledTaskStatus.COMPLETED
    current == ScheduledTaskStatus.PAUSED -> ScheduledTaskStatus.PAUSED
    trigger == TaskRunTrigger.MANUAL && previous == ScheduledTaskStatus.PAUSED -> ScheduledTaskStatus.PAUSED
    else -> ScheduledTaskStatus.ACTIVE
  }

  /** iOS `resultingFailureStatus`: a transient failure never disables an active recurring task. */
  private fun failureStatus(
    recurrence: ScheduleRecurrence,
    current: ScheduledTaskStatus,
    previous: ScheduledTaskStatus,
  ): ScheduledTaskStatus = when {
    recurrence == ScheduleRecurrence.ONCE -> ScheduledTaskStatus.FAILED
    current == ScheduledTaskStatus.PAUSED -> ScheduledTaskStatus.PAUSED
    previous == ScheduledTaskStatus.ACTIVE -> ScheduledTaskStatus.ACTIVE
    previous == ScheduledTaskStatus.PAUSED -> ScheduledTaskStatus.PAUSED
    else -> ScheduledTaskStatus.FAILED
  }

  // endregion

  // region reservation

  private fun reserve(taskId: String, manual: Boolean): Boolean = synchronized(lock) {
    val now = System.currentTimeMillis()
    if (manual) {
      queued.remove(taskId)
    } else if (isQueued(taskId, now)) {
      // A pending Run now owns the next run; the sweep must not issue a second request.
      return false
    }
    val reserved = running.add(taskId)
    publish()
    reserved
  }

  private fun release(taskId: String) = synchronized(lock) {
    running.remove(taskId)
    publish()
  }

  /** Stale requests (their worker never started) stop blocking scheduled runs after a while. */
  private fun isQueued(taskId: String, now: Long): Boolean {
    val requestedAt = queued[taskId] ?: return false
    if (now - requestedAt < QUEUE_GRACE_MS) return true
    queued.remove(taskId)
    return false
  }

  private fun publish() {
    _running.value = running.toSet()
    _queued.value = queued.keys.toSet()
  }

  // endregion

  companion object {
    const val INTERRUPTED_MESSAGE = "The previous run was interrupted before completion."
    private const val TAG = "TuringTasks"
    private const val KEPT_RUNS = 50
    private const val QUEUE_GRACE_MS = 10 * 60 * 1_000L
  }
}

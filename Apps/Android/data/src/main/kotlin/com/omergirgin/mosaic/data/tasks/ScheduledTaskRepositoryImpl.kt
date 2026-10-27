package com.omergirgin.mosaic.data.tasks

import android.content.Context
import android.util.Log
import androidx.room.withTransaction
import com.omergirgin.mosaic.core.scheduling.ScheduleCalculator
import com.omergirgin.mosaic.core.scheduling.ScheduleRecurrence
import com.omergirgin.mosaic.core.scheduling.TaskSchedule
import com.omergirgin.mosaic.data.api.ChatEngine
import com.omergirgin.mosaic.data.api.ConversationRepository
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.ScheduledTaskEntity
import com.omergirgin.mosaic.data.internal.FieldLimits
import com.omergirgin.mosaic.data.internal.newId
import com.omergirgin.mosaic.data.repo.ProviderRepositoryImpl
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

internal class ScheduledTaskRepositoryImpl(
  context: Context,
  private val db: MosaicDatabase,
  private val providers: ProviderRepositoryImpl,
  conversations: ConversationRepository,
  chat: ChatEngine,
  scope: CoroutineScope,
  /** The chat engine's startup repair; orphan runs are repaired after it, once per process. */
  messagesReady: Job,
) : ScheduledTaskRepository {
  private val appContext = context.applicationContext
  private val dao = db.scheduledTasks()
  private val notifier = TaskNotifier(appContext)
  private val scheduler = TaskWorkScheduler(appContext, dao)
  private val foreground = MutableStateFlow(false)

  /** No run survives its process: every run row still marked running is an interrupted orphan. */
  private val ready: Job = scope.launch {
    messagesReady.join()
    runCatching { dao.interruptOrphans(ORPHAN_MESSAGE, System.currentTimeMillis()) }
  }

  internal val runner = TaskRunner(db, providers, conversations, chat, notifier, scope, ready) { reconcileSchedule() }

  init {
    scope.launch {
      ready.join()
      reconcileSchedule()
    }
    // iOS foreground sweep: every 30 s while visible. Leaving the app stops the loop between
    // tasks; a run that already started finishes in the application scope.
    scope.launch {
      foreground.collectLatest { visible ->
        if (!visible) return@collectLatest
        reconcileSchedule()
        while (true) {
          try {
            runner.runDueTasks(waitForOtherSweep = false) { foreground.value }
          } catch (error: CancellationException) {
            throw error
          } catch (error: Exception) {
            Log.w(TAG, "Foreground sweep failed (${error.javaClass.simpleName}).")
          }
          delay(FOREGROUND_SWEEP_MS)
        }
      }
    }
  }

  override fun observeTasks(): Flow<List<ScheduledTask>> =
    dao.observeAll().map { rows -> rows.map { it.toModel() } }.distinctUntilChanged()

  override fun observeTask(id: String): Flow<ScheduledTask?> =
    dao.observe(id).map { it?.toModel() }.distinctUntilChanged()

  override fun observeRuns(taskId: String, limit: Int): Flow<List<ScheduledTaskRun>> =
    dao.observeRuns(taskId, limit.coerceIn(1, 50)).map { rows -> rows.map { it.toModel() } }.distinctUntilChanged()

  override val activity: Flow<Map<String, TaskActivity>> = combine(
    runner.runningIds,
    runner.queuedIds,
    scheduler.observePendingRunNow().catch { emit(emptySet()) },
  ) { running, queued, pendingWork ->
    buildMap {
      (queued + pendingWork).forEach { put(it, TaskActivity.QUEUED) }
      running.forEach { put(it, TaskActivity.RUNNING) }
    }
  }.distinctUntilChanged()

  override suspend fun save(draft: ScheduledTaskDraft): ScheduledTask {
    val title = draft.title.trim()
    val prompt = draft.prompt.trim()
    require(title.isNotEmpty()) { "Enter a title." }
    require(prompt.isNotEmpty()) { "Enter the prompt to send." }
    FieldLimits.requireWithin(title, FieldLimits.CONVERSATION_TITLE_BYTES, "The title")
    FieldLimits.requireWithin(prompt, FieldLimits.MESSAGE_CONTENT_BYTES, "The prompt")
    if (draft.recurrence == ScheduleRecurrence.WEEKLY) require(draft.weekdays.isNotEmpty()) { "Choose at least one weekday." }
    val zoneId = ScheduleCalculator.zoneOf(draft.timeZoneId).id
    // iOS canSave: only an enabled model on an enabled chat connection can be chosen.
    providers.resolveModel(draft.model)
    val mask = if (draft.recurrence == ScheduleRecurrence.WEEKLY) ScheduleCalculator.weekdayMask(draft.weekdays) else 0
    val now = System.currentTimeMillis()

    val saved = db.withTransaction {
      val existing = draft.id?.let { id -> requireNotNull(dao.get(id)) { "This automation no longer exists." } }
      if (draft.projectId != null && draft.projectId != existing?.projectId) {
        val project = requireNotNull(db.projects().get(draft.projectId)) { "This project no longer exists." }
        require(!project.isArchived) { "This project is archived. Restore it or choose another project." }
      }
      val schedule = TaskSchedule(draft.recurrence, draft.startAt, zoneId, draft.weekdays)
      if (existing == null) {
        ScheduledTaskEntity(
          id = newId(),
          title = title,
          prompt = prompt,
          recurrence = draft.recurrence.rawValue,
          status = ScheduledTaskStatus.ACTIVE.rawValue,
          scheduledAt = draft.startAt,
          weekdayMask = mask,
          timeZoneId = zoneId,
          providerId = draft.model.providerId,
          modelId = draft.model.modelId,
          projectId = draft.projectId,
          nextRunAt = ScheduleCalculator.initialNextRun(schedule, now),
          lastRunAt = null,
          lastError = null,
          lastConversationId = null,
          createdAt = now,
          updatedAt = now,
        ).also { dao.insert(it) }
      } else {
        check(!runner.isRunning(existing.id)) { "This automation is running. Try again when it finishes." }
        var updated = existing.copy(
          title = title,
          prompt = prompt,
          providerId = draft.model.providerId,
          modelId = draft.model.modelId,
          projectId = draft.projectId,
          updatedAt = now,
        )
        // Compared by effective run days, so an iOS-style row (mask 0) is not re-anchored by a
        // title edit. The time zone alone never re-schedules a task.
        val rescheduled = existing.recurrence != draft.recurrence.rawValue ||
          existing.scheduledAt != draft.startAt ||
          (draft.recurrence == ScheduleRecurrence.WEEKLY && ScheduleCalculator.runDays(existing.schedule()) != draft.weekdays)
        if (rescheduled) {
          // A new occurrence; a paused task stays paused, a finished or failed one becomes active.
          val reactivate = existing.statusValue == ScheduledTaskStatus.COMPLETED || existing.statusValue == ScheduledTaskStatus.FAILED
          updated = updated.copy(
            recurrence = draft.recurrence.rawValue,
            scheduledAt = draft.startAt,
            weekdayMask = mask,
            timeZoneId = zoneId,
            nextRunAt = ScheduleCalculator.initialNextRun(schedule, now),
            status = if (reactivate) ScheduledTaskStatus.ACTIVE.rawValue else existing.status,
            lastError = if (reactivate) null else existing.lastError,
          )
        }
        dao.update(updated)
        updated
      }
    }
    reconcileSchedule()
    return saved.toModel()
  }

  override suspend fun setPaused(id: String, paused: Boolean) {
    check(!runner.isRunning(id)) { "This automation is running. Try again when it finishes." }
    val changed = db.withTransaction {
      val current = dao.get(id) ?: return@withTransaction false
      val now = System.currentTimeMillis()
      val status = current.statusValue
      val updated = if (paused) {
        if (status != ScheduledTaskStatus.ACTIVE) return@withTransaction false
        current.copy(status = ScheduledTaskStatus.PAUSED.rawValue, updatedAt = now)
      } else {
        if (status != ScheduledTaskStatus.PAUSED && status != ScheduledTaskStatus.FAILED) return@withTransaction false
        val schedule = current.schedule()
        val next = if (schedule.recurrence == ScheduleRecurrence.ONCE) {
          check(schedule.startAt > now) { "This one-time prompt's time has passed. Choose a new time, or use Run now." }
          schedule.startAt
        } else {
          ScheduleCalculator.nextOccurrence(schedule, now)
        }
        current.copy(status = ScheduledTaskStatus.ACTIVE.rawValue, lastError = null, nextRunAt = next, updatedAt = now)
      }
      dao.update(updated)
      true
    }
    if (changed) reconcileSchedule()
  }

  override suspend fun delete(id: String) {
    check(!runner.isRunning(id)) { "This automation is running. Delete it when the run finishes." }
    runner.withdrawManual(id)
    runCatching { scheduler.cancelRunNow(id) }
    dao.delete(id)
    notifier.cancel(id)
    reconcileSchedule()
  }

  override fun runNow(id: String): Boolean {
    if (!runner.requestManual(id)) return false
    try {
      scheduler.enqueueRunNow(id)
    } catch (error: Exception) {
      runner.withdrawManual(id)
      throw IllegalStateException("Turing AI couldn't start this run. Try again.", error)
    }
    return true
  }

  override fun setAppInForeground(foreground: Boolean) {
    this.foreground.value = foreground
  }

  /** Never throws: scheduling problems must not fail a save or a recorded run. */
  internal suspend fun reconcileSchedule() {
    try {
      scheduler.reconcile()
    } catch (error: Exception) {
      if (error is CancellationException) throw error
      Log.w(TAG, "Could not update background scheduling (${error.javaClass.simpleName}).")
    }
  }

  private companion object {
    const val TAG = "TuringTasks"
    const val FOREGROUND_SWEEP_MS = 30_000L
    const val ORPHAN_MESSAGE =
      "Turing AI stopped before this run finished. It was not retried automatically, because the request may already have been sent."
  }
}

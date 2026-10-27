package com.omergirgin.mosaic.data.chat

import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Process-wide registry of in-flight generations (iOS `ConversationRequestRegistry`). Registering
 * is atomic and happens before the job starts, which is what serializes generations per
 * conversation and guarantees `stop` can always reach the running job.
 */
internal class GenerationRegistry {
  private val lock = Any()
  private val jobs = HashMap<String, Job>()
  private val _active = MutableStateFlow<Set<String>>(emptySet())
  val active: StateFlow<Set<String>> = _active.asStateFlow()

  /** Returns false (and leaves [job] unregistered) when [conversationId] is already busy. */
  fun register(conversationId: String, job: Job): Boolean = synchronized(lock) {
    if (jobs.containsKey(conversationId)) return false
    jobs[conversationId] = job
    _active.value = jobs.keys.toSet()
    true
  }

  fun release(conversationId: String, job: Job) {
    synchronized(lock) {
      if (jobs[conversationId] !== job) return
      jobs.remove(conversationId)
      _active.value = jobs.keys.toSet()
    }
  }

  fun isActive(conversationId: String): Boolean = synchronized(lock) { jobs.containsKey(conversationId) }

  fun cancel(conversationId: String) {
    synchronized(lock) { jobs[conversationId] }?.cancel()
  }

  /** Cancels and waits until the generation has written its terminal state. */
  suspend fun cancelAndJoin(conversationId: String) {
    val job = synchronized(lock) { jobs[conversationId] } ?: return
    job.cancel()
    job.join()
  }
}

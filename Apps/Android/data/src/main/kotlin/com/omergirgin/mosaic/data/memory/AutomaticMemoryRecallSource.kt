package com.omergirgin.mosaic.data.memory

import com.omergirgin.mosaic.core.context.MemoryContextScope
import com.omergirgin.mosaic.core.context.utf8Length
import com.omergirgin.mosaic.core.memory.MemoryTopicKind
import com.omergirgin.mosaic.core.memory.MemoryTopicStatus
import com.omergirgin.mosaic.core.memory.RecentEventMemoryPolicy
import com.omergirgin.mosaic.core.memory.sha256Hex
import com.omergirgin.mosaic.data.db.MemoryTopicEntity
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.recall.RecallAttributes
import com.omergirgin.mosaic.data.recall.RecallCandidate
import com.omergirgin.mosaic.data.recall.RecallCandidateSource
import com.omergirgin.mosaic.data.recall.RecallMessageSuppression
import com.omergirgin.mosaic.data.recall.RecallScope
import com.omergirgin.mosaic.data.recall.RecallSourceKind
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

/**
 * Active learned topics as recall candidates (iOS `SemanticMemoryRetrievalStore.accessibleTopics`).
 * Paused, forgotten and disabled topics never leave this source. The exact global, current-chat
 * and current-project partitions are each read before the shared cap is applied, so unrelated
 * project volume cannot starve an eligible topic. Retrieval owns ranking and rendering.
 *
 * Also suppresses raw recall of user messages already consolidated as topic evidence, so pausing,
 * forgetting or correcting a topic cannot be bypassed through its old source excerpt.
 */
internal class AutomaticMemoryRecallSource(db: MosaicDatabase) : RecallCandidateSource, RecallMessageSuppression {
  private val dao = db.automaticMemory()

  override suspend fun candidates(scope: RecallScope): List<RecallCandidate> {
    val global = dao.recallGlobalTopics(MAXIMUM_CANDIDATES)
    val conversation = dao.recallConversationTopics(scope.conversationId, MAXIMUM_CANDIDATES)
    val project = scope.projectId?.let { dao.recallProjectTopics(it, MAXIMUM_CANDIDATES) } ?: emptyList()
    val ordered = (global + conversation + project)
      .distinctBy { it.id }
      .sortedWith(
        compareByDescending<MemoryTopicEntity> { it.importance }
          .thenByDescending { it.updatedAt }
          .thenBy { it.id }
      )
    val now = System.currentTimeMillis()
    val selected = mutableListOf<RecallCandidate>()
    var bytes = 0L
    for (topic in ordered) {
      if (selected.size >= MAXIMUM_CANDIDATES) break
      bytes += utf8Length(topic.title) + utf8Length(topic.content)
      if (bytes > MAXIMUM_CANDIDATE_BYTES) break
      selected += candidate(topic, now)
    }
    return selected
  }

  /** By-ID revalidation: still active and enabled, same text, still inside the audience. */
  override suspend fun validate(scope: RecallScope, candidates: List<RecallCandidate>): Set<String> {
    val expected = candidates.filter { it.kind == RecallSourceKind.MEMORY_TOPIC }.associateBy { it.id }
    if (expected.isEmpty()) return emptySet()
    val valid = HashSet<String>()
    for (page in expected.keys.chunked(SQL_CHUNK)) {
      for (topic in dao.topics(page)) {
        val candidate = expected[topic.id] ?: continue
        val fingerprint = sha256Hex(text(topic))
        if (topic.status == MemoryTopicStatus.ACTIVE.rawValue && topic.isEnabled && isVisible(topic, scope) &&
          candidate.contentFingerprint == fingerprint && candidate.containerId == topic.id
        ) {
          valid += topic.id
        }
      }
    }
    return valid
  }

  override suspend fun suppressedMessageIds(messageIds: List<String>): Set<String> =
    messageIds.distinct().chunked(SQL_CHUNK).flatMapTo(HashSet()) { dao.consolidatedMessageIds(it) }

  /** Records that these topics were included in a sent request (usage counters only). */
  suspend fun recordUse(topicIds: Collection<String>) {
    if (topicIds.isEmpty()) return
    val now = MonotonicClock.now()
    topicIds.distinct().chunked(SQL_CHUNK).forEach { dao.recordUse(it, now) }
  }

  private fun isVisible(topic: MemoryTopicEntity, scope: RecallScope): Boolean = when (topic.scope) {
    MemoryContextScope.GLOBAL.rawValue -> topic.conversationId == null && topic.projectId == null
    MemoryContextScope.CONVERSATION.rawValue -> topic.conversationId == scope.conversationId && topic.projectId == null
    MemoryContextScope.PROJECT.rawValue -> topic.conversationId == null && scope.projectId != null && topic.projectId == scope.projectId
    else -> false
  }

  private fun text(topic: MemoryTopicEntity) = "${topic.title}: ${topic.content}"

  private fun candidate(topic: MemoryTopicEntity, now: Long): RecallCandidate {
    val isEvent = topic.kind == MemoryTopicKind.EVENT.rawValue
    val text = text(topic)
    return RecallCandidate(
      kind = RecallSourceKind.MEMORY_TOPIC,
      id = topic.id,
      containerId = topic.id,
      title = topic.title,
      text = text,
      contentFingerprint = sha256Hex(text),
      createdAt = topic.updatedAt,
      // An event is a dated personal report, not a permanent fact; recorded_at is when it was
      // reported, not necessarily when it happened.
      attributes = if (isEvent) {
        mapOf(
          RecallAttributes.MEMORY_LAYER to RecallAttributes.MEMORY_LAYER_EVENT,
          RecallAttributes.RECORDED_AT to iso(topic.lastConfirmedAt),
        )
      } else {
        emptyMap()
      },
      // Event recency decay: 45-day half-life, 40% floor (plus the retriever's top-rank shield). Lasting topics are neutral.
      weight = if (isEvent) RecentEventMemoryPolicy.relevanceWeight(topic.lastConfirmedAt, now) else 1.0,
      confidence = topic.confidence,
      importance = topic.importance,
    )
  }

  private fun iso(millis: Long): String =
    DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(millis).truncatedTo(ChronoUnit.SECONDS))

  private companion object {
    const val MAXIMUM_CANDIDATES = 5_000
    const val MAXIMUM_CANDIDATE_BYTES = 8L * 1_024 * 1_024
    const val SQL_CHUNK = 500
  }
}

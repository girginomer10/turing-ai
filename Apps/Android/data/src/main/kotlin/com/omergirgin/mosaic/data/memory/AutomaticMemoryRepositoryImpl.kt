package com.omergirgin.mosaic.data.memory

import androidx.room.withTransaction
import com.omergirgin.mosaic.core.context.MemoryContextScope
import com.omergirgin.mosaic.core.memory.AutomaticMemoryRules
import com.omergirgin.mosaic.core.memory.MemoryFormationJobStatus
import com.omergirgin.mosaic.core.memory.MemoryOrigin
import com.omergirgin.mosaic.core.memory.MemoryRevisionKind
import com.omergirgin.mosaic.core.memory.MemoryStability
import com.omergirgin.mosaic.core.memory.MemoryTopicKind
import com.omergirgin.mosaic.core.memory.MemoryTopicStatus
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.data.db.MemoryEvidenceDetailRow
import com.omergirgin.mosaic.data.db.MemoryFormationAuditEntity
import com.omergirgin.mosaic.data.db.MemoryRevisionEntity
import com.omergirgin.mosaic.data.db.MemoryTopicEntity
import com.omergirgin.mosaic.data.db.MemoryTopicListRow
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.internal.newId
import com.omergirgin.mosaic.data.model.MemoryScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map

/**
 * Memory library reads and the person's direct controls over learned topics (iOS
 * `MosaicMemoryLibraryRepository` and the topic actions in `MemoryLibraryView`). Every edit is a
 * compare-and-swap against the snapshot the person saw, and appends an immutable revision.
 */
internal class AutomaticMemoryRepositoryImpl(
  private val db: MosaicDatabase,
  private val formation: AutomaticMemoryFormation,
) : AutomaticMemoryRepository {
  private val dao = db.automaticMemory()

  override val isRetryingFailedUpdates: StateFlow<Boolean> get() = formation.isRetrying

  override fun observeTopics(query: String): Flow<List<LearnedTopic>> {
    val trimmed = query.trim()
    val pattern = if (trimmed.isEmpty()) "" else "%" + escapeLike(trimmed) + "%"
    return dao.observeTopicRows(pattern, MAXIMUM_LIBRARY_TOPICS)
      .map { rows -> rows.mapNotNull { it.toModel() } }
      .distinctUntilChanged()
      .flowOn(Dispatchers.Default)
  }

  override fun observeTopicDetail(id: String): Flow<LearnedTopicDetail?> {
    val evidence = combine(dao.observeEvidenceRows(id, DETAIL_LIMIT), dao.observeEvidenceCount(id)) { rows, count -> rows to count }
    val revisions = combine(dao.observeRevisions(id, DETAIL_LIMIT), dao.observeRevisionCount(id)) { rows, count -> rows to count }
    return combine(dao.observeTopicRow(id), evidence, revisions) { row, (evidenceRows, evidenceCount), (revisionRows, revisionCount) ->
      val topic = row?.toModel() ?: return@combine null
      LearnedTopicDetail(
        topic = topic,
        evidence = evidenceRows.map { it.toModel() },
        revisions = revisionRows.mapNotNull { it.toModel() },
        totalEvidenceCount = evidenceCount,
        totalRevisionCount = revisionCount,
      )
    }
      .distinctUntilChanged()
      .flowOn(Dispatchers.Default)
  }

  override fun observeActivity(): Flow<MemoryFormationActivity> =
    combine(
      dao.observeRecentAudits(RECENT_RUNS),
      dao.observeFailedJobCount(),
      dao.observeUnfinishedJobCount(),
      dao.observeAuditTotals(),
    ) { audits, failed, unfinished, totals ->
      MemoryFormationActivity(
        recentRuns = audits.map { it.toModel() },
        failedJobCount = failed,
        unfinishedJobCount = unfinished,
        totalProviderRequests = totals.requests,
        totalInputTokens = totals.inputTokens,
        totalOutputTokens = totals.outputTokens,
      )
    }
      .distinctUntilChanged()
      .flowOn(Dispatchers.Default)

  override suspend fun correctTopic(topic: LearnedTopic, title: String, content: String) {
    val newTitle = title.trim()
    val newContent = content.trim()
    require(newTitle.isNotEmpty()) { "Add a title." }
    require(newContent.isNotEmpty()) { "Add the fact Turing AI should remember." }
    AutomaticMemoryRules.textProblem(newTitle, newContent)?.let { throw IllegalArgumentException(it) }
    db.withTransaction {
      val record = current(topic)
      if (record.title == newTitle && record.content == newContent && record.status == MemoryTopicStatus.ACTIVE.rawValue) {
        return@withTransaction
      }
      val now = MonotonicClock.now()
      val nextRevision = record.revision + 1
      val wasForgotten = record.status == MemoryTopicStatus.FORGOTTEN.rawValue
      dao.updateTopic(
        record.copy(
          title = newTitle,
          content = newContent,
          confidence = 1.0,
          status = MemoryTopicStatus.ACTIVE.rawValue,
          isEnabled = if (wasForgotten) true else record.isEnabled,
          origin = MemoryOrigin.MANUAL.rawValue,
          revision = nextRevision,
          lastConfirmedAt = confirmedAt(record, now),
          updatedAt = now,
        )
      )
      insertRevision(record, nextRevision, MemoryRevisionKind.USER_EDITED, newTitle, newContent, now)
    }
  }

  override suspend fun setTopicEnabled(topic: LearnedTopic, enabled: Boolean) {
    db.withTransaction {
      val record = current(topic)
      if (record.status == MemoryTopicStatus.ACTIVE.rawValue && record.isEnabled == enabled) return@withTransaction
      val now = MonotonicClock.now()
      val nextRevision = record.revision + 1
      if (enabled && record.status == MemoryTopicStatus.FORGOTTEN.rawValue) {
        // "Remember again": restoring is the person's decision, so the head becomes manual.
        dao.updateTopic(
          record.copy(
            status = MemoryTopicStatus.ACTIVE.rawValue,
            isEnabled = true,
            origin = MemoryOrigin.MANUAL.rawValue,
            revision = nextRevision,
            lastConfirmedAt = confirmedAt(record, now),
            updatedAt = now,
          )
        )
        insertRevision(record, nextRevision, MemoryRevisionKind.REACTIVATED, record.title, record.content, now)
      } else {
        dao.updateTopic(record.copy(isEnabled = enabled, revision = nextRevision, updatedAt = now))
        insertRevision(
          record, nextRevision, if (enabled) MemoryRevisionKind.USER_ENABLED else MemoryRevisionKind.USER_DISABLED,
          record.title, record.content, now,
        )
      }
    }
  }

  override suspend fun forgetTopic(topic: LearnedTopic) {
    db.withTransaction {
      val record = current(topic)
      check(record.status == MemoryTopicStatus.ACTIVE.rawValue) { CHANGED_MESSAGE }
      val now = MonotonicClock.now()
      val nextRevision = record.revision + 1
      dao.updateTopic(
        record.copy(
          status = MemoryTopicStatus.FORGOTTEN.rawValue,
          isEnabled = false,
          origin = MemoryOrigin.MANUAL.rawValue,
          revision = nextRevision,
          lastConfirmedAt = confirmedAt(record, now),
          updatedAt = now,
        )
      )
      insertRevision(record, nextRevision, MemoryRevisionKind.FORGOTTEN, record.title, record.content, now)
    }
  }

  override suspend fun retryFailedUpdates(): MemoryRetryOutcome = formation.retryFailed()

  // region helpers

  /** The live row, provided it is still exactly what the person saw. */
  private suspend fun current(topic: LearnedTopic): MemoryTopicEntity {
    val record = dao.topic(topic.id) ?: throw IllegalStateException("This memory no longer exists.")
    check(record.revision == topic.revision && record.updatedAt == topic.updatedAt && record.revision < Int.MAX_VALUE) {
      CHANGED_MESSAGE
    }
    return record
  }

  /** Lasting facts are reconfirmed by a person's action; an event keeps its original report date. */
  private fun confirmedAt(record: MemoryTopicEntity, now: Long): Long =
    if (record.kind == MemoryTopicKind.EVENT.rawValue) record.lastConfirmedAt else now

  private suspend fun insertRevision(
    previous: MemoryTopicEntity,
    sequence: Int,
    kind: MemoryRevisionKind,
    title: String,
    content: String,
    now: Long,
  ) {
    dao.insertRevision(
      MemoryRevisionEntity(
        id = newId(),
        revisionKey = "${previous.id}/$sequence",
        topicId = previous.id,
        sequence = sequence,
        kind = kind.rawValue,
        previousTitle = previous.title,
        previousContent = previous.content,
        title = title,
        content = content,
        sourceEvidenceId = null,
        createdAt = now,
      )
    )
  }

  private fun escapeLike(value: String): String = value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")

  // endregion

  private companion object {
    const val MAXIMUM_LIBRARY_TOPICS = 1_000
    const val DETAIL_LIMIT = 100
    const val RECENT_RUNS = 20
    const val CHANGED_MESSAGE = "This memory changed while you were viewing it. Review the latest version and try again."
  }
}

private fun MemoryTopicListRow.toModel(): LearnedTopic? {
  val topic = topic
  return LearnedTopic(
    id = topic.id,
    title = topic.title,
    content = topic.content,
    kind = MemoryTopicKind.fromRaw(topic.kind) ?: MemoryTopicKind.FACT,
    scope = when (topic.scope) {
      MemoryContextScope.PROJECT.rawValue -> MemoryScope.PROJECT
      MemoryContextScope.CONVERSATION.rawValue -> MemoryScope.CONVERSATION
      MemoryContextScope.GLOBAL.rawValue -> MemoryScope.EVERYWHERE
      else -> return null
    },
    projectId = topic.projectId,
    projectName = projectName,
    conversationId = topic.conversationId,
    conversationTitle = conversationTitle,
    status = MemoryTopicStatus.fromRaw(topic.status) ?: MemoryTopicStatus.FORGOTTEN,
    origin = MemoryOrigin.fromRaw(topic.origin) ?: MemoryOrigin.AUTOMATIC,
    isEnabled = topic.isEnabled,
    confidence = topic.confidence,
    importance = topic.importance,
    stability = MemoryStability.fromRaw(topic.stability) ?: MemoryStability.EVOLVING,
    lastConfirmedAt = topic.lastConfirmedAt,
    lastUsedAt = topic.lastUsedAt,
    useCount = topic.useCount,
    evidenceCount = topic.evidenceCount,
    revision = topic.revision,
    createdAt = topic.createdAt,
    updatedAt = topic.updatedAt,
  )
}

private fun MemoryEvidenceDetailRow.toModel() = LearnedTopicEvidence(
  id = evidence.id,
  conversationId = evidence.conversationId,
  conversationTitle = conversationTitle,
  sourceMessageId = evidence.sourceMessageId,
  sourceAvailable = sourceAvailable,
  excerpt = evidence.excerpt,
  providerName = evidence.providerDisplayName,
  providerKind = evidence.providerKind?.let { ProviderKind.fromRawId(it) },
  modelId = evidence.modelIdentifier,
  providerHost = AutomaticMemoryStore.hostOf(evidence.providerEndpoint),
  confidence = evidence.confidence,
  createdAt = evidence.createdAt,
)

private fun MemoryRevisionEntity.toModel(): LearnedTopicRevision? = LearnedTopicRevision(
  id = id,
  sequence = sequence,
  kind = MemoryRevisionKind.fromRaw(kind) ?: return null,
  previousTitle = previousTitle,
  previousContent = previousContent,
  title = title,
  content = content,
  hasSourceEvidence = sourceEvidenceId != null,
  createdAt = createdAt,
)

private fun MemoryFormationAuditEntity.toModel() = MemoryFormationRun(
  id = id,
  jobId = jobId,
  outcome = MemoryFormationJobStatus.fromRaw(outcome) ?: MemoryFormationJobStatus.FAILED,
  attemptCount = attemptCount,
  providerName = providerDisplayName,
  providerKind = providerKind?.let { ProviderKind.fromRawId(it) },
  modelId = modelIdentifier,
  providerHost = AutomaticMemoryStore.hostOf(providerEndpoint),
  requestStarted = requestStarted,
  inputTokens = inputTokenCount,
  outputTokens = outputTokenCount,
  providerRequestCount = providerRequestCount,
  cumulativeInputTokens = cumulativeInputTokenCount,
  cumulativeOutputTokens = cumulativeOutputTokenCount,
  didDiscardInvalidTelemetry = didDiscardInvalidTelemetry,
  errorDescription = errorDescription,
  startedAt = startedAt,
  finishedAt = finishedAt,
)

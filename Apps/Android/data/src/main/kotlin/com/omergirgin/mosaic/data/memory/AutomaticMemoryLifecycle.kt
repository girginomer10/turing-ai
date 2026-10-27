package com.omergirgin.mosaic.data.memory

import com.omergirgin.mosaic.core.context.MemoryContextScope
import com.omergirgin.mosaic.core.memory.AutomaticMemoryRules
import com.omergirgin.mosaic.core.memory.MemoryOrigin
import com.omergirgin.mosaic.core.memory.MemoryRevisionKind
import com.omergirgin.mosaic.core.memory.MemoryTopicKind
import com.omergirgin.mosaic.core.memory.MemoryTopicStatus
import com.omergirgin.mosaic.data.db.MemoryRevisionEntity
import com.omergirgin.mosaic.data.db.MemoryTopicEntity
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.internal.newId

/** A chat move that would widen or split learned memory; the whole move is rejected. */
internal class AutomaticMemoryMoveException(message: String) : IllegalStateException(message)

/**
 * Keeps learned memory inside the audience of the conversations that support it (iOS
 * `MosaicConversationDeletion` topic cascade and `AutomaticMemoryProjectReconciler`). Both entry
 * points must be called inside the caller's Room transaction, before the conversation row changes.
 */
internal object AutomaticMemoryLifecycle {
  private const val SQL_CHUNK = 500

  /**
   * Conversation deletion: removes conversation-scoped topics, detaches the deleted evidence from
   * revision history, preserves manually corrected heads, and deactivates automatic heads that no
   * longer have current supporting evidence. Jobs and audits cascade with the conversation row.
   */
  suspend fun beforeConversationDeletion(db: MosaicDatabase, conversationId: String, now: Long) {
    val dao = db.automaticMemory()
    val scopedTopicIds = dao.conversationScopedTopics(conversationId).map { it.id }.toSet()
    // Evidence and revisions of scoped topics cascade with the topic rows.
    scopedTopicIds.chunked(SQL_CHUNK).forEach { dao.deleteTopics(it) }

    val sourceEvidence = dao.evidenceForConversation(conversationId)
    if (sourceEvidence.isEmpty()) return
    val removedEvidenceIds = sourceEvidence.map { it.id }
    removedEvidenceIds.chunked(SQL_CHUNK).forEach {
      dao.detachEvidence(it)
      dao.deleteEvidence(it)
    }

    val affectedTopicIds = sourceEvidence.map { it.topicId }.toSet() - scopedTopicIds
    for (topicId in affectedTopicIds) {
      val topic = dao.topic(topicId) ?: continue
      val remainingEvidenceIds = dao.evidenceForTopics(listOf(topicId)).map { it.id }.toSet()
      val revisions = dao.revisionsForTopic(topicId)
      // Reinforcement supports the current value only after its last semantic change; an older,
      // contradicted value must not keep the head active merely because its evidence survived.
      val valueRevision = revisions
        .filter { MemoryRevisionKind.fromRaw(it.kind) in VALUE_CHANGES }
        .maxOfOrNull { it.sequence } ?: 0
      val currentValue = AutomaticMemoryRules.normalizedValue(topic.content)
      val hasCurrentEvidence = revisions.any { revision ->
        revision.sequence >= valueRevision &&
          MemoryRevisionKind.fromRaw(revision.kind) in SUPPORTING &&
          revision.sourceEvidenceId != null && revision.sourceEvidenceId in remainingEvidenceIds &&
          AutomaticMemoryRules.normalizedValue(revision.content) == currentValue
      }
      val unsupportedAutomaticHead = topic.origin == MemoryOrigin.AUTOMATIC.rawValue && !hasCurrentEvidence
      if (unsupportedAutomaticHead && topic.status != MemoryTopicStatus.FORGOTTEN.rawValue && topic.revision < Int.MAX_VALUE) {
        val nextRevision = topic.revision + 1
        dao.updateTopic(
          topic.copy(
            status = MemoryTopicStatus.FORGOTTEN.rawValue,
            isEnabled = false,
            evidenceCount = remainingEvidenceIds.size,
            revision = nextRevision,
            updatedAt = now,
          )
        )
        dao.insertRevision(
          MemoryRevisionEntity(
            id = newId(),
            revisionKey = "${topic.id}/$nextRevision",
            topicId = topic.id,
            sequence = nextRevision,
            kind = MemoryRevisionKind.FORGOTTEN.rawValue,
            previousTitle = topic.title,
            previousContent = topic.content,
            title = topic.title,
            content = topic.content,
            sourceEvidenceId = null,
            createdAt = now,
          )
        )
      } else {
        // Provenance changed, but the value was not reconfirmed: no semantic revision.
        dao.updateTopic(topic.copy(evidenceCount = remainingEvidenceIds.size, updatedAt = now))
      }
    }
  }

  /**
   * Project move: atomically rekeys/rebinds automatic topics supported exclusively by this chat,
   * and rejects the move (throws [AutomaticMemoryMoveException]) when a topic's evidence spans
   * other chats, instead of leaving a partially widened memory.
   */
  suspend fun reconcileConversationMove(
    db: MosaicDatabase,
    conversationId: String,
    fromProjectId: String?,
    toProjectId: String?,
    now: Long,
  ) {
    if (fromProjectId == toProjectId) return
    val dao = db.automaticMemory()
    val candidateTopicIds = dao.evidenceForConversation(conversationId).map { it.topicId }.toSet()
    if (candidateTopicIds.isEmpty()) return
    val topics = candidateTopicIds.chunked(SQL_CHUNK).flatMap { dao.topics(it) }
      .filter { it.origin == MemoryOrigin.AUTOMATIC.rawValue }
      .filter { it.scope == MemoryContextScope.GLOBAL.rawValue || it.scope == MemoryContextScope.PROJECT.rawValue }
    if (topics.isEmpty()) return
    val evidenceByTopic = topics.map { it.id }.chunked(SQL_CHUNK).flatMap { dao.evidenceForTopics(it) }.groupBy { it.topicId }

    data class Plan(val topic: MemoryTopicEntity, val updated: MemoryTopicEntity)
    val plans = mutableListOf<Plan>()
    for (topic in topics) {
      val kind = MemoryTopicKind.fromRaw(topic.kind) ?: continue
      val supportingChats = evidenceByTopic[topic.id].orEmpty().map { it.conversationId }.toSet()
      when (topic.scope) {
        MemoryContextScope.GLOBAL.rawValue -> {
          // Leaving a project never widens a global topic; entering one narrows it.
          if (toProjectId == null) continue
          if (supportingChats != setOf(conversationId)) throw mixedEvidence(topic)
          val key = AutomaticMemoryRules.rekeyed(
            topic.canonicalKey, kind, "global:${kind.rawValue}:", MemoryContextScope.PROJECT, null, toProjectId,
          ) ?: throw invalidAudience(topic)
          plans += Plan(topic, topic.copy(canonicalKey = key, scope = MemoryContextScope.PROJECT.rawValue, conversationId = null, projectId = toProjectId, updatedAt = now))
        }
        MemoryContextScope.PROJECT.rawValue -> {
          // Only topics of the chat's current project move with it.
          if (fromProjectId == null || topic.projectId != fromProjectId) continue
          if (supportingChats != setOf(conversationId)) throw mixedEvidence(topic)
          val fromPrefix = "project:${fromProjectId.lowercase()}:${kind.rawValue}:"
          val updated = if (toProjectId != null) {
            val key = AutomaticMemoryRules.rekeyed(topic.canonicalKey, kind, fromPrefix, MemoryContextScope.PROJECT, null, toProjectId)
              ?: throw invalidAudience(topic)
            topic.copy(canonicalKey = key, projectId = toProjectId, updatedAt = now)
          } else {
            // Leaving the project narrows the topic to this chat rather than widening it to everyone.
            val key = AutomaticMemoryRules.rekeyed(topic.canonicalKey, kind, fromPrefix, MemoryContextScope.CONVERSATION, conversationId, null)
              ?: throw invalidAudience(topic)
            topic.copy(canonicalKey = key, scope = MemoryContextScope.CONVERSATION.rawValue, conversationId = conversationId, projectId = null, updatedAt = now)
          }
          plans += Plan(topic, updated)
        }
      }
    }

    val plannedKeys = HashSet<String>()
    for (plan in plans) {
      val key = plan.updated.canonicalKey
      val collision = dao.topicByKey(key)
      if (!plannedKeys.add(key) || (collision != null && collision.id != plan.topic.id)) {
        throw AutomaticMemoryMoveException(
          "Learned memory “${plan.topic.title}” already exists where this chat is moving. Forget or correct one " +
            "of them in Memory, then move the chat again."
        )
      }
    }
    for (plan in plans) dao.updateTopic(plan.updated)
  }

  private fun mixedEvidence(topic: MemoryTopicEntity) = AutomaticMemoryMoveException(
    "This chat helped form learned memory “${topic.title}” that other chats also support. Moving it would widen " +
      "or split that memory, so the chat was not moved. Forget or correct the topic in Memory first."
  )

  private fun invalidAudience(topic: MemoryTopicEntity) = AutomaticMemoryMoveException(
    "Learned memory “${topic.title}” could not be moved safely with this chat, so the chat was not moved."
  )

  private val VALUE_CHANGES = setOf(
    MemoryRevisionKind.CREATED, MemoryRevisionKind.UPDATED, MemoryRevisionKind.REACTIVATED, MemoryRevisionKind.USER_EDITED,
  )
  private val SUPPORTING = setOf(
    MemoryRevisionKind.CREATED, MemoryRevisionKind.UPDATED, MemoryRevisionKind.REACTIVATED, MemoryRevisionKind.REINFORCED,
  )
}

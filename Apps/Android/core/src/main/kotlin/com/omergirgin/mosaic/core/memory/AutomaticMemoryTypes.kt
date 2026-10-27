package com.omergirgin.mosaic.core.memory

import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.context.MemoryContextScope

/*
 * Provider-independent automatic-memory vocabulary (iOS `AutomaticMemoryTypes.swift`). Raw values
 * are identical to iOS so stored rows and a later portable backup stay interchangeable. Scopes
 * reuse [MemoryContextScope] (global / project / conversation), which already mirrors iOS.
 */

/** A small taxonomy that keeps learned facts atomic and mergeable. */
enum class MemoryTopicKind(val rawValue: String, val displayName: String) {
  EVENT("event", "Recent event"),
  IDENTITY("identity", "Identity"),
  PREFERENCE("preference", "Preference"),
  RELATIONSHIP("relationship", "People"),
  PROJECT("project", "Project"),
  GOAL("goal", "Goal"),
  CONSTRAINT("constraint", "Constraint"),
  WORKFLOW("workflow", "Workflow"),
  FACT("fact", "Fact");

  companion object {
    fun fromRaw(raw: String?): MemoryTopicKind? = entries.firstOrNull { it.rawValue == raw }
  }
}

enum class MemoryTopicStatus(val rawValue: String) {
  ACTIVE("active"),
  FORGOTTEN("forgotten");

  companion object {
    fun fromRaw(raw: String?): MemoryTopicStatus? = entries.firstOrNull { it.rawValue == raw }
  }
}

/** `MANUAL` means the person corrected the topic in Memory; implicit output cannot change it. */
enum class MemoryOrigin(val rawValue: String) {
  AUTOMATIC("automatic"),
  MANUAL("manual");

  companion object {
    fun fromRaw(raw: String?): MemoryOrigin? = entries.firstOrNull { it.rawValue == raw }
  }
}

/** How quickly a learned value is expected to change. Affects ranking, never truth. */
enum class MemoryStability(val rawValue: String, internal val rank: Int) {
  EVOLVING("evolving", 0),
  STABLE("stable", 1),
  PERMANENT("permanent", 2);

  companion object {
    fun fromRaw(raw: String?): MemoryStability? = entries.firstOrNull { it.rawValue == raw }
  }
}

enum class MemoryRevisionKind(val rawValue: String) {
  CREATED("created"),
  REINFORCED("reinforced"),
  UPDATED("updated"),
  FORGOTTEN("forgotten"),
  REACTIVATED("reactivated"),
  USER_EDITED("user_edited"),
  USER_DISABLED("user_disabled"),
  USER_ENABLED("user_enabled");

  companion object {
    fun fromRaw(raw: String?): MemoryRevisionKind? = entries.firstOrNull { it.rawValue == raw }
  }
}

enum class MemoryFormationJobStatus(val rawValue: String) {
  PENDING("pending"),
  GENERATING("generating"),
  COMPLETE("complete"),
  /** Retryable: provider or validation failures, interrupted requests. */
  FAILED("failed"),
  /** Local source or record state makes this exact job impossible to complete ("Not applied"). */
  REJECTED("rejected");

  companion object {
    fun fromRaw(raw: String?): MemoryFormationJobStatus? = entries.firstOrNull { it.rawValue == raw }
  }
}

fun memoryScopeFromRaw(raw: String?): MemoryContextScope? = MemoryContextScope.entries.firstOrNull { it.rawValue == raw }

/** Immutable topic head snapshot; also the compare-and-swap boundary for a formation result. */
data class AutomaticMemoryTopicSnapshot(
  val id: String,
  val canonicalKey: String,
  val title: String,
  val content: String,
  val kind: MemoryTopicKind,
  val scope: MemoryContextScope,
  val conversationId: String?,
  val projectId: String?,
  val status: MemoryTopicStatus,
  val origin: MemoryOrigin,
  val confidence: Double,
  val importance: Double,
  val stability: MemoryStability,
  val isEnabled: Boolean,
  val lastConfirmedAt: Long,
  val lastUsedAt: Long?,
  val useCount: Int,
  val evidenceCount: Int,
  val revision: Int,
  val createdAt: Long,
  val updatedAt: Long,
) {
  val isAvailable: Boolean get() = status == MemoryTopicStatus.ACTIVE && isEnabled
}

data class AutomaticMemorySourceMessage(
  val id: String,
  val role: ChatRole,
  val content: String,
  val createdAt: Long,
)

/** Everything one extraction request may see, captured before the provider call. */
data class AutomaticMemoryFormationPreparation(
  val jobId: String,
  val conversationId: String,
  val throughUserMessageId: String,
  val assistantMessageId: String,
  val sourceFingerprint: String,
  val messages: List<AutomaticMemorySourceMessage>,
  val existingTopics: List<AutomaticMemoryTopicSnapshot>,
  val projectId: String? = null,
  val projectName: String? = null,
)

data class AutomaticMemoryFormationResult(
  val createdCount: Int = 0,
  val updatedCount: Int = 0,
  val reinforcedCount: Int = 0,
  val forgottenCount: Int = 0,
) {
  val changedCount: Int get() = createdCount + updatedCount + reinforcedCount + forgottenCount
}

/** Source-field limits shared with iOS `MosaicSourceFieldLimits` (automatic-memory subset). */
object AutomaticMemoryLimits {
  const val CANONICAL_KEY_BYTES = 1_024
  const val EVIDENCE_EXCERPT_BYTES = 8 * 1_024
  const val AUDIT_KEY_BYTES = 2 * 1_024
  const val PROVENANCE_BYTES = 8 * 1_024
  const val FORMATION_ERROR_BYTES = 8 * 1_024
  const val TITLE_CHARACTERS = 160
  const val TITLE_BYTES = 512
  const val CONTENT_CHARACTERS = 2_000
  const val CONTENT_BYTES = 8 * 1_024
  const val EVIDENCE_EXCERPT_CHARACTERS = 1_500
}

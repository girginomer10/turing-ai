package com.omergirgin.mosaic.data.db

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

/*
 * Automatic durable memory (iOS `AutomaticMemoryRecords.swift`). Field names follow iOS so a later
 * portable backup maps one-to-one; enums are stored by their iOS raw values. iOS keeps project
 * membership in a separate binding sidecar; here it is the nullable `projectId` column (like
 * documents). Raw messages stay the source of truth; these tables are the compact learned heads,
 * their exact evidence, semantic history, and the durable formation work/cost receipts.
 *
 * Foreign keys are a safety net: the memory lifecycle reconciles shared topics explicitly before a
 * conversation is deleted, and a write racing a deletion fails closed instead of leaving orphans.
 */

/** A consolidated, current fact learned from one or more user messages. */
@Entity(
  tableName = "memory_topics",
  foreignKeys = [
    // Project topics have no audience once their project is gone (same as pinned project facts).
    ForeignKey(entity = ProjectEntity::class, parentColumns = ["id"], childColumns = ["projectId"], onDelete = ForeignKey.CASCADE),
    ForeignKey(entity = ConversationEntity::class, parentColumns = ["id"], childColumns = ["conversationId"], onDelete = ForeignKey.CASCADE),
  ],
  indices = [
    Index(value = ["canonicalKey"], unique = true),
    Index("projectId"),
    Index("conversationId"),
    Index("scope", "status", "isEnabled"),
    Index("updatedAt"),
  ],
)
internal data class MemoryTopicEntity(
  @PrimaryKey val id: String,
  /** `global:<kind>:<key>`, `project:<uuid>:<kind>:<key>` or `conversation:<uuid>:<kind>:<key>`. */
  val canonicalKey: String,
  val title: String,
  val content: String,
  /** `MemoryTopicKind.rawValue`. */
  val kind: String,
  /** `MemoryContextScope.rawValue` (global / project / conversation). */
  val scope: String,
  val conversationId: String?,
  val projectId: String?,
  /** `MemoryTopicStatus.rawValue`. Paused = active + not enabled. */
  val status: String,
  /** `MemoryOrigin.rawValue`; manual = corrected by the person, authoritative. */
  val origin: String,
  val confidence: Double,
  val importance: Double,
  /** `MemoryStability.rawValue`. */
  val stability: String,
  val isEnabled: Boolean,
  /** For events: the report date of the latest supporting user message. */
  val lastConfirmedAt: Long,
  val lastUsedAt: Long?,
  val useCount: Int,
  val evidenceCount: Int,
  val revision: Int,
  val createdAt: Long,
  val updatedAt: Long,
)

/** Immutable evidence tying one topic to an exact user message. */
@Entity(
  tableName = "memory_evidence",
  foreignKeys = [
    ForeignKey(entity = MemoryTopicEntity::class, parentColumns = ["id"], childColumns = ["topicId"], onDelete = ForeignKey.CASCADE),
    ForeignKey(entity = ConversationEntity::class, parentColumns = ["id"], childColumns = ["conversationId"], onDelete = ForeignKey.CASCADE),
  ],
  indices = [
    Index(value = ["evidenceKey"], unique = true),
    Index("topicId"),
    Index("conversationId"),
    Index("sourceMessageId"),
  ],
)
internal data class MemoryEvidenceEntity(
  @PrimaryKey val id: String,
  val evidenceKey: String,
  val topicId: String,
  val conversationId: String,
  val sourceMessageId: String,
  val assistantMessageId: String?,
  val excerpt: String,
  val sourceFingerprint: String,
  val providerConfigurationId: String?,
  /** `ProviderKind.rawId`. */
  val providerKind: String?,
  val providerDisplayName: String?,
  val modelIdentifier: String?,
  /** Normalized credential-binding endpoint (scheme://host:port/path). */
  val providerEndpoint: String?,
  val confidence: Double,
  val createdAt: Long,
)

/** Immutable before/after audit entry for corrections, reinforcement and forgetting. */
@Entity(
  tableName = "memory_revisions",
  foreignKeys = [
    ForeignKey(entity = MemoryTopicEntity::class, parentColumns = ["id"], childColumns = ["topicId"], onDelete = ForeignKey.CASCADE),
  ],
  indices = [Index(value = ["revisionKey"], unique = true), Index("topicId", "sequence"), Index("sourceEvidenceId")],
)
internal data class MemoryRevisionEntity(
  @PrimaryKey val id: String,
  /** `<topicId>/<sequence>`. */
  val revisionKey: String,
  val topicId: String,
  val sequence: Int,
  /** `MemoryRevisionKind.rawValue`. */
  val kind: String,
  val previousTitle: String?,
  val previousContent: String?,
  val title: String,
  val content: String,
  /** Detached (null) when the evidence's conversation is deleted. */
  val sourceEvidenceId: String?,
  val createdAt: Long,
)

/** Durable, idempotent work item for one completed user-message boundary. */
@Entity(
  tableName = "memory_formation_jobs",
  foreignKeys = [
    ForeignKey(entity = ConversationEntity::class, parentColumns = ["id"], childColumns = ["conversationId"], onDelete = ForeignKey.CASCADE),
  ],
  indices = [Index(value = ["jobKey"], unique = true), Index("status", "updatedAt"), Index("conversationId")],
)
internal data class MemoryFormationJobEntity(
  @PrimaryKey val id: String,
  val jobKey: String,
  val conversationId: String,
  val throughUserMessageId: String,
  val assistantMessageId: String,
  val sourceFingerprint: String,
  val promptVersion: String,
  /** `MemoryFormationJobStatus.rawValue`. */
  val status: String,
  val attemptCount: Int,
  val providerConfigurationId: String?,
  val providerKind: String?,
  val providerDisplayName: String?,
  val modelIdentifier: String?,
  val providerEndpoint: String?,
  val outputFingerprint: String?,
  val lastError: String?,
  val startedAt: Long?,
  val completedAt: Long?,
  val createdAt: Long,
  val updatedAt: Long,
)

/** Provider/cost receipt for the latest attempt of one job, with cumulative retry totals. */
@Entity(
  tableName = "memory_formation_audits",
  foreignKeys = [
    ForeignKey(entity = MemoryFormationJobEntity::class, parentColumns = ["id"], childColumns = ["jobId"], onDelete = ForeignKey.CASCADE),
  ],
  indices = [Index(value = ["jobId"], unique = true), Index(value = ["jobKey"], unique = true), Index("finishedAt")],
)
internal data class MemoryFormationAuditEntity(
  @PrimaryKey val id: String,
  val jobId: String,
  val jobKey: String,
  val attemptCount: Int,
  /** `MemoryFormationJobStatus.rawValue`. */
  val outcome: String,
  val providerConfigurationId: String?,
  val providerKind: String?,
  val providerDisplayName: String?,
  val modelIdentifier: String?,
  val providerEndpoint: String?,
  val providerMessageId: String?,
  /** Committed before the provider stream opens: a crash after this is never auto-resent. */
  val requestStarted: Boolean,
  val inputTokenCount: Int?,
  val outputTokenCount: Int?,
  val providerRequestCount: Int,
  val cumulativeInputTokenCount: Int,
  val cumulativeOutputTokenCount: Int,
  val didDiscardInvalidTelemetry: Boolean,
  val errorDescription: String?,
  val startedAt: Long?,
  val finishedAt: Long,
  val createdAt: Long,
  val updatedAt: Long,
)

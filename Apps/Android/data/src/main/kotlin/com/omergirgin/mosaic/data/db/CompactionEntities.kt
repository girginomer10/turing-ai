package com.omergirgin.mosaic.data.db

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

/*
 * Rolling conversation compaction (iOS `CompactionArtifactRecord`, `ConversationCompactionHeadRecord`
 * and the compaction part of `RequestContextEventRecord`). Artifacts and events are immutable and
 * append-only; the head is the only mutable row. Raw message rows are never replaced or deleted
 * by compaction. Everything cascades with its conversation because it is derived chat content.
 */

/**
 * One validated app-owned summary. Coverage is stored as only the message IDs added after its
 * coverage parent; following the chain reconstructs the exact canonical prefix, which is then
 * revalidated (IDs + SHA-256 content fingerprint) before every use.
 */
@Entity(
  tableName = "compaction_artifacts",
  foreignKeys = [
    ForeignKey(
      entity = ConversationEntity::class,
      parentColumns = ["id"],
      childColumns = ["conversationId"],
      onDelete = ForeignKey.CASCADE,
    ),
  ],
  indices = [Index("conversationId")],
)
internal data class CompactionArtifactEntity(
  @PrimaryKey val id: String,
  val conversationId: String,
  /** Summary this one extended or rebuilt (null for an initial summary). */
  val lineagePreviousCompactionId: String?,
  /** Artifact whose coverage precedes [coverageDeltaJson]. */
  val coverageParentArtifactId: String?,
  /** JSON array of the message IDs this artifact adds beyond its coverage parent. */
  val coverageDeltaJson: String,
  val coveredMessageCount: Int,
  /** `CompactionMode.rawValue`. */
  val mode: String,
  val promptVersion: String,
  val contentSchemaVersion: Int,
  /** Validated `CompactionContent` JSON. */
  val contentJson: String,
  val renderedSummary: String,
  /** SHA-256 over the length-prefixed covered messages. */
  val sourceFingerprint: String,
  /** Provenance snapshot of the request that produced it; survives provider edits/deletion. */
  val providerId: String,
  val providerKind: String,
  val providerName: String,
  val providerEndpoint: String,
  val providerHost: String?,
  val modelId: String,
  val responseId: String?,
  val inputTokens: Int?,
  val outputTokens: Int?,
  val estimatedSourceTokens: Int,
  val estimatedSummaryTokens: Int,
  val chainDepth: Int,
  val warningsJson: String,
  /** SHA-256 of every other column; a mismatch means the row is corrupt and is never used. */
  val payloadFingerprint: String,
  val createdAt: Long,
)

/** Per-conversation pointer to the active artifact (compare-and-swap by [revision]). */
@Entity(
  tableName = "compaction_heads",
  foreignKeys = [
    ForeignKey(
      entity = ConversationEntity::class,
      parentColumns = ["id"],
      childColumns = ["conversationId"],
      onDelete = ForeignKey.CASCADE,
    ),
  ],
)
internal data class CompactionHeadEntity(
  @PrimaryKey val conversationId: String,
  val activeArtifactId: String?,
  val revision: Int,
  val updatedAt: Long,
)

/**
 * Append-only audit of extra summary requests: `generating` is committed before the provider
 * stream opens, then `generated`, `failed` or `cancelled` is appended (never overwritten). The
 * assistant message is deliberately not a foreign key so deleting a reply keeps the audit of a
 * request that may have been billed.
 */
@Entity(
  tableName = "request_context_events",
  foreignKeys = [
    ForeignKey(
      entity = ConversationEntity::class,
      parentColumns = ["id"],
      childColumns = ["conversationId"],
      onDelete = ForeignKey.CASCADE,
    ),
  ],
  indices = [
    Index(value = ["assistantMessageId", "eventSequence"], unique = true),
    Index("conversationId", "createdAt"),
    Index("attemptId"),
    Index("status"),
  ],
)
internal data class RequestContextEventEntity(
  /** Deterministic from (assistantMessageId, eventSequence) so replays are idempotent. */
  @PrimaryKey val id: String,
  val conversationId: String,
  val assistantMessageId: String,
  val eventSequence: Int,
  val attemptId: String,
  /** generating | generated | failed | cancelled */
  val status: String,
  /** Bounded JSON payload (provenance, usage, estimates, coverage boundary, warnings). */
  val payloadJson: String,
  val createdAt: Long,
)

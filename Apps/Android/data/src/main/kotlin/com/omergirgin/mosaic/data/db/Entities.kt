package com.omergirgin.mosaic.data.db

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

/*
 * Room entities are private to the data layer; the UI sees the immutable snapshots in
 * `model/Models.kt`. IDs are UUID strings, timestamps are epoch millis, enums are stored by stable
 * raw value so a later backup format can stay interchangeable with iOS.
 *
 * Model choices (provider + model) are stored as two plain columns without a foreign key: a
 * provider deletion clears them explicitly in the same transaction (see ProviderDao).
 */

/** Non-secret provider connection metadata. The API key lives only in [SecretStore]. */
@Entity(tableName = "providers")
internal data class ProviderEntity(
  @PrimaryKey val id: String,
  /** `ProviderKind.rawId`. */
  val kind: String,
  val displayName: String,
  /** User override; null = preset default. */
  val baseUrl: String?,
  val isEnabled: Boolean,
  val createdAt: Long,
  val updatedAt: Long,
)

/** One saved catalog row for one provider (enabled, customized, or discovered). */
@Entity(
  tableName = "provider_models",
  primaryKeys = ["providerId", "modelId"],
  foreignKeys = [
    ForeignKey(
      entity = ProviderEntity::class,
      parentColumns = ["id"],
      childColumns = ["providerId"],
      onDelete = ForeignKey.CASCADE,
    ),
  ],
)
internal data class ProviderModelEntity(
  val providerId: String,
  val modelId: String,
  val isEnabled: Boolean,
  val contextWindowTokens: Int?,
  val maximumOutputTokens: Int?,
  val supportsImages: Boolean?,
  val isCustom: Boolean,
  val isDiscovered: Boolean,
)

@Entity(tableName = "projects")
internal data class ProjectEntity(
  @PrimaryKey val id: String,
  val name: String,
  val instructions: String,
  val isArchived: Boolean,
  val defaultProviderId: String?,
  val defaultModelId: String?,
  val createdAt: Long,
  val updatedAt: Long,
)

@Entity(
  tableName = "conversations",
  foreignKeys = [
    // Deleting a project keeps its chats; they move back to the personal workspace.
    ForeignKey(
      entity = ProjectEntity::class,
      parentColumns = ["id"],
      childColumns = ["projectId"],
      onDelete = ForeignKey.SET_NULL,
    ),
  ],
  indices = [Index("projectId"), Index("isArchived", "updatedAt")],
)
internal data class ConversationEntity(
  @PrimaryKey val id: String,
  val title: String,
  val projectId: String?,
  val systemPrompt: String?,
  val modelProviderId: String?,
  val modelId: String?,
  val draft: String,
  val isArchived: Boolean,
  val webSearchEnabled: Boolean,
  val createdAt: Long,
  val updatedAt: Long,
)

/**
 * Raw transcript row. Provider columns are an immutable provenance snapshot taken when the row is
 * created, so later provider edits never rewrite history. Large payloads (attachments, receipts)
 * live in side tables so a streaming checkpoint does not re-read or re-decode them.
 */
@Entity(
  tableName = "messages",
  foreignKeys = [
    ForeignKey(
      entity = ConversationEntity::class,
      parentColumns = ["id"],
      childColumns = ["conversationId"],
      onDelete = ForeignKey.CASCADE,
    ),
  ],
  indices = [Index("conversationId", "createdAt"), Index("status")],
)
internal data class MessageEntity(
  @PrimaryKey val id: String,
  val conversationId: String,
  /** `ChatRole.rawValue`. */
  val role: String,
  val content: String,
  /** `MessageStatus.name`. */
  val status: String,
  val errorMessage: String?,
  val providerId: String?,
  /** `ProviderKind.rawId`. */
  val providerKind: String?,
  val providerName: String?,
  val modelId: String?,
  val destinationHost: String?,
  val inputTokens: Int?,
  val outputTokens: Int?,
  val responseId: String?,
  val retryOfMessageId: String?,
  /** JSON array of web sources; small and bounded to 100 entries. */
  val citationsJson: String?,
  val createdAt: Long,
  val updatedAt: Long,
)

/** Attachment payloads, kept out of the message row (photos are up to ~1.4 MB of base64). */
@Entity(
  tableName = "attachments",
  foreignKeys = [
    ForeignKey(
      entity = MessageEntity::class,
      parentColumns = ["id"],
      childColumns = ["messageId"],
      onDelete = ForeignKey.CASCADE,
    ),
  ],
  indices = [Index("messageId"), Index("conversationId")],
)
internal data class AttachmentEntity(
  @PrimaryKey val id: String,
  val messageId: String,
  /** Denormalized so transcript observation queries this table alone. */
  val conversationId: String,
  /** `AttachmentKind.name`. */
  val kind: String,
  val fileName: String,
  val mimeType: String,
  val extractedText: String?,
  val imageBase64: String?,
  val position: Int,
  val createdAt: Long,
)

/** What was sent for one assistant attempt. Immutable once written. */
@Entity(
  tableName = "context_receipts",
  foreignKeys = [
    ForeignKey(
      entity = MessageEntity::class,
      parentColumns = ["id"],
      childColumns = ["messageId"],
      onDelete = ForeignKey.CASCADE,
    ),
  ],
  indices = [Index("conversationId")],
)
internal data class ContextReceiptEntity(
  @PrimaryKey val messageId: String,
  val conversationId: String,
  val json: String,
  val createdAt: Long,
)

@Entity(
  tableName = "memory_facts",
  foreignKeys = [
    // Project- and chat-scoped facts have no audience once their owner is gone.
    ForeignKey(
      entity = ProjectEntity::class,
      parentColumns = ["id"],
      childColumns = ["projectId"],
      onDelete = ForeignKey.CASCADE,
    ),
    ForeignKey(
      entity = ConversationEntity::class,
      parentColumns = ["id"],
      childColumns = ["conversationId"],
      onDelete = ForeignKey.CASCADE,
    ),
  ],
  indices = [Index("projectId"), Index("conversationId"), Index("updatedAt")],
)
internal data class MemoryFactEntity(
  @PrimaryKey val id: String,
  val title: String,
  val content: String,
  /** `MemoryScope.name`. */
  val scope: String,
  val projectId: String?,
  val conversationId: String?,
  val isEnabled: Boolean,
  val createdAt: Long,
  val updatedAt: Long,
)

/**
 * One row per provider request that reported usage. Snapshots provider identity so the report
 * survives provider and conversation deletion (usage may already have been billed).
 */
@Entity(tableName = "usage_records", indices = [Index("createdAt")])
internal data class UsageRecordEntity(
  @PrimaryKey val id: String,
  val providerId: String?,
  val providerKind: String,
  val providerName: String,
  val modelId: String,
  val destinationHost: String?,
  /** "Chat", "Connection test", ... */
  val category: String,
  val inputTokens: Int?,
  val outputTokens: Int?,
  val conversationId: String?,
  val messageId: String?,
  val createdAt: Long,
)

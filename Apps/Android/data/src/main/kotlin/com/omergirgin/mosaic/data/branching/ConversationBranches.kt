package com.omergirgin.mosaic.data.branching

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import com.omergirgin.mosaic.data.db.AttachmentEntity
import com.omergirgin.mosaic.data.db.ConversationEntity
import com.omergirgin.mosaic.data.db.MessageEntity
import com.omergirgin.mosaic.data.model.Attachment
import kotlinx.coroutines.flow.Flow

/*
 * Edit-and-branch alternatives (iOS `ConversationBranchStore` + `ConversationAlternativesView`).
 * An alternative is its own conversation holding a copy of the completed prefix before one user
 * message. Each conversation in a group has one link row whose fields mirror the iOS
 * `ExperienceValue(kind: .branch)` sidecar (`id`, `conversationID`, `branchGroupID`,
 * `originalConversationID`, `updatedAt`) so a backup can map them one-to-one. Like iOS, the
 * branch point itself is not stored: the copied prefix is the record of it.
 */

@Entity(
  tableName = "conversation_branches",
  foreignKeys = [
    // A deleted chat leaves its group (iOS deletes the ExperienceRecords it owns).
    ForeignKey(
      entity = ConversationEntity::class,
      parentColumns = ["id"],
      childColumns = ["conversationId"],
      onDelete = ForeignKey.CASCADE,
    ),
  ],
  indices = [Index(value = ["conversationId"], unique = true), Index("branchGroupId")],
)
internal data class ConversationBranchEntity(
  @PrimaryKey val id: String,
  val conversationId: String,
  /** Shared by every alternative of one chat: the ID of the group's first conversation. */
  val branchGroupId: String,
  /**
   * The chat this alternative was created from; null for the group's original. Deliberately not
   * a foreign key: alternatives outlive a deleted source, as on iOS.
   */
  val originalConversationId: String?,
  val updatedAt: Long,
)

/** One conversation of a branch group, for the Alternatives list. */
internal data class AlternativeRow(
  val conversationId: String,
  val title: String,
  val providerName: String?,
  val modelId: String?,
  val originalConversationId: String?,
  val isArchived: Boolean,
  val createdAt: Long,
  val updatedAt: Long,
)

@Dao
internal interface ConversationBranchDao {
  @Query("SELECT * FROM conversation_branches WHERE conversationId = :conversationId")
  suspend fun linkFor(conversationId: String): ConversationBranchEntity?

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insert(entity: ConversationBranchEntity)

  /** Every conversation in [conversationId]'s group, oldest first; empty when it has none. */
  @Query(
    """
    SELECT c.id AS conversationId, c.title AS title, p.displayName AS providerName, c.modelId AS modelId,
      b.originalConversationId AS originalConversationId, c.isArchived AS isArchived,
      c.createdAt AS createdAt, c.updatedAt AS updatedAt
    FROM conversation_branches b
    INNER JOIN conversations c ON c.id = b.conversationId
    LEFT JOIN providers p ON p.id = c.modelProviderId
    WHERE b.branchGroupId = (SELECT g.branchGroupId FROM conversation_branches g WHERE g.conversationId = :conversationId)
    ORDER BY c.createdAt, c.id
    """
  )
  fun observeGroup(conversationId: String): Flow<List<AlternativeRow>>

  /** Transcript order, paged so a long source chat is copied without loading it at once. */
  @Query("SELECT * FROM messages WHERE conversationId = :conversationId ORDER BY createdAt, id LIMIT :limit OFFSET :offset")
  suspend fun messagePage(conversationId: String, limit: Int, offset: Int): List<MessageEntity>

  /** The completed user turn a response answers (retries are appended later but answer it too). */
  @Query(
    """
    SELECT * FROM messages
    WHERE conversationId = :conversationId AND role = 'user' AND status = 'COMPLETE'
      AND (createdAt < :createdAt OR (createdAt = :createdAt AND id < :id))
    ORDER BY createdAt DESC, id DESC
    LIMIT 1
    """
  )
  suspend fun userTurnBefore(conversationId: String, createdAt: Long, id: String): MessageEntity?

  @Query("SELECT * FROM attachments WHERE messageId = :messageId ORDER BY position")
  suspend fun attachments(messageId: String): List<AttachmentEntity>

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insertMessages(rows: List<MessageEntity>)

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insertAttachments(rows: List<AttachmentEntity>)
}

/** One conversation of a branch group, as listed under Alternatives. */
data class ConversationAlternative(
  val conversationId: String,
  val title: String,
  /** The chat's current model (what its next turn uses). */
  val providerName: String?,
  val modelId: String?,
  /** The group's first conversation (the chat every alternative branched from, directly or not). */
  val isOriginal: Boolean,
  val isArchived: Boolean,
  val createdAt: Long,
  val updatedAt: Long,
)

/**
 * A new alternative ready to open: its draft text is already stored on the conversation; the
 * branch-point message's attachments are handed back for the composer (Android keeps unsent
 * attachments in memory only).
 */
data class CreatedAlternative(val conversationId: String, val draftAttachments: List<Attachment>)

/**
 * Edit & branch. The original conversation, its receipts, usage and memory evidence are never
 * changed; the copied turns carry no usage counters, receipts or citations because no request
 * ran twice. Recall and memory treat each alternative as its own chat.
 */
interface ConversationAlternativesRepository {
  /** Conversations in the same group as [conversationId] (including it), oldest first. */
  fun observeAlternatives(conversationId: String): Flow<List<ConversationAlternative>>

  /** "Edit": continues from [userMessageId] with [draft] as the new, unsent message. */
  suspend fun editAndBranch(sourceId: String, userMessageId: String, draft: String): CreatedAlternative

  /** "Ask another model": the question answered by [assistantMessageId] becomes the unsent draft. */
  suspend fun askAnotherModel(sourceId: String, assistantMessageId: String): CreatedAlternative
}

package com.omergirgin.mosaic.data.connections

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Upsert
import com.omergirgin.mosaic.data.db.MessageEntity
import com.omergirgin.mosaic.data.db.UsageRecordEntity
import kotlinx.coroutines.flow.Flow

/**
 * Durable outcome of one reviewed connection action (iOS `ConnectionActionReceipt`). Inserted as
 * STARTED before the request is sent, then updated to SUCCEEDED / FAILED / UNCERTAIN; DECLINED
 * rows record that nothing was sent. Non-secret: service, tool name, the exact reviewed arguments.
 */
@Entity(
  tableName = "connection_action_receipts",
  foreignKeys = [
    ForeignKey(entity = MessageEntity::class, parentColumns = ["id"], childColumns = ["messageId"], onDelete = ForeignKey.CASCADE),
  ],
  indices = [Index("messageId"), Index("conversationId")],
)
internal data class ConnectionActionReceiptEntity(
  @PrimaryKey val id: String,
  val messageId: String,
  val conversationId: String,
  /** `ConnectorId.rawId`. */
  val service: String,
  val tool: String,
  val argumentsJson: String,
  /** `ConnectionActionReceipt.Outcome.name`. */
  val outcome: String,
  val summary: String,
  val createdAt: Long,
  val updatedAt: Long,
)

/** What connected services contributed to one answer: coverage notice, services used and sources. */
@Entity(
  tableName = "connection_activity",
  foreignKeys = [
    ForeignKey(entity = MessageEntity::class, parentColumns = ["id"], childColumns = ["messageId"], onDelete = ForeignKey.CASCADE),
  ],
  indices = [Index("conversationId")],
)
internal data class ConnectionActivityEntity(
  @PrimaryKey val messageId: String,
  val conversationId: String,
  val notice: String?,
  /** JSON array of `ConnectorId.rawId`. */
  val servicesJson: String,
  /** JSON array of {title, url}. */
  val sourcesJson: String,
  val createdAt: Long,
)

@Dao
internal interface ConnectionDao {
  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insertReceipt(entity: ConnectionActionReceiptEntity)

  @Query("UPDATE connection_action_receipts SET outcome = :outcome, summary = :summary, updatedAt = :updatedAt WHERE id = :id")
  suspend fun updateReceipt(id: String, outcome: String, summary: String, updatedAt: Long): Int

  @Query("SELECT * FROM connection_action_receipts WHERE messageId = :messageId ORDER BY createdAt, id")
  fun observeReceipts(messageId: String): Flow<List<ConnectionActionReceiptEntity>>

  @Upsert
  suspend fun upsertActivity(entity: ConnectionActivityEntity)

  @Query("SELECT * FROM connection_activity WHERE messageId = :messageId")
  fun observeActivity(messageId: String): Flow<ConnectionActivityEntity?>

  /** Per-request "Connected tools" usage: inserted before the request, updated with reported tokens. */
  @Upsert
  suspend fun upsertUsage(entity: UsageRecordEntity)
}

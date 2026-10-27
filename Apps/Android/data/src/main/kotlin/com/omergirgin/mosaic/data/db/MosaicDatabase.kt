package com.omergirgin.mosaic.data.db

import android.content.Context
import androidx.room.AutoMigration
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import com.omergirgin.mosaic.data.backup.BackupDao
import com.omergirgin.mosaic.data.branching.ConversationBranchDao
import com.omergirgin.mosaic.data.branching.ConversationBranchEntity
import com.omergirgin.mosaic.data.connections.ConnectionActionReceiptEntity
import com.omergirgin.mosaic.data.connections.ConnectionActivityEntity
import com.omergirgin.mosaic.data.connections.ConnectionDao
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfileDao
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfileEntity
import com.omergirgin.mosaic.data.pricing.ModelPriceOverrideDao
import com.omergirgin.mosaic.data.pricing.ModelPriceOverrideEntity
import com.omergirgin.mosaic.data.recall.RecallDao

/**
 * Main source-of-truth store (conversations, raw messages, receipts, pinned facts, projects,
 * provider metadata, usage). API keys are never stored here. Schema JSON is exported to
 * `data/schemas` so later versions ship explicit migrations instead of destructive resets.
 */
@Database(
  entities = [
    ProviderEntity::class,
    ProviderModelEntity::class,
    ProjectEntity::class,
    ConversationEntity::class,
    MessageEntity::class,
    AttachmentEntity::class,
    ContextReceiptEntity::class,
    MemoryFactEntity::class,
    UsageRecordEntity::class,
    DocumentEntity::class,
    DocumentChunkEntity::class,
    CompactionArtifactEntity::class,
    CompactionHeadEntity::class,
    RequestContextEventEntity::class,
    ScheduledTaskEntity::class,
    ScheduledTaskRunEntity::class,
    EmbeddingProfileEntity::class,
    MemoryTopicEntity::class,
    MemoryEvidenceEntity::class,
    MemoryRevisionEntity::class,
    MemoryFormationJobEntity::class,
    MemoryFormationAuditEntity::class,
    // Schema v3 (additive, AutoMigration 2→3): custom per-model rates for Usage & cost.
    ModelPriceOverrideEntity::class,
    // Schema v3 (additive, AutoMigration 2→3): edit-and-branch alternative group links.
    ConversationBranchEntity::class,
    // Schema v3 (additive, AutoMigration 2→3): connection action receipts and per-answer activity.
    ConnectionActionReceiptEntity::class,
    ConnectionActivityEntity::class,
  ],
  // Every version that has reached a device is frozen under data/schemas. Later versions must add
  // a migration here; never edit an exported schema JSON in place.
  version = 3,
  exportSchema = true,
  autoMigrations = [
    // Compaction, embedding profiles, automatic memory and scheduled-prompt tables (additive).
    AutoMigration(from = 1, to = 2),
    // Price overrides, conversation branches and connection receipts/activity (additive).
    AutoMigration(from = 2, to = 3),
  ],
)
internal abstract class MosaicDatabase : RoomDatabase() {
  abstract fun providers(): ProviderDao
  abstract fun projects(): ProjectDao
  abstract fun conversations(): ConversationDao
  abstract fun messages(): MessageDao
  abstract fun attachments(): AttachmentDao
  abstract fun receipts(): ContextReceiptDao
  abstract fun memory(): MemoryDao
  abstract fun usage(): UsageDao
  abstract fun compaction(): CompactionDao
  abstract fun documents(): DocumentDao
  abstract fun scheduledTasks(): ScheduledTaskDao
  abstract fun embeddingProfiles(): EmbeddingProfileDao
  abstract fun recall(): RecallDao
  abstract fun automaticMemory(): AutomaticMemoryDao
  abstract fun priceOverrides(): ModelPriceOverrideDao
  abstract fun conversationBranches(): ConversationBranchDao
  abstract fun connections(): ConnectionDao
  /** Portable `.mosaicbackup` export pages and the one-transaction restore (no schema change). */
  abstract fun backup(): BackupDao

  companion object {
    private const val FILE_NAME = "turing.db"

    fun open(context: Context): MosaicDatabase =
      Room.databaseBuilder(context.applicationContext, MosaicDatabase::class.java, FILE_NAME)
        // No destructive fallback: a failed migration must never silently wipe a library.
        .build()
  }
}

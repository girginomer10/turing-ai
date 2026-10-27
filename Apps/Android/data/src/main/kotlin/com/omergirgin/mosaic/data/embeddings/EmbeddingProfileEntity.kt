package com.omergirgin.mosaic.data.embeddings

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Upsert
import com.omergirgin.mosaic.data.db.ProviderEntity
import kotlinx.coroutines.flow.Flow

/**
 * Embedding profile metadata (iOS `EmbeddingProfileRecord`), stored in the main database. The
 * vectors themselves live only in the rebuildable semantic index. Deleting the provider keeps the
 * profile but disconnects it, so its vector space is never silently reused.
 */
@Entity(
  tableName = "embedding_profiles",
  foreignKeys = [
    ForeignKey(
      entity = ProviderEntity::class,
      parentColumns = ["id"],
      childColumns = ["providerId"],
      onDelete = ForeignKey.SET_NULL,
    ),
  ],
  indices = [Index("providerId"), Index("isEnabled", "updatedAt")],
)
internal data class EmbeddingProfileEntity(
  @PrimaryKey val id: String,
  val displayName: String,
  val providerId: String?,
  val modelId: String,
  /** Ensemble weight for rank fusion (0.25...2). */
  val weight: Double,
  val isEnabled: Boolean,
  val indexesConversations: Boolean,
  val indexesDocuments: Boolean,
  val createdAt: Long,
  val updatedAt: Long,
)

@Dao
internal interface EmbeddingProfileDao {
  @Query("SELECT * FROM embedding_profiles ORDER BY updatedAt DESC, id")
  fun observeAll(): Flow<List<EmbeddingProfileEntity>>

  @Query("SELECT * FROM embedding_profiles ORDER BY updatedAt DESC, id")
  suspend fun all(): List<EmbeddingProfileEntity>

  @Query("SELECT * FROM embedding_profiles WHERE id = :id")
  suspend fun get(id: String): EmbeddingProfileEntity?

  /** Most recently updated enabled profiles first (the four used per request). */
  @Query("SELECT * FROM embedding_profiles WHERE isEnabled = 1 ORDER BY updatedAt DESC, id LIMIT :limit")
  suspend fun enabled(limit: Int): List<EmbeddingProfileEntity>

  @Query("SELECT COUNT(*) FROM embedding_profiles WHERE isEnabled = 1")
  suspend fun enabledCount(): Int

  @Query("SELECT COUNT(*) FROM embedding_profiles WHERE isEnabled = 1 AND id != :excludingId")
  suspend fun enabledCountExcluding(excludingId: String): Int

  @Query("SELECT id FROM embedding_profiles WHERE id IN (:ids)")
  suspend fun existingIds(ids: List<String>): List<String>

  @Upsert
  suspend fun upsert(entity: EmbeddingProfileEntity)

  @Query("UPDATE embedding_profiles SET isEnabled = :enabled, updatedAt = :now WHERE id = :id")
  suspend fun setEnabled(id: String, enabled: Boolean, now: Long): Int

  @Query("DELETE FROM embedding_profiles WHERE id = :id")
  suspend fun delete(id: String): Int
}

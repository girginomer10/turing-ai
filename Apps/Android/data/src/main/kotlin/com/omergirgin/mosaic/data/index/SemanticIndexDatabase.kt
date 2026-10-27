package com.omergirgin.mosaic.data.index

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Upsert

/**
 * One cached Float32 vector, keyed by profile and source. Rebuildable: everything here can be
 * regenerated from the main store, so it is never backed up and may be dropped on schema change.
 */
@Entity(
  tableName = "embedding_vectors",
  indices = [
    Index("profileId", "embeddingSpaceId", "dimensions"),
    Index("sourceKind", "cacheKey"),
    Index("sourceId"),
  ],
)
internal class EmbeddingVectorEntity(
  /** `"<profileId>/<sourceId>"` (lowercase), unique per profile and source. */
  @PrimaryKey val cacheKey: String,
  val profileId: String,
  /** `RecallSourceKind.rawValue`. */
  val sourceKind: String,
  val sourceId: String,
  val embeddingSpaceId: String,
  /** SHA-256 of the exact text that was embedded (before model-specific prefixes). */
  val contentFingerprint: String,
  val dimensions: Int,
  /** Little-endian Float32, exactly `dimensions * 4` bytes. */
  val vectorData: ByteArray,
  val createdAt: Long,
  val updatedAt: Long,
) {
  companion object {
    fun cacheKey(profileId: String, sourceId: String): String = "${profileId.lowercase()}/${sourceId.lowercase()}"
  }
}

/** Vector metadata without the blob (health and validation scans). */
internal data class VectorMetadataRow(
  val cacheKey: String,
  val profileId: String,
  val sourceKind: String,
  val sourceId: String,
  val embeddingSpaceId: String,
  val contentFingerprint: String,
  val dimensions: Int,
  val byteCount: Int,
)

@Dao
internal interface EmbeddingVectorDao {
  @Query("SELECT * FROM embedding_vectors WHERE cacheKey IN (:cacheKeys)")
  suspend fun byCacheKeys(cacheKeys: List<String>): List<EmbeddingVectorEntity>

  @Query(
    """
    SELECT cacheKey, profileId, sourceKind, sourceId, embeddingSpaceId, contentFingerprint, dimensions,
      length(vectorData) AS byteCount
    FROM embedding_vectors WHERE cacheKey IN (:cacheKeys)
    """
  )
  suspend fun metadata(cacheKeys: List<String>): List<VectorMetadataRow>

  /** Keyset page over one source kind, ordered by cache key. */
  @Query(
    """
    SELECT cacheKey, profileId, sourceKind, sourceId, embeddingSpaceId, contentFingerprint, dimensions,
      length(vectorData) AS byteCount
    FROM embedding_vectors WHERE sourceKind = :sourceKind AND cacheKey > :afterCacheKey
    ORDER BY cacheKey LIMIT :limit
    """
  )
  suspend fun metadataPage(sourceKind: String, afterCacheKey: String, limit: Int): List<VectorMetadataRow>

  @Query(
    """
    SELECT EXISTS(SELECT 1 FROM embedding_vectors WHERE profileId = :profileId
      AND embeddingSpaceId = :embeddingSpaceId AND dimensions != :dimensions
      AND cacheKey NOT IN (:replacedCacheKeys))
    """
  )
  suspend fun hasOtherDimension(
    profileId: String,
    embeddingSpaceId: String,
    dimensions: Int,
    replacedCacheKeys: List<String>,
  ): Boolean

  @Query(
    """
    SELECT COUNT(DISTINCT dimensions) FROM embedding_vectors
    WHERE profileId = :profileId AND embeddingSpaceId = :embeddingSpaceId
    """
  )
  suspend fun distinctDimensionCount(profileId: String, embeddingSpaceId: String): Int

  @Upsert
  suspend fun upsert(entities: List<EmbeddingVectorEntity>)

  @Query("DELETE FROM embedding_vectors WHERE cacheKey IN (:cacheKeys)")
  suspend fun delete(cacheKeys: List<String>): Int

  /** Every profile's vectors for deleted sources. */
  @Query("DELETE FROM embedding_vectors WHERE sourceKind = :sourceKind AND sourceId IN (:sourceIds)")
  suspend fun deleteSources(sourceKind: String, sourceIds: List<String>): Int

  @Query("DELETE FROM embedding_vectors WHERE cacheKey IN (SELECT cacheKey FROM embedding_vectors WHERE profileId = :profileId LIMIT :limit)")
  suspend fun deleteProfilePage(profileId: String, limit: Int): Int
}

/**
 * Second, rebuildable database (iOS `SemanticIndex.store`). Separate from the source-of-truth
 * database so a lost or corrupt cache never affects conversations, memory or documents.
 */
@Database(entities = [EmbeddingVectorEntity::class], version = 1, exportSchema = false)
internal abstract class SemanticIndexDatabase : RoomDatabase() {
  abstract fun vectors(): EmbeddingVectorDao

  companion object {
    private const val FILE_NAME = "turing_semantic_index.db"

    fun open(context: Context): SemanticIndexDatabase =
      Room.databaseBuilder(context.applicationContext, SemanticIndexDatabase::class.java, FILE_NAME)
        // Derived data only: a schema change may rebuild it from the main store.
        .fallbackToDestructiveMigration(dropAllTables = true)
        .build()

    fun inMemory(context: Context): SemanticIndexDatabase =
      Room.inMemoryDatabaseBuilder(context.applicationContext, SemanticIndexDatabase::class.java).build()
  }
}

package com.omergirgin.mosaic.data.index

import android.content.Context
import android.util.Log
import androidx.room.withTransaction
import com.omergirgin.mosaic.core.retrieval.EmbeddingVectorCodec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** One validated vector ready for the cache. */
internal class VectorWrite(
  val profileId: String,
  val sourceKind: String,
  val sourceId: String,
  val embeddingSpaceId: String,
  val contentFingerprint: String,
  val vector: FloatArray,
) {
  val cacheKey: String get() = EmbeddingVectorEntity.cacheKey(profileId, sourceId)
}

internal class MixedEmbeddingDimensionsException :
  IllegalStateException("A cached embedding space already uses a different vector dimension. Rebuild the document index.")

/**
 * Lazily opened rebuildable vector cache. Retrieval never touches it unless an embedding profile
 * job actually runs. If the file cannot be opened, an in-memory index is used for this process
 * ([isTemporary]) and the main database stays fully usable.
 *
 * Writes are serialized process-wide with a read-before-write check so every (profile, embedding
 * space) keeps exactly one dimension, also across retrieval and document indexing jobs.
 */
internal class SemanticVectorStore(private val context: Context) {
  private val openLock = Mutex()
  private val writeLock = Mutex()
  @Volatile private var database: SemanticIndexDatabase? = null
  @Volatile var isTemporary: Boolean = false
    private set

  val isOpen: Boolean get() = database != null

  private suspend fun dao(): EmbeddingVectorDao {
    database?.let { return it.vectors() }
    return openLock.withLock {
      database?.vectors() ?: withContext(Dispatchers.IO) {
        val opened = try {
          SemanticIndexDatabase.open(context).also { it.openHelper.writableDatabase }
        } catch (error: Exception) {
          // Type only: paths and SQL may describe user content.
          Log.w(TAG, "Semantic index unavailable; using a temporary index (${error.javaClass.simpleName}).")
          isTemporary = true
          SemanticIndexDatabase.inMemory(context)
        }
        database = opened
        opened.vectors()
      }
    }
  }

  /** Full rows for [sourceIds] of one profile (at most [MAXIMUM_PAGE_SIZE]). */
  suspend fun vectors(profileId: String, sourceIds: List<String>): List<EmbeddingVectorEntity> {
    if (sourceIds.isEmpty()) return emptyList()
    require(sourceIds.size <= MAXIMUM_PAGE_SIZE)
    return dao().byCacheKeys(sourceIds.map { EmbeddingVectorEntity.cacheKey(profileId, it) })
  }

  suspend fun metadata(profileId: String, sourceIds: List<String>): List<VectorMetadataRow> {
    if (sourceIds.isEmpty()) return emptyList()
    require(sourceIds.size <= MAXIMUM_PAGE_SIZE)
    return dao().metadata(sourceIds.map { EmbeddingVectorEntity.cacheKey(profileId, it) })
  }

  suspend fun metadataPage(sourceKind: String, afterCacheKey: String, limit: Int): List<VectorMetadataRow> =
    dao().metadataPage(sourceKind, afterCacheKey, limit)

  suspend fun hasMixedDimensions(profileId: String, embeddingSpaceId: String): Boolean =
    writeLock.withLock { dao().distinctDimensionCount(profileId, embeddingSpaceId) > 1 }

  /** Validates and upserts at most [MAXIMUM_PAGE_SIZE] writes in one transaction. */
  suspend fun upsert(writes: List<VectorWrite>) {
    if (writes.isEmpty()) return
    require(writes.size <= MAXIMUM_PAGE_SIZE)
    val dao = dao()
    writeLock.withLock {
      val dimensionsBySpace = HashMap<Pair<String, String>, Int>()
      val keysBySpace = HashMap<Pair<String, String>, MutableList<String>>()
      val seenKeys = HashSet<String>()
      for (write in writes) {
        if (write.vector.isEmpty() || !seenKeys.add(write.cacheKey) || write.vector.any { !it.isFinite() }) {
          throw IllegalArgumentException("Invalid embedding vector write.")
        }
        val space = write.profileId to write.embeddingSpaceId
        val expected = dimensionsBySpace.putIfAbsent(space, write.vector.size)
        if (expected != null && expected != write.vector.size) throw MixedEmbeddingDimensionsException()
        keysBySpace.getOrPut(space) { ArrayList() } += write.cacheKey
      }
      val now = System.currentTimeMillis()
      val db = requireNotNull(database)
      db.withTransaction {
        for ((space, dimension) in dimensionsBySpace) {
          if (dao.hasOtherDimension(space.first, space.second, dimension, keysBySpace[space].orEmpty())) {
            throw MixedEmbeddingDimensionsException()
          }
        }
        dao.upsert(
          writes.map {
            EmbeddingVectorEntity(
              cacheKey = it.cacheKey,
              profileId = it.profileId,
              sourceKind = it.sourceKind,
              sourceId = it.sourceId,
              embeddingSpaceId = it.embeddingSpaceId,
              contentFingerprint = it.contentFingerprint,
              dimensions = it.vector.size,
              vectorData = EmbeddingVectorCodec.encode(it.vector),
              createdAt = now,
              updatedAt = now,
            )
          }
        )
      }
    }
  }

  suspend fun delete(cacheKeys: List<String>) {
    if (cacheKeys.isEmpty()) return
    val dao = dao()
    writeLock.withLock { cacheKeys.chunked(MAXIMUM_PAGE_SIZE).forEach { dao.delete(it) } }
  }

  /** Removes every profile's vectors for deleted sources of one kind. */
  suspend fun deleteSources(sourceKind: String, sourceIds: Collection<String>) {
    if (sourceIds.isEmpty()) return
    val dao = dao()
    writeLock.withLock { sourceIds.toList().chunked(MAXIMUM_PAGE_SIZE).forEach { dao.deleteSources(sourceKind, it) } }
  }

  /** Removes every cached vector of one profile (all source kinds) in bounded pages. */
  suspend fun deleteProfile(profileId: String) {
    val dao = dao()
    writeLock.withLock {
      do {
        val deleted = dao.deleteProfilePage(profileId, 512)
      } while (deleted > 0)
    }
  }

  companion object {
    const val MAXIMUM_PAGE_SIZE: Int = 256
    private const val TAG = "TuringIndex"
  }
}

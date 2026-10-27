package com.omergirgin.mosaic.data.db

import androidx.room.Dao
import androidx.room.Embedded
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

/** Library row: the document plus its project label and a COUNT of its chunks (no chunk bodies). */
internal data class DocumentRow(
  @Embedded val document: DocumentEntity,
  val projectName: String?,
  val projectIsArchived: Boolean?,
  val chunkCount: Int,
)

/** Owned by the documents feature. Retrieval reads `document_chunks` through its own queries. */
@Dao
internal interface DocumentDao {
  @Query(
    """
    SELECT d.*, p.name AS projectName, p.isArchived AS projectIsArchived,
      (SELECT COUNT(*) FROM document_chunks c WHERE c.documentId = d.id) AS chunkCount
    FROM documents d LEFT JOIN projects p ON p.id = d.projectId
    ORDER BY d.createdAt DESC, d.id
    """
  )
  fun observeAll(): Flow<List<DocumentRow>>

  @Query(
    """
    SELECT d.*, p.name AS projectName, p.isArchived AS projectIsArchived,
      (SELECT COUNT(*) FROM document_chunks c WHERE c.documentId = d.id) AS chunkCount
    FROM documents d LEFT JOIN projects p ON p.id = d.projectId
    WHERE d.id = :id
    """
  )
  fun observe(id: String): Flow<DocumentRow?>

  @Query("SELECT * FROM documents WHERE id = :id")
  suspend fun get(id: String): DocumentEntity?

  @Query("SELECT EXISTS(SELECT 1 FROM documents WHERE contentFingerprint = :fingerprint)")
  suspend fun existsWithFingerprint(fingerprint: String): Boolean

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insert(document: DocumentEntity)

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insertChunks(chunks: List<DocumentChunkEntity>)

  @Query("UPDATE documents SET title = :title, updatedAt = :now WHERE id = :id")
  suspend fun rename(id: String, title: String, now: Long): Int

  @Query("UPDATE documents SET isEnabled = :enabled, updatedAt = :now WHERE id = :id")
  suspend fun setEnabled(id: String, enabled: Boolean, now: Long): Int

  @Query("UPDATE documents SET projectId = :projectId, updatedAt = :now WHERE id = :id")
  suspend fun setProject(id: String, projectId: String?, now: Long): Int

  @Query("SELECT * FROM document_chunks WHERE documentId = :documentId ORDER BY chunkIndex LIMIT :limit")
  suspend fun firstChunks(documentId: String, limit: Int): List<DocumentChunkEntity>

  @Query("SELECT id FROM document_chunks WHERE documentId = :documentId")
  suspend fun chunkIds(documentId: String): List<String>

  @Query("DELETE FROM document_chunks WHERE documentId = :documentId")
  suspend fun deleteChunks(documentId: String)

  @Query("DELETE FROM documents WHERE id = :id")
  suspend fun delete(id: String): Int
}

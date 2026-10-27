package com.omergirgin.mosaic.data.db

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

/*
 * Imported document source text (iOS `ImportedDocumentRecord` / `DocumentChunkRecord`). Field
 * names follow iOS so a portable backup can map them one-to-one. Project membership is a separate
 * binding (unlinked documents are available everywhere; linked ones are project-only), so it is
 * stored as a nullable column here rather than a sidecar table.
 *
 * Shared contract: the documents feature owns import/UI; retrieval reads chunks for recall.
 */

@Entity(
  tableName = "documents",
  foreignKeys = [
    // A deleted project leaves its documents available everywhere rather than deleting user files.
    ForeignKey(
      entity = ProjectEntity::class,
      parentColumns = ["id"],
      childColumns = ["projectId"],
      onDelete = ForeignKey.SET_NULL,
    ),
  ],
  indices = [Index("projectId"), Index("isEnabled")],
)
internal data class DocumentEntity(
  @PrimaryKey val id: String,
  val title: String,
  val sourceFilename: String,
  val mimeType: String,
  /** SHA-256 hex of the extracted source text. */
  val contentFingerprint: String,
  val characterCount: Int,
  val pageCount: Int?,
  val ocrPageCount: Int,
  /** Weak-text pages beyond the OCR budget that kept their embedded text. */
  val ocrFallbackPageCount: Int,
  val isEnabled: Boolean,
  val projectId: String?,
  val createdAt: Long,
  val updatedAt: Long,
)

@Entity(
  tableName = "document_chunks",
  foreignKeys = [
    ForeignKey(
      entity = DocumentEntity::class,
      parentColumns = ["id"],
      childColumns = ["documentId"],
      onDelete = ForeignKey.CASCADE,
    ),
  ],
  indices = [Index(value = ["documentId", "chunkIndex"], unique = true)],
)
internal data class DocumentChunkEntity(
  @PrimaryKey val id: String,
  val documentId: String,
  val chunkIndex: Int,
  val content: String,
  /** 1-based PDF page; null for text/Markdown. */
  val pageNumber: Int?,
  val isOcrDerived: Boolean,
  val createdAt: Long,
)

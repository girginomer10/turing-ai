package com.omergirgin.mosaic.data.embeddings

import androidx.room.withTransaction
import com.omergirgin.mosaic.core.context.utf8Length
import com.omergirgin.mosaic.core.provider.supportsEmbeddings
import com.omergirgin.mosaic.data.api.EmbeddingProfileRepository
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.index.SemanticVectorStore
import com.omergirgin.mosaic.data.internal.FieldLimits
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.internal.newId
import com.omergirgin.mosaic.data.recall.RecallSourceKind
import com.omergirgin.mosaic.data.repo.ProviderRepositoryImpl
import java.text.NumberFormat
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Embedding profiles plus document-index maintenance. Long operations (backfill, rebuild) run in
 * the application scope so leaving the screen does not abandon a half-written cache, and only
 * one runs at a time.
 */
internal class EmbeddingProfileRepositoryImpl(
  private val db: MosaicDatabase,
  private val vectors: SemanticVectorStore,
  private val indexer: DocumentIndexer,
  private val scope: CoroutineScope,
) : EmbeddingProfileRepository {
  private val dao = db.embeddingProfiles()
  private val operationLock = Mutex()
  private val status = MutableStateFlow(DocumentIndexingStatus())

  override val documentIndexing: StateFlow<DocumentIndexingStatus> = status.asStateFlow()

  override fun observeProfiles(): Flow<List<EmbeddingProfile>> =
    dao.observeAll().map { rows -> rows.map { it.toModel() } }.distinctUntilChanged()

  override suspend fun saveProfile(draft: EmbeddingProfileDraft): EmbeddingProfile {
    val name = draft.displayName.trim()
    val model = draft.modelId.trim()
    require(name.isNotEmpty()) { "Enter a name for this embedding model." }
    require(utf8Length(name) <= FieldLimits.MEMORY_TITLE_BYTES) { "The name is too long." }
    require(model.isNotEmpty()) { "Enter an embedding model ID." }
    require(utf8Length(model) <= FieldLimits.MODEL_ID_BYTES && model.none { it == '\n' || it == '\r' }) {
      "Enter a model ID without line breaks (at most 2 KB)."
    }
    require(draft.indexesConversations || draft.indexesDocuments) { "At least one source must be enabled." }
    val provider = requireNotNull(db.providers().get(draft.providerId)) { "Choose an embedding provider connection." }
    require(ProviderRepositoryImpl.kindOf(provider).supportsEmbeddings) {
      "This provider connection does not support embeddings in Turing AI."
    }
    val weight = if (draft.weight.isFinite()) {
      draft.weight.coerceIn(EmbeddingProfilePolicy.MINIMUM_WEIGHT, EmbeddingProfilePolicy.MAXIMUM_WEIGHT)
    } else {
      1.0
    }

    val entity = withContext(NonCancellable) {
      db.withTransaction {
        val existing = draft.id?.let { dao.get(it) }
        if (draft.id != null) requireNotNull(existing) { "This embedding model no longer exists." }
        val id = existing?.id ?: newId()
        if (draft.isEnabled && dao.enabledCountExcluding(id) >= EmbeddingProfilePolicy.MAXIMUM_ENABLED_PROFILES) {
          throw IllegalStateException(EmbeddingProfilePolicy.LIMIT_DESCRIPTION)
        }
        val now = MonotonicClock.now()
        val row = EmbeddingProfileEntity(
          id = id,
          displayName = name,
          providerId = provider.id,
          modelId = model,
          weight = weight,
          isEnabled = draft.isEnabled,
          indexesConversations = draft.indexesConversations,
          indexesDocuments = draft.indexesDocuments,
          createdAt = existing?.createdAt ?: now,
          updatedAt = now,
        )
        dao.upsert(row)
        row
      }
    }
    if (entity.isEnabled && entity.indexesDocuments) backfillDocuments()
    return entity.toModel()
  }

  override suspend fun setProfileEnabled(id: String, enabled: Boolean) {
    withContext(NonCancellable) {
      db.withTransaction {
        requireNotNull(dao.get(id)) { "This embedding model no longer exists." }
        if (enabled && dao.enabledCountExcluding(id) >= EmbeddingProfilePolicy.MAXIMUM_ENABLED_PROFILES) {
          throw IllegalStateException(EmbeddingProfilePolicy.LIMIT_DESCRIPTION)
        }
        dao.setEnabled(id, enabled, MonotonicClock.now())
      }
    }
    if (enabled) backfillDocuments()
  }

  override suspend fun deleteProfile(id: String): String? {
    withContext(NonCancellable) { db.withTransaction { dao.delete(id) } }
    // The source row is gone first; the cache is derived and can be swept by a rebuild later.
    return withContext(NonCancellable) {
      try {
        operationLock.withLock { vectors.deleteProfile(id) }
        null
      } catch (error: Exception) {
        "The embedding model was deleted, but its rebuildable vector cache could not be cleared completely. " +
          "Rebuild the document index to clean it up."
      }
    }
  }

  override suspend fun documentIndexHealth(): DocumentIndexHealth = indexer.health()

  override fun backfillDocuments() {
    launchOperation(rebuild = false)
  }

  override fun rebuildDocumentIndex() {
    launchOperation(rebuild = true)
  }

  override suspend fun indexDocuments(documentIds: Collection<String>): List<String> {
    if (documentIds.isEmpty() || dao.enabledCount() == 0) return emptyList()
    return operationLock.withLock {
      status.value = DocumentIndexingStatus(isRunning = true)
      try {
        indexer.index(documentIds).also { status.value = completion(it) }
      } finally {
        if (status.value.isRunning) status.value = DocumentIndexingStatus()
      }
    }
  }

  /** Drops every profile's vectors for deleted chunks. Without profiles the cache is never opened. */
  suspend fun dropDocumentVectors(chunkIds: Collection<String>) {
    if (chunkIds.isEmpty() || (dao.all().isEmpty() && !vectors.isOpen)) return
    vectors.deleteSources(RecallSourceKind.DOCUMENT_CHUNK.rawValue, chunkIds)
  }

  /**
   * Drops every profile's vectors for a deleted chat's messages and the learned topics scoped to
   * it (iOS `deleteConversationVectors`). Without profiles the cache is never opened.
   */
  suspend fun dropConversationVectors(messageIds: Collection<String>, topicIds: Collection<String>) {
    if ((messageIds.isEmpty() && topicIds.isEmpty()) || (dao.all().isEmpty() && !vectors.isOpen)) return
    vectors.deleteSources(RecallSourceKind.CONVERSATION_MESSAGE.rawValue, messageIds)
    vectors.deleteSources(RecallSourceKind.MEMORY_TOPIC.rawValue, topicIds)
  }

  private fun launchOperation(rebuild: Boolean) {
    scope.launch {
      if (!operationLock.tryLock()) return@launch
      try {
        status.value = DocumentIndexingStatus(isRunning = true)
        status.value = try {
          val warnings = if (rebuild) indexer.rebuildAllEnabledDocuments() else indexer.indexAllEnabledDocuments()
          completion(warnings)
        } catch (error: CancellationException) {
          throw error
        } catch (error: Exception) {
          val details = error.message ?: "The document index could not be rebuilt."
          DocumentIndexingStatus(
            outcome = DocumentIndexingOutcome.FAILURE,
            message = if (details.contains("lexical recall", ignoreCase = true)) "Rebuild failed: $details"
            else "Rebuild failed: $details Local lexical recall remains available.",
          )
        }
      } finally {
        if (status.value.isRunning) status.value = DocumentIndexingStatus()
        operationLock.unlock()
      }
    }
  }

  private suspend fun completion(warnings: List<String>): DocumentIndexingStatus {
    if (warnings.isNotEmpty()) {
      return DocumentIndexingStatus(outcome = DocumentIndexingOutcome.WARNING, message = warnings.joinToString(" "))
    }
    val health = runCatching { indexer.health() }.getOrNull()
    val message = when {
      health == null -> "Document indexing finished."
      health.enabledDocumentCount == 0 -> "No enabled documents need indexing."
      health.expectedVectorCount == 0 -> "Document indexing finished; no document vectors are required."
      else -> {
        val format = NumberFormat.getIntegerInstance()
        "${format.format(health.validVectorCount)} of ${format.format(health.expectedVectorCount)} document vectors are current."
      }
    }
    return DocumentIndexingStatus(outcome = DocumentIndexingOutcome.SUCCESS, message = message)
  }

  private fun EmbeddingProfileEntity.toModel() = EmbeddingProfile(
    id = id,
    displayName = displayName,
    providerId = providerId,
    modelId = modelId,
    weight = weight,
    isEnabled = isEnabled,
    indexesConversations = indexesConversations,
    indexesDocuments = indexesDocuments,
    createdAt = createdAt,
    updatedAt = updatedAt,
  )
}

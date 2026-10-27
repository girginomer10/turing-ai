package com.omergirgin.mosaic.data.recall

import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.context.utf8Length
import com.omergirgin.mosaic.core.retrieval.EmbeddingVectorCodec
import com.omergirgin.mosaic.data.model.MessageStatus
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Per-lane ceilings shared with iOS (`maximumCandidatesPerSource`, 8 MiB payload). */
internal object RecallLimits {
  const val MAXIMUM_CANDIDATES_PER_SOURCE = 5_000
  const val MAXIMUM_CANDIDATE_UTF8_BYTES_PER_SOURCE = 8L * 1_024 * 1_024
  const val MAXIMUM_SCANNED_RECORDS = 20_000
  const val SOURCE_PAGE_SIZE = 128
}

/**
 * Registered recall sources. Earlier-chat messages and documents are built in; automatic memory
 * registers its learned-topic source (and optional message suppression) from DataContainer.
 */
internal class RecallSourceRegistry {
  private val sources = CopyOnWriteArrayList<RecallCandidateSource>()

  /** Set by automatic memory: consolidated evidence messages are excluded from raw recall. */
  @Volatile var messageSuppression: RecallMessageSuppression? = null

  fun register(source: RecallCandidateSource) {
    if (sources.none { it === source }) sources += source
  }

  fun snapshot(): List<RecallCandidateSource> = sources.toList()
}

/**
 * Completed user messages from earlier chats in the same audience, newest first. Keys are read
 * without content, then rows in 128-ID pages until 5,000 candidates or 8 MiB of text.
 */
internal class MessageRecallSource(
  private val dao: RecallDao,
  private val registry: RecallSourceRegistry,
) : RecallCandidateSource {
  override suspend fun candidates(scope: RecallScope): List<RecallCandidate> {
    val keys = dao.messageKeys(scope.conversationId, scope.projectId, RecallLimits.MAXIMUM_SCANNED_RECORDS)
    val selected = ArrayList<RecallCandidate>()
    var bytes = 0L
    for (page in keys.chunked(RecallLimits.SOURCE_PAGE_SIZE)) {
      currentCoroutineContext().ensureActive()
      val ids = page.map { it.id }
      val rows = dao.messages(ids, scope.conversationId, scope.projectId).associateBy { it.id }
      val suppressed = registry.messageSuppression?.suppressedMessageIds(ids).orEmpty()
      for (id in ids) {
        val row = rows[id] ?: continue
        if (id in suppressed || row.content.isBlank()) continue
        bytes += utf8Length(row.content)
        if (bytes > RecallLimits.MAXIMUM_CANDIDATE_UTF8_BYTES_PER_SOURCE) return selected
        selected += RecallCandidate(
          kind = RecallSourceKind.CONVERSATION_MESSAGE,
          id = row.id,
          containerId = row.conversationId,
          title = row.conversationTitle.ifBlank { "Earlier conversation" },
          text = row.content,
          contentFingerprint = EmbeddingVectorCodec.fingerprint(row.content),
          createdAt = row.createdAt,
        )
        if (selected.size >= RecallLimits.MAXIMUM_CANDIDATES_PER_SOURCE) return selected
      }
    }
    return selected
  }

  override suspend fun validate(scope: RecallScope, candidates: List<RecallCandidate>): Set<String> {
    val expected = candidates.filter { it.kind == RecallSourceKind.CONVERSATION_MESSAGE }.associateBy { it.id }
    if (expected.isEmpty()) return emptySet()
    val valid = HashSet<String>()
    for (page in expected.keys.chunked(RecallLimits.SOURCE_PAGE_SIZE)) {
      currentCoroutineContext().ensureActive()
      val suppressed = registry.messageSuppression?.suppressedMessageIds(page).orEmpty()
      for (row in dao.messageValidation(page)) {
        val candidate = expected[row.id] ?: continue
        if (row.id in suppressed) continue
        if (row.conversationId != candidate.containerId || row.conversationId == scope.conversationId) continue
        if (row.role != ChatRole.USER.rawValue || row.status != MessageStatus.COMPLETE.name) continue
        if (row.projectId != scope.projectId) continue
        if (EmbeddingVectorCodec.fingerprint(row.content) != candidate.contentFingerprint) continue
        valid += row.id
      }
    }
    return valid
  }
}

/**
 * Chunks of enabled documents visible to the audience (global, or linked to the chat's project),
 * most recently updated documents first, in chunk order.
 */
internal class DocumentRecallSource(private val dao: RecallDao) : RecallCandidateSource {
  override suspend fun candidates(scope: RecallScope): List<RecallCandidate> {
    val documents = dao.accessibleDocuments(scope.projectId, RecallLimits.MAXIMUM_SCANNED_RECORDS)
    val selected = ArrayList<RecallCandidate>()
    var bytes = 0L
    var scanned = 0
    for (document in documents) {
      var cursor = -1
      while (selected.size < RecallLimits.MAXIMUM_CANDIDATES_PER_SOURCE && scanned < RecallLimits.MAXIMUM_SCANNED_RECORDS) {
        currentCoroutineContext().ensureActive()
        val limit = minOf(
          RecallLimits.SOURCE_PAGE_SIZE,
          RecallLimits.MAXIMUM_CANDIDATES_PER_SOURCE - selected.size,
          RecallLimits.MAXIMUM_SCANNED_RECORDS - scanned,
        )
        val page = dao.chunkPage(document.id, cursor, limit)
        if (page.isEmpty()) break
        scanned += page.size
        for (chunk in page) {
          if (chunk.content.isBlank()) continue
          bytes += utf8Length(chunk.content)
          if (bytes > RecallLimits.MAXIMUM_CANDIDATE_UTF8_BYTES_PER_SOURCE) return selected
          selected += chunk.toCandidate(document.title)
          if (selected.size >= RecallLimits.MAXIMUM_CANDIDATES_PER_SOURCE) return selected
        }
        cursor = page.last().chunkIndex
        if (page.size < limit) break
      }
      if (selected.size >= RecallLimits.MAXIMUM_CANDIDATES_PER_SOURCE || scanned >= RecallLimits.MAXIMUM_SCANNED_RECORDS) break
    }
    return selected
  }

  override suspend fun validate(scope: RecallScope, candidates: List<RecallCandidate>): Set<String> {
    val expected = candidates.filter { it.kind == RecallSourceKind.DOCUMENT_CHUNK }.associateBy { it.id }
    if (expected.isEmpty()) return emptySet()
    val valid = HashSet<String>()
    for (page in expected.keys.chunked(RecallLimits.SOURCE_PAGE_SIZE)) {
      currentCoroutineContext().ensureActive()
      for (row in dao.chunkValidation(page)) {
        val candidate = expected[row.id] ?: continue
        if (row.documentId != candidate.containerId || !row.isEnabled) continue
        if (row.projectId != null && row.projectId != scope.projectId) continue
        if (EmbeddingVectorCodec.fingerprint(row.content) != candidate.contentFingerprint) continue
        valid += row.id
      }
    }
    return valid
  }

  companion object {
    internal fun RecallChunkRow.toCandidate(documentTitle: String): RecallCandidate {
      val attributes = buildMap {
        pageNumber?.let { put(RecallAttributes.PAGE, it.toString()) }
        if (isOcrDerived) put(RecallAttributes.EXTRACTION, RecallAttributes.EXTRACTION_OCR)
      }
      return RecallCandidate(
        kind = RecallSourceKind.DOCUMENT_CHUNK,
        id = id,
        containerId = documentId,
        title = documentTitle.ifBlank { "Imported document" },
        text = content,
        contentFingerprint = EmbeddingVectorCodec.fingerprint(content),
        createdAt = createdAt,
        attributes = attributes,
      )
    }
  }
}

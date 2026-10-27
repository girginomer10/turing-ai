package com.omergirgin.mosaic.data.backup

import androidx.room.withTransaction
import com.omergirgin.mosaic.core.backup.PortableBlob
import com.omergirgin.mosaic.data.db.AttachmentEntity
import com.omergirgin.mosaic.data.db.CompactionArtifactEntity
import com.omergirgin.mosaic.data.db.CompactionHeadEntity
import com.omergirgin.mosaic.data.db.ConversationEntity
import com.omergirgin.mosaic.data.db.DocumentChunkEntity
import com.omergirgin.mosaic.data.db.DocumentEntity
import com.omergirgin.mosaic.data.db.MemoryEvidenceEntity
import com.omergirgin.mosaic.data.db.MemoryFactEntity
import com.omergirgin.mosaic.data.db.MemoryFormationAuditEntity
import com.omergirgin.mosaic.data.db.MemoryFormationJobEntity
import com.omergirgin.mosaic.data.db.MemoryRevisionEntity
import com.omergirgin.mosaic.data.db.MemoryTopicEntity
import com.omergirgin.mosaic.data.db.MessageEntity
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.ProjectEntity
import com.omergirgin.mosaic.data.db.ProviderEntity
import com.omergirgin.mosaic.data.db.ProviderModelEntity
import com.omergirgin.mosaic.data.db.ScheduledTaskEntity
import com.omergirgin.mosaic.data.db.UsageRecordEntity
import com.omergirgin.mosaic.data.branching.ConversationBranchEntity
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfileEntity
import com.omergirgin.mosaic.data.pricing.ModelPriceOverrideEntity
import java.io.File
import java.util.Base64

/** An attachment row whose photo bytes may still be on disk until the restore transaction. */
internal class StagedAttachment(val entity: AttachmentEntity, val image: PortableBlob?)

/**
 * The complete replacement library as Android rows, built and validated before any live write.
 * [stagingDir] holds spilled photo bytes and is deleted after apply or discard.
 */
internal class RestorePlan(
  val providers: List<ProviderEntity>,
  val providerModels: List<ProviderModelEntity>,
  val projects: List<ProjectEntity>,
  val conversations: List<ConversationEntity>,
  val messages: List<MessageEntity>,
  val attachments: List<StagedAttachment>,
  val facts: List<MemoryFactEntity>,
  val usage: List<UsageRecordEntity>,
  val documents: List<DocumentEntity>,
  val chunks: List<DocumentChunkEntity>,
  val artifacts: List<CompactionArtifactEntity>,
  val heads: List<CompactionHeadEntity>,
  val tasks: List<ScheduledTaskEntity>,
  val profiles: List<EmbeddingProfileEntity>,
  val topics: List<MemoryTopicEntity>,
  val evidence: List<MemoryEvidenceEntity>,
  val revisions: List<MemoryRevisionEntity>,
  val jobs: List<MemoryFormationJobEntity>,
  val audits: List<MemoryFormationAuditEntity>,
  val priceOverrides: List<ModelPriceOverrideEntity>,
  val branches: List<ConversationBranchEntity>,
  val stagingDir: File,
) {
  val rowCount: Long
    get() = listOf(
      providers.size, providerModels.size, projects.size, conversations.size, messages.size, attachments.size, facts.size,
      usage.size, documents.size, chunks.size, artifacts.size, heads.size, tasks.size, profiles.size, topics.size,
      evidence.size, revisions.size, jobs.size, audits.size, priceOverrides.size, branches.size,
    ).sumOf { it.toLong() }

  /**
   * Deletes every logical record and inserts the plan in one transaction; any failure (including a
   * constraint violation) rolls everything back so the previous library stays intact.
   */
  suspend fun replace(db: MosaicDatabase, onProgress: (Long) -> Unit) {
    val dao = db.backup()
    db.withTransaction {
      // Children first; foreign keys stay enforced so a dangling row aborts the transaction.
      dao.clearMemoryAudits()
      dao.clearMemoryJobs()
      dao.clearMemoryRevisions()
      dao.clearMemoryEvidence()
      dao.clearMemoryTopics()
      dao.clearRequestEvents()
      dao.clearCompactionHeads()
      dao.clearCompactionArtifacts()
      dao.clearReceipts()
      dao.clearAttachments()
      dao.clearConnectionReceipts()
      dao.clearConnectionActivity()
      dao.clearBranches()
      dao.clearPriceOverrides()
      dao.clearTaskRuns()
      dao.clearTasks()
      dao.clearUsage()
      dao.clearMemoryFacts()
      dao.clearChunks()
      dao.clearDocuments()
      dao.clearEmbeddingProfiles()
      dao.clearMessages()
      dao.clearConversations()
      dao.clearProjects()
      dao.clearProviderModels()
      dao.clearProviders()

      var done = 0L
      suspend fun <T> insert(rows: List<T>, block: suspend (List<T>) -> Unit) {
        for (chunk in rows.chunked(BATCH)) {
          block(chunk)
          done += chunk.size
          onProgress(done)
        }
      }
      insert(providers) { dao.insertProviders(it) }
      insert(providerModels) { dao.insertProviderModels(it) }
      insert(projects) { dao.insertProjects(it) }
      insert(conversations) { dao.insertConversations(it) }
      insert(messages) { dao.insertMessages(it) }
      for (staged in attachments) {
        val image = staged.image?.let { Base64.getEncoder().encodeToString(it.load()) }
        dao.insertAttachment(staged.entity.copy(imageBase64 = image))
        onProgress(++done)
      }
      insert(facts) { dao.insertMemoryFacts(it) }
      insert(usage) { dao.insertUsage(it) }
      insert(documents) { dao.insertDocuments(it) }
      insert(chunks) { dao.insertChunks(it) }
      insert(artifacts) { dao.insertCompactionArtifacts(it) }
      insert(heads) { dao.insertCompactionHeads(it) }
      insert(tasks) { dao.insertTasks(it) }
      insert(profiles) { dao.insertEmbeddingProfiles(it) }
      insert(topics) { dao.insertMemoryTopics(it) }
      insert(evidence) { dao.insertMemoryEvidence(it) }
      insert(revisions) { dao.insertMemoryRevisions(it) }
      insert(jobs) { dao.insertMemoryJobs(it) }
      insert(audits) { dao.insertMemoryAudits(it) }
      insert(priceOverrides) { dao.insertPriceOverrides(it) }
      insert(branches) { dao.insertBranches(it) }
    }
  }

  fun discard() {
    stagingDir.deleteRecursively()
  }

  private companion object {
    const val BATCH = 256
  }
}

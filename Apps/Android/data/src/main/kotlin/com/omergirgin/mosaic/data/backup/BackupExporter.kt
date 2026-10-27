package com.omergirgin.mosaic.data.backup

import androidx.room.withTransaction
import com.omergirgin.mosaic.core.backup.CompactionRules
import com.omergirgin.mosaic.core.backup.IosTextRules
import com.omergirgin.mosaic.core.backup.MemoryGraphRules
import com.omergirgin.mosaic.core.backup.PJArray
import com.omergirgin.mosaic.core.backup.PJString
import com.omergirgin.mosaic.core.backup.PortableBackupLimits
import com.omergirgin.mosaic.core.backup.PortableBackupValidator
import com.omergirgin.mosaic.core.backup.PortableBackupWriter
import com.omergirgin.mosaic.core.backup.PortableBlob
import com.omergirgin.mosaic.core.backup.PortableCompactionArtifact
import com.omergirgin.mosaic.core.backup.PortableCompactionHead
import com.omergirgin.mosaic.core.backup.PortableConversation
import com.omergirgin.mosaic.core.backup.PortableDate
import com.omergirgin.mosaic.core.backup.PortableDocumentChunk
import com.omergirgin.mosaic.core.backup.PortableEmbeddingProfile
import com.omergirgin.mosaic.core.backup.PortableExperienceValue
import com.omergirgin.mosaic.core.backup.PortableExtensionRecord
import com.omergirgin.mosaic.core.backup.PortableHashes
import com.omergirgin.mosaic.core.backup.PortableIds
import com.omergirgin.mosaic.core.backup.PortableImportedDocument
import com.omergirgin.mosaic.core.backup.PortableJsonReader
import com.omergirgin.mosaic.core.backup.PortableMemory
import com.omergirgin.mosaic.core.backup.PortableMemoryEvidence
import com.omergirgin.mosaic.core.backup.PortableMemoryFormationAudit
import com.omergirgin.mosaic.core.backup.PortableMemoryFormationJob
import com.omergirgin.mosaic.core.backup.PortableMemoryRevision
import com.omergirgin.mosaic.core.backup.PortableMemoryTopic
import com.omergirgin.mosaic.core.backup.PortableMessage
import com.omergirgin.mosaic.core.backup.PortableModelSelection
import com.omergirgin.mosaic.core.backup.PortableNamespaces
import com.omergirgin.mosaic.core.backup.PortableProject
import com.omergirgin.mosaic.core.backup.PortableProjectBinding
import com.omergirgin.mosaic.core.backup.PortableProviderConfiguration
import com.omergirgin.mosaic.core.backup.PortableScheduledTask
import com.omergirgin.mosaic.core.backup.PortableWebSource
import com.omergirgin.mosaic.core.backup.SwiftJsonWriter
import com.omergirgin.mosaic.data.db.AttachmentEntity
import com.omergirgin.mosaic.data.db.Codecs
import com.omergirgin.mosaic.data.db.CompactionArtifactEntity
import com.omergirgin.mosaic.data.db.MosaicDatabase
import java.io.File
import java.net.URI
import java.util.Base64
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

/** Result of writing one snapshot; the file is the final checksummed envelope. */
internal class ExportOutcome(val file: File, val contents: BackupContents, val notes: List<String>)

/**
 * Android library → iOS `.mosaicbackup`. Runs inside one Room transaction so the snapshot is
 * consistent, reads every growing table in bounded keyset pages and streams records straight into
 * the hashed body file. Rules iOS enforces on restore (memory provenance, compaction coverage,
 * attachment shapes) are applied before writing; anything that would make the whole file
 * unrestorable on iOS is left out and reported instead.
 */
internal class BackupExporter(
  private val db: MosaicDatabase,
  private val workDir: File,
  private val limits: PortableBackupLimits = PortableBackupLimits.DEFAULT,
) {
  private val dao = db.backup()

  suspend fun export(destination: File, onProgress: (BackupProgress) -> Unit): ExportOutcome {
    val bodyFile = File(workDir, "export-body-${PortableIds.random()}.tmp")
    try {
      return db.withTransaction { write(bodyFile, destination, onProgress) }
    } finally {
      bodyFile.delete()
    }
  }

  private class Counters {
    var conversations = 0
    var messages = 0
    var attachments = 0
    var facts = 0
    var topics = 0
    var documents = 0
    var projects = 0
    var providers = 0
    var tasks = 0
    var profiles = 0
    var processed = 0L
  }

  private suspend fun write(bodyFile: File, destination: File, onProgress: (BackupProgress) -> Unit): ExportOutcome {
    val notes = ArrayList<String>()
    val counters = Counters()
    val createdAt = PortableDate.fromMillis(System.currentTimeMillis())
    val total = dao.conversationCount().toLong() + dao.messageCount() + dao.chunkCount() + dao.usageCount()
    fun progress(step: Long = 1) {
      counters.processed += step
      if (counters.processed % PROGRESS_STEP == 0L) {
        onProgress(BackupProgress(BackupProgress.Stage.READING_LIBRARY, counters.processed, total))
      }
    }
    onProgress(BackupProgress(BackupProgress.Stage.READING_LIBRARY, 0, total))

    // region indexes (small tables fully, transcripts as light rows)
    val providers = dao.providers()
    val providerModels = dao.providerModels()
    val projects = dao.projects()
    val conversationFacts = dao.conversationFacts()
    val conversationIds = conversationFacts.mapTo(HashSet()) { it.id }
    val projectIds = projects.mapTo(HashSet()) { it.id }
    val projectByConversation = conversationFacts.mapNotNull { row -> row.projectId?.let { row.id to it } }.toMap()
    val messageFacts = HashMap<String, MessageFactRow>()
    var cursor = ""
    while (true) {
      coroutineContext.ensureActive()
      val page = dao.messageFactsAfter(cursor, FACT_PAGE)
      if (page.isEmpty()) break
      page.forEach { messageFacts[it.id] = it }
      cursor = page.last().id
    }
    val attachmentFacts = dao.attachmentFacts()
    val messagesWithAttachments = attachmentFacts.mapTo(HashSet()) { it.messageId }
    val contents = CanonicalContents(messagesWithAttachments)
    // endregion

    PortableBackupWriter(bodyFile, PortableIds.random(), limits).use { writer ->
      // region compaction (validated against the iOS canonical transcript)
      val (artifacts, heads) = compaction(conversationIds, messageFacts, contents, notes)
      writer.beginCollection("compactionArtifacts")
      artifacts.sortedBy { PortableIds.toPortable(it.id) }.forEach { writer.record("compaction_artifact", it.toPJ()) }
      writer.endCollection()
      writer.beginCollection("conversationCompactionHeads")
      heads.sortedBy { PortableIds.toPortable(it.conversationID) }.forEach { writer.record("conversation_compaction_head", it.toPJ()) }
      writer.endCollection()
      // endregion

      writer.beginCollection("conversations")
      cursor = ""
      while (true) {
        coroutineContext.ensureActive()
        val page = dao.conversationsAfter(cursor, CONVERSATION_PAGE)
        if (page.isEmpty()) break
        for (row in page) {
          writer.record(
            "conversation",
            PortableConversation(
              id = row.id, title = row.title, providerConfigurationID = row.modelProviderId,
              modelIdentifier = row.modelId ?: "", systemPrompt = row.systemPrompt, draftText = row.draft,
              compactionSnapshotData = null, isArchived = row.isArchived,
              createdAt = PortableDate.fromMillis(row.createdAt), updatedAt = PortableDate.fromMillis(row.updatedAt),
            ).toPJ(),
          )
          counters.conversations++
          progress()
        }
        cursor = page.last().id
      }
      writer.endCollection()

      writer.createdAt(createdAt)

      writer.beginCollection("documentChunks")
      cursor = ""
      while (true) {
        coroutineContext.ensureActive()
        val page = dao.chunksAfter(cursor, CHUNK_PAGE)
        if (page.isEmpty()) break
        for (row in page) {
          writer.record(
            "document_chunk",
            PortableDocumentChunk(
              id = row.id, documentID = row.documentId, chunkIndex = row.chunkIndex, content = row.content,
              pageNumber = row.pageNumber, isOCRDerived = row.isOcrDerived, createdAt = PortableDate.fromMillis(row.createdAt),
            ).toPJ(),
          )
          progress()
        }
        cursor = page.last().id
      }
      writer.endCollection()

      writer.beginCollection("embeddingProfiles")
      for (row in dao.embeddingProfiles()) {
        writer.record(
          "embedding_profile",
          PortableEmbeddingProfile(
            id = row.id, displayName = row.displayName, backendRawValue = "provider", providerConfigurationID = row.providerId,
            modelIdentifier = row.modelId, weight = row.weight.takeIf { it.isFinite() }?.coerceIn(0.25, 2.0) ?: 1.0,
            isEnabled = row.isEnabled, indexesConversations = row.indexesConversations, indexesDocuments = row.indexesDocuments,
            createdAt = PortableDate.fromMillis(row.createdAt), updatedAt = PortableDate.fromMillis(row.updatedAt),
          ).toPJ(),
        )
        counters.profiles++
      }
      writer.endCollection()

      // region extension records (namespace, record type, then UUID order)
      writer.beginCollection("extensionRecords")
      fun emit(record: PortableExtensionRecord) = writer.record("extension_record", record.toPJ())
      fun emitSorted(records: List<PortableExtensionRecord>) =
        records.sortedWith(PortableExtensionRecord.ORDER).forEach(::emit)

      // experience/attachment: streamed one row at a time (photo bytes stay bounded).
      for (fact in attachmentFacts) {
        coroutineContext.ensureActive()
        val row = dao.attachment(fact.id) ?: continue
        val exported = exportableAttachment(row) ?: continue
        if (row.messageId !in messageFacts || row.conversationId !in conversationIds) continue
        emit(exported.value.toRecord())
        counters.attachments++
      }
      val skippedAttachments = attachmentFacts.size - counters.attachments
      if (skippedAttachments > 0) {
        notes += plural(skippedAttachments, "attachment was", "attachments were") +
          " left out because iOS cannot restore their format."
      }

      // experience/branch: edit-and-branch alternative groups.
      emitSorted(
        dao.branches().filter { it.conversationId in conversationIds }.map { row ->
          PortableExperienceValue(
            id = row.id, kind = PortableExperienceValue.BRANCH, conversationID = row.conversationId,
            branchGroupID = row.branchGroupId, originalConversationID = row.originalConversationId,
            updatedAt = PortableDate.fromMillis(row.updatedAt),
          ).toRecord()
        }
      )
      // experience/model: per-model photo capability overrides and custom prices (one value each).
      val prices = dao.priceOverrides().filter { row ->
        listOf(row.inputPerMillion, row.outputPerMillion).all { it.isFinite() && it >= 0 && it <= 1_000_000 }
      }.associateBy { it.providerId to it.modelId }
      val imageOverrides = providerModels.filter { it.supportsImages != null }.associateBy { it.providerId to it.modelId }
      emitSorted(
        (imageOverrides.keys + prices.keys).filter { (_, model) -> model.isNotEmpty() && PortableMapping.utf8(model) <= 2_048 }
          .map { (providerId, model) ->
            val price = prices[providerId to model]
            PortableExperienceValue(
              id = PortableExperienceValue.derivedId(PortableModelSelection.selectionKey(providerId, model)),
              kind = PortableExperienceValue.MODEL, providerID = providerId, model = model,
              supportsImages = imageOverrides[providerId to model]?.supportsImages,
              inputPricePerMillion = price?.inputPerMillion, outputPricePerMillion = price?.outputPerMillion,
              updatedAt = price?.updatedAt?.let(PortableDate::fromMillis) ?: createdAt,
            ).toRecord()
          }
      )
      // experience/projectDefault: per-project default model.
      emitSorted(
        projects.filter { it.defaultProviderId != null && !it.defaultModelId.isNullOrEmpty() }.map { row ->
          PortableExperienceValue(
            id = PortableExperienceValue.derivedId("default:" + PortableIds.toPortable(row.id)),
            kind = PortableExperienceValue.PROJECT_DEFAULT, providerID = row.defaultProviderId, model = row.defaultModelId,
            projectID = row.id, updatedAt = PortableDate.fromMillis(row.updatedAt),
          ).toRecord()
        }
      )
      // experience/usage: request costs iOS cannot recompute from other records.
      var derivedUsage = 0
      cursor = ""
      while (true) {
        coroutineContext.ensureActive()
        val page = dao.usageAfter(cursor, USAGE_PAGE)
        if (page.isEmpty()) break
        for (row in page) {
          progress()
          if (row.category in PortableMapping.IOS_DERIVED_USAGE) { derivedUsage++; continue }
          val tokens = { value: Int? -> value?.takeIf { it in 0..1_000_000_000 } }
          emit(
            PortableExperienceValue(
              id = row.id, kind = PortableExperienceValue.USAGE,
              providerID = row.providerId ?: PortableIds.deterministicLocal("deleted-provider:${row.providerKind}:${row.providerName}"),
              model = row.modelId, conversationID = row.conversationId?.takeIf { it in conversationIds },
              messageID = row.messageId?.takeIf { id -> messageFacts[id]?.conversationId == row.conversationId && row.conversationId in conversationIds },
              usageCategory = PortableMapping.usageCategoryToPortable(row.category), inputTokens = tokens(row.inputTokens),
              outputTokens = tokens(row.outputTokens), usageDate = PortableDate.fromMillis(row.createdAt),
              usageProviderKind = PortableMapping.validProviderKind(row.providerKind),
              usageProviderHost = row.destinationHost?.takeIf { PortableMapping.utf8(it) <= 253 },
              updatedAt = PortableDate.fromMillis(row.createdAt),
            ).toRecord()
          )
        }
        cursor = page.last().id
      }
      // experience/webSources: answer citations.
      emitSorted(
        dao.citations().mapNotNull { row ->
          val sources = Codecs.decodeCitations(row.citationsJson).mapNotNull { source ->
            val host = runCatching { URI(source.url).host }.getOrNull()
            PortableWebSource((source.title?.takeIf { it.isNotBlank() } ?: host ?: "Source").take(500), source.url, null, null)
              .takeIf(PortableBackupValidator::isValidWebSource)
          }.take(100)
          val created = messageFacts[row.id]?.createdAt ?: return@mapNotNull null
          if (sources.isEmpty()) return@mapNotNull null
          PortableExperienceValue(
            id = PortableExperienceValue.derivedId("web:" + PortableIds.toPortable(row.id)),
            kind = PortableExperienceValue.WEB_SOURCES, conversationID = row.conversationId, messageID = row.id,
            sources = sources, updatedAt = PortableDate.fromMillis(created),
          ).toRecord()
        }
      )

      // memory/*: learned topics, evidence, history, formation jobs and audits.
      val memory = memoryGraph(conversationIds, projectByConversation, projectIds, messageFacts, contents, notes)
      counters.topics = memory.topics.size
      emitSorted(
        memory.evidence.map { it.toRecord() } + memory.audits.map { it.toRecord() } + memory.jobs.map { it.toRecord() } +
          memory.revisions.map { it.toRecord() } + memory.topics.map { it.toRecord() }
      )

      // models/*: catalogs and exact automation choices.
      val tasks = dao.scheduledTasks()
      val modelRecords = ArrayList<PortableExtensionRecord>()
      for (row in providerModels) {
        val contextWindow = row.contextWindowTokens?.takeIf { it in 2_048..2_000_000 }
        val selection = PortableModelSelection(
          recordType = PortableNamespaces.PROVIDER_MODEL,
          id = PortableIds.deterministicLocal("provider-model:" + PortableModelSelection.selectionKey(row.providerId, row.modelId)),
          providerID = row.providerId, modelIdentifier = row.modelId, enabled = row.isEnabled, contextWindow = contextWindow,
          maximumOutput = row.maximumOutputTokens?.takeIf { it > 0 && it <= (contextWindow ?: 16_777_216) },
        )
        if (PortableBackupValidator.isValidModelSelection(selection)) modelRecords += selection.toRecord()
      }
      for (task in tasks) {
        val providerId = task.providerId ?: continue
        val modelId = task.modelId ?: continue
        val selection = PortableModelSelection(PortableNamespaces.TASK_MODEL, task.id, providerId, modelId, null, null, null)
        if (PortableBackupValidator.isValidModelSelection(selection)) modelRecords += selection.toRecord()
      }
      emitSorted(modelRecords)

      // project/*: projects and resource bindings (Android keeps membership as columns).
      val projectRecords = ArrayList<PortableExtensionRecord>()
      val bindingDates = HashMap<String, PortableDate>()
      for (row in projects) {
        val created = PortableDate.fromMillis(row.createdAt)
        bindingDates[row.id] = created
        projectRecords += PortableProject(
          id = row.id, name = projectName(row.name),
          instructions = PortableMapping.boundedUtf8(row.instructions, PortableBackupValidator.MAXIMUM_PROJECT_INSTRUCTIONS_BYTES),
          isArchived = row.isArchived, createdAt = created,
          updatedAt = PortableDate.fromMillis(maxOf(row.createdAt, row.updatedAt)),
        ).toRecord()
        counters.projects++
      }
      fun binding(kind: String, resourceId: String, projectId: String) {
        val key = PortableProjectBinding.bindingKey(kind, PortableIds.toPortable(resourceId))
        val date = bindingDates.getValue(projectId)
        projectRecords += PortableProjectBinding(
          id = PortableIds.deterministicLocal("project-binding:$key"), bindingKey = key, resourceKindRawValue = kind,
          resourceID = resourceId, projectID = projectId, createdAt = date, updatedAt = date,
        ).toRecord()
      }
      projectByConversation.forEach { (conversation, project) -> if (project in projectIds) binding(PortableProjectBinding.CONVERSATION, conversation, project) }
      val facts = dao.memoryFacts()
      val exportedFacts = facts.filter { it.scope != "PROJECT" || it.projectId in projectIds }
      if (exportedFacts.size < facts.size) {
        notes += plural(facts.size - exportedFacts.size, "project memory without a project was", "project memories without a project were") +
          " left out."
      }
      exportedFacts.filter { it.scope == "PROJECT" }.forEach { binding(PortableProjectBinding.MEMORY, it.id, it.projectId!!) }
      memory.topics.filter { it.scopeRawValue == "project" }.forEach { topic ->
        memory.projectByTopic[topic.id]?.let { binding(PortableProjectBinding.MEMORY_TOPIC, topic.id, it) }
      }
      val documents = dao.documents()
      documents.forEach { document -> document.projectId?.takeIf { it in projectIds }?.let { binding(PortableProjectBinding.DOCUMENT, document.id, it) } }
      emitSorted(projectRecords)
      writer.endCollection()
      // endregion

      writer.beginCollection("importedDocuments")
      for (row in documents) {
        writer.record(
          "imported_document",
          PortableImportedDocument(
            id = row.id, title = row.title, sourceFilename = row.sourceFilename, mimeType = row.mimeType,
            contentFingerprint = row.contentFingerprint, characterCount = row.characterCount, pageCount = row.pageCount,
            ocrPageCount = row.ocrPageCount, ocrFallbackPageCount = row.ocrFallbackPageCount, isEnabled = row.isEnabled,
            createdAt = PortableDate.fromMillis(row.createdAt), updatedAt = PortableDate.fromMillis(row.updatedAt),
          ).toPJ(),
        )
        counters.documents++
      }
      writer.endCollection()

      writer.beginCollection("memories")
      for (row in exportedFacts) {
        writer.record(
          "memory",
          PortableMemory(
            id = row.id, title = PortableMapping.boundedUtf8(row.title, PortableBackupValidator.MAXIMUM_MEMORY_TITLE_BYTES),
            content = PortableMapping.boundedUtf8(row.content, PortableBackupValidator.MAXIMUM_MEMORY_CONTENT_BYTES),
            scopeRawValue = PortableMapping.factScopeToPortable(row.scope),
            conversationID = if (row.scope == "CONVERSATION") row.conversationId else null,
            isEnabled = row.isEnabled, isUserApproved = true,
            createdAt = PortableDate.fromMillis(row.createdAt), updatedAt = PortableDate.fromMillis(row.updatedAt),
          ).toPJ(),
        )
        counters.facts++
      }
      writer.endCollection()

      writer.beginCollection("messages")
      cursor = ""
      while (true) {
        coroutineContext.ensureActive()
        val page = dao.messagesAfter(cursor, MESSAGE_PAGE)
        if (page.isEmpty()) break
        for (row in page) {
          writer.record(
            "message",
            PortableMessage(
              id = row.id, conversationID = row.conversationId, roleRawValue = row.role,
              content = contents.canonical(row.id, row.content), statusRawValue = PortableMapping.messageStatusToPortable(row.status),
              providerConfigurationID = row.providerId, providerKindRawValue = PortableMapping.validProviderKind(row.providerKind),
              providerDisplayName = row.providerName, providerHost = row.destinationHost, providerMessageID = row.responseId,
              modelIdentifier = row.modelId, inputTokenCount = row.inputTokens, outputTokenCount = row.outputTokens,
              errorDescription = row.errorMessage, contextReceiptData = null,
              createdAt = PortableDate.fromMillis(row.createdAt), updatedAt = PortableDate.fromMillis(maxOf(row.createdAt, row.updatedAt)),
            ).toPJ(),
          )
          counters.messages++
          progress()
        }
        cursor = page.last().id
      }
      writer.endCollection()

      writer.beginCollection("normalizedBackfillProgress")
      writer.endCollection()

      writer.beginCollection("providerConfigurations")
      val modelsByProvider = providerModels.groupBy { it.providerId }
      for (row in providers) {
        val models = modelsByProvider[row.id].orEmpty()
        val primary = models.firstOrNull { it.isEnabled } ?: models.firstOrNull()
        writer.record(
          "provider_configuration",
          PortableProviderConfiguration(
            id = row.id, displayName = row.displayName, providerRawValue = row.kind, modelIdentifier = primary?.modelId ?: "",
            baseURLString = row.baseUrl, contextWindowTokens = primary?.contextWindowTokens?.takeIf { it in 2_048..2_000_000 },
            maximumOutputTokens = primary?.maximumOutputTokens?.takeIf { it in 128..1_000_000 }, isEnabled = row.isEnabled,
            createdAt = PortableDate.fromMillis(row.createdAt), updatedAt = PortableDate.fromMillis(row.updatedAt),
          ).toPJ(),
        )
        counters.providers++
      }
      writer.endCollection()

      writer.beginCollection("requestContextEvents")
      writer.endCollection()

      writer.beginCollection("scheduledTasks")
      var multiDay = 0
      var withProject = 0
      for (task in tasks) {
        if (Integer.bitCount(task.weekdayMask) > 1 && task.recurrence == "weekly") multiDay++
        if (task.projectId != null) withProject++
        writer.record(
          "scheduled_task",
          PortableScheduledTask(
            id = task.id, title = task.title, prompt = task.prompt,
            conversationID = task.lastConversationId?.takeIf { it in conversationIds }, providerConfigurationID = task.providerId,
            recurrenceRawValue = task.recurrence, statusRawValue = task.status, scheduledAt = PortableDate.fromMillis(task.scheduledAt),
            timeZoneIdentifier = task.timeZoneId, nextRunAt = task.nextRunAt?.let(PortableDate::fromMillis),
            lastRunAt = task.lastRunAt?.let(PortableDate::fromMillis), lastError = task.lastError,
            createdAt = PortableDate.fromMillis(task.createdAt), updatedAt = PortableDate.fromMillis(maxOf(task.createdAt, task.updatedAt)),
          ).toPJ(),
        )
        counters.tasks++
      }
      writer.endCollection()
      if (multiDay > 0) {
        notes += plural(multiDay, "weekly automation repeats", "weekly automations repeat") +
          " on several weekdays; iOS keeps only the weekday of the first run."
      }
      if (withProject > 0) notes += plural(withProject, "automation is", "automations are") + " restored on iOS without a project."

      writer.finish(destination)
    }
    onProgress(BackupProgress(BackupProgress.Stage.READING_LIBRARY, total, total))

    val receipts = dao.receiptCount()
    if (receipts > 0) notes += plural(receipts, "context receipt stays", "context receipts stay") + " on this device; receipts are not portable between platforms."
    if (dao.connectionActivityCount() > 0) notes += "Connected-account activity details stay on this device."
    val runs = dao.taskRunCount()
    if (runs > 0) notes += "Automation run history stays on this device."
    notes += "API keys, model favorites, app settings and the rebuildable search index are never included."
    return ExportOutcome(
      destination,
      BackupContents(
        conversations = counters.conversations, messages = counters.messages, attachments = counters.attachments,
        pinnedMemories = counters.facts, learnedTopics = counters.topics, documents = counters.documents,
        projects = counters.projects, providers = counters.providers, automations = counters.tasks,
        embeddingProfiles = counters.profiles,
      ),
      notes,
    )
  }

  private fun projectName(name: String): String {
    val trimmed = IosTextRules.trim(PortableMapping.boundedUtf8(name, PortableBackupValidator.MAXIMUM_PROJECT_NAME_BYTES))
    return trimmed.ifEmpty { "Untitled project" }
  }

  // region attachments and canonical text

  private class ExportedAttachment(val value: PortableExperienceValue, val embedded: IosTextRules.EmbeddedAttachment)

  /** iOS attachment shape: JPEG photo bytes, or extracted document text. */
  private fun exportableAttachment(row: AttachmentEntity): ExportedAttachment? {
    val filename = PortableMapping.boundedUtf8(row.fileName.trim(), 1_024)
      .ifEmpty { if (row.kind == "IMAGE") "Photo" else "Document" }
    val updatedAt = PortableDate.fromMillis(row.createdAt)
    return if (row.kind == "IMAGE") {
      val bytes = row.imageBase64?.let { runCatching { Base64.getMimeDecoder().decode(it) }.getOrNull() } ?: return null
      if (bytes.isEmpty() || bytes.size > 1_048_576 || !PortableMapping.isJpeg(bytes)) return null
      ExportedAttachment(
        PortableExperienceValue(
          id = row.id, kind = PortableExperienceValue.ATTACHMENT, conversationID = row.conversationId, messageID = row.messageId,
          filename = filename, mimeType = "image/jpeg", bytes = PortableBlob.inMemory(bytes), updatedAt = updatedAt,
        ),
        IosTextRules.EmbeddedAttachment.Image(PortableHashes.sha256Hex(bytes), filename),
      )
    } else {
      val text = row.extractedText?.takeIf { it.isNotEmpty() && PortableMapping.utf8(it) <= 800_000 } ?: return null
      val mime = row.mimeType.trim().takeIf { it.isNotEmpty() && !it.startsWith("image/") } ?: "text/plain"
      ExportedAttachment(
        PortableExperienceValue(
          id = row.id, kind = PortableExperienceValue.ATTACHMENT, conversationID = row.conversationId, messageID = row.messageId,
          filename = filename, mimeType = mime, extractedText = text, updatedAt = updatedAt,
        ),
        IosTextRules.EmbeddedAttachment.Document(filename, text),
      )
    }
  }

  /**
   * iOS canonical user text embeds attachments (photo digests, document JSON); Android keeps them
   * in rows. Every fingerprint in the export is computed over this same canonical text.
   */
  private inner class CanonicalContents(private val withAttachments: Set<String>) {
    private val cache = object : LinkedHashMap<String, String>(256, 0.75f, true) {
      override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?) = size > 512
    }

    suspend fun canonical(messageId: String, androidContent: String? = null): String {
      cache[messageId]?.let { return it }
      val content = androidContent ?: dao.messageContent(messageId) ?: return ""
      val result = if (messageId !in withAttachments) {
        content
      } else {
        val embedded = dao.attachmentsFor(messageId).mapNotNull { exportableAttachment(it)?.embedded }
        IosTextRules.canonicalContent(content, embedded)
          .takeIf { PortableMapping.utf8(it) <= PortableBackupValidator.MAXIMUM_MESSAGE_BYTES } ?: content
      }
      cache[messageId] = result
      return result
    }
  }

  // endregion

  // region memory graph

  private class MemoryExport(
    val topics: List<PortableMemoryTopic>,
    val evidence: List<PortableMemoryEvidence>,
    val revisions: List<PortableMemoryRevision>,
    val jobs: List<PortableMemoryFormationJob>,
    val audits: List<PortableMemoryFormationAudit>,
    val projectByTopic: Map<String, String>,
  )

  private suspend fun memoryGraph(
    conversationIds: Set<String>,
    projectByConversation: Map<String, String>,
    projectIds: Set<String>,
    messageFacts: Map<String, MessageFactRow>,
    contents: CanonicalContents,
    notes: MutableList<String>,
  ): MemoryExport {
    fun date(millis: Long) = PortableDate.fromMillis(millis)
    val topicRows = dao.memoryTopics()
    var topics = topicRows.map { row ->
      PortableMemoryTopic(
        id = row.id, canonicalKey = row.canonicalKey, title = row.title, content = row.content, kindRawValue = row.kind,
        scopeRawValue = row.scope, conversationID = row.conversationId, statusRawValue = row.status, originRawValue = row.origin,
        confidence = row.confidence, importance = row.importance, stabilityRawValue = row.stability, isEnabled = row.isEnabled,
        lastConfirmedAt = date(row.lastConfirmedAt), lastUsedAt = row.lastUsedAt?.let(::date), useCount = row.useCount,
        evidenceCount = row.evidenceCount, revision = row.revision, createdAt = date(row.createdAt), updatedAt = date(row.updatedAt),
      )
    }
    val projectByTopic = topicRows.mapNotNull { row ->
      row.projectId?.takeIf { row.scope == "project" && it in projectIds }?.let { row.id to it }
    }.toMap()
    // Fingerprints and excerpts are derived from the canonical text; recompute them for iOS.
    var evidence = dao.memoryEvidence().map { row ->
      val canonical = messageFacts[row.sourceMessageId]?.let { contents.canonical(row.sourceMessageId) }
      val fingerprint = canonical?.let { IosTextRules.memorySourceFingerprint(row.sourceMessageId, it) } ?: row.sourceFingerprint
      PortableMemoryEvidence(
        id = row.id, evidenceKey = canonical?.let { IosTextRules.evidenceKey(row.topicId, row.sourceMessageId, fingerprint) } ?: row.evidenceKey,
        topicID = row.topicId, conversationID = row.conversationId, sourceMessageID = row.sourceMessageId,
        assistantMessageID = row.assistantMessageId, excerpt = canonical?.let(IosTextRules::evidenceExcerpt) ?: row.excerpt,
        sourceFingerprint = fingerprint, providerConfigurationID = row.providerConfigurationId, providerKindRawValue = row.providerKind,
        providerDisplayName = row.providerDisplayName, modelIdentifier = row.modelIdentifier, providerEndpoint = row.providerEndpoint,
        confidence = row.confidence, createdAt = date(row.createdAt),
      )
    }
    var revisions = dao.memoryRevisions().map { row ->
      PortableMemoryRevision(
        id = row.id, revisionKey = row.revisionKey, topicID = row.topicId, sequence = row.sequence, kindRawValue = row.kind,
        previousTitle = row.previousTitle, previousContent = row.previousContent, title = row.title, content = row.content,
        sourceEvidenceID = row.sourceEvidenceId, createdAt = date(row.createdAt),
      )
    }
    val recomputedJobKeys = HashMap<String, String>()
    var jobs = dao.memoryJobs().map { row ->
      val canonical = messageFacts[row.throughUserMessageId]?.let { contents.canonical(row.throughUserMessageId) }
      val fingerprint = canonical?.let { IosTextRules.memorySourceFingerprint(row.throughUserMessageId, it) } ?: row.sourceFingerprint
      val key = canonical?.let { IosTextRules.formationJobKey(row.promptVersion, row.conversationId, row.throughUserMessageId, fingerprint) }
        ?: row.jobKey
      recomputedJobKeys[row.id] = key
      PortableMemoryFormationJob(
        id = row.id, jobKey = key, conversationID = row.conversationId, throughUserMessageID = row.throughUserMessageId,
        assistantMessageID = row.assistantMessageId, sourceFingerprint = fingerprint, promptVersion = row.promptVersion,
        statusRawValue = row.status, attemptCount = row.attemptCount, providerConfigurationID = row.providerConfigurationId,
        providerKindRawValue = row.providerKind, providerDisplayName = row.providerDisplayName, modelIdentifier = row.modelIdentifier,
        providerEndpoint = row.providerEndpoint, outputFingerprint = row.outputFingerprint, lastError = row.lastError,
        startedAt = row.startedAt?.let(::date), completedAt = row.completedAt?.let(::date), createdAt = date(row.createdAt),
        updatedAt = date(row.updatedAt),
      )
    }
    var audits = dao.memoryAudits().map { row ->
      PortableMemoryFormationAudit(
        id = row.id, jobID = row.jobId, jobKey = recomputedJobKeys[row.jobId] ?: row.jobKey, attemptCount = row.attemptCount,
        outcomeRawValue = row.outcome, providerConfigurationID = row.providerConfigurationId, providerKindRawValue = row.providerKind,
        providerDisplayName = row.providerDisplayName, modelIdentifier = row.modelIdentifier, providerEndpoint = row.providerEndpoint,
        providerMessageID = row.providerMessageId, requestStarted = row.requestStarted, inputTokenCount = row.inputTokenCount,
        outputTokenCount = row.outputTokenCount, providerRequestCount = row.providerRequestCount,
        cumulativeInputTokenCount = row.cumulativeInputTokenCount, cumulativeOutputTokenCount = row.cumulativeOutputTokenCount,
        didDiscardInvalidTelemetry = row.didDiscardInvalidTelemetry, errorDescription = row.errorDescription,
        startedAt = row.startedAt?.let(::date), finishedAt = date(row.finishedAt), createdAt = date(row.createdAt),
        updatedAt = date(row.updatedAt),
      )
    }

    // Message facts for the rules: canonical content is loaded only for referenced messages.
    val referenced = HashMap<String, MemoryGraphRules.MessageFacts?>()
    for (id in evidence.flatMap { listOfNotNull(it.sourceMessageID, it.assistantMessageID) } +
      jobs.flatMap { listOf(it.throughUserMessageID, it.assistantMessageID) }) {
      if (id in referenced) continue
      referenced[id] = messageFacts[id]?.let { fact ->
        MemoryGraphRules.MessageFacts(
          fact.id, fact.conversationId, fact.role, PortableMapping.messageStatusToPortable(fact.status),
          if (fact.role == "user") contents.canonical(fact.id) else "", PortableDate.fromMillis(fact.createdAt),
        )
      }
    }
    val droppedTopics = HashSet<String>()
    var droppedJobs = 0
    fun input() = MemoryGraphRules.Input(
      topics, evidence, revisions, jobs, audits, conversationIds, { referenced[it] }, projectByConversation,
      topics.mapTo(HashSet()) { it.id }.let { kept -> projectByTopic.filterKeys { it in kept } },
    )
    for (pass in 0 until MAXIMUM_REPAIR_PASSES) {
      val problems = MemoryGraphRules.problems(input())
      if (problems.isEmpty()) break
      val topicIds = problems.mapNotNullTo(HashSet()) { it.topicId }
      val jobIds = problems.mapNotNullTo(HashSet()) { it.jobId }
      val auditIds = problems.mapNotNullTo(HashSet()) { it.auditId }
      droppedTopics += topicIds
      droppedJobs += jobIds.size
      topics = topics.filter { it.id !in topicIds }
      evidence = evidence.filter { it.topicID !in topicIds }
      revisions = revisions.filter { it.topicID !in topicIds }
      jobs = jobs.filter { it.id !in jobIds }
      audits = audits.filter { it.id !in auditIds && it.jobID !in jobIds }
    }
    if (MemoryGraphRules.problems(input()).isNotEmpty()) {
      // Fail safe: never write a memory graph iOS would reject as a whole.
      droppedTopics += topics.map { it.id }
      topics = emptyList(); evidence = emptyList(); revisions = emptyList(); jobs = emptyList(); audits = emptyList()
    }
    if (droppedTopics.isNotEmpty()) {
      notes += plural(droppedTopics.size, "learned topic was", "learned topics were") +
        " left out because their sources no longer match (they can be learned again)."
    }
    if (droppedJobs > 0) notes += plural(droppedJobs, "memory-formation record was", "memory-formation records were") + " left out."
    val keptTopics = topics.mapTo(HashSet()) { it.id }
    return MemoryExport(topics, evidence, revisions, jobs, audits, projectByTopic.filterKeys { it in keptTopics })
  }

  // endregion

  // region compaction

  private suspend fun compaction(
    conversationIds: Set<String>,
    messageFacts: Map<String, MessageFactRow>,
    contents: CanonicalContents,
    notes: MutableList<String>,
  ): Pair<List<PortableCompactionArtifact>, List<PortableCompactionHead>> {
    val rows = dao.compactionArtifacts()
    if (rows.isEmpty()) return emptyList<PortableCompactionArtifact>() to emptyList()
    val canonical = HashMap<String, List<PortableMessage>>()
    for (conversationId in rows.mapTo(HashSet()) { it.conversationId }) {
      coroutineContext.ensureActive()
      canonical[conversationId] = dao.canonicalMessages(conversationId).map { row ->
        PortableMessage(
          id = row.id, conversationID = row.conversationId, roleRawValue = row.role,
          content = if (row.role == "user") contents.canonical(row.id, row.content) else row.content, statusRawValue = "complete",
          providerConfigurationID = null, providerKindRawValue = null, providerDisplayName = null, providerHost = null,
          providerMessageID = null, modelIdentifier = null, inputTokenCount = null, outputTokenCount = null,
          errorDescription = null, contextReceiptData = null, createdAt = PortableDate.fromMillis(row.createdAt),
          updatedAt = PortableDate.fromMillis(row.createdAt),
        )
      }.sortedWith(PortableBackupValidator.CANONICAL_ORDER)
    }
    var artifacts = rows.mapNotNull { row -> portableArtifact(row, canonical[row.conversationId].orEmpty()) }
    val maximumCounter = minOf(limits.maximumTotalBytes, 1_000_000_000L)
    for (pass in 0 until MAXIMUM_REPAIR_PASSES) {
      val problems = CompactionRules.problems(artifacts, canonical, conversationIds, maximumCounter)
      if (problems.isEmpty()) break
      val dropped = problems.mapTo(HashSet()) { it.first }
      // A summary whose coverage parent is gone can no longer be resolved either.
      var changed = true
      while (changed) {
        changed = false
        for (artifact in artifacts) {
          val parent = artifact.coverageParentArtifactID
          if (artifact.id !in dropped && parent != null && parent in dropped) {
            dropped += artifact.id
            changed = true
          }
        }
      }
      artifacts = artifacts.filter { it.id !in dropped }
    }
    if (CompactionRules.problems(artifacts, canonical, conversationIds, maximumCounter).isNotEmpty()) artifacts = emptyList()
    val kept = artifacts.associateBy { it.id }
    val heads = dao.compactionHeads().mapNotNull { head ->
      val active = head.activeArtifactId?.let(kept::get) ?: return@mapNotNull null
      PortableCompactionHead(head.conversationId, active.id, head.revision.coerceAtLeast(0), PortableDate.fromMillis(head.updatedAt))
    }
    val omitted = rows.size - artifacts.size
    if (omitted > 0) {
      notes += plural(omitted, "history summary was", "history summaries were") + " left out; they are recreated when needed."
    }
    return artifacts to heads
  }

  private fun portableArtifact(row: CompactionArtifactEntity, canonical: List<PortableMessage>): PortableCompactionArtifact? {
    val delta = runCatching {
      (PortableJsonReader.parse(row.coverageDeltaJson.toByteArray()) as PJArray).items
        .map { PJString(PortableIds.toPortable((it as PJString).value)) }
    }.getOrNull() ?: return null
    val content = CompactionRules.decodeContent(row.contentJson.toByteArray()) ?: return null
    val fingerprinter = IosTextRules.CompactionFingerprinter()
    if (row.coveredMessageCount !in 1..canonical.size) return null
    canonical.take(row.coveredMessageCount).forEach { fingerprinter.add(it.id, it.roleRawValue, it.content) }
    val unsigned = PortableCompactionArtifact(
      id = row.id, conversationID = row.conversationId, lineagePreviousCompactionID = row.lineagePreviousCompactionId,
      coverageParentArtifactID = row.coverageParentArtifactId,
      coverageDeltaData = SwiftJsonWriter.encode(PJArray(delta), withoutEscapingSlashes = false),
      coveredMessageCount = row.coveredMessageCount, modeRawValue = row.mode, promptVersion = row.promptVersion,
      contentSchemaVersion = row.contentSchemaVersion, contentData = row.contentJson.toByteArray(Charsets.UTF_8),
      renderedSummary = IosTextRules.renderedSummary(content.overview, content.items) ?: return null,
      sourceFingerprint = fingerprinter.current(), providerConfigurationID = row.providerId,
      providerKindRawValue = PortableMapping.validProviderKind(row.providerKind), providerDisplayName = row.providerName,
      providerEndpoint = row.providerEndpoint, modelIdentifier = row.modelId, providerMessageID = row.responseId,
      inputTokenCount = row.inputTokens, outputTokenCount = row.outputTokens, estimatedSourceTokens = row.estimatedSourceTokens,
      estimatedSummaryTokens = row.estimatedSummaryTokens, chainDepth = row.chainDepth,
      warningsData = (CompactionRules.decodeStringList(row.warningsJson.toByteArray()) ?: emptyList())
        .let { SwiftJsonWriter.encode(PJArray(it.map(::PJString)), withoutEscapingSlashes = false) },
      isSnapshotComplete = true,
      isDetachedCoverageRoot = row.coverageParentArtifactId == null && row.lineagePreviousCompactionId != null,
      payloadFingerprint = "", createdAt = PortableDate.fromMillis(row.createdAt),
    )
    return PortableCompactionArtifact(
      unsigned.id, unsigned.conversationID, unsigned.lineagePreviousCompactionID, unsigned.coverageParentArtifactID,
      unsigned.coverageDeltaData, unsigned.coveredMessageCount, unsigned.modeRawValue, unsigned.promptVersion,
      unsigned.contentSchemaVersion, unsigned.contentData, unsigned.renderedSummary, unsigned.sourceFingerprint,
      unsigned.providerConfigurationID, unsigned.providerKindRawValue, unsigned.providerDisplayName, unsigned.providerEndpoint,
      unsigned.modelIdentifier, unsigned.providerMessageID, unsigned.inputTokenCount, unsigned.outputTokenCount,
      unsigned.estimatedSourceTokens, unsigned.estimatedSummaryTokens, unsigned.chainDepth, unsigned.warningsData,
      unsigned.isSnapshotComplete, unsigned.isDetachedCoverageRoot, unsigned.computedFingerprint(), unsigned.createdAt,
    )
  }

  // endregion

  companion object {
    private const val FACT_PAGE = 512
    private const val CONVERSATION_PAGE = 32
    private const val MESSAGE_PAGE = 16
    private const val CHUNK_PAGE = 32
    private const val USAGE_PAGE = 256
    private const val PROGRESS_STEP = 64L
    private const val MAXIMUM_REPAIR_PASSES = 8

    fun plural(count: Int, singular: String, plural: String) = "$count ${if (count == 1) singular else plural}"
  }
}

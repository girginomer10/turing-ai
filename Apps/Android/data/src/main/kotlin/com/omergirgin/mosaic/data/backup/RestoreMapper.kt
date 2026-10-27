package com.omergirgin.mosaic.data.backup

import com.omergirgin.mosaic.core.backup.CompactionRules
import com.omergirgin.mosaic.core.backup.IosTextRules
import com.omergirgin.mosaic.core.backup.PortableBackupValidator
import com.omergirgin.mosaic.core.backup.PortableCompactionArtifact
import com.omergirgin.mosaic.core.backup.PortableExperienceValue
import com.omergirgin.mosaic.core.backup.PortableIds
import com.omergirgin.mosaic.core.backup.PortableMessage
import com.omergirgin.mosaic.core.backup.PortableSnapshot
import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.chat.WebSource
import com.omergirgin.mosaic.core.context.AttachmentText
import com.omergirgin.mosaic.core.context.ContextCandidate
import com.omergirgin.mosaic.core.context.PromptLayers
import com.omergirgin.mosaic.core.context.compaction.CompactionContent
import com.omergirgin.mosaic.core.context.compaction.CompactionItem
import com.omergirgin.mosaic.core.context.compaction.CompactionItemKind
import com.omergirgin.mosaic.core.context.compaction.ConversationCompactionPlanner
import com.omergirgin.mosaic.core.memory.AutomaticMemoryRules
import com.omergirgin.mosaic.core.provider.BundledModelCatalog
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.data.db.AttachmentEntity
import com.omergirgin.mosaic.data.db.Codecs
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
import com.omergirgin.mosaic.data.db.ProjectEntity
import com.omergirgin.mosaic.data.db.ProviderEntity
import com.omergirgin.mosaic.data.db.ProviderModelEntity
import com.omergirgin.mosaic.data.db.ScheduledTaskEntity
import com.omergirgin.mosaic.data.db.UsageRecordEntity
import com.omergirgin.mosaic.data.branching.ConversationBranchEntity
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfileEntity
import com.omergirgin.mosaic.data.pricing.ModelPriceOverrideEntity
import java.io.File
import java.net.URI
import java.security.MessageDigest
import java.time.ZoneId
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/**
 * iOS snapshot → Android rows (the iOS `transformForRestore` plus platform conversion):
 * - providers get fresh local IDs, stay disabled and have no keys; operational references
 *   (chat/project/task/profile model choices, formation jobs) follow the new IDs, while message,
 *   evidence, audit and summary provider IDs stay as immutable provenance;
 * - automations are paused; project bindings become `projectId` columns;
 * - attachment sidecars become attachment rows and the iOS attachment markers are removed from the
 *   user text (fingerprints derived from that text are recomputed);
 * - transcripts keep the iOS canonical order after rounding timestamps to milliseconds;
 * - the usage ledger is rebuilt from messages, formation audits, summaries and extra usage.
 * Everything Android cannot represent is counted in [notes].
 */
internal class RestoreMapper(private val snapshot: PortableSnapshot, private val stagingDir: File) {
  val notes = ArrayList<String>()

  private val extensions = snapshot.extensions
  private val conversationIds = snapshot.conversations.mapTo(HashSet()) { it.id }
  private val memberships = projectMemberships()
  private val providerIdMap = rekeyProviders()

  fun map(): RestorePlan {
    val providers = snapshot.providerConfigurations.map { item ->
      ProviderEntity(
        id = providerIdMap.getValue(item.id), kind = item.providerRawValue, displayName = item.displayName,
        baseUrl = item.baseURLString?.takeIf { it.isNotBlank() }, isEnabled = false,
        createdAt = item.createdAt.epochMillis, updatedAt = item.updatedAt.epochMillis,
      )
    }
    val messages = mapMessages()
    val messagesById = messages.associateBy { it.message.id }
    val attachments = mapAttachments(messagesById)
    val strippedMessages = messages.filter { it.strippedContent != null }.associate { it.message.id to it.message.content }
    val (topics, evidence, revisions, jobs, audits) = mapMemory(messagesById, strippedMessages)
    val (artifacts, heads) = mapCompaction(messagesById, attachments)
    val tasks = mapTasks()
    val plan = RestorePlan(
      providers = providers,
      providerModels = mapProviderModels(),
      projects = mapProjects(),
      conversations = mapConversations(),
      messages = messages.map { it.message },
      attachments = attachments,
      facts = mapFacts(),
      usage = mapUsage(messagesById),
      documents = snapshot.importedDocuments.map { item ->
        DocumentEntity(
          id = item.id, title = item.title, sourceFilename = item.sourceFilename, mimeType = item.mimeType,
          contentFingerprint = item.contentFingerprint, characterCount = item.characterCount, pageCount = item.pageCount,
          ocrPageCount = item.ocrPageCount, ocrFallbackPageCount = item.ocrFallbackPageCount, isEnabled = item.isEnabled,
          projectId = memberships.projectByDocument[item.id], createdAt = item.createdAt.epochMillis,
          updatedAt = item.updatedAt.epochMillis,
        )
      },
      chunks = mapChunks(),
      artifacts = artifacts,
      heads = heads,
      tasks = tasks,
      profiles = mapProfiles(),
      topics = topics,
      evidence = evidence,
      revisions = revisions,
      jobs = jobs,
      audits = audits,
      priceOverrides = mapPriceOverrides(),
      branches = mapBranches(),
      stagingDir = stagingDir,
    )
    collectSkippedNotes()
    return plan
  }

  fun contents(plan: RestorePlan) = BackupContents(
    conversations = plan.conversations.size, messages = plan.messages.size, attachments = plan.attachments.size,
    pinnedMemories = plan.facts.size, learnedTopics = plan.topics.size, documents = plan.documents.size,
    projects = plan.projects.size, providers = plan.providers.size, automations = plan.tasks.size,
    embeddingProfiles = plan.profiles.size,
  )

  // region identity

  private fun projectMemberships(): PortableBackupValidator.Memberships {
    val byKind = extensions.bindings.groupBy { it.resourceKindRawValue }
    fun map(kind: String) = byKind[kind].orEmpty().associate { it.resourceID to it.projectID }
    return PortableBackupValidator.Memberships(map("conversation"), map("memory_topic"), map("memory"), map("document"))
  }

  /** iOS `transformForRestore`: a fresh ID per provider, never reusing any ID from the file. */
  private fun rekeyProviders(): Map<String, String> {
    val original = snapshot.providerConfigurations.mapTo(HashSet()) { it.id }
    val used = HashSet<String>()
    val result = HashMap<String, String>()
    for (old in original.sortedBy { PortableIds.toPortable(it) }) {
      var candidate = PortableIds.random()
      while (candidate in original || !used.add(candidate)) candidate = PortableIds.random()
      result[old] = candidate
    }
    return result
  }

  private val providersById = snapshot.providerConfigurations.associateBy { it.id }

  private fun mapProvider(id: String?): String? = id?.let(providerIdMap::get)

  // endregion

  // region providers and models

  private fun mapProviderModels(): List<ProviderModelEntity> {
    val imageOverrides = extensions.experience.filter { it.kind == PortableExperienceValue.MODEL && it.supportsImages != null }
      .associate { (it.providerID to it.model) to it.supportsImages }
    val catalogs = extensions.providerModels.groupBy { it.providerID }
    val rows = ArrayList<ProviderModelEntity>()
    for (provider in snapshot.providerConfigurations) {
      val newId = providerIdMap.getValue(provider.id)
      val suggested = ProviderKind.fromRawId(provider.providerRawValue)?.let { BundledModelCatalog.models(it).toSet() }.orEmpty()
      val catalog = catalogs[provider.id]
      if (catalog != null) {
        for (model in catalog.distinctBy { it.modelIdentifier }) {
          rows += ProviderModelEntity(
            providerId = newId, modelId = model.modelIdentifier, isEnabled = model.enabled == true,
            contextWindowTokens = model.contextWindow, maximumOutputTokens = model.maximumOutput,
            supportsImages = imageOverrides[provider.id to model.modelIdentifier], isCustom = model.modelIdentifier !in suggested,
            isDiscovered = false,
          )
        }
      } else {
        // A legacy connection exposes exactly its old default model until a catalog exists.
        val model = provider.modelIdentifier
        if (model.isNotEmpty() && model == IosTextRules.trim(model) && PortableMapping.utf8(model) <= 2_048 && '\n' !in model) {
          rows += ProviderModelEntity(
            providerId = newId, modelId = model, isEnabled = true, contextWindowTokens = provider.contextWindowTokens,
            maximumOutputTokens = provider.maximumOutputTokens, supportsImages = imageOverrides[provider.id to model],
            isCustom = model !in suggested, isDiscovered = false,
          )
        }
      }
    }
    return rows
  }

  /** iOS per-model price fields (experience `model` values) → Android custom rates. */
  private fun mapPriceOverrides(): List<ModelPriceOverrideEntity> =
    extensions.experience.filter { it.kind == PortableExperienceValue.MODEL }.mapNotNull { value ->
      val input = value.inputPricePerMillion ?: return@mapNotNull null
      val output = value.outputPricePerMillion ?: return@mapNotNull null
      val providerId = mapProvider(value.providerID) ?: return@mapNotNull null
      ModelPriceOverrideEntity(providerId, value.model ?: return@mapNotNull null, input, output, value.updatedAt.epochMillis)
    }.distinctBy { it.providerId to it.modelId }

  /** iOS `branch` values → Android alternative-group links (one per conversation). */
  private fun mapBranches(): List<ConversationBranchEntity> =
    extensions.experience.filter { it.kind == PortableExperienceValue.BRANCH && it.conversationID in conversationIds }
      .sortedByDescending { it.updatedAt }
      .distinctBy { it.conversationID }
      .map { value ->
        ConversationBranchEntity(
          id = value.id, conversationId = value.conversationID!!, branchGroupId = value.branchGroupID!!,
          originalConversationId = value.originalConversationID, updatedAt = value.updatedAt.epochMillis,
        )
      }

  private fun mapProfiles(): List<EmbeddingProfileEntity> {
    var enabledSlots = MAXIMUM_ENABLED_PROFILES
    return snapshot.embeddingProfiles.sortedByDescending { it.updatedAt }.map { item ->
      val providerId = mapProvider(item.providerConfigurationID)
      // Android enables at most four profiles; an orphaned provider profile stays disabled (iOS).
      val enabled = item.isEnabled && providerId != null && enabledSlots > 0
      if (enabled) enabledSlots--
      EmbeddingProfileEntity(
        id = item.id, displayName = item.displayName, providerId = providerId, modelId = item.modelIdentifier,
        weight = item.weight, isEnabled = enabled, indexesConversations = item.indexesConversations,
        indexesDocuments = item.indexesDocuments, createdAt = item.createdAt.epochMillis, updatedAt = item.updatedAt.epochMillis,
      )
    }
  }

  // endregion

  // region library

  private fun mapProjects(): List<ProjectEntity> {
    val defaults = extensions.experience.filter { it.kind == PortableExperienceValue.PROJECT_DEFAULT && it.projectID != null }
      .associateBy { it.projectID }
    return extensions.projects.map { item ->
      val default = defaults[item.id]
      val providerId = mapProvider(default?.providerID)
      ProjectEntity(
        id = item.id, name = item.name, instructions = item.instructions, isArchived = item.isArchived,
        defaultProviderId = providerId, defaultModelId = default?.model?.takeIf { providerId != null },
        createdAt = item.createdAt.epochMillis, updatedAt = item.updatedAt.epochMillis,
      )
    }
  }

  private fun mapConversations(): List<ConversationEntity> = snapshot.conversations.map { item ->
    val providerId = mapProvider(item.providerConfigurationID)?.takeIf { item.modelIdentifier.isNotEmpty() }
    ConversationEntity(
      id = item.id, title = item.title, projectId = memberships.projectByConversation[item.id], systemPrompt = item.systemPrompt,
      modelProviderId = providerId, modelId = item.modelIdentifier.takeIf { providerId != null }, draft = item.draftText,
      isArchived = item.isArchived, webSearchEnabled = false, createdAt = item.createdAt.epochMillis,
      updatedAt = item.updatedAt.epochMillis,
    )
  }

  private class MappedMessage(val message: MessageEntity, val source: PortableMessage, val strippedContent: String?)

  private val attachmentValues = extensions.experience.filter { it.kind == PortableExperienceValue.ATTACHMENT }
  private val attachmentsByMessage = attachmentValues.filter { it.messageID != null }.groupBy { it.messageID!! }

  private fun mapMessages(): List<MappedMessage> {
    val citations = extensions.experience.filter { it.kind == PortableExperienceValue.WEB_SOURCES && it.messageID != null }
      .associateBy { it.messageID!! }
    val result = ArrayList<MappedMessage>(snapshot.messages.size)
    for ((_, list) in snapshot.messages.groupBy { it.conversationID }) {
      // Keep the exact iOS canonical order after rounding to milliseconds: Android orders a
      // transcript by (createdAt, id), so ties are broken by nudging later rows forward.
      var previous = Long.MIN_VALUE
      for (item in list.sortedWith(PortableBackupValidator.CANONICAL_ORDER)) {
        val createdAt = maxOf(item.createdAt.epochMillis, if (previous == Long.MIN_VALUE) Long.MIN_VALUE else previous + 1)
        previous = createdAt
        if (item.roleRawValue == "tool") continue
        val stripped = if (item.id in attachmentsByMessage) IosTextRules.displayText(item.content) else null
        val status = PortableMapping.messageStatusFromPortable(item.statusRawValue)
        val error = item.errorDescription
          ?: if (status == "FAILED" && item.statusRawValue != "failed") "This response was interrupted before it finished." else null
        val sources = citations[item.id]?.sources.orEmpty().map { WebSource(it.title, it.url) }
        result += MappedMessage(
          MessageEntity(
            id = item.id, conversationId = item.conversationID, role = item.roleRawValue, content = stripped ?: item.content,
            status = status, errorMessage = error, providerId = item.providerConfigurationID,
            providerKind = item.providerKindRawValue, providerName = item.providerDisplayName, modelId = item.modelIdentifier,
            destinationHost = item.providerHost, inputTokens = item.inputTokenCount, outputTokens = item.outputTokenCount,
            responseId = item.providerMessageID, retryOfMessageId = null, citationsJson = Codecs.encodeCitations(sources),
            createdAt = createdAt, updatedAt = maxOf(createdAt, item.updatedAt.epochMillis),
          ),
          item,
          stripped,
        )
      }
    }
    return result
  }

  private fun mapAttachments(messages: Map<String, MappedMessage>): List<StagedAttachment> {
    val rows = ArrayList<StagedAttachment>()
    for ((messageId, values) in attachmentsByMessage) {
      val message = messages[messageId]?.message ?: continue
      values.sortedWith(compareBy<PortableExperienceValue>({ it.updatedAt }, { PortableIds.toPortable(it.id) }))
        .forEachIndexed { index, value ->
          val image = value.isImage
          val mime = value.mimeType.orEmpty()
          rows += StagedAttachment(
            AttachmentEntity(
              id = value.id, messageId = messageId, conversationId = message.conversationId,
              kind = when {
                image -> "IMAGE"
                mime == "application/pdf" -> "PDF"
                else -> "TEXT"
              },
              fileName = value.filename.orEmpty().take(200), mimeType = mime, extractedText = value.extractedText.takeIf { !image },
              imageBase64 = null, position = index, createdAt = message.createdAt,
            ),
            value.bytes.takeIf { image },
          )
        }
    }
    return rows
  }

  private fun mapFacts(): List<MemoryFactEntity> = snapshot.memories.map { item ->
    val orphan = item.scopeRawValue == "conversation" && item.conversationID?.let { it in conversationIds } != true
    MemoryFactEntity(
      id = item.id, title = item.title, content = item.content, scope = PortableMapping.factScopeFromPortable(item.scopeRawValue),
      projectId = if (item.scopeRawValue == "project") memberships.projectByMemory[item.id] else null,
      conversationId = if (item.scopeRawValue == "conversation" && !orphan) item.conversationID else null,
      // iOS uses a memory only when enabled and approved; an orphaned chat memory is disabled.
      isEnabled = item.isEnabled && item.isUserApproved && !orphan,
      createdAt = item.createdAt.epochMillis, updatedAt = item.updatedAt.epochMillis,
    )
  }

  private fun mapChunks(): List<DocumentChunkEntity> {
    val result = ArrayList<DocumentChunkEntity>(snapshot.documentChunks.size)
    for ((_, chunks) in snapshot.documentChunks.groupBy { it.documentID }) {
      // Android requires a unique (document, index); renumber only if the file repeats an index.
      val unique = chunks.map { it.chunkIndex }.toSet().size == chunks.size
      chunks.sortedWith(compareBy({ it.chunkIndex }, { PortableIds.toPortable(it.id) })).forEachIndexed { position, item ->
        result += DocumentChunkEntity(
          id = item.id, documentId = item.documentID, chunkIndex = if (unique) item.chunkIndex else position,
          content = item.content, pageNumber = item.pageNumber, isOcrDerived = item.isOCRDerived, createdAt = item.createdAt.epochMillis,
        )
      }
    }
    return result
  }

  private fun mapTasks(): List<ScheduledTaskEntity> {
    val selections = extensions.taskModels.associateBy { it.id }
    var invalidZones = 0
    val tasks = snapshot.scheduledTasks.map { item ->
      val selection = selections[item.id]
      // A selection may name a provider that is gone; it then surfaces as a run error, never a switch.
      val providerId = selection?.let { providerIdMap[it.providerID] ?: it.providerID } ?: mapProvider(item.providerConfigurationID)
      val modelId = selection?.modelIdentifier
        ?: item.providerConfigurationID?.let(providersById::get)?.modelIdentifier?.takeIf { it.isNotEmpty() && providerId != null }
      val zone = item.timeZoneIdentifier.takeIf { runCatching { ZoneId.of(it) }.isSuccess }
        ?: ZoneId.systemDefault().id.also { invalidZones++ }
      ScheduledTaskEntity(
        id = item.id, title = item.title, prompt = item.prompt, recurrence = item.recurrenceRawValue,
        // Restored automations never run before the person reviews them.
        status = "paused", scheduledAt = item.scheduledAt.epochMillis, weekdayMask = 0, timeZoneId = zone,
        providerId = providerId?.takeIf { modelId != null }, modelId = modelId?.takeIf { providerId != null }, projectId = null,
        nextRunAt = item.nextRunAt?.epochMillis, lastRunAt = item.lastRunAt?.epochMillis, lastError = item.lastError,
        lastConversationId = item.conversationID?.takeIf { it in conversationIds },
        createdAt = item.createdAt.epochMillis, updatedAt = item.updatedAt.epochMillis,
      )
    }
    if (invalidZones > 0) notes += "${count(invalidZones, "automation uses", "automations use")} this device's time zone because the saved one is unknown here."
    return tasks
  }

  // endregion

  // region automatic memory

  private data class MemoryRows(
    val topics: List<MemoryTopicEntity>,
    val evidence: List<MemoryEvidenceEntity>,
    val revisions: List<MemoryRevisionEntity>,
    val jobs: List<MemoryFormationJobEntity>,
    val audits: List<MemoryFormationAuditEntity>,
  )

  private fun mapMemory(messages: Map<String, MappedMessage>, stripped: Map<String, String>): MemoryRows {
    val topics = extensions.topics.map { item ->
      MemoryTopicEntity(
        id = item.id, canonicalKey = item.canonicalKey, title = item.title, content = item.content, kind = item.kindRawValue,
        scope = item.scopeRawValue, conversationId = item.conversationID, projectId = memberships.projectByTopic[item.id],
        status = item.statusRawValue, origin = item.originRawValue, confidence = item.confidence, importance = item.importance,
        stability = item.stabilityRawValue, isEnabled = item.isEnabled, lastConfirmedAt = item.lastConfirmedAt.epochMillis,
        lastUsedAt = item.lastUsedAt?.epochMillis, useCount = item.useCount, evidenceCount = item.evidenceCount,
        revision = item.revision, createdAt = item.createdAt.epochMillis, updatedAt = item.updatedAt.epochMillis,
      )
    }
    // Evidence of a message whose attachment markers were removed is re-derived from the Android text.
    fun fingerprint(messageId: String, fallback: String) =
      stripped[messageId]?.let { IosTextRules.memorySourceFingerprint(messageId, it) } ?: fallback
    val evidence = extensions.evidence.map { item ->
      val sourceFingerprint = fingerprint(item.sourceMessageID, item.sourceFingerprint)
      MemoryEvidenceEntity(
        id = item.id,
        evidenceKey = if (item.sourceMessageID in stripped) IosTextRules.evidenceKey(item.topicID, item.sourceMessageID, sourceFingerprint) else item.evidenceKey,
        topicId = item.topicID, conversationId = item.conversationID, sourceMessageId = item.sourceMessageID,
        assistantMessageId = item.assistantMessageID,
        excerpt = stripped[item.sourceMessageID]?.let(AutomaticMemoryRules::boundedExcerpt)?.ifBlank { null } ?: item.excerpt,
        sourceFingerprint = sourceFingerprint, providerConfigurationId = item.providerConfigurationID,
        providerKind = item.providerKindRawValue, providerDisplayName = item.providerDisplayName, modelIdentifier = item.modelIdentifier,
        providerEndpoint = item.providerEndpoint, confidence = item.confidence, createdAt = item.createdAt.epochMillis,
      )
    }
    val revisions = extensions.revisions.map { item ->
      MemoryRevisionEntity(
        id = item.id, revisionKey = item.revisionKey, topicId = item.topicID, sequence = item.sequence, kind = item.kindRawValue,
        previousTitle = item.previousTitle, previousContent = item.previousContent, title = item.title, content = item.content,
        sourceEvidenceId = item.sourceEvidenceID, createdAt = item.createdAt.epochMillis,
      )
    }
    val jobKeys = HashMap<String, String>()
    val jobs = extensions.jobs.map { item ->
      val sourceFingerprint = fingerprint(item.throughUserMessageID, item.sourceFingerprint)
      val jobKey = if (item.throughUserMessageID in stripped) {
        IosTextRules.formationJobKey(item.promptVersion, item.conversationID, item.throughUserMessageID, sourceFingerprint)
      } else {
        item.jobKey
      }
      jobKeys[item.id] = jobKey
      MemoryFormationJobEntity(
        id = item.id, jobKey = jobKey, conversationId = item.conversationID, throughUserMessageId = item.throughUserMessageID,
        assistantMessageId = item.assistantMessageID, sourceFingerprint = sourceFingerprint, promptVersion = item.promptVersion,
        status = item.statusRawValue, attemptCount = item.attemptCount,
        // Formation-job provider IDs are operational locators and follow the rekeying (iOS).
        providerConfigurationId = mapProvider(item.providerConfigurationID), providerKind = item.providerKindRawValue,
        providerDisplayName = item.providerDisplayName, modelIdentifier = item.modelIdentifier, providerEndpoint = item.providerEndpoint,
        outputFingerprint = item.outputFingerprint, lastError = item.lastError, startedAt = item.startedAt?.epochMillis,
        completedAt = item.completedAt?.epochMillis, createdAt = item.createdAt.epochMillis, updatedAt = item.updatedAt.epochMillis,
      )
    }
    val audits = extensions.audits.map { item ->
      MemoryFormationAuditEntity(
        id = item.id, jobId = item.jobID, jobKey = jobKeys[item.jobID] ?: item.jobKey, attemptCount = item.attemptCount,
        outcome = item.outcomeRawValue, providerConfigurationId = item.providerConfigurationID, providerKind = item.providerKindRawValue,
        providerDisplayName = item.providerDisplayName, modelIdentifier = item.modelIdentifier, providerEndpoint = item.providerEndpoint,
        providerMessageId = item.providerMessageID, requestStarted = item.requestStarted, inputTokenCount = item.inputTokenCount,
        outputTokenCount = item.outputTokenCount, providerRequestCount = item.providerRequestCount,
        cumulativeInputTokenCount = item.cumulativeInputTokenCount, cumulativeOutputTokenCount = item.cumulativeOutputTokenCount,
        didDiscardInvalidTelemetry = item.didDiscardInvalidTelemetry, errorDescription = item.errorDescription,
        startedAt = item.startedAt?.epochMillis, finishedAt = item.finishedAt.epochMillis, createdAt = item.createdAt.epochMillis,
        updatedAt = item.updatedAt.epochMillis,
      )
    }
    return MemoryRows(topics, evidence, revisions, jobs, audits)
  }

  // endregion

  // region compaction

  @Serializable
  private data class AndroidArtifactIntegrity(
    val id: String,
    val conversationId: String,
    val lineagePreviousCompactionId: String?,
    val coverageParentArtifactId: String?,
    val coverageDeltaJson: String,
    val coveredMessageCount: Int,
    val mode: String,
    val promptVersion: String,
    val contentSchemaVersion: Int,
    val contentJson: String,
    val renderedSummary: String,
    val sourceFingerprint: String,
    val providerId: String,
    val providerKind: String,
    val providerName: String,
    val providerEndpoint: String,
    val providerHost: String?,
    val modelId: String,
    val responseId: String?,
    val inputTokens: Int?,
    val outputTokens: Int?,
    val estimatedSourceTokens: Int,
    val estimatedSummaryTokens: Int,
    val chainDepth: Int,
    val warningsJson: String,
    val createdAt: Long,
  )

  /**
   * Complete iOS summaries become Android artifacts (same lineage and coverage model). The Android
   * source fingerprint covers the provider-facing text (attachment blocks included), so it is
   * recomputed; the row integrity hash uses Android's own envelope.
   */
  private fun mapCompaction(
    messages: Map<String, MappedMessage>,
    attachments: List<StagedAttachment>,
  ): Pair<List<CompactionArtifactEntity>, List<CompactionHeadEntity>> {
    if (snapshot.compactionArtifacts.isEmpty()) return emptyList<CompactionArtifactEntity>() to emptyList()
    val attachmentTexts = attachments.filter { it.image == null }.groupBy { it.entity.messageId }
    val imageCounts = attachments.filter { it.image != null }.groupingBy { it.entity.messageId }.eachCount()
    val candidates = messages.values.asSequence()
      .filter { it.message.status == "COMPLETE" && (it.message.role == "user" || it.message.role == "assistant") }
      .groupBy { it.message.conversationId }
      .mapValues { (_, list) ->
        list.sortedWith(compareBy({ it.message.createdAt }, { it.message.id })).map { mapped ->
          val texts = attachmentTexts[mapped.message.id].orEmpty().sortedBy { it.entity.position }.mapNotNull { staged ->
            staged.entity.extractedText?.takeIf { it.isNotBlank() }?.let { AttachmentText(staged.entity.fileName, staged.entity.mimeType, it) }
          }
          ContextCandidate(
            id = mapped.message.id,
            role = if (mapped.message.role == "user") ChatRole.USER else ChatRole.ASSISTANT,
            content = PromptLayers.userContent(mapped.message.content, texts),
            imageCount = imageCounts[mapped.message.id] ?: 0,
          )
        }
      }
    val accepted = LinkedHashMap<String, CompactionArtifactEntity>()
    val pending = snapshot.compactionArtifacts.filter { it.isSnapshotComplete }.associateBy { it.id }.toMutableMap()
    // Parents first, so a child is accepted only if its coverage parent was.
    var progressed = true
    while (progressed && pending.isNotEmpty()) {
      progressed = false
      for (artifact in pending.values.toList()) {
        val parent = artifact.coverageParentArtifactID
        if (parent != null && parent !in accepted) {
          if (parent !in pending) pending.remove(artifact.id)
          continue
        }
        pending.remove(artifact.id)
        progressed = true
        convertArtifact(artifact, candidates[artifact.conversationID].orEmpty())?.let { accepted[artifact.id] = it }
      }
    }
    val heads = snapshot.conversationCompactionHeads.mapNotNull { head ->
      val active = head.activeArtifactID?.takeIf { it in accepted } ?: return@mapNotNull null
      CompactionHeadEntity(head.conversationID, active, head.revision, head.updatedAt.epochMillis)
    }
    val skipped = snapshot.compactionArtifacts.size - accepted.size
    if (skipped > 0) notes += "${count(skipped, "history summary is", "history summaries are")} not restored; Turing AI recreates summaries when needed."
    return accepted.values.toList() to heads
  }

  private fun convertArtifact(artifact: PortableCompactionArtifact, candidates: List<ContextCandidate>): CompactionArtifactEntity? {
    val providerId = artifact.providerConfigurationID ?: return null
    val providerKind = artifact.providerKindRawValue ?: return null
    val providerName = artifact.providerDisplayName ?: return null
    val endpoint = artifact.providerEndpoint ?: return null
    val modelId = artifact.modelIdentifier ?: return null
    if (artifact.coveredMessageCount !in 1..candidates.size) return null
    val delta = CompactionRules.decodeUuidList(artifact.coverageDeltaData) ?: return null
    val content = CompactionRules.decodeContent(artifact.contentData ?: return null) ?: return null
    val items = content.items.map { (kind, text) ->
      CompactionItem(CompactionItemKind.entries.firstOrNull { item -> serialName(item) == kind } ?: return null, text)
    }
    val androidContent = CompactionContent(items = items, overview = content.overview, schemaVersion = content.schemaVersion)
    val warnings = CompactionRules.decodeStringList(artifact.warningsData) ?: return null
    val unsigned = CompactionArtifactEntity(
      id = artifact.id, conversationId = artifact.conversationID, lineagePreviousCompactionId = artifact.lineagePreviousCompactionID,
      coverageParentArtifactId = artifact.coverageParentArtifactID,
      coverageDeltaJson = EventJson.encodeToString(StringList, delta), coveredMessageCount = artifact.coveredMessageCount,
      mode = artifact.modeRawValue, promptVersion = artifact.promptVersion, contentSchemaVersion = artifact.contentSchemaVersion,
      contentJson = EventJson.encodeToString(CompactionContent.serializer(), androidContent),
      renderedSummary = androidContent.render(),
      sourceFingerprint = ConversationCompactionPlanner.sourceFingerprint(candidates.subList(0, artifact.coveredMessageCount)),
      providerId = providerId, providerKind = providerKind, providerName = providerName, providerEndpoint = endpoint,
      providerHost = runCatching { URI(endpoint).host }.getOrNull(), modelId = modelId,
      responseId = artifact.providerMessageID, inputTokens = artifact.inputTokenCount, outputTokens = artifact.outputTokenCount,
      estimatedSourceTokens = artifact.estimatedSourceTokens, estimatedSummaryTokens = artifact.estimatedSummaryTokens,
      chainDepth = artifact.chainDepth, warningsJson = EventJson.encodeToString(StringList, warnings), payloadFingerprint = "",
      createdAt = artifact.createdAt.epochMillis,
    )
    return unsigned.copy(payloadFingerprint = integrityFingerprint(unsigned))
  }

  private fun serialName(kind: CompactionItemKind): String =
    CompactionItemKind.serializer().descriptor.getElementName(kind.ordinal)

  /** Same envelope and encoder as `CompactionStore.integrityFingerprint`. */
  private fun integrityFingerprint(artifact: CompactionArtifactEntity): String {
    val envelope = AndroidArtifactIntegrity(
      artifact.id, artifact.conversationId, artifact.lineagePreviousCompactionId, artifact.coverageParentArtifactId,
      artifact.coverageDeltaJson, artifact.coveredMessageCount, artifact.mode, artifact.promptVersion, artifact.contentSchemaVersion,
      artifact.contentJson, artifact.renderedSummary, artifact.sourceFingerprint, artifact.providerId, artifact.providerKind,
      artifact.providerName, artifact.providerEndpoint, artifact.providerHost, artifact.modelId, artifact.responseId,
      artifact.inputTokens, artifact.outputTokens, artifact.estimatedSourceTokens, artifact.estimatedSummaryTokens,
      artifact.chainDepth, artifact.warningsJson, artifact.createdAt,
    )
    val bytes = IntegrityJson.encodeToString(AndroidArtifactIntegrity.serializer(), envelope).toByteArray(Charsets.UTF_8)
    return MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
  }

  // endregion

  // region usage ledger

  private fun mapUsage(messages: Map<String, MappedMessage>): List<UsageRecordEntity> {
    val rows = ArrayList<UsageRecordEntity>()
    fun host(endpoint: String?) = endpoint?.let { runCatching { URI(it).host }.getOrNull() ?: it }?.take(253)
    for (mapped in messages.values) {
      val item = mapped.source
      if (item.roleRawValue != "assistant" || (item.inputTokenCount == null && item.outputTokenCount == null)) continue
      rows += UsageRecordEntity(
        id = PortableIds.deterministicLocal("usage-chat:${item.id}"), providerId = item.providerConfigurationID,
        providerKind = item.providerKindRawValue ?: ProviderKind.CUSTOM.rawId, providerName = item.providerDisplayName ?: "Provider",
        modelId = item.modelIdentifier ?: "Unknown model", destinationHost = item.providerHost, category = "Chat",
        inputTokens = item.inputTokenCount, outputTokens = item.outputTokenCount, conversationId = item.conversationID,
        messageId = item.id, createdAt = mapped.message.createdAt,
      )
    }
    val jobs = extensions.jobs.associateBy { it.id }
    for (audit in extensions.audits) {
      if (audit.providerRequestCount <= 0) continue
      val single = audit.providerRequestCount == 1
      rows += UsageRecordEntity(
        id = PortableIds.deterministicLocal("usage-memory:${audit.id}"), providerId = audit.providerConfigurationID,
        providerKind = audit.providerKindRawValue ?: ProviderKind.CUSTOM.rawId, providerName = audit.providerDisplayName ?: "Provider",
        modelId = audit.modelIdentifier ?: "Unknown model", destinationHost = host(audit.providerEndpoint), category = "Memory",
        inputTokens = if (single) audit.inputTokenCount else audit.cumulativeInputTokenCount,
        outputTokens = if (single) audit.outputTokenCount else audit.cumulativeOutputTokenCount,
        conversationId = jobs[audit.jobID]?.conversationID, messageId = jobs[audit.jobID]?.assistantMessageID,
        createdAt = audit.finishedAt.epochMillis,
      )
    }
    for (artifact in snapshot.compactionArtifacts) {
      if (artifact.inputTokenCount == null && artifact.outputTokenCount == null) continue
      rows += UsageRecordEntity(
        id = PortableIds.deterministicLocal("usage-compaction:${artifact.id}"), providerId = artifact.providerConfigurationID,
        providerKind = artifact.providerKindRawValue ?: ProviderKind.CUSTOM.rawId, providerName = artifact.providerDisplayName ?: "Provider",
        modelId = artifact.modelIdentifier ?: "Unknown model", destinationHost = host(artifact.providerEndpoint), category = "Compaction",
        inputTokens = artifact.inputTokenCount, outputTokens = artifact.outputTokenCount, conversationId = artifact.conversationID,
        messageId = null, createdAt = artifact.createdAt.epochMillis,
      )
    }
    for (value in extensions.experience) {
      if (value.kind != PortableExperienceValue.USAGE) continue
      val provider = value.providerID?.let(providersById::get)
      rows += UsageRecordEntity(
        id = value.id, providerId = mapProvider(value.providerID) ?: value.providerID,
        providerKind = value.usageProviderKind?.takeIf { ProviderKind.fromRawId(it) != null } ?: provider?.providerRawValue
          ?: ProviderKind.CUSTOM.rawId,
        providerName = provider?.displayName ?: "Provider", modelId = value.model ?: "Unknown model",
        destinationHost = value.usageProviderHost, category = PortableMapping.usageCategoryFromPortable(value.usageCategory ?: "Other"),
        inputTokens = value.inputTokens, outputTokens = value.outputTokens,
        conversationId = value.conversationID?.takeIf { it in conversationIds }, messageId = value.messageID,
        createdAt = (value.usageDate ?: value.updatedAt).epochMillis,
      )
    }
    return rows.distinctBy { it.id }
  }

  // endregion

  private fun collectSkippedNotes() {
    val receipts = snapshot.messages.count { it.contextReceiptData != null } + snapshot.requestContextEvents.size
    if (receipts > 0) notes += "${count(receipts, "context receipt stays", "context receipts stay")} in the iOS library; receipts are not portable between platforms."
    val legacySummaries = snapshot.conversations.count { it.compactionSnapshotData != null }
    if (legacySummaries > 0) notes += "${count(legacySummaries, "older-format history summary is", "older-format history summaries are")} not restored."
    val tools = snapshot.messages.count { it.roleRawValue == "tool" }
    if (tools > 0) notes += "${count(tools, "tool message is", "tool messages are")} not restored on Android."
    val drafts = attachmentValues.count { it.messageID == null }
    if (drafts > 0) notes += "${count(drafts, "unsent draft attachment is", "unsent draft attachments are")} not restored."
    val experience = extensions.experience.groupingBy { it.kind }.eachCount()
    experience[PortableExperienceValue.WATCH_RECEIPT]?.let { notes += "${count(it, "Apple Watch item is", "Apple Watch items are")} not restored on Android." }
    val preferences = extensions.experience.count {
      (it.kind == PortableExperienceValue.MODEL && (it.favorite || it.lastUsed != null)) ||
        (it.kind == PortableExperienceValue.PROJECT_DEFAULT && it.projectID == null)
    }
    if (preferences > 0) notes += "Model favorites and the default model are device preferences and are not restored."
    val connectionDetails = extensions.experience.count {
      it.kind == PortableExperienceValue.WEB_SOURCES && (it.connectionActions != null || it.searchNotice != null || it.searchedServices != null)
    }
    if (connectionDetails > 0) notes += "Connected-account activity details for ${count(connectionDetails, "answer", "answers")} stay in the iOS library; their sources are restored."
    val prices = extensions.experience.count {
      (it.inputPricePerMillion == null) != (it.outputPricePerMillion == null) ||
        ((it.inputPricePerMillion != null) && mapProvider(it.providerID) == null)
    }
    if (prices > 0) notes += "${count(prices, "custom model price is", "custom model prices are")} incomplete and not restored."
  }

  private fun count(value: Int, singular: String, plural: String) = "$value ${if (value == 1) singular else plural}"

  private companion object {
    const val MAXIMUM_ENABLED_PROFILES = 4
    val StringList = ListSerializer(String.serializer())
    val EventJson = Json {
      ignoreUnknownKeys = true
      encodeDefaults = true
      explicitNulls = false
    }
    val IntegrityJson = Json {
      encodeDefaults = true
      explicitNulls = true
    }
  }
}

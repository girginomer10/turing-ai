package com.omergirgin.mosaic.core.backup

import com.omergirgin.mosaic.core.provider.ProviderKind
import java.net.URI

/**
 * Port of the iOS restore validation (`MosaicPortableBackup.validate` plus the memory, project,
 * model-catalog and experience archives). It runs on every decoded backup before anything is
 * staged, and on Android's own export as a read-back check, so a file Android writes is accepted
 * by iOS and vice versa. Deep checks of opaque iOS receipt payloads are not ported: Android never
 * restores those payloads (see the restore notes).
 */
object PortableBackupValidator {
  const val MAXIMUM_CONVERSATION_TITLE_BYTES = 16 * 1_024
  const val MAXIMUM_SYSTEM_PROMPT_BYTES = 256 * 1_024
  const val MAXIMUM_DRAFT_BYTES = 512 * 1_024
  const val MAXIMUM_MESSAGE_BYTES = 512 * 1_024
  const val MAXIMUM_MEMORY_TITLE_BYTES = 4 * 1_024
  const val MAXIMUM_MEMORY_CONTENT_BYTES = 256 * 1_024
  const val MAXIMUM_PROJECT_NAME_BYTES = 4 * 1_024
  const val MAXIMUM_PROJECT_INSTRUCTIONS_BYTES = 256 * 1_024
  const val COMPACTION_PROMPT_VERSION = "mosaic-conversation-compaction-v1"
  private const val MAXIMUM_COVERAGE_DEPTH = 1_024

  val MESSAGE_ROLES = setOf("system", "user", "assistant", "tool")
  val MESSAGE_STATUSES = setOf("pending", "streaming", "complete", "failed", "cancelled")
  val MEMORY_SCOPES = setOf("global", "project", "conversation")
  val RECURRENCES = setOf("once", "daily", "weekly")
  val TASK_STATUSES = setOf("active", "paused", "completed", "failed")
  val COMPACTION_MODES = setOf("initial", "extend", "rebuild")

  fun isProviderKind(raw: String?): Boolean = raw != null && ProviderKind.fromRawId(raw) != null

  fun utf8(value: String): Int = value.toByteArray(Charsets.UTF_8).size

  fun validate(snapshot: PortableSnapshot, limits: PortableBackupLimits = PortableBackupLimits.DEFAULT) {
    if (snapshot.recordCount > limits.maximumRecordCount) throw PortableBackupException.tooManyRecords()
    unique(snapshot.conversations.map { it.id }, "conversation")
    unique(snapshot.messages.map { it.id }, "message")
    unique(snapshot.memories.map { it.id }, "memory")
    unique(snapshot.scheduledTasks.map { it.id }, "scheduled_task")
    unique(snapshot.providerConfigurations.map { it.id }, "provider_configuration")
    unique(snapshot.embeddingProfiles.map { it.id }, "embedding_profile")
    unique(snapshot.importedDocuments.map { it.id }, "imported_document")
    unique(snapshot.documentChunks.map { it.id }, "document_chunk")
    unique(snapshot.requestContextEvents.map { it.id }, "request_context_event")
    unique(snapshot.compactionArtifacts.map { it.id }, "compaction_artifact")
    unique(snapshot.conversationCompactionHeads.map { it.conversationID }, "conversation_compaction_head")
    uniqueKeys(snapshot.requestContextEvents.map { it.eventKey }, "request_context_event")
    uniqueKeys(snapshot.normalizedBackfillProgress.map { it.migrationKey }, "normalized_backfill_progress")
    validateSourceFieldSizes(snapshot)

    val conversationIds = snapshot.conversations.mapTo(HashSet()) { it.id }
    for (message in snapshot.messages) {
      if (message.conversationID !in conversationIds) throw PortableBackupException.missing("message", "conversation")
    }
    val documentIds = snapshot.importedDocuments.mapTo(HashSet()) { it.id }
    for (chunk in snapshot.documentChunks) {
      if (chunk.documentID !in documentIds) throw PortableBackupException.missing("document_chunk", "document")
    }
    for (profile in snapshot.embeddingProfiles) {
      if (!profile.weight.isFinite() || profile.weight < 0.25 || profile.weight > 2.0) {
        throw PortableBackupException.invalid("embedding_profile", "weight")
      }
      if (profile.backendRawValue != "provider") throw PortableBackupException.invalid("embedding_profile", "backend")
    }
    for (message in snapshot.messages) {
      if (message.roleRawValue !in MESSAGE_ROLES || message.statusRawValue !in MESSAGE_STATUSES ||
        (message.providerKindRawValue != null && !isProviderKind(message.providerKindRawValue))
      ) {
        throw PortableBackupException.invalid("message", "enum_value")
      }
      if (message.contextReceiptData != null && message.roleRawValue != "assistant") {
        throw PortableBackupException.invalid("message", "context_receipt_role")
      }
    }
    for (memory in snapshot.memories) {
      if (memory.scopeRawValue !in MEMORY_SCOPES) throw PortableBackupException.invalid("memory", "scope")
    }
    for (task in snapshot.scheduledTasks) {
      if (task.recurrenceRawValue !in RECURRENCES || task.statusRawValue !in TASK_STATUSES) {
        throw PortableBackupException.invalid("scheduled_task", "enum_value")
      }
    }
    for (provider in snapshot.providerConfigurations) {
      if (!isProviderKind(provider.providerRawValue)) throw PortableBackupException.invalid("provider_configuration", "provider")
      provider.contextWindowTokens?.let {
        if (it !in 2_048..2_000_000) throw PortableBackupException.invalid("provider_configuration", "context_window_tokens")
      }
      provider.maximumOutputTokens?.let {
        if (it !in 128..1_000_000) throw PortableBackupException.invalid("provider_configuration", "maximum_output_tokens")
      }
    }
    validateExperience(snapshot)
    validateModels(snapshot)
    val memberships = validateProjects(snapshot, conversationIds, documentIds)
    MemoryGraphRules.problems(snapshot, memberships).firstOrNull()?.let { throw it.toException() }
    validateNormalized(snapshot, limits)
  }

  private fun unique(ids: List<String>, recordType: String) {
    val seen = HashSet<String>(ids.size * 2)
    for (id in ids) if (!seen.add(id)) throw PortableBackupException.duplicateId(recordType)
  }

  private fun uniqueKeys(keys: List<String>, recordType: String) {
    val seen = HashSet<String>(keys.size * 2)
    for (key in keys) if (!seen.add(key)) throw PortableBackupException.duplicateKey(recordType)
  }

  private fun validateSourceFieldSizes(snapshot: PortableSnapshot) {
    for (conversation in snapshot.conversations) {
      if (utf8(conversation.title) > MAXIMUM_CONVERSATION_TITLE_BYTES) throw PortableBackupException.recordTooLarge("conversation_title")
      if (utf8(conversation.systemPrompt ?: "") > MAXIMUM_SYSTEM_PROMPT_BYTES) {
        throw PortableBackupException.recordTooLarge("conversation_system_prompt")
      }
      if (utf8(conversation.draftText) > MAXIMUM_DRAFT_BYTES) throw PortableBackupException.recordTooLarge("conversation_draft")
    }
    for (message in snapshot.messages) {
      if (utf8(message.content) > MAXIMUM_MESSAGE_BYTES) throw PortableBackupException.recordTooLarge("message_content")
    }
    for (memory in snapshot.memories) {
      if (utf8(memory.title) > MAXIMUM_MEMORY_TITLE_BYTES) throw PortableBackupException.recordTooLarge("memory_title")
      if (utf8(memory.content) > MAXIMUM_MEMORY_CONTENT_BYTES) throw PortableBackupException.recordTooLarge("memory_content")
    }
  }

  // region experience

  fun validateExperienceValue(value: PortableExperienceValue) {
    val bad = { throw PortableBackupException.malformed() }
    if ((value.model?.let(::utf8) ?: 0) > 2_048 || (value.filename?.let(::utf8) ?: 0) > 1_024 ||
      (value.bytes?.size ?: 0) > 1_048_576 || (value.extractedText?.let(::utf8) ?: 0) > 800_000 ||
      listOfNotNull(value.inputPricePerMillion, value.outputPricePerMillion).any { !it.isFinite() || it < 0 || it > 1_000_000 } ||
      (value.sources?.size ?: 0) > 100 || (value.usageProviderHost?.let(::utf8) ?: 0) > 253
    ) bad()
    value.connectionActions?.let { actions ->
      if (value.kind != PortableExperienceValue.WEB_SOURCES || (actions as? PJArray)?.items?.size?.let { it > 20 } != false) bad()
    }
    value.searchNotice?.let { if (value.kind != PortableExperienceValue.WEB_SOURCES || utf8(it) > 1_500) bad() }
    value.searchedServices?.let { services ->
      val items = (services as? PJArray)?.items ?: bad()
      if (value.kind != PortableExperienceValue.WEB_SOURCES || items.size > 2 || items.toSet().size != items.size) bad()
    }
    if (value.watchUsage != null && value.kind != PortableExperienceValue.USAGE) bad()
    val bytesEmpty = value.bytes == null
    when (value.kind) {
      PortableExperienceValue.MODEL, PortableExperienceValue.PROJECT_DEFAULT ->
        if (value.providerID == null || value.model.isNullOrEmpty() || !bytesEmpty || value.extractedText != null ||
          value.conversationID != null || value.messageID != null || value.mimeType != null || value.filename != null
        ) bad()
      PortableExperienceValue.USAGE ->
        if (value.providerID == null || value.model == null || value.usageCategory == null || !bytesEmpty ||
          value.extractedText != null || value.usageDate == null ||
          listOfNotNull(value.inputTokens, value.outputTokens).any { it !in 0..1_000_000_000 }
        ) bad()
      PortableExperienceValue.WATCH_RECEIPT ->
        if (value.originalConversationID == null || value.conversationID != null || value.messageID != null ||
          (value.watchUserMessageID == null) != (value.watchAssistantMessageID == null) || !bytesEmpty || value.extractedText != null
        ) bad()
      PortableExperienceValue.BRANCH ->
        if (value.conversationID == null || value.branchGroupID == null || !bytesEmpty || value.extractedText != null ||
          value.messageID != null
        ) bad()
      PortableExperienceValue.WEB_SOURCES ->
        if (value.conversationID == null || value.messageID == null || !bytesEmpty ||
          value.sources?.all(::isValidWebSource) != true
        ) bad()
      PortableExperienceValue.ATTACHMENT -> {
        val image = value.isImage
        val valid = value.conversationID != null && !value.filename.isNullOrEmpty() && value.providerID == null &&
          value.model == null && value.projectID == null && !value.mimeType.isNullOrEmpty() &&
          (!image || value.extractedText == null) &&
          if (image) value.mimeType == "image/jpeg" && (value.bytes?.size ?: 0) > 0
          else bytesEmpty && !value.extractedText.isNullOrEmpty()
        if (!valid) bad()
      }
      else -> throw PortableBackupException.unsupportedExtension()
    }
  }

  /** iOS `WebSource.isValid`. */
  fun isValidWebSource(source: PortableWebSource): Boolean {
    if (utf8(source.title) > 2_048 || utf8(source.url) > 8_192) return false
    if ('<' in source.url || '>' in source.url || '\n' in source.url) return false
    val uri = runCatching { URI(source.url) }.getOrNull() ?: return false
    if (uri.scheme?.lowercase() !in setOf("https", "http") || uri.host.isNullOrEmpty() || uri.rawUserInfo != null) return false
    return (source.start ?: 0) >= 0 && (source.end ?: 0) >= 0 && (source.end ?: 0) <= 2_000_000
  }

  private fun validateExperience(snapshot: PortableSnapshot) {
    val conversationIds = snapshot.conversations.mapTo(HashSet()) { it.id }
    val messageConversations = snapshot.messages.associate { it.id to it.conversationID }
    for (value in snapshot.extensions.experience) {
      validateExperienceValue(value)
      if (value.kind == PortableExperienceValue.ATTACHMENT || value.kind == PortableExperienceValue.BRANCH ||
        value.kind == PortableExperienceValue.WEB_SOURCES
      ) {
        val conversationId = value.conversationID
        if (conversationId == null || conversationId !in conversationIds ||
          (value.messageID != null && messageConversations[value.messageID] != conversationId)
        ) throw PortableBackupException.malformed()
      }
    }
  }

  // endregion

  // region models

  fun isValidModelSelection(value: PortableModelSelection): Boolean {
    val model = value.modelIdentifier
    return model.isNotEmpty() && model == IosTextRules.trim(model) && utf8(model) <= 2_048 &&
      model.none { it in "\n\r\u000B\u000C\u0085  " } &&
      (value.recordType == PortableNamespaces.PROVIDER_MODEL) == (value.enabled != null) &&
      (value.contextWindow?.let { it in 2_048..2_000_000 } ?: true) &&
      (value.maximumOutput?.let { it > 0 && it <= (value.contextWindow ?: 16_777_216) } ?: true)
  }

  private fun validateModels(snapshot: PortableSnapshot) {
    val providers = snapshot.providerConfigurations.mapTo(HashSet()) { it.id }
    val tasks = snapshot.scheduledTasks.associateBy { it.id }
    val keys = HashSet<String>()
    for (value in snapshot.extensions.providerModels + snapshot.extensions.taskModels) {
      if (!isValidModelSelection(value)) throw PortableBackupException.invalid(value.recordType, "model")
      val key = if (value.recordType == PortableNamespaces.PROVIDER_MODEL) {
        PortableModelSelection.selectionKey(value.providerID, value.modelIdentifier)
      } else {
        PortableIds.toPortable(value.id)
      }
      if (!keys.add(value.recordType + key)) throw PortableBackupException.duplicateKey(value.recordType)
      val valid = if (value.recordType == PortableNamespaces.PROVIDER_MODEL) {
        value.providerID in providers
      } else {
        tasks[value.id]?.providerConfigurationID == value.providerID
      }
      if (!valid) throw PortableBackupException.invalid(value.recordType, "provider_reference")
    }
  }

  // endregion

  // region projects

  class Memberships(
    val projectByConversation: Map<String, String>,
    val projectByTopic: Map<String, String>,
    val projectByMemory: Map<String, String>,
    val projectByDocument: Map<String, String>,
  )

  fun isValidProjectName(name: String): Boolean =
    IosTextRules.trim(name).let { it.isNotEmpty() && it == name } && utf8(name) <= MAXIMUM_PROJECT_NAME_BYTES

  private fun validateProjects(snapshot: PortableSnapshot, conversationIds: Set<String>, documentIds: Set<String>): Memberships {
    val projectIds = HashSet<String>()
    for (project in snapshot.extensions.projects) {
      if (!projectIds.add(project.id)) throw PortableBackupException.duplicateId("project")
      if (!isValidProjectName(project.name) || utf8(project.instructions) > MAXIMUM_PROJECT_INSTRUCTIONS_BYTES) {
        throw PortableBackupException.invalid("project", "name")
      }
      if (project.createdAt > project.updatedAt) throw PortableBackupException.invalid("project", "timestamps")
    }
    val memories = snapshot.memories.associateBy { it.id }
    for (memory in snapshot.memories) {
      if (memory.scopeRawValue == "project" && memory.conversationID != null) {
        throw PortableBackupException.invalid("memory", "project_scope")
      }
    }
    val topicScopes = HashMap<String, String>()
    for (topic in snapshot.extensions.topics) {
      if (topic.scopeRawValue !in MEMORY_SCOPES) throw PortableBackupException.invalid("memory_topic", "scope")
      if (topicScopes.put(topic.id, topic.scopeRawValue) != null) throw PortableBackupException.duplicateId("memory_topic")
    }
    val bindingIds = HashSet<String>()
    val bindingKeys = HashSet<String>()
    val byConversation = HashMap<String, String>()
    val byTopic = HashMap<String, String>()
    val byMemory = HashMap<String, String>()
    val byDocument = HashMap<String, String>()
    for (binding in snapshot.extensions.bindings) {
      if (!bindingIds.add(binding.id)) throw PortableBackupException.duplicateId("project_resource_binding")
      val kind = binding.resourceKindRawValue
      if (kind !in PortableProjectBinding.KINDS) throw PortableBackupException.invalid("project_resource_binding", "resource_kind")
      val expected = PortableProjectBinding.bindingKey(kind, binding.resourceID)
      if (binding.bindingKey != expected) throw PortableBackupException.invalid("project_resource_binding", "binding_key")
      if (!bindingKeys.add(expected)) throw PortableBackupException.duplicateKey("project_resource_binding")
      if (binding.projectID !in projectIds) throw PortableBackupException.missing("project_resource_binding", "project")
      if (binding.createdAt > binding.updatedAt) throw PortableBackupException.invalid("project_resource_binding", "timestamps")
      when (kind) {
        PortableProjectBinding.CONVERSATION -> {
          if (binding.resourceID !in conversationIds) throw PortableBackupException.missing("project_resource_binding", "resource")
          byConversation[binding.resourceID] = binding.projectID
        }
        PortableProjectBinding.MEMORY -> {
          val memory = memories[binding.resourceID] ?: throw PortableBackupException.missing("project_resource_binding", "resource")
          if (memory.scopeRawValue != "project" || memory.conversationID != null) {
            throw PortableBackupException.invalid("project_resource_binding", "resource_scope")
          }
          byMemory[binding.resourceID] = binding.projectID
        }
        PortableProjectBinding.MEMORY_TOPIC -> {
          val scope = topicScopes[binding.resourceID] ?: throw PortableBackupException.missing("project_resource_binding", "resource")
          if (scope != "project") throw PortableBackupException.invalid("project_resource_binding", "resource_scope")
          byTopic[binding.resourceID] = binding.projectID
        }
        PortableProjectBinding.DOCUMENT -> {
          if (binding.resourceID !in documentIds) throw PortableBackupException.missing("project_resource_binding", "resource")
          byDocument[binding.resourceID] = binding.projectID
        }
      }
    }
    for (memory in snapshot.memories) {
      if (memory.scopeRawValue == "project" && memory.id !in byMemory) throw PortableBackupException.invalid("memory", "project_binding")
    }
    for ((topicId, scope) in topicScopes) {
      if (scope == "project" && topicId !in byTopic) throw PortableBackupException.invalid("memory_topic", "project_binding")
    }
    return Memberships(byConversation, byTopic, byMemory, byDocument)
  }

  // endregion

  // region normalized context

  /** iOS canonical transcript order: createdAt, user before other roles, uppercase UUID text. */
  val CANONICAL_ORDER: Comparator<PortableMessage> = Comparator { a, b ->
    val byDate = a.createdAt.compareTo(b.createdAt)
    if (byDate != 0) return@Comparator byDate
    val rankA = if (a.roleRawValue == "user") 0 else 1
    val rankB = if (b.roleRawValue == "user") 0 else 1
    if (rankA != rankB) return@Comparator rankA - rankB
    PortableIds.toPortable(a.id).compareTo(PortableIds.toPortable(b.id))
  }

  fun canonicalMessagesByConversation(messages: List<PortableMessage>): Map<String, List<PortableMessage>> =
    messages.asSequence()
      .filter { it.statusRawValue == "complete" && (it.roleRawValue == "user" || it.roleRawValue == "assistant") }
      .groupBy { it.conversationID }
      .mapValues { (_, list) -> list.sortedWith(CANONICAL_ORDER) }

  /** iOS `NormalizedContextStore.eventKey`. */
  fun requestEventKey(assistantMessageId: String, sequence: Int): String =
    "request-context/v1/${assistantMessageId.lowercase()}/${sequence.toLong().toString().padStart(20, '0')}"

  private fun validateNormalized(snapshot: PortableSnapshot, limits: PortableBackupLimits) {
    val maximumCounter = maxOf(1L, minOf(limits.maximumTotalBytes, 1_000_000_000L))
    fun counter(value: Int) = value >= 0 && value <= maximumCounter
    val conversations = snapshot.conversations.mapTo(HashSet()) { it.id }
    val messages = snapshot.messages.associateBy { it.id }
    val artifacts = snapshot.compactionArtifacts.associateBy { it.id }
    val canonical = canonicalMessagesByConversation(snapshot.messages)
    val canonicalIndices = canonical.mapValues { (_, list) -> list.withIndex().associate { it.value.id to it.index } }

    for (event in snapshot.requestContextEvents) {
      if (event.payloadData.size > limits.maximumNormalizedPayloadBytes) {
        throw PortableBackupException.recordTooLarge("request_context_event_payload")
      }
      if (event.conversationID !in conversations) throw PortableBackupException.missing("request_context_event", "conversation")
      val assistant = messages[event.assistantMessageID]
      if (assistant == null || assistant.conversationID != event.conversationID || assistant.roleRawValue != "assistant") {
        throw PortableBackupException.missing("request_context_event", "assistant_message")
      }
      val source = messages[event.sourceThroughMessageID]
      if (source == null || source.conversationID != event.conversationID) {
        throw PortableBackupException.missing("request_context_event", "source_message")
      }
      if (source.roleRawValue != "user" || source.statusRawValue != "complete" || assistant.createdAt < source.createdAt) {
        throw PortableBackupException.invalid("request_context_event", "source_message")
      }
      if (!counter(event.eventSequence)) throw PortableBackupException.invalid("request_context_event", "event_sequence")
      val list = canonical[event.conversationID].orEmpty()
      val boundary = canonicalIndices[event.conversationID]?.get(assistant.id) ?: insertionIndex(assistant, list)
      if (event.sourceMessageCount <= 0 || event.sourceMessageCount > list.size ||
        list[event.sourceMessageCount - 1].id != event.sourceThroughMessageID || boundary != event.sourceMessageCount
      ) {
        throw PortableBackupException.invalid("request_context_event", "source_message_count")
      }
      val key = requestEventKey(event.assistantMessageID, event.eventSequence)
      if (event.eventKey != key) throw PortableBackupException.invalid("request_context_event", "event_key")
      if (event.id != PortableIds.deterministicLocal(key)) throw PortableBackupException.invalid("request_context_event", "id")
      if (PortableHashes.sha256Hex(event.payloadData) != event.payloadFingerprint) {
        throw PortableBackupException.invalid("request_context_event", "payload_fingerprint")
      }
    }

    CompactionRules.problems(snapshot.compactionArtifacts, canonical, conversations, maximumCounter)
      .firstOrNull()?.let { throw PortableBackupException.invalid("compaction_artifact", it.second) }

    for (head in snapshot.conversationCompactionHeads) {
      if (head.conversationID !in conversations) throw PortableBackupException.missing("conversation_compaction_head", "conversation")
      head.activeArtifactID?.let { artifactId ->
        val artifact = artifacts[artifactId]
        if (artifact == null || artifact.conversationID != head.conversationID) {
          throw PortableBackupException.missing("conversation_compaction_head", "active_artifact")
        }
        if (!artifact.isSnapshotComplete) throw PortableBackupException.invalid("conversation_compaction_head", "active_artifact_complete")
      }
      if (!counter(head.revision)) throw PortableBackupException.invalid("conversation_compaction_head", "revision")
    }

    for (progress in snapshot.normalizedBackfillProgress) {
      val combined = progress.migratedCount.toLong() + progress.retainedLegacyCount
      if (!counter(progress.processedCount) || !counter(progress.migratedCount) || !counter(progress.retainedLegacyCount) ||
        !counter(progress.failureCount) || progress.processedCount.toLong() != combined ||
        progress.failureCount > progress.retainedLegacyCount
      ) throw PortableBackupException.invalid("normalized_backfill_progress", "counts")
    }
  }

  private fun insertionIndex(message: PortableMessage, ordered: List<PortableMessage>): Int {
    var low = 0
    var high = ordered.size
    while (low < high) {
      val middle = low + (high - low) / 2
      if (CANONICAL_ORDER.compare(ordered[middle], message) < 0) low = middle + 1 else high = middle
    }
    return low
  }

  // endregion
}

/**
 * iOS compaction-artifact rules (lineage, chain depth, counters, payload fingerprint and exact
 * coverage of the canonical transcript). Returns `(artifactId, field)` for every invalid artifact so
 * an exporter can omit unusable summaries instead of producing a backup iOS rejects.
 */
object CompactionRules {
  fun problems(
    artifacts: List<PortableCompactionArtifact>,
    canonical: Map<String, List<PortableMessage>>,
    conversationIds: Set<String>,
    maximumCounter: Long,
  ): List<Pair<String, String>> {
    val problems = ArrayList<Pair<String, String>>()
    val byId = artifacts.associateBy { it.id }
    fun counter(value: Int) = value >= 0 && value <= maximumCounter
    for (artifact in artifacts) {
      val field: String? = run {
        if (artifact.conversationID !in conversationIds) return@run "conversation"
        if (artifact.providerKindRawValue != null && !PortableBackupValidator.isProviderKind(artifact.providerKindRawValue)) {
          return@run "provider_kind"
        }
        if (artifact.modeRawValue !in PortableBackupValidator.COMPACTION_MODES) return@run "mode"
        val parentId = artifact.coverageParentArtifactID
        if (parentId != null) {
          val parent = byId[parentId]
          if (parent == null || parent.conversationID != artifact.conversationID) return@run "coverage_parent"
          if (artifact.lineagePreviousCompactionID != parentId || artifact.isDetachedCoverageRoot) return@run "coverage_lineage"
        } else if (artifact.isDetachedCoverageRoot) {
          if (artifact.lineagePreviousCompactionID == null) return@run "detached_coverage_root"
        } else if (artifact.lineagePreviousCompactionID != null) {
          return@run "coverage_lineage"
        }
        when (artifact.modeRawValue) {
          "initial" -> if (artifact.chainDepth != 1 || artifact.lineagePreviousCompactionID != null || parentId != null ||
            artifact.isDetachedCoverageRoot
          ) return@run "chain_depth"
          "rebuild" -> if (artifact.chainDepth != 1 || artifact.lineagePreviousCompactionID == null) return@run "chain_depth"
          "extend" -> {
            val parent = parentId?.let(byId::get)
            if (parent != null) {
              if (artifact.chainDepth != parent.chainDepth + 1) return@run "chain_depth"
            } else if (!artifact.isDetachedCoverageRoot || artifact.chainDepth < 2) {
              return@run "chain_depth"
            }
          }
        }
        if (!counter(artifact.coveredMessageCount) || !counter(artifact.chainDepth) ||
          !counter(artifact.estimatedSourceTokens) || !counter(artifact.estimatedSummaryTokens)
        ) return@run "counts"
        if (artifact.computedFingerprint() != artifact.payloadFingerprint) return@run "payload_fingerprint"
        null
      }
      if (field != null) problems += artifact.id to field
    }
    if (problems.isNotEmpty()) return problems
    return coverageProblems(byId, canonical)
  }

  private fun coverageProblems(
    byId: Map<String, PortableCompactionArtifact>,
    canonical: Map<String, List<PortableMessage>>,
  ): List<Pair<String, String>> {
    val problems = ArrayList<Pair<String, String>>()
    val resolvedCounts = HashMap<String, Int>()
    val resolvedDepths = HashMap<String, Int>()
    val requestedCounts = HashMap<String, MutableSet<Int>>()
    for (artifact in byId.values) {
      if (artifact.isSnapshotComplete) requestedCounts.getOrPut(artifact.conversationID) { HashSet() } += artifact.coveredMessageCount
    }
    val fingerprints = HashMap<String, Map<Int, String>>()
    for ((conversationId, messages) in canonical) {
      val wanted = requestedCounts[conversationId] ?: continue
      val hasher = IosTextRules.CompactionFingerprinter()
      val result = HashMap<Int, String>()
      messages.forEachIndexed { index, message ->
        hasher.add(message.id, message.roleRawValue, message.content)
        if ((index + 1) in wanted) result[index + 1] = hasher.current()
      }
      fingerprints[conversationId] = result
    }

    for (artifact in byId.values.sortedBy { it.id }) {
      if (problems.isNotEmpty()) break
      val path = ArrayList<PortableCompactionArtifact>()
      val visited = HashSet<String>()
      var cursor: PortableCompactionArtifact? = artifact
      var inheritedCount = 0
      var inheritedDepth = 0
      var failed: String? = null
      while (true) {
        val current = cursor ?: break
        val resolved = resolvedCounts[current.id]
        if (resolved != null) {
          inheritedCount = resolved
          inheritedDepth = resolvedDepths[current.id] ?: 0
          break
        }
        if (!visited.add(current.id)) { failed = "cycle"; break }
        if (path.size >= MAXIMUM_DEPTH) { failed = "coverage_depth"; break }
        path += current
        cursor = current.coverageParentArtifactID?.let(byId::get)
      }
      failed?.let { problems += artifact.id to it; continue }
      for (current in path.asReversed()) {
        if (inheritedDepth >= MAXIMUM_DEPTH) { problems += current.id to "coverage_depth"; break }
        val delta = decodeUuidList(current.coverageDeltaData)
        if (delta == null) { problems += current.id to "coverage_delta"; break }
        val messages = canonical[current.conversationID].orEmpty()
        val coverageOk = inheritedCount <= current.coveredMessageCount && current.coveredMessageCount <= messages.size &&
          delta.size == current.coveredMessageCount - inheritedCount &&
          delta.indices.all { messages[inheritedCount + it].id == delta[it] }
        if (!coverageOk) { problems += current.id to "covered_message_count"; break }
        if (current.isSnapshotComplete && !isCompleteSnapshotValid(current, messages, fingerprints[current.conversationID])) {
          problems += current.id to "complete_snapshot"
          break
        }
        resolvedCounts[current.id] = current.coveredMessageCount
        inheritedDepth += 1
        resolvedDepths[current.id] = inheritedDepth
        inheritedCount = current.coveredMessageCount
      }
    }
    return problems
  }

  private fun isCompleteSnapshotValid(
    artifact: PortableCompactionArtifact,
    messages: List<PortableMessage>,
    fingerprints: Map<Int, String>?,
  ): Boolean {
    val count = artifact.coveredMessageCount
    if (count <= 0 || messages[count - 1].roleRawValue != "assistant") return false
    if (artifact.promptVersion != PortableBackupValidator.COMPACTION_PROMPT_VERSION) return false
    val content = decodeContent(artifact.contentData ?: return false) ?: return false
    if (content.schemaVersion != 1 || artifact.contentSchemaVersion != content.schemaVersion) return false
    val sourceFingerprint = artifact.sourceFingerprint ?: return false
    if (fingerprints?.get(count) != sourceFingerprint) return false
    if (artifact.providerConfigurationID == null || !PortableBackupValidator.isProviderKind(artifact.providerKindRawValue) ||
      artifact.providerDisplayName == null || artifact.providerEndpoint == null || artifact.modelIdentifier == null
    ) return false
    if (decodeStringList(artifact.warningsData) == null) return false
    return IosTextRules.renderedSummary(content.overview, content.items) == artifact.renderedSummary
  }

  class Content(val schemaVersion: Int, val overview: String, val items: List<Pair<String, String>>)

  /** Lenient like Swift `JSONDecoder` (unknown keys ignored), strict on required fields. */
  fun decodeContent(bytes: ByteArray): Content? = runCatching {
    val root = PortableJsonReader.parse(bytes) as PJObject
    val schema = (root["schema_version"] as PJNumber).literal.toInt()
    val overview = (root["overview"] as PJString).value
    val items = (root["items"] as PJArray).items.map { item ->
      val obj = item as PJObject
      (obj["kind"] as PJString).value to (obj["text"] as PJString).value
    }
    Content(schema, overview, items)
  }.getOrNull()

  fun decodeUuidList(bytes: ByteArray): List<String>? = runCatching {
    (PortableJsonReader.parse(bytes) as PJArray).items.map { PortableIds.fromPortable((it as PJString).value)!! }
  }.getOrNull()

  fun decodeStringList(bytes: ByteArray): List<String>? = runCatching {
    (PortableJsonReader.parse(bytes) as PJArray).items.map { (it as PJString).value }
  }.getOrNull()

  private const val MAXIMUM_DEPTH = 1_024
}

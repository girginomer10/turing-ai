package com.omergirgin.mosaic.core.backup

/**
 * iOS `AutomaticMemoryPortableArchive.validate` and the automatic-memory field limits, returning
 * every problem instead of throwing the first one. Restore rejects a backup with any problem; the
 * exporter instead leaves out the affected learned topic (with its evidence and history) or
 * formation job so the rest of the library stays restorable on iOS.
 */
object MemoryGraphRules {
  private const val CANONICAL_KEY_BYTES = 1_024
  private const val EXCERPT_BYTES = 8 * 1_024
  private const val KEY_BYTES = 2 * 1_024
  private const val PROVENANCE_BYTES = 8 * 1_024
  private const val ERROR_BYTES = 8 * 1_024
  private const val TITLE_CHARACTERS = 160
  private const val TITLE_BYTES = 512
  private const val CONTENT_CHARACTERS = 2_000
  private const val CONTENT_BYTES = 8 * 1_024

  val KINDS = setOf("event", "identity", "preference", "relationship", "project", "goal", "constraint", "workflow", "fact")
  val TOPIC_STATUSES = setOf("active", "forgotten")
  val ORIGINS = setOf("automatic", "manual")
  val STABILITIES = setOf("evolving", "stable", "permanent")
  val REVISION_KINDS = setOf("created", "reinforced", "updated", "forgotten", "reactivated", "user_edited", "user_disabled", "user_enabled")
  val JOB_STATUSES = setOf("pending", "generating", "complete", "failed", "rejected")

  class MessageFacts(
    val id: String,
    val conversationId: String,
    val role: String,
    val status: String,
    val content: String,
    val createdAt: PortableDate,
  )

  class Input(
    val topics: List<PortableMemoryTopic>,
    val evidence: List<PortableMemoryEvidence>,
    val revisions: List<PortableMemoryRevision>,
    val jobs: List<PortableMemoryFormationJob>,
    val audits: List<PortableMemoryFormationAudit>,
    val conversationIds: Set<String>,
    val message: (String) -> MessageFacts?,
    val projectByConversation: Map<String, String>,
    val projectByTopic: Map<String, String>,
  )

  /** One rule violation. [topicId] / [jobId] name the unit an exporter would omit. */
  class Problem(
    val recordType: String,
    val field: String,
    val missing: Boolean = false,
    val duplicate: Boolean = false,
    val topicId: String? = null,
    val jobId: String? = null,
    val auditId: String? = null,
  ) {
    fun toException(): PortableBackupException = when {
      duplicate -> PortableBackupException.duplicateKey(recordType)
      missing -> PortableBackupException.missing(recordType, field)
      else -> PortableBackupException.invalid(recordType, field)
    }
  }

  fun problems(snapshot: PortableSnapshot, memberships: PortableBackupValidator.Memberships): List<Problem> {
    val messages = snapshot.messages.associateBy { it.id }
    return problems(
      Input(
        topics = snapshot.extensions.topics,
        evidence = snapshot.extensions.evidence,
        revisions = snapshot.extensions.revisions,
        jobs = snapshot.extensions.jobs,
        audits = snapshot.extensions.audits,
        conversationIds = snapshot.conversations.mapTo(HashSet()) { it.id },
        message = { id ->
          messages[id]?.let { MessageFacts(it.id, it.conversationID, it.roleRawValue, it.statusRawValue, it.content, it.createdAt) }
        },
        projectByConversation = memberships.projectByConversation,
        projectByTopic = memberships.projectByTopic,
      )
    )
  }

  private fun bytes(value: String) = value.toByteArray(Charsets.UTF_8).size

  private fun validText(title: String, content: String): Boolean {
    val trimmedTitle = IosTextRules.trim(title)
    val trimmedContent = IosTextRules.trim(content)
    return trimmedTitle.isNotEmpty() && trimmedTitle == title && trimmedContent.isNotEmpty() && trimmedContent == content &&
      IosTextRules.characterCount(title) <= TITLE_CHARACTERS && IosTextRules.characterCount(content) <= CONTENT_CHARACTERS &&
      bytes(title) <= TITLE_BYTES && bytes(content) <= CONTENT_BYTES
  }

  private fun validEndpoint(endpoint: String?, providerConfigurationId: String?): Boolean {
    val trimmed = endpoint?.let(IosTextRules::trim)
    if (endpoint != null && trimmed.isNullOrEmpty()) return false
    return providerConfigurationId == null || !trimmed.isNullOrEmpty()
  }

  private fun validProvenance(vararg values: String?) = values.all { it == null || bytes(it) <= PROVENANCE_BYTES }

  fun problems(input: Input): List<Problem> {
    val problems = ArrayList<Problem>()
    val topicsById = input.topics.associateBy { it.id }
    val evidenceById = input.evidence.associateBy { it.id }

    val canonicalKeys = HashSet<String>()
    for (topic in input.topics) {
      fun bad(field: String, missing: Boolean = false, duplicate: Boolean = false) {
        problems += Problem("memory_topic", field, missing, duplicate, topicId = topic.id)
      }
      if (topic.kindRawValue !in KINDS || topic.scopeRawValue !in PortableBackupValidator.MEMORY_SCOPES ||
        topic.statusRawValue !in TOPIC_STATUSES || topic.originRawValue !in ORIGINS || topic.stabilityRawValue !in STABILITIES
      ) { bad("enum_value"); continue }
      if (topic.scopeRawValue != "conversation" && topic.conversationID != null) { bad("topic_conversation"); continue }
      val fieldsValid = validText(topic.title, topic.content) && topic.canonicalKey.isNotEmpty() &&
        bytes(topic.canonicalKey) <= CANONICAL_KEY_BYTES && topic.confidence in 0.0..1.0 && topic.importance in 0.0..1.0 &&
        topic.useCount >= 0 && topic.evidenceCount >= 0 && topic.revision > 0 &&
        (topic.scopeRawValue == "conversation") == (topic.conversationID != null) &&
        (topic.statusRawValue != "forgotten" || !topic.isEnabled) &&
        topic.createdAt <= topic.updatedAt && topic.lastConfirmedAt <= topic.updatedAt
      if (!fieldsValid) { bad("metadata"); continue }
      val prefix = when (topic.scopeRawValue) {
        "global" -> if (topic.id in input.projectByTopic) { bad("project_binding"); continue } else "global:${topic.kindRawValue}:"
        "project" -> {
          val projectId = input.projectByTopic[topic.id] ?: run { bad("project_binding"); null } ?: continue
          "project:${projectId.lowercase()}:${topic.kindRawValue}:"
        }
        else -> {
          val conversationId = topic.conversationID ?: run { bad("canonical_key"); null } ?: continue
          if (topic.id in input.projectByTopic) { bad("project_binding"); continue }
          "conversation:${conversationId.lowercase()}:${topic.kindRawValue}:"
        }
      }
      if (!topic.canonicalKey.startsWith(prefix) || bytes(topic.canonicalKey) <= bytes(prefix)) { bad("canonical_key"); continue }
      if (!canonicalKeys.add(topic.canonicalKey)) { bad("canonical_key", duplicate = true); continue }
      if (topic.conversationID != null && topic.conversationID !in input.conversationIds) bad("conversation", missing = true)
    }

    val evidenceKeys = HashSet<String>()
    val evidenceCountByTopic = HashMap<String, Int>()
    for (item in input.evidence) {
      fun bad(field: String, missing: Boolean = false, duplicate: Boolean = false) {
        problems += Problem("memory_evidence", field, missing, duplicate, topicId = item.topicID)
      }
      if (!evidenceKeys.add(item.evidenceKey)) { bad("evidence_key", duplicate = true); continue }
      if (item.providerKindRawValue != null && !PortableBackupValidator.isProviderKind(item.providerKindRawValue)) {
        bad("provider_kind"); continue
      }
      val fieldsValid = item.evidenceKey.isNotEmpty() && bytes(item.evidenceKey) <= KEY_BYTES &&
        bytes(item.excerpt) <= EXCERPT_BYTES && item.sourceFingerprint.isNotEmpty() && bytes(item.sourceFingerprint) <= KEY_BYTES &&
        validProvenance(item.providerDisplayName, item.modelIdentifier, item.providerEndpoint) &&
        IosTextRules.trim(item.excerpt).isNotEmpty() && item.confidence in 0.0..1.0
      if (!fieldsValid) { bad("metadata"); continue }
      if (!validEndpoint(item.providerEndpoint, item.providerConfigurationID)) { bad("provider_endpoint"); continue }
      val topic = topicsById[item.topicID] ?: run { bad("topic", missing = true); null } ?: continue
      if (topic.scopeRawValue == "conversation" && topic.conversationID != item.conversationID) { bad("topic_conversation"); continue }
      if (topic.originRawValue == "automatic") {
        val conversationProject = input.projectByConversation[item.conversationID]
        val audience = when (topic.scopeRawValue) {
          "global" -> conversationProject == null
          "project" -> input.projectByTopic[item.topicID] != null && input.projectByTopic[item.topicID] == conversationProject
          "conversation" -> topic.conversationID == item.conversationID
          else -> false
        }
        if (!audience) { bad("topic_project_audience"); continue }
      }
      if (item.conversationID !in input.conversationIds) { bad("conversation", missing = true); continue }
      val source = input.message(item.sourceMessageID)
      if (source == null || source.conversationId != item.conversationID || source.role != "user" || source.status != "complete") {
        bad("source_message", missing = true); continue
      }
      if (item.sourceFingerprint != IosTextRules.memorySourceFingerprint(source.id, source.content)) { bad("source_fingerprint"); continue }
      if (item.excerpt != IosTextRules.evidenceExcerpt(source.content)) { bad("excerpt"); continue }
      if (item.evidenceKey != IosTextRules.evidenceKey(item.topicID, item.sourceMessageID, item.sourceFingerprint)) {
        bad("evidence_key"); continue
      }
      item.assistantMessageID?.let { assistantId ->
        val assistant = input.message(assistantId)
        if (assistant == null || assistant.conversationId != item.conversationID || assistant.role != "assistant" ||
          assistant.status != "complete" || assistant.createdAt < source.createdAt
        ) { bad("assistant_message", missing = true); return@let }
      }
      evidenceCountByTopic[item.topicID] = (evidenceCountByTopic[item.topicID] ?: 0) + 1
    }

    for (topic in input.topics) {
      val count = evidenceCountByTopic[topic.id] ?: 0
      if (topic.evidenceCount != count) {
        problems += Problem("memory_topic", "evidence_count", topicId = topic.id)
        continue
      }
      if (topic.originRawValue == "automatic") {
        if (topic.statusRawValue == "active" && count == 0) problems += Problem("memory_topic", "automatic_evidence", topicId = topic.id)
        else if (count == 0 && (topic.statusRawValue != "forgotten" || topic.isEnabled)) {
          problems += Problem("memory_topic", "automatic_evidence", topicId = topic.id)
        }
      }
    }

    val revisionKeys = HashSet<String>()
    val revisionsByTopic = HashMap<String, MutableList<PortableMemoryRevision>>()
    for (item in input.revisions) {
      fun bad(field: String, missing: Boolean = false, duplicate: Boolean = false) {
        problems += Problem("memory_revision", field, missing, duplicate, topicId = item.topicID)
      }
      if (!revisionKeys.add(item.revisionKey)) { bad("revision_key", duplicate = true); continue }
      if (item.kindRawValue !in REVISION_KINDS) { bad("kind"); continue }
      val previousValid = (item.previousTitle == null) == (item.previousContent == null) &&
        (item.previousTitle == null || validText(item.previousTitle, item.previousContent!!))
      if (item.revisionKey.isEmpty() || bytes(item.revisionKey) > KEY_BYTES || !validText(item.title, item.content) ||
        !previousValid || item.sequence <= 0
      ) { bad("metadata"); continue }
      if (item.topicID !in topicsById) { bad("topic", missing = true); continue }
      item.sourceEvidenceID?.let { evidenceId ->
        val evidence = evidenceById[evidenceId]
        if (evidence == null) { bad("evidence", missing = true); return@let }
        if (evidence.topicID != item.topicID) bad("source_evidence_topic")
      }
      revisionsByTopic.getOrPut(item.topicID) { ArrayList() } += item
    }
    val evidenceIdsByTopic = input.evidence.groupBy { it.topicID }.mapValues { (_, list) -> list.mapTo(HashSet()) { it.id } }
    for (topic in input.topics) {
      val history = revisionsByTopic[topic.id].orEmpty()
        .sortedWith(compareBy<PortableMemoryRevision>({ it.sequence }, { PortableIds.toPortable(it.id) }))
      fun bad(field: String) {
        problems += Problem("memory_topic", field, topicId = topic.id)
      }
      if (history.size != topic.revision) { bad("revision_head"); continue }
      val surviving = evidenceIdsByTopic[topic.id].orEmpty()
      if (topic.originRawValue == "automatic" && topic.statusRawValue == "active" &&
        history.none { revision -> revision.sourceEvidenceID?.let { it in surviving } == true }
      ) { bad("revision_evidence"); continue }
      var previous: PortableMemoryRevision? = null
      var broken = false
      for ((index, revision) in history.withIndex()) {
        val sequence = index + 1
        if (revision.sequence != sequence || revision.revisionKey != "${topic.id.lowercase()}/$sequence") {
          broken = true; break
        }
        val prior = previous
        if (prior != null) {
          if (revision.previousTitle != prior.title || revision.previousContent != prior.content || revision.createdAt < prior.createdAt) {
            broken = true; break
          }
        } else if (revision.kindRawValue != "created" || revision.previousTitle != null || revision.previousContent != null) {
          broken = true; break
        }
        previous = revision
      }
      if (broken) { bad("revision_sequence"); continue }
      val head = previous
      if (head == null || head.title != topic.title || head.content != topic.content) bad("revision_value")
    }

    val jobKeys = HashSet<String>()
    for (item in input.jobs) {
      fun bad(field: String, missing: Boolean = false, duplicate: Boolean = false) {
        problems += Problem("memory_formation_job", field, missing, duplicate, jobId = item.id)
      }
      if (!jobKeys.add(item.jobKey)) { bad("job_key", duplicate = true); continue }
      if (item.statusRawValue !in JOB_STATUSES ||
        (item.providerKindRawValue != null && !PortableBackupValidator.isProviderKind(item.providerKindRawValue))
      ) { bad("enum_value"); continue }
      val fieldsValid = item.jobKey.isNotEmpty() && bytes(item.jobKey) <= KEY_BYTES && item.sourceFingerprint.isNotEmpty() &&
        bytes(item.sourceFingerprint) <= KEY_BYTES && item.promptVersion.isNotEmpty() && bytes(item.promptVersion) <= KEY_BYTES &&
        validProvenance(item.providerDisplayName, item.modelIdentifier, item.providerEndpoint, item.outputFingerprint) &&
        (item.lastError?.let { bytes(it) <= ERROR_BYTES } ?: true) && item.attemptCount >= 0 &&
        item.createdAt <= item.updatedAt && (item.statusRawValue != "complete" || item.outputFingerprint != null)
      if (!fieldsValid) { bad("metadata"); continue }
      if (!validEndpoint(item.providerEndpoint, item.providerConfigurationID)) { bad("provider_endpoint"); continue }
      if (item.conversationID !in input.conversationIds) { bad("conversation", missing = true); continue }
      val user = input.message(item.throughUserMessageID)
      if (user == null || user.conversationId != item.conversationID || user.role != "user" || user.status != "complete") {
        bad("user_message", missing = true); continue
      }
      val assistant = input.message(item.assistantMessageID)
      if (assistant == null || assistant.conversationId != item.conversationID || assistant.role != "assistant" ||
        assistant.status != "complete" || assistant.createdAt < user.createdAt
      ) { bad("assistant_message", missing = true); continue }
      if (item.sourceFingerprint != IosTextRules.memorySourceFingerprint(user.id, user.content)) { bad("source_fingerprint"); continue }
      if (item.jobKey != IosTextRules.formationJobKey(item.promptVersion, item.conversationID, item.throughUserMessageID, item.sourceFingerprint)) {
        bad("job_key")
      }
    }

    val jobsById = input.jobs.associateBy { it.id }
    val auditJobIds = HashSet<String>()
    val auditJobKeys = HashSet<String>()
    for (item in input.audits) {
      fun bad(field: String, missing: Boolean = false, duplicate: Boolean = false) {
        problems += Problem("memory_formation_audit", field, missing, duplicate, auditId = item.id)
      }
      if (!auditJobIds.add(item.jobID) || !auditJobKeys.add(item.jobKey)) { bad("job", duplicate = true); continue }
      val job = jobsById[item.jobID]
      if (job == null || job.jobKey != item.jobKey) { bad("formation_job", missing = true); continue }
      if (!isValidAudit(item)) { bad("metadata"); continue }
      val sameProvider = item.providerKindRawValue == job.providerKindRawValue &&
        item.providerDisplayName == job.providerDisplayName && item.modelIdentifier == job.modelIdentifier &&
        item.providerEndpoint == job.providerEndpoint
      val generating = job.statusRawValue == "generating" && (
        (item.attemptCount == job.attemptCount && item.outcomeRawValue == "generating" && item.requestStarted && sameProvider) ||
          (item.attemptCount < job.attemptCount && item.outcomeRawValue in setOf("complete", "failed", "rejected"))
        )
      val terminal = job.statusRawValue in setOf("complete", "failed", "rejected") && item.attemptCount == job.attemptCount &&
        item.outcomeRawValue == job.statusRawValue && sameProvider && item.finishedAt == job.updatedAt
      if (!validEndpoint(item.providerEndpoint, item.providerConfigurationID) || item.attemptCount > job.attemptCount ||
        !(generating || terminal)
      ) bad("job_state")
    }
    return problems
  }

  /** iOS `MosaicSourceFieldLimits.validateMemoryFormationAudit`. */
  fun isValidAudit(audit: PortableMemoryFormationAudit): Boolean {
    if (bytes(audit.jobKey) > KEY_BYTES ||
      !validProvenance(audit.providerDisplayName, audit.modelIdentifier, audit.providerEndpoint, audit.providerMessageID) ||
      (audit.errorDescription?.let { bytes(it) > ERROR_BYTES } == true)
    ) return false
    val outcome = audit.outcomeRawValue
    val generating = outcome == "generating"
    val complete = outcome == "complete"
    val failed = outcome == "failed"
    val rejected = outcome == "rejected"
    val trimmedEndpoint = audit.providerEndpoint?.let(IosTextRules::trim)
    val trimmedMessageId = audit.providerMessageID?.let(IosTextRules::trim)
    val trimmedError = audit.errorDescription?.let(IosTextRules::trim)
    val tokensValid = listOfNotNull(audit.inputTokenCount, audit.outputTokenCount).all { it in 0..1_000_000_000 }
    val startedBeforeFinish = audit.startedAt?.let { it <= audit.finishedAt } ?: true
    return audit.jobKey.isNotEmpty() && audit.attemptCount >= 0 && (generating || complete || failed || rejected) &&
      (audit.providerKindRawValue == null || PortableBackupValidator.isProviderKind(audit.providerKindRawValue)) &&
      (audit.providerEndpoint == null || !trimmedEndpoint.isNullOrEmpty()) &&
      (audit.providerMessageID == null || !trimmedMessageId.isNullOrEmpty()) &&
      tokensValid && audit.providerRequestCount >= 0 && audit.providerRequestCount <= audit.attemptCount &&
      audit.cumulativeInputTokenCount >= 0 && audit.cumulativeOutputTokenCount >= 0 &&
      (audit.inputTokenCount?.let { it <= audit.cumulativeInputTokenCount } ?: true) &&
      (audit.outputTokenCount?.let { it <= audit.cumulativeOutputTokenCount } ?: true) &&
      (audit.providerRequestCount > 0 || (audit.cumulativeInputTokenCount == 0 && audit.cumulativeOutputTokenCount == 0)) &&
      (audit.requestStarted || (audit.providerMessageID == null && audit.inputTokenCount == null && audit.outputTokenCount == null)) &&
      startedBeforeFinish && audit.createdAt <= audit.updatedAt && audit.updatedAt == audit.finishedAt &&
      (!generating || (audit.attemptCount > 0 && audit.requestStarted && audit.errorDescription == null)) &&
      (!complete || (audit.attemptCount > 0 && audit.requestStarted && audit.errorDescription == null)) &&
      (!audit.requestStarted || audit.providerRequestCount > 0) &&
      ((!failed && !rejected) || !trimmedError.isNullOrEmpty())
  }
}

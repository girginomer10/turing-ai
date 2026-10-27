package com.omergirgin.mosaic.core.backup

/*
 * Typed payloads of the iOS extension namespaces (automatic memory, projects, model catalogs and
 * "experience" sidecars). Each payload is encoded by Swift with `.sortedKeys` only, so slashes are
 * escaped, and iOS compares re-encoded payload bytes after its staging import: these encoders must
 * stay byte-identical to the Swift structs (`AutomaticMemoryPortableArchive.swift`,
 * `ProjectPortableArchive.swift`, `ProviderModelsPortableArchive.swift`, `ExperienceStore.swift`).
 */

object PortableNamespaces {
  const val EXPERIENCE = "com.omergirgin.mosaic.experience"
  const val MEMORY = "com.omergirgin.mosaic.memory"
  const val MODELS = "com.omergirgin.mosaic.models"
  const val PROJECT = "com.omergirgin.mosaic.project"
  const val RECORD_VERSION = 1

  const val TOPIC = "topic"
  const val EVIDENCE = "evidence"
  const val REVISION = "revision"
  const val FORMATION_JOB = "formation_job"
  const val FORMATION_AUDIT = "formation_audit"
  const val PROJECT_RECORD = "project"
  const val RESOURCE_BINDING = "resource_binding"
  const val PROVIDER_MODEL = "provider_model"
  const val TASK_MODEL = "task_model"
}

private fun payloadFailure(): () -> Nothing = { throw PortableBackupException.invalid("extension", "payload") }

private fun encodePayload(value: PJObject): ByteArray = SwiftJsonWriter.encode(value, withoutEscapingSlashes = false)

class PortableMemoryTopic(
  val id: String,
  val canonicalKey: String,
  val title: String,
  val content: String,
  val kindRawValue: String,
  val scopeRawValue: String,
  val conversationID: String?,
  val statusRawValue: String,
  val originRawValue: String,
  val confidence: Double,
  val importance: Double,
  val stabilityRawValue: String,
  val isEnabled: Boolean,
  val lastConfirmedAt: PortableDate,
  val lastUsedAt: PortableDate?,
  val useCount: Int,
  val evidenceCount: Int,
  val revision: Int,
  val createdAt: PortableDate,
  val updatedAt: PortableDate,
) {
  fun toRecord() = PortableExtensionRecord(
    PortableNamespaces.MEMORY, PortableNamespaces.TOPIC, PortableNamespaces.RECORD_VERSION, id,
    encodePayload(pjObject {
      uuid("id", id); string("canonicalKey", canonicalKey); string("title", title); string("content", content)
      string("kindRawValue", kindRawValue); string("scopeRawValue", scopeRawValue); uuid("conversationID", conversationID)
      string("statusRawValue", statusRawValue); string("originRawValue", originRawValue); double("confidence", confidence)
      double("importance", importance); string("stabilityRawValue", stabilityRawValue); bool("isEnabled", isEnabled)
      date("lastConfirmedAt", lastConfirmedAt); date("lastUsedAt", lastUsedAt); int("useCount", useCount)
      int("evidenceCount", evidenceCount); int("revision", revision); date("createdAt", createdAt); date("updatedAt", updatedAt)
    }),
  )

  companion object {
    fun from(value: PJ) = PJFields.read(value, payloadFailure()) {
      PortableMemoryTopic(
        id = uuid("id"), canonicalKey = string("canonicalKey"), title = string("title"), content = string("content"),
        kindRawValue = string("kindRawValue"), scopeRawValue = string("scopeRawValue"), conversationID = optUuid("conversationID"),
        statusRawValue = string("statusRawValue"), originRawValue = string("originRawValue"), confidence = double("confidence"),
        importance = double("importance"), stabilityRawValue = string("stabilityRawValue"), isEnabled = bool("isEnabled"),
        lastConfirmedAt = date("lastConfirmedAt"), lastUsedAt = optDate("lastUsedAt"), useCount = int("useCount"),
        evidenceCount = int("evidenceCount"), revision = int("revision"), createdAt = date("createdAt"), updatedAt = date("updatedAt"),
      )
    }
  }
}

class PortableMemoryEvidence(
  val id: String,
  val evidenceKey: String,
  val topicID: String,
  val conversationID: String,
  val sourceMessageID: String,
  val assistantMessageID: String?,
  val excerpt: String,
  val sourceFingerprint: String,
  val providerConfigurationID: String?,
  val providerKindRawValue: String?,
  val providerDisplayName: String?,
  val modelIdentifier: String?,
  val providerEndpoint: String?,
  val confidence: Double,
  val createdAt: PortableDate,
) {
  fun toRecord() = PortableExtensionRecord(
    PortableNamespaces.MEMORY, PortableNamespaces.EVIDENCE, PortableNamespaces.RECORD_VERSION, id,
    encodePayload(pjObject {
      uuid("id", id); string("evidenceKey", evidenceKey); uuid("topicID", topicID); uuid("conversationID", conversationID)
      uuid("sourceMessageID", sourceMessageID); uuid("assistantMessageID", assistantMessageID); string("excerpt", excerpt)
      string("sourceFingerprint", sourceFingerprint); uuid("providerConfigurationID", providerConfigurationID)
      string("providerKindRawValue", providerKindRawValue); string("providerDisplayName", providerDisplayName)
      string("modelIdentifier", modelIdentifier); string("providerEndpoint", providerEndpoint); double("confidence", confidence)
      date("createdAt", createdAt)
    }),
  )

  companion object {
    fun from(value: PJ) = PJFields.read(value, payloadFailure()) {
      PortableMemoryEvidence(
        id = uuid("id"), evidenceKey = string("evidenceKey"), topicID = uuid("topicID"), conversationID = uuid("conversationID"),
        sourceMessageID = uuid("sourceMessageID"), assistantMessageID = optUuid("assistantMessageID"), excerpt = string("excerpt"),
        sourceFingerprint = string("sourceFingerprint"), providerConfigurationID = optUuid("providerConfigurationID"),
        providerKindRawValue = optString("providerKindRawValue"), providerDisplayName = optString("providerDisplayName"),
        modelIdentifier = optString("modelIdentifier"), providerEndpoint = optString("providerEndpoint"),
        confidence = double("confidence"), createdAt = date("createdAt"),
      )
    }
  }
}

class PortableMemoryRevision(
  val id: String,
  val revisionKey: String,
  val topicID: String,
  val sequence: Int,
  val kindRawValue: String,
  val previousTitle: String?,
  val previousContent: String?,
  val title: String,
  val content: String,
  val sourceEvidenceID: String?,
  val createdAt: PortableDate,
) {
  fun toRecord() = PortableExtensionRecord(
    PortableNamespaces.MEMORY, PortableNamespaces.REVISION, PortableNamespaces.RECORD_VERSION, id,
    encodePayload(pjObject {
      uuid("id", id); string("revisionKey", revisionKey); uuid("topicID", topicID); int("sequence", sequence)
      string("kindRawValue", kindRawValue); string("previousTitle", previousTitle); string("previousContent", previousContent)
      string("title", title); string("content", content); uuid("sourceEvidenceID", sourceEvidenceID); date("createdAt", createdAt)
    }),
  )

  companion object {
    fun from(value: PJ) = PJFields.read(value, payloadFailure()) {
      PortableMemoryRevision(
        id = uuid("id"), revisionKey = string("revisionKey"), topicID = uuid("topicID"), sequence = int("sequence"),
        kindRawValue = string("kindRawValue"), previousTitle = optString("previousTitle"), previousContent = optString("previousContent"),
        title = string("title"), content = string("content"), sourceEvidenceID = optUuid("sourceEvidenceID"), createdAt = date("createdAt"),
      )
    }
  }
}

class PortableMemoryFormationJob(
  val id: String,
  val jobKey: String,
  val conversationID: String,
  val throughUserMessageID: String,
  val assistantMessageID: String,
  val sourceFingerprint: String,
  val promptVersion: String,
  val statusRawValue: String,
  val attemptCount: Int,
  val providerConfigurationID: String?,
  val providerKindRawValue: String?,
  val providerDisplayName: String?,
  val modelIdentifier: String?,
  val providerEndpoint: String?,
  val outputFingerprint: String?,
  val lastError: String?,
  val startedAt: PortableDate?,
  val completedAt: PortableDate?,
  val createdAt: PortableDate,
  val updatedAt: PortableDate,
) {
  fun toRecord() = PortableExtensionRecord(
    PortableNamespaces.MEMORY, PortableNamespaces.FORMATION_JOB, PortableNamespaces.RECORD_VERSION, id,
    encodePayload(pjObject {
      uuid("id", id); string("jobKey", jobKey); uuid("conversationID", conversationID)
      uuid("throughUserMessageID", throughUserMessageID); uuid("assistantMessageID", assistantMessageID)
      string("sourceFingerprint", sourceFingerprint); string("promptVersion", promptVersion); string("statusRawValue", statusRawValue)
      int("attemptCount", attemptCount); uuid("providerConfigurationID", providerConfigurationID)
      string("providerKindRawValue", providerKindRawValue); string("providerDisplayName", providerDisplayName)
      string("modelIdentifier", modelIdentifier); string("providerEndpoint", providerEndpoint)
      string("outputFingerprint", outputFingerprint); string("lastError", lastError); date("startedAt", startedAt)
      date("completedAt", completedAt); date("createdAt", createdAt); date("updatedAt", updatedAt)
    }),
  )

  companion object {
    fun from(value: PJ) = PJFields.read(value, payloadFailure()) {
      PortableMemoryFormationJob(
        id = uuid("id"), jobKey = string("jobKey"), conversationID = uuid("conversationID"),
        throughUserMessageID = uuid("throughUserMessageID"), assistantMessageID = uuid("assistantMessageID"),
        sourceFingerprint = string("sourceFingerprint"), promptVersion = string("promptVersion"),
        statusRawValue = string("statusRawValue"), attemptCount = int("attemptCount"),
        providerConfigurationID = optUuid("providerConfigurationID"), providerKindRawValue = optString("providerKindRawValue"),
        providerDisplayName = optString("providerDisplayName"), modelIdentifier = optString("modelIdentifier"),
        providerEndpoint = optString("providerEndpoint"), outputFingerprint = optString("outputFingerprint"),
        lastError = optString("lastError"), startedAt = optDate("startedAt"), completedAt = optDate("completedAt"),
        createdAt = date("createdAt"), updatedAt = date("updatedAt"),
      )
    }
  }
}

class PortableMemoryFormationAudit(
  val id: String,
  val jobID: String,
  val jobKey: String,
  val attemptCount: Int,
  val outcomeRawValue: String,
  val providerConfigurationID: String?,
  val providerKindRawValue: String?,
  val providerDisplayName: String?,
  val modelIdentifier: String?,
  val providerEndpoint: String?,
  val providerMessageID: String?,
  val requestStarted: Boolean,
  val inputTokenCount: Int?,
  val outputTokenCount: Int?,
  val providerRequestCount: Int,
  val cumulativeInputTokenCount: Int,
  val cumulativeOutputTokenCount: Int,
  val didDiscardInvalidTelemetry: Boolean,
  val errorDescription: String?,
  val startedAt: PortableDate?,
  val finishedAt: PortableDate,
  val createdAt: PortableDate,
  val updatedAt: PortableDate,
) {
  fun toRecord() = PortableExtensionRecord(
    PortableNamespaces.MEMORY, PortableNamespaces.FORMATION_AUDIT, PortableNamespaces.RECORD_VERSION, id,
    encodePayload(pjObject {
      uuid("id", id); uuid("jobID", jobID); string("jobKey", jobKey); int("attemptCount", attemptCount)
      string("outcomeRawValue", outcomeRawValue); uuid("providerConfigurationID", providerConfigurationID)
      string("providerKindRawValue", providerKindRawValue); string("providerDisplayName", providerDisplayName)
      string("modelIdentifier", modelIdentifier); string("providerEndpoint", providerEndpoint)
      string("providerMessageID", providerMessageID); bool("requestStarted", requestStarted)
      int("inputTokenCount", inputTokenCount); int("outputTokenCount", outputTokenCount)
      int("providerRequestCount", providerRequestCount); int("cumulativeInputTokenCount", cumulativeInputTokenCount)
      int("cumulativeOutputTokenCount", cumulativeOutputTokenCount); bool("didDiscardInvalidTelemetry", didDiscardInvalidTelemetry)
      string("errorDescription", errorDescription); date("startedAt", startedAt); date("finishedAt", finishedAt)
      date("createdAt", createdAt); date("updatedAt", updatedAt)
    }),
  )

  companion object {
    fun from(value: PJ) = PJFields.read(value, payloadFailure()) {
      PortableMemoryFormationAudit(
        id = uuid("id"), jobID = uuid("jobID"), jobKey = string("jobKey"), attemptCount = int("attemptCount"),
        outcomeRawValue = string("outcomeRawValue"), providerConfigurationID = optUuid("providerConfigurationID"),
        providerKindRawValue = optString("providerKindRawValue"), providerDisplayName = optString("providerDisplayName"),
        modelIdentifier = optString("modelIdentifier"), providerEndpoint = optString("providerEndpoint"),
        providerMessageID = optString("providerMessageID"), requestStarted = bool("requestStarted"),
        inputTokenCount = optInt("inputTokenCount"), outputTokenCount = optInt("outputTokenCount"),
        providerRequestCount = int("providerRequestCount"), cumulativeInputTokenCount = int("cumulativeInputTokenCount"),
        cumulativeOutputTokenCount = int("cumulativeOutputTokenCount"),
        didDiscardInvalidTelemetry = bool("didDiscardInvalidTelemetry"), errorDescription = optString("errorDescription"),
        startedAt = optDate("startedAt"), finishedAt = date("finishedAt"), createdAt = date("createdAt"), updatedAt = date("updatedAt"),
      )
    }
  }
}

class PortableProject(
  val id: String,
  val name: String,
  val instructions: String,
  val isArchived: Boolean,
  val createdAt: PortableDate,
  val updatedAt: PortableDate,
) {
  fun toRecord() = PortableExtensionRecord(
    PortableNamespaces.PROJECT, PortableNamespaces.PROJECT_RECORD, PortableNamespaces.RECORD_VERSION, id,
    encodePayload(pjObject {
      uuid("id", id); string("name", name); string("instructions", instructions); bool("isArchived", isArchived)
      date("createdAt", createdAt); date("updatedAt", updatedAt)
    }),
  )

  companion object {
    fun from(value: PJ) = PJFields.read(value, payloadFailure()) {
      PortableProject(
        id = uuid("id"), name = string("name"), instructions = string("instructions"), isArchived = bool("isArchived"),
        createdAt = date("createdAt"), updatedAt = date("updatedAt"),
      )
    }
  }
}

class PortableProjectBinding(
  val id: String,
  val bindingKey: String,
  val resourceKindRawValue: String,
  val resourceID: String,
  val projectID: String,
  val createdAt: PortableDate,
  val updatedAt: PortableDate,
) {
  fun toRecord() = PortableExtensionRecord(
    PortableNamespaces.PROJECT, PortableNamespaces.RESOURCE_BINDING, PortableNamespaces.RECORD_VERSION, id,
    encodePayload(pjObject {
      uuid("id", id); string("bindingKey", bindingKey); string("resourceKindRawValue", resourceKindRawValue)
      uuid("resourceID", resourceID); uuid("projectID", projectID); date("createdAt", createdAt); date("updatedAt", updatedAt)
    }),
  )

  companion object {
    const val CONVERSATION = "conversation"
    const val MEMORY = "memory"
    const val MEMORY_TOPIC = "memory_topic"
    const val DOCUMENT = "document"
    val KINDS = setOf(CONVERSATION, MEMORY, MEMORY_TOPIC, DOCUMENT)

    /** iOS `ProjectResourceBindingRecord.makeBindingKey`. */
    fun bindingKey(kind: String, resourceId: String) = "$kind:${resourceId.lowercase()}"

    fun from(value: PJ) = PJFields.read(value, payloadFailure()) {
      PortableProjectBinding(
        id = uuid("id"), bindingKey = string("bindingKey"), resourceKindRawValue = string("resourceKindRawValue"),
        resourceID = uuid("resourceID"), projectID = uuid("projectID"), createdAt = date("createdAt"), updatedAt = date("updatedAt"),
      )
    }
  }
}

/** `provider_model` (catalog row) or `task_model` (exact automation choice; [enabled] is null). */
class PortableModelSelection(
  val recordType: String,
  val id: String,
  val providerID: String,
  val modelIdentifier: String,
  val enabled: Boolean?,
  val contextWindow: Int?,
  val maximumOutput: Int?,
) {
  fun toRecord() = PortableExtensionRecord(
    PortableNamespaces.MODELS, recordType, PortableNamespaces.RECORD_VERSION, id,
    encodePayload(pjObject {
      uuid("id", id); uuid("providerID", providerID); string("modelIdentifier", modelIdentifier); bool("enabled", enabled)
      int("contextWindow", contextWindow); int("maximumOutput", maximumOutput)
    }),
  )

  companion object {
    /** iOS `ProviderModelRecord.key`: uppercase provider UUID, colon, exact model ID. */
    fun selectionKey(providerId: String, model: String) = PortableIds.toPortable(providerId) + ":" + model

    fun from(recordType: String, value: PJ) = PJFields.read(value, payloadFailure()) {
      PortableModelSelection(
        recordType = recordType, id = uuid("id"), providerID = uuid("providerID"), modelIdentifier = string("modelIdentifier"),
        enabled = optBool("enabled"), contextWindow = optInt("contextWindow"), maximumOutput = optInt("maximumOutput"),
      )
    }
  }
}

class PortableWebSource(val title: String, val url: String, val start: Int?, val end: Int?) {
  fun toPJ() = pjObject { string("title", title); string("url", url); int("start", start); int("end", end) }

  companion object {
    fun from(value: PJ) = PJFields.read(value, payloadFailure()) {
      PortableWebSource(title = string("title"), url = string("url"), start = optInt("start"), end = optInt("end"))
    }
  }
}

/** Large attachment bytes may live outside the heap while a restore is staged. */
class PortableBlob(val size: Int, private val loader: () -> ByteArray) {
  fun load(): ByteArray = loader()

  companion object {
    fun inMemory(bytes: ByteArray) = PortableBlob(bytes.size) { bytes }
  }
}

/** Optional spill target for attachment bytes during decode. */
fun interface PortableBlobSink {
  fun store(recordId: String, bytes: ByteArray): PortableBlob
}

/**
 * iOS `ExperienceValue` (attachments, chooser defaults, model preferences, extra usage, web
 * sources, conversation branches, Watch receipts). Nested Apple-only structures are kept opaque.
 */
class PortableExperienceValue(
  val id: String,
  val kind: String,
  val providerID: String? = null,
  val model: String? = null,
  val projectID: String? = null,
  val favorite: Boolean = false,
  val lastUsed: PortableDate? = null,
  val supportsImages: Boolean? = null,
  val conversationID: String? = null,
  val messageID: String? = null,
  val filename: String? = null,
  val mimeType: String? = null,
  val bytes: PortableBlob? = null,
  val extractedText: String? = null,
  val branchGroupID: String? = null,
  val originalConversationID: String? = null,
  val inputPricePerMillion: Double? = null,
  val outputPricePerMillion: Double? = null,
  val sources: List<PortableWebSource>? = null,
  val searchedServices: PJ? = null,
  val searchNotice: String? = null,
  val connectionActions: PJ? = null,
  val watchUserMessageID: String? = null,
  val watchAssistantMessageID: String? = null,
  val watchUsage: PJ? = null,
  val usageCategory: String? = null,
  val inputTokens: Int? = null,
  val outputTokens: Int? = null,
  val usageDate: PortableDate? = null,
  val usageProviderKind: String? = null,
  val usageProviderHost: String? = null,
  val updatedAt: PortableDate,
) {
  fun toRecord(): PortableExtensionRecord = PortableExtensionRecord(
    PortableNamespaces.EXPERIENCE, kind, PortableNamespaces.RECORD_VERSION, id,
    encodePayload(pjObject {
      uuid("id", id); string("kind", kind); uuid("providerID", providerID); string("model", model); uuid("projectID", projectID)
      bool("favorite", favorite); date("lastUsed", lastUsed); bool("supportsImages", supportsImages)
      uuid("conversationID", conversationID); uuid("messageID", messageID); string("filename", filename)
      string("mimeType", mimeType); data("bytes", bytes?.load()); string("extractedText", extractedText)
      uuid("branchGroupID", branchGroupID); uuid("originalConversationID", originalConversationID)
      double("inputPricePerMillion", inputPricePerMillion); double("outputPricePerMillion", outputPricePerMillion)
      value("sources", sources?.let { list -> PJArray(list.map { it.toPJ() }) }); value("searchedServices", searchedServices)
      string("searchNotice", searchNotice); value("connectionActions", connectionActions)
      uuid("watchUserMessageID", watchUserMessageID); uuid("watchAssistantMessageID", watchAssistantMessageID)
      value("watchUsage", watchUsage); string("usageCategory", usageCategory); int("inputTokens", inputTokens)
      int("outputTokens", outputTokens); date("usageDate", usageDate); string("usageProviderKind", usageProviderKind)
      string("usageProviderHost", usageProviderHost); date("updatedAt", updatedAt)
    }),
  )

  val isImage: Boolean get() = mimeType?.startsWith("image/") == true

  companion object {
    const val MODEL = "model"
    const val PROJECT_DEFAULT = "projectDefault"
    const val ATTACHMENT = "attachment"
    const val BRANCH = "branch"
    const val WEB_SOURCES = "webSources"
    const val USAGE = "usage"
    const val WATCH_RECEIPT = "watchReceipt"
    val KINDS = setOf(MODEL, PROJECT_DEFAULT, ATTACHMENT, BRANCH, WEB_SOURCES, USAGE, WATCH_RECEIPT)

    fun from(value: PJ, blobs: PortableBlobSink?) = PJFields.read(value, payloadFailure()) {
      val id = uuid("id")
      PortableExperienceValue(
        id = id, kind = string("kind").also { if (it !in KINDS) throw PortableBackupException.unsupportedExtension() },
        providerID = optUuid("providerID"), model = optString("model"), projectID = optUuid("projectID"),
        favorite = bool("favorite"), lastUsed = optDate("lastUsed"), supportsImages = optBool("supportsImages"),
        conversationID = optUuid("conversationID"), messageID = optUuid("messageID"), filename = optString("filename"),
        mimeType = optString("mimeType"),
        bytes = optData("bytes")?.let { bytes -> blobs?.store(id, bytes) ?: PortableBlob.inMemory(bytes) },
        extractedText = optString("extractedText"), branchGroupID = optUuid("branchGroupID"),
        originalConversationID = optUuid("originalConversationID"), inputPricePerMillion = optDouble("inputPricePerMillion"),
        outputPricePerMillion = optDouble("outputPricePerMillion"),
        sources = optArray("sources")?.map(PortableWebSource::from), searchedServices = optRaw("searchedServices"),
        searchNotice = optString("searchNotice"), connectionActions = optRaw("connectionActions"),
        watchUserMessageID = optUuid("watchUserMessageID"), watchAssistantMessageID = optUuid("watchAssistantMessageID"),
        watchUsage = optRaw("watchUsage"), usageCategory = optString("usageCategory"), inputTokens = optInt("inputTokens"),
        outputTokens = optInt("outputTokens"), usageDate = optDate("usageDate"), usageProviderKind = optString("usageProviderKind"),
        usageProviderHost = optString("usageProviderHost"), updatedAt = date("updatedAt"),
      )
    }

    /** iOS `ExperienceValue.modelID`. */
    fun derivedId(key: String): String = PortableIds.deterministicLocal(key)
  }
}

/** All decoded extension payloads of one snapshot. */
class PortableExtensions(
  val topics: List<PortableMemoryTopic> = emptyList(),
  val evidence: List<PortableMemoryEvidence> = emptyList(),
  val revisions: List<PortableMemoryRevision> = emptyList(),
  val jobs: List<PortableMemoryFormationJob> = emptyList(),
  val audits: List<PortableMemoryFormationAudit> = emptyList(),
  val projects: List<PortableProject> = emptyList(),
  val bindings: List<PortableProjectBinding> = emptyList(),
  val providerModels: List<PortableModelSelection> = emptyList(),
  val taskModels: List<PortableModelSelection> = emptyList(),
  val experience: List<PortableExperienceValue> = emptyList(),
) {
  val recordCount: Long
    get() = (topics.size + evidence.size + revisions.size + jobs.size + audits.size + projects.size + bindings.size +
      providerModels.size + taskModels.size + experience.size).toLong()

  /** Collects decoded payloads, enforcing envelope/payload ID agreement and unique record IDs. */
  class Builder(private val blobs: PortableBlobSink? = null) {
    private val topics = ArrayList<PortableMemoryTopic>()
    private val evidence = ArrayList<PortableMemoryEvidence>()
    private val revisions = ArrayList<PortableMemoryRevision>()
    private val jobs = ArrayList<PortableMemoryFormationJob>()
    private val audits = ArrayList<PortableMemoryFormationAudit>()
    private val projects = ArrayList<PortableProject>()
    private val bindings = ArrayList<PortableProjectBinding>()
    private val providerModels = ArrayList<PortableModelSelection>()
    private val taskModels = ArrayList<PortableModelSelection>()
    private val experience = ArrayList<PortableExperienceValue>()
    private val recordIds = HashSet<String>()

    fun add(record: PortableExtensionRecord) {
      if (!recordIds.add(record.id)) throw PortableBackupException.duplicateId("extension_record")
      if (record.recordVersion != PortableNamespaces.RECORD_VERSION) throw PortableBackupException.unsupportedExtension()
      val payload = runCatching { PortableJsonReader.parse(record.payload) }
        .getOrElse { throw PortableBackupException.invalid("${record.recordType}_extension", "payload") }
      val decodedId: String = when (record.namespace) {
        PortableNamespaces.MEMORY -> when (record.recordType) {
          PortableNamespaces.TOPIC -> PortableMemoryTopic.from(payload).also { topics += it }.id
          PortableNamespaces.EVIDENCE -> PortableMemoryEvidence.from(payload).also { evidence += it }.id
          PortableNamespaces.REVISION -> PortableMemoryRevision.from(payload).also { revisions += it }.id
          PortableNamespaces.FORMATION_JOB -> PortableMemoryFormationJob.from(payload).also { jobs += it }.id
          PortableNamespaces.FORMATION_AUDIT -> PortableMemoryFormationAudit.from(payload).also { audits += it }.id
          else -> throw PortableBackupException.unsupportedExtension()
        }
        PortableNamespaces.PROJECT -> when (record.recordType) {
          PortableNamespaces.PROJECT_RECORD -> PortableProject.from(payload).also { projects += it }.id
          PortableNamespaces.RESOURCE_BINDING -> PortableProjectBinding.from(payload).also { bindings += it }.id
          else -> throw PortableBackupException.unsupportedExtension()
        }
        PortableNamespaces.MODELS -> when (record.recordType) {
          PortableNamespaces.PROVIDER_MODEL -> PortableModelSelection.from(record.recordType, payload).also { providerModels += it }.id
          PortableNamespaces.TASK_MODEL -> PortableModelSelection.from(record.recordType, payload).also { taskModels += it }.id
          else -> throw PortableBackupException.unsupportedExtension()
        }
        PortableNamespaces.EXPERIENCE -> PortableExperienceValue.from(payload, blobs).also {
          if (it.kind != record.recordType) throw PortableBackupException.malformed()
          experience += it
        }.id
        else -> throw PortableBackupException.unsupportedExtension()
      }
      if (decodedId != record.id) throw PortableBackupException.invalid("${record.recordType}_extension", "payload")
    }

    fun build() = PortableExtensions(topics, evidence, revisions, jobs, audits, projects, bindings, providerModels, taskModels, experience)
  }
}

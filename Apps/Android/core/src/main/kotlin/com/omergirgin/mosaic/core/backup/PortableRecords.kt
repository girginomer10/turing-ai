package com.omergirgin.mosaic.core.backup

/*
 * Kotlin mirrors of the Swift Codable records inside a `.mosaicbackup` snapshot. Property names are
 * the JSON keys. IDs are Android-form (lowercase) strings, dates keep the exact Swift value, and
 * `Data` fields are raw bytes (base64 in JSON). Decoding is strict: an unknown key is rejected
 * because iOS would drop it while re-encoding and then fail the checksum.
 */

/** Strict field access for one decoded object; every failure is reported through [fail]. */
class PJFields(private val obj: PJObject, private val fail: () -> Nothing) {
  private val used = HashSet<String>(obj.fields.size * 2)

  private fun take(key: String): PJ? {
    used += key
    val value = obj.fields[key]
    return if (value == null || value === PJNull) null else value
  }

  fun optString(key: String): String? = take(key)?.let { (it as? PJString)?.value ?: fail() }
  fun string(key: String): String = optString(key) ?: fail()
  fun optUuid(key: String): String? = optString(key)?.let { PortableIds.fromPortable(it) ?: fail() }
  fun uuid(key: String): String = optUuid(key) ?: fail()
  fun optLong(key: String): Long? = take(key)?.let { (it as? PJNumber)?.literal?.toLongOrNull() ?: fail() }
  fun long(key: String): Long = optLong(key) ?: fail()
  fun optInt(key: String): Int? = optLong(key)?.let { if (it in Int.MIN_VALUE..Int.MAX_VALUE) it.toInt() else fail() }
  fun int(key: String): Int = optInt(key) ?: fail()
  fun optDouble(key: String): Double? =
    take(key)?.let { value -> (value as? PJNumber)?.literal?.toDoubleOrNull()?.takeIf { it.isFinite() } ?: fail() }
  fun double(key: String): Double = optDouble(key) ?: fail()
  fun optDate(key: String): PortableDate? = take(key)?.let { (it as? PJNumber)?.literal?.let(PortableDate::fromLiteral) ?: fail() }
  fun date(key: String): PortableDate = optDate(key) ?: fail()
  fun optBool(key: String): Boolean? = take(key)?.let { (it as? PJBool)?.value ?: fail() }
  fun bool(key: String): Boolean = optBool(key) ?: fail()
  fun optData(key: String): ByteArray? = optString(key)?.let { PortableBase64.decode(it) ?: fail() }
  fun data(key: String): ByteArray = optData(key) ?: fail()
  fun optArray(key: String): List<PJ>? = take(key)?.let { (it as? PJArray)?.items ?: fail() }
  fun optRaw(key: String): PJ? = take(key)

  fun finish() {
    if (obj.fields.keys.any { it !in used }) fail()
  }

  companion object {
    inline fun <T> read(value: PJ, noinline fail: () -> Nothing, block: PJFields.() -> T): T {
      val obj = value as? PJObject ?: fail()
      val fields = PJFields(obj, fail)
      val result = fields.block()
      fields.finish()
      return result
    }
  }
}

private val malformed: () -> Nothing = { throw PortableBackupException.malformed() }

class PortableConversation(
  val id: String,
  val title: String,
  val providerConfigurationID: String?,
  val modelIdentifier: String,
  val systemPrompt: String?,
  val draftText: String,
  val compactionSnapshotData: ByteArray?,
  val isArchived: Boolean,
  val createdAt: PortableDate,
  val updatedAt: PortableDate,
) {
  fun toPJ() = pjObject {
    uuid("id", id); string("title", title); uuid("providerConfigurationID", providerConfigurationID)
    string("modelIdentifier", modelIdentifier); string("systemPrompt", systemPrompt); string("draftText", draftText)
    data("compactionSnapshotData", compactionSnapshotData); bool("isArchived", isArchived)
    date("createdAt", createdAt); date("updatedAt", updatedAt)
  }

  companion object {
    fun from(value: PJ) = PJFields.read(value, malformed) {
      PortableConversation(
        id = uuid("id"), title = string("title"), providerConfigurationID = optUuid("providerConfigurationID"),
        modelIdentifier = string("modelIdentifier"), systemPrompt = optString("systemPrompt"), draftText = string("draftText"),
        compactionSnapshotData = optData("compactionSnapshotData"), isArchived = bool("isArchived"),
        createdAt = date("createdAt"), updatedAt = date("updatedAt"),
      )
    }
  }
}

class PortableMessage(
  val id: String,
  val conversationID: String,
  val roleRawValue: String,
  val content: String,
  val statusRawValue: String,
  val providerConfigurationID: String?,
  val providerKindRawValue: String?,
  val providerDisplayName: String?,
  val providerHost: String?,
  val providerMessageID: String?,
  val modelIdentifier: String?,
  val inputTokenCount: Int?,
  val outputTokenCount: Int?,
  val errorDescription: String?,
  val contextReceiptData: ByteArray?,
  val createdAt: PortableDate,
  val updatedAt: PortableDate,
) {
  fun toPJ() = pjObject {
    uuid("id", id); uuid("conversationID", conversationID); string("roleRawValue", roleRawValue); string("content", content)
    string("statusRawValue", statusRawValue); uuid("providerConfigurationID", providerConfigurationID)
    string("providerKindRawValue", providerKindRawValue); string("providerDisplayName", providerDisplayName)
    string("providerHost", providerHost); string("providerMessageID", providerMessageID); string("modelIdentifier", modelIdentifier)
    int("inputTokenCount", inputTokenCount); int("outputTokenCount", outputTokenCount); string("errorDescription", errorDescription)
    data("contextReceiptData", contextReceiptData); date("createdAt", createdAt); date("updatedAt", updatedAt)
  }

  companion object {
    fun from(value: PJ) = PJFields.read(value, malformed) {
      PortableMessage(
        id = uuid("id"), conversationID = uuid("conversationID"), roleRawValue = string("roleRawValue"), content = string("content"),
        statusRawValue = string("statusRawValue"), providerConfigurationID = optUuid("providerConfigurationID"),
        providerKindRawValue = optString("providerKindRawValue"), providerDisplayName = optString("providerDisplayName"),
        providerHost = optString("providerHost"), providerMessageID = optString("providerMessageID"),
        modelIdentifier = optString("modelIdentifier"), inputTokenCount = optInt("inputTokenCount"),
        outputTokenCount = optInt("outputTokenCount"), errorDescription = optString("errorDescription"),
        contextReceiptData = optData("contextReceiptData"), createdAt = date("createdAt"), updatedAt = date("updatedAt"),
      )
    }
  }
}

class PortableMemory(
  val id: String,
  val title: String,
  val content: String,
  val scopeRawValue: String,
  val conversationID: String?,
  val isEnabled: Boolean,
  val isUserApproved: Boolean,
  val createdAt: PortableDate,
  val updatedAt: PortableDate,
) {
  fun toPJ() = pjObject {
    uuid("id", id); string("title", title); string("content", content); string("scopeRawValue", scopeRawValue)
    uuid("conversationID", conversationID); bool("isEnabled", isEnabled); bool("isUserApproved", isUserApproved)
    date("createdAt", createdAt); date("updatedAt", updatedAt)
  }

  companion object {
    fun from(value: PJ) = PJFields.read(value, malformed) {
      PortableMemory(
        id = uuid("id"), title = string("title"), content = string("content"), scopeRawValue = string("scopeRawValue"),
        conversationID = optUuid("conversationID"), isEnabled = bool("isEnabled"), isUserApproved = bool("isUserApproved"),
        createdAt = date("createdAt"), updatedAt = date("updatedAt"),
      )
    }
  }
}

class PortableScheduledTask(
  val id: String,
  val title: String,
  val prompt: String,
  val conversationID: String?,
  val providerConfigurationID: String?,
  val recurrenceRawValue: String,
  val statusRawValue: String,
  val scheduledAt: PortableDate,
  val timeZoneIdentifier: String,
  val nextRunAt: PortableDate?,
  val lastRunAt: PortableDate?,
  val lastError: String?,
  val createdAt: PortableDate,
  val updatedAt: PortableDate,
) {
  fun toPJ() = pjObject {
    uuid("id", id); string("title", title); string("prompt", prompt); uuid("conversationID", conversationID)
    uuid("providerConfigurationID", providerConfigurationID); string("recurrenceRawValue", recurrenceRawValue)
    string("statusRawValue", statusRawValue); date("scheduledAt", scheduledAt); string("timeZoneIdentifier", timeZoneIdentifier)
    date("nextRunAt", nextRunAt); date("lastRunAt", lastRunAt); string("lastError", lastError)
    date("createdAt", createdAt); date("updatedAt", updatedAt)
  }

  companion object {
    fun from(value: PJ) = PJFields.read(value, malformed) {
      PortableScheduledTask(
        id = uuid("id"), title = string("title"), prompt = string("prompt"), conversationID = optUuid("conversationID"),
        providerConfigurationID = optUuid("providerConfigurationID"), recurrenceRawValue = string("recurrenceRawValue"),
        statusRawValue = string("statusRawValue"), scheduledAt = date("scheduledAt"),
        timeZoneIdentifier = string("timeZoneIdentifier"), nextRunAt = optDate("nextRunAt"), lastRunAt = optDate("lastRunAt"),
        lastError = optString("lastError"), createdAt = date("createdAt"), updatedAt = date("updatedAt"),
      )
    }
  }
}

class PortableProviderConfiguration(
  val id: String,
  val displayName: String,
  val providerRawValue: String,
  val modelIdentifier: String,
  val baseURLString: String?,
  val contextWindowTokens: Int?,
  val maximumOutputTokens: Int?,
  val isEnabled: Boolean,
  val createdAt: PortableDate,
  val updatedAt: PortableDate,
) {
  fun toPJ() = pjObject {
    uuid("id", id); string("displayName", displayName); string("providerRawValue", providerRawValue)
    string("modelIdentifier", modelIdentifier); string("baseURLString", baseURLString)
    int("contextWindowTokens", contextWindowTokens); int("maximumOutputTokens", maximumOutputTokens)
    bool("isEnabled", isEnabled); date("createdAt", createdAt); date("updatedAt", updatedAt)
  }

  companion object {
    fun from(value: PJ) = PJFields.read(value, malformed) {
      PortableProviderConfiguration(
        id = uuid("id"), displayName = string("displayName"), providerRawValue = string("providerRawValue"),
        modelIdentifier = string("modelIdentifier"), baseURLString = optString("baseURLString"),
        contextWindowTokens = optInt("contextWindowTokens"), maximumOutputTokens = optInt("maximumOutputTokens"),
        isEnabled = bool("isEnabled"), createdAt = date("createdAt"), updatedAt = date("updatedAt"),
      )
    }
  }
}

class PortableEmbeddingProfile(
  val id: String,
  val displayName: String,
  val backendRawValue: String,
  val providerConfigurationID: String?,
  val modelIdentifier: String,
  val weight: Double,
  val isEnabled: Boolean,
  val indexesConversations: Boolean,
  val indexesDocuments: Boolean,
  val createdAt: PortableDate,
  val updatedAt: PortableDate,
) {
  fun toPJ() = pjObject {
    uuid("id", id); string("displayName", displayName); string("backendRawValue", backendRawValue)
    uuid("providerConfigurationID", providerConfigurationID); string("modelIdentifier", modelIdentifier)
    double("weight", weight); bool("isEnabled", isEnabled); bool("indexesConversations", indexesConversations)
    bool("indexesDocuments", indexesDocuments); date("createdAt", createdAt); date("updatedAt", updatedAt)
  }

  companion object {
    fun from(value: PJ) = PJFields.read(value, malformed) {
      PortableEmbeddingProfile(
        id = uuid("id"), displayName = string("displayName"), backendRawValue = string("backendRawValue"),
        providerConfigurationID = optUuid("providerConfigurationID"), modelIdentifier = string("modelIdentifier"),
        weight = double("weight"), isEnabled = bool("isEnabled"), indexesConversations = bool("indexesConversations"),
        indexesDocuments = bool("indexesDocuments"), createdAt = date("createdAt"), updatedAt = date("updatedAt"),
      )
    }
  }
}

class PortableImportedDocument(
  val id: String,
  val title: String,
  val sourceFilename: String,
  val mimeType: String,
  val contentFingerprint: String,
  val characterCount: Int,
  val pageCount: Int?,
  val ocrPageCount: Int,
  val ocrFallbackPageCount: Int,
  val isEnabled: Boolean,
  val createdAt: PortableDate,
  val updatedAt: PortableDate,
) {
  fun toPJ() = pjObject {
    uuid("id", id); string("title", title); string("sourceFilename", sourceFilename); string("mimeType", mimeType)
    string("contentFingerprint", contentFingerprint); int("characterCount", characterCount); int("pageCount", pageCount)
    int("ocrPageCount", ocrPageCount); int("ocrFallbackPageCount", ocrFallbackPageCount); bool("isEnabled", isEnabled)
    date("createdAt", createdAt); date("updatedAt", updatedAt)
  }

  companion object {
    fun from(value: PJ) = PJFields.read(value, malformed) {
      PortableImportedDocument(
        id = uuid("id"), title = string("title"), sourceFilename = string("sourceFilename"), mimeType = string("mimeType"),
        contentFingerprint = string("contentFingerprint"), characterCount = int("characterCount"), pageCount = optInt("pageCount"),
        ocrPageCount = int("ocrPageCount"), ocrFallbackPageCount = int("ocrFallbackPageCount"), isEnabled = bool("isEnabled"),
        createdAt = date("createdAt"), updatedAt = date("updatedAt"),
      )
    }
  }
}

class PortableDocumentChunk(
  val id: String,
  val documentID: String,
  val chunkIndex: Int,
  val content: String,
  val pageNumber: Int?,
  val isOCRDerived: Boolean,
  val createdAt: PortableDate,
) {
  fun toPJ() = pjObject {
    uuid("id", id); uuid("documentID", documentID); int("chunkIndex", chunkIndex); string("content", content)
    int("pageNumber", pageNumber); bool("isOCRDerived", isOCRDerived); date("createdAt", createdAt)
  }

  companion object {
    fun from(value: PJ) = PJFields.read(value, malformed) {
      PortableDocumentChunk(
        id = uuid("id"), documentID = uuid("documentID"), chunkIndex = int("chunkIndex"), content = string("content"),
        pageNumber = optInt("pageNumber"), isOCRDerived = bool("isOCRDerived"), createdAt = date("createdAt"),
      )
    }
  }
}

class PortableRequestContextEvent(
  val id: String,
  val eventKey: String,
  val assistantMessageID: String,
  val conversationID: String,
  val sourceThroughMessageID: String,
  val sourceMessageCount: Int,
  val eventSequence: Int,
  val payloadData: ByteArray,
  val payloadFingerprint: String,
  val legacyReceiptFingerprint: String?,
  val createdAt: PortableDate,
) {
  fun toPJ() = pjObject {
    uuid("id", id); string("eventKey", eventKey); uuid("assistantMessageID", assistantMessageID)
    uuid("conversationID", conversationID); uuid("sourceThroughMessageID", sourceThroughMessageID)
    int("sourceMessageCount", sourceMessageCount); int("eventSequence", eventSequence); data("payloadData", payloadData)
    string("payloadFingerprint", payloadFingerprint); string("legacyReceiptFingerprint", legacyReceiptFingerprint)
    date("createdAt", createdAt)
  }

  companion object {
    fun from(value: PJ) = PJFields.read(value, malformed) {
      PortableRequestContextEvent(
        id = uuid("id"), eventKey = string("eventKey"), assistantMessageID = uuid("assistantMessageID"),
        conversationID = uuid("conversationID"), sourceThroughMessageID = uuid("sourceThroughMessageID"),
        sourceMessageCount = int("sourceMessageCount"), eventSequence = int("eventSequence"), payloadData = data("payloadData"),
        payloadFingerprint = string("payloadFingerprint"), legacyReceiptFingerprint = optString("legacyReceiptFingerprint"),
        createdAt = date("createdAt"),
      )
    }
  }
}

class PortableCompactionArtifact(
  val id: String,
  val conversationID: String,
  val lineagePreviousCompactionID: String?,
  val coverageParentArtifactID: String?,
  val coverageDeltaData: ByteArray,
  val coveredMessageCount: Int,
  val modeRawValue: String,
  val promptVersion: String,
  val contentSchemaVersion: Int,
  val contentData: ByteArray?,
  val renderedSummary: String,
  val sourceFingerprint: String?,
  val providerConfigurationID: String?,
  val providerKindRawValue: String?,
  val providerDisplayName: String?,
  val providerEndpoint: String?,
  val modelIdentifier: String?,
  val providerMessageID: String?,
  val inputTokenCount: Int?,
  val outputTokenCount: Int?,
  val estimatedSourceTokens: Int,
  val estimatedSummaryTokens: Int,
  val chainDepth: Int,
  val warningsData: ByteArray,
  val isSnapshotComplete: Boolean,
  val isDetachedCoverageRoot: Boolean,
  val payloadFingerprint: String,
  val createdAt: PortableDate,
) {
  /** Every field except the fingerprint (iOS `CompactionArtifactIntegrityEnvelope`). */
  fun integrityPJ() = pjObject {
    uuid("id", id); uuid("conversationID", conversationID); uuid("lineagePreviousCompactionID", lineagePreviousCompactionID)
    uuid("coverageParentArtifactID", coverageParentArtifactID); data("coverageDeltaData", coverageDeltaData)
    int("coveredMessageCount", coveredMessageCount); string("modeRawValue", modeRawValue); string("promptVersion", promptVersion)
    int("contentSchemaVersion", contentSchemaVersion); data("contentData", contentData); string("renderedSummary", renderedSummary)
    string("sourceFingerprint", sourceFingerprint); uuid("providerConfigurationID", providerConfigurationID)
    string("providerKindRawValue", providerKindRawValue); string("providerDisplayName", providerDisplayName)
    string("providerEndpoint", providerEndpoint); string("modelIdentifier", modelIdentifier)
    string("providerMessageID", providerMessageID); int("inputTokenCount", inputTokenCount); int("outputTokenCount", outputTokenCount)
    int("estimatedSourceTokens", estimatedSourceTokens); int("estimatedSummaryTokens", estimatedSummaryTokens)
    int("chainDepth", chainDepth); data("warningsData", warningsData); bool("isSnapshotComplete", isSnapshotComplete)
    bool("isDetachedCoverageRoot", isDetachedCoverageRoot); date("createdAt", createdAt)
  }

  /** iOS `compactionArtifactFingerprint`: SHA-256 of the sorted-key envelope (slashes escaped). */
  fun computedFingerprint(): String = PortableHashes.sha256Hex(SwiftJsonWriter.encode(integrityPJ(), withoutEscapingSlashes = false))

  fun toPJ(): PJObject = PJObject(integrityPJ().fields + ("payloadFingerprint" to PJString(payloadFingerprint)))

  companion object {
    fun from(value: PJ) = PJFields.read(value, malformed) {
      PortableCompactionArtifact(
        id = uuid("id"), conversationID = uuid("conversationID"), lineagePreviousCompactionID = optUuid("lineagePreviousCompactionID"),
        coverageParentArtifactID = optUuid("coverageParentArtifactID"), coverageDeltaData = data("coverageDeltaData"),
        coveredMessageCount = int("coveredMessageCount"), modeRawValue = string("modeRawValue"), promptVersion = string("promptVersion"),
        contentSchemaVersion = int("contentSchemaVersion"), contentData = optData("contentData"),
        renderedSummary = string("renderedSummary"), sourceFingerprint = optString("sourceFingerprint"),
        providerConfigurationID = optUuid("providerConfigurationID"), providerKindRawValue = optString("providerKindRawValue"),
        providerDisplayName = optString("providerDisplayName"), providerEndpoint = optString("providerEndpoint"),
        modelIdentifier = optString("modelIdentifier"), providerMessageID = optString("providerMessageID"),
        inputTokenCount = optInt("inputTokenCount"), outputTokenCount = optInt("outputTokenCount"),
        estimatedSourceTokens = int("estimatedSourceTokens"), estimatedSummaryTokens = int("estimatedSummaryTokens"),
        chainDepth = int("chainDepth"), warningsData = data("warningsData"), isSnapshotComplete = bool("isSnapshotComplete"),
        isDetachedCoverageRoot = bool("isDetachedCoverageRoot"), payloadFingerprint = string("payloadFingerprint"),
        createdAt = date("createdAt"),
      )
    }
  }
}

class PortableCompactionHead(
  val conversationID: String,
  val activeArtifactID: String?,
  val revision: Int,
  val updatedAt: PortableDate,
) {
  fun toPJ() = pjObject {
    uuid("conversationID", conversationID); uuid("activeArtifactID", activeArtifactID); int("revision", revision)
    date("updatedAt", updatedAt)
  }

  companion object {
    fun from(value: PJ) = PJFields.read(value, malformed) {
      PortableCompactionHead(
        conversationID = uuid("conversationID"), activeArtifactID = optUuid("activeArtifactID"), revision = int("revision"),
        updatedAt = date("updatedAt"),
      )
    }
  }
}

class PortableBackfillProgress(
  val migrationKey: String,
  val lastEventKey: String?,
  val processedCount: Int,
  val migratedCount: Int,
  val retainedLegacyCount: Int,
  val failureCount: Int,
  val isComplete: Boolean,
  val updatedAt: PortableDate,
) {
  fun toPJ() = pjObject {
    string("migrationKey", migrationKey); string("lastEventKey", lastEventKey); int("processedCount", processedCount)
    int("migratedCount", migratedCount); int("retainedLegacyCount", retainedLegacyCount); int("failureCount", failureCount)
    bool("isComplete", isComplete); date("updatedAt", updatedAt)
  }

  companion object {
    fun from(value: PJ) = PJFields.read(value, malformed) {
      PortableBackfillProgress(
        migrationKey = string("migrationKey"), lastEventKey = optString("lastEventKey"), processedCount = int("processedCount"),
        migratedCount = int("migratedCount"), retainedLegacyCount = int("retainedLegacyCount"), failureCount = int("failureCount"),
        isComplete = bool("isComplete"), updatedAt = date("updatedAt"),
      )
    }
  }
}

/** Opaque extension envelope; its payload is decoded by the owning namespace. */
class PortableExtensionRecord(
  val namespace: String,
  val recordType: String,
  val recordVersion: Int,
  val id: String,
  val payload: ByteArray,
) {
  fun toPJ() = pjObject {
    string("namespace", namespace); string("recordType", recordType); int("recordVersion", recordVersion)
    uuid("id", id); data("payload", payload)
  }

  companion object {
    fun from(value: PJ) = PJFields.read(value, malformed) {
      PortableExtensionRecord(
        namespace = string("namespace"), recordType = string("recordType"), recordVersion = int("recordVersion"),
        id = uuid("id"), payload = data("payload"),
      )
    }

    /** iOS `extensionRecordOrder`: namespace, record type, then uppercase UUID text. */
    val ORDER: Comparator<PortableExtensionRecord> = compareBy<PortableExtensionRecord>({ it.namespace }, { it.recordType })
      .thenBy { PortableIds.toPortable(it.id) }
  }
}

/** Every collection of one snapshot, in memory. */
class PortableSnapshot(
  val backupID: String,
  val createdAt: PortableDate,
  val sourceSchemaVersion: String,
  val conversations: List<PortableConversation>,
  val messages: List<PortableMessage>,
  val memories: List<PortableMemory>,
  val scheduledTasks: List<PortableScheduledTask>,
  val providerConfigurations: List<PortableProviderConfiguration>,
  val embeddingProfiles: List<PortableEmbeddingProfile>,
  val importedDocuments: List<PortableImportedDocument>,
  val documentChunks: List<PortableDocumentChunk>,
  val requestContextEvents: List<PortableRequestContextEvent>,
  val compactionArtifacts: List<PortableCompactionArtifact>,
  val conversationCompactionHeads: List<PortableCompactionHead>,
  val normalizedBackfillProgress: List<PortableBackfillProgress>,
  val extensions: PortableExtensions,
) {
  val recordCount: Long
    get() = listOf(
      conversations.size, messages.size, memories.size, scheduledTasks.size, providerConfigurations.size,
      embeddingProfiles.size, importedDocuments.size, documentChunks.size, requestContextEvents.size,
      compactionArtifacts.size, conversationCompactionHeads.size, normalizedBackfillProgress.size,
    ).sumOf { it.toLong() } + extensions.recordCount
}

/** Uppercase-UUID order used by iOS `idOrder`. */
fun <T> portableIdOrder(id: (T) -> String): Comparator<T> = compareBy { PortableIds.toPortable(id(it)) }

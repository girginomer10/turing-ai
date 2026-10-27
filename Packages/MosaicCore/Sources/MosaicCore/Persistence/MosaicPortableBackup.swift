import CryptoKit
import Foundation
import SwiftData

public struct MosaicPortableBackupLimits: Hashable, Sendable {
  public var maximumTotalBytes: Int
  public var maximumRecordBytes: Int
  public var maximumRecordCount: Int

  public init(
    // Version 1 is intentionally still a bounded, in-memory JSON envelope. The original 64 MiB
    // ceiling could reject an otherwise valid library after ordinary document growth, well before
    // any per-document ingestion limit was reached. 256 MiB leaves meaningful headroom while
    // retaining a finite peak-memory and untrusted-input boundary on supported iPhones and Macs.
    maximumTotalBytes: Int = 256 * 1_024 * 1_024,
    maximumRecordBytes: Int = 8 * 1_024 * 1_024,
    maximumRecordCount: Int = 1_000_000
  ) {
    self.maximumTotalBytes = max(1, maximumTotalBytes)
    self.maximumRecordBytes = max(1, maximumRecordBytes)
    self.maximumRecordCount = max(1, maximumRecordCount)
  }

  public static let `default` = MosaicPortableBackupLimits()
}

public enum MosaicPortableBackupError: Error, Equatable, Sendable {
  case malformedEnvelope
  case unsupportedFormat(String)
  case unsupportedFormatVersion(found: Int, supported: Int)
  case readerTooOld(required: Int, current: Int)
  case backupTooLarge(actual: Int, maximum: Int)
  case recordTooLarge(recordType: String, id: UUID, actual: Int, maximum: Int)
  case tooManyRecords(actual: Int, maximum: Int)
  case checksumMismatch
  case duplicateID(recordType: String, id: UUID)
  case duplicateKey(recordType: String, key: String)
  case missingConversation(messageID: UUID, conversationID: UUID)
  case missingDocument(chunkID: UUID, documentID: UUID)
  case missingNormalizedReference(recordType: String, id: UUID, field: String, targetID: UUID)
  case invalidNormalizedInvariant(recordType: String, id: UUID, field: String)
  case normalizedReferenceCycle(recordType: String, id: UUID)
  case normalizedFingerprintMismatch(recordType: String, id: UUID)
  case unsupportedExtensionRecord(namespace: String, recordType: String, version: Int)
  case invalidNumber(recordType: String, id: UUID, field: String)
  case stagingVerificationFailed
  case liveContextHasUnsavedChanges
  case persistenceFailure
  case liveStoreRecoveryFailed
}

extension MosaicPortableBackupError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .malformedEnvelope:
      "The selected file is not a valid Turing AI backup."
    case .unsupportedFormat:
      "The selected file uses a different backup format."
    case .unsupportedFormatVersion(let found, let supported):
      "This backup uses format version \(found), but this version of Turing AI supports up to \(supported)."
    case .readerTooOld(let required, let current):
      "This backup requires reader version \(required); this version of Turing AI provides \(current)."
    case .backupTooLarge:
      "This backup or local library is larger than Turing AI can process safely in one operation."
    case .recordTooLarge(let recordType, _, _, _):
      "A \(recordType) record is larger than the configured safety limit."
    case .tooManyRecords:
      "This backup or local library contains more records than Turing AI can process safely in one operation."
    case .checksumMismatch:
      "The backup checksum does not match its contents."
    case .duplicateID(let recordType, _):
      "The backup contains a duplicate \(recordType) identifier."
    case .duplicateKey(let recordType, _):
      "The backup contains a duplicate \(recordType) key."
    case .missingConversation:
      "A message in the backup points to a missing conversation."
    case .missingDocument:
      "A document chunk in the backup points to a missing document."
    case .missingNormalizedReference(let recordType, _, let field, _):
      "A \(recordType) record points to a missing \(field) record."
    case .invalidNormalizedInvariant(let recordType, _, let field):
      "A \(recordType) record contains an invalid \(field) value."
    case .normalizedReferenceCycle(let recordType, _):
      "The backup contains a cycle in its \(recordType) references."
    case .normalizedFingerprintMismatch(let recordType, _):
      "A \(recordType) record failed its payload fingerprint check."
    case .unsupportedExtensionRecord:
      "This backup contains an extension record that this version of Turing AI cannot restore."
    case .invalidNumber(let recordType, _, let field):
      "A \(recordType) record contains an invalid \(field) value."
    case .stagingVerificationFailed:
      "Turing AI could not verify the restored data in its staging store."
    case .liveContextHasUnsavedChanges:
      "Save or discard current changes before replacing the local library."
    case .persistenceFailure:
      "Turing AI could not replace the local library."
    case .liveStoreRecoveryFailed:
      "Turing AI could not verify either complete local library generation. Normal changes are blocked until you restore a valid backup."
    }
  }
}

public struct MosaicPortableConversation: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let title: String
  public let providerConfigurationID: UUID?
  public let modelIdentifier: String
  public let systemPrompt: String?
  public let draftText: String
  public let compactionSnapshotData: Data?
  public let isArchived: Bool
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: UUID,
    title: String,
    providerConfigurationID: UUID?,
    modelIdentifier: String,
    systemPrompt: String?,
    draftText: String,
    compactionSnapshotData: Data?,
    isArchived: Bool,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.title = title
    self.providerConfigurationID = providerConfigurationID
    self.modelIdentifier = modelIdentifier
    self.systemPrompt = systemPrompt
    self.draftText = draftText
    self.compactionSnapshotData = compactionSnapshotData
    self.isArchived = isArchived
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct MosaicPortableMessage: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let conversationID: UUID
  public let roleRawValue: String
  public let content: String
  public let statusRawValue: String
  public let providerConfigurationID: UUID?
  public let providerKindRawValue: String?
  public let providerDisplayName: String?
  public let providerHost: String?
  public let providerMessageID: String?
  public let modelIdentifier: String?
  public let inputTokenCount: Int?
  public let outputTokenCount: Int?
  public let errorDescription: String?
  public let contextReceiptData: Data?
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: UUID,
    conversationID: UUID,
    roleRawValue: String,
    content: String,
    statusRawValue: String,
    providerConfigurationID: UUID?,
    providerKindRawValue: String?,
    providerDisplayName: String?,
    providerHost: String?,
    providerMessageID: String?,
    modelIdentifier: String?,
    inputTokenCount: Int?,
    outputTokenCount: Int?,
    errorDescription: String?,
    contextReceiptData: Data?,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.conversationID = conversationID
    self.roleRawValue = roleRawValue
    self.content = content
    self.statusRawValue = statusRawValue
    self.providerConfigurationID = providerConfigurationID
    self.providerKindRawValue = providerKindRawValue
    self.providerDisplayName = providerDisplayName
    self.providerHost = providerHost
    self.providerMessageID = providerMessageID
    self.modelIdentifier = modelIdentifier
    self.inputTokenCount = inputTokenCount
    self.outputTokenCount = outputTokenCount
    self.errorDescription = errorDescription
    self.contextReceiptData = contextReceiptData
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct MosaicPortableMemory: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let title: String
  public let content: String
  public let scopeRawValue: String
  public let conversationID: UUID?
  public let isEnabled: Bool
  public let isUserApproved: Bool
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: UUID,
    title: String,
    content: String,
    scopeRawValue: String,
    conversationID: UUID?,
    isEnabled: Bool,
    isUserApproved: Bool,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.title = title
    self.content = content
    self.scopeRawValue = scopeRawValue
    self.conversationID = conversationID
    self.isEnabled = isEnabled
    self.isUserApproved = isUserApproved
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct MosaicPortableScheduledTask: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let title: String
  public let prompt: String
  public let conversationID: UUID?
  public let providerConfigurationID: UUID?
  public let recurrenceRawValue: String
  public let statusRawValue: String
  public let scheduledAt: Date
  public let timeZoneIdentifier: String
  public let nextRunAt: Date?
  public let lastRunAt: Date?
  public let lastError: String?
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: UUID,
    title: String,
    prompt: String,
    conversationID: UUID?,
    providerConfigurationID: UUID?,
    recurrenceRawValue: String,
    statusRawValue: String,
    scheduledAt: Date,
    timeZoneIdentifier: String,
    nextRunAt: Date?,
    lastRunAt: Date?,
    lastError: String?,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.title = title
    self.prompt = prompt
    self.conversationID = conversationID
    self.providerConfigurationID = providerConfigurationID
    self.recurrenceRawValue = recurrenceRawValue
    self.statusRawValue = statusRawValue
    self.scheduledAt = scheduledAt
    self.timeZoneIdentifier = timeZoneIdentifier
    self.nextRunAt = nextRunAt
    self.lastRunAt = lastRunAt
    self.lastError = lastError
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct MosaicPortableProviderConfiguration: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let displayName: String
  public let providerRawValue: String
  public let modelIdentifier: String
  public let baseURLString: String?
  public let contextWindowTokens: Int?
  public let maximumOutputTokens: Int?
  public let isEnabled: Bool
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: UUID,
    displayName: String,
    providerRawValue: String,
    modelIdentifier: String,
    baseURLString: String?,
    contextWindowTokens: Int?,
    maximumOutputTokens: Int?,
    isEnabled: Bool,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.displayName = displayName
    self.providerRawValue = providerRawValue
    self.modelIdentifier = modelIdentifier
    self.baseURLString = baseURLString
    self.contextWindowTokens = contextWindowTokens
    self.maximumOutputTokens = maximumOutputTokens
    self.isEnabled = isEnabled
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct MosaicPortableEmbeddingProfile: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let displayName: String
  public let backendRawValue: String
  public let providerConfigurationID: UUID?
  public let modelIdentifier: String
  public let weight: Double
  public let isEnabled: Bool
  public let indexesConversations: Bool
  public let indexesDocuments: Bool
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: UUID,
    displayName: String,
    backendRawValue: String,
    providerConfigurationID: UUID?,
    modelIdentifier: String,
    weight: Double,
    isEnabled: Bool,
    indexesConversations: Bool,
    indexesDocuments: Bool,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.displayName = displayName
    self.backendRawValue = backendRawValue
    self.providerConfigurationID = providerConfigurationID
    self.modelIdentifier = modelIdentifier
    self.weight = weight
    self.isEnabled = isEnabled
    self.indexesConversations = indexesConversations
    self.indexesDocuments = indexesDocuments
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct MosaicPortableImportedDocument: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let title: String
  public let sourceFilename: String
  public let mimeType: String
  public let contentFingerprint: String
  public let characterCount: Int
  public let pageCount: Int?
  public let ocrPageCount: Int
  public let ocrFallbackPageCount: Int
  public let isEnabled: Bool
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: UUID,
    title: String,
    sourceFilename: String,
    mimeType: String,
    contentFingerprint: String,
    characterCount: Int,
    pageCount: Int?,
    ocrPageCount: Int,
    ocrFallbackPageCount: Int,
    isEnabled: Bool,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.title = title
    self.sourceFilename = sourceFilename
    self.mimeType = mimeType
    self.contentFingerprint = contentFingerprint
    self.characterCount = characterCount
    self.pageCount = pageCount
    self.ocrPageCount = ocrPageCount
    self.ocrFallbackPageCount = ocrFallbackPageCount
    self.isEnabled = isEnabled
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct MosaicPortableDocumentChunk: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let documentID: UUID
  public let chunkIndex: Int
  public let content: String
  public let pageNumber: Int?
  public let isOCRDerived: Bool
  public let createdAt: Date

  public init(
    id: UUID,
    documentID: UUID,
    chunkIndex: Int,
    content: String,
    pageNumber: Int?,
    isOCRDerived: Bool,
    createdAt: Date
  ) {
    self.id = id
    self.documentID = documentID
    self.chunkIndex = chunkIndex
    self.content = content
    self.pageNumber = pageNumber
    self.isOCRDerived = isOCRDerived
    self.createdAt = createdAt
  }
}

public struct MosaicPortableRequestContextEvent: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let eventKey: String
  public let assistantMessageID: UUID
  public let conversationID: UUID
  public let sourceThroughMessageID: UUID
  public let sourceMessageCount: Int
  public let eventSequence: Int
  public let payloadData: Data
  public let payloadFingerprint: String
  public let legacyReceiptFingerprint: String?
  public let createdAt: Date

  public init(
    id: UUID,
    eventKey: String,
    assistantMessageID: UUID,
    conversationID: UUID,
    sourceThroughMessageID: UUID,
    sourceMessageCount: Int,
    eventSequence: Int,
    payloadData: Data,
    payloadFingerprint: String,
    legacyReceiptFingerprint: String?,
    createdAt: Date
  ) {
    self.id = id
    self.eventKey = eventKey
    self.assistantMessageID = assistantMessageID
    self.conversationID = conversationID
    self.sourceThroughMessageID = sourceThroughMessageID
    self.sourceMessageCount = sourceMessageCount
    self.eventSequence = eventSequence
    self.payloadData = payloadData
    self.payloadFingerprint = payloadFingerprint
    self.legacyReceiptFingerprint = legacyReceiptFingerprint
    self.createdAt = createdAt
  }
}

public struct MosaicPortableCompactionArtifact: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let conversationID: UUID
  public let lineagePreviousCompactionID: UUID?
  public let coverageParentArtifactID: UUID?
  public let coverageDeltaData: Data
  public let coveredMessageCount: Int
  public let modeRawValue: String
  public let promptVersion: String
  public let contentSchemaVersion: Int
  public let contentData: Data?
  public let renderedSummary: String
  public let sourceFingerprint: String?
  public let providerConfigurationID: UUID?
  public let providerKindRawValue: String?
  public let providerDisplayName: String?
  public let providerEndpoint: String?
  public let modelIdentifier: String?
  public let providerMessageID: String?
  public let inputTokenCount: Int?
  public let outputTokenCount: Int?
  public let estimatedSourceTokens: Int
  public let estimatedSummaryTokens: Int
  public let chainDepth: Int
  public let warningsData: Data
  public let isSnapshotComplete: Bool
  public let isDetachedCoverageRoot: Bool
  public let payloadFingerprint: String
  public let createdAt: Date

  public init(
    id: UUID,
    conversationID: UUID,
    lineagePreviousCompactionID: UUID?,
    coverageParentArtifactID: UUID?,
    coverageDeltaData: Data,
    coveredMessageCount: Int,
    modeRawValue: String,
    promptVersion: String,
    contentSchemaVersion: Int,
    contentData: Data?,
    renderedSummary: String,
    sourceFingerprint: String?,
    providerConfigurationID: UUID?,
    providerKindRawValue: String?,
    providerDisplayName: String?,
    providerEndpoint: String?,
    modelIdentifier: String?,
    providerMessageID: String?,
    inputTokenCount: Int?,
    outputTokenCount: Int?,
    estimatedSourceTokens: Int,
    estimatedSummaryTokens: Int,
    chainDepth: Int,
    warningsData: Data,
    isSnapshotComplete: Bool,
    isDetachedCoverageRoot: Bool,
    payloadFingerprint: String,
    createdAt: Date
  ) {
    self.id = id
    self.conversationID = conversationID
    self.lineagePreviousCompactionID = lineagePreviousCompactionID
    self.coverageParentArtifactID = coverageParentArtifactID
    self.coverageDeltaData = coverageDeltaData
    self.coveredMessageCount = coveredMessageCount
    self.modeRawValue = modeRawValue
    self.promptVersion = promptVersion
    self.contentSchemaVersion = contentSchemaVersion
    self.contentData = contentData
    self.renderedSummary = renderedSummary
    self.sourceFingerprint = sourceFingerprint
    self.providerConfigurationID = providerConfigurationID
    self.providerKindRawValue = providerKindRawValue
    self.providerDisplayName = providerDisplayName
    self.providerEndpoint = providerEndpoint
    self.modelIdentifier = modelIdentifier
    self.providerMessageID = providerMessageID
    self.inputTokenCount = inputTokenCount
    self.outputTokenCount = outputTokenCount
    self.estimatedSourceTokens = estimatedSourceTokens
    self.estimatedSummaryTokens = estimatedSummaryTokens
    self.chainDepth = chainDepth
    self.warningsData = warningsData
    self.isSnapshotComplete = isSnapshotComplete
    self.isDetachedCoverageRoot = isDetachedCoverageRoot
    self.payloadFingerprint = payloadFingerprint
    self.createdAt = createdAt
  }
}

public struct MosaicPortableConversationCompactionHead: Codable, Hashable, Identifiable, Sendable {
  public let conversationID: UUID
  public let activeArtifactID: UUID?
  public let revision: Int
  public let updatedAt: Date

  public var id: UUID { conversationID }

  public init(
    conversationID: UUID,
    activeArtifactID: UUID?,
    revision: Int,
    updatedAt: Date
  ) {
    self.conversationID = conversationID
    self.activeArtifactID = activeArtifactID
    self.revision = revision
    self.updatedAt = updatedAt
  }
}

public struct MosaicPortableNormalizedContextBackfillProgress: Codable, Hashable, Sendable {
  public let migrationKey: String
  public let lastEventKey: String?
  public let processedCount: Int
  public let migratedCount: Int
  public let retainedLegacyCount: Int
  public let failureCount: Int
  public let isComplete: Bool
  public let updatedAt: Date

  public init(
    migrationKey: String,
    lastEventKey: String?,
    processedCount: Int,
    migratedCount: Int,
    retainedLegacyCount: Int,
    failureCount: Int,
    isComplete: Bool,
    updatedAt: Date
  ) {
    self.migrationKey = migrationKey
    self.lastEventKey = lastEventKey
    self.processedCount = processedCount
    self.migratedCount = migratedCount
    self.retainedLegacyCount = retainedLegacyCount
    self.failureCount = failureCount
    self.isComplete = isComplete
    self.updatedAt = updatedAt
  }
}

/// Extension records let future normalized stores join the portable envelope without changing
/// the format's integrity or size-validation rules. Their payload is intentionally opaque here.
public struct MosaicPortableExtensionRecord: Codable, Hashable, Identifiable, Sendable {
  public let namespace: String
  public let recordType: String
  public let recordVersion: Int
  public let id: UUID
  public let payload: Data

  public init(
    namespace: String,
    recordType: String,
    recordVersion: Int,
    id: UUID,
    payload: Data
  ) {
    self.namespace = namespace
    self.recordType = recordType
    self.recordVersion = recordVersion
    self.id = id
    self.payload = payload
  }
}

public struct MosaicPortableBackupSnapshot: Codable, Hashable, Sendable {
  public let backupID: UUID
  public let createdAt: Date
  public let sourceSchemaVersion: String
  public let conversations: [MosaicPortableConversation]
  public let messages: [MosaicPortableMessage]
  public let memories: [MosaicPortableMemory]
  public let scheduledTasks: [MosaicPortableScheduledTask]
  public let providerConfigurations: [MosaicPortableProviderConfiguration]
  public let embeddingProfiles: [MosaicPortableEmbeddingProfile]
  public let importedDocuments: [MosaicPortableImportedDocument]
  public let documentChunks: [MosaicPortableDocumentChunk]
  public let requestContextEvents: [MosaicPortableRequestContextEvent]
  public let compactionArtifacts: [MosaicPortableCompactionArtifact]
  public let conversationCompactionHeads: [MosaicPortableConversationCompactionHead]
  public let normalizedBackfillProgress: [MosaicPortableNormalizedContextBackfillProgress]
  public let extensionRecords: [MosaicPortableExtensionRecord]

  public init(
    backupID: UUID,
    createdAt: Date,
    sourceSchemaVersion: String,
    conversations: [MosaicPortableConversation],
    messages: [MosaicPortableMessage],
    memories: [MosaicPortableMemory],
    scheduledTasks: [MosaicPortableScheduledTask],
    providerConfigurations: [MosaicPortableProviderConfiguration],
    embeddingProfiles: [MosaicPortableEmbeddingProfile],
    importedDocuments: [MosaicPortableImportedDocument],
    documentChunks: [MosaicPortableDocumentChunk],
    requestContextEvents: [MosaicPortableRequestContextEvent] = [],
    compactionArtifacts: [MosaicPortableCompactionArtifact] = [],
    conversationCompactionHeads: [MosaicPortableConversationCompactionHead] = [],
    normalizedBackfillProgress: [MosaicPortableNormalizedContextBackfillProgress] = [],
    extensionRecords: [MosaicPortableExtensionRecord] = []
  ) {
    self.backupID = backupID
    self.createdAt = createdAt
    self.sourceSchemaVersion = sourceSchemaVersion
    self.conversations = conversations
    self.messages = messages
    self.memories = memories
    self.scheduledTasks = scheduledTasks
    self.providerConfigurations = providerConfigurations
    self.embeddingProfiles = embeddingProfiles
    self.importedDocuments = importedDocuments
    self.documentChunks = documentChunks
    self.requestContextEvents = requestContextEvents
    self.compactionArtifacts = compactionArtifacts
    self.conversationCompactionHeads = conversationCompactionHeads
    self.normalizedBackfillProgress = normalizedBackfillProgress
    self.extensionRecords = extensionRecords
  }
}

public struct MosaicPortableBackupEnvelope: Codable, Hashable, Sendable {
  public let formatIdentifier: String
  public let formatVersion: Int
  public let minimumReaderVersion: Int
  public let credentialsIncluded: Bool
  public let semanticVectorsIncluded: Bool
  public let snapshot: MosaicPortableBackupSnapshot
  public let checksumSHA256: String
}

public struct MosaicPortableRestorePlan: Hashable, Sendable {
  public let backupID: UUID
  public let snapshot: MosaicPortableBackupSnapshot
  public let providerIDMap: [UUID: UUID]
  fileprivate let limits: MosaicPortableBackupLimits
}

/// Owns a private SwiftData context on a serial executor so large backup scans, staging imports,
/// and live replacements never monopolize the UI actor. Only immutable portable values cross this
/// boundary.
@ModelActor
private actor MosaicPortableBackupRepository {
  func captureSnapshot(
    backupID: UUID,
    createdAt: Date,
    extensionRecords: [MosaicPortableExtensionRecord],
    limits: MosaicPortableBackupLimits
  ) throws -> MosaicPortableBackupSnapshot {
    try Task.checkCancellation()
    return try MosaicPortableBackup.captureSnapshotRecords(
      from: modelContext,
      backupID: backupID,
      createdAt: createdAt,
      extensionRecords: extensionRecords,
      limits: limits,
      includesPendingChanges: false
    )
  }

  func verifyRestore(_ plan: MosaicPortableRestorePlan) throws {
    try Task.checkCancellation()
    try MosaicPortableBackup.verifyRestoredContents(plan, in: modelContext)
  }

  func replaceLiveStore(
    using plan: MosaicPortableRestorePlan,
    requiresCompensation: Bool
  ) throws {
    try Task.checkCancellation()
    try MosaicPortableBackup.replaceStoreContents(
      using: plan,
      in: modelContext,
      beforeSave: {},
      requiresCompensation: requiresCompensation
    )
  }
}

public enum MosaicPortableBackup {
  public static let formatIdentifier = "com.omergirgin.mosaic.backup"
  public static let currentFormatVersion = 1
  public static let currentReaderVersion = 1
  public static let sourceSchemaVersion = "mosaic-main-6"
  private static let maximumCompactionCoverageDepth = 1_024

  @MainActor
  public static func export(
    from modelContext: ModelContext,
    backupID: UUID = UUID(),
    createdAt: Date = .now,
    extensionRecords: [MosaicPortableExtensionRecord] = [],
    limits: MosaicPortableBackupLimits = .default
  ) throws -> Data {
    try encode(
      snapshot: captureSnapshot(
        from: modelContext,
        backupID: backupID,
        createdAt: createdAt,
        extensionRecords: extensionRecords,
        limits: limits
      ),
      limits: limits
    )
  }

  /// Captures only source-of-truth records on the main actor. Encoding, hashing, and size
  /// validation can then run on any executor through `encode(snapshot:limits:)`.
  @MainActor
  public static func captureSnapshot(
    from modelContext: ModelContext,
    backupID: UUID = UUID(),
    createdAt: Date = .now,
    extensionRecords: [MosaicPortableExtensionRecord] = [],
    limits: MosaicPortableBackupLimits = .default
  ) throws -> MosaicPortableBackupSnapshot {
    try captureSnapshotRecords(
      from: modelContext,
      backupID: backupID,
      createdAt: createdAt,
      extensionRecords: extensionRecords,
      limits: limits,
      includesPendingChanges: true
    )
  }

  /// Flushes validated pending UI edits, then captures committed source records through a
  /// dedicated SwiftData model actor. The caller must hold the coordinator's verified snapshot
  /// maintenance lease across this call so no other source writer can interleave with the scan.
  @MainActor
  public static func captureSnapshotAsync(
    from modelContext: ModelContext,
    backupID: UUID = UUID(),
    createdAt: Date = .now,
    extensionRecords: [MosaicPortableExtensionRecord] = [],
    limits: MosaicPortableBackupLimits = .default
  ) async throws -> MosaicPortableBackupSnapshot {
    try MosaicOperationCoordinator.shared.flushSourceChangesForVerifiedSnapshot(in: modelContext)
    try Task.checkCancellation()
    let container = modelContext.container
    let repository = await Task.detached {
      MosaicPortableBackupRepository(modelContainer: container)
    }.value
    return try await repository.captureSnapshot(
      backupID: backupID,
      createdAt: createdAt,
      extensionRecords: extensionRecords,
      limits: limits
    )
  }

  /// Optimistic periodic-sync read: reserve against replacement, but allow normal UI work.
  /// Any concurrent writer invalidates the result instead of making the user wait for the scan.
  @MainActor
  static func captureBackgroundSyncSnapshot(
    from context: ModelContext, coordinator: MosaicOperationCoordinator = .shared
  ) async throws
    -> (snapshot: MosaicPortableBackupSnapshot, revision: UInt64)?
  {
    guard !coordinator.isSourceAccessBlocked, coordinator.activeOperations.isEmpty else {
      return nil
    }
    if context.hasChanges { try coordinator.saveSourceChanges(in: context) }
    guard coordinator.begin(.librarySnapshot) else { return nil }
    defer { coordinator.end(.librarySnapshot) }
    let revision = coordinator.sourceActivityRevision
    let container = context.container
    let worker = Task.detached(priority: .utility) {
      let repository = MosaicPortableBackupRepository(modelContainer: container)
      return try await repository.captureSnapshot(
        backupID: UUID(), createdAt: .now, extensionRecords: [], limits: .default)
    }
    let snapshot = try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
    try Task.checkCancellation()
    guard coordinator.sourceActivityRevision == revision, !context.hasChanges else { return nil }
    return (snapshot, revision)
  }

  /// Convenience surface that releases the main actor before encoding and hashing a large backup.
  @MainActor
  public static func exportAsync(
    from modelContext: ModelContext,
    backupID: UUID = UUID(),
    createdAt: Date = .now,
    extensionRecords: [MosaicPortableExtensionRecord] = [],
    limits: MosaicPortableBackupLimits = .default
  ) async throws -> Data {
    let snapshot = try await captureSnapshotAsync(
      from: modelContext,
      backupID: backupID,
      createdAt: createdAt,
      extensionRecords: extensionRecords,
      limits: limits
    )
    let worker = Task.detached(priority: .userInitiated) {
      try encode(snapshot: snapshot, limits: limits)
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  public static func encode(
    snapshot: MosaicPortableBackupSnapshot,
    limits: MosaicPortableBackupLimits = .default
  ) throws -> Data {
    try validate(snapshot: snapshot, limits: limits)
    return try encodeUnchecked(snapshot: snapshot, limits: limits)
  }

  public static func decode(
    _ data: Data,
    limits: MosaicPortableBackupLimits = .default
  ) throws -> MosaicPortableBackupSnapshot {
    guard data.count <= limits.maximumTotalBytes else {
      throw MosaicPortableBackupError.backupTooLarge(
        actual: data.count,
        maximum: limits.maximumTotalBytes
      )
    }

    let envelope: MosaicPortableBackupEnvelope
    do {
      envelope = try decoder.decode(MosaicPortableBackupEnvelope.self, from: data)
    } catch {
      throw MosaicPortableBackupError.malformedEnvelope
    }

    guard envelope.formatIdentifier == formatIdentifier else {
      throw MosaicPortableBackupError.unsupportedFormat(envelope.formatIdentifier)
    }
    guard envelope.formatVersion <= currentFormatVersion else {
      throw MosaicPortableBackupError.unsupportedFormatVersion(
        found: envelope.formatVersion,
        supported: currentFormatVersion
      )
    }
    guard envelope.formatVersion >= 1 else {
      throw MosaicPortableBackupError.unsupportedFormatVersion(
        found: envelope.formatVersion,
        supported: currentFormatVersion
      )
    }
    guard envelope.minimumReaderVersion <= currentReaderVersion else {
      throw MosaicPortableBackupError.readerTooOld(
        required: envelope.minimumReaderVersion,
        current: currentReaderVersion
      )
    }
    guard !envelope.credentialsIncluded, !envelope.semanticVectorsIncluded else {
      throw MosaicPortableBackupError.malformedEnvelope
    }

    let body = IntegrityBody(
      formatIdentifier: envelope.formatIdentifier,
      formatVersion: envelope.formatVersion,
      minimumReaderVersion: envelope.minimumReaderVersion,
      credentialsIncluded: envelope.credentialsIncluded,
      semanticVectorsIncluded: envelope.semanticVectorsIncluded,
      snapshot: envelope.snapshot
    )
    guard try checksum(for: body) == envelope.checksumSHA256 else {
      throw MosaicPortableBackupError.checksumMismatch
    }
    try validate(snapshot: envelope.snapshot, limits: limits)
    return envelope.snapshot
  }

  @MainActor
  public static func prepareRestore(
    from data: Data,
    limits: MosaicPortableBackupLimits = .default
  ) throws -> MosaicPortableRestorePlan {
    let decoded = try decode(data, limits: limits)
    let transformed = try transformForRestore(decoded, limits: limits)
    try verifyInStagingStore(transformed)
    return transformed
  }

  /// Decodes, hashes, validates, transforms, stages, and fetch-verifies without monopolizing the
  /// main actor. Creating the isolated in-memory container is the only main-actor hop.
  public static func prepareRestoreAsync(
    from data: Data,
    limits: MosaicPortableBackupLimits = .default
  ) async throws -> MosaicPortableRestorePlan {
    let worker = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      return try transformForRestore(try decode(data, limits: limits), limits: limits)
    }
    return try await withTaskCancellationHandler {
      let transformed = try await worker.value
      try Task.checkCancellation()
      let stagingContainer = try await MainActor.run {
        try MosaicSchema.makeModelContainer(inMemory: true)
      }
      let repository = MosaicPortableBackupRepository(modelContainer: stagingContainer)
      try await repository.verifyRestore(transformed)
      try Task.checkCancellation()
      return transformed
    } onCancel: {
      worker.cancel()
    }
  }

  /// iCloud already uses stable source IDs; unlike manual import, never rekey credentials.
  static func prepareSyncAsync(snapshot: MosaicPortableBackupSnapshot) async throws
    -> MosaicPortableRestorePlan
  {
    try validate(snapshot: snapshot, limits: .default)
    let plan = MosaicPortableRestorePlan(
      backupID: snapshot.backupID, snapshot: sorted(snapshot),
      providerIDMap: Dictionary(
        uniqueKeysWithValues: snapshot.providerConfigurations.map { ($0.id, $0.id) }),
      limits: .default)
    let staging = try await MosaicSchema.makeModelContainer(inMemory: true)
    try await MosaicPortableBackupRepository(modelContainer: staging).verifyRestore(plan)
    return plan
  }

  @MainActor
  private static func verifyInStagingStore(
    _ plan: MosaicPortableRestorePlan
  ) throws {
    let stagingContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let stagingContext = ModelContext(stagingContainer)
    try verifyRestoredContents(plan, in: stagingContext)
  }

  fileprivate static func verifyRestoredContents(
    _ plan: MosaicPortableRestorePlan,
    in stagingContext: ModelContext
  ) throws {
    if let unsupported = plan.snapshot.extensionRecords.first(where: {
      !isSupportedExtensionRecord($0)
    }) {
      throw MosaicPortableBackupError.unsupportedExtensionRecord(
        namespace: unsupported.namespace,
        recordType: unsupported.recordType,
        version: unsupported.recordVersion
      )
    }
    do {
      try insert(plan.snapshot, into: stagingContext)
      try stagingContext.save()
      let canonicalMessagesByConversation = Dictionary(
        grouping: plan.snapshot.messages.filter {
          $0.statusRawValue == MessageStatus.complete.rawValue
            && ($0.roleRawValue == MessageRole.user.rawValue
              || $0.roleRawValue == MessageRole.assistant.rawValue)
        },
        by: \.conversationID
      ).mapValues { records in
        records.sorted { lhs, rhs in
          if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
          let lhsRoleRank = lhs.roleRawValue == MessageRole.user.rawValue ? 0 : 1
          let rhsRoleRank = rhs.roleRawValue == MessageRole.user.rawValue ? 0 : 1
          if lhsRoleRank != rhsRoleRank { return lhsRoleRank < rhsRoleRank }
          return lhs.id.uuidString < rhs.id.uuidString
        }
      }
      let canonicalIndicesByConversation = canonicalMessagesByConversation.mapValues { records in
        Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) })
      }
      let restoreArtifactsByID = Dictionary(
        uniqueKeysWithValues: plan.snapshot.compactionArtifacts.map { artifact in
          (
            artifact.id,
            NormalizedRestoreCompactionArtifact(
              conversationID: artifact.conversationID,
              coveredMessageCount: artifact.coveredMessageCount,
              providerConfigurationID: artifact.providerConfigurationID,
              providerKindRawValue: artifact.providerKindRawValue,
              providerDisplayName: artifact.providerDisplayName,
              providerEndpoint: artifact.providerEndpoint,
              modelIdentifier: artifact.modelIdentifier
            )
          )
        }
      )
      let portableArtifactsByID = Dictionary(
        uniqueKeysWithValues: plan.snapshot.compactionArtifacts.map { ($0.id, $0) }
      )
      for event in plan.snapshot.requestContextEvents {
        try NormalizedContextStore.validateRequestEventForRestore(
          event: NormalizedRestoreRequestEvent(
            id: event.id,
            eventKey: event.eventKey,
            assistantMessageID: event.assistantMessageID,
            conversationID: event.conversationID,
            sourceThroughMessageID: event.sourceThroughMessageID,
            sourceMessageCount: event.sourceMessageCount,
            eventSequence: event.eventSequence,
            payloadData: event.payloadData,
            payloadFingerprint: event.payloadFingerprint
          ),
          canonicalMessageIndices: canonicalIndicesByConversation[event.conversationID] ?? [:]
        ) { artifactID in
          guard let artifact = restoreArtifactsByID[artifactID] else {
            throw NormalizedContextStoreError.missingCompactionArtifact(artifactID)
          }
          return artifact
        }
      }
      var legacySnapshotsByConversation: [UUID: ConversationCompactionSnapshot] = [:]
      for conversation in plan.snapshot.conversations {
        guard let data = conversation.compactionSnapshotData else { continue }
        let snapshot = try JSONDecoder().decode(ConversationCompactionSnapshot.self, from: data)
        let canonical = (canonicalMessagesByConversation[conversation.id] ?? []).map {
          AIChatMessage(
            id: $0.id,
            role: MessageRole(rawValue: $0.roleRawValue) ?? .assistant,
            content: $0.content
          )
        }
        try NormalizedContextStore.validateLegacyCompactionSnapshot(
          snapshot,
          conversationID: conversation.id,
          canonicalMessages: canonical
        )
        legacySnapshotsByConversation[conversation.id] = snapshot
      }
      for message in plan.snapshot.messages {
        guard let data = message.contextReceiptData else { continue }
        guard message.roleRawValue == MessageRole.assistant.rawValue else {
          throw MosaicPortableBackupError.invalidNormalizedInvariant(
            recordType: "message",
            id: message.id,
            field: "context_receipt_role"
          )
        }
        let receipt = try JSONDecoder().decode(RequestContextReceipt.self, from: data)
        let source = (canonicalMessagesByConversation[message.conversationID] ?? [])
          .prefix { candidate in
            if candidate.createdAt != message.createdAt {
              return candidate.createdAt < message.createdAt
            }
            let candidateRoleRank = candidate.roleRawValue == MessageRole.user.rawValue ? 0 : 1
            return candidateRoleRank < 1
              || (candidateRoleRank == 1 && candidate.id.uuidString < message.id.uuidString)
          }
          .map {
            AIChatMessage(
              id: $0.id,
              role: MessageRole(rawValue: $0.roleRawValue) ?? .assistant,
              content: $0.content
            )
          }
        try NormalizedContextStore.validateLegacyRequestReceiptStructure(
          receipt,
          conversationID: message.conversationID,
          canonicalMessages: Array(source),
          legacyCompactionSnapshot: legacySnapshotsByConversation[message.conversationID]
        ) { compactionID in
          guard let artifact = portableArtifactsByID[compactionID] else { return nil }
          guard let providerConfigurationID = artifact.providerConfigurationID,
            let providerKindRawValue = artifact.providerKindRawValue,
            let providerDisplayName = artifact.providerDisplayName,
            let providerEndpoint = artifact.providerEndpoint,
            let modelIdentifier = artifact.modelIdentifier
          else {
            throw NormalizedContextStoreError.incompleteCompactionArtifact(artifact.id)
          }
          return NormalizedLegacyCompactionReference(
            id: artifact.id,
            renderedSummary: artifact.renderedSummary,
            coveredMessageCount: artifact.coveredMessageCount,
            providerConfigurationID: providerConfigurationID,
            providerKindRawValue: providerKindRawValue,
            providerDisplayName: providerDisplayName,
            providerEndpoint: providerEndpoint,
            modelIdentifier: modelIdentifier,
            createdAt: artifact.createdAt
          )
        }
      }
      let fetched = try captureContents(
        from: stagingContext,
        backupID: plan.snapshot.backupID,
        createdAt: plan.snapshot.createdAt,
        extensionRecords: plan.snapshot.extensionRecords,
        limits: maintenanceCaptureLimits(for: plan)
      )
      guard fetched == contents(of: plan.snapshot) else {
        throw MosaicPortableBackupError.stagingVerificationFailed
      }
      guard
        try ExperiencePortableArchive.capture(from: stagingContext)
          == plan.snapshot.extensionRecords.filter(ExperiencePortableArchive.isOwned)
      else { throw MosaicPortableBackupError.stagingVerificationFailed }
      let expectedMemoryRecords = plan.snapshot.extensionRecords.filter(
        AutomaticMemoryPortableArchive.isOwned
      )
      let fetchedMemoryRecords = try AutomaticMemoryPortableArchive.capture(
        from: stagingContext,
        includesPendingChanges: false,
        limits: maintenanceCaptureLimits(for: plan)
      )
      guard fetchedMemoryRecords == expectedMemoryRecords else {
        throw MosaicPortableBackupError.stagingVerificationFailed
      }
      let expectedProjectRecords = plan.snapshot.extensionRecords.filter(
        ProjectPortableArchive.isOwned
      )
      let fetchedProjectRecords = try ProjectPortableArchive.capture(
        from: stagingContext,
        includesPendingChanges: false,
        limits: maintenanceCaptureLimits(for: plan)
      )
      guard fetchedProjectRecords == expectedProjectRecords else {
        throw MosaicPortableBackupError.stagingVerificationFailed
      }
      guard
        try ProviderModelsPortableArchive.capture(
          from: stagingContext, includesPendingChanges: false,
          limits: maintenanceCaptureLimits(for: plan))
          == plan.snapshot.extensionRecords.filter(ProviderModelsPortableArchive.isOwned)
      else { throw MosaicPortableBackupError.stagingVerificationFailed }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as MosaicPortableBackupError {
      throw error
    } catch {
      throw MosaicPortableBackupError.stagingVerificationFailed
    }
  }

  @MainActor
  public static func replaceLiveStore(
    using plan: MosaicPortableRestorePlan,
    in modelContext: ModelContext
  ) throws {
    try replaceLiveStore(using: plan, in: modelContext, beforeSave: {})
  }

  /// Replaces the committed source records on a dedicated SwiftData model actor. The caller's
  /// context is used only to reject unsaved edits and to publish the committed change afterward.
  @MainActor
  public static func replaceLiveStoreAsync(
    using plan: MosaicPortableRestorePlan,
    in modelContext: ModelContext
  ) async throws {
    guard !modelContext.hasChanges else {
      throw MosaicPortableBackupError.liveContextHasUnsavedChanges
    }
    defer {
      if modelContext.hasChanges {
        modelContext.rollback()
      }
      modelContext.processPendingChanges()
    }
    let container = modelContext.container
    let repository = await Task.detached {
      MosaicPortableBackupRepository(modelContainer: container)
    }.value
    // Once the durable unavailable latch is set, the current generation has already failed exact
    // verification and cannot be trusted as rollback material. Requiring it to pass export limits
    // here would make the only recovery path permanently unreachable.
    let requiresCompensation = !MosaicOperationCoordinator.shared.isSourceStoreUnavailable
    try await repository.replaceLiveStore(
      using: plan,
      requiresCompensation: requiresCompensation
    )
  }

  @MainActor
  static func replaceLiveStore(
    using plan: MosaicPortableRestorePlan,
    in modelContext: ModelContext,
    beforeSave: () throws -> Void,
    afterSave: () throws -> Void = {},
    requiresCompensation: Bool = true
  ) throws {
    try replaceStoreContents(
      using: plan,
      in: modelContext,
      beforeSave: beforeSave,
      afterSave: afterSave,
      requiresCompensation: requiresCompensation
    )
  }

  fileprivate static func replaceStoreContents(
    using plan: MosaicPortableRestorePlan,
    in modelContext: ModelContext,
    beforeSave: () throws -> Void,
    afterSave: () throws -> Void = {},
    requiresCompensation: Bool = true
  ) throws {
    guard !modelContext.hasChanges else {
      throw MosaicPortableBackupError.liveContextHasUnsavedChanges
    }
    defer {
      if modelContext.hasChanges {
        modelContext.rollback()
      }
      modelContext.processPendingChanges()
    }

    // Keep an exact logical compensation image. SwiftData rollback only covers an uncommitted
    // context; once the replacement save succeeds, a later verification error needs a real
    // committed restore of the previous library rather than a misleading rollback call.
    let captureLimits = maintenanceCaptureLimits(for: plan)
    let previousSnapshot: MosaicPortableBackupSnapshot?
    if requiresCompensation {
      previousSnapshot = try captureSnapshotRecords(
        from: modelContext,
        backupID: UUID(),
        createdAt: .now,
        extensionRecords: [],
        limits: captureLimits,
        includesPendingChanges: false
      )
    } else {
      previousSnapshot = nil
    }

    do {
      try deleteAllSourceRecords(in: modelContext)
      try insert(plan.snapshot, into: modelContext)
      try beforeSave()
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw mappedPersistenceError(error)
    }

    // Cancellation is deliberately no longer observed beyond the commit boundary. If the
    // requested snapshot is exact, completion is success. If it is not, compensate with the
    // pre-commit image before surfacing any failure.
    do {
      try afterSave()
      try repairLateWritesIfNeeded(using: plan, in: modelContext.container)
    } catch {
      let postCommitError = error
      if (try? hasExactContents(
        plan.snapshot,
        in: modelContext.container,
        limits: captureLimits
      )) == true {
        return
      }
      guard let previousSnapshot else {
        // With an already-unverified source generation there is no safe rollback target. Finish
        // the requested, fully staged generation without observing cancellation; only an exact
        // read-back is allowed to clear the caller's unavailable latch.
        do {
          try replaceCommittedContents(
            with: plan.snapshot,
            in: modelContext.container,
            limits: captureLimits
          )
          return
        } catch {
          throw MosaicPortableBackupError.liveStoreRecoveryFailed
        }
      }
      do {
        try replaceCommittedContents(
          with: previousSnapshot,
          in: modelContext.container,
          limits: captureLimits
        )
      } catch {
        guard
          (try? hasExactContents(
            previousSnapshot,
            in: modelContext.container,
            limits: captureLimits
          )) == true
        else {
          throw MosaicPortableBackupError.liveStoreRecoveryFailed
        }
      }
      throw mappedPersistenceError(postCommitError)
    }
  }

  /// The process-level mutation gate should make this a no-op. The exact read-back is a second
  /// line of defense against an uncoordinated context that committed after the delete scan but
  /// before the restore save.
  fileprivate static func repairLateWritesIfNeeded(
    using plan: MosaicPortableRestorePlan,
    in modelContainer: ModelContainer
  ) throws {
    let captureLimits = maintenanceCaptureLimits(for: plan)
    guard
      try !hasExactContents(
        plan.snapshot,
        in: modelContainer,
        limits: captureLimits
      )
    else { return }
    try replaceCommittedContents(
      with: plan.snapshot,
      in: modelContainer,
      limits: captureLimits
    )
  }

  /// Performs a post-commit reconciliation or compensation without observing task cancellation.
  /// The caller has already crossed an irreversible commit boundary and must leave a verified
  /// complete snapshot behind before returning.
  fileprivate static func replaceCommittedContents(
    with snapshot: MosaicPortableBackupSnapshot,
    in modelContainer: ModelContainer,
    limits: MosaicPortableBackupLimits
  ) throws {
    let replacementContext = ModelContext(modelContainer)
    do {
      try deleteAllSourceRecords(in: replacementContext, honorsCancellation: false)
      try insert(snapshot, into: replacementContext, honorsCancellation: false)
      try replacementContext.save()
      guard try hasExactContents(snapshot, in: modelContainer, limits: limits) else {
        throw MosaicPortableBackupError.persistenceFailure
      }
    } catch {
      replacementContext.rollback()
      throw error
    }
  }

  fileprivate static func hasExactContents(
    _ snapshot: MosaicPortableBackupSnapshot,
    in modelContainer: ModelContainer,
    limits: MosaicPortableBackupLimits
  ) throws -> Bool {
    let verificationContext = ModelContext(modelContainer)
    let fetched = try captureContents(
      from: verificationContext,
      backupID: snapshot.backupID,
      createdAt: snapshot.createdAt,
      extensionRecords: snapshot.extensionRecords,
      limits: limits,
      honorsCancellation: false
    )
    guard fetched == contents(of: snapshot) else { return false }
    let expectedMemoryRecords = snapshot.extensionRecords.filter(
      AutomaticMemoryPortableArchive.isOwned
    )
    let expectedProjectRecords = snapshot.extensionRecords.filter(ProjectPortableArchive.isOwned)
    guard
      expectedMemoryRecords.count + expectedProjectRecords.count
        + snapshot.extensionRecords.filter(ProviderModelsPortableArchive.isOwned).count
        + snapshot.extensionRecords.filter(ExperiencePortableArchive.isOwned).count
        == snapshot.extensionRecords.count
    else { return false }
    let fetchedMemoryRecords = try AutomaticMemoryPortableArchive.capture(
      from: verificationContext,
      includesPendingChanges: false,
      limits: limits,
      honorsCancellation: false
    )
    guard fetchedMemoryRecords == expectedMemoryRecords else { return false }
    let fetchedProjectRecords = try ProjectPortableArchive.capture(
      from: verificationContext,
      includesPendingChanges: false,
      limits: limits,
      honorsCancellation: false
    )
    guard fetchedProjectRecords == expectedProjectRecords else { return false }
    guard
      try ExperiencePortableArchive.capture(
        from: verificationContext, limits: limits, honorsCancellation: false)
        == snapshot.extensionRecords.filter(ExperiencePortableArchive.isOwned)
    else { return false }
    return try ProviderModelsPortableArchive.capture(
      from: verificationContext, includesPendingChanges: false,
      limits: limits, honorsCancellation: false)
      == snapshot.extensionRecords.filter(ProviderModelsPortableArchive.isOwned)
  }

  fileprivate static func maintenanceCaptureLimits(
    for plan: MosaicPortableRestorePlan
  ) -> MosaicPortableBackupLimits {
    MosaicPortableBackupLimits(
      maximumTotalBytes: max(
        MosaicPortableBackupLimits.default.maximumTotalBytes,
        plan.limits.maximumTotalBytes
      ),
      maximumRecordBytes: max(
        MosaicPortableBackupLimits.default.maximumRecordBytes,
        plan.limits.maximumRecordBytes
      ),
      maximumRecordCount: max(
        MosaicPortableBackupLimits.default.maximumRecordCount,
        plan.limits.maximumRecordCount
      )
    )
  }

  fileprivate static func mappedPersistenceError(_ error: Error) -> Error {
    if error is CancellationError { return CancellationError() }
    if let backupError = error as? MosaicPortableBackupError { return backupError }
    return MosaicPortableBackupError.persistenceFailure
  }
}

extension MosaicPortableBackup {
  fileprivate struct IntegrityBody: Codable {
    let formatIdentifier: String
    let formatVersion: Int
    let minimumReaderVersion: Int
    let credentialsIncluded: Bool
    let semanticVectorsIncluded: Bool
    let snapshot: MosaicPortableBackupSnapshot
  }

  fileprivate struct Contents: Equatable {
    let conversations: [MosaicPortableConversation]
    let messages: [MosaicPortableMessage]
    let memories: [MosaicPortableMemory]
    let scheduledTasks: [MosaicPortableScheduledTask]
    let providerConfigurations: [MosaicPortableProviderConfiguration]
    let embeddingProfiles: [MosaicPortableEmbeddingProfile]
    let importedDocuments: [MosaicPortableImportedDocument]
    let documentChunks: [MosaicPortableDocumentChunk]
    let requestContextEvents: [MosaicPortableRequestContextEvent]
    let compactionArtifacts: [MosaicPortableCompactionArtifact]
    let conversationCompactionHeads: [MosaicPortableConversationCompactionHead]
    let normalizedBackfillProgress: [MosaicPortableNormalizedContextBackfillProgress]
  }

  fileprivate struct CompactionArtifactIntegrityEnvelope: Codable {
    let id: UUID
    let conversationID: UUID
    let lineagePreviousCompactionID: UUID?
    let coverageParentArtifactID: UUID?
    let coverageDeltaData: Data
    let coveredMessageCount: Int
    let modeRawValue: String
    let promptVersion: String
    let contentSchemaVersion: Int
    let contentData: Data?
    let renderedSummary: String
    let sourceFingerprint: String?
    let providerConfigurationID: UUID?
    let providerKindRawValue: String?
    let providerDisplayName: String?
    let providerEndpoint: String?
    let modelIdentifier: String?
    let providerMessageID: String?
    let inputTokenCount: Int?
    let outputTokenCount: Int?
    let estimatedSourceTokens: Int
    let estimatedSummaryTokens: Int
    let chainDepth: Int
    let warningsData: Data
    let isSnapshotComplete: Bool
    let isDetachedCoverageRoot: Bool
    let createdAt: Date
  }

  fileprivate static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  fileprivate static var decoder: JSONDecoder { JSONDecoder() }

  fileprivate static func checksum(for body: IntegrityBody) throws -> String {
    SHA256.hash(data: try encoder.encode(body)).map { String(format: "%02x", $0) }.joined()
  }

  static func compactionArtifactFingerprint(
    _ artifact: MosaicPortableCompactionArtifact
  ) throws -> String {
    let envelope = CompactionArtifactIntegrityEnvelope(
      id: artifact.id,
      conversationID: artifact.conversationID,
      lineagePreviousCompactionID: artifact.lineagePreviousCompactionID,
      coverageParentArtifactID: artifact.coverageParentArtifactID,
      coverageDeltaData: artifact.coverageDeltaData,
      coveredMessageCount: artifact.coveredMessageCount,
      modeRawValue: artifact.modeRawValue,
      promptVersion: artifact.promptVersion,
      contentSchemaVersion: artifact.contentSchemaVersion,
      contentData: artifact.contentData,
      renderedSummary: artifact.renderedSummary,
      sourceFingerprint: artifact.sourceFingerprint,
      providerConfigurationID: artifact.providerConfigurationID,
      providerKindRawValue: artifact.providerKindRawValue,
      providerDisplayName: artifact.providerDisplayName,
      providerEndpoint: artifact.providerEndpoint,
      modelIdentifier: artifact.modelIdentifier,
      providerMessageID: artifact.providerMessageID,
      inputTokenCount: artifact.inputTokenCount,
      outputTokenCount: artifact.outputTokenCount,
      estimatedSourceTokens: artifact.estimatedSourceTokens,
      estimatedSummaryTokens: artifact.estimatedSummaryTokens,
      chainDepth: artifact.chainDepth,
      warningsData: artifact.warningsData,
      isSnapshotComplete: artifact.isSnapshotComplete,
      isDetachedCoverageRoot: artifact.isDetachedCoverageRoot,
      createdAt: artifact.createdAt
    )
    let normalizedEncoder = JSONEncoder()
    normalizedEncoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try normalizedEncoder.encode(envelope))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  static func encodeUnchecked(
    snapshot: MosaicPortableBackupSnapshot,
    limits: MosaicPortableBackupLimits
  ) throws -> Data {
    let body = IntegrityBody(
      formatIdentifier: formatIdentifier,
      formatVersion: currentFormatVersion,
      minimumReaderVersion: currentReaderVersion,
      credentialsIncluded: false,
      semanticVectorsIncluded: false,
      snapshot: snapshot
    )
    let envelope = MosaicPortableBackupEnvelope(
      formatIdentifier: body.formatIdentifier,
      formatVersion: body.formatVersion,
      minimumReaderVersion: body.minimumReaderVersion,
      credentialsIncluded: body.credentialsIncluded,
      semanticVectorsIncluded: body.semanticVectorsIncluded,
      snapshot: body.snapshot,
      checksumSHA256: try checksum(for: body)
    )
    let data = try encoder.encode(envelope)
    guard data.count <= limits.maximumTotalBytes else {
      throw MosaicPortableBackupError.backupTooLarge(
        actual: data.count,
        maximum: limits.maximumTotalBytes
      )
    }
    return data
  }

  fileprivate static func captureSnapshotRecords(
    from modelContext: ModelContext,
    backupID: UUID,
    createdAt: Date,
    extensionRecords: [MosaicPortableExtensionRecord],
    limits: MosaicPortableBackupLimits,
    includesPendingChanges: Bool
  ) throws -> MosaicPortableBackupSnapshot {
    if let reserved = extensionRecords.first(where: isSupportedExtensionRecord) {
      throw MosaicPortableBackupError.unsupportedExtensionRecord(
        namespace: reserved.namespace,
        recordType: reserved.recordType,
        version: reserved.recordVersion
      )
    }
    let automaticMemoryRecords = try AutomaticMemoryPortableArchive.capture(
      from: modelContext,
      includesPendingChanges: includesPendingChanges,
      limits: limits
    )
    let projectRecords = try ProjectPortableArchive.capture(
      from: modelContext,
      includesPendingChanges: includesPendingChanges,
      limits: limits
    )
    let modelRecords = try ProviderModelsPortableArchive.capture(
      from: modelContext,
      includesPendingChanges: includesPendingChanges, limits: limits)
    let extensionRecords =
      (extensionRecords + automaticMemoryRecords + projectRecords + modelRecords
      + (try ExperiencePortableArchive.capture(
        from: modelContext, includesPendingChanges: includesPendingChanges, limits: limits)))
      .sorted(
        by: extensionRecordOrder
      )
    let contents = try captureContents(
      from: modelContext,
      backupID: backupID,
      createdAt: createdAt,
      extensionRecords: extensionRecords,
      limits: limits,
      includesPendingChanges: includesPendingChanges
    )
    return MosaicPortableBackupSnapshot(
      backupID: backupID,
      createdAt: createdAt,
      sourceSchemaVersion: sourceSchemaVersion,
      conversations: contents.conversations,
      messages: contents.messages,
      memories: contents.memories,
      scheduledTasks: contents.scheduledTasks,
      providerConfigurations: contents.providerConfigurations,
      embeddingProfiles: contents.embeddingProfiles,
      importedDocuments: contents.importedDocuments,
      documentChunks: contents.documentChunks,
      requestContextEvents: contents.requestContextEvents,
      compactionArtifacts: contents.compactionArtifacts,
      conversationCompactionHeads: contents.conversationCompactionHeads,
      normalizedBackfillProgress: contents.normalizedBackfillProgress,
      extensionRecords: extensionRecords
    )
  }

  /// Tracks the exact encoded archive growth while records are captured. An empty envelope is the
  /// fixed baseline; each JSON object then replaces an empty array slot or adds one comma plus its
  /// standalone encoding. JSONEncoder uses the same deterministic settings for both paths.
  fileprivate struct CaptureBudget {
    let limits: MosaicPortableBackupLimits
    private(set) var recordCount: Int
    private(set) var encodedArchiveBytes: Int

    init(
      backupID: UUID,
      createdAt: Date,
      extensionRecords: [MosaicPortableExtensionRecord],
      limits: MosaicPortableBackupLimits
    ) throws {
      self.limits = limits
      recordCount = extensionRecords.count

      guard recordCount <= limits.maximumRecordCount else {
        throw MosaicPortableBackupError.tooManyRecords(
          actual: recordCount,
          maximum: limits.maximumRecordCount
        )
      }
      for record in extensionRecords {
        _ = try Self.validateRecordSize(
          record,
          recordType: "extension_record",
          id: record.id,
          limits: limits
        )
      }

      let emptySnapshot = MosaicPortableBackupSnapshot(
        backupID: backupID,
        createdAt: createdAt,
        sourceSchemaVersion: sourceSchemaVersion,
        conversations: [],
        messages: [],
        memories: [],
        scheduledTasks: [],
        providerConfigurations: [],
        embeddingProfiles: [],
        importedDocuments: [],
        documentChunks: [],
        requestContextEvents: [],
        compactionArtifacts: [],
        conversationCompactionHeads: [],
        normalizedBackfillProgress: [],
        extensionRecords: extensionRecords
      )
      let unrestricted = MosaicPortableBackupLimits(
        maximumTotalBytes: .max,
        maximumRecordBytes: .max,
        maximumRecordCount: .max
      )
      encodedArchiveBytes = try encodeUnchecked(
        snapshot: emptySnapshot,
        limits: unrestricted
      ).count
      guard encodedArchiveBytes <= limits.maximumTotalBytes else {
        throw MosaicPortableBackupError.backupTooLarge(
          actual: encodedArchiveBytes,
          maximum: limits.maximumTotalBytes
        )
      }
    }

    mutating func retain<Record: Encodable>(
      _ record: Record,
      recordType: String,
      id: UUID,
      isFirstInCollection: Bool
    ) throws {
      let recordBytes = try Self.validateRecordSize(
        record,
        recordType: recordType,
        id: id,
        limits: limits
      )
      let (nextRecordCount, recordCountOverflow) = recordCount.addingReportingOverflow(1)
      guard !recordCountOverflow, nextRecordCount <= limits.maximumRecordCount else {
        throw MosaicPortableBackupError.tooManyRecords(
          actual: recordCountOverflow ? .max : nextRecordCount,
          maximum: limits.maximumRecordCount
        )
      }

      let separatorBytes = isFirstInCollection ? 0 : 1
      let (recordDelta, deltaOverflow) = recordBytes.addingReportingOverflow(separatorBytes)
      let (nextArchiveBytes, archiveOverflow) =
        encodedArchiveBytes.addingReportingOverflow(recordDelta)
      guard !deltaOverflow, !archiveOverflow, nextArchiveBytes <= limits.maximumTotalBytes else {
        throw MosaicPortableBackupError.backupTooLarge(
          actual: deltaOverflow || archiveOverflow ? .max : nextArchiveBytes,
          maximum: limits.maximumTotalBytes
        )
      }

      recordCount = nextRecordCount
      encodedArchiveBytes = nextArchiveBytes
    }

    private static func validateRecordSize<Record: Encodable>(
      _ record: Record,
      recordType: String,
      id: UUID,
      limits: MosaicPortableBackupLimits
    ) throws -> Int {
      let count = try encoder.encode(record).count
      guard count <= limits.maximumRecordBytes else {
        throw MosaicPortableBackupError.recordTooLarge(
          recordType: recordType,
          id: id,
          actual: count,
          maximum: limits.maximumRecordBytes
        )
      }
      return count
    }
  }

  private static let captureFetchPageSize = 4

  fileprivate static func captureKeyedRecords<
    Source: PersistentModel, Key: Comparable, Record: Encodable
  >(
    from modelContext: ModelContext,
    makeDescriptor: (Key?) -> FetchDescriptor<Source>,
    key: (Source) -> Key,
    recordID: (Source) -> UUID,
    recordType: String,
    includesPendingChanges: Bool,
    honorsCancellation: Bool,
    budget: inout CaptureBudget,
    transform: (Source) throws -> Record
  ) throws -> [Record] {
    var records: [Record] = []
    var cursor: Key?

    while true {
      try checkCancellation(if: honorsCancellation)
      var descriptor = makeDescriptor(cursor)
      descriptor.fetchLimit = captureFetchPageSize
      descriptor.includePendingChanges = includesPendingChanges
      let page = try modelContext.fetch(descriptor)
      guard !page.isEmpty else { break }

      for source in page {
        try checkCancellation(if: honorsCancellation)
        let sourceKey = key(source)
        guard cursor.map({ sourceKey > $0 }) ?? true else {
          throw MosaicPortableBackupError.persistenceFailure
        }
        let record = try transform(source)
        try budget.retain(
          record,
          recordType: recordType,
          id: recordID(source),
          isFirstInCollection: records.isEmpty
        )
        records.append(record)
        cursor = sourceKey
      }

      if page.count < captureFetchPageSize { break }
    }
    return records
  }

  fileprivate static func captureContents(
    from modelContext: ModelContext,
    backupID: UUID,
    createdAt: Date,
    extensionRecords: [MosaicPortableExtensionRecord],
    limits: MosaicPortableBackupLimits,
    includesPendingChanges: Bool = false,
    honorsCancellation: Bool = true
  ) throws -> Contents {
    var budget = try CaptureBudget(
      backupID: backupID,
      createdAt: createdAt,
      extensionRecords: extensionRecords,
      limits: limits
    )
    let conversations = try captureKeyedRecords(
      from: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\ConversationRecord.id)]
          )
        }
        return FetchDescriptor<ConversationRecord>(
          sortBy: [SortDescriptor(\ConversationRecord.id)]
        )
      },
      key: \ConversationRecord.id,
      recordID: \ConversationRecord.id,
      recordType: "conversation",
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation,
      budget: &budget,
      transform: {
        MosaicPortableConversation(
          id: $0.id,
          title: $0.title,
          providerConfigurationID: $0.providerConfigurationID,
          modelIdentifier: $0.modelIdentifier,
          systemPrompt: $0.systemPrompt,
          draftText: $0.draftText,
          compactionSnapshotData: $0.compactionSnapshotData,
          isArchived: $0.isArchived,
          createdAt: $0.createdAt,
          updatedAt: $0.updatedAt
        )
      }
    )
    let messages = try captureKeyedRecords(
      from: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\MessageRecord.id)]
          )
        }
        return FetchDescriptor<MessageRecord>(sortBy: [SortDescriptor(\MessageRecord.id)])
      },
      key: \MessageRecord.id,
      recordID: \MessageRecord.id,
      recordType: "message",
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation,
      budget: &budget,
      transform: {
        MosaicPortableMessage(
          id: $0.id,
          conversationID: $0.conversationID,
          roleRawValue: $0.roleRawValue,
          content: $0.content,
          statusRawValue: $0.statusRawValue,
          providerConfigurationID: $0.providerConfigurationID,
          providerKindRawValue: $0.providerKindRawValue,
          providerDisplayName: $0.providerDisplayName,
          providerHost: $0.providerHost,
          providerMessageID: $0.providerMessageID,
          modelIdentifier: $0.modelIdentifier,
          inputTokenCount: $0.inputTokenCount,
          outputTokenCount: $0.outputTokenCount,
          errorDescription: $0.errorDescription,
          contextReceiptData: $0.contextReceiptData,
          createdAt: $0.createdAt,
          updatedAt: $0.updatedAt
        )
      }
    )
    let memories = try captureKeyedRecords(
      from: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<MemoryRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\MemoryRecord.id)]
          )
        }
        return FetchDescriptor<MemoryRecord>(sortBy: [SortDescriptor(\MemoryRecord.id)])
      },
      key: \MemoryRecord.id,
      recordID: \MemoryRecord.id,
      recordType: "memory",
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation,
      budget: &budget,
      transform: {
        MosaicPortableMemory(
          id: $0.id,
          title: $0.title,
          content: $0.content,
          scopeRawValue: $0.scopeRawValue,
          conversationID: $0.conversationID,
          isEnabled: $0.isEnabled,
          isUserApproved: $0.isUserApproved,
          createdAt: $0.createdAt,
          updatedAt: $0.updatedAt
        )
      }
    )
    let scheduledTasks = try captureKeyedRecords(
      from: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<ScheduledTaskRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\ScheduledTaskRecord.id)]
          )
        }
        return FetchDescriptor<ScheduledTaskRecord>(
          sortBy: [SortDescriptor(\ScheduledTaskRecord.id)]
        )
      },
      key: \ScheduledTaskRecord.id,
      recordID: \ScheduledTaskRecord.id,
      recordType: "scheduled_task",
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation,
      budget: &budget,
      transform: {
        MosaicPortableScheduledTask(
          id: $0.id,
          title: $0.title,
          prompt: $0.prompt,
          conversationID: $0.conversationID,
          providerConfigurationID: $0.providerConfigurationID,
          recurrenceRawValue: $0.recurrenceRawValue,
          statusRawValue: $0.statusRawValue,
          scheduledAt: $0.scheduledAt,
          timeZoneIdentifier: $0.timeZoneIdentifier,
          nextRunAt: $0.nextRunAt,
          lastRunAt: $0.lastRunAt,
          lastError: $0.lastError,
          createdAt: $0.createdAt,
          updatedAt: $0.updatedAt
        )
      }
    )
    let providerConfigurations = try captureKeyedRecords(
      from: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<ProviderConfigurationRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\ProviderConfigurationRecord.id)]
          )
        }
        return FetchDescriptor<ProviderConfigurationRecord>(
          sortBy: [SortDescriptor(\ProviderConfigurationRecord.id)]
        )
      },
      key: \ProviderConfigurationRecord.id,
      recordID: \ProviderConfigurationRecord.id,
      recordType: "provider_configuration",
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation,
      budget: &budget,
      transform: {
        MosaicPortableProviderConfiguration(
          id: $0.id,
          displayName: $0.displayName,
          providerRawValue: $0.providerRawValue,
          modelIdentifier: $0.modelIdentifier,
          baseURLString: $0.baseURLString,
          contextWindowTokens: $0.contextWindowTokens,
          maximumOutputTokens: $0.maximumOutputTokens,
          isEnabled: $0.isEnabled,
          createdAt: $0.createdAt,
          updatedAt: $0.updatedAt
        )
      }
    )
    let embeddingProfiles = try captureKeyedRecords(
      from: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<EmbeddingProfileRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\EmbeddingProfileRecord.id)]
          )
        }
        return FetchDescriptor<EmbeddingProfileRecord>(
          sortBy: [SortDescriptor(\EmbeddingProfileRecord.id)]
        )
      },
      key: \EmbeddingProfileRecord.id,
      recordID: \EmbeddingProfileRecord.id,
      recordType: "embedding_profile",
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation,
      budget: &budget,
      transform: {
        guard $0.weight.isFinite else {
          throw MosaicPortableBackupError.invalidNumber(
            recordType: "embedding_profile",
            id: $0.id,
            field: "weight"
          )
        }
        return MosaicPortableEmbeddingProfile(
          id: $0.id,
          displayName: $0.displayName,
          backendRawValue: $0.backendRawValue,
          providerConfigurationID: $0.providerConfigurationID,
          modelIdentifier: $0.modelIdentifier,
          weight: $0.weight,
          isEnabled: $0.isEnabled,
          indexesConversations: $0.indexesConversations,
          indexesDocuments: $0.indexesDocuments,
          createdAt: $0.createdAt,
          updatedAt: $0.updatedAt
        )
      }
    )
    let importedDocuments = try captureKeyedRecords(
      from: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<ImportedDocumentRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\ImportedDocumentRecord.id)]
          )
        }
        return FetchDescriptor<ImportedDocumentRecord>(
          sortBy: [SortDescriptor(\ImportedDocumentRecord.id)]
        )
      },
      key: \ImportedDocumentRecord.id,
      recordID: \ImportedDocumentRecord.id,
      recordType: "imported_document",
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation,
      budget: &budget,
      transform: {
        MosaicPortableImportedDocument(
          id: $0.id,
          title: $0.title,
          sourceFilename: $0.sourceFilename,
          mimeType: $0.mimeType,
          contentFingerprint: $0.contentFingerprint,
          characterCount: $0.characterCount,
          pageCount: $0.pageCount,
          ocrPageCount: $0.ocrPageCount,
          ocrFallbackPageCount: $0.ocrFallbackPageCount,
          isEnabled: $0.isEnabled,
          createdAt: $0.createdAt,
          updatedAt: $0.updatedAt
        )
      }
    )
    let documentChunks = try captureKeyedRecords(
      from: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<DocumentChunkRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\DocumentChunkRecord.id)]
          )
        }
        return FetchDescriptor<DocumentChunkRecord>(
          sortBy: [SortDescriptor(\DocumentChunkRecord.id)]
        )
      },
      key: \DocumentChunkRecord.id,
      recordID: \DocumentChunkRecord.id,
      recordType: "document_chunk",
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation,
      budget: &budget,
      transform: {
        MosaicPortableDocumentChunk(
          id: $0.id,
          documentID: $0.documentID,
          chunkIndex: $0.chunkIndex,
          content: $0.content,
          pageNumber: $0.pageNumber,
          isOCRDerived: $0.isOCRDerived,
          createdAt: $0.createdAt
        )
      }
    )
    let requestContextEvents = try captureKeyedRecords(
      from: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<RequestContextEventRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\RequestContextEventRecord.id)]
          )
        }
        return FetchDescriptor<RequestContextEventRecord>(
          sortBy: [SortDescriptor(\RequestContextEventRecord.id)]
        )
      },
      key: \RequestContextEventRecord.id,
      recordID: \RequestContextEventRecord.id,
      recordType: "request_context_event",
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation,
      budget: &budget,
      transform: {
        MosaicPortableRequestContextEvent(
          id: $0.id,
          eventKey: $0.eventKey,
          assistantMessageID: $0.assistantMessageID,
          conversationID: $0.conversationID,
          sourceThroughMessageID: $0.sourceThroughMessageID,
          sourceMessageCount: $0.sourceMessageCount,
          eventSequence: $0.eventSequence,
          payloadData: $0.payloadData,
          payloadFingerprint: $0.payloadFingerprint,
          legacyReceiptFingerprint: $0.legacyReceiptFingerprint,
          createdAt: $0.createdAt
        )
      }
    )
    let compactionArtifacts = try captureKeyedRecords(
      from: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<CompactionArtifactRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\CompactionArtifactRecord.id)]
          )
        }
        return FetchDescriptor<CompactionArtifactRecord>(
          sortBy: [SortDescriptor(\CompactionArtifactRecord.id)]
        )
      },
      key: \CompactionArtifactRecord.id,
      recordID: \CompactionArtifactRecord.id,
      recordType: "compaction_artifact",
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation,
      budget: &budget,
      transform: {
        MosaicPortableCompactionArtifact(
          id: $0.id,
          conversationID: $0.conversationID,
          lineagePreviousCompactionID: $0.lineagePreviousCompactionID,
          coverageParentArtifactID: $0.coverageParentArtifactID,
          coverageDeltaData: $0.coverageDeltaData,
          coveredMessageCount: $0.coveredMessageCount,
          modeRawValue: $0.modeRawValue,
          promptVersion: $0.promptVersion,
          contentSchemaVersion: $0.contentSchemaVersion,
          contentData: $0.contentData,
          renderedSummary: $0.renderedSummary,
          sourceFingerprint: $0.sourceFingerprint,
          providerConfigurationID: $0.providerConfigurationID,
          providerKindRawValue: $0.providerKindRawValue,
          providerDisplayName: $0.providerDisplayName,
          providerEndpoint: $0.providerEndpoint,
          modelIdentifier: $0.modelIdentifier,
          providerMessageID: $0.providerMessageID,
          inputTokenCount: $0.inputTokenCount,
          outputTokenCount: $0.outputTokenCount,
          estimatedSourceTokens: $0.estimatedSourceTokens,
          estimatedSummaryTokens: $0.estimatedSummaryTokens,
          chainDepth: $0.chainDepth,
          warningsData: $0.warningsData,
          isSnapshotComplete: $0.isSnapshotComplete,
          isDetachedCoverageRoot: $0.isDetachedCoverageRoot,
          payloadFingerprint: $0.payloadFingerprint,
          createdAt: $0.createdAt
        )
      }
    )
    let conversationCompactionHeads = try captureKeyedRecords(
      from: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<ConversationCompactionHeadRecord>(
            predicate: #Predicate { $0.conversationID > cursor },
            sortBy: [SortDescriptor(\ConversationCompactionHeadRecord.conversationID)]
          )
        }
        return FetchDescriptor<ConversationCompactionHeadRecord>(
          sortBy: [SortDescriptor(\ConversationCompactionHeadRecord.conversationID)]
        )
      },
      key: \ConversationCompactionHeadRecord.conversationID,
      recordID: \ConversationCompactionHeadRecord.conversationID,
      recordType: "conversation_compaction_head",
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation,
      budget: &budget,
      transform: {
        MosaicPortableConversationCompactionHead(
          conversationID: $0.conversationID,
          activeArtifactID: $0.activeArtifactID,
          revision: $0.revision,
          updatedAt: $0.updatedAt
        )
      }
    )
    let normalizedBackfillProgress = try captureKeyedRecords(
      from: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<NormalizedContextBackfillProgressRecord>(
            predicate: #Predicate { $0.migrationKey > cursor },
            sortBy: [SortDescriptor(\NormalizedContextBackfillProgressRecord.migrationKey)]
          )
        }
        return FetchDescriptor<NormalizedContextBackfillProgressRecord>(
          sortBy: [SortDescriptor(\NormalizedContextBackfillProgressRecord.migrationKey)]
        )
      },
      key: \NormalizedContextBackfillProgressRecord.migrationKey,
      recordID: { deterministicUUID($0.migrationKey) },
      recordType: "normalized_backfill_progress",
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation,
      budget: &budget,
      transform: {
        MosaicPortableNormalizedContextBackfillProgress(
          migrationKey: $0.migrationKey,
          lastEventKey: $0.lastEventKey,
          processedCount: $0.processedCount,
          migratedCount: $0.migratedCount,
          retainedLegacyCount: $0.retainedLegacyCount,
          failureCount: $0.failureCount,
          isComplete: $0.isComplete,
          updatedAt: $0.updatedAt
        )
      }
    )

    return Contents(
      conversations: conversations,
      messages: messages,
      memories: memories,
      scheduledTasks: scheduledTasks,
      providerConfigurations: providerConfigurations,
      embeddingProfiles: embeddingProfiles,
      importedDocuments: importedDocuments,
      documentChunks: documentChunks,
      requestContextEvents: requestContextEvents,
      compactionArtifacts: compactionArtifacts,
      conversationCompactionHeads: conversationCompactionHeads,
      normalizedBackfillProgress: normalizedBackfillProgress
    )
  }

  fileprivate static func contents(of snapshot: MosaicPortableBackupSnapshot) -> Contents {
    Contents(
      conversations: snapshot.conversations,
      messages: snapshot.messages,
      memories: snapshot.memories,
      scheduledTasks: snapshot.scheduledTasks,
      providerConfigurations: snapshot.providerConfigurations,
      embeddingProfiles: snapshot.embeddingProfiles,
      importedDocuments: snapshot.importedDocuments,
      documentChunks: snapshot.documentChunks,
      requestContextEvents: snapshot.requestContextEvents,
      compactionArtifacts: snapshot.compactionArtifacts,
      conversationCompactionHeads: snapshot.conversationCompactionHeads,
      normalizedBackfillProgress: snapshot.normalizedBackfillProgress
    )
  }

  fileprivate static func validate(
    snapshot: MosaicPortableBackupSnapshot,
    limits: MosaicPortableBackupLimits
  ) throws {
    let recordCounts = [
      snapshot.conversations.count,
      snapshot.messages.count,
      snapshot.memories.count,
      snapshot.scheduledTasks.count,
      snapshot.providerConfigurations.count,
      snapshot.embeddingProfiles.count,
      snapshot.importedDocuments.count,
      snapshot.documentChunks.count,
      snapshot.requestContextEvents.count,
      snapshot.compactionArtifacts.count,
      snapshot.conversationCompactionHeads.count,
      snapshot.normalizedBackfillProgress.count,
      snapshot.extensionRecords.count,
    ]
    var totalRecordCount = 0
    for count in recordCounts {
      let (nextCount, overflow) = totalRecordCount.addingReportingOverflow(count)
      guard !overflow, nextCount <= limits.maximumRecordCount else {
        throw MosaicPortableBackupError.tooManyRecords(
          actual: overflow ? .max : nextCount,
          maximum: limits.maximumRecordCount
        )
      }
      totalRecordCount = nextCount
    }
    try validateUnique(snapshot.conversations, recordType: "conversation")
    try validateUnique(snapshot.messages, recordType: "message")
    try validateUnique(snapshot.memories, recordType: "memory")
    try validateUnique(snapshot.scheduledTasks, recordType: "scheduled_task")
    try validateUnique(snapshot.providerConfigurations, recordType: "provider_configuration")
    try validateUnique(snapshot.embeddingProfiles, recordType: "embedding_profile")
    try validateUnique(snapshot.importedDocuments, recordType: "imported_document")
    try validateUnique(snapshot.documentChunks, recordType: "document_chunk")
    try validateUnique(snapshot.requestContextEvents, recordType: "request_context_event")
    try validateUnique(snapshot.compactionArtifacts, recordType: "compaction_artifact")
    try validateUnique(
      snapshot.conversationCompactionHeads,
      recordType: "conversation_compaction_head"
    )
    try validateUnique(snapshot.extensionRecords, recordType: "extension_record")
    try validateUniqueStrings(
      snapshot.requestContextEvents.map(\.eventKey),
      recordType: "request_context_event"
    )
    try validateUniqueStrings(
      snapshot.normalizedBackfillProgress.map(\.migrationKey),
      recordType: "normalized_backfill_progress"
    )
    try validateSourceFieldSizes(snapshot)

    let conversationIDs = Set(snapshot.conversations.map(\.id))
    for message in snapshot.messages where !conversationIDs.contains(message.conversationID) {
      throw MosaicPortableBackupError.missingConversation(
        messageID: message.id,
        conversationID: message.conversationID
      )
    }
    let documentIDs = Set(snapshot.importedDocuments.map(\.id))
    for chunk in snapshot.documentChunks where !documentIDs.contains(chunk.documentID) {
      throw MosaicPortableBackupError.missingDocument(
        chunkID: chunk.id,
        documentID: chunk.documentID
      )
    }
    for profile in snapshot.embeddingProfiles
    where !profile.weight.isFinite || !(0.25...2).contains(profile.weight) {
      throw MosaicPortableBackupError.invalidNumber(
        recordType: "embedding_profile",
        id: profile.id,
        field: "weight"
      )
    }
    for message in snapshot.messages {
      guard MessageRole(rawValue: message.roleRawValue) != nil,
        MessageStatus(rawValue: message.statusRawValue) != nil,
        message.providerKindRawValue.map({ ProviderKind(rawValue: $0) != nil }) ?? true
      else {
        throw MosaicPortableBackupError.invalidNormalizedInvariant(
          recordType: "message",
          id: message.id,
          field: "enum_value"
        )
      }
    }
    for memory in snapshot.memories
    where MemoryScope(rawValue: memory.scopeRawValue) == nil {
      throw MosaicPortableBackupError.invalidNormalizedInvariant(
        recordType: "memory",
        id: memory.id,
        field: "scope"
      )
    }
    for task in snapshot.scheduledTasks
    where ScheduleRecurrence(rawValue: task.recurrenceRawValue) == nil
      || ScheduledTaskStatus(rawValue: task.statusRawValue) == nil
    {
      throw MosaicPortableBackupError.invalidNormalizedInvariant(
        recordType: "scheduled_task",
        id: task.id,
        field: "enum_value"
      )
    }
    for profile in snapshot.embeddingProfiles
    where EmbeddingBackend(rawValue: profile.backendRawValue) == nil {
      throw MosaicPortableBackupError.invalidNormalizedInvariant(
        recordType: "embedding_profile",
        id: profile.id,
        field: "backend"
      )
    }
    for provider in snapshot.providerConfigurations {
      guard ProviderKind(rawValue: provider.providerRawValue) != nil else {
        throw MosaicPortableBackupError.invalidNormalizedInvariant(
          recordType: "provider_configuration",
          id: provider.id,
          field: "provider"
        )
      }
      if let contextWindowTokens = provider.contextWindowTokens,
        !(2_048...2_000_000).contains(contextWindowTokens)
      {
        throw MosaicPortableBackupError.invalidNormalizedInvariant(
          recordType: "provider_configuration",
          id: provider.id,
          field: "context_window_tokens"
        )
      }
      if let maximumOutputTokens = provider.maximumOutputTokens,
        !(128...1_000_000).contains(maximumOutputTokens)
      {
        throw MosaicPortableBackupError.invalidNormalizedInvariant(
          recordType: "provider_configuration",
          id: provider.id,
          field: "maximum_output_tokens"
        )
      }
    }
    let automaticMemoryRecords = snapshot.extensionRecords.filter(
      AutomaticMemoryPortableArchive.isOwned
    )
    try ExperiencePortableArchive.validate(
      snapshot.extensionRecords.filter(ExperiencePortableArchive.isOwned), snapshot: snapshot)
    try ProviderModelsPortableArchive.validate(
      snapshot.extensionRecords.filter(ProviderModelsPortableArchive.isOwned),
      providers: Set(snapshot.providerConfigurations.map(\.id)), tasks: snapshot.scheduledTasks)
    let projectMemberships = try ProjectPortableArchive.validate(
      snapshot.extensionRecords.filter(ProjectPortableArchive.isOwned),
      conversationIDs: conversationIDs,
      memories: snapshot.memories,
      automaticMemoryTopicScopes: try AutomaticMemoryPortableArchive.topicScopes(
        in: automaticMemoryRecords
      ),
      documentIDs: documentIDs
    )
    try AutomaticMemoryPortableArchive.validate(
      automaticMemoryRecords,
      conversationIDs: conversationIDs,
      messages: snapshot.messages,
      projectIDsByConversation: projectMemberships.projectIDsByConversation,
      projectIDsByTopic: projectMemberships.projectIDsByMemoryTopic
    )
    try validateNormalizedReferencesAndFingerprints(snapshot, limits: limits)

    try validateRecordSizes(snapshot, limits: limits)
  }

  fileprivate static func validateUnique<T: Identifiable>(
    _ records: [T],
    recordType: String
  ) throws where T.ID == UUID {
    var ids: Set<UUID> = []
    for record in records where !ids.insert(record.id).inserted {
      throw MosaicPortableBackupError.duplicateID(recordType: recordType, id: record.id)
    }
  }

  fileprivate static func validateUniqueStrings(
    _ keys: [String],
    recordType: String
  ) throws {
    var seen: Set<String> = []
    for key in keys where !seen.insert(key).inserted {
      throw MosaicPortableBackupError.duplicateKey(recordType: recordType, key: key)
    }
  }

  fileprivate static func validateSourceFieldSizes(
    _ snapshot: MosaicPortableBackupSnapshot
  ) throws {
    for conversation in snapshot.conversations {
      let fields: [(String, Int, Int)] = [
        (
          "conversation_title",
          conversation.title.utf8.count,
          MosaicSourceFieldLimits.maximumConversationTitleUTF8Bytes
        ),
        (
          "conversation_system_prompt",
          conversation.systemPrompt?.utf8.count ?? 0,
          MosaicSourceFieldLimits.maximumConversationSystemPromptUTF8Bytes
        ),
        (
          "conversation_draft",
          conversation.draftText.utf8.count,
          MosaicSourceFieldLimits.maximumConversationDraftUTF8Bytes
        ),
      ]
      for (type, actual, maximum) in fields where actual > maximum {
        throw MosaicPortableBackupError.recordTooLarge(
          recordType: type,
          id: conversation.id,
          actual: actual,
          maximum: maximum
        )
      }
    }
    for message in snapshot.messages {
      let count = message.content.utf8.count
      guard count <= MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes else {
        throw MosaicPortableBackupError.recordTooLarge(
          recordType: "message_content",
          id: message.id,
          actual: count,
          maximum: MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes
        )
      }
    }
    for memory in snapshot.memories {
      let titleCount = memory.title.utf8.count
      guard titleCount <= MosaicSourceFieldLimits.maximumMemoryTitleUTF8Bytes else {
        throw MosaicPortableBackupError.recordTooLarge(
          recordType: "memory_title",
          id: memory.id,
          actual: titleCount,
          maximum: MosaicSourceFieldLimits.maximumMemoryTitleUTF8Bytes
        )
      }
      let contentCount = memory.content.utf8.count
      guard contentCount <= MosaicSourceFieldLimits.maximumMemoryContentUTF8Bytes else {
        throw MosaicPortableBackupError.recordTooLarge(
          recordType: "memory_content",
          id: memory.id,
          actual: contentCount,
          maximum: MosaicSourceFieldLimits.maximumMemoryContentUTF8Bytes
        )
      }
    }
  }

  fileprivate static func validateNormalizedReferencesAndFingerprints(
    _ snapshot: MosaicPortableBackupSnapshot,
    limits: MosaicPortableBackupLimits
  ) throws {
    let maximumCounterValue = max(1, min(limits.maximumTotalBytes, 1_000_000_000))
    let conversationsByID = Dictionary(
      uniqueKeysWithValues: snapshot.conversations.map { ($0.id, $0) })
    let messagesByID = Dictionary(uniqueKeysWithValues: snapshot.messages.map { ($0.id, $0) })
    let artifactsByID = Dictionary(
      uniqueKeysWithValues: snapshot.compactionArtifacts.map { ($0.id, $0) })
    let canonicalMessagesByConversation = Dictionary(
      grouping: snapshot.messages.filter {
        $0.statusRawValue == MessageStatus.complete.rawValue
          && ($0.roleRawValue == MessageRole.user.rawValue
            || $0.roleRawValue == MessageRole.assistant.rawValue)
      },
      by: \.conversationID
    ).mapValues { records in
      records.sorted(by: canonicalMessageOrder)
    }
    let canonicalMessageIndicesByConversation = canonicalMessagesByConversation.mapValues {
      messages in
      Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) })
    }

    for event in snapshot.requestContextEvents {
      guard event.payloadData.count <= NormalizedContextStore.maximumCompactPayloadBytes else {
        throw MosaicPortableBackupError.recordTooLarge(
          recordType: "request_context_event_payload",
          id: event.id,
          actual: event.payloadData.count,
          maximum: NormalizedContextStore.maximumCompactPayloadBytes
        )
      }
      guard conversationsByID[event.conversationID] != nil else {
        throw MosaicPortableBackupError.missingNormalizedReference(
          recordType: "request_context_event",
          id: event.id,
          field: "conversation",
          targetID: event.conversationID
        )
      }
      guard let assistant = messagesByID[event.assistantMessageID],
        assistant.conversationID == event.conversationID,
        assistant.roleRawValue == MessageRole.assistant.rawValue,
        MessageStatus(rawValue: assistant.statusRawValue) != nil
      else {
        throw MosaicPortableBackupError.missingNormalizedReference(
          recordType: "request_context_event",
          id: event.id,
          field: "assistant_message",
          targetID: event.assistantMessageID
        )
      }
      guard let source = messagesByID[event.sourceThroughMessageID],
        source.conversationID == event.conversationID
      else {
        throw MosaicPortableBackupError.missingNormalizedReference(
          recordType: "request_context_event",
          id: event.id,
          field: "source_message",
          targetID: event.sourceThroughMessageID
        )
      }
      guard source.roleRawValue == MessageRole.user.rawValue,
        source.statusRawValue == MessageStatus.complete.rawValue,
        assistant.createdAt >= source.createdAt
      else {
        throw MosaicPortableBackupError.invalidNormalizedInvariant(
          recordType: "request_context_event",
          id: event.id,
          field: "source_message"
        )
      }
      guard (0...maximumCounterValue).contains(event.eventSequence) else {
        throw MosaicPortableBackupError.invalidNormalizedInvariant(
          recordType: "request_context_event",
          id: event.id,
          field: "event_sequence"
        )
      }
      let canonicalMessages = canonicalMessagesByConversation[event.conversationID] ?? []
      let canonicalIndices = canonicalMessageIndicesByConversation[event.conversationID] ?? [:]
      let assistantBoundaryIndex =
        canonicalIndices[assistant.id]
        ?? canonicalInsertionIndex(for: assistant, in: canonicalMessages)
      guard event.sourceMessageCount > 0,
        event.sourceMessageCount <= canonicalMessages.count,
        canonicalMessages[event.sourceMessageCount - 1].id == event.sourceThroughMessageID,
        assistantBoundaryIndex == event.sourceMessageCount
      else {
        throw MosaicPortableBackupError.invalidNormalizedInvariant(
          recordType: "request_context_event",
          id: event.id,
          field: "source_message_count"
        )
      }
      guard
        event.eventKey
          == NormalizedContextStore.eventKey(
            assistantMessageID: event.assistantMessageID,
            eventSequence: event.eventSequence
          )
      else {
        throw MosaicPortableBackupError.invalidNormalizedInvariant(
          recordType: "request_context_event",
          id: event.id,
          field: "event_key"
        )
      }
      guard
        event.id
          == NormalizedContextStore.eventID(
            assistantMessageID: event.assistantMessageID,
            eventSequence: event.eventSequence
          )
      else {
        throw MosaicPortableBackupError.invalidNormalizedInvariant(
          recordType: "request_context_event",
          id: event.id,
          field: "id"
        )
      }
      guard fingerprint(event.payloadData) == event.payloadFingerprint
      else {
        throw MosaicPortableBackupError.normalizedFingerprintMismatch(
          recordType: "request_context_event",
          id: event.id
        )
      }
    }

    for artifact in snapshot.compactionArtifacts {
      guard conversationsByID[artifact.conversationID] != nil else {
        throw MosaicPortableBackupError.missingNormalizedReference(
          recordType: "compaction_artifact",
          id: artifact.id,
          field: "conversation",
          targetID: artifact.conversationID
        )
      }
      guard
        artifact.providerKindRawValue.map({ ProviderKind(rawValue: $0) != nil }) ?? true
      else {
        throw MosaicPortableBackupError.invalidNormalizedInvariant(
          recordType: "compaction_artifact",
          id: artifact.id,
          field: "provider_kind"
        )
      }
      guard let mode = ConversationCompactionMode(rawValue: artifact.modeRawValue) else {
        throw MosaicPortableBackupError.invalidNormalizedInvariant(
          recordType: "compaction_artifact",
          id: artifact.id,
          field: "mode"
        )
      }
      if let parentID = artifact.coverageParentArtifactID {
        guard let parent = artifactsByID[parentID], parent.conversationID == artifact.conversationID
        else {
          throw MosaicPortableBackupError.missingNormalizedReference(
            recordType: "compaction_artifact",
            id: artifact.id,
            field: "coverage_parent",
            targetID: parentID
          )
        }
        guard artifact.lineagePreviousCompactionID == parentID,
          !artifact.isDetachedCoverageRoot
        else {
          throw MosaicPortableBackupError.invalidNormalizedInvariant(
            recordType: "compaction_artifact",
            id: artifact.id,
            field: "coverage_lineage"
          )
        }
      } else if artifact.isDetachedCoverageRoot {
        guard artifact.lineagePreviousCompactionID != nil else {
          throw MosaicPortableBackupError.invalidNormalizedInvariant(
            recordType: "compaction_artifact",
            id: artifact.id,
            field: "detached_coverage_root"
          )
        }
      } else if artifact.lineagePreviousCompactionID != nil {
        throw MosaicPortableBackupError.invalidNormalizedInvariant(
          recordType: "compaction_artifact",
          id: artifact.id,
          field: "coverage_lineage"
        )
      }
      switch mode {
      case .initial:
        guard artifact.chainDepth == 1,
          artifact.lineagePreviousCompactionID == nil,
          artifact.coverageParentArtifactID == nil,
          !artifact.isDetachedCoverageRoot
        else {
          throw MosaicPortableBackupError.invalidNormalizedInvariant(
            recordType: "compaction_artifact",
            id: artifact.id,
            field: "chain_depth"
          )
        }
      case .rebuild:
        guard artifact.chainDepth == 1,
          artifact.lineagePreviousCompactionID != nil
        else {
          throw MosaicPortableBackupError.invalidNormalizedInvariant(
            recordType: "compaction_artifact",
            id: artifact.id,
            field: "chain_depth"
          )
        }
      case .extend:
        if let parentID = artifact.coverageParentArtifactID,
          let parent = artifactsByID[parentID]
        {
          let (expectedDepth, overflow) = parent.chainDepth.addingReportingOverflow(1)
          guard !overflow, artifact.chainDepth == expectedDepth else {
            throw MosaicPortableBackupError.invalidNormalizedInvariant(
              recordType: "compaction_artifact",
              id: artifact.id,
              field: "chain_depth"
            )
          }
        } else {
          guard artifact.isDetachedCoverageRoot, artifact.chainDepth >= 2 else {
            throw MosaicPortableBackupError.invalidNormalizedInvariant(
              recordType: "compaction_artifact",
              id: artifact.id,
              field: "chain_depth"
            )
          }
        }
      }
      guard (0...maximumCounterValue).contains(artifact.coveredMessageCount),
        (0...maximumCounterValue).contains(artifact.chainDepth),
        (0...maximumCounterValue).contains(artifact.estimatedSourceTokens),
        (0...maximumCounterValue).contains(artifact.estimatedSummaryTokens)
      else {
        throw MosaicPortableBackupError.invalidNormalizedInvariant(
          recordType: "compaction_artifact",
          id: artifact.id,
          field: "counts"
        )
      }
      guard try compactionArtifactFingerprint(artifact) == artifact.payloadFingerprint else {
        throw MosaicPortableBackupError.normalizedFingerprintMismatch(
          recordType: "compaction_artifact",
          id: artifact.id
        )
      }
    }

    try validateCompactionCoverage(
      artifactsByID: artifactsByID,
      canonicalMessagesByConversation: canonicalMessagesByConversation
    )

    for head in snapshot.conversationCompactionHeads {
      guard conversationsByID[head.conversationID] != nil else {
        throw MosaicPortableBackupError.missingNormalizedReference(
          recordType: "conversation_compaction_head",
          id: head.conversationID,
          field: "conversation",
          targetID: head.conversationID
        )
      }
      if let artifactID = head.activeArtifactID {
        guard let artifact = artifactsByID[artifactID],
          artifact.conversationID == head.conversationID
        else {
          throw MosaicPortableBackupError.missingNormalizedReference(
            recordType: "conversation_compaction_head",
            id: head.conversationID,
            field: "active_artifact",
            targetID: artifactID
          )
        }
        guard artifact.isSnapshotComplete else {
          throw MosaicPortableBackupError.invalidNormalizedInvariant(
            recordType: "conversation_compaction_head",
            id: head.conversationID,
            field: "active_artifact_complete"
          )
        }
      }
      guard (0...maximumCounterValue).contains(head.revision) else {
        throw MosaicPortableBackupError.invalidNormalizedInvariant(
          recordType: "conversation_compaction_head",
          id: head.conversationID,
          field: "revision"
        )
      }
    }

    for progress in snapshot.normalizedBackfillProgress {
      let id = deterministicUUID(progress.migrationKey)
      let (combinedCount, countOverflow) = progress.migratedCount.addingReportingOverflow(
        progress.retainedLegacyCount
      )
      guard (0...maximumCounterValue).contains(progress.processedCount),
        (0...maximumCounterValue).contains(progress.migratedCount),
        (0...maximumCounterValue).contains(progress.retainedLegacyCount),
        (0...maximumCounterValue).contains(progress.failureCount),
        !countOverflow,
        progress.processedCount == combinedCount,
        progress.failureCount <= progress.retainedLegacyCount
      else {
        throw MosaicPortableBackupError.invalidNormalizedInvariant(
          recordType: "normalized_backfill_progress",
          id: id,
          field: "counts"
        )
      }
    }
  }

  static func validateCompactionCoverage(
    artifactsByID: [UUID: MosaicPortableCompactionArtifact],
    canonicalMessagesByConversation: [UUID: [MosaicPortableMessage]]
  ) throws {
    var resolvedCoverageCounts: [UUID: Int] = [:]
    var resolvedCoverageDepths: [UUID: Int] = [:]
    var sourceFingerprintsByConversation: [UUID: [Int: String]] = [:]
    var requestedCountsByConversation: [UUID: Set<Int>] = [:]

    for artifact in artifactsByID.values where artifact.isSnapshotComplete {
      requestedCountsByConversation[artifact.conversationID, default: []].insert(
        artifact.coveredMessageCount
      )
    }

    for (conversationID, canonicalMessages) in canonicalMessagesByConversation {
      sourceFingerprintsByConversation[conversationID] = compactionSourceFingerprints(
        for: canonicalMessages,
        requestedCounts: requestedCountsByConversation[conversationID] ?? []
      )
    }

    for artifact in artifactsByID.values {
      try Task.checkCancellation()

      var unresolvedPath: [MosaicPortableCompactionArtifact] = []
      var unresolvedIDs: Set<UUID> = []
      var cursor: MosaicPortableCompactionArtifact? = artifact
      var inheritedCoverageCount = 0
      var inheritedCoverageDepth = 0

      while let current = cursor {
        if let resolvedCount = resolvedCoverageCounts[current.id] {
          inheritedCoverageCount = resolvedCount
          inheritedCoverageDepth = resolvedCoverageDepths[current.id] ?? 0
          break
        }
        guard unresolvedIDs.insert(current.id).inserted else {
          throw MosaicPortableBackupError.normalizedReferenceCycle(
            recordType: "compaction_artifact",
            id: current.id
          )
        }
        guard unresolvedPath.count < maximumCompactionCoverageDepth else {
          throw MosaicPortableBackupError.invalidNormalizedInvariant(
            recordType: "compaction_artifact",
            id: current.id,
            field: "coverage_depth"
          )
        }
        unresolvedPath.append(current)
        cursor = current.coverageParentArtifactID.flatMap { artifactsByID[$0] }
      }

      for current in unresolvedPath.reversed() {
        try Task.checkCancellation()
        guard inheritedCoverageDepth < maximumCompactionCoverageDepth else {
          throw MosaicPortableBackupError.invalidNormalizedInvariant(
            recordType: "compaction_artifact",
            id: current.id,
            field: "coverage_depth"
          )
        }
        let delta: [UUID]
        do {
          delta = try decoder.decode([UUID].self, from: current.coverageDeltaData)
        } catch {
          throw MosaicPortableBackupError.invalidNormalizedInvariant(
            recordType: "compaction_artifact",
            id: current.id,
            field: "coverage_delta"
          )
        }

        let canonicalMessages = canonicalMessagesByConversation[current.conversationID] ?? []
        guard inheritedCoverageCount <= current.coveredMessageCount,
          current.coveredMessageCount <= canonicalMessages.count,
          delta.count == current.coveredMessageCount - inheritedCoverageCount,
          delta.elementsEqual(
            canonicalMessages[inheritedCoverageCount..<current.coveredMessageCount].lazy.map(\.id)
          )
        else {
          throw MosaicPortableBackupError.invalidNormalizedInvariant(
            recordType: "compaction_artifact",
            id: current.id,
            field: "covered_message_count"
          )
        }

        if current.isSnapshotComplete {
          guard current.coveredMessageCount > 0,
            canonicalMessages[current.coveredMessageCount - 1].roleRawValue
              == MessageRole.assistant.rawValue,
            ConversationCompactionMode(rawValue: current.modeRawValue) != nil,
            current.promptVersion == ConversationCompactionPrompt.version,
            let contentData = current.contentData,
            let content = try? decoder.decode(
              ConversationCompactionContent.self,
              from: contentData
            ),
            content.schemaVersion == ConversationCompactionContent.currentSchemaVersion,
            current.contentSchemaVersion == content.schemaVersion,
            let sourceFingerprint = current.sourceFingerprint,
            sourceFingerprintsByConversation[current.conversationID]?[current.coveredMessageCount]
              == sourceFingerprint,
            current.providerConfigurationID != nil,
            current.providerKindRawValue.flatMap(ProviderKind.init(rawValue:)) != nil,
            current.providerDisplayName != nil,
            current.providerEndpoint != nil,
            current.modelIdentifier != nil,
            (try? decoder.decode([String].self, from: current.warningsData)) != nil,
            renderedSummary(for: content) == current.renderedSummary
          else {
            throw MosaicPortableBackupError.invalidNormalizedInvariant(
              recordType: "compaction_artifact",
              id: current.id,
              field: "complete_snapshot"
            )
          }
        }

        resolvedCoverageCounts[current.id] = current.coveredMessageCount
        inheritedCoverageDepth += 1
        resolvedCoverageDepths[current.id] = inheritedCoverageDepth
        inheritedCoverageCount = current.coveredMessageCount
      }
    }
  }

  /// Computes every requested prefix digest in one pass so a backup containing a long summary
  /// lineage cannot amplify validation into quadratic hashing work.
  fileprivate static func compactionSourceFingerprints(
    for canonicalMessages: [MosaicPortableMessage],
    requestedCounts: Set<Int>
  ) -> [Int: String] {
    var hasher = SHA256()
    var fingerprints: [Int: String] = [:]
    for (index, message) in canonicalMessages.enumerated() {
      updateLengthPrefixed(message.id.uuidString.lowercased(), hasher: &hasher)
      updateLengthPrefixed(message.roleRawValue, hasher: &hasher)
      updateLengthPrefixed(MessageStatus.complete.rawValue, hasher: &hasher)
      updateLengthPrefixed(message.content, hasher: &hasher)
      let count = index + 1
      if requestedCounts.contains(count) {
        let prefixHasher = hasher
        fingerprints[count] = prefixHasher.finalize().map { String(format: "%02x", $0) }
          .joined()
      }
    }
    return fingerprints
  }

  fileprivate static func updateLengthPrefixed<H: HashFunction>(
    _ value: String,
    hasher: inout H
  ) {
    let bytes = Data(value.utf8)
    hasher.update(data: Data("\(bytes.count):".utf8))
    hasher.update(data: bytes)
  }

  fileprivate static func renderedSummary(for content: ConversationCompactionContent) -> String {
    var lines = [content.overview.trimmingCharacters(in: .whitespacesAndNewlines)]
      .filter { !$0.isEmpty }
    for item in content.items {
      let label =
        switch item.kind {
        case .goal: "Current goal"
        case .preference: "Preference"
        case .fact: "Fact"
        case .constraint: "Constraint"
        case .decision: "Decision"
        case .completed: "Completed"
        case .correction: "Correction"
        case .openLoop: "Open loop"
        }
      lines.append("- \(label): \(item.text)")
    }
    return lines.joined(separator: "\n")
  }

  fileprivate static func fingerprint(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  fileprivate static func validateRecordSizes(
    _ snapshot: MosaicPortableBackupSnapshot,
    limits: MosaicPortableBackupLimits
  ) throws {
    try validateRecordSizes(snapshot.conversations, type: "conversation", limits: limits)
    try validateRecordSizes(snapshot.messages, type: "message", limits: limits)
    try validateRecordSizes(snapshot.memories, type: "memory", limits: limits)
    try validateRecordSizes(snapshot.scheduledTasks, type: "scheduled_task", limits: limits)
    try validateRecordSizes(
      snapshot.providerConfigurations,
      type: "provider_configuration",
      limits: limits
    )
    try validateRecordSizes(snapshot.embeddingProfiles, type: "embedding_profile", limits: limits)
    try validateRecordSizes(snapshot.importedDocuments, type: "imported_document", limits: limits)
    try validateRecordSizes(snapshot.documentChunks, type: "document_chunk", limits: limits)
    try validateRecordSizes(
      snapshot.requestContextEvents,
      type: "request_context_event",
      limits: limits
    )
    try validateRecordSizes(
      snapshot.compactionArtifacts,
      type: "compaction_artifact",
      limits: limits
    )
    try validateRecordSizes(
      snapshot.conversationCompactionHeads,
      type: "conversation_compaction_head",
      limits: limits
    )
    try validateBackfillProgressRecordSizes(snapshot.normalizedBackfillProgress, limits: limits)
    try validateRecordSizes(snapshot.extensionRecords, type: "extension_record", limits: limits)
  }

  fileprivate static func validateRecordSizes<T: Encodable & Identifiable>(
    _ records: [T],
    type: String,
    limits: MosaicPortableBackupLimits
  ) throws where T.ID == UUID {
    for record in records {
      let count = try encoder.encode(record).count
      guard count <= limits.maximumRecordBytes else {
        throw MosaicPortableBackupError.recordTooLarge(
          recordType: type,
          id: record.id,
          actual: count,
          maximum: limits.maximumRecordBytes
        )
      }
    }
  }

  fileprivate static func validateBackfillProgressRecordSizes(
    _ records: [MosaicPortableNormalizedContextBackfillProgress],
    limits: MosaicPortableBackupLimits
  ) throws {
    for record in records {
      let count = try encoder.encode(record).count
      guard count <= limits.maximumRecordBytes else {
        throw MosaicPortableBackupError.recordTooLarge(
          recordType: "normalized_backfill_progress",
          id: deterministicUUID(record.migrationKey),
          actual: count,
          maximum: limits.maximumRecordBytes
        )
      }
    }
  }

  fileprivate static func deterministicUUID(_ value: String) -> UUID {
    let bytes = Array(SHA256.hash(data: Data(value.utf8)))
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      )
    )
  }

  fileprivate static func transformForRestore(
    _ snapshot: MosaicPortableBackupSnapshot,
    limits: MosaicPortableBackupLimits
  ) throws -> MosaicPortableRestorePlan {
    let originalProviderIDs = Set(snapshot.providerConfigurations.map(\.id))
    var replacementIDs: Set<UUID> = []
    var providerIDMap: [UUID: UUID] = [:]
    for oldID in originalProviderIDs.sorted(by: uuidOrder) {
      var newID = UUID()
      while originalProviderIDs.contains(newID) || !replacementIDs.insert(newID).inserted {
        newID = UUID()
      }
      providerIDMap[oldID] = newID
    }
    let conversationIDs = Set(snapshot.conversations.map(\.id))
    let automaticMemoryRecords = try AutomaticMemoryPortableArchive.remapProviderConfigurationIDs(
      in: snapshot.extensionRecords.filter(AutomaticMemoryPortableArchive.isOwned),
      using: providerIDMap
    )
    let projectRecords = try ProjectPortableArchive.remapProviderConfigurationIDs(
      in: snapshot.extensionRecords.filter(ProjectPortableArchive.isOwned),
      using: providerIDMap
    )
    let modelRecords = try ProviderModelsPortableArchive.remapProviderConfigurationIDs(
      in: snapshot.extensionRecords.filter(ProviderModelsPortableArchive.isOwned),
      using: providerIDMap)
    let extensionRecords =
      (snapshot.extensionRecords.filter { !isSupportedExtensionRecord($0) }
      + automaticMemoryRecords + projectRecords + modelRecords
      + (try ExperiencePortableArchive.remap(
        snapshot.extensionRecords.filter(ExperiencePortableArchive.isOwned), using: providerIDMap)))
      .sorted(by: extensionRecordOrder)

    let transformed = MosaicPortableBackupSnapshot(
      backupID: snapshot.backupID,
      createdAt: snapshot.createdAt,
      sourceSchemaVersion: snapshot.sourceSchemaVersion,
      conversations: snapshot.conversations.map { item in
        MosaicPortableConversation(
          id: item.id,
          title: item.title,
          providerConfigurationID: item.providerConfigurationID.flatMap { providerIDMap[$0] },
          modelIdentifier: item.modelIdentifier,
          systemPrompt: item.systemPrompt,
          draftText: item.draftText,
          compactionSnapshotData: item.compactionSnapshotData,
          isArchived: item.isArchived,
          createdAt: item.createdAt,
          updatedAt: item.updatedAt
        )
      },
      messages: snapshot.messages,
      memories: snapshot.memories.map { item in
        let isOrphan =
          item.scopeRawValue == MemoryScope.conversation.rawValue
          && item.conversationID.map { !conversationIDs.contains($0) } != false
        return MosaicPortableMemory(
          id: item.id,
          title: item.title,
          content: item.content,
          scopeRawValue: item.scopeRawValue,
          conversationID: isOrphan ? nil : item.conversationID,
          isEnabled: isOrphan ? false : item.isEnabled,
          isUserApproved: item.isUserApproved,
          createdAt: item.createdAt,
          updatedAt: item.updatedAt
        )
      },
      scheduledTasks: snapshot.scheduledTasks.map { item in
        MosaicPortableScheduledTask(
          id: item.id,
          title: item.title,
          prompt: item.prompt,
          conversationID: item.conversationID.flatMap { conversationIDs.contains($0) ? $0 : nil },
          providerConfigurationID: item.providerConfigurationID.flatMap { providerIDMap[$0] },
          recurrenceRawValue: item.recurrenceRawValue,
          statusRawValue: ScheduledTaskStatus.paused.rawValue,
          scheduledAt: item.scheduledAt,
          timeZoneIdentifier: item.timeZoneIdentifier,
          nextRunAt: item.nextRunAt,
          lastRunAt: item.lastRunAt,
          lastError: item.lastError,
          createdAt: item.createdAt,
          updatedAt: item.updatedAt
        )
      },
      providerConfigurations: snapshot.providerConfigurations.map { item in
        MosaicPortableProviderConfiguration(
          id: providerIDMap[item.id] ?? item.id,
          displayName: item.displayName,
          providerRawValue: item.providerRawValue,
          modelIdentifier: item.modelIdentifier,
          baseURLString: item.baseURLString,
          contextWindowTokens: item.contextWindowTokens,
          maximumOutputTokens: item.maximumOutputTokens,
          // A portable archive is untrusted input. Even keyless adapters (custom and Ollama) must
          // not become an immediately usable exfiltration destination after restore.
          isEnabled: false,
          createdAt: item.createdAt,
          updatedAt: item.updatedAt
        )
      },
      embeddingProfiles: snapshot.embeddingProfiles.map { item in
        let mappedProviderID = item.providerConfigurationID.flatMap { providerIDMap[$0] }
        let isOrphanProviderProfile =
          item.backendRawValue == EmbeddingBackend.provider.rawValue
          && mappedProviderID == nil
        return MosaicPortableEmbeddingProfile(
          id: item.id,
          displayName: item.displayName,
          backendRawValue: item.backendRawValue,
          providerConfigurationID: mappedProviderID,
          modelIdentifier: item.modelIdentifier,
          weight: item.weight,
          isEnabled: isOrphanProviderProfile ? false : item.isEnabled,
          indexesConversations: item.indexesConversations,
          indexesDocuments: item.indexesDocuments,
          createdAt: item.createdAt,
          updatedAt: item.updatedAt
        )
      },
      importedDocuments: snapshot.importedDocuments,
      documentChunks: snapshot.documentChunks,
      requestContextEvents: snapshot.requestContextEvents,
      compactionArtifacts: snapshot.compactionArtifacts,
      conversationCompactionHeads: snapshot.conversationCompactionHeads,
      normalizedBackfillProgress: snapshot.normalizedBackfillProgress,
      extensionRecords: extensionRecords
    )
    return MosaicPortableRestorePlan(
      backupID: snapshot.backupID,
      snapshot: sorted(transformed),
      providerIDMap: providerIDMap,
      limits: limits
    )
  }

  fileprivate static func sorted(
    _ snapshot: MosaicPortableBackupSnapshot
  ) -> MosaicPortableBackupSnapshot {
    MosaicPortableBackupSnapshot(
      backupID: snapshot.backupID,
      createdAt: snapshot.createdAt,
      sourceSchemaVersion: snapshot.sourceSchemaVersion,
      conversations: snapshot.conversations.sorted(by: idOrder),
      messages: snapshot.messages.sorted(by: idOrder),
      memories: snapshot.memories.sorted(by: idOrder),
      scheduledTasks: snapshot.scheduledTasks.sorted(by: idOrder),
      providerConfigurations: snapshot.providerConfigurations.sorted(by: idOrder),
      embeddingProfiles: snapshot.embeddingProfiles.sorted(by: idOrder),
      importedDocuments: snapshot.importedDocuments.sorted(by: idOrder),
      documentChunks: snapshot.documentChunks.sorted(by: idOrder),
      requestContextEvents: snapshot.requestContextEvents.sorted(by: idOrder),
      compactionArtifacts: snapshot.compactionArtifacts.sorted(by: idOrder),
      conversationCompactionHeads: snapshot.conversationCompactionHeads.sorted(by: idOrder),
      normalizedBackfillProgress: snapshot.normalizedBackfillProgress.sorted {
        $0.migrationKey < $1.migrationKey
      },
      extensionRecords: snapshot.extensionRecords.sorted(by: extensionRecordOrder)
    )
  }

  fileprivate static func insert(
    _ snapshot: MosaicPortableBackupSnapshot,
    into modelContext: ModelContext,
    honorsCancellation: Bool = true
  ) throws {
    for item in snapshot.providerConfigurations {
      try checkCancellation(if: honorsCancellation)
      let record = ProviderConfigurationRecord(
        id: item.id,
        displayName: item.displayName,
        provider: ProviderKind(rawValue: item.providerRawValue) ?? .custom,
        modelIdentifier: item.modelIdentifier,
        baseURL: item.baseURLString.flatMap(URL.init(string:)),
        contextWindowTokens: item.contextWindowTokens,
        maximumOutputTokens: item.maximumOutputTokens,
        isEnabled: item.isEnabled,
        createdAt: item.createdAt,
        updatedAt: item.updatedAt
      )
      record.providerRawValue = item.providerRawValue
      record.baseURLString = item.baseURLString
      modelContext.insert(record)
    }
    for item in snapshot.conversations {
      try checkCancellation(if: honorsCancellation)
      let record = ConversationRecord(
        id: item.id,
        title: item.title,
        providerConfigurationID: item.providerConfigurationID,
        modelIdentifier: item.modelIdentifier,
        systemPrompt: item.systemPrompt,
        draftText: item.draftText,
        isArchived: item.isArchived,
        createdAt: item.createdAt,
        updatedAt: item.updatedAt
      )
      record.compactionSnapshotData = item.compactionSnapshotData
      modelContext.insert(record)
    }
    for item in snapshot.messages {
      try checkCancellation(if: honorsCancellation)
      let record = MessageRecord(
        id: item.id,
        conversationID: item.conversationID,
        role: MessageRole(rawValue: item.roleRawValue) ?? .assistant,
        content: item.content,
        status: MessageStatus(rawValue: item.statusRawValue) ?? .complete,
        providerConfigurationID: item.providerConfigurationID,
        providerKind: item.providerKindRawValue.flatMap(ProviderKind.init(rawValue:)),
        providerDisplayName: item.providerDisplayName,
        providerHost: item.providerHost,
        providerMessageID: item.providerMessageID,
        modelIdentifier: item.modelIdentifier,
        inputTokenCount: item.inputTokenCount,
        outputTokenCount: item.outputTokenCount,
        errorDescription: item.errorDescription,
        createdAt: item.createdAt,
        updatedAt: item.updatedAt
      )
      record.roleRawValue = item.roleRawValue
      record.statusRawValue = item.statusRawValue
      record.providerKindRawValue = item.providerKindRawValue
      record.contextReceiptData = item.contextReceiptData
      modelContext.insert(record)
    }
    for item in snapshot.memories {
      try checkCancellation(if: honorsCancellation)
      let record = MemoryRecord(
        id: item.id,
        title: item.title,
        content: item.content,
        scope: MemoryScope(rawValue: item.scopeRawValue) ?? .global,
        conversationID: item.conversationID,
        isEnabled: item.isEnabled,
        isUserApproved: item.isUserApproved,
        createdAt: item.createdAt,
        updatedAt: item.updatedAt
      )
      record.scopeRawValue = item.scopeRawValue
      modelContext.insert(record)
    }
    for item in snapshot.scheduledTasks {
      try checkCancellation(if: honorsCancellation)
      let record = ScheduledTaskRecord(
        id: item.id,
        title: item.title,
        prompt: item.prompt,
        conversationID: item.conversationID,
        providerConfigurationID: item.providerConfigurationID,
        recurrence: ScheduleRecurrence(rawValue: item.recurrenceRawValue) ?? .once,
        status: ScheduledTaskStatus(rawValue: item.statusRawValue) ?? .paused,
        scheduledAt: item.scheduledAt,
        timeZoneIdentifier: item.timeZoneIdentifier,
        nextRunAt: item.nextRunAt,
        lastRunAt: item.lastRunAt,
        lastError: item.lastError,
        createdAt: item.createdAt,
        updatedAt: item.updatedAt
      )
      record.recurrenceRawValue = item.recurrenceRawValue
      record.statusRawValue = item.statusRawValue
      modelContext.insert(record)
    }
    for item in snapshot.embeddingProfiles {
      try checkCancellation(if: honorsCancellation)
      let record = EmbeddingProfileRecord(
        id: item.id,
        displayName: item.displayName,
        backend: EmbeddingBackend(rawValue: item.backendRawValue) ?? .provider,
        providerConfigurationID: item.providerConfigurationID,
        modelIdentifier: item.modelIdentifier,
        weight: item.weight,
        isEnabled: item.isEnabled,
        indexesConversations: item.indexesConversations,
        indexesDocuments: item.indexesDocuments,
        createdAt: item.createdAt,
        updatedAt: item.updatedAt
      )
      record.backendRawValue = item.backendRawValue
      modelContext.insert(record)
    }
    for item in snapshot.importedDocuments {
      try checkCancellation(if: honorsCancellation)
      modelContext.insert(
        ImportedDocumentRecord(
          id: item.id,
          title: item.title,
          sourceFilename: item.sourceFilename,
          mimeType: item.mimeType,
          contentFingerprint: item.contentFingerprint,
          characterCount: item.characterCount,
          pageCount: item.pageCount,
          ocrPageCount: item.ocrPageCount,
          ocrFallbackPageCount: item.ocrFallbackPageCount,
          isEnabled: item.isEnabled,
          createdAt: item.createdAt,
          updatedAt: item.updatedAt
        )
      )
    }
    for item in snapshot.documentChunks {
      try checkCancellation(if: honorsCancellation)
      modelContext.insert(
        DocumentChunkRecord(
          id: item.id,
          documentID: item.documentID,
          chunkIndex: item.chunkIndex,
          content: item.content,
          pageNumber: item.pageNumber,
          isOCRDerived: item.isOCRDerived,
          createdAt: item.createdAt
        )
      )
    }
    for item in snapshot.requestContextEvents {
      try checkCancellation(if: honorsCancellation)
      modelContext.insert(
        RequestContextEventRecord(
          id: item.id,
          eventKey: item.eventKey,
          assistantMessageID: item.assistantMessageID,
          conversationID: item.conversationID,
          sourceThroughMessageID: item.sourceThroughMessageID,
          sourceMessageCount: item.sourceMessageCount,
          eventSequence: item.eventSequence,
          payloadData: item.payloadData,
          payloadFingerprint: item.payloadFingerprint,
          legacyReceiptFingerprint: item.legacyReceiptFingerprint,
          createdAt: item.createdAt
        )
      )
    }
    for item in snapshot.compactionArtifacts {
      try checkCancellation(if: honorsCancellation)
      modelContext.insert(
        CompactionArtifactRecord(
          id: item.id,
          conversationID: item.conversationID,
          lineagePreviousCompactionID: item.lineagePreviousCompactionID,
          coverageParentArtifactID: item.coverageParentArtifactID,
          coverageDeltaData: item.coverageDeltaData,
          coveredMessageCount: item.coveredMessageCount,
          modeRawValue: item.modeRawValue,
          promptVersion: item.promptVersion,
          contentSchemaVersion: item.contentSchemaVersion,
          contentData: item.contentData,
          renderedSummary: item.renderedSummary,
          sourceFingerprint: item.sourceFingerprint,
          providerConfigurationID: item.providerConfigurationID,
          providerKindRawValue: item.providerKindRawValue,
          providerDisplayName: item.providerDisplayName,
          providerEndpoint: item.providerEndpoint,
          modelIdentifier: item.modelIdentifier,
          providerMessageID: item.providerMessageID,
          inputTokenCount: item.inputTokenCount,
          outputTokenCount: item.outputTokenCount,
          estimatedSourceTokens: item.estimatedSourceTokens,
          estimatedSummaryTokens: item.estimatedSummaryTokens,
          chainDepth: item.chainDepth,
          warningsData: item.warningsData,
          isSnapshotComplete: item.isSnapshotComplete,
          isDetachedCoverageRoot: item.isDetachedCoverageRoot,
          payloadFingerprint: item.payloadFingerprint,
          createdAt: item.createdAt
        )
      )
    }
    for item in snapshot.conversationCompactionHeads {
      try checkCancellation(if: honorsCancellation)
      modelContext.insert(
        ConversationCompactionHeadRecord(
          conversationID: item.conversationID,
          activeArtifactID: item.activeArtifactID,
          revision: item.revision,
          updatedAt: item.updatedAt
        )
      )
    }
    for item in snapshot.normalizedBackfillProgress {
      try checkCancellation(if: honorsCancellation)
      modelContext.insert(
        NormalizedContextBackfillProgressRecord(
          migrationKey: item.migrationKey,
          lastEventKey: item.lastEventKey,
          processedCount: item.processedCount,
          migratedCount: item.migratedCount,
          retainedLegacyCount: item.retainedLegacyCount,
          failureCount: item.failureCount,
          isComplete: item.isComplete,
          updatedAt: item.updatedAt
        )
      )
    }
    if let unsupported = snapshot.extensionRecords.first(where: {
      !isSupportedExtensionRecord($0)
    }) {
      throw MosaicPortableBackupError.unsupportedExtensionRecord(
        namespace: unsupported.namespace,
        recordType: unsupported.recordType,
        version: unsupported.recordVersion
      )
    }
    try AutomaticMemoryPortableArchive.insert(
      snapshot.extensionRecords.filter(AutomaticMemoryPortableArchive.isOwned),
      into: modelContext,
      honorsCancellation: honorsCancellation
    )
    try ExperiencePortableArchive.insert(
      snapshot.extensionRecords.filter(ExperiencePortableArchive.isOwned), into: modelContext)
    try ProviderModelsPortableArchive.insert(
      snapshot.extensionRecords.filter(ProviderModelsPortableArchive.isOwned),
      into: modelContext, honorsCancellation: honorsCancellation)
    try ProjectPortableArchive.insert(
      snapshot.extensionRecords.filter(ProjectPortableArchive.isOwned),
      into: modelContext,
      honorsCancellation: honorsCancellation
    )
  }

  /// Fetches only a small keyset page at a time while preserving per-model, rollbackable deletes.
  /// SwiftData must track deleted models until the single replacement save; the compensation
  /// snapshot captured before this scan has already bounded that aggregate row and byte volume.
  fileprivate static func deleteKeyedRecords<Source: PersistentModel, Key: Comparable>(
    in modelContext: ModelContext,
    makeDescriptor: (Key?) -> FetchDescriptor<Source>,
    key: (Source) -> Key,
    honorsCancellation: Bool
  ) throws {
    var cursor: Key?
    while true {
      try checkCancellation(if: honorsCancellation)
      var descriptor = makeDescriptor(cursor)
      descriptor.fetchLimit = captureFetchPageSize
      descriptor.includePendingChanges = false
      let page = try modelContext.fetch(descriptor)
      guard !page.isEmpty else { break }

      for source in page {
        try checkCancellation(if: honorsCancellation)
        let sourceKey = key(source)
        guard cursor.map({ sourceKey > $0 }) ?? true else {
          throw MosaicPortableBackupError.persistenceFailure
        }
        modelContext.delete(source)
        cursor = sourceKey
      }
      if page.count < captureFetchPageSize { break }
    }
  }

  fileprivate static func deleteAllSourceRecords(
    in modelContext: ModelContext,
    honorsCancellation: Bool = true
  ) throws {
    try ExperiencePortableArchive.deleteAll(in: modelContext)
    try ProviderModelsPortableArchive.deleteAll(
      from: modelContext, honorsCancellation: honorsCancellation)
    try ProjectPortableArchive.deleteAll(
      in: modelContext,
      honorsCancellation: honorsCancellation
    )
    try AutomaticMemoryPortableArchive.deleteAll(
      in: modelContext,
      honorsCancellation: honorsCancellation
    )
    try deleteKeyedRecords(
      in: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<RequestContextEventRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\RequestContextEventRecord.id)]
          )
        }
        return FetchDescriptor<RequestContextEventRecord>(
          sortBy: [SortDescriptor(\RequestContextEventRecord.id)]
        )
      },
      key: \RequestContextEventRecord.id,
      honorsCancellation: honorsCancellation
    )
    try deleteKeyedRecords(
      in: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<ConversationCompactionHeadRecord>(
            predicate: #Predicate { $0.conversationID > cursor },
            sortBy: [SortDescriptor(\ConversationCompactionHeadRecord.conversationID)]
          )
        }
        return FetchDescriptor<ConversationCompactionHeadRecord>(
          sortBy: [SortDescriptor(\ConversationCompactionHeadRecord.conversationID)]
        )
      },
      key: \ConversationCompactionHeadRecord.conversationID,
      honorsCancellation: honorsCancellation
    )
    try deleteKeyedRecords(
      in: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<CompactionArtifactRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\CompactionArtifactRecord.id)]
          )
        }
        return FetchDescriptor<CompactionArtifactRecord>(
          sortBy: [SortDescriptor(\CompactionArtifactRecord.id)]
        )
      },
      key: \CompactionArtifactRecord.id,
      honorsCancellation: honorsCancellation
    )
    try deleteKeyedRecords(
      in: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<NormalizedContextBackfillProgressRecord>(
            predicate: #Predicate { $0.migrationKey > cursor },
            sortBy: [SortDescriptor(\NormalizedContextBackfillProgressRecord.migrationKey)]
          )
        }
        return FetchDescriptor<NormalizedContextBackfillProgressRecord>(
          sortBy: [SortDescriptor(\NormalizedContextBackfillProgressRecord.migrationKey)]
        )
      },
      key: \NormalizedContextBackfillProgressRecord.migrationKey,
      honorsCancellation: honorsCancellation
    )
    try deleteKeyedRecords(
      in: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\MessageRecord.id)]
          )
        }
        return FetchDescriptor<MessageRecord>(sortBy: [SortDescriptor(\MessageRecord.id)])
      },
      key: \MessageRecord.id,
      honorsCancellation: honorsCancellation
    )
    try deleteKeyedRecords(
      in: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<MemoryRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\MemoryRecord.id)]
          )
        }
        return FetchDescriptor<MemoryRecord>(sortBy: [SortDescriptor(\MemoryRecord.id)])
      },
      key: \MemoryRecord.id,
      honorsCancellation: honorsCancellation
    )
    try deleteKeyedRecords(
      in: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<ScheduledTaskRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\ScheduledTaskRecord.id)]
          )
        }
        return FetchDescriptor<ScheduledTaskRecord>(
          sortBy: [SortDescriptor(\ScheduledTaskRecord.id)]
        )
      },
      key: \ScheduledTaskRecord.id,
      honorsCancellation: honorsCancellation
    )
    try deleteKeyedRecords(
      in: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<EmbeddingProfileRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\EmbeddingProfileRecord.id)]
          )
        }
        return FetchDescriptor<EmbeddingProfileRecord>(
          sortBy: [SortDescriptor(\EmbeddingProfileRecord.id)]
        )
      },
      key: \EmbeddingProfileRecord.id,
      honorsCancellation: honorsCancellation
    )
    try deleteKeyedRecords(
      in: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<DocumentChunkRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\DocumentChunkRecord.id)]
          )
        }
        return FetchDescriptor<DocumentChunkRecord>(
          sortBy: [SortDescriptor(\DocumentChunkRecord.id)]
        )
      },
      key: \DocumentChunkRecord.id,
      honorsCancellation: honorsCancellation
    )
    try deleteKeyedRecords(
      in: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<ImportedDocumentRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\ImportedDocumentRecord.id)]
          )
        }
        return FetchDescriptor<ImportedDocumentRecord>(
          sortBy: [SortDescriptor(\ImportedDocumentRecord.id)]
        )
      },
      key: \ImportedDocumentRecord.id,
      honorsCancellation: honorsCancellation
    )
    try deleteKeyedRecords(
      in: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\ConversationRecord.id)]
          )
        }
        return FetchDescriptor<ConversationRecord>(
          sortBy: [SortDescriptor(\ConversationRecord.id)]
        )
      },
      key: \ConversationRecord.id,
      honorsCancellation: honorsCancellation
    )
    try deleteKeyedRecords(
      in: modelContext,
      makeDescriptor: { cursor in
        if let cursor {
          return FetchDescriptor<ProviderConfigurationRecord>(
            predicate: #Predicate { $0.id > cursor },
            sortBy: [SortDescriptor(\ProviderConfigurationRecord.id)]
          )
        }
        return FetchDescriptor<ProviderConfigurationRecord>(
          sortBy: [SortDescriptor(\ProviderConfigurationRecord.id)]
        )
      },
      key: \ProviderConfigurationRecord.id,
      honorsCancellation: honorsCancellation
    )
  }

  fileprivate static func checkCancellation(if enabled: Bool) throws {
    if enabled {
      try Task.checkCancellation()
    }
  }

  fileprivate static func idOrder<T: Identifiable>(_ lhs: T, _ rhs: T) -> Bool where T.ID == UUID {
    uuidOrder(lhs.id, rhs.id)
  }

  fileprivate static func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString < rhs.uuidString
  }

  fileprivate static func canonicalMessageOrder(
    _ lhs: MosaicPortableMessage,
    _ rhs: MosaicPortableMessage
  ) -> Bool {
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    let lhsRoleRank = lhs.roleRawValue == MessageRole.user.rawValue ? 0 : 1
    let rhsRoleRank = rhs.roleRawValue == MessageRole.user.rawValue ? 0 : 1
    if lhsRoleRank != rhsRoleRank { return lhsRoleRank < rhsRoleRank }
    return uuidOrder(lhs.id, rhs.id)
  }

  fileprivate static func canonicalInsertionIndex(
    for message: MosaicPortableMessage,
    in orderedMessages: [MosaicPortableMessage]
  ) -> Int {
    var lowerBound = 0
    var upperBound = orderedMessages.count
    while lowerBound < upperBound {
      let middle = lowerBound + (upperBound - lowerBound) / 2
      if canonicalMessageOrder(orderedMessages[middle], message) {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }
    return lowerBound
  }

  static func extensionRecordOrder(
    _ lhs: MosaicPortableExtensionRecord,
    _ rhs: MosaicPortableExtensionRecord
  ) -> Bool {
    if lhs.namespace != rhs.namespace { return lhs.namespace < rhs.namespace }
    if lhs.recordType != rhs.recordType { return lhs.recordType < rhs.recordType }
    return uuidOrder(lhs.id, rhs.id)
  }

  private static func isSupportedExtensionRecord(
    _ record: MosaicPortableExtensionRecord
  ) -> Bool {
    AutomaticMemoryPortableArchive.isOwned(record) || ProjectPortableArchive.isOwned(record)
      || ProviderModelsPortableArchive.isOwned(record) || ExperiencePortableArchive.isOwned(record)
  }
}

import CryptoKit
import Foundation
import SwiftData

/// One immutable event in the preparation of an answer request. The compact payload deliberately
/// excludes growing message-ID partitions and repeated compaction summaries.
@Model
public final class RequestContextEventRecord {
  @Attribute(.unique) public private(set) var id: UUID
  @Attribute(.unique) public private(set) var eventKey: String
  public private(set) var assistantMessageID: UUID
  public private(set) var conversationID: UUID
  public private(set) var sourceThroughMessageID: UUID
  public private(set) var sourceMessageCount: Int
  public private(set) var eventSequence: Int
  public private(set) var payloadData: Data
  public private(set) var payloadFingerprint: String
  public private(set) var legacyReceiptFingerprint: String?
  public private(set) var createdAt: Date

  init(
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

/// An immutable app-owned summary. Coverage is stored as only the suffix added after the coverage
/// parent; following the chain reconstructs the exact canonical prefix.
@Model
public final class CompactionArtifactRecord {
  @Attribute(.unique) public private(set) var id: UUID
  public private(set) var conversationID: UUID
  public private(set) var lineagePreviousCompactionID: UUID?
  public private(set) var coverageParentArtifactID: UUID?
  public private(set) var coverageDeltaData: Data
  public private(set) var coveredMessageCount: Int
  public private(set) var modeRawValue: String
  public private(set) var promptVersion: String
  public private(set) var contentSchemaVersion: Int
  public private(set) var contentData: Data?
  public private(set) var renderedSummary: String
  public private(set) var sourceFingerprint: String?
  public private(set) var providerConfigurationID: UUID?
  public private(set) var providerKindRawValue: String?
  public private(set) var providerDisplayName: String?
  public private(set) var providerEndpoint: String?
  public private(set) var modelIdentifier: String?
  public private(set) var providerMessageID: String?
  public private(set) var inputTokenCount: Int?
  public private(set) var outputTokenCount: Int?
  public private(set) var estimatedSourceTokens: Int
  public private(set) var estimatedSummaryTokens: Int
  public private(set) var chainDepth: Int
  public private(set) var warningsData: Data
  public private(set) var isSnapshotComplete: Bool
  public private(set) var isDetachedCoverageRoot: Bool
  public private(set) var payloadFingerprint: String
  public private(set) var createdAt: Date

  init(
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

/// The only mutable compaction object: a small compare-and-swap style pointer to an immutable
/// artifact. The artifacts and request events themselves never change.
@Model
public final class ConversationCompactionHeadRecord {
  @Attribute(.unique) public private(set) var conversationID: UUID
  public private(set) var activeArtifactID: UUID?
  public private(set) var revision: Int
  public private(set) var updatedAt: Date

  init(
    conversationID: UUID,
    activeArtifactID: UUID? = nil,
    revision: Int = 0,
    updatedAt: Date = .now
  ) {
    self.conversationID = conversationID
    self.activeArtifactID = activeArtifactID
    self.revision = revision
    self.updatedAt = updatedAt
  }

  fileprivate func advance(to artifactID: UUID, at date: Date) throws {
    guard revision < Int.max else {
      throw NormalizedContextStoreError.counterOverflow("compaction head revision")
    }
    activeArtifactID = artifactID
    revision += 1
    updatedAt = date
  }
}

/// Resumable, idempotent progress for converting legacy receipt blobs without deleting them.
@Model
public final class NormalizedContextBackfillProgressRecord {
  @Attribute(.unique) public private(set) var migrationKey: String
  public private(set) var lastEventKey: String?
  public private(set) var processedCount: Int
  public private(set) var migratedCount: Int
  public private(set) var retainedLegacyCount: Int
  public private(set) var failureCount: Int
  public private(set) var isComplete: Bool
  public private(set) var updatedAt: Date

  init(migrationKey: String, updatedAt: Date = .now) {
    self.migrationKey = migrationKey
    self.lastEventKey = nil
    self.processedCount = 0
    self.migratedCount = 0
    self.retainedLegacyCount = 0
    self.failureCount = 0
    self.isComplete = false
    self.updatedAt = updatedAt
  }

  /// Byte-exact backup restore entry point. Runtime backfill should use the smaller initializer and
  /// the mutation methods below instead of manufacturing progress.
  init(
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

  fileprivate func recordSuccess(eventKey: String, at date: Date) throws {
    guard processedCount < Int.max, migratedCount < Int.max else {
      throw NormalizedContextStoreError.counterOverflow("backfill success count")
    }
    lastEventKey = eventKey
    processedCount += 1
    migratedCount += 1
    updatedAt = date
  }

  fileprivate func recordFailure(eventKey: String, at date: Date) throws {
    guard processedCount < Int.max, retainedLegacyCount < Int.max, failureCount < Int.max else {
      throw NormalizedContextStoreError.counterOverflow("backfill failure count")
    }
    lastEventKey = eventKey
    processedCount += 1
    retainedLegacyCount += 1
    failureCount += 1
    updatedAt = date
  }

  fileprivate func markComplete(at date: Date) {
    isComplete = true
    updatedAt = date
  }
}

public enum NormalizedContextStoreError: Error, Equatable, LocalizedError, Sendable {
  case invalidEventSequence(Int)
  case emptyCanonicalSource
  case sourceCountMismatch(expected: Int, actual: Int)
  case sourceBoundaryMismatch
  case duplicateCanonicalMessageID(UUID)
  case nonContiguousSelection(String)
  case receiptPartitionMismatch(String)
  case missingCompactionArtifact(UUID)
  case incompleteCompactionArtifact(UUID)
  case compactionArtifactConflict(UUID)
  case compactionArtifactCycle(UUID)
  case compactionCountMismatch(UUID)
  case compactionPrefixMismatch(UUID)
  case compactionConversationMismatch(UUID)
  case corruptPayload(String)
  case unsupportedPayloadVersion(Int)
  case idempotencyConflict(String)
  case payloadTooLarge(Int)
  case headConflict(expected: UUID?, actual: UUID?)
  case dualReadConflict(normalized: UUID, legacy: UUID)
  case legacySnapshotNotNewer(current: UUID, candidate: UUID)
  case counterOverflow(String)

  public var errorDescription: String? {
    switch self {
    case .invalidEventSequence(let sequence):
      "Context event sequence \(sequence) is invalid."
    case .emptyCanonicalSource:
      "A request context cannot be normalized without a canonical source message."
    case .sourceCountMismatch(let expected, let actual):
      "The canonical source contains \(actual) messages instead of the expected \(expected)."
    case .sourceBoundaryMismatch:
      "The request source boundary does not match the canonical message order."
    case .duplicateCanonicalMessageID(let id):
      "The canonical source repeats message \(id.uuidString)."
    case .nonContiguousSelection(let label):
      "The \(label) selection is not one canonical contiguous range."
    case .receiptPartitionMismatch(let reason):
      "The legacy receipt cannot be normalized safely: \(reason)"
    case .missingCompactionArtifact(let id):
      "Compaction artifact \(id.uuidString) is missing."
    case .incompleteCompactionArtifact(let id):
      "Compaction artifact \(id.uuidString) cannot reconstruct a full snapshot."
    case .compactionArtifactConflict(let id):
      "Compaction artifact \(id.uuidString) conflicts with an immutable stored artifact."
    case .compactionArtifactCycle(let id):
      "The compaction artifact chain cycles at \(id.uuidString)."
    case .compactionCountMismatch(let id):
      "The compaction coverage count is invalid at \(id.uuidString)."
    case .compactionPrefixMismatch(let id):
      "The compaction coverage is not the canonical conversation prefix at \(id.uuidString)."
    case .compactionConversationMismatch(let id):
      "Compaction artifact \(id.uuidString) belongs to another conversation."
    case .corruptPayload(let description):
      "Normalized context data failed integrity validation: \(description)"
    case .unsupportedPayloadVersion(let version):
      "Normalized context payload version \(version) is unsupported."
    case .idempotencyConflict(let key):
      "Context event \(key) already exists with different immutable data."
    case .payloadTooLarge(let byteCount):
      "The compact request payload unexpectedly grew to \(byteCount) bytes."
    case .headConflict(let expected, let actual):
      "The compaction head changed (expected \(String(describing: expected)), found \(String(describing: actual)))."
    case .dualReadConflict(let normalized, let legacy):
      "Normalized compaction \(normalized.uuidString) conflicts with equally current legacy compaction \(legacy.uuidString)."
    case .legacySnapshotNotNewer(let current, let candidate):
      "Legacy compaction \(candidate.uuidString) is not ahead of normalized compaction \(current.uuidString)."
    case .counterOverflow(let label):
      "Normalized context data exceeded the supported \(label)."
    }
  }
}

public struct LegacyRequestContextBackfillItem: Hashable, Sendable {
  public let assistantMessageID: UUID
  public let conversationID: UUID
  public let sourceThroughMessageID: UUID
  public let eventSequence: Int
  public let canonicalMessages: [AIChatMessage]
  public let legacyReceiptData: Data
  public let legacyCompactionSnapshotData: Data?
  public let createdAt: Date

  public init(
    assistantMessageID: UUID,
    conversationID: UUID,
    sourceThroughMessageID: UUID,
    eventSequence: Int = 0,
    canonicalMessages: [AIChatMessage],
    legacyReceiptData: Data,
    legacyCompactionSnapshotData: Data? = nil,
    createdAt: Date = .now
  ) {
    self.assistantMessageID = assistantMessageID
    self.conversationID = conversationID
    self.sourceThroughMessageID = sourceThroughMessageID
    self.eventSequence = eventSequence
    self.canonicalMessages = canonicalMessages
    self.legacyReceiptData = legacyReceiptData
    self.legacyCompactionSnapshotData = legacyCompactionSnapshotData
    self.createdAt = createdAt
  }
}

public struct NormalizedContextBackfillResult: Hashable, Sendable {
  public let processedCount: Int
  public let insertedEventCount: Int
  public let retainedLegacyCount: Int
  public let isComplete: Bool
  public let failedEventKeys: [String]

  public init(
    processedCount: Int,
    insertedEventCount: Int,
    retainedLegacyCount: Int,
    isComplete: Bool,
    failedEventKeys: [String]
  ) {
    self.processedCount = processedCount
    self.insertedEventCount = insertedEventCount
    self.retainedLegacyCount = retainedLegacyCount
    self.isComplete = isComplete
    self.failedEventKeys = failedEventKeys
  }
}

public enum NormalizedContextInsertDisposition: Hashable, Sendable {
  case inserted
  case alreadyPresent
}

public struct NormalizedCompactionActivation: Hashable, Sendable {
  public let snapshot: ConversationCompactionSnapshot
  public let expectedCurrentArtifactID: UUID?
  public let allowVerifiedDetachedTakeover: Bool

  public init(
    snapshot: ConversationCompactionSnapshot,
    expectedCurrentArtifactID: UUID?,
    allowVerifiedDetachedTakeover: Bool
  ) {
    self.snapshot = snapshot
    self.expectedCurrentArtifactID = expectedCurrentArtifactID
    self.allowVerifiedDetachedTakeover = allowVerifiedDetachedTakeover
  }
}

struct NormalizedRestoreRequestEvent: Sendable {
  let id: UUID
  let eventKey: String
  let assistantMessageID: UUID
  let conversationID: UUID
  let sourceThroughMessageID: UUID
  let sourceMessageCount: Int
  let eventSequence: Int
  let payloadData: Data
  let payloadFingerprint: String

  init(_ record: RequestContextEventRecord) {
    id = record.id
    eventKey = record.eventKey
    assistantMessageID = record.assistantMessageID
    conversationID = record.conversationID
    sourceThroughMessageID = record.sourceThroughMessageID
    sourceMessageCount = record.sourceMessageCount
    eventSequence = record.eventSequence
    payloadData = record.payloadData
    payloadFingerprint = record.payloadFingerprint
  }

  init(
    id: UUID,
    eventKey: String,
    assistantMessageID: UUID,
    conversationID: UUID,
    sourceThroughMessageID: UUID,
    sourceMessageCount: Int,
    eventSequence: Int,
    payloadData: Data,
    payloadFingerprint: String
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
  }
}

struct NormalizedRestoreCompactionArtifact: Sendable {
  let conversationID: UUID
  let coveredMessageCount: Int
  let providerConfigurationID: UUID?
  let providerKindRawValue: String?
  let providerDisplayName: String?
  let providerEndpoint: String?
  let modelIdentifier: String?

  init(_ record: CompactionArtifactRecord) {
    conversationID = record.conversationID
    coveredMessageCount = record.coveredMessageCount
    providerConfigurationID = record.providerConfigurationID
    providerKindRawValue = record.providerKindRawValue
    providerDisplayName = record.providerDisplayName
    providerEndpoint = record.providerEndpoint
    modelIdentifier = record.modelIdentifier
  }

  init(
    conversationID: UUID,
    coveredMessageCount: Int,
    providerConfigurationID: UUID?,
    providerKindRawValue: String?,
    providerDisplayName: String?,
    providerEndpoint: String?,
    modelIdentifier: String?
  ) {
    self.conversationID = conversationID
    self.coveredMessageCount = coveredMessageCount
    self.providerConfigurationID = providerConfigurationID
    self.providerKindRawValue = providerKindRawValue
    self.providerDisplayName = providerDisplayName
    self.providerEndpoint = providerEndpoint
    self.modelIdentifier = modelIdentifier
  }
}

struct NormalizedLegacyCompactionReference: Sendable {
  let id: UUID
  let renderedSummary: String
  let coveredMessageCount: Int
  let providerConfigurationID: UUID
  let providerKindRawValue: String
  let providerDisplayName: String
  let providerEndpoint: String
  let modelIdentifier: String
  let createdAt: Date
}

/// Main-actor facade around the additive normalized models. Network code can prepare immutable
/// value snapshots off actor, but all source-of-truth SwiftData mutations remain serialized here.
@MainActor
public final class NormalizedContextStore {
  private static let maximumCompactionCoverageDepth = 1_024
  private static let maximumReconciliationEvents = 64
  private static let maximumReconciliationPayloadBytes = 2 * 1_024 * 1_024

  public nonisolated static let requestPayloadVersion = 1
  public nonisolated static let maximumCompactPayloadBytes = 512_000

  private let modelContext: ModelContext

  public init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  @discardableResult
  public func persistCompactionArtifact(
    snapshot: ConversationCompactionSnapshot,
    canonicalMessages: [AIChatMessage],
    allowDetachedLegacyRoot: Bool = false
  ) throws -> NormalizedContextInsertDisposition {
    do {
      let result = try insertCompactionArtifact(
        snapshot: snapshot,
        canonicalMessages: canonicalMessages,
        allowDetachedLegacyRoot: allowDetachedLegacyRoot
      )
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
      return result
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  @discardableResult
  public func appendRequestEvent(
    assistantMessageID: UUID,
    conversationID: UUID,
    sourceThroughMessageID: UUID,
    eventSequence: Int,
    receipt: RequestContextReceipt,
    canonicalMessages: [AIChatMessage],
    activeCompactionSnapshot: ConversationCompactionSnapshot? = nil,
    legacyReceiptFingerprint: String? = nil,
    createdAt: Date = .now
  ) throws -> NormalizedContextInsertDisposition {
    try appendRequestEventAtomically(
      assistantMessageID: assistantMessageID,
      conversationID: conversationID,
      sourceThroughMessageID: sourceThroughMessageID,
      eventSequence: eventSequence,
      receipt: receipt,
      canonicalMessages: canonicalMessages,
      activeCompactionSnapshot: activeCompactionSnapshot,
      compactionActivations: [],
      legacyReceiptFingerprint: legacyReceiptFingerprint,
      createdAt: createdAt
    )
  }

  /// Commits the immutable request event and every head activation that made that exact event
  /// possible in one SwiftData transaction. A payload/CAS/save failure rolls the artifacts and
  /// heads back together, so the audit can never claim a different active summary than the head.
  @discardableResult
  public func appendRequestEventAtomically(
    assistantMessageID: UUID,
    conversationID: UUID,
    sourceThroughMessageID: UUID,
    eventSequence: Int,
    receipt: RequestContextReceipt,
    canonicalMessages: [AIChatMessage],
    activeCompactionSnapshot: ConversationCompactionSnapshot? = nil,
    compactionActivations: [NormalizedCompactionActivation],
    legacyReceiptFingerprint: String? = nil,
    createdAt: Date = .now
  ) throws -> NormalizedContextInsertDisposition {
    do {
      if try preflightExistingRequestEvent(
        assistantMessageID: assistantMessageID,
        conversationID: conversationID,
        sourceThroughMessageID: sourceThroughMessageID,
        eventSequence: eventSequence,
        receipt: receipt,
        canonicalMessages: canonicalMessages,
        activeCompactionSnapshot: activeCompactionSnapshot,
        compactionActivations: compactionActivations,
        legacyReceiptFingerprint: legacyReceiptFingerprint
      ) {
        return .alreadyPresent
      }
      for activation in compactionActivations {
        _ = try stageCompactionSnapshotActivation(
          activation.snapshot,
          conversationID: conversationID,
          expectedCurrentArtifactID: activation.expectedCurrentArtifactID,
          canonicalMessages: canonicalMessages,
          allowVerifiedDetachedTakeover: activation.allowVerifiedDetachedTakeover,
          at: createdAt
        )
      }
      let result = try insertRequestEvent(
        assistantMessageID: assistantMessageID,
        conversationID: conversationID,
        sourceThroughMessageID: sourceThroughMessageID,
        eventSequence: eventSequence,
        receipt: receipt,
        canonicalMessages: canonicalMessages,
        activeCompactionSnapshot: activeCompactionSnapshot,
        legacyReceiptFingerprint: legacyReceiptFingerprint,
        createdAt: createdAt
      )
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
      return result
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  /// Exact event replay remains idempotent even after a later request advances the mutable head.
  /// The immutable row and all referenced artifacts are re-projected, but historical CAS intents
  /// are deliberately not replayed against the newer head.
  private func preflightExistingRequestEvent(
    assistantMessageID: UUID,
    conversationID: UUID,
    sourceThroughMessageID: UUID,
    eventSequence: Int,
    receipt: RequestContextReceipt,
    canonicalMessages: [AIChatMessage],
    activeCompactionSnapshot: ConversationCompactionSnapshot?,
    compactionActivations: [NormalizedCompactionActivation],
    legacyReceiptFingerprint: String?
  ) throws -> Bool {
    let eventKey = Self.eventKey(
      assistantMessageID: assistantMessageID,
      eventSequence: eventSequence
    )
    guard let existing = try event(key: eventKey) else { return false }
    let source = try canonicalSource(
      canonicalMessages,
      through: sourceThroughMessageID,
      count: receipt.conversationContext?.originalMessageCount ?? canonicalMessages.count
    )
    guard
      existing.id
        == Self.eventID(
          assistantMessageID: assistantMessageID,
          eventSequence: eventSequence
        ),
      existing.assistantMessageID == assistantMessageID,
      existing.conversationID == conversationID,
      existing.sourceThroughMessageID == sourceThroughMessageID,
      existing.sourceMessageCount == source.count,
      existing.eventSequence == eventSequence,
      existing.legacyReceiptFingerprint == legacyReceiptFingerprint,
      try projectReceipt(event: existing, canonicalMessages: canonicalMessages) == receipt
    else {
      throw NormalizedContextStoreError.idempotencyConflict(eventKey)
    }

    let snapshotsToVerify =
      compactionActivations.map(\.snapshot) + (activeCompactionSnapshot.map { [$0] } ?? [])
    for snapshot in snapshotsToVerify {
      guard
        try projectCompactionSnapshot(
          artifactID: snapshot.id,
          canonicalMessages: canonicalMessages
        ) == snapshot
      else {
        throw NormalizedContextStoreError.compactionArtifactConflict(snapshot.id)
      }
    }
    return true
  }

  /// Advances the small mutable head only when the caller's expected predecessor still matches.
  public func advanceCompactionHead(
    conversationID: UUID,
    to artifactID: UUID,
    expectedCurrentArtifactID: UUID?,
    canonicalMessages: [AIChatMessage],
    at date: Date = .now
  ) throws {
    do {
      let artifact = try requiredArtifact(id: artifactID)
      guard artifact.conversationID == conversationID else {
        throw NormalizedContextStoreError.compactionConversationMismatch(artifactID)
      }
      _ = try projectSnapshot(artifact: artifact, canonicalMessages: canonicalMessages)

      let head = try compactionHead(conversationID: conversationID)
      let actual = head?.activeArtifactID
      if actual == artifactID { return }
      guard actual == expectedCurrentArtifactID else {
        throw NormalizedContextStoreError.headConflict(
          expected: expectedCurrentArtifactID,
          actual: actual
        )
      }
      let activatesDetachedLegacyRoot =
        artifact.isDetachedCoverageRoot && actual == nil && expectedCurrentArtifactID == nil
      guard activatesDetachedLegacyRoot || artifact.lineagePreviousCompactionID == actual else {
        throw NormalizedContextStoreError.headConflict(
          expected: artifact.lineagePreviousCompactionID,
          actual: actual
        )
      }

      if let head {
        try head.advance(to: artifactID, at: date)
      } else {
        modelContext.insert(
          ConversationCompactionHeadRecord(
            conversationID: conversationID,
            activeArtifactID: artifactID,
            revision: 1,
            updatedAt: date
          )
        )
      }
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func activeCompactionArtifactID(conversationID: UUID) throws -> UUID? {
    try compactionHead(conversationID: conversationID)?.activeArtifactID
  }

  /// Atomically stores and activates a validated snapshot. Ordinary generation must extend the
  /// exact current lineage. A verified detached takeover is an explicit recovery-only escape hatch
  /// and additionally requires non-regressing canonical coverage and recency.
  @discardableResult
  public func activateCompactionSnapshot(
    _ snapshot: ConversationCompactionSnapshot,
    conversationID: UUID,
    expectedCurrentArtifactID: UUID?,
    canonicalMessages: [AIChatMessage],
    allowVerifiedDetachedTakeover: Bool = false,
    at date: Date = .now
  ) throws -> NormalizedContextInsertDisposition {
    do {
      let disposition = try stageCompactionSnapshotActivation(
        snapshot,
        conversationID: conversationID,
        expectedCurrentArtifactID: expectedCurrentArtifactID,
        canonicalMessages: canonicalMessages,
        allowVerifiedDetachedTakeover: allowVerifiedDetachedTakeover,
        at: date
      )
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
      return disposition
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  private func stageCompactionSnapshotActivation(
    _ snapshot: ConversationCompactionSnapshot,
    conversationID: UUID,
    expectedCurrentArtifactID: UUID?,
    canonicalMessages: [AIChatMessage],
    allowVerifiedDetachedTakeover: Bool,
    at date: Date
  ) throws -> NormalizedContextInsertDisposition {
    guard snapshot.conversationID == conversationID,
      ConversationCompactionPlanner(contextPolicy: .conservativeDefault).isValid(
        snapshot: snapshot,
        conversationID: conversationID,
        messages: canonicalMessages
      )
    else {
      throw NormalizedContextStoreError.compactionPrefixMismatch(snapshot.id)
    }

    let head = try compactionHead(conversationID: conversationID)
    let actual = head?.activeArtifactID
    if actual == snapshot.id {
      let current = try projectCompactionSnapshot(
        artifactID: snapshot.id,
        canonicalMessages: canonicalMessages
      )
      guard current == snapshot else {
        throw NormalizedContextStoreError.compactionArtifactConflict(snapshot.id)
      }
      return .alreadyPresent
    }
    guard actual == expectedCurrentArtifactID else {
      throw NormalizedContextStoreError.headConflict(
        expected: expectedCurrentArtifactID,
        actual: actual
      )
    }

    let followsCurrentLineage = snapshot.previousCompactionID == actual
    if let actual {
      let current = try projectCompactionSnapshot(
        artifactID: actual,
        canonicalMessages: canonicalMessages
      )
      guard snapshot.coveredMessageIDs.starts(with: current.coveredMessageIDs) else {
        throw NormalizedContextStoreError.legacySnapshotNotNewer(
          current: current.id,
          candidate: snapshot.id
        )
      }
      if !followsCurrentLineage {
        let hasGreaterCoverage =
          snapshot.coveredMessageIDs.count > current.coveredMessageIDs.count
        let isNewerAtEqualCoverage =
          snapshot.coveredMessageIDs.count == current.coveredMessageIDs.count
          && snapshot.createdAt > current.createdAt
        guard allowVerifiedDetachedTakeover,
          hasGreaterCoverage || isNewerAtEqualCoverage
        else {
          throw NormalizedContextStoreError.legacySnapshotNotNewer(
            current: current.id,
            candidate: snapshot.id
          )
        }
      }
    } else if !followsCurrentLineage && !allowVerifiedDetachedTakeover {
      throw NormalizedContextStoreError.headConflict(
        expected: snapshot.previousCompactionID,
        actual: nil
      )
    }

    let disposition = try insertCompactionArtifact(
      snapshot: snapshot,
      canonicalMessages: canonicalMessages,
      allowDetachedLegacyRoot: allowVerifiedDetachedTakeover
    )
    if let head {
      try head.advance(to: snapshot.id, at: date)
    } else {
      modelContext.insert(
        ConversationCompactionHeadRecord(
          conversationID: conversationID,
          activeArtifactID: snapshot.id,
          revision: 1,
          updatedAt: date
        )
      )
    }
    return disposition
  }

  /// Explicit rollback-window adoption. Unlike ordinary lineage advancement, this may adopt a
  /// detached legacy artifact over an existing head, but only after canonical validation, an exact
  /// compare-and-swap check, and proof that the candidate has greater coverage or a newer timestamp
  /// at equal coverage.
  @discardableResult
  public func adoptLegacyCompactionSnapshot(
    _ snapshot: ConversationCompactionSnapshot,
    conversationID: UUID,
    expectedCurrentArtifactID: UUID?,
    canonicalMessages: [AIChatMessage],
    at date: Date = .now
  ) throws -> NormalizedContextInsertDisposition {
    try activateCompactionSnapshot(
      snapshot,
      conversationID: conversationID,
      expectedCurrentArtifactID: expectedCurrentArtifactID,
      canonicalMessages: canonicalMessages,
      allowVerifiedDetachedTakeover: true,
      at: date
    )
  }

  /// Reads normalized data when present. Legacy bytes are decoded only when no normalized event
  /// exists; corrupt normalized data never silently falls back and masks source-of-truth damage.
  public func requestReceipt(
    assistantMessageID: UUID,
    conversationID: UUID? = nil,
    canonicalMessages: [AIChatMessage],
    legacyReceiptData: Data? = nil,
    legacyCompactionSnapshotData: Data? = nil
  ) throws -> RequestContextReceipt? {
    if let event = try latestEvent(assistantMessageID: assistantMessageID) {
      return try projectReceipt(event: event, canonicalMessages: canonicalMessages)
    }
    guard let legacyReceiptData else { return nil }
    let receipt = try JSONDecoder().decode(RequestContextReceipt.self, from: legacyReceiptData)
    guard
      let assistantIndex = canonicalMessages.firstIndex(where: {
        $0.id == assistantMessageID && $0.role == .assistant
      })
    else {
      throw NormalizedContextStoreError.sourceBoundaryMismatch
    }
    let source = Array(canonicalMessages.prefix(upTo: assistantIndex))
    let legacySnapshot = try legacyCompactionSnapshotData.map {
      try JSONDecoder().decode(ConversationCompactionSnapshot.self, from: $0)
    }
    if let legacySnapshot {
      try Self.validateLegacyCompactionSnapshot(
        legacySnapshot,
        conversationID: conversationID ?? legacySnapshot.conversationID,
        canonicalMessages: canonicalMessages
      )
    }
    try validateLegacyRequestReceipt(
      receipt,
      conversationID: conversationID,
      canonicalMessages: source,
      legacyCompactionSnapshot: legacySnapshot
    )
    return receipt
  }

  /// Restore-time integrity hook for validating every immutable event, not only the latest event
  /// that the conversation UI would normally project.
  public func validateRequestEvent(
    assistantMessageID: UUID,
    eventSequence: Int,
    canonicalMessages: [AIChatMessage]
  ) throws {
    let key = Self.eventKey(
      assistantMessageID: assistantMessageID,
      eventSequence: eventSequence
    )
    guard let event = try event(key: key) else {
      throw NormalizedContextStoreError.idempotencyConflict(key)
    }
    _ = try projectReceipt(event: event, canonicalMessages: canonicalMessages)
  }

  /// Returns whether the bounded recent audit window contains a newest-per-answer generating
  /// compaction attempt. This is a cheap presentation-time preflight: canonical chat history is
  /// fetched only when reconciliation can actually append a terminal event.
  func hasInterruptedGeneratingEvents(conversationID: UUID) throws -> Bool {
    let events = try recentReconciliationEvents(conversationID: conversationID)
    var seenAssistants: Set<UUID> = []
    var inspectedPayloadBytes = 0
    for event in events {
      let (nextPayloadBytes, payloadOverflow) = inspectedPayloadBytes.addingReportingOverflow(
        event.payloadData.count
      )
      guard !payloadOverflow, nextPayloadBytes <= Self.maximumReconciliationPayloadBytes else {
        break
      }
      inspectedPayloadBytes = nextPayloadBytes
      guard seenAssistants.insert(event.assistantMessageID).inserted else { continue }
      guard
        event.eventKey
          == Self.eventKey(
            assistantMessageID: event.assistantMessageID,
            eventSequence: event.eventSequence
          ),
        NormalizedContextCodec.fingerprint(event.payloadData) == event.payloadFingerprint
      else {
        throw NormalizedContextStoreError.corruptPayload("invalid reconciliation event")
      }
      let payload: NormalizedRequestPayload
      do {
        payload = try NormalizedContextCodec.decode(
          NormalizedRequestPayload.self,
          from: event.payloadData
        )
      } catch {
        throw NormalizedContextStoreError.corruptPayload(
          "reconciliation payload is not decodable"
        )
      }
      guard payload.schemaVersion == Self.requestPayloadVersion else {
        throw NormalizedContextStoreError.unsupportedPayloadVersion(payload.schemaVersion)
      }
      if payload.conversationCompaction?.status == .generating { return true }
    }
    return false
  }

  /// Converts recent pre-stream `.generating` audits into bounded failed terminal events after a
  /// process interruption. Work is capped by both row count and compact-payload bytes so this
  /// main-actor recovery pass cannot walk an unbounded append-only history; an older forensic
  /// sweep can be resumed separately. A live operation must be excluded by the caller. The method
  /// is idempotent and never mutates the original event.
  @discardableResult
  public func reconcileInterruptedGeneratingEvents(
    conversationID: UUID,
    canonicalMessages: [AIChatMessage],
    at date: Date = .now
  ) throws -> Int {
    let events = try recentReconciliationEvents(conversationID: conversationID)
    var seenAssistants: Set<UUID> = []
    var insertedCount = 0
    var inspectedPayloadBytes = 0
    do {
      for event in events {
        let (nextPayloadBytes, payloadOverflow) = inspectedPayloadBytes.addingReportingOverflow(
          event.payloadData.count
        )
        guard !payloadOverflow, nextPayloadBytes <= Self.maximumReconciliationPayloadBytes else {
          break
        }
        inspectedPayloadBytes = nextPayloadBytes
        guard seenAssistants.insert(event.assistantMessageID).inserted else { continue }
        let receipt = try projectReceipt(event: event, canonicalMessages: canonicalMessages)
        guard let generating = receipt.conversationCompaction,
          generating.status == .generating
        else { continue }
        let (nextSequence, overflow) = event.eventSequence.addingReportingOverflow(1)
        guard !overflow else {
          throw NormalizedContextStoreError.counterOverflow("request event sequence")
        }
        let source = try canonicalSource(
          canonicalMessages,
          through: event.sourceThroughMessageID,
          count: event.sourceMessageCount
        )
        let terminal = ConversationCompactionReceipt(
          attemptID: generating.attemptID,
          status: .failed,
          attemptedMessageIDs: generating.attemptedMessageIDs,
          providerConfigurationID: generating.providerConfigurationID,
          providerKind: generating.providerKind,
          providerDisplayName: String(generating.providerDisplayName.prefix(512)),
          providerEndpoint: String(generating.providerEndpoint.prefix(2_048)),
          modelIdentifier: String(generating.modelIdentifier.prefix(512)),
          providerMessageID: generating.providerMessageID.map { String($0.prefix(512)) },
          inputTokenCount: generating.inputTokenCount,
          outputTokenCount: generating.outputTokenCount,
          estimatedInputTokensBefore: generating.estimatedInputTokensBefore,
          estimatedInputTokensAfter: nil,
          extraRequestCount: 1,
          errorDescription:
            "Turing AI recovered an interrupted history-compression audit after the app stopped.",
          warnings: ["No partial or unvalidated summary was activated."],
          createdAt: date
        )
        let terminalReceipt = RequestContextReceipt(
          curatedContext: .empty,
          retrievedContext: .empty,
          conversationCompaction: terminal,
          createdAt: date
        )
        let disposition = try insertRequestEvent(
          assistantMessageID: event.assistantMessageID,
          conversationID: conversationID,
          sourceThroughMessageID: event.sourceThroughMessageID,
          eventSequence: nextSequence,
          receipt: terminalReceipt,
          canonicalMessages: source,
          activeCompactionSnapshot: nil,
          legacyReceiptFingerprint: nil,
          createdAt: date
        )
        if disposition == .inserted { insertedCount += 1 }
      }
      if insertedCount > 0 {
        try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
      }
      return insertedCount
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  private func recentReconciliationEvents(
    conversationID: UUID
  ) throws -> [RequestContextEventRecord] {
    var descriptor = FetchDescriptor<RequestContextEventRecord>(
      predicate: #Predicate { $0.conversationID == conversationID },
      sortBy: [
        SortDescriptor(\RequestContextEventRecord.createdAt, order: .reverse),
        SortDescriptor(\RequestContextEventRecord.eventSequence, order: .reverse),
        SortDescriptor(\RequestContextEventRecord.id, order: .reverse),
      ]
    )
    descriptor.fetchLimit = Self.maximumReconciliationEvents
    descriptor.includePendingChanges = false
    return try modelContext.fetch(descriptor)
  }

  /// Restore-only structural validation that never materializes the historical prefix or walks a
  /// compaction coverage chain per event. Portable-backup validation has already verified every
  /// artifact against the canonical transcript; this pass verifies the compact event payload and
  /// its partitions in work proportional to the payload itself.
  public func validateRequestEventForRestore(
    assistantMessageID: UUID,
    eventSequence: Int,
    canonicalMessageIndices: [UUID: Int]
  ) throws {
    let key = Self.eventKey(
      assistantMessageID: assistantMessageID,
      eventSequence: eventSequence
    )
    guard let record = try event(key: key) else {
      throw NormalizedContextStoreError.corruptPayload("invalid restore request event")
    }
    try Self.validateRequestEventForRestore(
      event: NormalizedRestoreRequestEvent(record),
      canonicalMessageIndices: canonicalMessageIndices
    ) { artifactID in
      NormalizedRestoreCompactionArtifact(try self.requiredArtifact(id: artifactID))
    }
  }

  nonisolated static func validateRequestEventForRestore(
    event: NormalizedRestoreRequestEvent,
    canonicalMessageIndices: [UUID: Int],
    artifactResolver: (UUID) throws -> NormalizedRestoreCompactionArtifact
  ) throws {
    let key = Self.eventKey(
      assistantMessageID: event.assistantMessageID,
      eventSequence: event.eventSequence
    )
    guard
      event.id
        == Self.eventID(
          assistantMessageID: event.assistantMessageID,
          eventSequence: event.eventSequence
        ),
      event.eventKey == key,
      event.sourceMessageCount > 0,
      event.sourceMessageCount <= canonicalMessageIndices.count,
      canonicalMessageIndices[event.sourceThroughMessageID] == event.sourceMessageCount - 1,
      canonicalMessageIndices[event.assistantMessageID].map({
        $0 == event.sourceMessageCount
      }) ?? true,
      NormalizedContextCodec.fingerprint(event.payloadData) == event.payloadFingerprint
    else {
      throw NormalizedContextStoreError.corruptPayload("invalid restore request event")
    }

    let payload: NormalizedRequestPayload
    do {
      payload = try NormalizedContextCodec.decode(
        NormalizedRequestPayload.self,
        from: event.payloadData
      )
    } catch {
      throw NormalizedContextStoreError.corruptPayload("request payload is not decodable")
    }
    guard payload.schemaVersion == Self.requestPayloadVersion,
      payload.curatedContext.includedMemories.count <= 4_096,
      payload.retrievedContext.items.count <= 4_096,
      payload.retrievedContext.items.allSatisfy({ $0.relevance.isFinite })
    else {
      throw NormalizedContextStoreError.corruptPayload("invalid restore request payload")
    }

    let sourceCount = event.sourceMessageCount
    var summarizedCount = 0
    var recalledIndices: Set<Int> = []
    var recalledMessageIDs: [UUID] = []
    if let compact = payload.conversationContext {
      try Self.validateConversationTokenBudget(
        estimatedInputTokens: compact.estimatedInputTokens,
        contextWindowTokens: compact.contextWindowTokens,
        maximumOutputTokens: compact.maximumOutputTokens,
        safetyMarginTokens: compact.safetyMarginTokens
      )
      guard compact.rawIncludedMessageCount >= 0,
        compact.rawIncludedMessageCount <= sourceCount
      else {
        throw NormalizedContextStoreError.corruptPayload("invalid raw suffix count")
      }

      // Presence preserves the receipt's nil-versus-empty distinction. An explicit empty
      // list is valid before the first compaction and is already written by ordinary chats.
      if let artifactID = compact.activeCompactionID {
        guard compact.summarizedFieldPresent else {
          throw NormalizedContextStoreError.corruptPayload("unrepresented active artifact")
        }
        let artifact = try artifactResolver(artifactID)
        guard artifact.conversationID == event.conversationID,
          artifact.coveredMessageCount > 0,
          artifact.coveredMessageCount <= sourceCount
        else {
          throw NormalizedContextStoreError.corruptPayload("invalid summarized artifact")
        }
        summarizedCount = artifact.coveredMessageCount
      }

      let rawStart = sourceCount - compact.rawIncludedMessageCount
      guard summarizedCount <= rawStart else {
        throw NormalizedContextStoreError.receiptPartitionMismatch(
          "summary overlaps the raw suffix"
        )
      }
      for messageID in compact.recalledMessageIDs ?? [] {
        guard let index = canonicalMessageIndices[messageID],
          index < sourceCount,
          index < rawStart,
          recalledIndices.insert(index).inserted
        else {
          throw NormalizedContextStoreError.receiptPartitionMismatch(
            "recalled message is duplicated or overlaps the raw partition"
          )
        }
        recalledMessageIDs.append(messageID)
      }

      switch compact.strategy {
      case .full:
        guard compact.rawIncludedMessageCount == sourceCount,
          summarizedCount == 0,
          recalledIndices.isEmpty
        else {
          throw NormalizedContextStoreError.receiptPartitionMismatch(
            "full strategy does not contain the full source"
          )
        }
      case .recentOnly:
        guard summarizedCount == 0 else {
          throw NormalizedContextStoreError.receiptPartitionMismatch(
            "recent-only strategy contains a summary"
          )
        }
      case .summaryAndRecent:
        guard summarizedCount > 0 else {
          throw NormalizedContextStoreError.receiptPartitionMismatch(
            "summary strategy has no summarized prefix"
          )
        }
      }
    } else if payload.sameConversationRecall != nil {
      throw NormalizedContextStoreError.corruptPayload("same-chat recall has no context receipt")
    }

    if let recall = payload.sameConversationRecall {
      guard recall.conversationID == event.conversationID,
        recall.items.count <= 4_096,
        recall.eligibleCandidateCount >= recall.items.count,
        (0...1_000_000_000).contains(recall.eligibleCandidateCount),
        (0...1_000_000_000).contains(recall.injectedInputTokens),
        recall.items.allSatisfy({ $0.relevance.isFinite }),
        recall.recalledMessageIDs == recalledMessageIDs,
        recall.items.allSatisfy({ item in
          guard let index = canonicalMessageIndices[item.id] else { return false }
          let expectedOrigin: SameConversationRecallOrigin =
            index < summarizedCount ? .summarized : .omitted
          return item.origin == expectedOrigin
        })
      else {
        throw NormalizedContextStoreError.corruptPayload("invalid same-chat recall audit")
      }
    } else if !recalledIndices.isEmpty {
      throw NormalizedContextStoreError.corruptPayload("recalled IDs have no recall audit")
    }

    if let compact = payload.conversationCompaction {
      try Self.validateCompactionAudit(
        status: compact.status,
        activeCompactionID: compact.activeCompactionID,
        summaryTextPresent: compact.summaryTextPresent,
        attemptedSelectionPresent: compact.attemptedSelection != nil,
        activeProvenancePresent: compact.activeProvenancePresent,
        inputTokenCount: compact.inputTokenCount,
        outputTokenCount: compact.outputTokenCount,
        estimatedInputTokensBefore: compact.estimatedInputTokensBefore,
        estimatedInputTokensAfter: compact.estimatedInputTokensAfter,
        extraRequestCount: compact.extraRequestCount
      )
      if let artifactID = compact.activeCompactionID {
        let artifact = try artifactResolver(artifactID)
        guard artifact.conversationID == event.conversationID,
          artifact.coveredMessageCount <= sourceCount
        else {
          throw NormalizedContextStoreError.corruptPayload("invalid active summary reference")
        }
        if compact.activeProvenancePresent {
          guard artifact.providerConfigurationID != nil,
            artifact.providerKindRawValue.flatMap(ProviderKind.init(rawValue:)) != nil,
            artifact.providerDisplayName != nil,
            artifact.providerEndpoint != nil,
            artifact.modelIdentifier != nil
          else {
            throw NormalizedContextStoreError.corruptPayload(
              "active summary provenance is incomplete"
            )
          }
        }
      }
      if let selection = compact.attemptedSelection {
        guard selection.startOffset >= 0,
          selection.count > 0,
          selection.startOffset <= sourceCount,
          selection.count <= sourceCount - selection.startOffset
        else {
          throw NormalizedContextStoreError.corruptPayload("message selection bounds")
        }
      }
    }

    if let conversationArtifactID = payload.conversationContext?.activeCompactionID {
      guard conversationArtifactID == payload.conversationCompaction?.activeCompactionID else {
        throw NormalizedContextStoreError.receiptPartitionMismatch(
          "conversation and attempt reference different active summaries"
        )
      }
    }
  }

  /// Projects the immutable active artifact, or decodes the retained V1 snapshot when this
  /// conversation has not been normalized yet.
  public func activeCompactionSnapshot(
    conversationID: UUID,
    canonicalMessages: [AIChatMessage],
    legacySnapshotData: Data? = nil
  ) throws -> ConversationCompactionSnapshot? {
    let normalized = try compactionHead(conversationID: conversationID)?.activeArtifactID.map {
      let snapshot = try projectCompactionSnapshot(
        artifactID: $0,
        canonicalMessages: canonicalMessages
      )
      guard snapshot.conversationID == conversationID else {
        throw NormalizedContextStoreError.compactionConversationMismatch(snapshot.id)
      }
      return snapshot
    }
    guard let legacySnapshotData else { return normalized }

    let legacy: ConversationCompactionSnapshot
    do {
      legacy = try JSONDecoder().decode(
        ConversationCompactionSnapshot.self,
        from: legacySnapshotData
      )
      try Self.validateLegacyCompactionSnapshot(
        legacy,
        conversationID: conversationID,
        canonicalMessages: canonicalMessages
      )
    } catch {
      // Once a verified normalized head exists, a stale or damaged rollback-window blob cannot
      // replace it. With no normalized head the legacy source remains authoritative and errors.
      if let normalized { return normalized }
      throw error
    }

    guard let normalized else { return legacy }
    if normalized == legacy { return normalized }
    if normalized.coveredMessageIDs.count != legacy.coveredMessageIDs.count {
      return normalized.coveredMessageIDs.count > legacy.coveredMessageIDs.count
        ? normalized : legacy
    }
    if normalized.createdAt != legacy.createdAt {
      return normalized.createdAt > legacy.createdAt ? normalized : legacy
    }
    throw NormalizedContextStoreError.dualReadConflict(
      normalized: normalized.id,
      legacy: legacy.id
    )
  }

  /// Applies the same bounded lineage and source checks to retained V1 blobs that normalized V2
  /// artifacts receive. This is intentionally reusable by portable-backup staging.
  public nonisolated static func validateLegacyCompactionSnapshot(
    _ snapshot: ConversationCompactionSnapshot,
    conversationID: UUID,
    canonicalMessages: [AIChatMessage]
  ) throws {
    let maximumCounter = 1_000_000_000
    guard snapshot.conversationID == conversationID,
      (1...maximumCounter).contains(snapshot.chainDepth),
      (0...maximumCounter).contains(snapshot.estimatedSourceTokens),
      (0...maximumCounter).contains(snapshot.estimatedSummaryTokens),
      snapshot.inputTokenCount.map({ (0...maximumCounter).contains($0) }) ?? true,
      snapshot.outputTokenCount.map({ (0...maximumCounter).contains($0) }) ?? true,
      ConversationCompactionPlanner(contextPolicy: .conservativeDefault).isValid(
        snapshot: snapshot,
        conversationID: conversationID,
        messages: canonicalMessages
      )
    else {
      throw NormalizedContextStoreError.compactionPrefixMismatch(snapshot.id)
    }
    switch snapshot.mode {
    case .initial:
      guard snapshot.chainDepth == 1, snapshot.previousCompactionID == nil else {
        throw NormalizedContextStoreError.corruptPayload("invalid initial compaction lineage")
      }
    case .rebuild:
      guard snapshot.chainDepth == 1, snapshot.previousCompactionID != nil else {
        throw NormalizedContextStoreError.corruptPayload("invalid rebuild compaction lineage")
      }
    case .extend:
      guard snapshot.chainDepth >= 2, snapshot.previousCompactionID != nil else {
        throw NormalizedContextStoreError.corruptPayload("invalid extended compaction lineage")
      }
    }
  }

  /// Validates retained V1 request receipts before they can reach UI arithmetic or be trusted as
  /// an audit trail. It performs no writes and tolerates an unavailable historical artifact only
  /// after validating the receipt's complete structural provenance and canonical partitions.
  public func validateLegacyRequestReceipt(
    _ receipt: RequestContextReceipt,
    conversationID: UUID?,
    canonicalMessages: [AIChatMessage],
    legacyCompactionSnapshot: ConversationCompactionSnapshot? = nil
  ) throws {
    try Self.validateLegacyRequestReceiptStructure(
      receipt,
      conversationID: conversationID,
      canonicalMessages: canonicalMessages,
      legacyCompactionSnapshot: legacyCompactionSnapshot
    ) { compactionID in
      guard let artifact = try self.artifact(id: compactionID) else { return nil }
      try self.validateIntegrity(artifact)
      let coverage = try self.resolveCoverage(
        artifact: artifact,
        canonicalMessages: canonicalMessages
      )
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
        coveredMessageCount: coverage.count,
        providerConfigurationID: providerConfigurationID,
        providerKindRawValue: providerKindRawValue,
        providerDisplayName: providerDisplayName,
        providerEndpoint: providerEndpoint,
        modelIdentifier: modelIdentifier,
        createdAt: artifact.createdAt
      )
    }
  }

  nonisolated static func validateLegacyRequestReceiptStructure(
    _ receipt: RequestContextReceipt,
    conversationID: UUID?,
    canonicalMessages: [AIChatMessage],
    legacyCompactionSnapshot: ConversationCompactionSnapshot? = nil,
    activeCompactionResolver: (UUID) throws -> NormalizedLegacyCompactionReference? = { _ in nil }
  ) throws {
    guard receipt.curatedContext.includedMemories.count <= 4_096,
      receipt.retrievedContext.items.count <= 4_096,
      receipt.retrievedContext.items.allSatisfy({ $0.relevance.isFinite })
    else {
      throw NormalizedContextStoreError.corruptPayload("invalid legacy request payload")
    }

    let canonicalIDs = canonicalMessages.map(\.id)
    if let context = receipt.conversationContext {
      try Self.validateConversationTokenBudget(
        estimatedInputTokens: context.estimatedInputTokens,
        contextWindowTokens: context.contextWindowTokens,
        maximumOutputTokens: context.maximumOutputTokens,
        safetyMarginTokens: context.safetyMarginTokens
      )
      guard context.originalMessageCount == canonicalIDs.count else {
        throw NormalizedContextStoreError.sourceCountMismatch(
          expected: context.originalMessageCount,
          actual: canonicalIDs.count
        )
      }
      let rawIDs = context.includedMessageIDs
      guard rawIDs.count <= canonicalIDs.count,
        rawIDs == Array(canonicalIDs.suffix(rawIDs.count))
      else {
        throw NormalizedContextStoreError.nonContiguousSelection("legacy raw included")
      }
      let summaryIDs = context.summarizedMessageIDs ?? []
      guard summaryIDs.count <= canonicalIDs.count,
        summaryIDs == Array(canonicalIDs.prefix(summaryIDs.count))
      else {
        throw NormalizedContextStoreError.nonContiguousSelection("legacy summarized")
      }
      let recalledIDs = context.recalledMessageIDs ?? []
      if let recall = receipt.sameConversationRecall {
        guard conversationID.map({ recall.conversationID == $0 }) ?? true,
          recall.items.count <= 4_096,
          recall.eligibleCandidateCount >= recall.items.count,
          (0...1_000_000_000).contains(recall.eligibleCandidateCount),
          (0...1_000_000_000).contains(recall.injectedInputTokens),
          recall.items.allSatisfy({ $0.relevance.isFinite }),
          recall.recalledMessageIDs == recalledIDs
        else {
          throw NormalizedContextStoreError.corruptPayload("invalid legacy same-chat recall")
        }
      } else if !recalledIDs.isEmpty {
        throw NormalizedContextStoreError.receiptPartitionMismatch(
          "legacy recalled IDs have no recall audit"
        )
      }

      let rawSet = Set(rawIDs)
      let summarySet = Set(summaryIDs)
      let recalledSet = Set(recalledIDs)
      let canonicalSet = Set(canonicalIDs)
      guard rawSet.count == rawIDs.count,
        summarySet.count == summaryIDs.count,
        recalledSet.count == recalledIDs.count,
        rawSet.isDisjoint(with: summarySet),
        rawSet.isDisjoint(with: recalledSet),
        recalledSet.isSubset(of: canonicalSet)
      else {
        throw NormalizedContextStoreError.receiptPartitionMismatch(
          "legacy receipt partitions overlap or contain duplicates"
        )
      }
      if let recall = receipt.sameConversationRecall {
        guard
          recall.items.allSatisfy({ item in
            let expectedOrigin: SameConversationRecallOrigin =
              summarySet.contains(item.id) ? .summarized : .omitted
            return item.origin == expectedOrigin
          })
        else {
          throw NormalizedContextStoreError.corruptPayload(
            "invalid legacy same-chat recall origin"
          )
        }
      }
      let represented = rawSet.union(summarySet).union(recalledSet)
      guard context.omittedMessageIDs == canonicalIDs.filter({ !represented.contains($0) }) else {
        throw NormalizedContextStoreError.receiptPartitionMismatch(
          "legacy omitted membership is not canonical"
        )
      }
      switch context.strategy {
      case .full:
        guard rawIDs == canonicalIDs, context.summarizedMessageIDs == nil,
          recalledIDs.isEmpty
        else {
          throw NormalizedContextStoreError.receiptPartitionMismatch(
            "legacy full strategy is incomplete"
          )
        }
      case .recentOnly:
        guard context.summarizedMessageIDs == nil else {
          throw NormalizedContextStoreError.receiptPartitionMismatch(
            "legacy recent-only strategy contains a summary"
          )
        }
      case .summaryAndRecent:
        guard !summaryIDs.isEmpty else {
          throw NormalizedContextStoreError.receiptPartitionMismatch(
            "legacy summary strategy has no summary"
          )
        }
      }
    } else if receipt.sameConversationRecall != nil {
      throw NormalizedContextStoreError.corruptPayload("legacy recall has no context receipt")
    }

    guard let compaction = receipt.conversationCompaction else { return }
    if let attempted = compaction.attemptedMessageIDs {
      guard !attempted.isEmpty else {
        throw NormalizedContextStoreError.nonContiguousSelection("legacy attempted compaction")
      }
      _ = try Self.compactSelection(
        attempted,
        in: canonicalIDs,
        label: "legacy attempted compaction"
      )
    }
    let activeProvenanceValues: [Any?] = [
      compaction.activeSummaryProviderConfigurationID,
      compaction.activeSummaryProviderKind,
      compaction.activeSummaryProviderDisplayName,
      compaction.activeSummaryProviderEndpoint,
      compaction.activeSummaryModelIdentifier,
      compaction.activeSummaryCreatedAt,
    ]
    let presentProvenanceCount = activeProvenanceValues.compactMap { $0 }.count
    guard presentProvenanceCount == 0 || presentProvenanceCount == activeProvenanceValues.count
    else {
      throw NormalizedContextStoreError.corruptPayload("partial legacy active provenance")
    }
    let hasActiveProvenance = presentProvenanceCount == activeProvenanceValues.count
    try Self.validateCompactionAudit(
      status: compaction.status,
      activeCompactionID: compaction.compactionID,
      summaryTextPresent: compaction.summaryText != nil,
      attemptedSelectionPresent: compaction.attemptedMessageIDs != nil,
      activeProvenancePresent: hasActiveProvenance,
      inputTokenCount: compaction.inputTokenCount,
      outputTokenCount: compaction.outputTokenCount,
      estimatedInputTokensBefore: compaction.estimatedInputTokensBefore,
      estimatedInputTokensAfter: compaction.estimatedInputTokensAfter,
      extraRequestCount: compaction.extraRequestCount
    )
    if let compactionID = compaction.compactionID {
      guard let summary = compaction.summaryText, !summary.isEmpty,
        !compaction.coveredMessageIDs.isEmpty,
        compaction.coveredMessageIDs.count <= canonicalIDs.count,
        compaction.coveredMessageIDs
          == Array(canonicalIDs.prefix(compaction.coveredMessageIDs.count)),
        hasActiveProvenance
      else {
        throw NormalizedContextStoreError.corruptPayload("invalid legacy active compaction")
      }
      if let legacyCompactionSnapshot, legacyCompactionSnapshot.id == compactionID {
        guard legacyCompactionSnapshot.renderedSummary == summary,
          legacyCompactionSnapshot.coveredMessageIDs == compaction.coveredMessageIDs,
          legacyCompactionSnapshot.providerConfigurationID
            == compaction.activeSummaryProviderConfigurationID,
          legacyCompactionSnapshot.providerKind == compaction.activeSummaryProviderKind,
          legacyCompactionSnapshot.providerDisplayName
            == compaction.activeSummaryProviderDisplayName,
          legacyCompactionSnapshot.providerEndpoint == compaction.activeSummaryProviderEndpoint,
          legacyCompactionSnapshot.modelIdentifier == compaction.activeSummaryModelIdentifier,
          legacyCompactionSnapshot.createdAt == compaction.activeSummaryCreatedAt
        else {
          throw NormalizedContextStoreError.compactionArtifactConflict(compactionID)
        }
      } else if let reference = try activeCompactionResolver(compactionID) {
        guard reference.id == compactionID,
          reference.renderedSummary == summary,
          reference.coveredMessageCount == compaction.coveredMessageIDs.count,
          reference.providerConfigurationID
            == compaction.activeSummaryProviderConfigurationID,
          reference.providerKindRawValue == compaction.activeSummaryProviderKind?.rawValue,
          reference.providerDisplayName == compaction.activeSummaryProviderDisplayName,
          reference.providerEndpoint == compaction.activeSummaryProviderEndpoint,
          reference.modelIdentifier == compaction.activeSummaryModelIdentifier,
          reference.createdAt == compaction.activeSummaryCreatedAt
        else {
          throw NormalizedContextStoreError.compactionArtifactConflict(compactionID)
        }
      }
    } else {
      guard compaction.summaryText == nil, compaction.coveredMessageIDs.isEmpty,
        !hasActiveProvenance
      else {
        throw NormalizedContextStoreError.corruptPayload(
          "legacy active compaction has no artifact ID"
        )
      }
    }
  }

  public func projectCompactionSnapshot(
    artifactID: UUID,
    canonicalMessages: [AIChatMessage]
  ) throws -> ConversationCompactionSnapshot {
    try projectSnapshot(
      artifact: requiredArtifact(id: artifactID),
      canonicalMessages: canonicalMessages
    )
  }

  /// Converts at most one deterministic batch. Source bytes are inputs only and are never removed
  /// or changed; malformed items advance as explicitly retained legacy records.
  public func backfillLegacyReceipts(
    _ items: [LegacyRequestContextBackfillItem],
    migrationKey: String,
    batchSize: Int = 100,
    at date: Date = .now
  ) throws -> NormalizedContextBackfillResult {
    let boundedBatchSize = max(1, batchSize)
    let ordered = items.sorted {
      Self.eventKey(
        assistantMessageID: $0.assistantMessageID,
        eventSequence: $0.eventSequence
      )
        < Self.eventKey(
          assistantMessageID: $1.assistantMessageID,
          eventSequence: $1.eventSequence
        )
    }
    var progress = try backfillProgress(migrationKey: migrationKey, createIfMissing: true, at: date)
    guard !progress.isComplete else {
      return NormalizedContextBackfillResult(
        processedCount: 0,
        insertedEventCount: 0,
        retainedLegacyCount: 0,
        isComplete: true,
        failedEventKeys: []
      )
    }

    let remaining = ordered.filter { item in
      guard let last = progress.lastEventKey else { return true }
      return Self.eventKey(
        assistantMessageID: item.assistantMessageID,
        eventSequence: item.eventSequence
      ) > last
    }
    let selected = Array(remaining.prefix(boundedBatchSize))
    var insertedCount = 0
    var retainedCount = 0
    var failedKeys: [String] = []

    for item in selected {
      let key = Self.eventKey(
        assistantMessageID: item.assistantMessageID,
        eventSequence: item.eventSequence
      )
      do {
        let receipt = try JSONDecoder().decode(
          RequestContextReceipt.self,
          from: item.legacyReceiptData
        )
        let snapshot = try item.legacyCompactionSnapshotData.map {
          try JSONDecoder().decode(ConversationCompactionSnapshot.self, from: $0)
        }
        let disposition = try insertRequestEvent(
          assistantMessageID: item.assistantMessageID,
          conversationID: item.conversationID,
          sourceThroughMessageID: item.sourceThroughMessageID,
          eventSequence: item.eventSequence,
          receipt: receipt,
          canonicalMessages: item.canonicalMessages,
          activeCompactionSnapshot: snapshot,
          legacyReceiptFingerprint: NormalizedContextCodec.fingerprint(item.legacyReceiptData),
          createdAt: item.createdAt
        )
        try progress.recordSuccess(eventKey: key, at: date)
        try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
        if disposition == .inserted { insertedCount += 1 }
      } catch {
        modelContext.rollback()
        progress = try backfillProgress(migrationKey: migrationKey, createIfMissing: true, at: date)
        try progress.recordFailure(eventKey: key, at: date)
        try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
        retainedCount += 1
        failedKeys.append(key)
      }
    }

    progress = try backfillProgress(migrationKey: migrationKey, createIfMissing: true, at: date)
    let hasMore = remaining.count > selected.count
    if !hasMore {
      progress.markComplete(at: date)
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: modelContext)
    }

    return NormalizedContextBackfillResult(
      processedCount: selected.count,
      insertedEventCount: insertedCount,
      retainedLegacyCount: retainedCount,
      isComplete: !hasMore,
      failedEventKeys: failedKeys
    )
  }

  public nonisolated static func eventKey(
    assistantMessageID: UUID,
    eventSequence: Int
  ) -> String {
    let paddedSequence = String(format: "%020lld", Int64(eventSequence))
    return "request-context/v1/\(assistantMessageID.uuidString.lowercased())/\(paddedSequence)"
  }

  public nonisolated static func eventID(
    assistantMessageID: UUID,
    eventSequence: Int
  ) -> UUID {
    NormalizedContextCodec.deterministicUUID(
      eventKey(
        assistantMessageID: assistantMessageID,
        eventSequence: eventSequence
      )
    )
  }

  private func insertRequestEvent(
    assistantMessageID: UUID,
    conversationID: UUID,
    sourceThroughMessageID: UUID,
    eventSequence: Int,
    receipt: RequestContextReceipt,
    canonicalMessages: [AIChatMessage],
    activeCompactionSnapshot: ConversationCompactionSnapshot?,
    legacyReceiptFingerprint: String?,
    createdAt: Date
  ) throws -> NormalizedContextInsertDisposition {
    guard eventSequence >= 0 else {
      throw NormalizedContextStoreError.invalidEventSequence(eventSequence)
    }
    let source = try canonicalSource(
      canonicalMessages,
      through: sourceThroughMessageID,
      count: receipt.conversationContext?.originalMessageCount ?? canonicalMessages.count
    )
    if let activeCompactionSnapshot {
      guard activeCompactionSnapshot.conversationID == conversationID else {
        throw NormalizedContextStoreError.compactionConversationMismatch(
          activeCompactionSnapshot.id
        )
      }
      _ = try insertCompactionArtifact(
        snapshot: activeCompactionSnapshot,
        canonicalMessages: canonicalMessages,
        allowDetachedLegacyRoot: legacyReceiptFingerprint != nil
      )
    }
    try ensureReceiptCompactionArtifact(
      receipt.conversationCompaction,
      conversationID: conversationID,
      canonicalMessages: source
    )

    let compactConversation = try compactConversationContext(
      receipt.conversationContext,
      sameConversationRecall: receipt.sameConversationRecall,
      compactionReceipt: receipt.conversationCompaction,
      canonicalMessages: source,
      expectedConversationID: conversationID
    )
    let compactCompaction = try compactCompactionReceipt(
      receipt.conversationCompaction,
      canonicalMessages: source
    )
    let payload = NormalizedRequestPayload(
      schemaVersion: Self.requestPayloadVersion,
      curatedContext: receipt.curatedContext,
      retrievedContext: receipt.retrievedContext,
      projectContext: receipt.projectContext,
      conversationContext: compactConversation,
      sameConversationRecall: receipt.sameConversationRecall,
      conversationCompaction: compactCompaction,
      receiptCreatedAt: receipt.createdAt
    )
    let payloadData = try NormalizedContextCodec.encode(payload)
    guard payloadData.count <= Self.maximumCompactPayloadBytes else {
      throw NormalizedContextStoreError.payloadTooLarge(payloadData.count)
    }
    let payloadFingerprint = NormalizedContextCodec.fingerprint(payloadData)
    let eventKey = Self.eventKey(
      assistantMessageID: assistantMessageID,
      eventSequence: eventSequence
    )

    if let existing = try event(key: eventKey) {
      guard existing.assistantMessageID == assistantMessageID,
        existing.conversationID == conversationID,
        existing.sourceThroughMessageID == sourceThroughMessageID,
        existing.sourceMessageCount == source.count,
        existing.eventSequence == eventSequence,
        existing.payloadData == payloadData,
        existing.payloadFingerprint == payloadFingerprint,
        existing.legacyReceiptFingerprint == legacyReceiptFingerprint
      else {
        throw NormalizedContextStoreError.idempotencyConflict(eventKey)
      }
      return .alreadyPresent
    }

    modelContext.insert(
      RequestContextEventRecord(
        id: Self.eventID(
          assistantMessageID: assistantMessageID,
          eventSequence: eventSequence
        ),
        eventKey: eventKey,
        assistantMessageID: assistantMessageID,
        conversationID: conversationID,
        sourceThroughMessageID: sourceThroughMessageID,
        sourceMessageCount: source.count,
        eventSequence: eventSequence,
        payloadData: payloadData,
        payloadFingerprint: payloadFingerprint,
        legacyReceiptFingerprint: legacyReceiptFingerprint,
        createdAt: createdAt
      )
    )
    return .inserted
  }

  private func insertCompactionArtifact(
    snapshot: ConversationCompactionSnapshot,
    canonicalMessages: [AIChatMessage],
    allowDetachedLegacyRoot: Bool
  ) throws -> NormalizedContextInsertDisposition {
    guard
      ConversationCompactionPlanner(contextPolicy: .conservativeDefault).isValid(
        snapshot: snapshot,
        conversationID: snapshot.conversationID,
        messages: canonicalMessages
      )
    else {
      throw NormalizedContextStoreError.compactionPrefixMismatch(snapshot.id)
    }

    // Detached legacy roots intentionally retain their original lineage identifier even when the
    // predecessor row is unavailable. Once that exact immutable artifact has been verified and
    // stored, subsequent request events must be able to reference it idempotently without trying
    // to resolve the absent predecessor again.
    if let existing = try artifact(id: snapshot.id) {
      let persisted = try projectSnapshot(
        artifact: existing,
        canonicalMessages: canonicalMessages
      )
      guard persisted == snapshot else {
        throw NormalizedContextStoreError.compactionArtifactConflict(snapshot.id)
      }
      return .alreadyPresent
    }
    try validateNewCompactionLineageMetadata(
      snapshot,
      allowDetachedLegacyRoot: allowDetachedLegacyRoot
    )

    let parentCoverage: [UUID]
    let coverageParentID: UUID?
    var isDetachedCoverageRoot = false
    if let previousID = snapshot.previousCompactionID {
      if let parent = try artifact(id: previousID) {
        guard parent.conversationID == snapshot.conversationID else {
          throw NormalizedContextStoreError.compactionConversationMismatch(previousID)
        }
        parentCoverage = try resolveCoverage(
          artifact: parent,
          canonicalMessages: canonicalMessages
        )
        coverageParentID = parent.id
      } else if allowDetachedLegacyRoot {
        parentCoverage = []
        coverageParentID = nil
        isDetachedCoverageRoot = true
      } else {
        throw NormalizedContextStoreError.missingCompactionArtifact(previousID)
      }
    } else {
      parentCoverage = []
      coverageParentID = nil
    }

    guard snapshot.coveredMessageIDs.starts(with: parentCoverage) else {
      throw NormalizedContextStoreError.compactionPrefixMismatch(snapshot.id)
    }
    let delta = Array(snapshot.coveredMessageIDs.dropFirst(parentCoverage.count))
    let coverageDeltaData = try NormalizedContextCodec.encode(delta)
    let contentData = try NormalizedContextCodec.encode(snapshot.content)
    let warningsData = try NormalizedContextCodec.encode(snapshot.warnings)
    let envelope = CompactionArtifactIntegrityEnvelope(
      id: snapshot.id,
      conversationID: snapshot.conversationID,
      lineagePreviousCompactionID: snapshot.previousCompactionID,
      coverageParentArtifactID: coverageParentID,
      coverageDeltaData: coverageDeltaData,
      coveredMessageCount: snapshot.coveredMessageIDs.count,
      modeRawValue: snapshot.mode.rawValue,
      promptVersion: snapshot.promptVersion,
      contentSchemaVersion: snapshot.content.schemaVersion,
      contentData: contentData,
      renderedSummary: snapshot.renderedSummary,
      sourceFingerprint: snapshot.sourceFingerprint,
      providerConfigurationID: snapshot.providerConfigurationID,
      providerKindRawValue: snapshot.providerKind.rawValue,
      providerDisplayName: snapshot.providerDisplayName,
      providerEndpoint: snapshot.providerEndpoint,
      modelIdentifier: snapshot.modelIdentifier,
      providerMessageID: snapshot.providerMessageID,
      inputTokenCount: snapshot.inputTokenCount,
      outputTokenCount: snapshot.outputTokenCount,
      estimatedSourceTokens: snapshot.estimatedSourceTokens,
      estimatedSummaryTokens: snapshot.estimatedSummaryTokens,
      chainDepth: snapshot.chainDepth,
      warningsData: warningsData,
      isSnapshotComplete: true,
      isDetachedCoverageRoot: isDetachedCoverageRoot,
      createdAt: snapshot.createdAt
    )
    return try insertArtifact(envelope)
  }

  private func validateNewCompactionLineageMetadata(
    _ snapshot: ConversationCompactionSnapshot,
    allowDetachedLegacyRoot: Bool
  ) throws {
    switch snapshot.mode {
    case .initial:
      guard snapshot.chainDepth == 1, snapshot.previousCompactionID == nil else {
        throw NormalizedContextStoreError.corruptPayload("invalid initial compaction lineage")
      }
    case .rebuild:
      guard snapshot.chainDepth == 1, snapshot.previousCompactionID != nil else {
        throw NormalizedContextStoreError.corruptPayload("invalid rebuild compaction lineage")
      }
    case .extend:
      guard let parentID = snapshot.previousCompactionID else {
        throw NormalizedContextStoreError.corruptPayload("invalid extended compaction lineage")
      }
      if let parent = try artifact(id: parentID) {
        let (expectedDepth, overflow) = parent.chainDepth.addingReportingOverflow(1)
        guard !overflow, snapshot.chainDepth == expectedDepth else {
          throw NormalizedContextStoreError.corruptPayload("invalid extended compaction lineage")
        }
      } else {
        guard allowDetachedLegacyRoot, snapshot.chainDepth >= 2 else {
          throw NormalizedContextStoreError.corruptPayload("invalid detached compaction lineage")
        }
      }
    }
  }

  private func ensureReceiptCompactionArtifact(
    _ receipt: ConversationCompactionReceipt?,
    conversationID: UUID,
    canonicalMessages: [AIChatMessage]
  ) throws {
    guard let receipt, let compactionID = receipt.compactionID else {
      if let receipt {
        guard receipt.summaryText == nil, receipt.coveredMessageIDs.isEmpty,
          receipt.activeSummaryProviderConfigurationID == nil,
          receipt.activeSummaryProviderKind == nil,
          receipt.activeSummaryProviderDisplayName == nil,
          receipt.activeSummaryProviderEndpoint == nil,
          receipt.activeSummaryModelIdentifier == nil,
          receipt.activeSummaryCreatedAt == nil
        else {
          throw NormalizedContextStoreError.receiptPartitionMismatch(
            "active summary fields exist without a compaction ID"
          )
        }
      }
      return
    }

    if let existing = try artifact(id: compactionID) {
      guard existing.conversationID == conversationID else {
        throw NormalizedContextStoreError.compactionConversationMismatch(compactionID)
      }
      try validateArtifact(existing, against: receipt, canonicalMessages: canonicalMessages)
      return
    }
    guard let summary = receipt.summaryText, !summary.isEmpty,
      !receipt.coveredMessageIDs.isEmpty,
      let providerConfigurationID = receipt.activeSummaryProviderConfigurationID,
      let providerKind = receipt.activeSummaryProviderKind,
      let providerDisplayName = receipt.activeSummaryProviderDisplayName,
      let providerEndpoint = receipt.activeSummaryProviderEndpoint,
      let modelIdentifier = receipt.activeSummaryModelIdentifier,
      let activeSummaryCreatedAt = receipt.activeSummaryCreatedAt
    else {
      throw NormalizedContextStoreError.incompleteCompactionArtifact(compactionID)
    }
    guard canonicalMessages.map(\.id).starts(with: receipt.coveredMessageIDs) else {
      throw NormalizedContextStoreError.compactionPrefixMismatch(compactionID)
    }

    let deltaData = try NormalizedContextCodec.encode(receipt.coveredMessageIDs)
    let warningsData = try NormalizedContextCodec.encode([String]())
    let envelope = CompactionArtifactIntegrityEnvelope(
      id: compactionID,
      conversationID: conversationID,
      lineagePreviousCompactionID: nil,
      coverageParentArtifactID: nil,
      coverageDeltaData: deltaData,
      coveredMessageCount: receipt.coveredMessageIDs.count,
      modeRawValue: ConversationCompactionMode.initial.rawValue,
      promptVersion: ConversationCompactionPrompt.version,
      contentSchemaVersion: ConversationCompactionContent.currentSchemaVersion,
      contentData: nil,
      renderedSummary: summary,
      sourceFingerprint: nil,
      providerConfigurationID: providerConfigurationID,
      providerKindRawValue: providerKind.rawValue,
      providerDisplayName: providerDisplayName,
      providerEndpoint: providerEndpoint,
      modelIdentifier: modelIdentifier,
      providerMessageID: nil,
      inputTokenCount: nil,
      outputTokenCount: nil,
      estimatedSourceTokens: 0,
      estimatedSummaryTokens: 0,
      chainDepth: 1,
      warningsData: warningsData,
      isSnapshotComplete: false,
      isDetachedCoverageRoot: false,
      createdAt: activeSummaryCreatedAt
    )
    _ = try insertArtifact(envelope)
  }

  private func insertArtifact(
    _ envelope: CompactionArtifactIntegrityEnvelope
  ) throws -> NormalizedContextInsertDisposition {
    let envelopeData = try NormalizedContextCodec.encode(envelope)
    let fingerprint = NormalizedContextCodec.fingerprint(envelopeData)
    if let existing = try artifact(id: envelope.id) {
      guard try integrityEnvelope(for: existing) == envelope,
        existing.payloadFingerprint == fingerprint
      else {
        throw NormalizedContextStoreError.compactionArtifactConflict(envelope.id)
      }
      return .alreadyPresent
    }

    modelContext.insert(
      CompactionArtifactRecord(
        id: envelope.id,
        conversationID: envelope.conversationID,
        lineagePreviousCompactionID: envelope.lineagePreviousCompactionID,
        coverageParentArtifactID: envelope.coverageParentArtifactID,
        coverageDeltaData: envelope.coverageDeltaData,
        coveredMessageCount: envelope.coveredMessageCount,
        modeRawValue: envelope.modeRawValue,
        promptVersion: envelope.promptVersion,
        contentSchemaVersion: envelope.contentSchemaVersion,
        contentData: envelope.contentData,
        renderedSummary: envelope.renderedSummary,
        sourceFingerprint: envelope.sourceFingerprint,
        providerConfigurationID: envelope.providerConfigurationID,
        providerKindRawValue: envelope.providerKindRawValue,
        providerDisplayName: envelope.providerDisplayName,
        providerEndpoint: envelope.providerEndpoint,
        modelIdentifier: envelope.modelIdentifier,
        providerMessageID: envelope.providerMessageID,
        inputTokenCount: envelope.inputTokenCount,
        outputTokenCount: envelope.outputTokenCount,
        estimatedSourceTokens: envelope.estimatedSourceTokens,
        estimatedSummaryTokens: envelope.estimatedSummaryTokens,
        chainDepth: envelope.chainDepth,
        warningsData: envelope.warningsData,
        isSnapshotComplete: envelope.isSnapshotComplete,
        isDetachedCoverageRoot: envelope.isDetachedCoverageRoot,
        payloadFingerprint: fingerprint,
        createdAt: envelope.createdAt
      )
    )
    return .inserted
  }

  private func compactConversationContext(
    _ receipt: ConversationContextReceipt?,
    sameConversationRecall: SameConversationRecallReceipt?,
    compactionReceipt: ConversationCompactionReceipt?,
    canonicalMessages: [AIChatMessage],
    expectedConversationID: UUID
  ) throws -> CompactConversationContext? {
    guard let receipt else {
      guard sameConversationRecall == nil else {
        throw NormalizedContextStoreError.corruptPayload(
          "same-chat recall has no context receipt"
        )
      }
      return nil
    }
    try Self.validateConversationTokenBudget(
      estimatedInputTokens: receipt.estimatedInputTokens,
      contextWindowTokens: receipt.contextWindowTokens,
      maximumOutputTokens: receipt.maximumOutputTokens,
      safetyMarginTokens: receipt.safetyMarginTokens
    )
    guard receipt.originalMessageCount == canonicalMessages.count else {
      throw NormalizedContextStoreError.sourceCountMismatch(
        expected: receipt.originalMessageCount,
        actual: canonicalMessages.count
      )
    }
    let canonicalIDs = canonicalMessages.map(\.id)
    let rawCount = receipt.includedMessageIDs.count
    guard rawCount <= canonicalIDs.count,
      receipt.includedMessageIDs == Array(canonicalIDs.suffix(rawCount))
    else {
      throw NormalizedContextStoreError.nonContiguousSelection("raw included")
    }

    let activeCompactionID = compactionReceipt?.compactionID
    let summaryIDs: [UUID]
    if receipt.summarizedMessageIDs != nil {
      if let activeCompactionID {
        summaryIDs = try resolveCoverage(
          artifact: requiredArtifact(id: activeCompactionID),
          canonicalMessages: canonicalMessages
        )
      } else {
        summaryIDs = []
      }
      guard receipt.summarizedMessageIDs == summaryIDs else {
        throw NormalizedContextStoreError.receiptPartitionMismatch(
          "summary coverage differs from its immutable artifact"
        )
      }
    } else {
      summaryIDs = []
    }

    let recalledIDs = receipt.recalledMessageIDs ?? []
    if let sameConversationRecall {
      guard sameConversationRecall.conversationID == expectedConversationID else {
        throw NormalizedContextStoreError.receiptPartitionMismatch(
          "same-chat recall belongs to another conversation"
        )
      }
      guard sameConversationRecall.recalledMessageIDs == recalledIDs else {
        throw NormalizedContextStoreError.receiptPartitionMismatch(
          "same-chat recall IDs disagree across receipt sections"
        )
      }
      guard sameConversationRecall.items.count <= 4_096,
        sameConversationRecall.eligibleCandidateCount >= sameConversationRecall.items.count,
        (0...1_000_000_000).contains(sameConversationRecall.eligibleCandidateCount),
        (0...1_000_000_000).contains(sameConversationRecall.injectedInputTokens),
        sameConversationRecall.items.allSatisfy({ $0.relevance.isFinite })
      else {
        throw NormalizedContextStoreError.corruptPayload("invalid same-chat recall audit")
      }
    } else if !recalledIDs.isEmpty {
      throw NormalizedContextStoreError.receiptPartitionMismatch(
        "same-chat IDs exist without their bounded recall receipt"
      )
    }

    let rawSet = Set(receipt.includedMessageIDs)
    let summarySet = Set(summaryIDs)
    let recalledSet = Set(recalledIDs)
    let canonicalSet = Set(canonicalIDs)
    guard rawSet.count == receipt.includedMessageIDs.count,
      summarySet.count == summaryIDs.count,
      recalledSet.count == recalledIDs.count,
      rawSet.isDisjoint(with: summarySet),
      rawSet.isDisjoint(with: recalledSet),
      recalledSet.isSubset(of: canonicalSet)
    else {
      throw NormalizedContextStoreError.receiptPartitionMismatch(
        "raw, summary, or recalled membership is duplicated"
      )
    }
    if let sameConversationRecall {
      guard
        sameConversationRecall.items.allSatisfy({ item in
          let expectedOrigin: SameConversationRecallOrigin =
            summarySet.contains(item.id) ? .summarized : .omitted
          return item.origin == expectedOrigin
        })
      else {
        throw NormalizedContextStoreError.receiptPartitionMismatch(
          "same-chat recall origin disagrees with summary membership"
        )
      }
    }
    let represented = rawSet.union(summarySet).union(recalledSet)
    let expectedOmitted = canonicalIDs.filter { !represented.contains($0) }
    guard receipt.omittedMessageIDs == expectedOmitted else {
      throw NormalizedContextStoreError.receiptPartitionMismatch(
        "omitted membership is not the canonical complement"
      )
    }

    return CompactConversationContext(
      strategy: receipt.strategy,
      rawIncludedMessageCount: rawCount,
      summarizedFieldPresent: receipt.summarizedMessageIDs != nil,
      recalledMessageIDs: receipt.recalledMessageIDs,
      activeCompactionID: activeCompactionID,
      estimatedInputTokens: receipt.estimatedInputTokens,
      contextWindowTokens: receipt.contextWindowTokens,
      maximumOutputTokens: receipt.maximumOutputTokens,
      safetyMarginTokens: receipt.safetyMarginTokens,
      warnings: receipt.warnings
    )
  }

  private func compactCompactionReceipt(
    _ receipt: ConversationCompactionReceipt?,
    canonicalMessages: [AIChatMessage]
  ) throws -> CompactCompactionReceipt? {
    guard let receipt else { return nil }
    let attemptedSelection = try receipt.attemptedMessageIDs.map {
      try Self.compactSelection(
        $0,
        in: canonicalMessages.map(\.id),
        label: "attempted compaction"
      )
    }
    let hasActiveProvenance =
      receipt.activeSummaryProviderConfigurationID != nil
      || receipt.activeSummaryProviderKind != nil
      || receipt.activeSummaryProviderDisplayName != nil
      || receipt.activeSummaryProviderEndpoint != nil
      || receipt.activeSummaryModelIdentifier != nil
      || receipt.activeSummaryCreatedAt != nil
    try Self.validateCompactionAudit(
      status: receipt.status,
      activeCompactionID: receipt.compactionID,
      summaryTextPresent: receipt.summaryText != nil,
      attemptedSelectionPresent: attemptedSelection != nil,
      activeProvenancePresent: hasActiveProvenance,
      inputTokenCount: receipt.inputTokenCount,
      outputTokenCount: receipt.outputTokenCount,
      estimatedInputTokensBefore: receipt.estimatedInputTokensBefore,
      estimatedInputTokensAfter: receipt.estimatedInputTokensAfter,
      extraRequestCount: receipt.extraRequestCount
    )

    if let compactionID = receipt.compactionID {
      let artifact = try requiredArtifact(id: compactionID)
      try validateArtifact(artifact, against: receipt, canonicalMessages: canonicalMessages)
      guard hasActiveProvenance else {
        throw NormalizedContextStoreError.receiptPartitionMismatch(
          "a compaction artifact exists without active provenance"
        )
      }
    } else if hasActiveProvenance || receipt.summaryText != nil
      || !receipt.coveredMessageIDs.isEmpty
    {
      throw NormalizedContextStoreError.receiptPartitionMismatch(
        "active compaction data exists without an artifact ID"
      )
    }

    return CompactCompactionReceipt(
      attemptID: receipt.attemptID,
      status: receipt.status,
      activeCompactionID: receipt.compactionID,
      summaryTextPresent: receipt.summaryText != nil,
      attemptedSelection: attemptedSelection,
      activeProvenancePresent: hasActiveProvenance,
      providerConfigurationID: receipt.providerConfigurationID,
      providerKind: receipt.providerKind,
      providerDisplayName: receipt.providerDisplayName,
      providerEndpoint: receipt.providerEndpoint,
      modelIdentifier: receipt.modelIdentifier,
      providerMessageID: receipt.providerMessageID,
      inputTokenCount: receipt.inputTokenCount,
      outputTokenCount: receipt.outputTokenCount,
      estimatedInputTokensBefore: receipt.estimatedInputTokensBefore,
      estimatedInputTokensAfter: receipt.estimatedInputTokensAfter,
      extraRequestCount: receipt.extraRequestCount,
      errorDescription: receipt.errorDescription,
      warnings: receipt.warnings,
      createdAt: receipt.createdAt
    )
  }

  private func projectReceipt(
    event: RequestContextEventRecord,
    canonicalMessages: [AIChatMessage]
  ) throws -> RequestContextReceipt {
    guard
      event.eventKey
        == Self.eventKey(
          assistantMessageID: event.assistantMessageID,
          eventSequence: event.eventSequence
        )
    else {
      throw NormalizedContextStoreError.corruptPayload("event key mismatch")
    }
    guard NormalizedContextCodec.fingerprint(event.payloadData) == event.payloadFingerprint else {
      throw NormalizedContextStoreError.corruptPayload("request payload fingerprint mismatch")
    }
    let payload: NormalizedRequestPayload
    do {
      payload = try NormalizedContextCodec.decode(
        NormalizedRequestPayload.self,
        from: event.payloadData
      )
    } catch {
      throw NormalizedContextStoreError.corruptPayload("request payload is not decodable")
    }
    guard payload.schemaVersion == Self.requestPayloadVersion else {
      throw NormalizedContextStoreError.unsupportedPayloadVersion(payload.schemaVersion)
    }
    let source = try canonicalSource(
      canonicalMessages,
      through: event.sourceThroughMessageID,
      count: event.sourceMessageCount
    )
    let referencedArtifactIDs = [
      payload.conversationContext?.activeCompactionID,
      payload.conversationCompaction?.activeCompactionID,
    ].compactMap { $0 }
    for artifactID in referencedArtifactIDs {
      guard try requiredArtifact(id: artifactID).conversationID == event.conversationID else {
        throw NormalizedContextStoreError.compactionConversationMismatch(artifactID)
      }
    }
    let conversationContext = try payload.conversationContext.map {
      try projectConversationContext($0, canonicalMessages: source)
    }
    let compactionReceipt = try payload.conversationCompaction.map {
      try projectCompactionReceipt($0, canonicalMessages: source)
    }
    let result = RequestContextReceipt(
      curatedContext: payload.curatedContext,
      retrievedContext: payload.retrievedContext,
      projectContext: payload.projectContext,
      conversationContext: conversationContext,
      sameConversationRecall: payload.sameConversationRecall,
      conversationCompaction: compactionReceipt,
      createdAt: payload.receiptCreatedAt
    )

    _ = try compactConversationContext(
      result.conversationContext,
      sameConversationRecall: result.sameConversationRecall,
      compactionReceipt: result.conversationCompaction,
      canonicalMessages: source,
      expectedConversationID: event.conversationID
    )
    return result
  }

  private func projectConversationContext(
    _ compact: CompactConversationContext,
    canonicalMessages: [AIChatMessage]
  ) throws -> ConversationContextReceipt {
    try Self.validateConversationTokenBudget(
      estimatedInputTokens: compact.estimatedInputTokens,
      contextWindowTokens: compact.contextWindowTokens,
      maximumOutputTokens: compact.maximumOutputTokens,
      safetyMarginTokens: compact.safetyMarginTokens
    )
    let ids = canonicalMessages.map(\.id)
    guard compact.rawIncludedMessageCount >= 0,
      compact.rawIncludedMessageCount <= ids.count
    else {
      throw NormalizedContextStoreError.corruptPayload("invalid raw suffix count")
    }
    let rawIDs = Array(ids.suffix(compact.rawIncludedMessageCount))
    let summaryIDs: [UUID]
    if compact.summarizedFieldPresent, let artifactID = compact.activeCompactionID {
      summaryIDs = try resolveCoverage(
        artifact: requiredArtifact(id: artifactID),
        canonicalMessages: canonicalMessages
      )
    } else {
      summaryIDs = []
    }
    let recalledIDs = compact.recalledMessageIDs ?? []
    let represented = Set(rawIDs + summaryIDs + recalledIDs)
    let omittedIDs = ids.filter { !represented.contains($0) }
    return ConversationContextReceipt(
      strategy: compact.strategy,
      originalMessageCount: ids.count,
      includedMessageIDs: rawIDs,
      omittedMessageIDs: omittedIDs,
      summarizedMessageIDs: compact.summarizedFieldPresent ? summaryIDs : nil,
      recalledMessageIDs: compact.recalledMessageIDs,
      estimatedInputTokens: compact.estimatedInputTokens,
      contextWindowTokens: compact.contextWindowTokens,
      maximumOutputTokens: compact.maximumOutputTokens,
      safetyMarginTokens: compact.safetyMarginTokens,
      warnings: compact.warnings
    )
  }

  fileprivate nonisolated static func validateConversationTokenBudget(
    estimatedInputTokens: Int,
    contextWindowTokens: Int,
    maximumOutputTokens: Int,
    safetyMarginTokens: Int
  ) throws {
    guard estimatedInputTokens >= 0,
      (1...2_000_000).contains(contextWindowTokens),
      (0...1_000_000).contains(maximumOutputTokens),
      (0...2_000_000).contains(safetyMarginTokens),
      maximumOutputTokens < contextWindowTokens
    else {
      throw NormalizedContextStoreError.corruptPayload("invalid conversation token budget")
    }
    let afterOutput = contextWindowTokens - maximumOutputTokens
    guard safetyMarginTokens < afterOutput else {
      throw NormalizedContextStoreError.corruptPayload("invalid conversation token budget")
    }
    let availableInputTokens = afterOutput - safetyMarginTokens
    guard estimatedInputTokens <= availableInputTokens else {
      throw NormalizedContextStoreError.corruptPayload("invalid conversation token budget")
    }
  }

  private func projectCompactionReceipt(
    _ compact: CompactCompactionReceipt,
    canonicalMessages: [AIChatMessage]
  ) throws -> ConversationCompactionReceipt {
    try Self.validateCompactionAudit(
      status: compact.status,
      activeCompactionID: compact.activeCompactionID,
      summaryTextPresent: compact.summaryTextPresent,
      attemptedSelectionPresent: compact.attemptedSelection != nil,
      activeProvenancePresent: compact.activeProvenancePresent,
      inputTokenCount: compact.inputTokenCount,
      outputTokenCount: compact.outputTokenCount,
      estimatedInputTokensBefore: compact.estimatedInputTokensBefore,
      estimatedInputTokensAfter: compact.estimatedInputTokensAfter,
      extraRequestCount: compact.extraRequestCount
    )
    let artifact = try compact.activeCompactionID.map { try requiredArtifact(id: $0) }
    let coveredIDs =
      try artifact.map {
        try resolveCoverage(artifact: $0, canonicalMessages: canonicalMessages)
      } ?? []
    let attemptedIDs = try compact.attemptedSelection.map {
      try projectSelection($0, from: canonicalMessages.map(\.id))
    }
    let providerKind = artifact?.providerKindRawValue.flatMap(ProviderKind.init(rawValue:))
    return ConversationCompactionReceipt(
      attemptID: compact.attemptID,
      status: compact.status,
      compactionID: compact.activeCompactionID,
      summaryText: compact.summaryTextPresent ? artifact?.renderedSummary : nil,
      coveredMessageIDs: coveredIDs,
      attemptedMessageIDs: attemptedIDs,
      activeSummaryProviderConfigurationID: compact.activeProvenancePresent
        ? artifact?.providerConfigurationID : nil,
      activeSummaryProviderKind: compact.activeProvenancePresent ? providerKind : nil,
      activeSummaryProviderDisplayName: compact.activeProvenancePresent
        ? artifact?.providerDisplayName : nil,
      activeSummaryProviderEndpoint: compact.activeProvenancePresent
        ? artifact?.providerEndpoint : nil,
      activeSummaryModelIdentifier: compact.activeProvenancePresent
        ? artifact?.modelIdentifier : nil,
      activeSummaryCreatedAt: compact.activeProvenancePresent ? artifact?.createdAt : nil,
      providerConfigurationID: compact.providerConfigurationID,
      providerKind: compact.providerKind,
      providerDisplayName: compact.providerDisplayName,
      providerEndpoint: compact.providerEndpoint,
      modelIdentifier: compact.modelIdentifier,
      providerMessageID: compact.providerMessageID,
      inputTokenCount: compact.inputTokenCount,
      outputTokenCount: compact.outputTokenCount,
      estimatedInputTokensBefore: compact.estimatedInputTokensBefore,
      estimatedInputTokensAfter: compact.estimatedInputTokensAfter,
      extraRequestCount: compact.extraRequestCount,
      errorDescription: compact.errorDescription,
      warnings: compact.warnings,
      createdAt: compact.createdAt
    )
  }

  fileprivate nonisolated static func validateCompactionAudit(
    status: ConversationCompactionAttemptStatus,
    activeCompactionID: UUID?,
    summaryTextPresent: Bool,
    attemptedSelectionPresent: Bool,
    activeProvenancePresent: Bool,
    inputTokenCount: Int?,
    outputTokenCount: Int?,
    estimatedInputTokensBefore: Int,
    estimatedInputTokensAfter: Int?,
    extraRequestCount: Int
  ) throws {
    let maximumAuditCounter = 1_000_000_000
    guard (0...1).contains(extraRequestCount),
      (0...maximumAuditCounter).contains(estimatedInputTokensBefore),
      estimatedInputTokensAfter.map({ (0...maximumAuditCounter).contains($0) }) ?? true,
      inputTokenCount.map({ (0...maximumAuditCounter).contains($0) }) ?? true,
      outputTokenCount.map({ (0...maximumAuditCounter).contains($0) }) ?? true,
      attemptedSelectionPresent == (extraRequestCount > 0)
    else {
      throw NormalizedContextStoreError.corruptPayload("invalid compaction audit counters")
    }

    let isCompleteActiveSummary =
      activeCompactionID != nil && summaryTextPresent && activeProvenancePresent
    switch status {
    case .generating:
      guard extraRequestCount == 1,
        activeCompactionID == nil,
        !summaryTextPresent,
        !activeProvenancePresent,
        estimatedInputTokensAfter == nil
      else {
        throw NormalizedContextStoreError.corruptPayload("invalid generating compaction audit")
      }
    case .generated:
      guard extraRequestCount == 1, isCompleteActiveSummary else {
        throw NormalizedContextStoreError.corruptPayload("invalid generated compaction audit")
      }
    case .reused:
      guard extraRequestCount == 0, isCompleteActiveSummary else {
        throw NormalizedContextStoreError.corruptPayload("invalid reused compaction audit")
      }
    case .failed, .cancelled:
      if activeCompactionID != nil || summaryTextPresent || activeProvenancePresent {
        guard isCompleteActiveSummary else {
          throw NormalizedContextStoreError.corruptPayload("partial active compaction audit")
        }
      }
    }
  }

  private func projectSnapshot(
    artifact: CompactionArtifactRecord,
    canonicalMessages: [AIChatMessage]
  ) throws -> ConversationCompactionSnapshot {
    try validateIntegrity(artifact)
    guard artifact.isSnapshotComplete,
      let contentData = artifact.contentData,
      let sourceFingerprint = artifact.sourceFingerprint,
      let providerConfigurationID = artifact.providerConfigurationID,
      let providerKindRawValue = artifact.providerKindRawValue,
      let providerKind = ProviderKind(rawValue: providerKindRawValue),
      let providerDisplayName = artifact.providerDisplayName,
      let providerEndpoint = artifact.providerEndpoint,
      let modelIdentifier = artifact.modelIdentifier,
      let mode = ConversationCompactionMode(rawValue: artifact.modeRawValue)
    else {
      throw NormalizedContextStoreError.incompleteCompactionArtifact(artifact.id)
    }
    try validateCompactionLineageMetadata(artifact, mode: mode)
    let content: ConversationCompactionContent
    let warnings: [String]
    do {
      content = try NormalizedContextCodec.decode(
        ConversationCompactionContent.self,
        from: contentData
      )
      warnings = try NormalizedContextCodec.decode([String].self, from: artifact.warningsData)
    } catch {
      throw NormalizedContextStoreError.corruptPayload("compaction artifact payload")
    }
    guard content.schemaVersion == artifact.contentSchemaVersion else {
      throw NormalizedContextStoreError.corruptPayload("compaction content version mismatch")
    }
    let coveredIDs = try resolveCoverage(
      artifact: artifact,
      canonicalMessages: canonicalMessages
    )
    let snapshot = ConversationCompactionSnapshot(
      id: artifact.id,
      conversationID: artifact.conversationID,
      previousCompactionID: artifact.lineagePreviousCompactionID,
      mode: mode,
      promptVersion: artifact.promptVersion,
      content: content,
      coveredMessageIDs: coveredIDs,
      sourceFingerprint: sourceFingerprint,
      providerConfigurationID: providerConfigurationID,
      providerKind: providerKind,
      providerDisplayName: providerDisplayName,
      providerEndpoint: providerEndpoint,
      modelIdentifier: modelIdentifier,
      providerMessageID: artifact.providerMessageID,
      inputTokenCount: artifact.inputTokenCount,
      outputTokenCount: artifact.outputTokenCount,
      estimatedSourceTokens: artifact.estimatedSourceTokens,
      estimatedSummaryTokens: artifact.estimatedSummaryTokens,
      chainDepth: artifact.chainDepth,
      warnings: warnings,
      createdAt: artifact.createdAt
    )
    guard snapshot.renderedSummary == artifact.renderedSummary,
      ConversationCompactionPlanner(contextPolicy: .conservativeDefault).isValid(
        snapshot: snapshot,
        conversationID: artifact.conversationID,
        messages: canonicalMessages
      )
    else {
      throw NormalizedContextStoreError.compactionPrefixMismatch(artifact.id)
    }
    return snapshot
  }

  private func validateCompactionLineageMetadata(
    _ artifact: CompactionArtifactRecord,
    mode: ConversationCompactionMode
  ) throws {
    switch mode {
    case .initial:
      guard artifact.chainDepth == 1,
        artifact.lineagePreviousCompactionID == nil,
        artifact.coverageParentArtifactID == nil,
        !artifact.isDetachedCoverageRoot
      else {
        throw NormalizedContextStoreError.corruptPayload("invalid initial compaction lineage")
      }
    case .rebuild:
      guard artifact.chainDepth == 1,
        artifact.lineagePreviousCompactionID != nil
      else {
        throw NormalizedContextStoreError.corruptPayload("invalid rebuild compaction lineage")
      }
    case .extend:
      if let parentID = artifact.coverageParentArtifactID {
        let parent = try requiredArtifact(id: parentID)
        let (expectedDepth, overflow) = parent.chainDepth.addingReportingOverflow(1)
        guard !overflow, artifact.chainDepth == expectedDepth else {
          throw NormalizedContextStoreError.corruptPayload("invalid extended compaction lineage")
        }
      } else {
        guard artifact.isDetachedCoverageRoot, artifact.chainDepth >= 2 else {
          throw NormalizedContextStoreError.corruptPayload("invalid detached compaction lineage")
        }
      }
    }
  }

  private func resolveCoverage(
    artifact: CompactionArtifactRecord,
    canonicalMessages: [AIChatMessage]
  ) throws -> [UUID] {
    var chain: [CompactionArtifactRecord] = []
    var visited: Set<UUID> = []
    var cursor: CompactionArtifactRecord? = artifact

    while let current = cursor {
      guard visited.insert(current.id).inserted else {
        throw NormalizedContextStoreError.compactionArtifactCycle(current.id)
      }
      guard current.conversationID == artifact.conversationID else {
        throw NormalizedContextStoreError.compactionConversationMismatch(current.id)
      }
      try validateIntegrity(current)
      chain.append(current)
      if let parentID = current.coverageParentArtifactID {
        cursor = try requiredArtifact(id: parentID)
      } else {
        cursor = nil
      }
      guard chain.count <= Self.maximumCompactionCoverageDepth else {
        throw NormalizedContextStoreError.compactionArtifactCycle(current.id)
      }
    }

    let canonicalIDs = canonicalMessages.map(\.id)
    var coverage: [UUID] = []
    var seenMessageIDs: Set<UUID> = []
    for current in chain.reversed() {
      let delta: [UUID]
      do {
        delta = try NormalizedContextCodec.decode(
          [UUID].self,
          from: current.coverageDeltaData
        )
      } catch {
        throw NormalizedContextStoreError.corruptPayload("compaction coverage delta")
      }
      let start = coverage.count
      guard start <= canonicalIDs.count,
        delta.count <= canonicalIDs.count - start
      else {
        throw NormalizedContextStoreError.compactionCountMismatch(current.id)
      }
      let end = start + delta.count
      guard end == current.coveredMessageCount, end <= canonicalIDs.count else {
        throw NormalizedContextStoreError.compactionCountMismatch(current.id)
      }
      guard Array(canonicalIDs[start..<end]) == delta,
        delta.allSatisfy({ seenMessageIDs.insert($0).inserted })
      else {
        throw NormalizedContextStoreError.compactionPrefixMismatch(current.id)
      }
      coverage.append(contentsOf: delta)
    }
    return coverage
  }

  private func validateArtifact(
    _ artifact: CompactionArtifactRecord,
    against receipt: ConversationCompactionReceipt,
    canonicalMessages: [AIChatMessage]
  ) throws {
    try validateIntegrity(artifact)
    let coverage = try resolveCoverage(
      artifact: artifact,
      canonicalMessages: canonicalMessages
    )
    guard artifact.id == receipt.compactionID,
      artifact.renderedSummary == receipt.summaryText,
      coverage == receipt.coveredMessageIDs,
      artifact.providerConfigurationID == receipt.activeSummaryProviderConfigurationID,
      artifact.providerKindRawValue == receipt.activeSummaryProviderKind?.rawValue,
      artifact.providerDisplayName == receipt.activeSummaryProviderDisplayName,
      artifact.providerEndpoint == receipt.activeSummaryProviderEndpoint,
      artifact.modelIdentifier == receipt.activeSummaryModelIdentifier,
      artifact.createdAt == receipt.activeSummaryCreatedAt
    else {
      throw NormalizedContextStoreError.compactionArtifactConflict(artifact.id)
    }
  }

  private func validateIntegrity(_ artifact: CompactionArtifactRecord) throws {
    let envelope = try integrityEnvelope(for: artifact)
    let fingerprint = NormalizedContextCodec.fingerprint(
      try NormalizedContextCodec.encode(envelope)
    )
    guard fingerprint == artifact.payloadFingerprint else {
      throw NormalizedContextStoreError.corruptPayload(
        "compaction artifact \(artifact.id.uuidString) fingerprint mismatch"
      )
    }
  }

  private func integrityEnvelope(
    for artifact: CompactionArtifactRecord
  ) throws -> CompactionArtifactIntegrityEnvelope {
    CompactionArtifactIntegrityEnvelope(
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
  }

  private func canonicalSource(
    _ canonicalMessages: [AIChatMessage],
    through sourceThroughMessageID: UUID,
    count: Int
  ) throws -> [AIChatMessage] {
    guard count > 0 else { throw NormalizedContextStoreError.emptyCanonicalSource }
    guard canonicalMessages.count >= count else {
      throw NormalizedContextStoreError.sourceCountMismatch(
        expected: count,
        actual: canonicalMessages.count
      )
    }
    let source = Array(canonicalMessages.prefix(count))
    guard source.last?.id == sourceThroughMessageID else {
      throw NormalizedContextStoreError.sourceBoundaryMismatch
    }
    var seen: Set<UUID> = []
    for message in source where !seen.insert(message.id).inserted {
      throw NormalizedContextStoreError.duplicateCanonicalMessageID(message.id)
    }
    return source
  }

  fileprivate nonisolated static func compactSelection(
    _ selectedIDs: [UUID],
    in canonicalIDs: [UUID],
    label: String
  ) throws -> CompactMessageSelection {
    guard !selectedIDs.isEmpty else {
      return CompactMessageSelection(startOffset: 0, count: 0)
    }
    guard let start = canonicalIDs.firstIndex(of: selectedIDs[0]),
      start + selectedIDs.count <= canonicalIDs.count,
      Array(canonicalIDs[start..<(start + selectedIDs.count)]) == selectedIDs
    else {
      throw NormalizedContextStoreError.nonContiguousSelection(label)
    }
    return CompactMessageSelection(startOffset: start, count: selectedIDs.count)
  }

  private func projectSelection(
    _ selection: CompactMessageSelection,
    from canonicalIDs: [UUID]
  ) throws -> [UUID] {
    guard selection.startOffset >= 0, selection.count >= 0,
      selection.startOffset <= canonicalIDs.count,
      selection.count <= canonicalIDs.count - selection.startOffset
    else {
      throw NormalizedContextStoreError.corruptPayload("message selection bounds")
    }
    return Array(
      canonicalIDs[
        selection.startOffset..<(selection.startOffset + selection.count)
      ]
    )
  }

  private func event(key: String) throws -> RequestContextEventRecord? {
    var descriptor = FetchDescriptor<RequestContextEventRecord>(
      predicate: #Predicate { $0.eventKey == key }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func latestEvent(assistantMessageID: UUID) throws -> RequestContextEventRecord? {
    let descriptor = FetchDescriptor<RequestContextEventRecord>(
      predicate: #Predicate { $0.assistantMessageID == assistantMessageID },
      sortBy: [
        SortDescriptor(\RequestContextEventRecord.eventSequence, order: .reverse),
        SortDescriptor(\RequestContextEventRecord.createdAt, order: .reverse),
      ]
    )
    return try modelContext.fetch(descriptor).first
  }

  private func artifact(id: UUID) throws -> CompactionArtifactRecord? {
    var descriptor = FetchDescriptor<CompactionArtifactRecord>(
      predicate: #Predicate { $0.id == id }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func requiredArtifact(id: UUID) throws -> CompactionArtifactRecord {
    guard let result = try artifact(id: id) else {
      throw NormalizedContextStoreError.missingCompactionArtifact(id)
    }
    return result
  }

  private func compactionHead(
    conversationID: UUID
  ) throws -> ConversationCompactionHeadRecord? {
    var descriptor = FetchDescriptor<ConversationCompactionHeadRecord>(
      predicate: #Predicate { $0.conversationID == conversationID }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func backfillProgress(
    migrationKey: String,
    createIfMissing: Bool,
    at date: Date
  ) throws -> NormalizedContextBackfillProgressRecord {
    var descriptor = FetchDescriptor<NormalizedContextBackfillProgressRecord>(
      predicate: #Predicate { $0.migrationKey == migrationKey }
    )
    descriptor.fetchLimit = 1
    if let existing = try modelContext.fetch(descriptor).first { return existing }
    guard createIfMissing else {
      throw NormalizedContextStoreError.corruptPayload("missing backfill checkpoint")
    }
    let progress = NormalizedContextBackfillProgressRecord(
      migrationKey: migrationKey,
      updatedAt: date
    )
    modelContext.insert(progress)
    return progress
  }
}

private struct NormalizedRequestPayload: Hashable, Codable, Sendable {
  let schemaVersion: Int
  let curatedContext: MemoryContext
  let retrievedContext: RetrievedContext
  let projectContext: ProjectContextReceipt?
  let conversationContext: CompactConversationContext?
  let sameConversationRecall: SameConversationRecallReceipt?
  let conversationCompaction: CompactCompactionReceipt?
  let receiptCreatedAt: Date
}

private struct CompactConversationContext: Hashable, Codable, Sendable {
  let strategy: ConversationContextStrategy
  let rawIncludedMessageCount: Int
  let summarizedFieldPresent: Bool
  let recalledMessageIDs: [UUID]?
  let activeCompactionID: UUID?
  let estimatedInputTokens: Int
  let contextWindowTokens: Int
  let maximumOutputTokens: Int
  let safetyMarginTokens: Int
  let warnings: [String]
}

private struct CompactMessageSelection: Hashable, Codable, Sendable {
  let startOffset: Int
  let count: Int
}

private struct CompactCompactionReceipt: Hashable, Codable, Sendable {
  let attemptID: UUID
  let status: ConversationCompactionAttemptStatus
  let activeCompactionID: UUID?
  let summaryTextPresent: Bool
  let attemptedSelection: CompactMessageSelection?
  let activeProvenancePresent: Bool
  let providerConfigurationID: UUID
  let providerKind: ProviderKind
  let providerDisplayName: String
  let providerEndpoint: String
  let modelIdentifier: String
  let providerMessageID: String?
  let inputTokenCount: Int?
  let outputTokenCount: Int?
  let estimatedInputTokensBefore: Int
  let estimatedInputTokensAfter: Int?
  let extraRequestCount: Int
  let errorDescription: String?
  let warnings: [String]
  let createdAt: Date
}

private struct CompactionArtifactIntegrityEnvelope: Hashable, Codable, Sendable {
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

private enum NormalizedContextCodec {
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    return try decoder.decode(type, from: data)
  }

  static func fingerprint(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func deterministicUUID(_ key: String) -> UUID {
    let bytes = Array(SHA256.hash(data: Data(key.utf8)))
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      )
    )
  }
}

#if DEBUG
  /// Keeps corruption construction out of the production API while allowing fail-closed chain
  /// tests to persist byte-integrity-valid but structurally invalid records.
  enum NormalizedContextStoreTestSupport {
    static func artifact(
      id: UUID,
      conversationID: UUID,
      coverageParentArtifactID: UUID?,
      coverageDelta: [UUID],
      coveredMessageCount: Int,
      renderedSummary: String = "Test summary",
      providerConfigurationID: UUID = UUID(
        uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      )!,
      modelIdentifier: String? = "test-model",
      createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> CompactionArtifactRecord {
      let deltaData = try NormalizedContextCodec.encode(coverageDelta)
      let warningsData = try NormalizedContextCodec.encode([String]())
      let envelope = CompactionArtifactIntegrityEnvelope(
        id: id,
        conversationID: conversationID,
        lineagePreviousCompactionID: coverageParentArtifactID,
        coverageParentArtifactID: coverageParentArtifactID,
        coverageDeltaData: deltaData,
        coveredMessageCount: coveredMessageCount,
        modeRawValue: ConversationCompactionMode.initial.rawValue,
        promptVersion: ConversationCompactionPrompt.version,
        contentSchemaVersion: ConversationCompactionContent.currentSchemaVersion,
        contentData: nil,
        renderedSummary: renderedSummary,
        sourceFingerprint: nil,
        providerConfigurationID: providerConfigurationID,
        providerKindRawValue: ProviderKind.openAI.rawValue,
        providerDisplayName: "OpenAI",
        providerEndpoint: "https://api.openai.com:443/v1",
        modelIdentifier: modelIdentifier,
        providerMessageID: nil,
        inputTokenCount: nil,
        outputTokenCount: nil,
        estimatedSourceTokens: 0,
        estimatedSummaryTokens: 0,
        chainDepth: 1,
        warningsData: warningsData,
        isSnapshotComplete: false,
        isDetachedCoverageRoot: false,
        createdAt: createdAt
      )
      let fingerprint = NormalizedContextCodec.fingerprint(
        try NormalizedContextCodec.encode(envelope)
      )
      return CompactionArtifactRecord(
        id: envelope.id,
        conversationID: envelope.conversationID,
        lineagePreviousCompactionID: envelope.lineagePreviousCompactionID,
        coverageParentArtifactID: envelope.coverageParentArtifactID,
        coverageDeltaData: envelope.coverageDeltaData,
        coveredMessageCount: envelope.coveredMessageCount,
        modeRawValue: envelope.modeRawValue,
        promptVersion: envelope.promptVersion,
        contentSchemaVersion: envelope.contentSchemaVersion,
        contentData: envelope.contentData,
        renderedSummary: envelope.renderedSummary,
        sourceFingerprint: envelope.sourceFingerprint,
        providerConfigurationID: envelope.providerConfigurationID,
        providerKindRawValue: envelope.providerKindRawValue,
        providerDisplayName: envelope.providerDisplayName,
        providerEndpoint: envelope.providerEndpoint,
        modelIdentifier: envelope.modelIdentifier,
        providerMessageID: envelope.providerMessageID,
        inputTokenCount: envelope.inputTokenCount,
        outputTokenCount: envelope.outputTokenCount,
        estimatedSourceTokens: envelope.estimatedSourceTokens,
        estimatedSummaryTokens: envelope.estimatedSummaryTokens,
        chainDepth: envelope.chainDepth,
        warningsData: envelope.warningsData,
        isSnapshotComplete: envelope.isSnapshotComplete,
        isDetachedCoverageRoot: envelope.isDetachedCoverageRoot,
        payloadFingerprint: fingerprint,
        createdAt: envelope.createdAt
      )
    }
  }
#endif

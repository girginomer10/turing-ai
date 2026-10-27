import Foundation
import SwiftData

/// A consolidated, current fact learned from one or more user messages. Raw messages remain the
/// source of truth; this table is the compact, queryable head used for cross-chat recall.
@Model
public final class MemoryTopicRecord {
  @Attribute(.unique) public private(set) var id: UUID
  @Attribute(.unique) public private(set) var canonicalKey: String
  public private(set) var title: String
  public private(set) var content: String
  public private(set) var kindRawValue: String
  public private(set) var scopeRawValue: String
  public private(set) var conversationID: UUID?
  public private(set) var statusRawValue: String
  public private(set) var originRawValue: String
  public private(set) var confidence: Double
  public private(set) var importance: Double
  public private(set) var stabilityRawValue: String
  public private(set) var isEnabled: Bool
  public private(set) var lastConfirmedAt: Date
  public private(set) var lastUsedAt: Date?
  public private(set) var useCount: Int
  public private(set) var evidenceCount: Int
  public private(set) var revision: Int
  public private(set) var createdAt: Date
  public private(set) var updatedAt: Date

  public init(
    id: UUID = UUID(),
    canonicalKey: String,
    title: String,
    content: String,
    kind: MemoryTopicKind,
    scope: MemoryScope,
    conversationID: UUID?,
    status: MemoryTopicStatus = .active,
    origin: MemoryOrigin = .automatic,
    confidence: Double,
    importance: Double,
    stability: MemoryStability,
    isEnabled: Bool = true,
    lastConfirmedAt: Date = .now,
    lastUsedAt: Date? = nil,
    useCount: Int = 0,
    evidenceCount: Int = 0,
    revision: Int = 1,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.canonicalKey = canonicalKey
    self.title = title
    self.content = content
    self.kindRawValue = kind.rawValue
    self.scopeRawValue = scope.rawValue
    self.conversationID = conversationID
    self.statusRawValue = status.rawValue
    self.originRawValue = origin.rawValue
    self.confidence = confidence
    self.importance = importance
    self.stabilityRawValue = stability.rawValue
    self.isEnabled = isEnabled
    self.lastConfirmedAt = lastConfirmedAt
    self.lastUsedAt = lastUsedAt
    self.useCount = useCount
    self.evidenceCount = evidenceCount
    self.revision = revision
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var kind: MemoryTopicKind {
    MemoryTopicKind(rawValue: kindRawValue) ?? .fact
  }

  public var scope: MemoryScope {
    MemoryScope(rawValue: scopeRawValue) ?? .global
  }

  public var status: MemoryTopicStatus {
    MemoryTopicStatus(rawValue: statusRawValue) ?? .forgotten
  }

  public var origin: MemoryOrigin {
    MemoryOrigin(rawValue: originRawValue) ?? .automatic
  }

  public var stability: MemoryStability {
    MemoryStability(rawValue: stabilityRawValue) ?? .evolving
  }

  public var snapshot: AutomaticMemoryTopicSnapshot {
    snapshot(projectID: nil)
  }

  public func snapshot(projectID: UUID?) -> AutomaticMemoryTopicSnapshot {
    AutomaticMemoryTopicSnapshot(
      id: id,
      canonicalKey: canonicalKey,
      title: title,
      content: content,
      kind: kind,
      scope: scope,
      conversationID: conversationID,
      projectID: projectID,
      status: status,
      origin: origin,
      confidence: confidence,
      importance: importance,
      stability: stability,
      isEnabled: isEnabled,
      lastConfirmedAt: lastConfirmedAt,
      lastUsedAt: lastUsedAt,
      useCount: useCount,
      evidenceCount: evidenceCount,
      revision: revision,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }

  func apply(
    title: String,
    content: String,
    confidence: Double,
    importance: Double,
    stability: MemoryStability,
    status: MemoryTopicStatus,
    isEnabled: Bool,
    evidenceCount: Int,
    revision: Int,
    at date: Date
  ) {
    self.title = title
    self.content = content
    self.confidence = confidence
    self.importance = importance
    stabilityRawValue = stability.rawValue
    statusRawValue = status.rawValue
    self.isEnabled = isEnabled
    self.evidenceCount = evidenceCount
    self.revision = revision
    lastConfirmedAt = date
    updatedAt = date
  }

  func setEventReportDate(_ date: Date) {
    guard kind == .event else { return }
    lastConfirmedAt = min(date, updatedAt)
  }

  func setOrigin(_ origin: MemoryOrigin) {
    originRawValue = origin.rawValue
  }

  /// Narrows or moves an automatically learned topic when its source conversation changes
  /// audience. The semantic head and revision chain stay intact because only routing changes.
  func reassignAutomaticAudience(
    canonicalKey: String,
    scope: MemoryScope,
    conversationID: UUID?,
    at date: Date
  ) {
    self.canonicalKey = canonicalKey
    scopeRawValue = scope.rawValue
    self.conversationID = conversationID
    updatedAt = date
  }

  func setEnabled(_ enabled: Bool, revision: Int, at date: Date) {
    isEnabled = enabled
    self.revision = revision
    updatedAt = date
  }

  func recordUse(at date: Date) {
    guard useCount < Int.max else { return }
    useCount += 1
    lastUsedAt = date
  }

  /// Reconciles provenance after a source conversation is removed without pretending the
  /// remaining fact was newly confirmed or creating a semantic revision for an unchanged value.
  func reconcileEvidenceCount(_ evidenceCount: Int, at date: Date) {
    self.evidenceCount = evidenceCount
    updatedAt = date
  }

  /// Removes an unsupported automatic head without pretending the deletion reconfirmed it.
  func markForgottenAfterEvidenceRemoval(
    revision: Int, remainingEvidenceCount: Int, at date: Date
  ) {
    statusRawValue = MemoryTopicStatus.forgotten.rawValue
    isEnabled = false
    evidenceCount = remainingEvidenceCount
    self.revision = revision
    updatedAt = date
  }
}

/// Immutable evidence tying one consolidated topic back to an exact user message.
@Model
public final class MemoryEvidenceRecord {
  @Attribute(.unique) public private(set) var id: UUID
  @Attribute(.unique) public private(set) var evidenceKey: String
  public private(set) var topicID: UUID
  public private(set) var conversationID: UUID
  public private(set) var sourceMessageID: UUID
  public private(set) var assistantMessageID: UUID?
  public private(set) var excerpt: String
  public private(set) var sourceFingerprint: String
  public private(set) var providerConfigurationID: UUID?
  public private(set) var providerKindRawValue: String?
  public private(set) var providerDisplayName: String?
  public private(set) var modelIdentifier: String?
  public private(set) var providerEndpoint: String?
  public private(set) var confidence: Double
  public private(set) var createdAt: Date

  public init(
    id: UUID = UUID(),
    evidenceKey: String,
    topicID: UUID,
    conversationID: UUID,
    sourceMessageID: UUID,
    assistantMessageID: UUID?,
    excerpt: String,
    sourceFingerprint: String,
    providerConfigurationID: UUID?,
    providerKind: ProviderKind?,
    providerDisplayName: String?,
    modelIdentifier: String?,
    providerEndpoint: String? = nil,
    confidence: Double,
    createdAt: Date = .now
  ) {
    self.id = id
    self.evidenceKey = evidenceKey
    self.topicID = topicID
    self.conversationID = conversationID
    self.sourceMessageID = sourceMessageID
    self.assistantMessageID = assistantMessageID
    self.excerpt = excerpt
    self.sourceFingerprint = sourceFingerprint
    self.providerConfigurationID = providerConfigurationID
    self.providerKindRawValue = providerKind?.rawValue
    self.providerDisplayName = providerDisplayName
    self.modelIdentifier = modelIdentifier
    self.providerEndpoint = providerEndpoint
    self.confidence = confidence
    self.createdAt = createdAt
  }

  public var snapshot: AutomaticMemoryEvidenceSnapshot {
    AutomaticMemoryEvidenceSnapshot(
      id: id,
      topicID: topicID,
      conversationID: conversationID,
      sourceMessageID: sourceMessageID,
      assistantMessageID: assistantMessageID,
      excerpt: excerpt,
      sourceFingerprint: sourceFingerprint,
      providerConfigurationID: providerConfigurationID,
      providerKind: providerKindRawValue.flatMap(ProviderKind.init(rawValue:)),
      providerDisplayName: providerDisplayName,
      modelIdentifier: modelIdentifier,
      providerEndpoint: providerEndpoint,
      confidence: confidence,
      createdAt: createdAt
    )
  }
}

/// Immutable before/after audit entry for corrections, reinforcement, and forgetting.
@Model
public final class MemoryRevisionRecord {
  @Attribute(.unique) public private(set) var id: UUID
  @Attribute(.unique) public private(set) var revisionKey: String
  public private(set) var topicID: UUID
  public private(set) var sequence: Int
  public private(set) var kindRawValue: String
  public private(set) var previousTitle: String?
  public private(set) var previousContent: String?
  public private(set) var title: String
  public private(set) var content: String
  public private(set) var sourceEvidenceID: UUID?
  public private(set) var createdAt: Date

  public init(
    id: UUID = UUID(),
    revisionKey: String,
    topicID: UUID,
    sequence: Int,
    kind: MemoryRevisionKind,
    previousTitle: String?,
    previousContent: String?,
    title: String,
    content: String,
    sourceEvidenceID: UUID?,
    createdAt: Date = .now
  ) {
    self.id = id
    self.revisionKey = revisionKey
    self.topicID = topicID
    self.sequence = sequence
    self.kindRawValue = kind.rawValue
    self.previousTitle = previousTitle
    self.previousContent = previousContent
    self.title = title
    self.content = content
    self.sourceEvidenceID = sourceEvidenceID
    self.createdAt = createdAt
  }

  public var snapshot: AutomaticMemoryRevisionSnapshot {
    AutomaticMemoryRevisionSnapshot(
      id: id,
      topicID: topicID,
      sequence: sequence,
      kind: MemoryRevisionKind(rawValue: kindRawValue) ?? .updated,
      previousTitle: previousTitle,
      previousContent: previousContent,
      title: title,
      content: content,
      sourceEvidenceID: sourceEvidenceID,
      createdAt: createdAt
    )
  }

  /// A conversation deletion removes its copied evidence excerpt. The semantic before/after audit
  /// remains useful, but its now-dangling evidence pointer must be detached transactionally.
  func detachSourceEvidence() {
    sourceEvidenceID = nil
  }
}

/// Durable, idempotent work item. A provider failure never changes the successful chat response.
@Model
public final class MemoryFormationJobRecord {
  @Attribute(.unique) public private(set) var id: UUID
  @Attribute(.unique) public private(set) var jobKey: String
  public private(set) var conversationID: UUID
  public private(set) var throughUserMessageID: UUID
  public private(set) var assistantMessageID: UUID
  public private(set) var sourceFingerprint: String
  public private(set) var promptVersion: String
  public private(set) var statusRawValue: String
  public private(set) var attemptCount: Int
  public private(set) var providerConfigurationID: UUID?
  public private(set) var providerKindRawValue: String?
  public private(set) var providerDisplayName: String?
  public private(set) var modelIdentifier: String?
  public private(set) var providerEndpoint: String?
  public private(set) var outputFingerprint: String?
  public private(set) var lastError: String?
  public private(set) var startedAt: Date?
  public private(set) var completedAt: Date?
  public private(set) var createdAt: Date
  public private(set) var updatedAt: Date

  public init(
    id: UUID = UUID(),
    jobKey: String,
    conversationID: UUID,
    throughUserMessageID: UUID,
    assistantMessageID: UUID,
    sourceFingerprint: String,
    promptVersion: String,
    status: MemoryFormationJobStatus = .pending,
    attemptCount: Int = 0,
    providerConfigurationID: UUID? = nil,
    providerKind: ProviderKind? = nil,
    providerDisplayName: String? = nil,
    modelIdentifier: String? = nil,
    providerEndpoint: String? = nil,
    outputFingerprint: String? = nil,
    lastError: String? = nil,
    startedAt: Date? = nil,
    completedAt: Date? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.jobKey = jobKey
    self.conversationID = conversationID
    self.throughUserMessageID = throughUserMessageID
    self.assistantMessageID = assistantMessageID
    self.sourceFingerprint = sourceFingerprint
    self.promptVersion = promptVersion
    self.statusRawValue = status.rawValue
    self.attemptCount = attemptCount
    self.providerConfigurationID = providerConfigurationID
    self.providerKindRawValue = providerKind?.rawValue
    self.providerDisplayName = providerDisplayName
    self.modelIdentifier = modelIdentifier
    self.providerEndpoint = providerEndpoint
    self.outputFingerprint = outputFingerprint
    self.lastError = lastError
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var status: MemoryFormationJobStatus {
    MemoryFormationJobStatus(rawValue: statusRawValue) ?? .failed
  }

  func markGenerating(provider: ProviderConnection, at date: Date) {
    statusRawValue = MemoryFormationJobStatus.generating.rawValue
    if attemptCount < Int.max { attemptCount += 1 }
    providerConfigurationID = provider.id
    providerKindRawValue = provider.provider.rawValue
    providerDisplayName = provider.displayName
    modelIdentifier = provider.modelIdentifier
    providerEndpoint = provider.credentialBinding.endpoint
    lastError = nil
    startedAt = date
    completedAt = nil
    updatedAt = date
  }

  /// Narrows `startedAt` from local preparation time to the durable provider-request boundary.
  /// This is called only after the request has been built and immediately before its stream opens.
  func markRequestOpened(at date: Date) {
    startedAt = date
    updatedAt = date
  }

  func markComplete(outputFingerprint: String, at date: Date) {
    statusRawValue = MemoryFormationJobStatus.complete.rawValue
    self.outputFingerprint = outputFingerprint
    lastError = nil
    completedAt = date
    updatedAt = date
  }

  func markFailed(_ error: String, at date: Date) {
    statusRawValue = MemoryFormationJobStatus.failed.rawValue
    lastError = error
    completedAt = nil
    updatedAt = date
  }

  func markRejected(_ error: String, at date: Date) {
    statusRawValue = MemoryFormationJobStatus.rejected.rawValue
    lastError = error
    completedAt = nil
    updatedAt = date
  }
}

/// The durable provider/cost receipt for the latest attempt of a formation job. This is a separate
/// V4 table so the already-shipped V3 formation-job entity remains byte-for-byte frozen.
@Model
public final class MemoryFormationAuditRecord {
  @Attribute(.unique) public private(set) var id: UUID
  @Attribute(.unique) public private(set) var jobID: UUID
  @Attribute(.unique) public private(set) var jobKey: String
  public private(set) var attemptCount: Int
  public private(set) var outcomeRawValue: String
  public private(set) var providerConfigurationID: UUID?
  public private(set) var providerKindRawValue: String?
  public private(set) var providerDisplayName: String?
  public private(set) var modelIdentifier: String?
  public private(set) var providerEndpoint: String?
  public private(set) var providerMessageID: String?
  public private(set) var requestStarted: Bool
  public private(set) var inputTokenCount: Int?
  public private(set) var outputTokenCount: Int?
  public private(set) var providerRequestCount: Int
  public private(set) var cumulativeInputTokenCount: Int
  public private(set) var cumulativeOutputTokenCount: Int
  public private(set) var didDiscardInvalidTelemetry: Bool
  public private(set) var errorDescription: String?
  public private(set) var startedAt: Date?
  public private(set) var finishedAt: Date
  public private(set) var createdAt: Date
  public private(set) var updatedAt: Date

  public init(
    id: UUID = UUID(),
    jobID: UUID,
    jobKey: String,
    attemptCount: Int,
    outcome: MemoryFormationJobStatus,
    providerConfigurationID: UUID?,
    providerKind: ProviderKind?,
    providerDisplayName: String?,
    modelIdentifier: String?,
    providerEndpoint: String?,
    providerMessageID: String?,
    requestStarted: Bool,
    inputTokenCount: Int?,
    outputTokenCount: Int?,
    providerRequestCount: Int,
    cumulativeInputTokenCount: Int,
    cumulativeOutputTokenCount: Int,
    didDiscardInvalidTelemetry: Bool,
    errorDescription: String?,
    startedAt: Date?,
    finishedAt: Date,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.jobID = jobID
    self.jobKey = jobKey
    self.attemptCount = attemptCount
    self.outcomeRawValue = outcome.rawValue
    self.providerConfigurationID = providerConfigurationID
    self.providerKindRawValue = providerKind?.rawValue
    self.providerDisplayName = providerDisplayName
    self.modelIdentifier = modelIdentifier
    self.providerEndpoint = providerEndpoint
    self.providerMessageID = providerMessageID
    self.requestStarted = requestStarted
    self.inputTokenCount = inputTokenCount
    self.outputTokenCount = outputTokenCount
    self.providerRequestCount = providerRequestCount
    self.cumulativeInputTokenCount = cumulativeInputTokenCount
    self.cumulativeOutputTokenCount = cumulativeOutputTokenCount
    self.didDiscardInvalidTelemetry = didDiscardInvalidTelemetry
    self.errorDescription = errorDescription
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var outcome: MemoryFormationJobStatus {
    MemoryFormationJobStatus(rawValue: outcomeRawValue) ?? .failed
  }

  public var snapshot: AutomaticMemoryFormationAuditSnapshot {
    AutomaticMemoryFormationAuditSnapshot(
      id: id,
      jobID: jobID,
      jobKey: jobKey,
      attemptCount: attemptCount,
      outcome: outcome,
      providerConfigurationID: providerConfigurationID,
      providerKind: providerKindRawValue.flatMap(ProviderKind.init(rawValue:)),
      providerDisplayName: providerDisplayName,
      modelIdentifier: modelIdentifier,
      providerEndpoint: providerEndpoint,
      providerMessageID: providerMessageID,
      requestStarted: requestStarted,
      inputTokenCount: inputTokenCount,
      outputTokenCount: outputTokenCount,
      providerRequestCount: providerRequestCount,
      cumulativeInputTokenCount: cumulativeInputTokenCount,
      cumulativeOutputTokenCount: cumulativeOutputTokenCount,
      didDiscardInvalidTelemetry: didDiscardInvalidTelemetry,
      errorDescription: errorDescription,
      startedAt: startedAt,
      finishedAt: finishedAt,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }

  func replace(
    attemptCount: Int,
    outcome: MemoryFormationJobStatus,
    providerConfigurationID: UUID?,
    providerKind: ProviderKind?,
    providerDisplayName: String?,
    modelIdentifier: String?,
    providerEndpoint: String?,
    providerMessageID: String?,
    requestStarted: Bool,
    inputTokenCount: Int?,
    outputTokenCount: Int?,
    providerRequestCount: Int,
    cumulativeInputTokenCount: Int,
    cumulativeOutputTokenCount: Int,
    didDiscardInvalidTelemetry: Bool,
    errorDescription: String?,
    startedAt: Date?,
    finishedAt: Date
  ) {
    self.attemptCount = attemptCount
    outcomeRawValue = outcome.rawValue
    self.providerConfigurationID = providerConfigurationID
    providerKindRawValue = providerKind?.rawValue
    self.providerDisplayName = providerDisplayName
    self.modelIdentifier = modelIdentifier
    self.providerEndpoint = providerEndpoint
    self.providerMessageID = providerMessageID
    self.requestStarted = requestStarted
    self.inputTokenCount = inputTokenCount
    self.outputTokenCount = outputTokenCount
    self.providerRequestCount = providerRequestCount
    self.cumulativeInputTokenCount = cumulativeInputTokenCount
    self.cumulativeOutputTokenCount = cumulativeOutputTokenCount
    self.didDiscardInvalidTelemetry = didDiscardInvalidTelemetry
    self.errorDescription = errorDescription
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    updatedAt = finishedAt
  }
}

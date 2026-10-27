import Foundation

public enum AutomaticMemorySettings {
  public static let enabledKey = "com.omergirgin.mosaic.automaticMemoryEnabled"
}

/// A small, provider-independent taxonomy used to keep learned facts atomic and mergeable.
public enum MemoryTopicKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case event
  case identity
  case preference
  case relationship
  case project
  case goal
  case constraint
  case workflow
  case fact

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .event: "Recent event"
    case .identity: "Identity"
    case .preference: "Preference"
    case .relationship: "People"
    case .project: "Project"
    case .goal: "Goal"
    case .constraint: "Constraint"
    case .workflow: "Workflow"
    case .fact: "Fact"
    }
  }

  public var systemImage: String {
    switch self {
    case .event: "clock"
    case .identity: "person.text.rectangle"
    case .preference: "slider.horizontal.3"
    case .relationship: "person.2"
    case .project: "folder"
    case .goal: "target"
    case .constraint: "exclamationmark.shield"
    case .workflow: "arrow.triangle.branch"
    case .fact: "lightbulb"
    }
  }
}

public enum MemoryTopicStatus: String, Codable, CaseIterable, Sendable {
  case active
  case forgotten
}

public enum MemoryOrigin: String, Codable, CaseIterable, Sendable {
  case automatic
  case manual
}

/// How quickly a learned value is expected to change. This affects ranking, never truth.
public enum MemoryStability: String, Codable, CaseIterable, Sendable {
  case evolving
  case stable
  case permanent
}

public enum MemoryRevisionKind: String, Codable, CaseIterable, Sendable {
  case created
  case reinforced
  case updated
  case forgotten
  case reactivated
  case userEdited = "user_edited"
  case userDisabled = "user_disabled"
  case userEnabled = "user_enabled"
}

public enum MemoryFormationJobStatus: String, Codable, CaseIterable, Sendable {
  case pending
  case generating
  case complete
  case failed
  /// Local source or record state makes this exact job impossible to complete by rerunning it.
  /// Provider-output validation failures remain retryable because a new generation can differ.
  case rejected
}

/// A bounded, provider-neutral receipt for the most recent attempt of one durable formation job.
/// The job keeps scheduling state; this snapshot keeps the provider response and token audit that
/// would otherwise be lost after a process restart or failed extraction.
public struct AutomaticMemoryFormationAuditSnapshot: Identifiable, Hashable, Sendable {
  public let id: UUID
  public let jobID: UUID
  public let jobKey: String
  public let attemptCount: Int
  public let outcome: MemoryFormationJobStatus
  public let providerConfigurationID: UUID?
  public let providerKind: ProviderKind?
  public let providerDisplayName: String?
  public let modelIdentifier: String?
  public let providerEndpoint: String?
  public let providerMessageID: String?
  public let requestStarted: Bool
  public let inputTokenCount: Int?
  public let outputTokenCount: Int?
  public let providerRequestCount: Int
  public let cumulativeInputTokenCount: Int
  public let cumulativeOutputTokenCount: Int
  public let didDiscardInvalidTelemetry: Bool
  public let errorDescription: String?
  public let startedAt: Date?
  public let finishedAt: Date
  public let createdAt: Date
  public let updatedAt: Date

  public var totalTokenCount: Int? {
    guard inputTokenCount != nil || outputTokenCount != nil else { return nil }
    let input = inputTokenCount ?? 0
    let output = outputTokenCount ?? 0
    let (total, overflow) = input.addingReportingOverflow(output)
    return overflow ? nil : total
  }

  public var duration: TimeInterval? {
    startedAt.map { max(0, finishedAt.timeIntervalSince($0)) }
  }

  public var cumulativeTotalTokenCount: Int? {
    let (total, overflow) = cumulativeInputTokenCount.addingReportingOverflow(
      cumulativeOutputTokenCount
    )
    return overflow ? nil : total
  }

  public init(
    id: UUID,
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
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.jobID = jobID
    self.jobKey = jobKey
    self.attemptCount = attemptCount
    self.outcome = outcome
    self.providerConfigurationID = providerConfigurationID
    self.providerKind = providerKind
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
}

public struct AutomaticMemoryTopicSnapshot: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let canonicalKey: String
  public let title: String
  public let content: String
  public let kind: MemoryTopicKind
  public let scope: MemoryScope
  public let conversationID: UUID?
  /// Additive sidecar scope resolved at read time. It is never stored on the V3 topic model.
  public let projectID: UUID?
  public let status: MemoryTopicStatus
  public let origin: MemoryOrigin
  public let confidence: Double
  public let importance: Double
  public let stability: MemoryStability
  public let isEnabled: Bool
  public let lastConfirmedAt: Date
  public let lastUsedAt: Date?
  public let useCount: Int
  public let evidenceCount: Int
  public let revision: Int
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: UUID,
    canonicalKey: String,
    title: String,
    content: String,
    kind: MemoryTopicKind,
    scope: MemoryScope,
    conversationID: UUID?,
    projectID: UUID? = nil,
    status: MemoryTopicStatus,
    origin: MemoryOrigin,
    confidence: Double,
    importance: Double,
    stability: MemoryStability,
    isEnabled: Bool,
    lastConfirmedAt: Date,
    lastUsedAt: Date?,
    useCount: Int,
    evidenceCount: Int,
    revision: Int,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.canonicalKey = canonicalKey
    self.title = title
    self.content = content
    self.kind = kind
    self.scope = scope
    self.conversationID = conversationID
    self.projectID = projectID
    self.status = status
    self.origin = origin
    self.confidence = confidence
    self.importance = importance
    self.stability = stability
    self.isEnabled = isEnabled
    self.lastConfirmedAt = lastConfirmedAt
    self.lastUsedAt = lastUsedAt
    self.useCount = useCount
    self.evidenceCount = evidenceCount
    self.revision = revision
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var isAvailable: Bool { status == .active && isEnabled }
}

public struct AutomaticMemoryEvidenceSnapshot: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let topicID: UUID
  public let conversationID: UUID
  public let sourceMessageID: UUID
  public let assistantMessageID: UUID?
  public let excerpt: String
  public let sourceFingerprint: String
  public let providerConfigurationID: UUID?
  public let providerKind: ProviderKind?
  public let providerDisplayName: String?
  public let modelIdentifier: String?
  public let providerEndpoint: String?
  public let confidence: Double
  public let createdAt: Date

  public init(
    id: UUID,
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
    createdAt: Date
  ) {
    self.id = id
    self.topicID = topicID
    self.conversationID = conversationID
    self.sourceMessageID = sourceMessageID
    self.assistantMessageID = assistantMessageID
    self.excerpt = excerpt
    self.sourceFingerprint = sourceFingerprint
    self.providerConfigurationID = providerConfigurationID
    self.providerKind = providerKind
    self.providerDisplayName = providerDisplayName
    self.modelIdentifier = modelIdentifier
    self.providerEndpoint = providerEndpoint
    self.confidence = confidence
    self.createdAt = createdAt
  }
}

public struct AutomaticMemoryRevisionSnapshot: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let topicID: UUID
  public let sequence: Int
  public let kind: MemoryRevisionKind
  public let previousTitle: String?
  public let previousContent: String?
  public let title: String
  public let content: String
  public let sourceEvidenceID: UUID?
  public let createdAt: Date

  public init(
    id: UUID,
    topicID: UUID,
    sequence: Int,
    kind: MemoryRevisionKind,
    previousTitle: String?,
    previousContent: String?,
    title: String,
    content: String,
    sourceEvidenceID: UUID?,
    createdAt: Date
  ) {
    self.id = id
    self.topicID = topicID
    self.sequence = sequence
    self.kind = kind
    self.previousTitle = previousTitle
    self.previousContent = previousContent
    self.title = title
    self.content = content
    self.sourceEvidenceID = sourceEvidenceID
    self.createdAt = createdAt
  }
}

public struct AutomaticMemorySourceMessage: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let role: MessageRole
  public let content: String
  public let createdAt: Date

  public init(id: UUID, role: MessageRole, content: String, createdAt: Date) {
    self.id = id
    self.role = role
    self.content = content
    self.createdAt = createdAt
  }
}

public struct AutomaticMemoryFormationPreparation: Hashable, Sendable {
  public let jobID: UUID
  public let conversationID: UUID
  public let throughUserMessageID: UUID
  public let assistantMessageID: UUID
  public let sourceFingerprint: String
  public let messages: [AutomaticMemorySourceMessage]
  public let existingTopics: [AutomaticMemoryTopicSnapshot]
  public let projectID: UUID?
  public let projectName: String?

  public init(
    jobID: UUID,
    conversationID: UUID,
    throughUserMessageID: UUID,
    assistantMessageID: UUID,
    sourceFingerprint: String,
    messages: [AutomaticMemorySourceMessage],
    existingTopics: [AutomaticMemoryTopicSnapshot],
    projectID: UUID? = nil,
    projectName: String? = nil
  ) {
    self.jobID = jobID
    self.conversationID = conversationID
    self.throughUserMessageID = throughUserMessageID
    self.assistantMessageID = assistantMessageID
    self.sourceFingerprint = sourceFingerprint
    self.messages = messages
    self.existingTopics = existingTopics
    self.projectID = projectID
    self.projectName = projectName
  }
}

public struct AutomaticMemoryFormationResult: Hashable, Sendable {
  public let createdCount: Int
  public let updatedCount: Int
  public let reinforcedCount: Int
  public let forgottenCount: Int

  public init(
    createdCount: Int = 0,
    updatedCount: Int = 0,
    reinforcedCount: Int = 0,
    forgottenCount: Int = 0
  ) {
    self.createdCount = createdCount
    self.updatedCount = updatedCount
    self.reinforcedCount = reinforcedCount
    self.forgottenCount = forgottenCount
  }

  public var changedCount: Int {
    createdCount + updatedCount + reinforcedCount + forgottenCount
  }
}

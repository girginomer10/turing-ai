import Foundation

/// Hard source-field limits keep one locally created or restored row from defeating otherwise
/// bounded actor fetches. They are intentionally far above normal chat and memory payloads.
public enum MosaicSourceFieldLimits {
  public static let maximumConversationTitleUTF8Bytes = 16 * 1_024
  public static let maximumConversationSystemPromptUTF8Bytes = 256 * 1_024
  public static let maximumConversationDraftUTF8Bytes = 512 * 1_024
  public static let maximumMessageContentUTF8Bytes = 512 * 1_024
  public static let maximumProjectNameUTF8Bytes = 4 * 1_024
  public static let maximumProjectInstructionsUTF8Bytes = 256 * 1_024
  public static let maximumMemoryTitleUTF8Bytes = 4 * 1_024
  public static let maximumMemoryContentUTF8Bytes = 256 * 1_024
  public static let maximumMemoryCanonicalKeyUTF8Bytes = 1_024
  public static let maximumMemoryEvidenceExcerptUTF8Bytes = 8 * 1_024
  public static let maximumMemoryAuditKeyUTF8Bytes = 2 * 1_024
  public static let maximumMemoryProvenanceUTF8Bytes = 8 * 1_024
  public static let maximumMemoryFormationErrorUTF8Bytes = 8 * 1_024
  public static let maximumAutomaticMemoryTitleCharacters = 160
  public static let maximumAutomaticMemoryTitleUTF8Bytes = 512
  public static let maximumAutomaticMemoryContentCharacters = 2_000
  public static let maximumAutomaticMemoryContentUTF8Bytes = 8 * 1_024

  public static func validateConversation(
    title: String,
    systemPrompt: String?,
    draft: String
  ) throws {
    let titleBytes = title.utf8.count
    guard titleBytes <= maximumConversationTitleUTF8Bytes else {
      throw MosaicSourceFieldLimitError.conversationTitle(
        actual: titleBytes,
        maximum: maximumConversationTitleUTF8Bytes
      )
    }
    let systemPromptBytes = systemPrompt?.utf8.count ?? 0
    guard systemPromptBytes <= maximumConversationSystemPromptUTF8Bytes else {
      throw MosaicSourceFieldLimitError.conversationSystemPrompt(
        actual: systemPromptBytes,
        maximum: maximumConversationSystemPromptUTF8Bytes
      )
    }
    let draftBytes = draft.utf8.count
    guard draftBytes <= maximumConversationDraftUTF8Bytes else {
      throw MosaicSourceFieldLimitError.conversationDraft(
        actual: draftBytes,
        maximum: maximumConversationDraftUTF8Bytes
      )
    }
  }

  public static func validateMessageContent(_ content: String) throws {
    let actual = content.utf8.count
    guard actual <= maximumMessageContentUTF8Bytes else {
      throw MosaicSourceFieldLimitError.messageContent(
        actual: actual,
        maximum: maximumMessageContentUTF8Bytes
      )
    }
  }

  public static func validateProject(name: String, instructions: String) throws {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let nameBytes = name.utf8.count
    guard !trimmedName.isEmpty, trimmedName == name,
      nameBytes <= maximumProjectNameUTF8Bytes
    else {
      throw MosaicSourceFieldLimitError.projectName(
        actual: nameBytes,
        maximum: maximumProjectNameUTF8Bytes
      )
    }
    let instructionBytes = instructions.utf8.count
    guard instructionBytes <= maximumProjectInstructionsUTF8Bytes else {
      throw MosaicSourceFieldLimitError.projectInstructions(
        actual: instructionBytes,
        maximum: maximumProjectInstructionsUTF8Bytes
      )
    }
  }

  public static func validateMemory(title: String, content: String) throws {
    let titleBytes = title.utf8.count
    guard titleBytes <= maximumMemoryTitleUTF8Bytes else {
      throw MosaicSourceFieldLimitError.memoryTitle(
        actual: titleBytes,
        maximum: maximumMemoryTitleUTF8Bytes
      )
    }
    let contentBytes = content.utf8.count
    guard contentBytes <= maximumMemoryContentUTF8Bytes else {
      throw MosaicSourceFieldLimitError.memoryContent(
        actual: contentBytes,
        maximum: maximumMemoryContentUTF8Bytes
      )
    }
  }

  public static func validateAutomaticMemoryText(title: String, content: String) throws {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty, trimmedTitle == title,
      !trimmedContent.isEmpty, trimmedContent == content
    else {
      throw MosaicSourceFieldLimitError.automaticMemoryInvalidValue("title or content")
    }
    guard title.count <= maximumAutomaticMemoryTitleCharacters else {
      throw MosaicSourceFieldLimitError.automaticMemoryTitleCharacters(
        actual: title.count,
        maximum: maximumAutomaticMemoryTitleCharacters
      )
    }
    guard content.count <= maximumAutomaticMemoryContentCharacters else {
      throw MosaicSourceFieldLimitError.automaticMemoryContentCharacters(
        actual: content.count,
        maximum: maximumAutomaticMemoryContentCharacters
      )
    }
    try validateBoundedMemoryField(
      title,
      field: "title",
      maximum: maximumAutomaticMemoryTitleUTF8Bytes
    )
    try validateBoundedMemoryField(
      content,
      field: "content",
      maximum: maximumAutomaticMemoryContentUTF8Bytes
    )
  }

  public static func validateMemoryTopic(_ topic: MemoryTopicRecord) throws {
    try validateAutomaticMemoryText(title: topic.title, content: topic.content)
    try validateBoundedMemoryField(
      topic.canonicalKey,
      field: "canonical key",
      maximum: maximumMemoryCanonicalKeyUTF8Bytes
    )
    guard !topic.canonicalKey.isEmpty,
      !topic.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !topic.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      topic.confidence.isFinite, (0...1).contains(topic.confidence),
      topic.importance.isFinite, (0...1).contains(topic.importance),
      topic.useCount >= 0, topic.evidenceCount >= 0, topic.revision > 0,
      MemoryTopicKind(rawValue: topic.kindRawValue) != nil,
      MemoryTopicStatus(rawValue: topic.statusRawValue) != nil,
      MemoryOrigin(rawValue: topic.originRawValue) != nil,
      MemoryStability(rawValue: topic.stabilityRawValue) != nil,
      MemoryScope(rawValue: topic.scopeRawValue) != nil,
      topic.scope == .conversation ? topic.conversationID != nil : topic.conversationID == nil,
      topic.status != .forgotten || !topic.isEnabled,
      topic.createdAt <= topic.updatedAt,
      topic.lastConfirmedAt <= topic.updatedAt
    else {
      throw MosaicSourceFieldLimitError.automaticMemoryInvalidValue("topic metadata")
    }
  }

  public static func validateMemoryEvidence(_ evidence: MemoryEvidenceRecord) throws {
    try validateBoundedMemoryField(
      evidence.evidenceKey,
      field: "evidence key",
      maximum: maximumMemoryAuditKeyUTF8Bytes
    )
    try validateBoundedMemoryField(
      evidence.excerpt,
      field: "evidence excerpt",
      maximum: maximumMemoryEvidenceExcerptUTF8Bytes
    )
    try validateBoundedMemoryField(
      evidence.sourceFingerprint,
      field: "evidence source fingerprint",
      maximum: maximumMemoryAuditKeyUTF8Bytes
    )
    if let providerDisplayName = evidence.providerDisplayName {
      try validateBoundedMemoryField(
        providerDisplayName,
        field: "evidence provider name",
        maximum: maximumMemoryProvenanceUTF8Bytes
      )
    }
    if let modelIdentifier = evidence.modelIdentifier {
      try validateBoundedMemoryField(
        modelIdentifier,
        field: "evidence model identifier",
        maximum: maximumMemoryProvenanceUTF8Bytes
      )
    }
    if let providerEndpoint = evidence.providerEndpoint {
      try validateBoundedMemoryField(
        providerEndpoint,
        field: "evidence provider endpoint",
        maximum: maximumMemoryProvenanceUTF8Bytes
      )
    }
    let trimmedProviderEndpoint = evidence.providerEndpoint?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !evidence.evidenceKey.isEmpty,
      !evidence.sourceFingerprint.isEmpty,
      !evidence.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      evidence.providerKindRawValue == nil
        || ProviderKind(rawValue: evidence.providerKindRawValue ?? "") != nil,
      evidence.providerEndpoint == nil || trimmedProviderEndpoint?.isEmpty == false,
      evidence.confidence.isFinite, (0...1).contains(evidence.confidence)
    else {
      throw MosaicSourceFieldLimitError.automaticMemoryInvalidValue("evidence metadata")
    }
  }

  public static func validateMemoryRevision(_ revision: MemoryRevisionRecord) throws {
    try validateBoundedMemoryField(
      revision.revisionKey,
      field: "revision key",
      maximum: maximumMemoryAuditKeyUTF8Bytes
    )
    try validateAutomaticMemoryText(title: revision.title, content: revision.content)
    if let previousTitle = revision.previousTitle, let previousContent = revision.previousContent {
      try validateAutomaticMemoryText(title: previousTitle, content: previousContent)
    }
    guard !revision.revisionKey.isEmpty,
      (revision.previousTitle == nil) == (revision.previousContent == nil),
      !revision.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !revision.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      revision.sequence > 0,
      MemoryRevisionKind(rawValue: revision.kindRawValue) != nil
    else {
      throw MosaicSourceFieldLimitError.automaticMemoryInvalidValue("revision metadata")
    }
  }

  public static func validateMemoryFormationJob(_ job: MemoryFormationJobRecord) throws {
    try validateBoundedMemoryField(
      job.jobKey,
      field: "formation job key",
      maximum: maximumMemoryAuditKeyUTF8Bytes
    )
    try validateBoundedMemoryField(
      job.sourceFingerprint,
      field: "formation source fingerprint",
      maximum: maximumMemoryAuditKeyUTF8Bytes
    )
    try validateBoundedMemoryField(
      job.promptVersion,
      field: "formation prompt version",
      maximum: maximumMemoryProvenanceUTF8Bytes
    )
    for (value, field) in [
      (job.providerDisplayName, "formation provider name"),
      (job.modelIdentifier, "formation model identifier"),
      (job.providerEndpoint, "formation provider endpoint"),
      (job.outputFingerprint, "formation output fingerprint"),
    ] {
      if let value {
        try validateBoundedMemoryField(
          value,
          field: field,
          maximum: maximumMemoryProvenanceUTF8Bytes
        )
      }
    }
    if let error = job.lastError {
      try validateBoundedMemoryField(
        error,
        field: "formation error",
        maximum: maximumMemoryFormationErrorUTF8Bytes
      )
    }
    let trimmedProviderEndpoint = job.providerEndpoint?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !job.jobKey.isEmpty,
      !job.sourceFingerprint.isEmpty,
      !job.promptVersion.isEmpty,
      job.attemptCount >= 0,
      MemoryFormationJobStatus(rawValue: job.statusRawValue) != nil,
      job.providerKindRawValue == nil
        || ProviderKind(rawValue: job.providerKindRawValue ?? "") != nil,
      job.providerEndpoint == nil || trimmedProviderEndpoint?.isEmpty == false,
      job.createdAt <= job.updatedAt,
      job.status != .complete || job.outputFingerprint != nil
    else {
      throw MosaicSourceFieldLimitError.automaticMemoryInvalidValue("formation job metadata")
    }
  }

  public static func validateMemoryFormationAudit(_ audit: MemoryFormationAuditRecord) throws {
    try validateBoundedMemoryField(
      audit.jobKey,
      field: "formation audit job key",
      maximum: maximumMemoryAuditKeyUTF8Bytes
    )
    for (value, field) in [
      (audit.providerDisplayName, "formation audit provider name"),
      (audit.modelIdentifier, "formation audit model identifier"),
      (audit.providerEndpoint, "formation audit provider endpoint"),
      (audit.providerMessageID, "formation audit provider message identifier"),
    ] {
      if let value {
        try validateBoundedMemoryField(
          value,
          field: field,
          maximum: maximumMemoryProvenanceUTF8Bytes
        )
      }
    }
    if let error = audit.errorDescription {
      try validateBoundedMemoryField(
        error,
        field: "formation audit error",
        maximum: maximumMemoryFormationErrorUTF8Bytes
      )
    }
    let trimmedEndpoint = audit.providerEndpoint?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let trimmedMessageID = audit.providerMessageID?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let trimmedError = audit.errorDescription?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let outcome = MemoryFormationJobStatus(rawValue: audit.outcomeRawValue)
    let isGenerating = outcome == .generating
    let isComplete = outcome == .complete
    let isFailed = outcome == .failed
    let isRejected = outcome == .rejected
    let startedBeforeFinish = audit.startedAt.map { $0 <= audit.finishedAt } ?? true
    let tokensAreValid = [audit.inputTokenCount, audit.outputTokenCount].allSatisfy {
      guard let value = $0 else { return true }
      return (0...1_000_000_000).contains(value)
    }
    guard !audit.jobKey.isEmpty,
      audit.attemptCount >= 0,
      isGenerating || isComplete || isFailed || isRejected,
      audit.providerKindRawValue == nil
        || ProviderKind(rawValue: audit.providerKindRawValue ?? "") != nil,
      audit.providerEndpoint == nil || trimmedEndpoint?.isEmpty == false,
      audit.providerMessageID == nil || trimmedMessageID?.isEmpty == false,
      tokensAreValid,
      audit.providerRequestCount >= 0,
      audit.providerRequestCount <= audit.attemptCount,
      audit.cumulativeInputTokenCount >= 0,
      audit.cumulativeOutputTokenCount >= 0,
      audit.inputTokenCount.map({ $0 <= audit.cumulativeInputTokenCount }) ?? true,
      audit.outputTokenCount.map({ $0 <= audit.cumulativeOutputTokenCount }) ?? true,
      audit.providerRequestCount > 0
        || (audit.cumulativeInputTokenCount == 0 && audit.cumulativeOutputTokenCount == 0),
      audit.requestStarted
        || (audit.providerMessageID == nil
          && audit.inputTokenCount == nil
          && audit.outputTokenCount == nil),
      startedBeforeFinish,
      audit.createdAt <= audit.updatedAt,
      audit.updatedAt == audit.finishedAt,
      !isGenerating
        || (audit.attemptCount > 0 && audit.requestStarted && audit.errorDescription == nil),
      !isComplete
        || (audit.attemptCount > 0 && audit.requestStarted && audit.errorDescription == nil),
      !audit.requestStarted || audit.providerRequestCount > 0,
      (!isFailed && !isRejected) || trimmedError?.isEmpty == false
    else {
      throw MosaicSourceFieldLimitError.automaticMemoryInvalidValue(
        "formation audit metadata"
      )
    }
  }

  private static func validateBoundedMemoryField(
    _ value: String,
    field: String,
    maximum: Int
  ) throws {
    let actual = value.utf8.count
    guard actual <= maximum else {
      throw MosaicSourceFieldLimitError.automaticMemoryField(
        field: field,
        actual: actual,
        maximum: maximum
      )
    }
  }
}

public enum MosaicSourceFieldLimitError: Error, Equatable, LocalizedError, Sendable {
  case conversationTitle(actual: Int, maximum: Int)
  case conversationSystemPrompt(actual: Int, maximum: Int)
  case conversationDraft(actual: Int, maximum: Int)
  case messageContent(actual: Int, maximum: Int)
  case projectName(actual: Int, maximum: Int)
  case projectInstructions(actual: Int, maximum: Int)
  case memoryTitle(actual: Int, maximum: Int)
  case memoryContent(actual: Int, maximum: Int)
  case automaticMemoryTitleCharacters(actual: Int, maximum: Int)
  case automaticMemoryContentCharacters(actual: Int, maximum: Int)
  case automaticMemoryField(field: String, actual: Int, maximum: Int)
  case automaticMemoryInvalidValue(String)

  public var errorDescription: String? {
    switch self {
    case .conversationTitle(_, let maximum):
      "This chat title is larger than Turing AI’s safe local limit of \(formatted(maximum)). Shorten it and try again."
    case .conversationSystemPrompt(_, let maximum):
      "This chat instruction is larger than Turing AI’s safe local limit of \(formatted(maximum)). Shorten it and try again."
    case .conversationDraft(_, let maximum):
      "This draft is larger than Turing AI’s safe local limit of \(formatted(maximum)). Split it into smaller messages before saving."
    case .messageContent(_, let maximum):
      "This message is larger than Turing AI’s safe local limit of \(formatted(maximum)). Split it into smaller messages and try again."
    case .projectName(_, let maximum):
      "This project name is empty or larger than Turing AI’s safe local limit of \(formatted(maximum))."
    case .projectInstructions(_, let maximum):
      "These project instructions are larger than Turing AI’s safe local limit of \(formatted(maximum)). Shorten them and try again."
    case .memoryTitle(_, let maximum):
      "This memory title is larger than Turing AI’s safe local limit of \(formatted(maximum)). Shorten it and try again."
    case .memoryContent(_, let maximum):
      "This memory is larger than Turing AI’s safe local limit of \(formatted(maximum)). Split it into smaller memories and try again."
    case .automaticMemoryTitleCharacters(_, let maximum):
      "A learned-memory title can contain at most \(maximum.formatted()) characters. Shorten it and try again."
    case .automaticMemoryContentCharacters(_, let maximum):
      "A learned memory can contain at most \(maximum.formatted()) characters. Split it into smaller facts and try again."
    case .automaticMemoryField(let field, _, let maximum):
      "The automatic-memory \(field) is larger than Turing AI’s safe local limit of \(formatted(maximum))."
    case .automaticMemoryInvalidValue(let field):
      "The automatic-memory \(field) is invalid."
    }
  }

  private func formatted(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
  }
}

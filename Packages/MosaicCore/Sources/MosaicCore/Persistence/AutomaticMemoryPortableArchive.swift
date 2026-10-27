import Foundation
import SwiftData

private struct PortableMemoryTopic: Codable, Hashable {
  let id: UUID
  let canonicalKey: String
  let title: String
  let content: String
  let kindRawValue: String
  let scopeRawValue: String
  let conversationID: UUID?
  let statusRawValue: String
  let originRawValue: String
  let confidence: Double
  let importance: Double
  let stabilityRawValue: String
  let isEnabled: Bool
  let lastConfirmedAt: Date
  let lastUsedAt: Date?
  let useCount: Int
  let evidenceCount: Int
  let revision: Int
  let createdAt: Date
  let updatedAt: Date

  init(_ record: MemoryTopicRecord) {
    id = record.id
    canonicalKey = record.canonicalKey
    title = record.title
    content = record.content
    kindRawValue = record.kindRawValue
    scopeRawValue = record.scopeRawValue
    conversationID = record.conversationID
    statusRawValue = record.statusRawValue
    originRawValue = record.originRawValue
    confidence = record.confidence
    importance = record.importance
    stabilityRawValue = record.stabilityRawValue
    isEnabled = record.isEnabled
    lastConfirmedAt = record.lastConfirmedAt
    lastUsedAt = record.lastUsedAt
    useCount = record.useCount
    evidenceCount = record.evidenceCount
    revision = record.revision
    createdAt = record.createdAt
    updatedAt = record.updatedAt
  }

  var record: MemoryTopicRecord {
    let value = MemoryTopicRecord(
      id: id,
      canonicalKey: canonicalKey,
      title: title,
      content: content,
      kind: MemoryTopicKind(rawValue: kindRawValue) ?? .fact,
      scope: MemoryScope(rawValue: scopeRawValue) ?? .global,
      conversationID: conversationID,
      status: MemoryTopicStatus(rawValue: statusRawValue) ?? .forgotten,
      origin: MemoryOrigin(rawValue: originRawValue) ?? .automatic,
      confidence: confidence,
      importance: importance,
      stability: MemoryStability(rawValue: stabilityRawValue) ?? .evolving,
      isEnabled: isEnabled,
      lastConfirmedAt: lastConfirmedAt,
      lastUsedAt: lastUsedAt,
      useCount: useCount,
      evidenceCount: evidenceCount,
      revision: revision,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
    return value
  }
}

private struct PortableMemoryEvidence: Codable, Hashable {
  let id: UUID
  let evidenceKey: String
  let topicID: UUID
  let conversationID: UUID
  let sourceMessageID: UUID
  let assistantMessageID: UUID?
  let excerpt: String
  let sourceFingerprint: String
  let providerConfigurationID: UUID?
  let providerKindRawValue: String?
  let providerDisplayName: String?
  let modelIdentifier: String?
  let providerEndpoint: String?
  let confidence: Double
  let createdAt: Date

  init(_ record: MemoryEvidenceRecord) {
    id = record.id
    evidenceKey = record.evidenceKey
    topicID = record.topicID
    conversationID = record.conversationID
    sourceMessageID = record.sourceMessageID
    assistantMessageID = record.assistantMessageID
    excerpt = record.excerpt
    sourceFingerprint = record.sourceFingerprint
    providerConfigurationID = record.providerConfigurationID
    providerKindRawValue = record.providerKindRawValue
    providerDisplayName = record.providerDisplayName
    modelIdentifier = record.modelIdentifier
    providerEndpoint = record.providerEndpoint
    confidence = record.confidence
    createdAt = record.createdAt
  }

  var record: MemoryEvidenceRecord {
    MemoryEvidenceRecord(
      id: id,
      evidenceKey: evidenceKey,
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

private struct PortableMemoryRevision: Codable, Hashable {
  let id: UUID
  let revisionKey: String
  let topicID: UUID
  let sequence: Int
  let kindRawValue: String
  let previousTitle: String?
  let previousContent: String?
  let title: String
  let content: String
  let sourceEvidenceID: UUID?
  let createdAt: Date

  init(_ record: MemoryRevisionRecord) {
    id = record.id
    revisionKey = record.revisionKey
    topicID = record.topicID
    sequence = record.sequence
    kindRawValue = record.kindRawValue
    previousTitle = record.previousTitle
    previousContent = record.previousContent
    title = record.title
    content = record.content
    sourceEvidenceID = record.sourceEvidenceID
    createdAt = record.createdAt
  }

  var record: MemoryRevisionRecord {
    MemoryRevisionRecord(
      id: id,
      revisionKey: revisionKey,
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
}

private struct PortableMemoryFormationJob: Codable, Hashable {
  let id: UUID
  let jobKey: String
  let conversationID: UUID
  let throughUserMessageID: UUID
  let assistantMessageID: UUID
  let sourceFingerprint: String
  let promptVersion: String
  let statusRawValue: String
  let attemptCount: Int
  let providerConfigurationID: UUID?
  let providerKindRawValue: String?
  let providerDisplayName: String?
  let modelIdentifier: String?
  let providerEndpoint: String?
  let outputFingerprint: String?
  let lastError: String?
  let startedAt: Date?
  let completedAt: Date?
  let createdAt: Date
  let updatedAt: Date

  init(_ record: MemoryFormationJobRecord) {
    id = record.id
    jobKey = record.jobKey
    conversationID = record.conversationID
    throughUserMessageID = record.throughUserMessageID
    assistantMessageID = record.assistantMessageID
    sourceFingerprint = record.sourceFingerprint
    promptVersion = record.promptVersion
    statusRawValue = record.statusRawValue
    attemptCount = record.attemptCount
    providerConfigurationID = record.providerConfigurationID
    providerKindRawValue = record.providerKindRawValue
    providerDisplayName = record.providerDisplayName
    modelIdentifier = record.modelIdentifier
    providerEndpoint = record.providerEndpoint
    outputFingerprint = record.outputFingerprint
    lastError = record.lastError
    startedAt = record.startedAt
    completedAt = record.completedAt
    createdAt = record.createdAt
    updatedAt = record.updatedAt
  }

  init(copying value: Self, providerConfigurationID: UUID?) {
    id = value.id
    jobKey = value.jobKey
    conversationID = value.conversationID
    throughUserMessageID = value.throughUserMessageID
    assistantMessageID = value.assistantMessageID
    sourceFingerprint = value.sourceFingerprint
    promptVersion = value.promptVersion
    statusRawValue = value.statusRawValue
    attemptCount = value.attemptCount
    self.providerConfigurationID = providerConfigurationID
    providerKindRawValue = value.providerKindRawValue
    providerDisplayName = value.providerDisplayName
    modelIdentifier = value.modelIdentifier
    providerEndpoint = value.providerEndpoint
    outputFingerprint = value.outputFingerprint
    lastError = value.lastError
    startedAt = value.startedAt
    completedAt = value.completedAt
    createdAt = value.createdAt
    updatedAt = value.updatedAt
  }

  var record: MemoryFormationJobRecord {
    MemoryFormationJobRecord(
      id: id,
      jobKey: jobKey,
      conversationID: conversationID,
      throughUserMessageID: throughUserMessageID,
      assistantMessageID: assistantMessageID,
      sourceFingerprint: sourceFingerprint,
      promptVersion: promptVersion,
      status: MemoryFormationJobStatus(rawValue: statusRawValue) ?? .failed,
      attemptCount: attemptCount,
      providerConfigurationID: providerConfigurationID,
      providerKind: providerKindRawValue.flatMap(ProviderKind.init(rawValue:)),
      providerDisplayName: providerDisplayName,
      modelIdentifier: modelIdentifier,
      providerEndpoint: providerEndpoint,
      outputFingerprint: outputFingerprint,
      lastError: lastError,
      startedAt: startedAt,
      completedAt: completedAt,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

private struct PortableMemoryFormationAudit: Codable, Hashable {
  let id: UUID
  let jobID: UUID
  let jobKey: String
  let attemptCount: Int
  let outcomeRawValue: String
  let providerConfigurationID: UUID?
  let providerKindRawValue: String?
  let providerDisplayName: String?
  let modelIdentifier: String?
  let providerEndpoint: String?
  let providerMessageID: String?
  let requestStarted: Bool
  let inputTokenCount: Int?
  let outputTokenCount: Int?
  let providerRequestCount: Int
  let cumulativeInputTokenCount: Int
  let cumulativeOutputTokenCount: Int
  let didDiscardInvalidTelemetry: Bool
  let errorDescription: String?
  let startedAt: Date?
  let finishedAt: Date
  let createdAt: Date
  let updatedAt: Date

  init(_ record: MemoryFormationAuditRecord) {
    id = record.id
    jobID = record.jobID
    jobKey = record.jobKey
    attemptCount = record.attemptCount
    outcomeRawValue = record.outcomeRawValue
    providerConfigurationID = record.providerConfigurationID
    providerKindRawValue = record.providerKindRawValue
    providerDisplayName = record.providerDisplayName
    modelIdentifier = record.modelIdentifier
    providerEndpoint = record.providerEndpoint
    providerMessageID = record.providerMessageID
    requestStarted = record.requestStarted
    inputTokenCount = record.inputTokenCount
    outputTokenCount = record.outputTokenCount
    providerRequestCount = record.providerRequestCount
    cumulativeInputTokenCount = record.cumulativeInputTokenCount
    cumulativeOutputTokenCount = record.cumulativeOutputTokenCount
    didDiscardInvalidTelemetry = record.didDiscardInvalidTelemetry
    errorDescription = record.errorDescription
    startedAt = record.startedAt
    finishedAt = record.finishedAt
    createdAt = record.createdAt
    updatedAt = record.updatedAt
  }

  var record: MemoryFormationAuditRecord {
    MemoryFormationAuditRecord(
      id: id,
      jobID: jobID,
      jobKey: jobKey,
      attemptCount: attemptCount,
      outcome: MemoryFormationJobStatus(rawValue: outcomeRawValue) ?? .failed,
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
}

enum AutomaticMemoryPortableArchive {
  static let namespace = "com.omergirgin.mosaic.memory"

  static func topicCount(in records: [MosaicPortableExtensionRecord]) -> Int {
    records.lazy.filter { $0.namespace == namespace && $0.recordType == topicType }.count
  }

  static let recordVersion = 1
  private static let pageSize = 64
  private static let maximumEvidenceExcerptCharacters = 1_500
  private static let topicType = "topic"
  private static let evidenceType = "evidence"
  private static let revisionType = "revision"
  private static let jobType = "formation_job"
  private static let auditType = "formation_audit"

  private enum Payload {
    case topic(PortableMemoryTopic)
    case evidence(PortableMemoryEvidence)
    case revision(PortableMemoryRevision)
    case job(PortableMemoryFormationJob)
    case audit(PortableMemoryFormationAudit)
  }

  static func isOwned(_ record: MosaicPortableExtensionRecord) -> Bool {
    record.namespace == namespace
  }

  static func capture(
    from modelContext: ModelContext,
    includesPendingChanges: Bool,
    limits: MosaicPortableBackupLimits,
    honorsCancellation: Bool = true
  ) throws -> [MosaicPortableExtensionRecord] {
    var records: [MosaicPortableExtensionRecord] = []
    var approximateBytes = 0

    try capturePages(
      from: modelContext,
      makeDescriptor: topicDescriptor,
      key: \MemoryTopicRecord.id,
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation
    ) { topic in
      try append(
        payload: PortableMemoryTopic(topic),
        recordType: topicType,
        id: topic.id,
        limits: limits,
        records: &records,
        approximateBytes: &approximateBytes
      )
    }
    try capturePages(
      from: modelContext,
      makeDescriptor: evidenceDescriptor,
      key: \MemoryEvidenceRecord.id,
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation
    ) { evidence in
      try append(
        payload: PortableMemoryEvidence(evidence),
        recordType: evidenceType,
        id: evidence.id,
        limits: limits,
        records: &records,
        approximateBytes: &approximateBytes
      )
    }
    try capturePages(
      from: modelContext,
      makeDescriptor: revisionDescriptor,
      key: \MemoryRevisionRecord.id,
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation
    ) { revision in
      try append(
        payload: PortableMemoryRevision(revision),
        recordType: revisionType,
        id: revision.id,
        limits: limits,
        records: &records,
        approximateBytes: &approximateBytes
      )
    }
    try capturePages(
      from: modelContext,
      makeDescriptor: jobDescriptor,
      key: \MemoryFormationJobRecord.id,
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation
    ) { job in
      try append(
        payload: PortableMemoryFormationJob(job),
        recordType: jobType,
        id: job.id,
        limits: limits,
        records: &records,
        approximateBytes: &approximateBytes
      )
    }
    try capturePages(
      from: modelContext,
      makeDescriptor: auditDescriptor,
      key: \MemoryFormationAuditRecord.id,
      includesPendingChanges: includesPendingChanges,
      honorsCancellation: honorsCancellation
    ) { audit in
      try append(
        payload: PortableMemoryFormationAudit(audit),
        recordType: auditType,
        id: audit.id,
        limits: limits,
        records: &records,
        approximateBytes: &approximateBytes
      )
    }
    return records.sorted(by: MosaicPortableBackup.extensionRecordOrder)
  }

  static func validate(
    _ extensionRecords: [MosaicPortableExtensionRecord],
    conversationIDs: Set<UUID>,
    messages: [MosaicPortableMessage],
    projectIDsByConversation: [UUID: UUID],
    projectIDsByTopic: [UUID: UUID]
  ) throws {
    let payloads = try extensionRecords.map(decode)
    let topics = payloads.compactMap { payload -> PortableMemoryTopic? in
      if case .topic(let value) = payload { return value }
      return nil
    }
    let evidence = payloads.compactMap { payload -> PortableMemoryEvidence? in
      if case .evidence(let value) = payload { return value }
      return nil
    }
    let revisions = payloads.compactMap { payload -> PortableMemoryRevision? in
      if case .revision(let value) = payload { return value }
      return nil
    }
    let jobs = payloads.compactMap { payload -> PortableMemoryFormationJob? in
      if case .job(let value) = payload { return value }
      return nil
    }
    let audits = payloads.compactMap { payload -> PortableMemoryFormationAudit? in
      if case .audit(let value) = payload { return value }
      return nil
    }

    var canonicalKeys: Set<String> = []
    var evidenceKeys: Set<String> = []
    var revisionKeys: Set<String> = []
    var jobKeys: Set<String> = []
    var auditJobIDs: Set<UUID> = []
    var auditJobKeys: Set<String> = []
    let topicIDs = Set(topics.map(\.id))
    let topicsByID = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0) })
    let evidenceIDs = Set(evidence.map(\.id))
    let messagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
    for topic in topics {
      guard let kind = MemoryTopicKind(rawValue: topic.kindRawValue),
        let scope = MemoryScope(rawValue: topic.scopeRawValue),
        MemoryTopicStatus(rawValue: topic.statusRawValue) != nil,
        MemoryOrigin(rawValue: topic.originRawValue) != nil,
        MemoryStability(rawValue: topic.stabilityRawValue) != nil
      else {
        throw invalid(recordType: "memory_topic", id: topic.id, field: "enum_value")
      }
      if scope != .conversation, topic.conversationID != nil {
        throw invalid(recordType: "memory_topic", id: topic.id, field: "topic_conversation")
      }
      let record = topic.record
      try MosaicSourceFieldLimits.validateMemoryTopic(record)
      let canonicalPrefix: String
      switch scope {
      case .global:
        guard projectIDsByTopic[topic.id] == nil else {
          throw invalid(recordType: "memory_topic", id: topic.id, field: "project_binding")
        }
        canonicalPrefix = "global:\(kind.rawValue):"
      case .project:
        guard let projectID = projectIDsByTopic[topic.id] else {
          throw invalid(recordType: "memory_topic", id: topic.id, field: "project_binding")
        }
        canonicalPrefix =
          "project:\(projectID.uuidString.lowercased()):\(kind.rawValue):"
      case .conversation:
        guard let conversationID = topic.conversationID else {
          throw invalid(recordType: "memory_topic", id: topic.id, field: "canonical_key")
        }
        guard projectIDsByTopic[topic.id] == nil else {
          throw invalid(recordType: "memory_topic", id: topic.id, field: "project_binding")
        }
        canonicalPrefix =
          "conversation:\(conversationID.uuidString.lowercased()):\(kind.rawValue):"
      }
      guard topic.canonicalKey.hasPrefix(canonicalPrefix),
        topic.canonicalKey.utf8.count > canonicalPrefix.utf8.count
      else {
        throw invalid(recordType: "memory_topic", id: topic.id, field: "canonical_key")
      }
      guard canonicalKeys.insert(topic.canonicalKey).inserted else {
        throw MosaicPortableBackupError.duplicateKey(
          recordType: "memory_topic",
          key: topic.canonicalKey
        )
      }
      if let conversationID = topic.conversationID,
        !conversationIDs.contains(conversationID)
      {
        throw MosaicPortableBackupError.missingNormalizedReference(
          recordType: "memory_topic",
          id: topic.id,
          field: "conversation",
          targetID: conversationID
        )
      }
    }
    var evidenceCountByTopic: [UUID: Int] = [:]
    for item in evidence {
      guard evidenceKeys.insert(item.evidenceKey).inserted else {
        throw MosaicPortableBackupError.duplicateKey(
          recordType: "memory_evidence",
          key: item.evidenceKey
        )
      }
      guard item.providerKindRawValue.map({ ProviderKind(rawValue: $0) != nil }) ?? true else {
        throw invalid(recordType: "memory_evidence", id: item.id, field: "provider_kind")
      }
      try MosaicSourceFieldLimits.validateMemoryEvidence(item.record)
      guard
        validProviderEndpoint(
          item.providerEndpoint,
          providerConfigurationID: item.providerConfigurationID
        )
      else {
        throw invalid(recordType: "memory_evidence", id: item.id, field: "provider_endpoint")
      }
      guard topicIDs.contains(item.topicID) else {
        throw missing(recordType: "memory_evidence", id: item.id, field: "topic", item.topicID)
      }
      guard let topic = topicsByID[item.topicID],
        topic.scopeRawValue != MemoryScope.conversation.rawValue
          || topic.conversationID == item.conversationID
      else {
        throw invalid(
          recordType: "memory_evidence",
          id: item.id,
          field: "topic_conversation"
        )
      }
      if topic.originRawValue == MemoryOrigin.automatic.rawValue {
        let conversationProjectID = projectIDsByConversation[item.conversationID]
        let hasValidAudience: Bool
        switch MemoryScope(rawValue: topic.scopeRawValue) {
        case .global:
          hasValidAudience = conversationProjectID == nil
        case .project:
          hasValidAudience =
            projectIDsByTopic[item.topicID] != nil
            && projectIDsByTopic[item.topicID] == conversationProjectID
        case .conversation:
          hasValidAudience = topic.conversationID == item.conversationID
        case nil:
          hasValidAudience = false
        }
        guard hasValidAudience else {
          throw invalid(
            recordType: "memory_evidence",
            id: item.id,
            field: "topic_project_audience"
          )
        }
      }
      guard conversationIDs.contains(item.conversationID) else {
        throw missing(
          recordType: "memory_evidence",
          id: item.id,
          field: "conversation",
          item.conversationID
        )
      }
      guard let source = messagesByID[item.sourceMessageID],
        source.conversationID == item.conversationID,
        source.roleRawValue == MessageRole.user.rawValue,
        source.statusRawValue == MessageStatus.complete.rawValue
      else {
        throw missing(
          recordType: "memory_evidence",
          id: item.id,
          field: "source_message",
          item.sourceMessageID
        )
      }
      guard item.sourceFingerprint == sourceFingerprint(for: source) else {
        throw invalid(
          recordType: "memory_evidence",
          id: item.id,
          field: "source_fingerprint"
        )
      }
      guard item.excerpt == evidenceExcerpt(for: source.content) else {
        throw invalid(recordType: "memory_evidence", id: item.id, field: "excerpt")
      }
      let expectedEvidenceKey =
        "\(item.topicID.uuidString.lowercased())/"
        + "\(item.sourceMessageID.uuidString.lowercased())/"
        + item.sourceFingerprint
      guard item.evidenceKey == expectedEvidenceKey else {
        throw invalid(recordType: "memory_evidence", id: item.id, field: "evidence_key")
      }
      if let assistantMessageID = item.assistantMessageID {
        guard let assistant = messagesByID[assistantMessageID],
          assistant.conversationID == item.conversationID,
          assistant.roleRawValue == MessageRole.assistant.rawValue,
          assistant.statusRawValue == MessageStatus.complete.rawValue,
          assistant.createdAt >= source.createdAt
        else {
          throw missing(
            recordType: "memory_evidence",
            id: item.id,
            field: "assistant_message",
            assistantMessageID
          )
        }
      }
      evidenceCountByTopic[item.topicID, default: 0] += 1
    }
    for topic in topics where topic.evidenceCount != evidenceCountByTopic[topic.id, default: 0] {
      throw invalid(recordType: "memory_topic", id: topic.id, field: "evidence_count")
    }
    for topic in topics where topic.originRawValue == MemoryOrigin.automatic.rawValue {
      let evidenceCount = evidenceCountByTopic[topic.id, default: 0]
      if topic.statusRawValue == MemoryTopicStatus.active.rawValue, evidenceCount == 0 {
        throw invalid(recordType: "memory_topic", id: topic.id, field: "automatic_evidence")
      }
      if evidenceCount == 0,
        topic.statusRawValue != MemoryTopicStatus.forgotten.rawValue || topic.isEnabled
      {
        throw invalid(recordType: "memory_topic", id: topic.id, field: "automatic_evidence")
      }
    }
    let evidenceByID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })
    let evidenceIDsByTopic = Dictionary(grouping: evidence, by: \.topicID).mapValues {
      Set($0.map(\.id))
    }
    var revisionsByTopic: [UUID: [PortableMemoryRevision]] = [:]
    for item in revisions {
      guard revisionKeys.insert(item.revisionKey).inserted else {
        throw MosaicPortableBackupError.duplicateKey(
          recordType: "memory_revision",
          key: item.revisionKey
        )
      }
      guard MemoryRevisionKind(rawValue: item.kindRawValue) != nil else {
        throw invalid(recordType: "memory_revision", id: item.id, field: "kind")
      }
      try MosaicSourceFieldLimits.validateMemoryRevision(item.record)
      guard topicIDs.contains(item.topicID) else {
        throw missing(recordType: "memory_revision", id: item.id, field: "topic", item.topicID)
      }
      if let evidenceID = item.sourceEvidenceID, !evidenceIDs.contains(evidenceID) {
        throw missing(
          recordType: "memory_revision",
          id: item.id,
          field: "evidence",
          evidenceID
        )
      }
      if let evidenceID = item.sourceEvidenceID,
        evidenceByID[evidenceID]?.topicID != item.topicID
      {
        throw invalid(
          recordType: "memory_revision",
          id: item.id,
          field: "source_evidence_topic"
        )
      }
      revisionsByTopic[item.topicID, default: []].append(item)
    }
    for topic in topics {
      let history = revisionsByTopic[topic.id, default: []].sorted {
        if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
        return $0.id.uuidString < $1.id.uuidString
      }
      guard history.count == topic.revision else {
        throw invalid(recordType: "memory_topic", id: topic.id, field: "revision_head")
      }
      let survivingEvidenceIDs = evidenceIDsByTopic[topic.id, default: []]
      if topic.originRawValue == MemoryOrigin.automatic.rawValue,
        topic.statusRawValue == MemoryTopicStatus.active.rawValue,
        !history.contains(where: {
          $0.sourceEvidenceID.map(survivingEvidenceIDs.contains) == true
        })
      {
        throw invalid(
          recordType: "memory_topic",
          id: topic.id,
          field: "revision_evidence"
        )
      }
      var previous: PortableMemoryRevision?
      for (index, revision) in history.enumerated() {
        let expectedSequence = index + 1
        guard revision.sequence == expectedSequence,
          revision.revisionKey
            == "\(topic.id.uuidString.lowercased())/\(expectedSequence)"
        else {
          throw invalid(
            recordType: "memory_revision",
            id: revision.id,
            field: "revision_sequence"
          )
        }
        if let previous {
          guard revision.previousTitle == previous.title,
            revision.previousContent == previous.content,
            revision.createdAt >= previous.createdAt
          else {
            throw invalid(
              recordType: "memory_revision",
              id: revision.id,
              field: "previous_value"
            )
          }
        } else {
          guard revision.kindRawValue == MemoryRevisionKind.created.rawValue,
            revision.previousTitle == nil,
            revision.previousContent == nil
          else {
            throw invalid(
              recordType: "memory_revision",
              id: revision.id,
              field: "revision_root"
            )
          }
        }
        previous = revision
      }
      guard let head = previous, head.title == topic.title, head.content == topic.content else {
        throw invalid(recordType: "memory_topic", id: topic.id, field: "revision_value")
      }
    }
    for item in jobs {
      guard jobKeys.insert(item.jobKey).inserted else {
        throw MosaicPortableBackupError.duplicateKey(
          recordType: "memory_formation_job",
          key: item.jobKey
        )
      }
      guard MemoryFormationJobStatus(rawValue: item.statusRawValue) != nil,
        item.providerKindRawValue.map({ ProviderKind(rawValue: $0) != nil }) ?? true
      else {
        throw invalid(recordType: "memory_formation_job", id: item.id, field: "enum_value")
      }
      try MosaicSourceFieldLimits.validateMemoryFormationJob(item.record)
      guard
        validProviderEndpoint(
          item.providerEndpoint,
          providerConfigurationID: item.providerConfigurationID
        )
      else {
        throw invalid(
          recordType: "memory_formation_job",
          id: item.id,
          field: "provider_endpoint"
        )
      }
      guard conversationIDs.contains(item.conversationID) else {
        throw missing(
          recordType: "memory_formation_job",
          id: item.id,
          field: "conversation",
          item.conversationID
        )
      }
      guard let userMessage = messagesByID[item.throughUserMessageID],
        userMessage.conversationID == item.conversationID,
        userMessage.roleRawValue == MessageRole.user.rawValue,
        userMessage.statusRawValue == MessageStatus.complete.rawValue
      else {
        throw missing(
          recordType: "memory_formation_job",
          id: item.id,
          field: "user_message",
          item.throughUserMessageID
        )
      }
      guard let assistantMessage = messagesByID[item.assistantMessageID],
        assistantMessage.conversationID == item.conversationID,
        assistantMessage.roleRawValue == MessageRole.assistant.rawValue,
        assistantMessage.statusRawValue == MessageStatus.complete.rawValue,
        assistantMessage.createdAt >= userMessage.createdAt
      else {
        throw missing(
          recordType: "memory_formation_job",
          id: item.id,
          field: "assistant_message",
          item.assistantMessageID
        )
      }
      guard item.sourceFingerprint == sourceFingerprint(for: userMessage) else {
        throw invalid(
          recordType: "memory_formation_job",
          id: item.id,
          field: "source_fingerprint"
        )
      }
      let expectedJobKey = EmbeddingVectorCodec.fingerprint(
        for:
          "\(item.promptVersion)|\(item.conversationID.uuidString.lowercased())|"
          + "\(item.throughUserMessageID.uuidString.lowercased())|\(item.sourceFingerprint)"
      )
      guard item.jobKey == expectedJobKey else {
        throw invalid(recordType: "memory_formation_job", id: item.id, field: "job_key")
      }
    }
    let jobsByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
    for item in audits {
      guard auditJobIDs.insert(item.jobID).inserted else {
        throw MosaicPortableBackupError.duplicateKey(
          recordType: "memory_formation_audit",
          key: item.jobID.uuidString.lowercased()
        )
      }
      guard auditJobKeys.insert(item.jobKey).inserted else {
        throw MosaicPortableBackupError.duplicateKey(
          recordType: "memory_formation_audit",
          key: item.jobKey
        )
      }
      guard let job = jobsByID[item.jobID], job.jobKey == item.jobKey else {
        throw missing(
          recordType: "memory_formation_audit",
          id: item.id,
          field: "formation_job",
          item.jobID
        )
      }
      try MosaicSourceFieldLimits.validateMemoryFormationAudit(item.record)
      let jobStatus = MemoryFormationJobStatus(rawValue: job.statusRawValue)
      let auditOutcome = MemoryFormationJobStatus(rawValue: item.outcomeRawValue)
      let sameProvider =
        item.providerKindRawValue == job.providerKindRawValue
        && item.providerDisplayName == job.providerDisplayName
        && item.modelIdentifier == job.modelIdentifier
        && item.providerEndpoint == job.providerEndpoint
      let validGeneratingRelationship =
        jobStatus == .generating
        && ((item.attemptCount == job.attemptCount
          && auditOutcome == .generating
          && item.requestStarted
          && sameProvider)
          || (item.attemptCount < job.attemptCount
            && (auditOutcome == .complete || auditOutcome == .failed
              || auditOutcome == .rejected)))
      let validTerminalRelationship =
        (jobStatus == .complete || jobStatus == .failed || jobStatus == .rejected)
        && item.attemptCount == job.attemptCount
        && item.outcomeRawValue == job.statusRawValue
        && sameProvider
        && item.finishedAt == job.updatedAt
      guard
        validProviderEndpoint(
          item.providerEndpoint,
          providerConfigurationID: item.providerConfigurationID
        ),
        item.attemptCount <= job.attemptCount,
        validGeneratingRelationship || validTerminalRelationship
      else {
        throw invalid(
          recordType: "memory_formation_audit",
          id: item.id,
          field: "job_state"
        )
      }
    }
  }

  static func topicScopes(
    in extensionRecords: [MosaicPortableExtensionRecord]
  ) throws -> [UUID: MemoryScope] {
    var result: [UUID: MemoryScope] = [:]
    for payload in try extensionRecords.map(decode) {
      guard case .topic(let topic) = payload else { continue }
      guard let scope = MemoryScope(rawValue: topic.scopeRawValue) else {
        throw invalid(recordType: "memory_topic", id: topic.id, field: "scope")
      }
      guard result.updateValue(scope, forKey: topic.id) == nil else {
        throw MosaicPortableBackupError.duplicateID(recordType: "memory_topic", id: topic.id)
      }
    }
    return result
  }

  /// Formation-job provider IDs are operational locators, so they follow restore-time rekeying.
  /// Evidence and audit provider IDs, like message provider IDs, are immutable provenance.
  static func remapProviderConfigurationIDs(
    in extensionRecords: [MosaicPortableExtensionRecord],
    using providerIDMap: [UUID: UUID]
  ) throws -> [MosaicPortableExtensionRecord] {
    return try extensionRecords.map { record in
      switch try decode(record) {
      case .topic, .evidence, .revision, .audit:
        return record
      case .job(let value):
        return try encoded(
          PortableMemoryFormationJob(
            copying: value,
            providerConfigurationID: value.providerConfigurationID.flatMap {
              providerIDMap[$0]
            }
          ),
          recordType: jobType,
          id: value.id
        )
      }
    }
  }

  static func insert(
    _ extensionRecords: [MosaicPortableExtensionRecord],
    into modelContext: ModelContext,
    honorsCancellation: Bool
  ) throws {
    let payloads = try extensionRecords.map(decode)
    for payload in payloads {
      if honorsCancellation { try Task.checkCancellation() }
      switch payload {
      case .topic(let value): modelContext.insert(value.record)
      case .evidence(let value): modelContext.insert(value.record)
      case .revision(let value): modelContext.insert(value.record)
      case .job(let value): modelContext.insert(value.record)
      case .audit(let value): modelContext.insert(value.record)
      }
    }
  }

  static func deleteAll(
    in modelContext: ModelContext,
    honorsCancellation: Bool
  ) throws {
    try deleteAll(
      MemoryEvidenceRecord.self,
      in: modelContext,
      honorsCancellation: honorsCancellation
    )
    try deleteAll(
      MemoryRevisionRecord.self,
      in: modelContext,
      honorsCancellation: honorsCancellation
    )
    try deleteAll(
      MemoryFormationAuditRecord.self,
      in: modelContext,
      honorsCancellation: honorsCancellation
    )
    try deleteAll(
      MemoryFormationJobRecord.self,
      in: modelContext,
      honorsCancellation: honorsCancellation
    )
    try deleteAll(
      MemoryTopicRecord.self,
      in: modelContext,
      honorsCancellation: honorsCancellation
    )
  }

  private static func decode(_ record: MosaicPortableExtensionRecord) throws -> Payload {
    guard record.namespace == namespace, record.recordVersion == recordVersion else {
      throw MosaicPortableBackupError.unsupportedExtensionRecord(
        namespace: record.namespace,
        recordType: record.recordType,
        version: record.recordVersion
      )
    }
    let decoder = JSONDecoder()
    do {
      switch record.recordType {
      case topicType:
        let payload = try decoder.decode(PortableMemoryTopic.self, from: record.payload)
        guard payload.id == record.id else { throw CocoaError(.coderInvalidValue) }
        return .topic(payload)
      case evidenceType:
        let payload = try decoder.decode(PortableMemoryEvidence.self, from: record.payload)
        guard payload.id == record.id else { throw CocoaError(.coderInvalidValue) }
        return .evidence(payload)
      case revisionType:
        let payload = try decoder.decode(PortableMemoryRevision.self, from: record.payload)
        guard payload.id == record.id else { throw CocoaError(.coderInvalidValue) }
        return .revision(payload)
      case jobType:
        let payload = try decoder.decode(PortableMemoryFormationJob.self, from: record.payload)
        guard payload.id == record.id else { throw CocoaError(.coderInvalidValue) }
        return .job(payload)
      case auditType:
        let payload = try decoder.decode(PortableMemoryFormationAudit.self, from: record.payload)
        guard payload.id == record.id else { throw CocoaError(.coderInvalidValue) }
        return .audit(payload)
      default:
        throw MosaicPortableBackupError.unsupportedExtensionRecord(
          namespace: record.namespace,
          recordType: record.recordType,
          version: record.recordVersion
        )
      }
    } catch let error as MosaicPortableBackupError {
      throw error
    } catch {
      throw MosaicPortableBackupError.invalidNormalizedInvariant(
        recordType: "memory_extension",
        id: record.id,
        field: "payload"
      )
    }
  }

  private static func append<Payload: Encodable>(
    payload: Payload,
    recordType: String,
    id: UUID,
    limits: MosaicPortableBackupLimits,
    records: inout [MosaicPortableExtensionRecord],
    approximateBytes: inout Int
  ) throws {
    guard records.count < limits.maximumRecordCount else {
      throw MosaicPortableBackupError.tooManyRecords(
        actual: records.count + 1,
        maximum: limits.maximumRecordCount
      )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    let record = MosaicPortableExtensionRecord(
      namespace: namespace,
      recordType: recordType,
      recordVersion: recordVersion,
      id: id,
      payload: data
    )
    let encodedBytes = try encoder.encode(record).count
    guard encodedBytes <= limits.maximumRecordBytes else {
      throw MosaicPortableBackupError.recordTooLarge(
        recordType: "memory_\(recordType)",
        id: id,
        actual: encodedBytes,
        maximum: limits.maximumRecordBytes
      )
    }
    let (nextBytes, overflow) = approximateBytes.addingReportingOverflow(encodedBytes)
    guard !overflow, nextBytes <= limits.maximumTotalBytes else {
      throw MosaicPortableBackupError.backupTooLarge(
        actual: overflow ? .max : nextBytes,
        maximum: limits.maximumTotalBytes
      )
    }
    approximateBytes = nextBytes
    records.append(record)
  }

  private static func encoded<Payload: Encodable>(
    _ payload: Payload,
    recordType: String,
    id: UUID
  ) throws -> MosaicPortableExtensionRecord {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return MosaicPortableExtensionRecord(
      namespace: namespace,
      recordType: recordType,
      recordVersion: recordVersion,
      id: id,
      payload: try encoder.encode(payload)
    )
  }

  private static func capturePages<Source: PersistentModel>(
    from modelContext: ModelContext,
    makeDescriptor: (UUID?) -> FetchDescriptor<Source>,
    key: (Source) -> UUID,
    includesPendingChanges: Bool,
    honorsCancellation: Bool,
    body: (Source) throws -> Void
  ) throws {
    var cursor: UUID?
    while true {
      if honorsCancellation { try Task.checkCancellation() }
      var descriptor = makeDescriptor(cursor)
      descriptor.fetchLimit = pageSize
      descriptor.includePendingChanges = includesPendingChanges
      let page = try modelContext.fetch(descriptor)
      guard !page.isEmpty else { break }
      for source in page {
        if honorsCancellation { try Task.checkCancellation() }
        try body(source)
      }
      guard let last = page.last else { break }
      let nextCursor = key(last)
      guard cursor.map({ nextCursor > $0 }) ?? true else {
        throw MosaicPortableBackupError.persistenceFailure
      }
      cursor = nextCursor
      if page.count < pageSize { break }
    }
  }

  private static func topicDescriptor(after cursor: UUID?) -> FetchDescriptor<MemoryTopicRecord> {
    if let cursor {
      return FetchDescriptor(
        predicate: #Predicate { $0.id > cursor },
        sortBy: [SortDescriptor(\MemoryTopicRecord.id)]
      )
    }
    return FetchDescriptor(sortBy: [SortDescriptor(\MemoryTopicRecord.id)])
  }

  private static func evidenceDescriptor(
    after cursor: UUID?
  ) -> FetchDescriptor<MemoryEvidenceRecord> {
    if let cursor {
      return FetchDescriptor(
        predicate: #Predicate { $0.id > cursor },
        sortBy: [SortDescriptor(\MemoryEvidenceRecord.id)]
      )
    }
    return FetchDescriptor(sortBy: [SortDescriptor(\MemoryEvidenceRecord.id)])
  }

  private static func revisionDescriptor(
    after cursor: UUID?
  ) -> FetchDescriptor<MemoryRevisionRecord> {
    if let cursor {
      return FetchDescriptor(
        predicate: #Predicate { $0.id > cursor },
        sortBy: [SortDescriptor(\MemoryRevisionRecord.id)]
      )
    }
    return FetchDescriptor(sortBy: [SortDescriptor(\MemoryRevisionRecord.id)])
  }

  private static func jobDescriptor(
    after cursor: UUID?
  ) -> FetchDescriptor<MemoryFormationJobRecord> {
    if let cursor {
      return FetchDescriptor(
        predicate: #Predicate { $0.id > cursor },
        sortBy: [SortDescriptor(\MemoryFormationJobRecord.id)]
      )
    }
    return FetchDescriptor(sortBy: [SortDescriptor(\MemoryFormationJobRecord.id)])
  }

  private static func auditDescriptor(
    after cursor: UUID?
  ) -> FetchDescriptor<MemoryFormationAuditRecord> {
    if let cursor {
      return FetchDescriptor(
        predicate: #Predicate { $0.id > cursor },
        sortBy: [SortDescriptor(\MemoryFormationAuditRecord.id)]
      )
    }
    return FetchDescriptor(sortBy: [SortDescriptor(\MemoryFormationAuditRecord.id)])
  }

  private static func deleteAll<T: PersistentModel>(
    _ type: T.Type,
    in modelContext: ModelContext,
    honorsCancellation: Bool
  ) throws {
    let descriptor = FetchDescriptor<T>()
    try modelContext.enumerate(
      descriptor,
      batchSize: pageSize,
      allowEscapingMutations: true
    ) { record in
      if honorsCancellation { try Task.checkCancellation() }
      modelContext.delete(record)
    }
  }

  private static func missing(
    recordType: String,
    id: UUID,
    field: String,
    _ targetID: UUID
  ) -> MosaicPortableBackupError {
    .missingNormalizedReference(
      recordType: recordType,
      id: id,
      field: field,
      targetID: targetID
    )
  }

  private static func invalid(
    recordType: String,
    id: UUID,
    field: String
  ) -> MosaicPortableBackupError {
    .invalidNormalizedInvariant(recordType: recordType, id: id, field: field)
  }

  private static func sourceFingerprint(for message: MosaicPortableMessage) -> String {
    AutomaticMemorySourceFingerprint.make(
      messages: [
        AutomaticMemorySourceMessage(
          id: message.id,
          role: .user,
          content: message.content,
          createdAt: message.createdAt
        )
      ]
    )
  }

  private static func evidenceExcerpt(for content: String) -> String {
    let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > maximumEvidenceExcerptCharacters else { return normalized }
    return String(normalized.prefix(maximumEvidenceExcerptCharacters - 1)) + "…"
  }

  private static func validProviderEndpoint(
    _ endpoint: String?,
    providerConfigurationID: UUID?
  ) -> Bool {
    let trimmed = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
    if endpoint != nil, trimmed?.isEmpty != false { return false }
    return providerConfigurationID == nil || trimmed?.isEmpty == false
  }
}

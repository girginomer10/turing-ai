import Foundation
import SwiftData

public enum AutomaticMemoryStoreError: Error, Equatable, LocalizedError, Sendable {
  case sourceUnavailable
  case staleSource
  case invalidOperation
  case missingTopic(UUID)
  case providerUnavailable
  case counterOverflow
  case requestAlreadyActive
  case interruptedRequestRequiresExplicitRetry

  public var errorDescription: String? {
    switch self {
    case .sourceUnavailable:
      "The completed chat turn is no longer available for memory formation."
    case .staleSource:
      "The chat changed while Turing AI was forming memory, so the stale result was discarded."
    case .invalidOperation:
      "The proposed memory change failed deterministic validation."
    case .missingTopic:
      "The proposed memory target is no longer available."
    case .providerUnavailable:
      "The provider originally used for this memory update is unavailable or disabled."
    case .counterOverflow:
      "The memory history exceeded Turing AI's supported counter range."
    case .requestAlreadyActive:
      "This automatic memory request is already running."
    case .interruptedRequestRequiresExplicitRetry:
      "Turing AI stopped an interrupted automatic memory request to avoid charging for an automatic duplicate. Retry it explicitly if you want to run it again."
    }
  }
}

/// Process-local liveness prevents another window's recovery scan from terminalizing a request
/// that is genuinely running. A hard crash clears this registry while leaving the durable audit,
/// which is exactly the signal recovery uses to prohibit an automatic paid resend.
private final class AutomaticMemoryInFlightRegistry: @unchecked Sendable {
  static let shared = AutomaticMemoryInFlightRegistry()

  private let lock = NSLock()
  private var jobIDs: Set<UUID> = []

  private init() {}

  func begin(_ jobID: UUID) -> Bool {
    lock.withLock { jobIDs.insert(jobID).inserted }
  }

  func end(_ jobID: UUID) {
    _ = lock.withLock { jobIDs.remove(jobID) }
  }

  func contains(_ jobID: UUID) -> Bool {
    lock.withLock { jobIDs.contains(jobID) }
  }
}

public struct AutomaticMemoryPendingJob: Identifiable, Hashable, Sendable {
  public let id: UUID
  public let conversationID: UUID
  public let throughUserMessageID: UUID
  public let assistantMessageID: UUID
  public let providerConfigurationID: UUID?
  public let modelIdentifier: String?
  public let status: MemoryFormationJobStatus
  public let attemptCount: Int
  public let updatedAt: Date
}

/// Owns automatic-memory source validation and the single atomic consolidation commit.
@ModelActor
public actor AutomaticMemoryStore {
  private static let maximumExistingTopics = 128
  private static let maximumExistingTopicsScanned = 5_000
  private static let maximumPendingJobs = 16
  private static let maximumEvidenceExcerptCharacters = 1_500

  public func enqueue(
    conversationID: UUID,
    throughUserMessageID: UUID,
    assistantMessageID: UUID,
    provider: ProviderConnection,
    promptVersion: String = AutomaticMemoryExtractionPrompt.version,
    now: Date = .now
  ) throws -> UUID? {
    modelContext.autosaveEnabled = false
    let source = try validatedSource(
      conversationID: conversationID,
      throughUserMessageID: throughUserMessageID,
      assistantMessageID: assistantMessageID
    )
    if let projectID = try ProjectBindingStore.projectID(
      resourceKind: .conversation,
      resourceID: conversationID,
      in: modelContext
    ), try !isActiveProject(id: projectID) {
      return nil
    }
    let fingerprint = AutomaticMemorySourceFingerprint.make(messages: [source.user])
    let key = Self.jobKey(
      promptVersion: promptVersion,
      conversationID: conversationID,
      throughUserMessageID: throughUserMessageID,
      sourceFingerprint: fingerprint
    )
    var descriptor = FetchDescriptor<MemoryFormationJobRecord>(
      predicate: #Predicate { $0.jobKey == key }
    )
    descriptor.fetchLimit = 1
    if let existing = try modelContext.fetch(descriptor).first {
      return existing.status == .complete || existing.status == .rejected ? nil : existing.id
    }

    let job = MemoryFormationJobRecord(
      jobKey: key,
      conversationID: conversationID,
      throughUserMessageID: throughUserMessageID,
      assistantMessageID: assistantMessageID,
      sourceFingerprint: fingerprint,
      promptVersion: promptVersion,
      providerConfigurationID: provider.id,
      providerKind: provider.provider,
      providerDisplayName: provider.displayName,
      modelIdentifier: provider.modelIdentifier,
      providerEndpoint: provider.credentialBinding.endpoint,
      createdAt: now,
      updatedAt: now
    )
    try MosaicSourceFieldLimits.validateMemoryFormationJob(job)
    modelContext.insert(job)
    do {
      try modelContext.save()
      return job.id
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func prepare(
    jobID: UUID,
    provider: ProviderConnection,
    now: Date = .now
  ) throws -> AutomaticMemoryFormationPreparation? {
    modelContext.autosaveEnabled = false
    guard let job = try job(id: jobID) else { return nil }
    guard job.status != .complete, job.status != .rejected else { return nil }
    guard job.providerConfigurationID == provider.id,
      job.providerKindRawValue == provider.provider.rawValue,
      job.modelIdentifier == provider.modelIdentifier,
      job.providerEndpoint == provider.credentialBinding.endpoint
    else {
      throw AutomaticMemoryStoreError.providerUnavailable
    }
    if job.status == .generating,
      let audit = try formationAudit(jobID: job.id),
      audit.attemptCount == job.attemptCount,
      audit.requestStarted
    {
      do {
        try reconcileInterruptedRequest(job: job, audit: audit, now: now)
        try modelContext.save()
      } catch {
        modelContext.rollback()
        throw error
      }
      throw AutomaticMemoryStoreError.interruptedRequestRequiresExplicitRetry
    }
    let source = try validatedSource(
      conversationID: job.conversationID,
      throughUserMessageID: job.throughUserMessageID,
      assistantMessageID: job.assistantMessageID
    )
    guard
      AutomaticMemorySourceFingerprint.make(messages: [source.user])
        == job.sourceFingerprint
    else {
      throw AutomaticMemoryStoreError.staleSource
    }
    let audience = try ProjectBindingStore.conversationScope(
      conversationID: job.conversationID,
      in: modelContext
    )
    let topics = try visibleTopics(
      conversationID: job.conversationID,
      projectID: audience.projectID
    )
    let projectName = try audience.projectID.map { try resolvedProjectName(id: $0) }

    job.markGenerating(provider: provider, at: now)
    try MosaicSourceFieldLimits.validateMemoryFormationJob(job)
    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
    return AutomaticMemoryFormationPreparation(
      jobID: job.id,
      conversationID: job.conversationID,
      throughUserMessageID: job.throughUserMessageID,
      assistantMessageID: job.assistantMessageID,
      sourceFingerprint: job.sourceFingerprint,
      messages: [source.user],
      existingTopics: topics,
      projectID: audience.projectID,
      projectName: projectName
    )
  }

  public func apply(
    _ result: AutomaticMemoryExtractionGenerationResult,
    now: Date = .now
  ) throws -> AutomaticMemoryFormationResult {
    modelContext.autosaveEnabled = false
    guard let job = try job(id: result.jobID) else {
      throw AutomaticMemoryStoreError.sourceUnavailable
    }
    if job.status == .complete { return AutomaticMemoryFormationResult() }
    guard job.status == .generating,
      job.sourceFingerprint == result.sourceFingerprint,
      job.providerConfigurationID == result.providerConfigurationID,
      job.providerKindRawValue == result.providerKind.rawValue,
      job.providerDisplayName == result.providerDisplayName,
      job.modelIdentifier == result.modelIdentifier,
      job.providerEndpoint == result.providerEndpoint
    else {
      throw AutomaticMemoryStoreError.staleSource
    }
    let source = try validatedSource(
      conversationID: job.conversationID,
      throughUserMessageID: job.throughUserMessageID,
      assistantMessageID: job.assistantMessageID
    )
    guard
      AutomaticMemorySourceFingerprint.make(messages: [source.user])
        == job.sourceFingerprint
    else {
      throw AutomaticMemoryStoreError.staleSource
    }
    let currentAudience = try ProjectBindingStore.conversationScope(
      conversationID: job.conversationID,
      in: modelContext
    )
    guard currentAudience.projectID == result.projectID else {
      throw AutomaticMemoryStoreError.staleSource
    }
    if let projectID = result.projectID,
      try !isActiveProject(id: projectID)
    {
      throw AutomaticMemoryStoreError.staleSource
    }
    guard result.envelope.schemaVersion == AutomaticMemoryExtractionEnvelope.currentSchemaVersion,
      result.envelope.operations.count <= AutomaticMemoryExtractor.maximumOperations,
      result.existingTopics.count <= Self.maximumExistingTopics
    else {
      throw AutomaticMemoryStoreError.invalidOperation
    }
    var expectedTopicsByID: [UUID: AutomaticMemoryTopicSnapshot] = [:]
    for expected in result.existingTopics {
      guard
        Self.matchesAudience(
          expected,
          conversationID: job.conversationID,
          projectID: result.projectID
        ), expectedTopicsByID.updateValue(expected, forKey: expected.id) == nil
      else {
        throw AutomaticMemoryStoreError.invalidOperation
      }
    }

    var createdCount = 0
    var updatedCount = 0
    var reinforcedCount = 0
    var forgottenCount = 0
    var operationKeys: Set<String> = []

    do {
      for operation in result.envelope.operations {
        guard Set(operation.evidenceMessageIDs) == Set([source.user.id]),
          operation.evidenceMessageIDs.count == 1,
          result.projectID == nil || operation.scope != .global || operation.targetID != nil,
          operation.action != .upsert
            || (operation.confidence >= AutomaticMemoryExtractor.minimumUpsertConfidence
              && (operation.kind != .event
                || (operation.stability == .evolving && operation.confidence >= 0.75))
              && !AutomaticMemoryExtractor.containsLikelySecret(operation))
        else {
          throw AutomaticMemoryStoreError.invalidOperation
        }
        let canonicalKey = try Self.canonicalKey(
          proposed: operation.canonicalKey,
          kind: operation.kind,
          scope: operation.scope,
          conversationID: job.conversationID,
          projectID: result.projectID
        )
        guard operationKeys.insert(canonicalKey).inserted else {
          throw AutomaticMemoryStoreError.invalidOperation
        }
        var topic = try resolveTopic(
          targetID: operation.targetID,
          canonicalKey: canonicalKey,
          kind: operation.kind,
          conversationID: job.conversationID,
          projectID: result.projectID,
          scope: operation.scope
        )
        if let topic {
          guard let expected = expectedTopicsByID[topic.id],
            try matchesCurrentState(topic, expected: expected)
          else {
            throw AutomaticMemoryStoreError.staleSource
          }
        }

        if operation.action == .forget, topic == nil {
          continue
        }
        if let topic, topic.origin == .manual {
          let isSafeReinforcement =
            operation.action == .upsert
            && topic.status == .active
            && Self.normalizedValue(topic.content) == Self.normalizedValue(operation.content)
          if !isSafeReinforcement {
            guard operation.targetID == topic.id else {
              throw AutomaticMemoryStoreError.invalidOperation
            }
            if operation.action == .upsert,
              Self.normalizedValue(topic.content) != Self.normalizedValue(operation.content),
              operation.confidence < AutomaticMemoryExtractor.minimumManualOverrideConfidence
            {
              throw AutomaticMemoryStoreError.invalidOperation
            }
          }
        }
        if let topic, topic.kind == .event, source.user.createdAt < topic.lastConfirmedAt {
          // A delayed older report cannot overwrite a later resolution or refresh its recency.
          continue
        }
        var wasCreated = false
        if operation.action == .upsert, topic == nil {
          let created = MemoryTopicRecord(
            canonicalKey: canonicalKey,
            title: operation.title,
            content: operation.content,
            kind: operation.kind,
            scope: operation.scope,
            conversationID: operation.scope == .conversation ? job.conversationID : nil,
            confidence: operation.confidence,
            importance: operation.importance,
            stability: operation.stability,
            lastConfirmedAt: now,
            createdAt: now,
            updatedAt: now
          )
          try MosaicSourceFieldLimits.validateMemoryTopic(created)
          modelContext.insert(created)
          if operation.scope == .project {
            guard let projectID = result.projectID else {
              throw AutomaticMemoryStoreError.invalidOperation
            }
            modelContext.insert(
              ProjectResourceBindingRecord(
                resourceKind: .memoryTopic,
                resourceID: created.id,
                projectID: projectID,
                createdAt: now,
                updatedAt: now
              )
            )
          }
          topic = created
          wasCreated = true
          createdCount += 1
        }
        guard let topic else { continue }

        let evidence = try insertEvidenceIfNeeded(
          operation: operation,
          topic: topic,
          job: job,
          source: source.user,
          result: result,
          now: now
        )
        let addedEvidenceCount = evidence == nil ? 0 : 1
        guard topic.evidenceCount <= Int.max - addedEvidenceCount else {
          throw AutomaticMemoryStoreError.counterOverflow
        }

        let previousTitle: String?
        let previousContent: String?
        let nextRevision: Int
        let revisionKind: MemoryRevisionKind
        if wasCreated {
          guard operation.action == .upsert, addedEvidenceCount == 1 else {
            throw AutomaticMemoryStoreError.invalidOperation
          }
          previousTitle = nil
          previousContent = nil
          nextRevision = 1
          revisionKind = .created
          topic.apply(
            title: operation.title,
            content: operation.content,
            confidence: operation.confidence,
            importance: operation.importance,
            stability: operation.stability,
            status: .active,
            isEnabled: true,
            evidenceCount: addedEvidenceCount,
            revision: nextRevision,
            at: now
          )
        } else {
          guard topic.revision < Int.max else {
            throw AutomaticMemoryStoreError.counterOverflow
          }
          previousTitle = topic.title
          previousContent = topic.content
          nextRevision = topic.revision + 1
          switch operation.action {
          case .forget:
            revisionKind = .forgotten
            topic.apply(
              title: topic.title,
              content: topic.content,
              confidence: topic.confidence,
              importance: topic.importance,
              stability: topic.stability,
              status: .forgotten,
              isEnabled: false,
              evidenceCount: topic.evidenceCount + addedEvidenceCount,
              revision: nextRevision,
              at: now
            )
            forgottenCount += 1

          case .upsert:
            let sameValue =
              Self.normalizedValue(topic.content)
              == Self.normalizedValue(operation.content)
            // A user-paused active topic stays paused. Only an explicit restatement after a
            // forgotten topic reactivates it; background consolidation must not undo UI intent.
            let shouldEnable = topic.status == .forgotten ? true : topic.isEnabled
            if sameValue, topic.status == .active {
              revisionKind = .reinforced
              let preservesManualCorrection = topic.origin == .manual
              topic.apply(
                title: preservesManualCorrection ? topic.title : operation.title,
                content: preservesManualCorrection ? topic.content : operation.content,
                confidence: preservesManualCorrection
                  ? 1
                  : Self.reinforcedConfidence(
                    existing: topic.confidence,
                    incoming: operation.confidence
                  ),
                importance: max(topic.importance, operation.importance),
                stability: Self.moreStable(topic.stability, operation.stability),
                status: .active,
                isEnabled: shouldEnable,
                evidenceCount: topic.evidenceCount + addedEvidenceCount,
                revision: nextRevision,
                at: now
              )
              reinforcedCount += 1
            } else {
              revisionKind = topic.status == .forgotten ? .reactivated : .updated
              topic.apply(
                title: operation.title,
                content: operation.content,
                confidence: operation.confidence,
                importance: max(topic.importance, operation.importance),
                stability: operation.stability,
                status: .active,
                isEnabled: shouldEnable,
                evidenceCount: topic.evidenceCount + addedEvidenceCount,
                revision: nextRevision,
                at: now
              )
              topic.setOrigin(.automatic)
              updatedCount += 1
            }
          }
        }

        topic.setEventReportDate(source.user.createdAt)
        try MosaicSourceFieldLimits.validateMemoryTopic(topic)
        let revision = MemoryRevisionRecord(
          revisionKey: "\(topic.id.uuidString.lowercased())/\(nextRevision)",
          topicID: topic.id,
          sequence: nextRevision,
          kind: revisionKind,
          previousTitle: previousTitle,
          previousContent: previousContent,
          title: topic.title,
          content: topic.content,
          sourceEvidenceID: evidence?.id,
          createdAt: now
        )
        try MosaicSourceFieldLimits.validateMemoryRevision(revision)
        modelContext.insert(revision)
      }

      let outputData = try Self.outputData(result.envelope)
      job.markComplete(
        outputFingerprint: EmbeddingVectorCodec.fingerprint(
          for: String(decoding: outputData, as: UTF8.self)
        ),
        at: now
      )
      try MosaicSourceFieldLimits.validateMemoryFormationJob(job)
      try upsertFormationAudit(
        for: job,
        outcome: .complete,
        providerMessageID: result.providerMessageID,
        requestStarted: result.requestStarted,
        inputTokenCount: result.inputTokenCount,
        outputTokenCount: result.outputTokenCount,
        didDiscardInvalidTelemetry: result.didDiscardInvalidTelemetry,
        errorDescription: nil,
        now: now
      )
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }

    return AutomaticMemoryFormationResult(
      createdCount: createdCount,
      updatedCount: updatedCount,
      reinforcedCount: reinforcedCount,
      forgottenCount: forgottenCount
    )
  }

  /// Commits the paid-request boundary before `AIProviderClient.stream` is allowed to open.
  /// A current-attempt receipt can be created only once, preventing an accidental duplicate call.
  public func markRequestStarted(
    jobID: UUID,
    provider: ProviderConnection,
    expectedProjectID: UUID?,
    now: Date = .now
  ) throws {
    modelContext.autosaveEnabled = false
    guard let job = try job(id: jobID), job.status == .generating,
      job.providerConfigurationID == provider.id,
      job.providerKindRawValue == provider.provider.rawValue,
      job.providerDisplayName == provider.displayName,
      job.modelIdentifier == provider.modelIdentifier,
      job.providerEndpoint == provider.credentialBinding.endpoint,
      job.attemptCount > 0
    else {
      throw AutomaticMemoryStoreError.staleSource
    }
    let audience = try ProjectBindingStore.conversationScope(
      conversationID: job.conversationID,
      in: modelContext
    )
    guard audience.projectID == expectedProjectID else {
      throw AutomaticMemoryStoreError.staleSource
    }
    if let expectedProjectID, try !isActiveProject(id: expectedProjectID) {
      throw AutomaticMemoryStoreError.staleSource
    }
    if let audit = try formationAudit(jobID: job.id),
      audit.attemptCount == job.attemptCount,
      audit.requestStarted
    {
      throw AutomaticMemoryStoreError.interruptedRequestRequiresExplicitRetry
    }

    do {
      job.markRequestOpened(at: now)
      try MosaicSourceFieldLimits.validateMemoryFormationJob(job)
      try upsertFormationAudit(
        for: job,
        outcome: .generating,
        providerMessageID: nil,
        requestStarted: true,
        inputTokenCount: nil,
        outputTokenCount: nil,
        didDiscardInvalidTelemetry: false,
        errorDescription: nil,
        now: now
      )
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  /// Checkpoints provider-reported usage while the request is in flight. Each update replaces the
  /// latest attempt values and adjusts all-time totals by delta, so repeated cumulative events do
  /// not double-count tokens.
  public func recordAttemptTelemetry(
    jobID: UUID,
    provider: ProviderConnection,
    telemetry: AutomaticMemoryExtractionAttemptTelemetry,
    now: Date = .now
  ) throws {
    modelContext.autosaveEnabled = false
    guard telemetry.requestStarted,
      let job = try job(id: jobID), job.status == .generating,
      job.providerConfigurationID == provider.id,
      job.providerKindRawValue == provider.provider.rawValue,
      job.providerDisplayName == provider.displayName,
      job.modelIdentifier == provider.modelIdentifier,
      job.providerEndpoint == provider.credentialBinding.endpoint,
      let audit = try formationAudit(jobID: jobID),
      audit.attemptCount == job.attemptCount,
      audit.requestStarted
    else {
      throw AutomaticMemoryStoreError.staleSource
    }

    do {
      try upsertFormationAudit(
        for: job,
        outcome: .generating,
        providerMessageID: telemetry.providerMessageID,
        requestStarted: true,
        inputTokenCount: telemetry.inputTokenCount,
        outputTokenCount: telemetry.outputTokenCount,
        didDiscardInvalidTelemetry: telemetry.didDiscardInvalidTelemetry,
        errorDescription: nil,
        now: now
      )
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func markFailed(
    jobID: UUID,
    error: Error,
    redacting secret: String? = nil,
    telemetry: AutomaticMemoryExtractionAttemptTelemetry? = nil,
    now: Date = .now
  ) throws {
    try markTerminalFailure(
      jobID: jobID,
      outcome: .failed,
      error: error,
      redacting: secret,
      telemetry: telemetry,
      now: now
    )
  }

  public func markRejected(
    jobID: UUID,
    error: Error,
    redacting secret: String? = nil,
    telemetry: AutomaticMemoryExtractionAttemptTelemetry? = nil,
    now: Date = .now
  ) throws {
    try markTerminalFailure(
      jobID: jobID,
      outcome: .rejected,
      error: error,
      redacting: secret,
      telemetry: telemetry,
      now: now
    )
  }

  private func markTerminalFailure(
    jobID: UUID,
    outcome: MemoryFormationJobStatus,
    error: Error,
    redacting secret: String?,
    telemetry: AutomaticMemoryExtractionAttemptTelemetry?,
    now: Date
  ) throws {
    precondition(outcome == .failed || outcome == .rejected)
    guard let job = try job(id: jobID), job.status != .complete else { return }
    // Higher-level recovery catches may still call `markFailed` after the coordinator persisted an
    // immutable local rejection. Never turn that terminal receipt back into a retryable job.
    guard job.status != .rejected || outcome == .rejected else { return }
    let existingAudit = try formationAudit(jobID: jobID)
    if job.status == outcome, existingAudit != nil {
      return
    }
    let sanitized = ProviderErrorSanitizer.description(for: error, redacting: secret)
    let boundedMessage = Self.boundedUTF8(
      sanitized,
      maximumBytes: MosaicSourceFieldLimits.maximumMemoryFormationErrorUTF8Bytes
    )
    let message =
      boundedMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Memory formation failed."
      : boundedMessage
    do {
      if outcome == .rejected {
        job.markRejected(message, at: now)
      } else {
        job.markFailed(message, at: now)
      }
      try MosaicSourceFieldLimits.validateMemoryFormationJob(job)
      let currentAttemptAudit = existingAudit.flatMap { audit in
        audit.attemptCount == job.attemptCount ? audit : nil
      }
      let telemetry = AutomaticMemoryExtractionAttemptTelemetry(
        requestStarted: telemetry?.requestStarted == true
          || currentAttemptAudit?.requestStarted == true,
        providerMessageID: telemetry?.providerMessageID ?? currentAttemptAudit?.providerMessageID,
        inputTokenCount: telemetry?.inputTokenCount ?? currentAttemptAudit?.inputTokenCount,
        outputTokenCount: telemetry?.outputTokenCount ?? currentAttemptAudit?.outputTokenCount,
        discardedInvalidUsage: telemetry?.discardedInvalidUsage == true
          || currentAttemptAudit?.didDiscardInvalidTelemetry == true,
        discardedInvalidProviderMessageID: telemetry?.discardedInvalidProviderMessageID == true
          || currentAttemptAudit?.didDiscardInvalidTelemetry == true
      )
      try upsertFormationAudit(
        for: job,
        outcome: outcome,
        providerMessageID: telemetry.providerMessageID,
        requestStarted: telemetry.requestStarted,
        inputTokenCount: telemetry.inputTokenCount,
        outputTokenCount: telemetry.outputTokenCount,
        didDiscardInvalidTelemetry: telemetry.didDiscardInvalidTelemetry,
        errorDescription: message,
        now: now
      )
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func pendingJobs(now: Date = .now) throws -> [AutomaticMemoryPendingJob] {
    modelContext.autosaveEnabled = false
    let pending = MemoryFormationJobStatus.pending.rawValue
    let generating = MemoryFormationJobStatus.generating.rawValue
    var descriptor = FetchDescriptor<MemoryFormationJobRecord>(
      predicate: #Predicate {
        $0.statusRawValue == pending || $0.statusRawValue == generating
      },
      sortBy: [
        SortDescriptor(\MemoryFormationJobRecord.updatedAt),
        SortDescriptor(\MemoryFormationJobRecord.id),
      ]
    )
    descriptor.fetchLimit = Self.maximumPendingJobs
    descriptor.includePendingChanges = false
    let jobs = try modelContext.fetch(descriptor)
    var result: [AutomaticMemoryPendingJob] = []
    do {
      for job in jobs {
        if job.status == .generating {
          if AutomaticMemoryInFlightRegistry.shared.contains(job.id) {
            continue
          }
          if let audit = try formationAudit(jobID: job.id),
            audit.attemptCount == job.attemptCount,
            audit.requestStarted
          {
            try reconcileInterruptedRequest(job: job, audit: audit, now: now)
            continue
          }
        }
        result.append(
          AutomaticMemoryPendingJob(
            id: job.id,
            conversationID: job.conversationID,
            throughUserMessageID: job.throughUserMessageID,
            assistantMessageID: job.assistantMessageID,
            providerConfigurationID: job.providerConfigurationID,
            modelIdentifier: job.modelIdentifier,
            status: job.status,
            attemptCount: job.attemptCount,
            updatedAt: job.updatedAt
          )
        )
      }
      if modelContext.hasChanges {
        try modelContext.save()
      }
      return result
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  /// Converts dormant jobs into immutable provenance before their provider configuration is
  /// removed. This mutates only the supplied source context: the caller must delete the provider
  /// record and save both changes in the same synchronous transaction. A live provider request is
  /// rejected before any model is changed.
  @MainActor
  static func abandonRetryableJobsForProviderDeletion(
    providerConfigurationID: UUID,
    in modelContext: ModelContext,
    now: Date = .now
  ) throws -> Int {
    let providerID = providerConfigurationID
    let pending = MemoryFormationJobStatus.pending.rawValue
    let generating = MemoryFormationJobStatus.generating.rawValue
    let failed = MemoryFormationJobStatus.failed.rawValue
    let descriptor = FetchDescriptor<MemoryFormationJobRecord>(
      predicate: #Predicate {
        $0.providerConfigurationID == providerID
          && ($0.statusRawValue == pending || $0.statusRawValue == generating
            || $0.statusRawValue == failed)
      },
      sortBy: [SortDescriptor(\MemoryFormationJobRecord.id)]
    )
    let jobs = try modelContext.fetch(descriptor)
    guard !jobs.contains(where: { AutomaticMemoryInFlightRegistry.shared.contains($0.id) }) else {
      throw AutomaticMemoryStoreError.requestAlreadyActive
    }
    guard !jobs.isEmpty else { return 0 }

    let jobIDs = jobs.map(\.id)
    let audits = try modelContext.fetch(
      FetchDescriptor<MemoryFormationAuditRecord>(
        predicate: #Predicate { jobIDs.contains($0.jobID) }
      )
    )
    let auditsByJobID = Dictionary(uniqueKeysWithValues: audits.map { ($0.jobID, $0) })
    let message =
      "This automatic memory job was abandoned because its provider configuration was deleted."

    for job in jobs {
      let audit = auditsByJobID[job.id]
      guard audit == nil || (audit?.jobKey == job.jobKey && audit?.attemptCount == job.attemptCount)
      else {
        throw AutomaticMemoryStoreError.invalidOperation
      }
      job.markRejected(message, at: now)
      try MosaicSourceFieldLimits.validateMemoryFormationJob(job)

      if let audit {
        audit.replace(
          attemptCount: job.attemptCount,
          outcome: .rejected,
          providerConfigurationID: job.providerConfigurationID,
          providerKind: job.providerKindRawValue.flatMap(ProviderKind.init(rawValue:)),
          providerDisplayName: job.providerDisplayName,
          modelIdentifier: job.modelIdentifier,
          providerEndpoint: job.providerEndpoint,
          providerMessageID: audit.providerMessageID,
          requestStarted: audit.requestStarted,
          inputTokenCount: audit.inputTokenCount,
          outputTokenCount: audit.outputTokenCount,
          providerRequestCount: audit.providerRequestCount,
          cumulativeInputTokenCount: audit.cumulativeInputTokenCount,
          cumulativeOutputTokenCount: audit.cumulativeOutputTokenCount,
          didDiscardInvalidTelemetry: audit.didDiscardInvalidTelemetry,
          errorDescription: message,
          startedAt: job.startedAt,
          finishedAt: now
        )
        try MosaicSourceFieldLimits.validateMemoryFormationAudit(audit)
      } else {
        let audit = MemoryFormationAuditRecord(
          jobID: job.id,
          jobKey: job.jobKey,
          attemptCount: job.attemptCount,
          outcome: .rejected,
          providerConfigurationID: job.providerConfigurationID,
          providerKind: job.providerKindRawValue.flatMap(ProviderKind.init(rawValue:)),
          providerDisplayName: job.providerDisplayName,
          modelIdentifier: job.modelIdentifier,
          providerEndpoint: job.providerEndpoint,
          providerMessageID: nil,
          requestStarted: false,
          inputTokenCount: nil,
          outputTokenCount: nil,
          providerRequestCount: 0,
          cumulativeInputTokenCount: 0,
          cumulativeOutputTokenCount: 0,
          didDiscardInvalidTelemetry: false,
          errorDescription: message,
          startedAt: job.startedAt,
          finishedAt: now,
          createdAt: now,
          updatedAt: now
        )
        try MosaicSourceFieldLimits.validateMemoryFormationAudit(audit)
        modelContext.insert(audit)
      }
    }
    return jobs.count
  }

  public func recordUse(topicIDs: Set<UUID>, at date: Date = .now) throws {
    guard !topicIDs.isEmpty else { return }
    let ids = Array(topicIDs)
    let descriptor = FetchDescriptor<MemoryTopicRecord>(
      predicate: #Predicate { ids.contains($0.id) }
    )
    let topics = try modelContext.fetch(descriptor)
    for topic in topics where topic.status == .active && topic.isEnabled {
      topic.recordUse(at: date)
      try MosaicSourceFieldLimits.validateMemoryTopic(topic)
    }
    guard modelContext.hasChanges else { return }
    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  private func validatedSource(
    conversationID: UUID,
    throughUserMessageID: UUID,
    assistantMessageID: UUID
  ) throws -> (user: AutomaticMemorySourceMessage, assistant: MessageRecord) {
    var userDescriptor = FetchDescriptor<MessageRecord>(
      predicate: #Predicate { $0.id == throughUserMessageID }
    )
    userDescriptor.fetchLimit = 1
    userDescriptor.includePendingChanges = false
    var assistantDescriptor = FetchDescriptor<MessageRecord>(
      predicate: #Predicate { $0.id == assistantMessageID }
    )
    assistantDescriptor.fetchLimit = 1
    assistantDescriptor.includePendingChanges = false
    guard let user = try modelContext.fetch(userDescriptor).first,
      let assistant = try modelContext.fetch(assistantDescriptor).first,
      user.conversationID == conversationID,
      assistant.conversationID == conversationID,
      user.role == .user,
      user.status == .complete,
      assistant.role == .assistant,
      assistant.status == .complete,
      !user.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw AutomaticMemoryStoreError.sourceUnavailable
    }
    return (
      AutomaticMemorySourceMessage(
        id: user.id,
        role: .user,
        content: user.content,
        createdAt: user.createdAt
      ),
      assistant
    )
  }

  private func resolveTopic(
    targetID: UUID?,
    canonicalKey: String,
    kind: MemoryTopicKind,
    conversationID: UUID,
    projectID: UUID?,
    scope: MemoryScope
  ) throws -> MemoryTopicRecord? {
    if let targetID {
      var descriptor = FetchDescriptor<MemoryTopicRecord>(
        predicate: #Predicate { $0.id == targetID }
      )
      descriptor.fetchLimit = 1
      guard let topic = try modelContext.fetch(descriptor).first else {
        throw AutomaticMemoryStoreError.missingTopic(targetID)
      }
      guard topic.scope == scope,
        topic.kind == kind,
        topic.canonicalKey == canonicalKey,
        try topicMatchesAudience(
          topic,
          conversationID: conversationID,
          projectID: projectID
        )
      else {
        throw AutomaticMemoryStoreError.invalidOperation
      }
      return topic
    }
    var descriptor = FetchDescriptor<MemoryTopicRecord>(
      predicate: #Predicate { $0.canonicalKey == canonicalKey }
    )
    descriptor.fetchLimit = 1
    guard let topic = try modelContext.fetch(descriptor).first else { return nil }
    guard topic.kind == kind,
      topic.scope == scope,
      try topicMatchesAudience(
        topic,
        conversationID: conversationID,
        projectID: projectID
      )
    else {
      throw AutomaticMemoryStoreError.invalidOperation
    }
    return topic
  }

  private func topicMatchesAudience(
    _ topic: MemoryTopicRecord,
    conversationID: UUID,
    projectID: UUID?
  ) throws -> Bool {
    let boundProjectID = try ProjectBindingStore.projectID(
      resourceKind: .memoryTopic,
      resourceID: topic.id,
      in: modelContext
    )
    switch topic.scope {
    case .global:
      return topic.conversationID == nil && boundProjectID == nil
    case .project:
      return topic.conversationID == nil
        && boundProjectID != nil
        && boundProjectID == projectID
    case .conversation:
      return topic.conversationID == conversationID && boundProjectID == nil
    }
  }

  private func visibleTopics(
    conversationID: UUID,
    projectID: UUID?
  ) throws -> [AutomaticMemoryTopicSnapshot] {
    let globalScope = MemoryScope.global.rawValue
    let conversationScope = MemoryScope.conversation.rawValue
    let activeStatus = MemoryTopicStatus.active.rawValue
    var globalDescriptor = FetchDescriptor<MemoryTopicRecord>(
      predicate: #Predicate {
        $0.scopeRawValue == globalScope && $0.conversationID == nil
          && $0.statusRawValue == activeStatus && $0.isEnabled
      },
      sortBy: [
        SortDescriptor(\MemoryTopicRecord.updatedAt, order: .reverse),
        SortDescriptor(\MemoryTopicRecord.id),
      ]
    )
    globalDescriptor.fetchLimit = Self.maximumExistingTopicsScanned
    globalDescriptor.includePendingChanges = false
    let globalTopics = try modelContext.fetch(globalDescriptor)

    var conversationDescriptor = FetchDescriptor<MemoryTopicRecord>(
      predicate: #Predicate {
        $0.scopeRawValue == conversationScope && $0.conversationID == conversationID
          && $0.statusRawValue == activeStatus && $0.isEnabled
      },
      sortBy: [
        SortDescriptor(\MemoryTopicRecord.updatedAt, order: .reverse),
        SortDescriptor(\MemoryTopicRecord.id),
      ]
    )
    conversationDescriptor.fetchLimit = Self.maximumExistingTopicsScanned
    conversationDescriptor.includePendingChanges = false
    let conversationTopics = try modelContext.fetch(conversationDescriptor)

    let directTopics = globalTopics + conversationTopics
    let directProjectIDs = try ProjectBindingStore.projectIDs(
      resourceKind: .memoryTopic,
      resourceIDs: directTopics.map(\.id),
      in: modelContext
    )
    var candidates = directTopics.filter { directProjectIDs[$0.id] == nil }

    if let projectID {
      let topicKind = ProjectResourceKind.memoryTopic.rawValue
      var bindingDescriptor = FetchDescriptor<ProjectResourceBindingRecord>(
        predicate: #Predicate {
          $0.projectID == projectID && $0.resourceKindRawValue == topicKind
        },
        sortBy: [SortDescriptor(\ProjectResourceBindingRecord.id)]
      )
      bindingDescriptor.fetchLimit = Self.maximumExistingTopicsScanned + 1
      bindingDescriptor.includePendingChanges = false
      let bindings = try modelContext.fetch(bindingDescriptor)
      guard bindings.count <= Self.maximumExistingTopicsScanned else {
        throw AutomaticMemoryStoreError.invalidOperation
      }
      var projectTopicsByID: [UUID: MemoryTopicRecord] = [:]
      for page in bindings.map(\.resourceID).chunked(maximumCount: 128) {
        let ids = page
        var topicDescriptor = FetchDescriptor<MemoryTopicRecord>(
          predicate: #Predicate { ids.contains($0.id) }
        )
        topicDescriptor.includePendingChanges = false
        for topic in try modelContext.fetch(topicDescriptor) {
          guard projectTopicsByID.updateValue(topic, forKey: topic.id) == nil else {
            throw AutomaticMemoryStoreError.invalidOperation
          }
        }
      }
      guard projectTopicsByID.count == bindings.count,
        projectTopicsByID.values.allSatisfy({
          $0.scope == .project && $0.conversationID == nil
        })
      else {
        throw AutomaticMemoryStoreError.invalidOperation
      }
      candidates.append(
        contentsOf: projectTopicsByID.values.filter {
          $0.status == .active && $0.isEnabled
        })
    }

    return candidates.sorted {
      if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
      return $0.id < $1.id
    }.prefix(Self.maximumExistingTopics).map { topic in
      topic.snapshot(projectID: topic.scope == .project ? projectID : nil)
    }
  }

  private func resolvedProjectName(id: UUID) throws -> String {
    var descriptor = FetchDescriptor<ProjectRecord>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    guard let project = try modelContext.fetch(descriptor).first, !project.isArchived else {
      throw ProjectBindingError.projectUnavailable(id)
    }
    return project.name
  }

  private func isActiveProject(id: UUID) throws -> Bool {
    var descriptor = FetchDescriptor<ProjectRecord>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first.map { !$0.isArchived } ?? false
  }

  private func insertEvidenceIfNeeded(
    operation: AutomaticMemoryExtractionOperation,
    topic: MemoryTopicRecord,
    job: MemoryFormationJobRecord,
    source: AutomaticMemorySourceMessage,
    result: AutomaticMemoryExtractionGenerationResult,
    now: Date
  ) throws -> MemoryEvidenceRecord? {
    guard operation.evidenceMessageIDs.contains(source.id) else {
      throw AutomaticMemoryStoreError.invalidOperation
    }
    let key =
      "\(topic.id.uuidString.lowercased())/\(source.id.uuidString.lowercased())/\(job.sourceFingerprint)"
    var descriptor = FetchDescriptor<MemoryEvidenceRecord>(
      predicate: #Predicate { $0.evidenceKey == key }
    )
    descriptor.fetchLimit = 1
    if try modelContext.fetch(descriptor).first != nil { return nil }

    let evidence = MemoryEvidenceRecord(
      evidenceKey: key,
      topicID: topic.id,
      conversationID: job.conversationID,
      sourceMessageID: source.id,
      assistantMessageID: job.assistantMessageID,
      excerpt: Self.boundedExcerpt(source.content),
      sourceFingerprint: job.sourceFingerprint,
      providerConfigurationID: result.providerConfigurationID,
      providerKind: result.providerKind,
      providerDisplayName: result.providerDisplayName,
      modelIdentifier: result.modelIdentifier,
      providerEndpoint: result.providerEndpoint,
      confidence: operation.confidence,
      createdAt: now
    )
    try MosaicSourceFieldLimits.validateMemoryEvidence(evidence)
    modelContext.insert(evidence)
    return evidence
  }

  private func job(id: UUID) throws -> MemoryFormationJobRecord? {
    var descriptor = FetchDescriptor<MemoryFormationJobRecord>(
      predicate: #Predicate { $0.id == id }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func formationAudit(jobID: UUID) throws -> MemoryFormationAuditRecord? {
    var descriptor = FetchDescriptor<MemoryFormationAuditRecord>(
      predicate: #Predicate { $0.jobID == jobID }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func reconcileInterruptedRequest(
    job: MemoryFormationJobRecord,
    audit: MemoryFormationAuditRecord,
    now: Date
  ) throws {
    guard job.status == .generating,
      audit.jobID == job.id,
      audit.jobKey == job.jobKey,
      audit.attemptCount == job.attemptCount,
      audit.requestStarted
    else {
      throw AutomaticMemoryStoreError.invalidOperation
    }
    let message =
      "Turing AI found an interrupted automatic memory request. It was not retried automatically to avoid a duplicate provider charge."
    job.markFailed(message, at: now)
    try MosaicSourceFieldLimits.validateMemoryFormationJob(job)
    try upsertFormationAudit(
      for: job,
      outcome: .failed,
      providerMessageID: audit.providerMessageID,
      requestStarted: true,
      inputTokenCount: audit.inputTokenCount,
      outputTokenCount: audit.outputTokenCount,
      didDiscardInvalidTelemetry: audit.didDiscardInvalidTelemetry,
      errorDescription: message,
      now: now
    )
  }

  private func upsertFormationAudit(
    for job: MemoryFormationJobRecord,
    outcome: MemoryFormationJobStatus,
    providerMessageID: String?,
    requestStarted: Bool,
    inputTokenCount: Int?,
    outputTokenCount: Int?,
    didDiscardInvalidTelemetry: Bool,
    errorDescription: String?,
    now: Date
  ) throws {
    var discardedInvalidTelemetry = didDiscardInvalidTelemetry
    let boundedProviderMessageID: String?
    if let providerMessageID {
      let trimmed = providerMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty,
        providerMessageID.utf8.count <= MosaicSourceFieldLimits.maximumMemoryProvenanceUTF8Bytes
      {
        boundedProviderMessageID = providerMessageID
      } else {
        boundedProviderMessageID = nil
        discardedInvalidTelemetry = true
      }
    } else {
      boundedProviderMessageID = nil
    }
    func boundedTokenCount(_ value: Int?) -> Int? {
      guard let value else { return nil }
      guard (0...1_000_000_000).contains(value) else {
        discardedInvalidTelemetry = true
        return nil
      }
      return value
    }
    let boundedInputTokenCount = boundedTokenCount(inputTokenCount)
    let boundedOutputTokenCount = boundedTokenCount(outputTokenCount)
    let providerKind = job.providerKindRawValue.flatMap(ProviderKind.init(rawValue:))

    if let audit = try formationAudit(jobID: job.id) {
      guard audit.jobKey == job.jobKey, job.attemptCount >= audit.attemptCount else {
        throw AutomaticMemoryStoreError.invalidOperation
      }
      discardedInvalidTelemetry =
        discardedInvalidTelemetry || audit.didDiscardInvalidTelemetry
      let isNewAttempt = job.attemptCount > audit.attemptCount
      let latestProviderMessageID =
        boundedProviderMessageID ?? (isNewAttempt ? nil : audit.providerMessageID)
      let latestInputTokenCount =
        boundedInputTokenCount ?? (isNewAttempt ? nil : audit.inputTokenCount)
      let latestOutputTokenCount =
        boundedOutputTokenCount ?? (isNewAttempt ? nil : audit.outputTokenCount)
      let latestRequestStarted = requestStarted || (!isNewAttempt && audit.requestStarted)
      func cumulativeCount(existing: Int, replacing previous: Int?, with value: Int?) -> Int {
        let base: Int
        if isNewAttempt {
          base = existing
        } else {
          let previous = previous ?? 0
          guard previous <= existing else {
            discardedInvalidTelemetry = true
            return existing
          }
          base = existing - previous
        }
        guard let value else { return base }
        let (total, overflow) = base.addingReportingOverflow(value)
        if overflow {
          discardedInvalidTelemetry = true
          return Int.max
        }
        return total
      }
      let cumulativeInputTokenCount = cumulativeCount(
        existing: audit.cumulativeInputTokenCount,
        replacing: audit.inputTokenCount,
        with: latestInputTokenCount
      )
      let cumulativeOutputTokenCount = cumulativeCount(
        existing: audit.cumulativeOutputTokenCount,
        replacing: audit.outputTokenCount,
        with: latestOutputTokenCount
      )
      var providerRequestCount = audit.providerRequestCount
      if isNewAttempt, latestRequestStarted {
        if providerRequestCount < Int.max {
          providerRequestCount += 1
        } else {
          discardedInvalidTelemetry = true
        }
      }
      audit.replace(
        attemptCount: job.attemptCount,
        outcome: outcome,
        providerConfigurationID: job.providerConfigurationID,
        providerKind: providerKind,
        providerDisplayName: job.providerDisplayName,
        modelIdentifier: job.modelIdentifier,
        providerEndpoint: job.providerEndpoint,
        providerMessageID: latestProviderMessageID,
        requestStarted: latestRequestStarted,
        inputTokenCount: latestInputTokenCount,
        outputTokenCount: latestOutputTokenCount,
        providerRequestCount: providerRequestCount,
        cumulativeInputTokenCount: cumulativeInputTokenCount,
        cumulativeOutputTokenCount: cumulativeOutputTokenCount,
        didDiscardInvalidTelemetry: discardedInvalidTelemetry,
        errorDescription: errorDescription,
        startedAt: job.startedAt,
        finishedAt: now
      )
      try MosaicSourceFieldLimits.validateMemoryFormationAudit(audit)
      return
    }

    let audit = MemoryFormationAuditRecord(
      jobID: job.id,
      jobKey: job.jobKey,
      attemptCount: job.attemptCount,
      outcome: outcome,
      providerConfigurationID: job.providerConfigurationID,
      providerKind: providerKind,
      providerDisplayName: job.providerDisplayName,
      modelIdentifier: job.modelIdentifier,
      providerEndpoint: job.providerEndpoint,
      providerMessageID: boundedProviderMessageID,
      requestStarted: requestStarted,
      inputTokenCount: boundedInputTokenCount,
      outputTokenCount: boundedOutputTokenCount,
      providerRequestCount: requestStarted ? 1 : 0,
      cumulativeInputTokenCount: boundedInputTokenCount ?? 0,
      cumulativeOutputTokenCount: boundedOutputTokenCount ?? 0,
      didDiscardInvalidTelemetry: discardedInvalidTelemetry,
      errorDescription: errorDescription,
      startedAt: job.startedAt,
      finishedAt: now,
      createdAt: now,
      updatedAt: now
    )
    try MosaicSourceFieldLimits.validateMemoryFormationAudit(audit)
    modelContext.insert(audit)
  }

  private static func jobKey(
    promptVersion: String,
    conversationID: UUID,
    throughUserMessageID: UUID,
    sourceFingerprint: String
  ) -> String {
    EmbeddingVectorCodec.fingerprint(
      for:
        "\(promptVersion)|\(conversationID.uuidString.lowercased())|\(throughUserMessageID.uuidString.lowercased())|\(sourceFingerprint)"
    )
  }

  private static func canonicalKey(
    proposed: String,
    kind: MemoryTopicKind,
    scope: MemoryScope,
    conversationID: UUID,
    projectID: UUID?
  ) throws -> String {
    let normalized =
      proposed
      .lowercased(with: Locale(identifier: "en_US_POSIX"))
      .unicodeScalars
      .map { scalar -> Character in
        let allowed = CharacterSet.alphanumerics
          .union(CharacterSet(charactersIn: "._-:/"))
        return allowed.contains(scalar) ? Character(String(scalar)) : "_"
      }
      .reduce(into: "") { result, character in
        if character != "_" || result.last != "_" { result.append(character) }
      }
      .trimmingCharacters(in: CharacterSet(charactersIn: "._-:/"))
    guard !normalized.isEmpty else { throw AutomaticMemoryStoreError.invalidOperation }
    let prefix: String
    switch scope {
    case .global:
      prefix = "global:\(kind.rawValue):"
    case .project:
      guard let projectID else { throw AutomaticMemoryStoreError.invalidOperation }
      prefix = "project:\(projectID.uuidString.lowercased()):\(kind.rawValue):"
    case .conversation:
      prefix = "conversation:\(conversationID.uuidString.lowercased()):\(kind.rawValue):"
    }
    if normalized.hasPrefix("global:") || normalized.hasPrefix("project:")
      || normalized.hasPrefix("conversation:")
    {
      guard normalized.hasPrefix(prefix) else {
        throw AutomaticMemoryStoreError.invalidOperation
      }
    }
    var suffix = normalized
    if suffix.hasPrefix(prefix) {
      suffix.removeFirst(prefix.count)
    }
    let repeatedKindPrefix = "\(kind.rawValue)."
    if suffix.hasPrefix(repeatedKindPrefix) {
      suffix.removeFirst(repeatedKindPrefix.count)
    }
    guard !suffix.isEmpty else { throw AutomaticMemoryStoreError.invalidOperation }
    let value = prefix + suffix
    guard value.utf8.count <= MosaicSourceFieldLimits.maximumMemoryCanonicalKeyUTF8Bytes else {
      throw AutomaticMemoryStoreError.invalidOperation
    }
    return value
  }

  nonisolated static func normalizedValue(_ value: String) -> String {
    value
      .lowercased(with: Locale(identifier: "tr_TR"))
      .folding(
        options: [.diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "tr_TR")
      )
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
  }

  private func matchesCurrentState(
    _ topic: MemoryTopicRecord,
    expected: AutomaticMemoryTopicSnapshot
  ) throws -> Bool {
    let boundProjectID = try ProjectBindingStore.projectID(
      resourceKind: .memoryTopic,
      resourceID: topic.id,
      in: modelContext
    )
    return topic.id == expected.id
      && topic.canonicalKey == expected.canonicalKey
      && topic.title == expected.title
      && topic.content == expected.content
      && topic.kind == expected.kind
      && topic.scope == expected.scope
      && topic.conversationID == expected.conversationID
      && boundProjectID == expected.projectID
      && topic.status == expected.status
      && topic.origin == expected.origin
      && topic.confidence == expected.confidence
      && topic.importance == expected.importance
      && topic.stability == expected.stability
      && topic.isEnabled == expected.isEnabled
      && topic.lastConfirmedAt == expected.lastConfirmedAt
      && topic.evidenceCount == expected.evidenceCount
      && topic.revision == expected.revision
      && topic.createdAt == expected.createdAt
      && topic.updatedAt == expected.updatedAt
  }

  private static func matchesAudience(
    _ topic: AutomaticMemoryTopicSnapshot,
    conversationID: UUID,
    projectID: UUID?
  ) -> Bool {
    switch topic.scope {
    case .global:
      topic.conversationID == nil && topic.projectID == nil
    case .project:
      topic.conversationID == nil
        && topic.projectID != nil
        && topic.projectID == projectID
    case .conversation:
      topic.conversationID == conversationID && topic.projectID == nil
    }
  }

  private static func reinforcedConfidence(existing: Double, incoming: Double) -> Double {
    min(0.99, max(existing, 1 - (1 - existing) * (1 - incoming * 0.35)))
  }

  private static func moreStable(
    _ lhs: MemoryStability,
    _ rhs: MemoryStability
  ) -> MemoryStability {
    let rank: [MemoryStability: Int] = [.evolving: 0, .stable: 1, .permanent: 2]
    return (rank[lhs] ?? 0) >= (rank[rhs] ?? 0) ? lhs : rhs
  }

  private static func boundedExcerpt(_ value: String) -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > maximumEvidenceExcerptCharacters else { return normalized }
    return String(normalized.prefix(maximumEvidenceExcerptCharacters - 1)) + "…"
  }

  private static func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
    guard value.utf8.count > maximumBytes else { return value }
    var result = ""
    var byteCount = 0
    for character in value {
      let characterBytes = String(character).utf8.count
      guard byteCount <= maximumBytes - characterBytes else { break }
      result.append(character)
      byteCount += characterBytes
    }
    return result
  }

  private static func outputData(_ envelope: AutomaticMemoryExtractionEnvelope) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(envelope)
  }
}

/// Serializes provider calls process-wide. SwiftData revalidation still protects against stale
/// results, while the actor prevents two windows from paying for the same job concurrently.
public actor AutomaticMemoryFormationCoordinator {
  public static let shared = AutomaticMemoryFormationCoordinator()

  public init() {}

  public func formMemory(
    conversationID: UUID,
    throughUserMessageID: UUID,
    assistantMessageID: UUID,
    provider: ProviderConnection,
    client: any AIProviderClient,
    modelContainer: ModelContainer,
    resumingJobID: UUID? = nil
  ) async throws -> AutomaticMemoryFormationResult {
    let store = AutomaticMemoryStore(modelContainer: modelContainer)
    let enqueuedJobID = try await store.enqueue(
      conversationID: conversationID,
      throughUserMessageID: throughUserMessageID,
      assistantMessageID: assistantMessageID,
      provider: provider
    )
    if let resumingJobID, resumingJobID != enqueuedJobID {
      // A prompt-version upgrade creates a new audited job. Retire the old queue entry even
      // when the replacement has already completed, so recovery cannot loop over it forever.
      try await store.markRejected(jobID: resumingJobID, error: SupersededMemoryFormation())
    }
    guard let jobID = enqueuedJobID else { return AutomaticMemoryFormationResult() }
    guard AutomaticMemoryInFlightRegistry.shared.begin(jobID) else {
      throw AutomaticMemoryStoreError.requestAlreadyActive
    }
    defer { AutomaticMemoryInFlightRegistry.shared.end(jobID) }

    let telemetry = AutomaticMemoryExtractionTelemetryCollector()
    do {
      guard let preparation = try await store.prepare(jobID: jobID, provider: provider) else {
        return AutomaticMemoryFormationResult()
      }
      let generated = try await AutomaticMemoryExtractor().generate(
        preparation: preparation,
        provider: provider,
        client: client,
        telemetry: telemetry,
        beforeOpeningStream: {
          try await store.markRequestStarted(
            jobID: jobID,
            provider: provider,
            expectedProjectID: preparation.projectID
          )
        },
        telemetryDidChange: { snapshot in
          try await store.recordAttemptTelemetry(
            jobID: jobID,
            provider: provider,
            telemetry: snapshot
          )
        }
      )
      return try await AutomaticMemoryStore(modelContainer: modelContainer).apply(generated)
    } catch {
      if Self.isNonRetryableLocalFailure(error) {
        try? await store.markRejected(
          jobID: jobID,
          error: error,
          redacting: provider.apiKey,
          telemetry: telemetry.snapshot
        )
      } else {
        try? await store.markFailed(
          jobID: jobID,
          error: error,
          redacting: provider.apiKey,
          telemetry: telemetry.snapshot
        )
      }
      throw error
    }
  }

  static func isNonRetryableLocalFailure(_ error: Error) -> Bool {
    if let extractionError = error as? AutomaticMemoryExtractionError {
      switch extractionError {
      case .invalidPreparation, .incompleteResponse, .emptyResponse, .responseTooLarge,
        .invalidOutput,
        .invalidEvidence, .invalidTarget:
        return false
      }
    }
    if let storeError = error as? AutomaticMemoryStoreError {
      switch storeError {
      case .sourceUnavailable, .counterOverflow:
        return true
      case .staleSource, .invalidOperation, .missingTopic, .providerUnavailable,
        .requestAlreadyActive, .interruptedRequestRequiresExplicitRetry:
        return false
      }
    }
    return false
  }
}

private struct SupersededMemoryFormation: LocalizedError {
  var errorDescription: String? {
    "This memory attempt was replaced by an attempt using the updated memory rules."
  }
}

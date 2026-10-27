import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite(.serialized)
struct AutomaticMemoryPortableBackupTests {
  fileprivate static let providerEndpoint = "https://api.openai.com:443/v1"

  @MainActor
  @Test
  func automaticMemoryRecordsRoundTripWithEvidenceAndOperationalProviderRekeying() throws {
    let source = try makeAutomaticMemoryBackupFixture()

    let data = try MosaicPortableBackup.export(
      from: source.context,
      backupID: source.backupID,
      createdAt: source.date
    )
    let repeatedData = try MosaicPortableBackup.export(
      from: source.context,
      backupID: source.backupID,
      createdAt: source.date
    )
    let decoded = try MosaicPortableBackup.decode(data)

    #expect(repeatedData == data)
    #expect(decoded.sourceSchemaVersion == "mosaic-main-6")
    #expect(decoded.extensionRecords.count == 5)
    #expect(
      Set(decoded.extensionRecords.map(\.namespace))
        == [AutomaticMemoryPortableArchive.namespace]
    )

    let plan = try MosaicPortableBackup.prepareRestore(from: data)
    let replacementProviderID = try #require(plan.providerIDMap[source.providerID])
    let targetContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let targetContext = ModelContext(targetContainer)
    try MosaicPortableBackup.replaceLiveStore(using: plan, in: targetContext)

    let topics = try targetContext.fetch(FetchDescriptor<MemoryTopicRecord>())
    let evidence = try targetContext.fetch(FetchDescriptor<MemoryEvidenceRecord>())
    let revisions = try targetContext.fetch(FetchDescriptor<MemoryRevisionRecord>())
    let jobs = try targetContext.fetch(FetchDescriptor<MemoryFormationJobRecord>())
    let audits = try targetContext.fetch(FetchDescriptor<MemoryFormationAuditRecord>())

    #expect(topics.count == 1)
    #expect(topics.first?.id == source.topicID)
    #expect(topics.first?.evidenceCount == 1)
    #expect(evidence.count == 1)
    #expect(evidence.first?.topicID == source.topicID)
    // Evidence keeps the provider ID as immutable historical provenance, like chat messages.
    #expect(evidence.first?.providerConfigurationID == source.providerID)
    #expect(evidence.first?.providerEndpoint == Self.providerEndpoint)
    #expect(revisions.count == 1)
    #expect(revisions.first?.sourceEvidenceID == source.evidenceID)
    #expect(jobs.count == 1)
    // A job's provider ID is operational and must follow restore-time provider rekeying.
    #expect(jobs.first?.providerConfigurationID == replacementProviderID)
    #expect(jobs.first?.providerEndpoint == Self.providerEndpoint)
    #expect(audits.count == 1)
    #expect(audits.first?.jobID == jobs.first?.id)
    // Audit provider identity is immutable provenance, like evidence; usage survives restore.
    #expect(audits.first?.providerConfigurationID == source.providerID)
    #expect(audits.first?.providerMessageID == "memory-response")
    #expect(audits.first?.inputTokenCount == 120)
    #expect(audits.first?.outputTokenCount == 45)
    #expect(audits.first?.cumulativeInputTokenCount == 120)
    #expect(audits.first?.cumulativeOutputTokenCount == 45)
  }

  @MainActor
  @Test
  func captureRejectsCallerInjectionIntoReservedAutomaticMemoryNamespace() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = ModelContext(container)
    let injected = MosaicPortableExtensionRecord(
      namespace: AutomaticMemoryPortableArchive.namespace,
      recordType: "topic",
      recordVersion: AutomaticMemoryPortableArchive.recordVersion,
      id: UUID(),
      payload: Data("{}".utf8)
    )

    do {
      _ = try MosaicPortableBackup.captureSnapshot(
        from: context,
        extensionRecords: [injected]
      )
      Issue.record("Expected the reserved namespace to reject caller-provided records")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .unsupportedExtensionRecord(
            namespace: injected.namespace,
            recordType: injected.recordType,
            version: injected.recordVersion
          )
      )
    }
  }

  @MainActor
  @Test
  func replacingWithBackupWithoutAutomaticMemoryDeletesPreviousMemoryGraph() throws {
    let emptyContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let emptyContext = ModelContext(emptyContainer)
    let emptyArchive = try MosaicPortableBackup.export(from: emptyContext)
    let emptyPlan = try MosaicPortableBackup.prepareRestore(from: emptyArchive)

    let target = try makeAutomaticMemoryBackupFixture()
    try MosaicPortableBackup.replaceLiveStore(using: emptyPlan, in: target.context)

    #expect(try target.context.fetchCount(FetchDescriptor<MemoryTopicRecord>()) == 0)
    #expect(try target.context.fetchCount(FetchDescriptor<MemoryEvidenceRecord>()) == 0)
    #expect(try target.context.fetchCount(FetchDescriptor<MemoryRevisionRecord>()) == 0)
    #expect(try target.context.fetchCount(FetchDescriptor<MemoryFormationJobRecord>()) == 0)
    #expect(try target.context.fetchCount(FetchDescriptor<MemoryFormationAuditRecord>()) == 0)
  }

  @MainActor
  @Test
  func decodeRejectsAutomaticMemoryEvidenceWithTamperedSourceFingerprint() throws {
    let source = try makeAutomaticMemoryBackupFixture()
    let archive = try MosaicPortableBackup.export(from: source.context)
    let snapshot = try MosaicPortableBackup.decode(archive)
    var extensionRecords = snapshot.extensionRecords
    let evidenceIndex = try #require(
      extensionRecords.firstIndex { $0.recordType == "evidence" }
    )
    let original = extensionRecords[evidenceIndex]
    var payload = try #require(
      JSONSerialization.jsonObject(with: original.payload) as? [String: Any]
    )
    payload["sourceFingerprint"] = "tampered"
    extensionRecords[evidenceIndex] = MosaicPortableExtensionRecord(
      namespace: original.namespace,
      recordType: original.recordType,
      recordVersion: original.recordVersion,
      id: original.id,
      payload: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    )
    let tampered = replacingExtensions(in: snapshot, with: extensionRecords)
    let tamperedArchive = try MosaicPortableBackup.encodeUnchecked(
      snapshot: tampered,
      limits: .default
    )

    do {
      _ = try MosaicPortableBackup.decode(tamperedArchive)
      Issue.record("Expected tampered memory provenance to fail closed")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .invalidNormalizedInvariant(
            recordType: "memory_evidence",
            id: source.evidenceID,
            field: "source_fingerprint"
          )
      )
    }
  }

  @MainActor
  @Test
  func decodeRejectsActiveAutomaticTopicWithoutEvidence() throws {
    let source = try makeAutomaticMemoryBackupFixture()
    let snapshot = try MosaicPortableBackup.decode(
      MosaicPortableBackup.export(from: source.context)
    )
    var extensionRecords = snapshot.extensionRecords.filter { $0.recordType != "evidence" }
    let topicIndex = try #require(
      extensionRecords.firstIndex { $0.recordType == "topic" }
    )
    let topicRecord = extensionRecords[topicIndex]
    var topicPayload = try #require(
      JSONSerialization.jsonObject(with: topicRecord.payload) as? [String: Any]
    )
    topicPayload["evidenceCount"] = 0
    extensionRecords[topicIndex] = MosaicPortableExtensionRecord(
      namespace: topicRecord.namespace,
      recordType: topicRecord.recordType,
      recordVersion: topicRecord.recordVersion,
      id: topicRecord.id,
      payload: try JSONSerialization.data(withJSONObject: topicPayload, options: [.sortedKeys])
    )
    let revisionIndex = try #require(
      extensionRecords.firstIndex { $0.recordType == "revision" }
    )
    let revisionRecord = extensionRecords[revisionIndex]
    var revisionPayload = try #require(
      JSONSerialization.jsonObject(with: revisionRecord.payload) as? [String: Any]
    )
    revisionPayload.removeValue(forKey: "sourceEvidenceID")
    extensionRecords[revisionIndex] = MosaicPortableExtensionRecord(
      namespace: revisionRecord.namespace,
      recordType: revisionRecord.recordType,
      recordVersion: revisionRecord.recordVersion,
      id: revisionRecord.id,
      payload: try JSONSerialization.data(withJSONObject: revisionPayload, options: [.sortedKeys])
    )
    let tamperedArchive = try MosaicPortableBackup.encodeUnchecked(
      snapshot: replacingExtensions(in: snapshot, with: extensionRecords),
      limits: .default
    )

    #expect(
      throws: MosaicPortableBackupError.invalidNormalizedInvariant(
        recordType: "memory_topic",
        id: source.topicID,
        field: "automatic_evidence"
      )
    ) {
      try MosaicPortableBackup.decode(tamperedArchive)
    }
  }

  @MainActor
  @Test
  func decodeRejectsActiveAutomaticTopicWhenNoRevisionCitesItsEvidence() throws {
    let source = try makeAutomaticMemoryBackupFixture()
    let snapshot = try MosaicPortableBackup.decode(
      MosaicPortableBackup.export(from: source.context)
    )
    var extensionRecords = snapshot.extensionRecords
    let revisionIndex = try #require(
      extensionRecords.firstIndex { $0.recordType == "revision" }
    )
    let revisionRecord = extensionRecords[revisionIndex]
    var payload = try #require(
      JSONSerialization.jsonObject(with: revisionRecord.payload) as? [String: Any]
    )
    payload.removeValue(forKey: "sourceEvidenceID")
    extensionRecords[revisionIndex] = MosaicPortableExtensionRecord(
      namespace: revisionRecord.namespace,
      recordType: revisionRecord.recordType,
      recordVersion: revisionRecord.recordVersion,
      id: revisionRecord.id,
      payload: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    )
    let tamperedArchive = try MosaicPortableBackup.encodeUnchecked(
      snapshot: replacingExtensions(in: snapshot, with: extensionRecords),
      limits: .default
    )

    #expect(
      throws: MosaicPortableBackupError.invalidNormalizedInvariant(
        recordType: "memory_topic",
        id: source.topicID,
        field: "revision_evidence"
      )
    ) {
      try MosaicPortableBackup.decode(tamperedArchive)
    }
  }

  @MainActor
  @Test
  func decodeRejectsGlobalTopicWithConversationAudience() throws {
    let source = try makeAutomaticMemoryBackupFixture()
    let snapshot = try MosaicPortableBackup.decode(
      MosaicPortableBackup.export(from: source.context)
    )
    var extensionRecords = snapshot.extensionRecords
    let topicIndex = try #require(
      extensionRecords.firstIndex { $0.recordType == "topic" }
    )
    let topicRecord = extensionRecords[topicIndex]
    var payload = try #require(
      JSONSerialization.jsonObject(with: topicRecord.payload) as? [String: Any]
    )
    payload["conversationID"] = source.conversationID.uuidString
    extensionRecords[topicIndex] = MosaicPortableExtensionRecord(
      namespace: topicRecord.namespace,
      recordType: topicRecord.recordType,
      recordVersion: topicRecord.recordVersion,
      id: topicRecord.id,
      payload: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    )
    let tamperedArchive = try MosaicPortableBackup.encodeUnchecked(
      snapshot: replacingExtensions(in: snapshot, with: extensionRecords),
      limits: .default
    )

    #expect(
      throws: MosaicPortableBackupError.invalidNormalizedInvariant(
        recordType: "memory_topic",
        id: source.topicID,
        field: "topic_conversation"
      )
    ) {
      try MosaicPortableBackup.decode(tamperedArchive)
    }
  }

  @MainActor
  @Test
  func decodeRejectsRevisionHistoryThatDoesNotMatchCurrentTopic() throws {
    let source = try makeAutomaticMemoryBackupFixture()
    let archive = try MosaicPortableBackup.export(from: source.context)
    let snapshot = try MosaicPortableBackup.decode(archive)
    var extensionRecords = snapshot.extensionRecords
    let revisionIndex = try #require(
      extensionRecords.firstIndex { $0.recordType == "revision" }
    )
    let original = extensionRecords[revisionIndex]
    var payload = try #require(
      JSONSerialization.jsonObject(with: original.payload) as? [String: Any]
    )
    payload["content"] = "Tampered history value"
    extensionRecords[revisionIndex] = MosaicPortableExtensionRecord(
      namespace: original.namespace,
      recordType: original.recordType,
      recordVersion: original.recordVersion,
      id: original.id,
      payload: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    )
    let tamperedArchive = try MosaicPortableBackup.encodeUnchecked(
      snapshot: replacingExtensions(in: snapshot, with: extensionRecords),
      limits: .default
    )

    do {
      _ = try MosaicPortableBackup.decode(tamperedArchive)
      Issue.record("Expected a revision head that diverges from its topic to fail closed")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .invalidNormalizedInvariant(
            recordType: "memory_topic",
            id: source.topicID,
            field: "revision_value"
          )
      )
    }
  }

  @MainActor
  @Test
  func decodeRejectsConversationTopicEvidenceFromAnotherConversation() throws {
    let source = try makeAutomaticMemoryBackupFixture()
    let archive = try MosaicPortableBackup.export(from: source.context)
    let snapshot = try MosaicPortableBackup.decode(archive)
    let otherConversationID = UUID(
      uuidString: "91000000-0000-0000-0000-000000000099"
    )!
    let otherConversation = MosaicPortableConversation(
      id: otherConversationID,
      title: "Other chat",
      providerConfigurationID: nil,
      modelIdentifier: "gpt-test",
      systemPrompt: nil,
      draftText: "",
      compactionSnapshotData: nil,
      isArchived: false,
      createdAt: source.date,
      updatedAt: source.date
    )
    var extensionRecords = snapshot.extensionRecords
    let topicIndex = try #require(
      extensionRecords.firstIndex { $0.recordType == "topic" }
    )
    let original = extensionRecords[topicIndex]
    var payload = try #require(
      JSONSerialization.jsonObject(with: original.payload) as? [String: Any]
    )
    payload["scopeRawValue"] = MemoryScope.conversation.rawValue
    payload["conversationID"] = otherConversationID.uuidString
    payload["canonicalKey"] =
      "conversation:\(otherConversationID.uuidString.lowercased()):preference:interface-theme"
    extensionRecords[topicIndex] = MosaicPortableExtensionRecord(
      namespace: original.namespace,
      recordType: original.recordType,
      recordVersion: original.recordVersion,
      id: original.id,
      payload: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    )
    let tampered = replacingExtensions(
      in: snapshot,
      with: extensionRecords,
      conversations: snapshot.conversations + [otherConversation]
    )
    let tamperedArchive = try MosaicPortableBackup.encodeUnchecked(
      snapshot: tampered,
      limits: .default
    )

    do {
      _ = try MosaicPortableBackup.decode(tamperedArchive)
      Issue.record("Expected conversation-scoped evidence from another chat to fail closed")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .invalidNormalizedInvariant(
            recordType: "memory_evidence",
            id: source.evidenceID,
            field: "topic_conversation"
          )
      )
    }
  }

  @MainActor
  @Test
  func decodeRejectsMissingProviderEndpointWhenAProviderIDIsPresent() throws {
    let source = try makeAutomaticMemoryBackupFixture()
    let archive = try MosaicPortableBackup.export(from: source.context)
    let snapshot = try MosaicPortableBackup.decode(archive)
    var extensionRecords = snapshot.extensionRecords
    let evidenceIndex = try #require(
      extensionRecords.firstIndex { $0.recordType == "evidence" }
    )
    let original = extensionRecords[evidenceIndex]
    var payload = try #require(
      JSONSerialization.jsonObject(with: original.payload) as? [String: Any]
    )
    payload.removeValue(forKey: "providerEndpoint")
    extensionRecords[evidenceIndex] = MosaicPortableExtensionRecord(
      namespace: original.namespace,
      recordType: original.recordType,
      recordVersion: original.recordVersion,
      id: original.id,
      payload: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    )
    let tamperedArchive = try MosaicPortableBackup.encodeUnchecked(
      snapshot: replacingExtensions(in: snapshot, with: extensionRecords),
      limits: .default
    )

    do {
      _ = try MosaicPortableBackup.decode(tamperedArchive)
      Issue.record("Expected provider provenance without an endpoint to fail closed")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .invalidNormalizedInvariant(
            recordType: "memory_evidence",
            id: source.evidenceID,
            field: "provider_endpoint"
          )
      )
    }
  }
}

@MainActor
private func makeAutomaticMemoryBackupFixture() throws -> (
  context: ModelContext,
  backupID: UUID,
  date: Date,
  providerID: UUID,
  conversationID: UUID,
  topicID: UUID,
  evidenceID: UUID
) {
  let container = try MosaicSchema.makeModelContainer(inMemory: true)
  let context = ModelContext(container)
  let date = Date(timeIntervalSince1970: 1_788_000_000)
  let providerID = UUID(uuidString: "91000000-0000-0000-0000-000000000001")!
  let conversationID = UUID(uuidString: "91000000-0000-0000-0000-000000000002")!
  let userMessageID = UUID(uuidString: "91000000-0000-0000-0000-000000000003")!
  let assistantMessageID = UUID(uuidString: "91000000-0000-0000-0000-000000000004")!
  let topicID = UUID(uuidString: "91000000-0000-0000-0000-000000000005")!
  let evidenceID = UUID(uuidString: "91000000-0000-0000-0000-000000000006")!
  let revisionID = UUID(uuidString: "91000000-0000-0000-0000-000000000007")!
  let sourceContent = "Koyu temayı tercih ediyorum."
  let sourceFingerprint = AutomaticMemorySourceFingerprint.make(
    messages: [
      AutomaticMemorySourceMessage(
        id: userMessageID,
        role: .user,
        content: sourceContent,
        createdAt: date
      )
    ]
  )
  let jobKey = EmbeddingVectorCodec.fingerprint(
    for:
      "automatic-memory-v1|\(conversationID.uuidString.lowercased())|"
      + "\(userMessageID.uuidString.lowercased())|\(sourceFingerprint)"
  )

  context.insert(
    ProviderConfigurationRecord(
      id: providerID,
      displayName: "OpenAI",
      provider: .openAI,
      modelIdentifier: "gpt-test",
      createdAt: date,
      updatedAt: date
    )
  )
  context.insert(
    ConversationRecord(
      id: conversationID,
      title: "Memory source",
      providerConfigurationID: providerID,
      modelIdentifier: "gpt-test",
      createdAt: date,
      updatedAt: date
    )
  )
  context.insert(
    MessageRecord(
      id: userMessageID,
      conversationID: conversationID,
      role: .user,
      content: sourceContent,
      status: .complete,
      createdAt: date,
      updatedAt: date
    )
  )
  context.insert(
    MessageRecord(
      id: assistantMessageID,
      conversationID: conversationID,
      role: .assistant,
      content: "Bunu hatırlayacağım.",
      status: .complete,
      providerConfigurationID: providerID,
      providerKind: .openAI,
      providerDisplayName: "OpenAI",
      modelIdentifier: "gpt-test",
      createdAt: date.addingTimeInterval(1),
      updatedAt: date.addingTimeInterval(1)
    )
  )
  context.insert(
    MemoryTopicRecord(
      id: topicID,
      canonicalKey: "global:preference:interface-theme",
      title: "Interface theme",
      content: "Prefers dark interface themes.",
      kind: .preference,
      scope: .global,
      conversationID: nil,
      confidence: 0.95,
      importance: 0.7,
      stability: .stable,
      lastConfirmedAt: date,
      evidenceCount: 1,
      revision: 1,
      createdAt: date,
      updatedAt: date
    )
  )
  context.insert(
    MemoryEvidenceRecord(
      id: evidenceID,
      evidenceKey:
        "\(topicID.uuidString.lowercased())/"
        + "\(userMessageID.uuidString.lowercased())/\(sourceFingerprint)",
      topicID: topicID,
      conversationID: conversationID,
      sourceMessageID: userMessageID,
      assistantMessageID: assistantMessageID,
      excerpt: sourceContent,
      sourceFingerprint: sourceFingerprint,
      providerConfigurationID: providerID,
      providerKind: .openAI,
      providerDisplayName: "OpenAI",
      modelIdentifier: "gpt-test",
      providerEndpoint: AutomaticMemoryPortableBackupTests.providerEndpoint,
      confidence: 0.95,
      createdAt: date
    )
  )
  context.insert(
    MemoryRevisionRecord(
      id: revisionID,
      revisionKey: "\(topicID.uuidString.lowercased())/1",
      topicID: topicID,
      sequence: 1,
      kind: .created,
      previousTitle: nil,
      previousContent: nil,
      title: "Interface theme",
      content: "Prefers dark interface themes.",
      sourceEvidenceID: evidenceID,
      createdAt: date
    )
  )
  let formationJob = MemoryFormationJobRecord(
    jobKey: jobKey,
    conversationID: conversationID,
    throughUserMessageID: userMessageID,
    assistantMessageID: assistantMessageID,
    sourceFingerprint: sourceFingerprint,
    promptVersion: "automatic-memory-v1",
    status: .complete,
    attemptCount: 1,
    providerConfigurationID: providerID,
    providerKind: .openAI,
    providerDisplayName: "OpenAI",
    modelIdentifier: "gpt-test",
    providerEndpoint: AutomaticMemoryPortableBackupTests.providerEndpoint,
    outputFingerprint: "output-fingerprint",
    startedAt: date,
    completedAt: date.addingTimeInterval(2),
    createdAt: date,
    updatedAt: date.addingTimeInterval(2)
  )
  context.insert(formationJob)
  context.insert(
    MemoryFormationAuditRecord(
      jobID: formationJob.id,
      jobKey: jobKey,
      attemptCount: 1,
      outcome: .complete,
      providerConfigurationID: providerID,
      providerKind: .openAI,
      providerDisplayName: "OpenAI",
      modelIdentifier: "gpt-test",
      providerEndpoint: AutomaticMemoryPortableBackupTests.providerEndpoint,
      providerMessageID: "memory-response",
      requestStarted: true,
      inputTokenCount: 120,
      outputTokenCount: 45,
      providerRequestCount: 1,
      cumulativeInputTokenCount: 120,
      cumulativeOutputTokenCount: 45,
      didDiscardInvalidTelemetry: false,
      errorDescription: nil,
      startedAt: date,
      finishedAt: date.addingTimeInterval(2),
      createdAt: date,
      updatedAt: date.addingTimeInterval(2)
    )
  )
  try context.save()

  return (
    context,
    UUID(uuidString: "91000000-0000-0000-0000-000000000009")!,
    date,
    providerID,
    conversationID,
    topicID,
    evidenceID
  )
}

private func replacingExtensions(
  in snapshot: MosaicPortableBackupSnapshot,
  with extensionRecords: [MosaicPortableExtensionRecord],
  conversations: [MosaicPortableConversation]? = nil
) -> MosaicPortableBackupSnapshot {
  MosaicPortableBackupSnapshot(
    backupID: snapshot.backupID,
    createdAt: snapshot.createdAt,
    sourceSchemaVersion: snapshot.sourceSchemaVersion,
    conversations: conversations ?? snapshot.conversations,
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
    normalizedBackfillProgress: snapshot.normalizedBackfillProgress,
    extensionRecords: extensionRecords
  )
}

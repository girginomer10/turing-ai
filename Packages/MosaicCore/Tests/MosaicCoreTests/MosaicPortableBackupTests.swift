import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite(.serialized)
struct MosaicPortableBackupTests {
  @Test
  func defaultEnvelopeBudgetSupportsOrdinaryLibraryGrowthButRemainsBounded() {
    let limits = MosaicPortableBackupLimits.default

    #expect(limits.maximumTotalBytes == 256 * 1_024 * 1_024)
    #expect(limits.maximumRecordBytes == 8 * 1_024 * 1_024)
    #expect(limits.maximumRecordCount == 1_000_000)
    #expect(limits.maximumTotalBytes < .max)
    #expect(limits.maximumRecordCount < .max)
  }

  @MainActor
  @Test
  func validLibraryBeyondLegacyCeilingExportsAndCanBeReplaced() throws {
    let legacyTotalByteCeiling = 64 * 1_024 * 1_024
    let liveContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let liveContext = liveContainer.mainContext
    let conversation = ConversationRecord(title: "Large but valid library")
    liveContext.insert(conversation)
    let content = String(
      repeating: "x",
      count: MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes
    )
    for index in 0..<129 {
      liveContext.insert(
        MessageRecord(
          conversationID: conversation.id,
          role: index.isMultiple(of: 2) ? .user : .assistant,
          content: content
        )
      )
    }
    try liveContext.save()

    let largeArchive = try MosaicPortableBackup.export(from: liveContext)
    #expect(largeArchive.count > legacyTotalByteCeiling)
    #expect(largeArchive.count <= MosaicPortableBackupLimits.default.maximumTotalBytes)

    let fixture = try makeFixture()
    let replacementArchive = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let plan = try MosaicPortableBackup.prepareRestore(from: replacementArchive)
    try MosaicPortableBackup.replaceLiveStore(using: plan, in: liveContext)

    let verificationContext = ModelContext(liveContainer)
    #expect(
      try verificationContext.fetch(FetchDescriptor<ConversationRecord>()).map(\.id)
        == [fixture.conversationID]
    )
  }

  @MainActor
  @Test
  func deterministicRoundTripPreservesEveryMainRecordAndOpaqueBlob() throws {
    let fixture = try makeFixture()

    let first = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let second = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let snapshot = try MosaicPortableBackup.decode(first)

    #expect(first == second)
    #expect(snapshot.conversations.count == 1)
    #expect(snapshot.messages.count == 2)
    #expect(snapshot.memories.count == 2)
    #expect(snapshot.scheduledTasks.count == 1)
    #expect(snapshot.providerConfigurations.count == 1)
    #expect(snapshot.embeddingProfiles.count == 2)
    #expect(snapshot.importedDocuments.count == 1)
    #expect(snapshot.documentChunks.count == 1)
    #expect(snapshot.requestContextEvents.count == 1)
    #expect(snapshot.compactionArtifacts.count == 1)
    #expect(snapshot.conversationCompactionHeads.count == 1)
    #expect(snapshot.normalizedBackfillProgress.count == 1)
    #expect(snapshot.conversations.first?.compactionSnapshotData == fixture.compactionBlob)
    #expect(snapshot.messages.first?.contextReceiptData == fixture.receiptBlob)
    #expect(snapshot.requestContextEvents.first?.payloadData == fixture.normalizedEventPayload)
    #expect(snapshot.compactionArtifacts.first?.warningsData == fixture.normalizedWarningsBlob)
    #expect(snapshot.conversationCompactionHeads.first?.activeArtifactID == fixture.artifactID)
    #expect(snapshot.normalizedBackfillProgress.first?.processedCount == 7)
  }

  @MainActor
  @Test
  func exportNeverReadsCredentialOrSemanticVectorStores() throws {
    let fixture = try makeFixture()
    let secretSentinel = "mosaic-secret-sentinel-never-export"
    _ = try ProviderCredentialEnvelope.encode(
      apiKey: secretSentinel,
      binding: ProviderCredentialBinding(
        provider: .openAI,
        baseURL: URL(string: "https://api.openai.com/v1")
      )
    )

    let indexContainer = try SemanticIndexStore.makeModelContainer(inMemory: true)
    let indexContext = ModelContext(indexContainer)
    indexContext.insert(
      EmbeddingVectorRecord(
        profileID: fixture.profileID,
        sourceKind: .conversationMessage,
        sourceID: fixture.messageID,
        embeddingSpaceIdentifier: "semantic-vector-sentinel",
        contentFingerprint: "not-source-data",
        dimensions: 1,
        vectorData: Data([0xFA, 0xFB, 0xFC])
      )
    )
    try indexContext.save()

    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let text = try #require(String(data: data, encoding: .utf8))

    #expect(!text.contains(secretSentinel))
    #expect(!text.contains("apiKey"))
    #expect(!text.contains("vectorData"))
    #expect(!text.contains("semantic-vector-sentinel"))
  }

  @MainActor
  @Test
  func prepareRestoreRekeysProvidersPausesTasksAndRepairsSoftOrphans() throws {
    let fixture = try makeFixture()
    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )

    let plan = try MosaicPortableBackup.prepareRestore(from: data)
    let newProviderID = try #require(plan.providerIDMap[fixture.providerID])
    let conversation = try #require(plan.snapshot.conversations.first)
    let task = try #require(plan.snapshot.scheduledTasks.first)
    let profiles = Dictionary(
      uniqueKeysWithValues: plan.snapshot.embeddingProfiles.map { ($0.id, $0) })
    let memories = Dictionary(uniqueKeysWithValues: plan.snapshot.memories.map { ($0.id, $0) })

    #expect(newProviderID != fixture.providerID)
    #expect(plan.snapshot.providerConfigurations.first?.id == newProviderID)
    #expect(plan.snapshot.providerConfigurations.first?.isEnabled == false)
    #expect(conversation.providerConfigurationID == newProviderID)
    #expect(task.providerConfigurationID == newProviderID)
    #expect(task.statusRawValue == ScheduledTaskStatus.paused.rawValue)
    #expect(profiles[fixture.profileID]?.providerConfigurationID == newProviderID)
    #expect(profiles[fixture.orphanProfileID]?.providerConfigurationID == nil)
    #expect(profiles[fixture.orphanProfileID]?.isEnabled == false)
    #expect(memories[fixture.orphanMemoryID]?.conversationID == nil)
    #expect(memories[fixture.orphanMemoryID]?.isEnabled == false)
    // Message provider IDs are immutable historical provenance, not an operational key locator.
    #expect(plan.snapshot.messages.first?.providerConfigurationID == fixture.providerID)
  }

  @MainActor
  @Test(arguments: [ProviderKind.custom, .ollama])
  func restoredKeylessProviderCannotSendBeforeExplicitReview(kind: ProviderKind) throws {
    let fixture = try makeFixture()
    let exported = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let snapshot = try MosaicPortableBackup.decode(exported)
    let original = try #require(snapshot.providerConfigurations.first)
    let untrustedProvider = MosaicPortableProviderConfiguration(
      id: original.id,
      displayName: "Untrusted keyless destination",
      providerRawValue: kind.rawValue,
      modelIdentifier: "remote-model",
      baseURLString: "https://attacker.example/v1",
      contextWindowTokens: original.contextWindowTokens,
      maximumOutputTokens: original.maximumOutputTokens,
      isEnabled: true,
      createdAt: original.createdAt,
      updatedAt: original.updatedAt
    )
    let archive = try MosaicPortableBackup.encode(
      snapshot: copy(snapshot, providerConfigurations: [untrustedProvider])
    )

    let plan = try MosaicPortableBackup.prepareRestore(from: archive)
    let restored = try #require(plan.snapshot.providerConfigurations.first)
    #expect(restored.providerRawValue == kind.rawValue)
    #expect(restored.isEnabled == false)
  }

  @MainActor
  @Test
  func validatedPlanReplacesLiveStoreWithOneCommittedState() throws {
    let fixture = try makeFixture()
    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let plan = try MosaicPortableBackup.prepareRestore(from: data)

    let liveContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let liveContext = ModelContext(liveContainer)
    let obsoleteID = UUID()
    liveContext.insert(ConversationRecord(id: obsoleteID, title: "Obsolete"))
    try liveContext.save()

    try MosaicPortableBackup.replaceLiveStore(using: plan, in: liveContext)

    let conversations = try liveContext.fetch(FetchDescriptor<ConversationRecord>())
    let providers = try liveContext.fetch(FetchDescriptor<ProviderConfigurationRecord>())
    let tasks = try liveContext.fetch(FetchDescriptor<ScheduledTaskRecord>())
    let messages = try liveContext.fetch(FetchDescriptor<MessageRecord>())
    let events = try liveContext.fetch(FetchDescriptor<RequestContextEventRecord>())
    let artifacts = try liveContext.fetch(FetchDescriptor<CompactionArtifactRecord>())
    let heads = try liveContext.fetch(FetchDescriptor<ConversationCompactionHeadRecord>())
    let progress = try liveContext.fetch(
      FetchDescriptor<NormalizedContextBackfillProgressRecord>()
    )
    #expect(conversations.map(\.id) == [fixture.conversationID])
    #expect(!conversations.contains { $0.id == obsoleteID })
    #expect(providers.first?.id == plan.providerIDMap[fixture.providerID])
    #expect(tasks.first?.status == .paused)
    #expect(
      messages.first(where: { $0.id == fixture.messageID })?.contextReceiptData
        == fixture.receiptBlob)
    #expect(conversations.first?.compactionSnapshotData == fixture.compactionBlob)
    #expect(events.first?.payloadData == fixture.normalizedEventPayload)
    #expect(artifacts.first?.warningsData == fixture.normalizedWarningsBlob)
    #expect(heads.first?.activeArtifactID == fixture.artifactID)
    #expect(progress.first?.processedCount == 7)
    #expect(progress.first?.failureCount == 2)
  }

  @MainActor
  @Test
  func summarizedSameChatRecallSurvivesPortableRoundTripAndRestore() throws {
    let fixture = try makeFixture()
    let snapshot = try JSONDecoder().decode(
      ConversationCompactionSnapshot.self,
      from: fixture.compactionBlob
    )
    let currentUserID = UUID(uuidString: "30000000-0000-0000-0000-000000000005")!
    let responseID = UUID(uuidString: "30000000-0000-0000-0000-000000000006")!
    let source = [
      AIChatMessage(id: fixture.userMessageID, role: .user, content: "Merhaba"),
      AIChatMessage(id: fixture.messageID, role: .assistant, content: "Merhaba 👋"),
      AIChatMessage(id: currentUserID, role: .user, content: "Earlier preference?"),
    ]
    fixture.context.insert(
      MessageRecord(
        id: currentUserID,
        conversationID: fixture.conversationID,
        role: .user,
        content: source[2].content,
        status: .complete,
        createdAt: fixture.date.addingTimeInterval(1),
        updatedAt: fixture.date.addingTimeInterval(1)
      )
    )
    fixture.context.insert(
      MessageRecord(
        id: responseID,
        conversationID: fixture.conversationID,
        role: .assistant,
        content: "You said hello earlier.",
        status: .complete,
        providerConfigurationID: fixture.providerID,
        providerKind: .openAI,
        providerDisplayName: "OpenAI",
        providerHost: "api.openai.com",
        modelIdentifier: "gpt-test",
        createdAt: fixture.date.addingTimeInterval(2),
        updatedAt: fixture.date.addingTimeInterval(2)
      )
    )

    let recall = SameConversationRecallReceipt(
      conversationID: fixture.conversationID,
      items: [
        SameConversationRecallItem(
          id: fixture.userMessageID,
          origin: .summarized,
          title: "Earlier greeting",
          content: source[0].content,
          createdAt: fixture.date.addingTimeInterval(-1),
          relevance: 0.9,
          isTruncated: false
        )
      ],
      eligibleCandidateCount: 1,
      injectedInputTokens: 8
    )
    let receipt = RequestContextReceipt(
      curatedContext: .empty,
      retrievedContext: .empty,
      conversationContext: ConversationContextReceipt(
        strategy: .summaryAndRecent,
        originalMessageCount: source.count,
        includedMessageIDs: [currentUserID],
        omittedMessageIDs: [],
        summarizedMessageIDs: snapshot.coveredMessageIDs,
        recalledMessageIDs: [fixture.userMessageID],
        estimatedInputTokens: 300,
        contextWindowTokens: 8_192,
        maximumOutputTokens: 1_024,
        safetyMarginTokens: 256
      ),
      sameConversationRecall: recall,
      conversationCompaction: ConversationCompactionReceipt(
        attemptID: UUID(),
        status: .reused,
        compactionID: snapshot.id,
        summaryText: snapshot.renderedSummary,
        coveredMessageIDs: snapshot.coveredMessageIDs,
        attemptedMessageIDs: nil,
        activeSummaryProviderConfigurationID: snapshot.providerConfigurationID,
        activeSummaryProviderKind: snapshot.providerKind,
        activeSummaryProviderDisplayName: snapshot.providerDisplayName,
        activeSummaryProviderEndpoint: snapshot.providerEndpoint,
        activeSummaryModelIdentifier: snapshot.modelIdentifier,
        activeSummaryCreatedAt: snapshot.createdAt,
        providerConfigurationID: fixture.providerID,
        providerKind: .openAI,
        providerDisplayName: "OpenAI",
        providerEndpoint: "https://api.openai.com:443/v1",
        modelIdentifier: "gpt-test",
        providerMessageID: snapshot.providerMessageID,
        inputTokenCount: nil,
        outputTokenCount: nil,
        estimatedInputTokensBefore: 500,
        estimatedInputTokensAfter: 300,
        extraRequestCount: 0,
        createdAt: fixture.date.addingTimeInterval(1)
      ),
      createdAt: fixture.date.addingTimeInterval(1)
    )
    _ = try NormalizedContextStore(modelContext: fixture.context).appendRequestEvent(
      assistantMessageID: responseID,
      conversationID: fixture.conversationID,
      sourceThroughMessageID: currentUserID,
      eventSequence: 0,
      receipt: receipt,
      canonicalMessages: source,
      createdAt: fixture.date.addingTimeInterval(2)
    )

    let archive = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: UUID(),
      createdAt: fixture.date.addingTimeInterval(3)
    )
    let plan = try MosaicPortableBackup.prepareRestore(from: archive)
    let restoredContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let restoredContext = ModelContext(restoredContainer)
    try MosaicPortableBackup.replaceLiveStore(using: plan, in: restoredContext)

    let restoredReceipt = try #require(
      try NormalizedContextStore(modelContext: restoredContext).requestReceipt(
        assistantMessageID: responseID,
        canonicalMessages: source
      )
    )
    #expect(restoredReceipt.sameConversationRecall?.items.first?.origin == .summarized)
    #expect(restoredReceipt.sameConversationRecall?.recalledMessageIDs == [fixture.userMessageID])
    #expect(
      restoredReceipt.conversationContext?.summarizedMessageIDs?.contains(fixture.userMessageID)
        == true
    )
  }

  @MainActor
  @Test
  func injectedReplaceFailureRollsBackTheEntireLiveMutation() throws {
    let fixture = try makeFixture()
    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let plan = try MosaicPortableBackup.prepareRestore(from: data)

    let liveContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let liveContext = ModelContext(liveContainer)
    let existing = ConversationRecord(title: "Keep me")
    let existingID = existing.id
    liveContext.insert(existing)
    let existingMessageIDs = (0..<9).map { _ in UUID() }
    for (index, id) in existingMessageIDs.enumerated() {
      liveContext.insert(
        MessageRecord(
          id: id,
          conversationID: existingID,
          role: index.isMultiple(of: 2) ? .user : .assistant,
          content: "Keep message \(index)"
        )
      )
    }
    try liveContext.save()

    do {
      try MosaicPortableBackup.replaceLiveStore(
        using: plan,
        in: liveContext,
        beforeSave: { throw InjectedFailure.stop }
      )
      Issue.record("Expected the injected replacement failure")
    } catch let error as MosaicPortableBackupError {
      #expect(error == .persistenceFailure)
    }

    let conversations = try liveContext.fetch(FetchDescriptor<ConversationRecord>())
    let messages = try liveContext.fetch(FetchDescriptor<MessageRecord>())
    #expect(conversations.map(\.id) == [existingID])
    #expect(conversations.first?.title == "Keep me")
    #expect(Set(messages.map(\.id)) == Set(existingMessageIDs))
  }

  @MainActor
  @Test
  func exactReadBackRepairsAnUncoordinatedLateContextWrite() throws {
    let fixture = try makeFixture()
    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let plan = try MosaicPortableBackup.prepareRestore(from: data)
    let liveContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let liveContext = ModelContext(liveContainer)
    let lateConversationID = UUID()

    try MosaicPortableBackup.replaceLiveStore(
      using: plan,
      in: liveContext,
      beforeSave: {
        let lateContext = ModelContext(liveContainer)
        lateContext.insert(
          ConversationRecord(id: lateConversationID, title: "Uncoordinated late write")
        )
        try lateContext.save()
      }
    )

    let verificationContext = ModelContext(liveContainer)
    let conversationIDs = try verificationContext.fetch(
      FetchDescriptor<ConversationRecord>()
    ).map(\.id)
    #expect(conversationIDs == [fixture.conversationID])
    #expect(!conversationIDs.contains(lateConversationID))
  }

  @MainActor
  @Test
  func postCommitSignalFailureReturnsSuccessWhenReplacementIsAlreadyExact() throws {
    let fixture = try makeFixture()
    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let plan = try MosaicPortableBackup.prepareRestore(from: data)
    let liveContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let liveContext = ModelContext(liveContainer)
    liveContext.insert(ConversationRecord(title: "Obsolete"))
    try liveContext.save()

    try MosaicPortableBackup.replaceLiveStore(
      using: plan,
      in: liveContext,
      beforeSave: {},
      afterSave: { throw InjectedFailure.stop }
    )

    let verificationContext = ModelContext(liveContainer)
    let conversationIDs = try verificationContext.fetch(
      FetchDescriptor<ConversationRecord>()
    ).map(\.id)
    #expect(conversationIDs == [fixture.conversationID])
  }

  @MainActor
  @Test
  func postCommitMixedStateFailureCompensatesThePreviousLibrary() throws {
    let fixture = try makeFixture()
    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let plan = try MosaicPortableBackup.prepareRestore(from: data)
    let liveContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let liveContext = ModelContext(liveContainer)
    let existing = ConversationRecord(title: "Keep me")
    let existingID = existing.id
    liveContext.insert(existing)
    try liveContext.save()

    do {
      try MosaicPortableBackup.replaceLiveStore(
        using: plan,
        in: liveContext,
        beforeSave: {},
        afterSave: {
          let lateContext = ModelContext(liveContainer)
          lateContext.insert(ConversationRecord(title: "Post-commit mixed write"))
          try lateContext.save()
          throw InjectedFailure.stop
        }
      )
      Issue.record("Expected a compensated post-commit failure")
    } catch let error as MosaicPortableBackupError {
      #expect(error == .persistenceFailure)
    }

    let verificationContext = ModelContext(liveContainer)
    let conversations = try verificationContext.fetch(FetchDescriptor<ConversationRecord>())
    #expect(conversations.map(\.id) == [existingID])
    #expect(conversations.first?.title == "Keep me")
    #expect(try verificationContext.fetch(FetchDescriptor<MessageRecord>()).isEmpty)
  }

  @MainActor
  @Test
  func unverifiedOversizedCurrentGenerationDoesNotBlockAStagedRecovery() throws {
    let fixture = try makeFixture()
    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let plan = try MosaicPortableBackup.prepareRestore(from: data)
    let liveContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let liveContext = ModelContext(liveContainer)
    let invalidConversation = ConversationRecord(title: "Unverified")
    liveContext.insert(invalidConversation)
    liveContext.insert(
      MessageRecord(
        conversationID: invalidConversation.id,
        role: .user,
        content: String(repeating: "x", count: 9 * 1_024 * 1_024)
      )
    )
    try liveContext.save()

    #expect(throws: (any Error).self) {
      try MosaicPortableBackup.replaceLiveStore(using: plan, in: liveContext)
    }

    try MosaicPortableBackup.replaceLiveStore(
      using: plan,
      in: liveContext,
      beforeSave: {},
      requiresCompensation: false
    )

    let verificationContext = ModelContext(liveContainer)
    #expect(
      try verificationContext.fetch(FetchDescriptor<ConversationRecord>()).map(\.id)
        == [fixture.conversationID]
    )
  }

  @MainActor
  @Test
  func replaceSupportsAStoreThatAlreadyContainsTheBackedUpIdentifiers() throws {
    let fixture = try makeFixture()
    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let plan = try MosaicPortableBackup.prepareRestore(from: data)

    try MosaicPortableBackup.replaceLiveStore(using: plan, in: fixture.context)

    let conversations = try fixture.context.fetch(FetchDescriptor<ConversationRecord>())
    let messages = try fixture.context.fetch(FetchDescriptor<MessageRecord>())
    let providers = try fixture.context.fetch(FetchDescriptor<ProviderConfigurationRecord>())
    #expect(conversations.map(\.id) == [fixture.conversationID])
    #expect(Set(messages.map(\.id)) == Set(plan.snapshot.messages.map(\.id)))
    #expect(providers.map(\.id) == [plan.providerIDMap[fixture.providerID]])
  }

  @MainActor
  @Test
  func duplicateAndMissingHardReferencesFailBeforeAPlanExists() throws {
    let fixture = try makeFixture()
    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let snapshot = try MosaicPortableBackup.decode(data)

    let duplicate = copy(snapshot, conversations: snapshot.conversations + snapshot.conversations)
    let duplicateData = try MosaicPortableBackup.encodeUnchecked(
      snapshot: duplicate,
      limits: .default
    )
    do {
      _ = try MosaicPortableBackup.prepareRestore(from: duplicateData)
      Issue.record("Expected duplicate validation to fail")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .duplicateID(recordType: "conversation", id: fixture.conversationID)
      )
    }

    let originalMessage = try #require(snapshot.messages.first)
    let missingConversationID = UUID()
    let invalidMessage = MosaicPortableMessage(
      id: originalMessage.id,
      conversationID: missingConversationID,
      roleRawValue: originalMessage.roleRawValue,
      content: originalMessage.content,
      statusRawValue: originalMessage.statusRawValue,
      providerConfigurationID: originalMessage.providerConfigurationID,
      providerKindRawValue: originalMessage.providerKindRawValue,
      providerDisplayName: originalMessage.providerDisplayName,
      providerHost: originalMessage.providerHost,
      providerMessageID: originalMessage.providerMessageID,
      modelIdentifier: originalMessage.modelIdentifier,
      inputTokenCount: originalMessage.inputTokenCount,
      outputTokenCount: originalMessage.outputTokenCount,
      errorDescription: originalMessage.errorDescription,
      contextReceiptData: originalMessage.contextReceiptData,
      createdAt: originalMessage.createdAt,
      updatedAt: originalMessage.updatedAt
    )
    let missingReference = copy(snapshot, messages: [invalidMessage])
    let missingReferenceData = try MosaicPortableBackup.encodeUnchecked(
      snapshot: missingReference,
      limits: .default
    )
    do {
      _ = try MosaicPortableBackup.prepareRestore(from: missingReferenceData)
      Issue.record("Expected hard-reference validation to fail")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .missingConversation(
            messageID: originalMessage.id,
            conversationID: missingConversationID
          )
      )
    }

    let originalChunk = try #require(snapshot.documentChunks.first)
    let missingDocumentID = UUID()
    let invalidChunk = MosaicPortableDocumentChunk(
      id: originalChunk.id,
      documentID: missingDocumentID,
      chunkIndex: originalChunk.chunkIndex,
      content: originalChunk.content,
      pageNumber: originalChunk.pageNumber,
      isOCRDerived: originalChunk.isOCRDerived,
      createdAt: originalChunk.createdAt
    )
    let missingDocument = copy(snapshot, documentChunks: [invalidChunk])
    let missingDocumentData = try MosaicPortableBackup.encodeUnchecked(
      snapshot: missingDocument,
      limits: .default
    )
    do {
      _ = try MosaicPortableBackup.prepareRestore(from: missingDocumentData)
      Issue.record("Expected document hard-reference validation to fail")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .missingDocument(
            chunkID: originalChunk.id,
            documentID: missingDocumentID
          )
      )
    }

  }

  @MainActor
  @Test
  func restoreRejectsSourceFieldsThatExceedRuntimeRowLimits() throws {
    let fixture = try makeFixture()
    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let snapshot = try MosaicPortableBackup.decode(data)
    let original = try #require(snapshot.messages.first)
    let oversized = MosaicPortableMessage(
      id: original.id,
      conversationID: original.conversationID,
      roleRawValue: original.roleRawValue,
      content: String(
        repeating: "x",
        count: MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes + 1
      ),
      statusRawValue: original.statusRawValue,
      providerConfigurationID: original.providerConfigurationID,
      providerKindRawValue: original.providerKindRawValue,
      providerDisplayName: original.providerDisplayName,
      providerHost: original.providerHost,
      providerMessageID: original.providerMessageID,
      modelIdentifier: original.modelIdentifier,
      inputTokenCount: original.inputTokenCount,
      outputTokenCount: original.outputTokenCount,
      errorDescription: original.errorDescription,
      contextReceiptData: original.contextReceiptData,
      createdAt: original.createdAt,
      updatedAt: original.updatedAt
    )
    let archive = try MosaicPortableBackup.encodeUnchecked(
      snapshot: copy(snapshot, messages: [oversized]),
      limits: .default
    )

    do {
      _ = try MosaicPortableBackup.prepareRestore(from: archive)
      Issue.record("Expected oversized message content to be rejected")
    } catch let error as MosaicPortableBackupError {
      guard case .recordTooLarge(let type, let id, let actual, let maximum) = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(type == "message_content")
      #expect(id == original.id)
      #expect(actual == MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes + 1)
      #expect(maximum == MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes)
    }
  }

  @MainActor
  @Test
  func asyncTwoPhaseSurfaceMatchesTheDeterministicCodecAndStagesRestore() async throws {
    let fixture = try makeFixture()
    let snapshot = try MosaicPortableBackup.captureSnapshot(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let syncData = try MosaicPortableBackup.encode(snapshot: snapshot)
    let coordinator = MosaicOperationCoordinator.shared
    let reservedSnapshotLease = coordinator.beginVerifiedSourceSnapshotMaintenance()
    #expect(reservedSnapshotLease)
    let asyncData: Data
    if reservedSnapshotLease {
      defer { coordinator.endExclusiveMaintenance() }
      asyncData = try await MosaicPortableBackup.exportAsync(
        from: fixture.context,
        backupID: fixture.backupID,
        createdAt: fixture.date
      )
    } else {
      return
    }
    let plan = try await MosaicPortableBackup.prepareRestoreAsync(from: asyncData)

    let liveContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let liveContext = ModelContext(liveContainer)
    let obsoleteID = UUID()
    liveContext.insert(ConversationRecord(id: obsoleteID, title: "Obsolete"))
    try liveContext.save()
    try await MosaicPortableBackup.replaceLiveStoreAsync(using: plan, in: liveContext)
    let verificationContext = ModelContext(liveContainer)
    let restoredConversationIDs = try verificationContext.fetch(
      FetchDescriptor<ConversationRecord>()
    ).map(\.id)

    #expect(asyncData == syncData)
    #expect(plan.backupID == fixture.backupID)
    #expect(plan.snapshot.requestContextEvents.first?.payloadData == fixture.normalizedEventPayload)
    #expect(plan.snapshot.conversationCompactionHeads.first?.activeArtifactID == fixture.artifactID)
    #expect(restoredConversationIDs == [fixture.conversationID])
    #expect(!restoredConversationIDs.contains(obsoleteID))
  }

  @MainActor
  @Test
  func asyncCaptureValidatesPendingSourceFieldsBeforeItsMaintenanceFlush() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = ModelContext(container)
    context.insert(
      MemoryRecord(
        title: "Pending oversized memory",
        content: String(
          repeating: "x",
          count: MosaicSourceFieldLimits.maximumMemoryContentUTF8Bytes + 1
        )
      )
    )

    let coordinator = MosaicOperationCoordinator.shared
    let reservedSnapshotLease = coordinator.beginVerifiedSourceSnapshotMaintenance()
    #expect(reservedSnapshotLease)
    guard reservedSnapshotLease else { return }
    defer { coordinator.endExclusiveMaintenance() }

    do {
      _ = try await MosaicPortableBackup.captureSnapshotAsync(from: context)
      Issue.record("Expected the maintenance flush to reject the oversized pending source row")
    } catch let error as MosaicSourceFieldLimitError {
      #expect(
        error
          == .memoryContent(
            actual: MosaicSourceFieldLimits.maximumMemoryContentUTF8Bytes + 1,
            maximum: MosaicSourceFieldLimits.maximumMemoryContentUTF8Bytes
          )
      )
    }

    #expect(!context.hasChanges)
    let verificationContext = ModelContext(container)
    #expect(try verificationContext.fetch(FetchDescriptor<MemoryRecord>()).isEmpty)
  }

  @MainActor
  @Test
  func keysetCaptureIsCanonicalAndEnforcesRunningArchiveBudgets() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = ModelContext(container)
    let conversationID = UUID(uuidString: "10000000-0000-0000-0000-000000000000")!
    let backupID = UUID(uuidString: "20000000-0000-0000-0000-000000000000")!
    let date = Date(timeIntervalSinceReferenceDate: 999)
    context.insert(
      ConversationRecord(
        id: conversationID,
        title: "Paged capture",
        createdAt: date,
        updatedAt: date
      )
    )
    let messageIDs = [9, 2, 7, 1, 8, 3, 6, 4, 5].map { suffix in
      UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", suffix))!
    }
    for (index, id) in messageIDs.enumerated() {
      context.insert(
        MessageRecord(
          id: id,
          conversationID: conversationID,
          role: index.isMultiple(of: 2) ? .user : .assistant,
          content: "Message \(index)",
          createdAt: date.addingTimeInterval(Double(index)),
          updatedAt: date.addingTimeInterval(Double(index))
        )
      )
    }
    try context.save()

    let data = try MosaicPortableBackup.export(
      from: context,
      backupID: backupID,
      createdAt: date
    )
    let snapshot = try MosaicPortableBackup.captureSnapshot(
      from: context,
      backupID: backupID,
      createdAt: date,
      limits: MosaicPortableBackupLimits(
        maximumTotalBytes: data.count,
        maximumRecordBytes: .max,
        maximumRecordCount: .max
      )
    )
    #expect(snapshot.messages.map(\.id) == messageIDs.sorted { $0.uuidString < $1.uuidString })
    #expect(try MosaicPortableBackup.encode(snapshot: snapshot) == data)

    do {
      _ = try MosaicPortableBackup.captureSnapshot(
        from: context,
        backupID: backupID,
        createdAt: date,
        limits: MosaicPortableBackupLimits(
          maximumTotalBytes: data.count - 1,
          maximumRecordBytes: .max,
          maximumRecordCount: .max
        )
      )
      Issue.record("Expected capture to stop before retaining the over-budget final record")
    } catch let error as MosaicPortableBackupError {
      #expect(error == .backupTooLarge(actual: data.count, maximum: data.count - 1))
    }

    do {
      _ = try MosaicPortableBackup.captureSnapshot(
        from: context,
        backupID: backupID,
        createdAt: date,
        limits: MosaicPortableBackupLimits(
          maximumTotalBytes: .max,
          maximumRecordBytes: .max,
          maximumRecordCount: 5
        )
      )
      Issue.record("Expected capture to stop at the running record-count limit")
    } catch let error as MosaicPortableBackupError {
      #expect(error == .tooManyRecords(actual: 6, maximum: 5))
    }

    do {
      _ = try MosaicPortableBackup.captureSnapshot(
        from: context,
        backupID: backupID,
        createdAt: date,
        limits: MosaicPortableBackupLimits(
          maximumTotalBytes: .max,
          maximumRecordBytes: 8,
          maximumRecordCount: .max
        )
      )
      Issue.record("Expected capture to reject the oversized record before retaining it")
    } catch let error as MosaicPortableBackupError {
      guard case .recordTooLarge(let recordType, let id, _, let maximum) = error else {
        Issue.record("Expected a record-too-large error, received \(error)")
        return
      }
      #expect(recordType == "conversation")
      #expect(id == conversationID)
      #expect(maximum == 8)
    }
  }

  @MainActor
  @Test
  func capturePreservesTheDomainErrorForANonFiniteEmbeddingWeight() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = ModelContext(container)
    let profileID = UUID()
    context.insert(
      EmbeddingProfileRecord(
        id: profileID,
        displayName: "Invalid weight",
        providerConfigurationID: nil,
        modelIdentifier: "embedding-test",
        weight: .nan
      )
    )

    do {
      _ = try MosaicPortableBackup.captureSnapshot(from: context)
      Issue.record("Expected the non-finite weight to fail with its domain error")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .invalidNumber(
            recordType: "embedding_profile",
            id: profileID,
            field: "weight"
          )
      )
    }
  }

  @MainActor
  @Test
  func tamperingAndUnsupportedReaderVersionFailClosed() throws {
    let fixture = try makeFixture()
    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )

    var tamperedObject = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    var snapshotObject = try #require(tamperedObject["snapshot"] as? [String: Any])
    var conversations = try #require(snapshotObject["conversations"] as? [[String: Any]])
    conversations[0]["title"] = "Tampered"
    snapshotObject["conversations"] = conversations
    tamperedObject["snapshot"] = snapshotObject
    let tamperedData = try JSONSerialization.data(withJSONObject: tamperedObject)

    do {
      _ = try MosaicPortableBackup.decode(tamperedData)
      Issue.record("Expected checksum validation to fail")
    } catch let error as MosaicPortableBackupError {
      #expect(error == .checksumMismatch)
    }

    var newerObject = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    newerObject["minimumReaderVersion"] = MosaicPortableBackup.currentReaderVersion + 1
    let newerData = try JSONSerialization.data(withJSONObject: newerObject)
    do {
      _ = try MosaicPortableBackup.decode(newerData)
      Issue.record("Expected the newer reader requirement to fail")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .readerTooOld(
            required: MosaicPortableBackup.currentReaderVersion + 1,
            current: MosaicPortableBackup.currentReaderVersion
          )
      )
    }

    var futureFormatObject = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    futureFormatObject["formatVersion"] = MosaicPortableBackup.currentFormatVersion + 1
    let futureFormatData = try JSONSerialization.data(withJSONObject: futureFormatObject)
    do {
      _ = try MosaicPortableBackup.decode(futureFormatData)
      Issue.record("Expected the future format version to fail")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .unsupportedFormatVersion(
            found: MosaicPortableBackup.currentFormatVersion + 1,
            supported: MosaicPortableBackup.currentFormatVersion
          )
      )
    }
  }

  @MainActor
  @Test
  func totalAndPerRecordLimitsAreEnforced() throws {
    let fixture = try makeFixture()
    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )

    do {
      _ = try MosaicPortableBackup.decode(
        data,
        limits: MosaicPortableBackupLimits(
          maximumTotalBytes: data.count - 1,
          maximumRecordBytes: .max
        )
      )
      Issue.record("Expected the total-size limit to fail")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .backupTooLarge(actual: data.count, maximum: data.count - 1)
      )
    }

    let snapshot = try MosaicPortableBackup.decode(data)
    do {
      _ = try MosaicPortableBackup.encode(
        snapshot: snapshot,
        limits: MosaicPortableBackupLimits(
          maximumTotalBytes: .max,
          maximumRecordBytes: 8
        )
      )
      Issue.record("Expected the record-size limit to fail")
    } catch let error as MosaicPortableBackupError {
      guard case .recordTooLarge = error else {
        Issue.record("Expected a record-too-large error, received \(error)")
        return
      }
    }
  }

  @MainActor
  @Test
  func malformedCountersAndUnknownMemoryScopeFailWithoutOverflowOrScopeWidening() throws {
    let fixture = try makeFixture()
    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let snapshot = try MosaicPortableBackup.decode(data)

    let progress = try #require(snapshot.normalizedBackfillProgress.first)
    let overflowingProgress = MosaicPortableNormalizedContextBackfillProgress(
      migrationKey: progress.migrationKey,
      lastEventKey: progress.lastEventKey,
      processedCount: .max,
      migratedCount: .max,
      retainedLegacyCount: 1,
      failureCount: 0,
      isComplete: false,
      updatedAt: progress.updatedAt
    )
    let overflowingData = try MosaicPortableBackup.encodeUnchecked(
      snapshot: copy(snapshot, normalizedBackfillProgress: [overflowingProgress]),
      limits: .default
    )
    do {
      _ = try MosaicPortableBackup.decode(overflowingData)
      Issue.record("Expected overflowing progress counters to fail closed")
    } catch let error as MosaicPortableBackupError {
      guard case .invalidNormalizedInvariant(let recordType, _, let field) = error else {
        Issue.record("Expected invalid progress counters, received \(error)")
        return
      }
      #expect(recordType == "normalized_backfill_progress")
      #expect(field == "counts")
    }

    let memory = try #require(snapshot.memories.first)
    let unknownScopeMemory = MosaicPortableMemory(
      id: memory.id,
      title: memory.title,
      content: memory.content,
      scopeRawValue: "future_scope_that_must_not_become_global",
      conversationID: memory.conversationID,
      isEnabled: true,
      isUserApproved: true,
      createdAt: memory.createdAt,
      updatedAt: memory.updatedAt
    )
    let unknownScopeData = try MosaicPortableBackup.encodeUnchecked(
      snapshot: copy(snapshot, memories: [unknownScopeMemory]),
      limits: .default
    )
    do {
      _ = try MosaicPortableBackup.decode(unknownScopeData)
      Issue.record("Expected an unknown memory scope to fail closed")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .invalidNormalizedInvariant(
            recordType: "memory",
            id: memory.id,
            field: "scope"
          )
      )
    }
  }

  @MainActor
  @Test
  func normalizedPayloadTamperAndBrokenHeadReferenceAreRejected() throws {
    let fixture = try makeFixture()
    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let snapshot = try MosaicPortableBackup.decode(data)
    let event = try #require(snapshot.requestContextEvents.first)
    let corruptedEvent = MosaicPortableRequestContextEvent(
      id: event.id,
      eventKey: event.eventKey,
      assistantMessageID: event.assistantMessageID,
      conversationID: event.conversationID,
      sourceThroughMessageID: event.sourceThroughMessageID,
      sourceMessageCount: event.sourceMessageCount,
      eventSequence: event.eventSequence,
      payloadData: event.payloadData + Data([0x00]),
      payloadFingerprint: event.payloadFingerprint,
      legacyReceiptFingerprint: event.legacyReceiptFingerprint,
      createdAt: event.createdAt
    )
    let corruptSnapshot = copy(snapshot, requestContextEvents: [corruptedEvent])
    let corruptData = try MosaicPortableBackup.encodeUnchecked(
      snapshot: corruptSnapshot,
      limits: .default
    )
    do {
      _ = try MosaicPortableBackup.decode(corruptData)
      Issue.record("Expected normalized payload fingerprint validation to fail")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .normalizedFingerprintMismatch(
            recordType: "request_context_event",
            id: event.id
          )
      )
    }

    let brokenArtifactID = UUID()
    let head = try #require(snapshot.conversationCompactionHeads.first)
    let brokenHead = MosaicPortableConversationCompactionHead(
      conversationID: head.conversationID,
      activeArtifactID: brokenArtifactID,
      revision: head.revision,
      updatedAt: head.updatedAt
    )
    let brokenSnapshot = copy(snapshot, conversationCompactionHeads: [brokenHead])
    let brokenData = try MosaicPortableBackup.encodeUnchecked(
      snapshot: brokenSnapshot,
      limits: .default
    )
    do {
      _ = try MosaicPortableBackup.decode(brokenData)
      Issue.record("Expected normalized head reference validation to fail")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .missingNormalizedReference(
            recordType: "conversation_compaction_head",
            id: fixture.conversationID,
            field: "active_artifact",
            targetID: brokenArtifactID
          )
      )
    }

    let artifact = try #require(snapshot.compactionArtifacts.first)
    let tamperedArtifact = copyArtifact(
      artifact,
      renderedSummary: artifact.renderedSummary + " tampered"
    )
    let tamperedArtifactSnapshot = copy(snapshot, compactionArtifacts: [tamperedArtifact])
    let tamperedArtifactData = try MosaicPortableBackup.encodeUnchecked(
      snapshot: tamperedArtifactSnapshot,
      limits: .default
    )
    do {
      _ = try MosaicPortableBackup.decode(tamperedArtifactData)
      Issue.record("Expected artifact fingerprint validation to fail")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .normalizedFingerprintMismatch(
            recordType: "compaction_artifact",
            id: fixture.artifactID
          )
      )
    }

    let missingParentID = UUID()
    let orphanedArtifact = copyArtifact(
      artifact,
      lineagePreviousCompactionID: missingParentID,
      coverageParentArtifactID: missingParentID
    )
    let orphanedArtifactSnapshot = copy(snapshot, compactionArtifacts: [orphanedArtifact])
    let orphanedArtifactData = try MosaicPortableBackup.encodeUnchecked(
      snapshot: orphanedArtifactSnapshot,
      limits: .default
    )
    do {
      _ = try MosaicPortableBackup.decode(orphanedArtifactData)
      Issue.record("Expected artifact parent validation to fail")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .missingNormalizedReference(
            recordType: "compaction_artifact",
            id: fixture.artifactID,
            field: "coverage_parent",
            targetID: missingParentID
          )
      )
    }
  }

  @MainActor
  @Test
  func requestEventIdentityAndCanonicalSourceBoundaryCannotBeRebound() throws {
    let fixture = try makeFixture()
    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let snapshot = try MosaicPortableBackup.decode(data)
    let event = try #require(snapshot.requestContextEvents.first)

    let reboundIdentity = MosaicPortableRequestContextEvent(
      id: UUID(),
      eventKey: event.eventKey,
      assistantMessageID: event.assistantMessageID,
      conversationID: event.conversationID,
      sourceThroughMessageID: event.sourceThroughMessageID,
      sourceMessageCount: event.sourceMessageCount,
      eventSequence: event.eventSequence,
      payloadData: event.payloadData,
      payloadFingerprint: event.payloadFingerprint,
      legacyReceiptFingerprint: event.legacyReceiptFingerprint,
      createdAt: event.createdAt
    )
    let reboundIdentityData = try MosaicPortableBackup.encodeUnchecked(
      snapshot: copy(snapshot, requestContextEvents: [reboundIdentity]),
      limits: .default
    )
    do {
      _ = try MosaicPortableBackup.decode(reboundIdentityData)
      Issue.record("Expected deterministic event identity validation to fail")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .invalidNormalizedInvariant(
            recordType: "request_context_event",
            id: reboundIdentity.id,
            field: "id"
          )
      )
    }

    let laterMessageID = UUID()
    let laterMessage = MosaicPortableMessage(
      id: laterMessageID,
      conversationID: fixture.conversationID,
      roleRawValue: MessageRole.user.rawValue,
      content: "Later source that cannot be rebound into an older request",
      statusRawValue: MessageStatus.complete.rawValue,
      providerConfigurationID: nil,
      providerKindRawValue: nil,
      providerDisplayName: nil,
      providerHost: nil,
      providerMessageID: nil,
      modelIdentifier: nil,
      inputTokenCount: nil,
      outputTokenCount: nil,
      errorDescription: nil,
      contextReceiptData: nil,
      createdAt: fixture.date.addingTimeInterval(1),
      updatedAt: fixture.date.addingTimeInterval(1)
    )
    let reboundSource = MosaicPortableRequestContextEvent(
      id: event.id,
      eventKey: event.eventKey,
      assistantMessageID: event.assistantMessageID,
      conversationID: event.conversationID,
      sourceThroughMessageID: laterMessageID,
      sourceMessageCount: event.sourceMessageCount,
      eventSequence: event.eventSequence,
      payloadData: event.payloadData,
      payloadFingerprint: event.payloadFingerprint,
      legacyReceiptFingerprint: event.legacyReceiptFingerprint,
      createdAt: event.createdAt
    )
    let reboundSourceData = try MosaicPortableBackup.encodeUnchecked(
      snapshot: copy(
        snapshot,
        messages: snapshot.messages + [laterMessage],
        requestContextEvents: [reboundSource]
      ),
      limits: .default
    )
    do {
      _ = try MosaicPortableBackup.decode(reboundSourceData)
      Issue.record("Expected canonical request boundary validation to fail")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .invalidNormalizedInvariant(
            recordType: "request_context_event",
            id: event.id,
            field: "source_message"
          )
      )
    }

    let earlierAssistantID = UUID()
    let earlierAssistant = MosaicPortableMessage(
      id: earlierAssistantID,
      conversationID: fixture.conversationID,
      roleRawValue: MessageRole.assistant.rawValue,
      content: "Earlier assistant that cannot own a later request source",
      statusRawValue: MessageStatus.complete.rawValue,
      providerConfigurationID: nil,
      providerKindRawValue: nil,
      providerDisplayName: nil,
      providerHost: nil,
      providerMessageID: nil,
      modelIdentifier: nil,
      inputTokenCount: nil,
      outputTokenCount: nil,
      errorDescription: nil,
      contextReceiptData: nil,
      createdAt: fixture.date.addingTimeInterval(-2),
      updatedAt: fixture.date.addingTimeInterval(-2)
    )
    let reboundAssistant = MosaicPortableRequestContextEvent(
      id: NormalizedContextStore.eventID(
        assistantMessageID: earlierAssistantID,
        eventSequence: event.eventSequence
      ),
      eventKey: NormalizedContextStore.eventKey(
        assistantMessageID: earlierAssistantID,
        eventSequence: event.eventSequence
      ),
      assistantMessageID: earlierAssistantID,
      conversationID: event.conversationID,
      sourceThroughMessageID: event.sourceThroughMessageID,
      sourceMessageCount: 2,
      eventSequence: event.eventSequence,
      payloadData: event.payloadData,
      payloadFingerprint: event.payloadFingerprint,
      legacyReceiptFingerprint: event.legacyReceiptFingerprint,
      createdAt: event.createdAt
    )
    let reboundAssistantData = try MosaicPortableBackup.encodeUnchecked(
      snapshot: copy(
        snapshot,
        messages: snapshot.messages + [earlierAssistant],
        requestContextEvents: [reboundAssistant]
      ),
      limits: .default
    )
    do {
      _ = try MosaicPortableBackup.decode(reboundAssistantData)
      Issue.record("Expected an assistant inside its own source prefix to fail")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .invalidNormalizedInvariant(
            recordType: "request_context_event",
            id: reboundAssistant.id,
            field: "source_message"
          )
      )
    }
  }

  @MainActor
  @Test
  func compactionCoverageDepthCapCannotBeBypassedByResolvedParents() throws {
    let fixture = try makeFixture()
    let data = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let snapshot = try MosaicPortableBackup.decode(data)
    let template = try #require(snapshot.compactionArtifacts.first)
    let canonicalMessage = try #require(snapshot.messages.first)
    let rootDelta = try JSONEncoder().encode([canonicalMessage.id])
    let emptyDelta = try JSONEncoder().encode([UUID]())
    var artifacts: [MosaicPortableCompactionArtifact] = []
    var parentID: UUID?

    for index in 0...1_024 {
      let id = UUID()
      artifacts.append(
        copyArtifact(
          template,
          id: id,
          lineagePreviousCompactionID: parentID,
          coverageParentArtifactID: parentID,
          coverageDeltaData: index == 0 ? rootDelta : emptyDelta,
          coveredMessageCount: 1,
          isSnapshotComplete: false
        )
      )
      parentID = id
    }

    do {
      try MosaicPortableBackup.validateCompactionCoverage(
        artifactsByID: Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) }),
        canonicalMessagesByConversation: [fixture.conversationID: [canonicalMessage]]
      )
      Issue.record("Expected the real resolved coverage depth cap to fail closed")
    } catch let error as MosaicPortableBackupError {
      guard case .invalidNormalizedInvariant(let recordType, _, let field) = error else {
        Issue.record("Expected an invalid coverage depth, received \(error)")
        return
      }
      #expect(recordType == "compaction_artifact")
      #expect(field == "coverage_depth")
    }
  }

  @MainActor
  @Test
  func unknownExtensionRecordIsIntegrityCheckedButRestoreFailsClosed() throws {
    let fixture = try makeFixture()
    let snapshot = try MosaicPortableBackup.captureSnapshot(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date,
      extensionRecords: [
        MosaicPortableExtensionRecord(
          namespace: "com.example.future",
          recordType: "future_record",
          recordVersion: 1,
          id: UUID(uuidString: "80000000-0000-0000-0000-000000000008")!,
          payload: Data([0x01, 0x02, 0x03])
        )
      ]
    )
    let data = try MosaicPortableBackup.encode(snapshot: snapshot)
    #expect(try MosaicPortableBackup.decode(data).extensionRecords == snapshot.extensionRecords)

    do {
      _ = try MosaicPortableBackup.prepareRestore(from: data)
      Issue.record("Expected an unknown extension to fail closed during staging")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .unsupportedExtensionRecord(
            namespace: "com.example.future",
            recordType: "future_record",
            version: 1
          )
      )
    }
  }

  @MainActor
  @Test
  func restoreStagingRejectsMalformedLegacyReceiptAndSnapshotBlobs() throws {
    let fixture = try makeFixture()
    let exported = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let snapshot = try MosaicPortableBackup.decode(exported)
    let originalConversation = try #require(snapshot.conversations.first)
    let originalLegacySnapshot = try JSONDecoder().decode(
      ConversationCompactionSnapshot.self,
      from: fixture.compactionBlob
    )
    let malformedSnapshot = ConversationCompactionSnapshot(
      id: UUID(),
      conversationID: fixture.conversationID,
      previousCompactionID: UUID(),
      mode: .extend,
      content: ConversationCompactionContent(overview: "Unsafe", items: []),
      coveredMessageIDs: originalLegacySnapshot.coveredMessageIDs,
      sourceFingerprint: originalLegacySnapshot.sourceFingerprint,
      providerConfigurationID: fixture.providerID,
      providerKind: .openAI,
      providerDisplayName: "OpenAI",
      providerEndpoint: "https://api.openai.com:443/v1",
      modelIdentifier: "gpt-test",
      estimatedSourceTokens: 1,
      estimatedSummaryTokens: 1,
      chainDepth: .max,
      createdAt: fixture.date
    )
    let poisonedConversation = MosaicPortableConversation(
      id: originalConversation.id,
      title: originalConversation.title,
      providerConfigurationID: originalConversation.providerConfigurationID,
      modelIdentifier: originalConversation.modelIdentifier,
      systemPrompt: originalConversation.systemPrompt,
      draftText: originalConversation.draftText,
      compactionSnapshotData: try JSONEncoder().encode(malformedSnapshot),
      isArchived: originalConversation.isArchived,
      createdAt: originalConversation.createdAt,
      updatedAt: originalConversation.updatedAt
    )
    let poisonedSnapshotArchive = try MosaicPortableBackup.encode(
      snapshot: copy(snapshot, conversations: [poisonedConversation])
    )
    do {
      _ = try MosaicPortableBackup.prepareRestore(from: poisonedSnapshotArchive)
      Issue.record("Expected invalid legacy compaction lineage to fail staging")
    } catch let error as MosaicPortableBackupError {
      #expect(error == .stagingVerificationFailed)
    }

    let originalMessage = try #require(snapshot.messages.first)
    let malformedReceipt = RequestContextReceipt(
      curatedContext: .empty,
      retrievedContext: .empty,
      conversationContext: ConversationContextReceipt(
        strategy: .full,
        originalMessageCount: 0,
        includedMessageIDs: [],
        omittedMessageIDs: [],
        estimatedInputTokens: 0,
        contextWindowTokens: .min,
        maximumOutputTokens: 1,
        safetyMarginTokens: 0
      ),
      createdAt: fixture.date
    )
    let poisonedMessage = MosaicPortableMessage(
      id: originalMessage.id,
      conversationID: originalMessage.conversationID,
      roleRawValue: originalMessage.roleRawValue,
      content: originalMessage.content,
      statusRawValue: originalMessage.statusRawValue,
      providerConfigurationID: originalMessage.providerConfigurationID,
      providerKindRawValue: originalMessage.providerKindRawValue,
      providerDisplayName: originalMessage.providerDisplayName,
      providerHost: originalMessage.providerHost,
      providerMessageID: originalMessage.providerMessageID,
      modelIdentifier: originalMessage.modelIdentifier,
      inputTokenCount: originalMessage.inputTokenCount,
      outputTokenCount: originalMessage.outputTokenCount,
      errorDescription: originalMessage.errorDescription,
      contextReceiptData: try JSONEncoder().encode(malformedReceipt),
      createdAt: originalMessage.createdAt,
      updatedAt: originalMessage.updatedAt
    )
    let poisonedReceiptArchive = try MosaicPortableBackup.encode(
      snapshot: copy(
        snapshot,
        messages: snapshot.messages.map { message in
          message.id == poisonedMessage.id ? poisonedMessage : message
        }
      )
    )
    do {
      _ = try MosaicPortableBackup.prepareRestore(from: poisonedReceiptArchive)
      Issue.record("Expected invalid legacy receipt arithmetic to fail staging")
    } catch let error as MosaicPortableBackupError {
      #expect(error == .stagingVerificationFailed)
    }
  }

  @MainActor
  @Test
  func activeCompactionHeadCannotReferenceAnIncompleteArtifact() throws {
    let fixture = try makeFixture()
    let exported = try MosaicPortableBackup.export(
      from: fixture.context,
      backupID: fixture.backupID,
      createdAt: fixture.date
    )
    let snapshot = try MosaicPortableBackup.decode(exported)
    let artifact = try #require(snapshot.compactionArtifacts.first)
    let incompleteBase = copyArtifact(artifact, isSnapshotComplete: false)
    let incomplete = copyArtifact(
      incompleteBase,
      payloadFingerprint: try MosaicPortableBackup.compactionArtifactFingerprint(incompleteBase)
    )
    let poisoned = try MosaicPortableBackup.encodeUnchecked(
      snapshot: copy(snapshot, compactionArtifacts: [incomplete]),
      limits: .default
    )
    do {
      _ = try MosaicPortableBackup.decode(poisoned)
      Issue.record("Expected an incomplete active artifact to fail closed")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .invalidNormalizedInvariant(
            recordType: "conversation_compaction_head",
            id: fixture.conversationID,
            field: "active_artifact_complete"
          )
      )
    }
  }
}

private enum InjectedFailure: Error {
  case stop
}

private struct BackupFixture {
  let context: ModelContext
  let backupID: UUID
  let date: Date
  let providerID: UUID
  let conversationID: UUID
  let messageID: UUID
  let userMessageID: UUID
  let profileID: UUID
  let orphanProfileID: UUID
  let orphanMemoryID: UUID
  let compactionBlob: Data
  let receiptBlob: Data
  let artifactID: UUID
  let normalizedEventPayload: Data
  let normalizedWarningsBlob: Data
}

@MainActor
private func makeFixture() throws -> BackupFixture {
  let container = try MosaicSchema.makeModelContainer(inMemory: true)
  let context = ModelContext(container)
  let date = Date(timeIntervalSinceReferenceDate: 123_456.789)
  let providerID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
  let conversationID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
  let messageID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
  let userMessageID = UUID(uuidString: "30000000-0000-0000-0000-000000000004")!
  let profileID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
  let orphanProfileID = UUID(uuidString: "40000000-0000-0000-0000-000000000005")!
  let orphanMemoryID = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
  let documentID = UUID(uuidString: "60000000-0000-0000-0000-000000000006")!
  let artifactID = UUID(uuidString: "70000000-0000-0000-0000-000000000007")!
  let canonicalMessages = [
    AIChatMessage(id: userMessageID, role: .user, content: "Merhaba"),
    AIChatMessage(id: messageID, role: .assistant, content: "Merhaba 👋"),
  ]
  let compactionSnapshot = ConversationCompactionSnapshot(
    id: artifactID,
    conversationID: conversationID,
    mode: .initial,
    content: ConversationCompactionContent(overview: "Summary", items: []),
    coveredMessageIDs: canonicalMessages.map(\.id),
    sourceFingerprint: ConversationCompactionPlanner.sourceFingerprint(for: canonicalMessages),
    providerConfigurationID: providerID,
    providerKind: .openAI,
    providerDisplayName: "OpenAI",
    providerEndpoint: "https://api.openai.com:443/v1",
    modelIdentifier: "gpt-test",
    estimatedSourceTokens: 12,
    estimatedSummaryTokens: 3,
    chainDepth: 1,
    warnings: ["normalized-warning"],
    createdAt: date
  )
  let compactionBlob = try JSONEncoder().encode(compactionSnapshot)
  let receiptBlob = try JSONEncoder().encode(
    RequestContextReceipt(
      curatedContext: .empty,
      retrievedContext: .empty,
      createdAt: date
    )
  )

  context.insert(
    ProviderConfigurationRecord(
      id: providerID,
      displayName: "OpenAI",
      provider: .openAI,
      modelIdentifier: "gpt-test",
      baseURL: URL(string: "https://api.openai.com/v1"),
      contextWindowTokens: 32_000,
      maximumOutputTokens: 4_096,
      createdAt: date,
      updatedAt: date
    )
  )
  let conversation = ConversationRecord(
    id: conversationID,
    title: "Portable chat",
    providerConfigurationID: providerID,
    modelIdentifier: "gpt-test",
    systemPrompt: "Stay exact",
    draftText: "draft",
    isArchived: true,
    createdAt: date,
    updatedAt: date
  )
  conversation.compactionSnapshotData = compactionBlob
  context.insert(conversation)
  context.insert(
    MessageRecord(
      id: userMessageID,
      conversationID: conversationID,
      role: .user,
      content: "Merhaba",
      status: .complete,
      createdAt: date.addingTimeInterval(-1),
      updatedAt: date.addingTimeInterval(-1)
    )
  )
  let message = MessageRecord(
    id: messageID,
    conversationID: conversationID,
    role: .assistant,
    content: "Merhaba 👋",
    status: .complete,
    providerConfigurationID: providerID,
    providerKind: .openAI,
    providerDisplayName: "OpenAI",
    providerHost: "api.openai.com",
    providerMessageID: "response-1",
    modelIdentifier: "gpt-test",
    inputTokenCount: 11,
    outputTokenCount: 7,
    errorDescription: nil,
    createdAt: date,
    updatedAt: date
  )
  message.contextReceiptData = receiptBlob
  context.insert(message)
  context.insert(
    MemoryRecord(
      title: "Scoped fact",
      content: "Current conversation fact",
      scope: .conversation,
      conversationID: conversationID,
      createdAt: date,
      updatedAt: date
    )
  )
  context.insert(
    MemoryRecord(
      id: orphanMemoryID,
      title: "Orphaned fact",
      content: "Must be disabled",
      scope: .conversation,
      conversationID: UUID(),
      createdAt: date,
      updatedAt: date
    )
  )
  context.insert(
    ScheduledTaskRecord(
      title: "Daily follow-up",
      prompt: "Run me only after review",
      conversationID: conversationID,
      providerConfigurationID: providerID,
      recurrence: .daily,
      status: .active,
      scheduledAt: date,
      timeZoneIdentifier: "Europe/Istanbul",
      nextRunAt: date,
      createdAt: date,
      updatedAt: date
    )
  )
  context.insert(
    EmbeddingProfileRecord(
      id: profileID,
      displayName: "Provider embeddings",
      providerConfigurationID: providerID,
      modelIdentifier: "embedding-test",
      weight: 0.75,
      createdAt: date,
      updatedAt: date
    )
  )
  context.insert(
    EmbeddingProfileRecord(
      id: orphanProfileID,
      displayName: "Orphan embeddings",
      providerConfigurationID: UUID(),
      modelIdentifier: "embedding-missing",
      weight: 1,
      createdAt: date,
      updatedAt: date
    )
  )
  context.insert(
    ImportedDocumentRecord(
      id: documentID,
      title: "Reference",
      sourceFilename: "reference.pdf",
      mimeType: "application/pdf",
      contentFingerprint: "fingerprint",
      characterCount: 14,
      pageCount: 1,
      ocrPageCount: 1,
      ocrFallbackPageCount: 0,
      createdAt: date,
      updatedAt: date
    )
  )
  context.insert(
    DocumentChunkRecord(
      documentID: documentID,
      chunkIndex: 0,
      content: "Belge içeriği",
      pageNumber: 1,
      isOCRDerived: true,
      createdAt: date
    )
  )
  try context.save()

  let normalizedStore = NormalizedContextStore(modelContext: context)
  _ = try normalizedStore.persistCompactionArtifact(
    snapshot: compactionSnapshot,
    canonicalMessages: canonicalMessages
  )
  try normalizedStore.advanceCompactionHead(
    conversationID: conversationID,
    to: artifactID,
    expectedCurrentArtifactID: nil,
    canonicalMessages: canonicalMessages,
    at: date
  )
  _ = try normalizedStore.appendRequestEvent(
    assistantMessageID: messageID,
    conversationID: conversationID,
    sourceThroughMessageID: userMessageID,
    eventSequence: 0,
    receipt: .empty,
    canonicalMessages: Array(canonicalMessages.prefix(1)),
    createdAt: date
  )
  context.insert(
    NormalizedContextBackfillProgressRecord(
      migrationKey: "portable-backfill-v1",
      lastEventKey: "request-context/v1/example/6",
      processedCount: 7,
      migratedCount: 5,
      retainedLegacyCount: 2,
      failureCount: 2,
      isComplete: false,
      updatedAt: date
    )
  )
  try context.save()
  let normalizedEventPayload = try #require(
    try context.fetch(FetchDescriptor<RequestContextEventRecord>()).first?.payloadData
  )
  let normalizedWarningsBlob = try #require(
    try context.fetch(FetchDescriptor<CompactionArtifactRecord>()).first?.warningsData
  )

  return BackupFixture(
    context: context,
    backupID: UUID(uuidString: "90000000-0000-0000-0000-000000000009")!,
    date: date,
    providerID: providerID,
    conversationID: conversationID,
    messageID: messageID,
    userMessageID: userMessageID,
    profileID: profileID,
    orphanProfileID: orphanProfileID,
    orphanMemoryID: orphanMemoryID,
    compactionBlob: compactionBlob,
    receiptBlob: receiptBlob,
    artifactID: artifactID,
    normalizedEventPayload: normalizedEventPayload,
    normalizedWarningsBlob: normalizedWarningsBlob
  )
}

private func copy(
  _ snapshot: MosaicPortableBackupSnapshot,
  conversations: [MosaicPortableConversation]? = nil,
  messages: [MosaicPortableMessage]? = nil,
  memories: [MosaicPortableMemory]? = nil,
  providerConfigurations: [MosaicPortableProviderConfiguration]? = nil,
  documentChunks: [MosaicPortableDocumentChunk]? = nil,
  requestContextEvents: [MosaicPortableRequestContextEvent]? = nil,
  compactionArtifacts: [MosaicPortableCompactionArtifact]? = nil,
  conversationCompactionHeads: [MosaicPortableConversationCompactionHead]? = nil,
  normalizedBackfillProgress: [MosaicPortableNormalizedContextBackfillProgress]? = nil,
  extensionRecords: [MosaicPortableExtensionRecord]? = nil
) -> MosaicPortableBackupSnapshot {
  MosaicPortableBackupSnapshot(
    backupID: snapshot.backupID,
    createdAt: snapshot.createdAt,
    sourceSchemaVersion: snapshot.sourceSchemaVersion,
    conversations: conversations ?? snapshot.conversations,
    messages: messages ?? snapshot.messages,
    memories: memories ?? snapshot.memories,
    scheduledTasks: snapshot.scheduledTasks,
    providerConfigurations: providerConfigurations ?? snapshot.providerConfigurations,
    embeddingProfiles: snapshot.embeddingProfiles,
    importedDocuments: snapshot.importedDocuments,
    documentChunks: documentChunks ?? snapshot.documentChunks,
    requestContextEvents: requestContextEvents ?? snapshot.requestContextEvents,
    compactionArtifacts: compactionArtifacts ?? snapshot.compactionArtifacts,
    conversationCompactionHeads:
      conversationCompactionHeads ?? snapshot.conversationCompactionHeads,
    normalizedBackfillProgress:
      normalizedBackfillProgress ?? snapshot.normalizedBackfillProgress,
    extensionRecords: extensionRecords ?? snapshot.extensionRecords
  )
}

private func copyArtifact(
  _ artifact: MosaicPortableCompactionArtifact,
  id: UUID? = nil,
  lineagePreviousCompactionID: UUID? = nil,
  coverageParentArtifactID: UUID? = nil,
  coverageDeltaData: Data? = nil,
  coveredMessageCount: Int? = nil,
  renderedSummary: String? = nil,
  isSnapshotComplete: Bool? = nil,
  payloadFingerprint: String? = nil
) -> MosaicPortableCompactionArtifact {
  MosaicPortableCompactionArtifact(
    id: id ?? artifact.id,
    conversationID: artifact.conversationID,
    lineagePreviousCompactionID: lineagePreviousCompactionID,
    coverageParentArtifactID: coverageParentArtifactID,
    coverageDeltaData: coverageDeltaData ?? artifact.coverageDeltaData,
    coveredMessageCount: coveredMessageCount ?? artifact.coveredMessageCount,
    modeRawValue: artifact.modeRawValue,
    promptVersion: artifact.promptVersion,
    contentSchemaVersion: artifact.contentSchemaVersion,
    contentData: artifact.contentData,
    renderedSummary: renderedSummary ?? artifact.renderedSummary,
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
    isSnapshotComplete: isSnapshotComplete ?? artifact.isSnapshotComplete,
    isDetachedCoverageRoot: artifact.isDetachedCoverageRoot,
    payloadFingerprint: payloadFingerprint ?? artifact.payloadFingerprint,
    createdAt: artifact.createdAt
  )
}

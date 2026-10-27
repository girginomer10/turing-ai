import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite(.serialized)
struct ProjectPortableBackupTests {
  @MainActor
  @Test
  func projectGraphRoundTripsDeterministicallyAndSurvivesRestoreTransformation() throws {
    let source = try makeProjectBackupFixture()

    let data = try MosaicPortableBackup.export(
      from: source.context,
      backupID: source.backupID,
      createdAt: source.date
    )
    let repeated = try MosaicPortableBackup.export(
      from: source.context,
      backupID: source.backupID,
      createdAt: source.date
    )
    let decoded = try MosaicPortableBackup.decode(data)

    #expect(data == repeated)
    #expect(decoded.sourceSchemaVersion == "mosaic-main-6")
    #expect(decoded.extensionRecords.filter(ProjectPortableArchive.isOwned).count == 5)
    #expect(
      decoded.extensionRecords.filter(AutomaticMemoryPortableArchive.isOwned).count == 2
    )

    let expectedProjectRecords = decoded.extensionRecords.filter(ProjectPortableArchive.isOwned)
    let plan = try MosaicPortableBackup.prepareRestore(from: data)
    #expect(
      plan.snapshot.extensionRecords.filter(ProjectPortableArchive.isOwned)
        == expectedProjectRecords)

    let targetContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let targetContext = ModelContext(targetContainer)
    try MosaicPortableBackup.replaceLiveStore(using: plan, in: targetContext)

    let projects = try targetContext.fetch(FetchDescriptor<ProjectRecord>())
    let bindings = try targetContext.fetch(FetchDescriptor<ProjectResourceBindingRecord>())
    let memories = try targetContext.fetch(FetchDescriptor<MemoryRecord>())
    let topics = try targetContext.fetch(FetchDescriptor<MemoryTopicRecord>())

    #expect(projects.count == 1)
    #expect(projects.first?.id == source.projectID)
    #expect(projects.first?.name == "Mosaic V4")
    #expect(bindings.count == 4)
    #expect(Set(bindings.map(\.bindingKey)).count == 4)
    #expect(bindings.allSatisfy { $0.projectID == source.projectID })
    #expect(memories.first?.id == source.memoryID)
    #expect(memories.first?.scope == .project)
    #expect(topics.first?.id == source.topicID)
    #expect(topics.first?.scope == .project)
  }

  @MainActor
  @Test
  func legacyV3ArchiveWithoutProjectRecordsRestoresAndDeletesExistingProjectGraph() throws {
    let emptyContainer = try MosaicSchema.makeModelContainer(inMemory: true)
    let emptyContext = ModelContext(emptyContainer)
    let current = try MosaicPortableBackup.captureSnapshot(from: emptyContext)
    let legacy = projectBackupCopy(
      current,
      sourceSchemaVersion: "mosaic-main-3",
      extensionRecords: current.extensionRecords.filter { !ProjectPortableArchive.isOwned($0) }
    )
    let data = try MosaicPortableBackup.encode(snapshot: legacy)
    let plan = try MosaicPortableBackup.prepareRestore(from: data)

    let target = try makeProjectBackupFixture()
    try MosaicPortableBackup.replaceLiveStore(using: plan, in: target.context)

    #expect(try target.context.fetchCount(FetchDescriptor<ProjectRecord>()) == 0)
    #expect(try target.context.fetchCount(FetchDescriptor<ProjectResourceBindingRecord>()) == 0)
  }

  @MainActor
  @Test
  func callerCannotInjectRecordsIntoReservedProjectNamespace() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = ModelContext(container)
    let injected = MosaicPortableExtensionRecord(
      namespace: ProjectPortableArchive.namespace,
      recordType: "project",
      recordVersion: ProjectPortableArchive.recordVersion,
      id: UUID(),
      payload: Data("{}".utf8)
    )

    do {
      _ = try MosaicPortableBackup.captureSnapshot(
        from: context,
        extensionRecords: [injected]
      )
      Issue.record("Expected the project namespace to be reserved")
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
  func decodeRejectsNonDeterministicOrDuplicateProjectMembership() throws {
    let source = try makeProjectBackupFixture()
    let snapshot = try MosaicPortableBackup.decode(
      MosaicPortableBackup.export(from: source.context)
    )
    let original = try projectBinding(
      kind: .conversation,
      in: snapshot.extensionRecords
    )

    let badKey = try replacingProjectPayload(original) { payload in
      payload["bindingKey"] = "conversation:tampered"
    }
    do {
      _ = try decodeProjectTamper(snapshot, replacing: original, with: badKey)
      Issue.record("Expected a non-deterministic binding key to fail closed")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .invalidNormalizedInvariant(
            recordType: "project_resource_binding",
            id: original.id,
            field: "binding_key"
          )
      )
    }

    let duplicateID = UUID(uuidString: "92000000-0000-0000-0000-000000000099")!
    let duplicate = try replacingProjectPayload(original, id: duplicateID) { payload in
      payload["id"] = duplicateID.uuidString
    }
    let duplicateSnapshot = projectBackupCopy(
      snapshot,
      extensionRecords: snapshot.extensionRecords + [duplicate]
    )
    do {
      _ = try MosaicPortableBackup.decode(
        MosaicPortableBackup.encodeUnchecked(snapshot: duplicateSnapshot, limits: .default)
      )
      Issue.record("Expected a resource with two project memberships to fail closed")
    } catch let error as MosaicPortableBackupError {
      let expectedKey = ProjectResourceBindingRecord.makeBindingKey(
        resourceKind: .conversation,
        resourceID: source.conversationID
      )
      #expect(
        error
          == .duplicateKey(recordType: "project_resource_binding", key: expectedKey)
      )
    }
  }

  @MainActor
  @Test
  func decodeRejectsDanglingProjectAndResourceReferencesOrUnknownResourceKind() throws {
    let source = try makeProjectBackupFixture()
    let snapshot = try MosaicPortableBackup.decode(
      MosaicPortableBackup.export(from: source.context)
    )
    let original = try projectBinding(kind: .document, in: snapshot.extensionRecords)

    let missingProjectID = UUID(uuidString: "92000000-0000-0000-0000-000000000091")!
    let missingProject = try replacingProjectPayload(original) { payload in
      payload["projectID"] = missingProjectID.uuidString
    }
    do {
      _ = try decodeProjectTamper(snapshot, replacing: original, with: missingProject)
      Issue.record("Expected a dangling project reference to fail closed")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .missingNormalizedReference(
            recordType: "project_resource_binding",
            id: original.id,
            field: "project",
            targetID: missingProjectID
          )
      )
    }

    let missingResourceID = UUID(uuidString: "92000000-0000-0000-0000-000000000092")!
    let missingResource = try replacingProjectPayload(original) { payload in
      payload["resourceID"] = missingResourceID.uuidString
      payload["bindingKey"] = ProjectResourceBindingRecord.makeBindingKey(
        resourceKind: .document,
        resourceID: missingResourceID
      )
    }
    do {
      _ = try decodeProjectTamper(snapshot, replacing: original, with: missingResource)
      Issue.record("Expected a dangling project resource to fail closed")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .missingNormalizedReference(
            recordType: "project_resource_binding",
            id: original.id,
            field: "resource",
            targetID: missingResourceID
          )
      )
    }

    let unknownKind = try replacingProjectPayload(original) { payload in
      payload["resourceKindRawValue"] = "future_kind"
    }
    do {
      _ = try decodeProjectTamper(snapshot, replacing: original, with: unknownKind)
      Issue.record("Expected an unknown project resource kind to fail closed")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .invalidNormalizedInvariant(
            recordType: "project_resource_binding",
            id: original.id,
            field: "resource_kind"
          )
      )
    }
  }

  @MainActor
  @Test(arguments: [ProjectResourceKind.memory, .memoryTopic])
  func everyProjectScopedMemoryRequiresItsExactBinding(kind: ProjectResourceKind) throws {
    let source = try makeProjectBackupFixture()
    let snapshot = try MosaicPortableBackup.decode(
      MosaicPortableBackup.export(from: source.context)
    )
    let removed = try projectBinding(kind: kind, in: snapshot.extensionRecords)
    let extensionRecords = snapshot.extensionRecords.filter { $0.id != removed.id }
    let tampered = projectBackupCopy(snapshot, extensionRecords: extensionRecords)

    do {
      _ = try MosaicPortableBackup.decode(
        MosaicPortableBackup.encodeUnchecked(snapshot: tampered, limits: .default)
      )
      Issue.record("Expected project-scoped memory without a binding to fail closed")
    } catch let error as MosaicPortableBackupError {
      let recordType = kind == .memory ? "memory" : "memory_topic"
      let id = kind == .memory ? source.memoryID : source.topicID
      #expect(
        error
          == .invalidNormalizedInvariant(
            recordType: recordType,
            id: id,
            field: "project_binding"
          )
      )
    }
  }

  @MainActor
  @Test
  func globalOrConversationMemoryAndTopicCannotCarryAProjectBinding() throws {
    let source = try makeProjectBackupFixture()
    let snapshot = try MosaicPortableBackup.decode(
      MosaicPortableBackup.export(from: source.context)
    )
    let originalMemory = try #require(
      snapshot.memories.first { $0.id == source.memoryID }
    )
    let globalMemory = MosaicPortableMemory(
      id: originalMemory.id,
      title: originalMemory.title,
      content: originalMemory.content,
      scopeRawValue: MemoryScope.global.rawValue,
      conversationID: nil,
      isEnabled: originalMemory.isEnabled,
      isUserApproved: originalMemory.isUserApproved,
      createdAt: originalMemory.createdAt,
      updatedAt: originalMemory.updatedAt
    )
    let tampered = projectBackupCopy(snapshot, memories: [globalMemory])
    let binding = try projectBinding(kind: .memory, in: snapshot.extensionRecords)

    do {
      _ = try MosaicPortableBackup.decode(
        MosaicPortableBackup.encodeUnchecked(snapshot: tampered, limits: .default)
      )
      Issue.record("Expected global memory with a project binding to fail closed")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .invalidNormalizedInvariant(
            recordType: "project_resource_binding",
            id: binding.id,
            field: "resource_scope"
          )
      )
    }

    let topicRecord = try #require(
      snapshot.extensionRecords.first {
        AutomaticMemoryPortableArchive.isOwned($0) && $0.recordType == "topic"
      }
    )
    let globalTopicRecord = try replacingProjectPayload(topicRecord) { payload in
      payload["scopeRawValue"] = MemoryScope.global.rawValue
      payload["canonicalKey"] = "global:preference:response-length"
    }
    var topicExtensions = snapshot.extensionRecords
    let topicIndex = try #require(topicExtensions.firstIndex { $0.id == topicRecord.id })
    topicExtensions[topicIndex] = globalTopicRecord
    let globalTopicSnapshot = projectBackupCopy(
      snapshot,
      extensionRecords: topicExtensions
    )
    let topicBinding = try projectBinding(kind: .memoryTopic, in: snapshot.extensionRecords)

    do {
      _ = try MosaicPortableBackup.decode(
        MosaicPortableBackup.encodeUnchecked(snapshot: globalTopicSnapshot, limits: .default)
      )
      Issue.record("Expected global topic with a project binding to fail closed")
    } catch let error as MosaicPortableBackupError {
      #expect(
        error
          == .invalidNormalizedInvariant(
            recordType: "project_resource_binding",
            id: topicBinding.id,
            field: "resource_scope"
          )
      )
    }
  }

  @MainActor
  @Test(arguments: [MemoryScope.global, .project])
  func backupRejectsAutomaticEvidenceOutsideItsTopicAudience(scope: MemoryScope) throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = ModelContext(container)
    let date = Date(timeIntervalSince1970: 1_788_200_000)
    let sourceProject = ProjectRecord(name: "Source", createdAt: date, updatedAt: date)
    let otherProject = ProjectRecord(name: "Other", createdAt: date, updatedAt: date)
    let conversation = ConversationRecord(title: "Moved source", createdAt: date, updatedAt: date)
    let messageID = UUID()
    let messageContent = "Keep this durable preference."
    let sourceMessage = AutomaticMemorySourceMessage(
      id: messageID,
      role: .user,
      content: messageContent,
      createdAt: date
    )
    let fingerprint = AutomaticMemorySourceFingerprint.make(messages: [sourceMessage])
    let topicID = UUID()
    let canonicalKey =
      scope == .project
      ? "project:\(sourceProject.id.uuidString.lowercased()):preference:response_length"
      : "global:preference:response_length"
    let topic = MemoryTopicRecord(
      id: topicID,
      canonicalKey: canonicalKey,
      title: "Response length",
      content: "Use concise responses.",
      kind: .preference,
      scope: scope,
      conversationID: nil,
      confidence: 0.95,
      importance: 0.8,
      stability: .stable,
      lastConfirmedAt: date,
      evidenceCount: 1,
      revision: 1,
      createdAt: date,
      updatedAt: date
    )
    let evidence = MemoryEvidenceRecord(
      evidenceKey:
        "\(topicID.uuidString.lowercased())/\(messageID.uuidString.lowercased())/\(fingerprint)",
      topicID: topicID,
      conversationID: conversation.id,
      sourceMessageID: messageID,
      assistantMessageID: nil,
      excerpt: messageContent,
      sourceFingerprint: fingerprint,
      providerConfigurationID: nil,
      providerKind: nil,
      providerDisplayName: nil,
      modelIdentifier: nil,
      confidence: 0.95,
      createdAt: date
    )
    context.insert(sourceProject)
    context.insert(otherProject)
    context.insert(conversation)
    context.insert(
      MessageRecord(
        id: messageID,
        conversationID: conversation.id,
        role: .user,
        content: messageContent,
        status: .complete,
        createdAt: date
      )
    )
    context.insert(topic)
    context.insert(evidence)
    context.insert(
      MemoryRevisionRecord(
        revisionKey: "\(topicID.uuidString.lowercased())/1",
        topicID: topicID,
        sequence: 1,
        kind: .created,
        previousTitle: nil,
        previousContent: nil,
        title: topic.title,
        content: topic.content,
        sourceEvidenceID: evidence.id,
        createdAt: date
      )
    )
    context.insert(
      ProjectResourceBindingRecord(
        resourceKind: .conversation,
        resourceID: conversation.id,
        projectID: otherProject.id,
        createdAt: date,
        updatedAt: date
      )
    )
    if scope == .project {
      context.insert(
        ProjectResourceBindingRecord(
          resourceKind: .memoryTopic,
          resourceID: topic.id,
          projectID: sourceProject.id,
          createdAt: date,
          updatedAt: date
        )
      )
    }
    try context.save()

    #expect(
      throws: MosaicPortableBackupError.invalidNormalizedInvariant(
        recordType: "memory_evidence",
        id: evidence.id,
        field: "topic_project_audience"
      )
    ) {
      try MosaicPortableBackup.export(from: context)
    }
  }

  @MainActor
  @Test
  func decodeRejectsProjectTopicWithConversationAudience() throws {
    let source = try makeProjectBackupFixture()
    let snapshot = try MosaicPortableBackup.decode(
      MosaicPortableBackup.export(from: source.context)
    )
    let topicRecord = try #require(
      snapshot.extensionRecords.first {
        AutomaticMemoryPortableArchive.isOwned($0)
          && $0.recordType == "topic"
          && $0.id == source.topicID
      }
    )
    let replacement = try replacingProjectPayload(topicRecord) { payload in
      payload["conversationID"] = source.conversationID.uuidString
    }

    #expect(
      throws: MosaicPortableBackupError.invalidNormalizedInvariant(
        recordType: "memory_topic",
        id: source.topicID,
        field: "topic_conversation"
      )
    ) {
      _ = try decodeProjectTamper(snapshot, replacing: topicRecord, with: replacement)
    }
  }
}

private struct ProjectBackupFixture {
  let context: ModelContext
  let backupID: UUID
  let date: Date
  let projectID: UUID
  let conversationID: UUID
  let memoryID: UUID
  let topicID: UUID
}

@MainActor
private func makeProjectBackupFixture() throws -> ProjectBackupFixture {
  let container = try MosaicSchema.makeModelContainer(inMemory: true)
  let context = ModelContext(container)
  let date = Date(timeIntervalSince1970: 1_788_100_000)
  let projectID = UUID(uuidString: "92000000-0000-0000-0000-000000000001")!
  let conversationID = UUID(uuidString: "92000000-0000-0000-0000-000000000002")!
  let memoryID = UUID(uuidString: "92000000-0000-0000-0000-000000000003")!
  let topicID = UUID(uuidString: "92000000-0000-0000-0000-000000000004")!
  let revisionID = UUID(uuidString: "92000000-0000-0000-0000-000000000005")!
  let documentID = UUID(uuidString: "92000000-0000-0000-0000-000000000006")!

  context.insert(
    ProjectRecord(
      id: projectID,
      name: "Mosaic V4",
      instructions: "Keep project answers concise.",
      createdAt: date,
      updatedAt: date
    )
  )
  context.insert(
    ConversationRecord(
      id: conversationID,
      title: "Project chat",
      modelIdentifier: "local-model",
      createdAt: date,
      updatedAt: date
    )
  )
  context.insert(
    MemoryRecord(
      id: memoryID,
      title: "Project convention",
      content: "Use Mosaic V4 terminology.",
      scope: .project,
      conversationID: nil,
      isUserApproved: true,
      createdAt: date,
      updatedAt: date
    )
  )
  context.insert(
    MemoryTopicRecord(
      id: topicID,
      canonicalKey:
        "project:\(projectID.uuidString.lowercased()):preference:response-length",
      title: "Response length",
      content: "Keep project responses concise.",
      kind: .preference,
      scope: .project,
      conversationID: nil,
      origin: .manual,
      confidence: 1,
      importance: 0.8,
      stability: .stable,
      lastConfirmedAt: date,
      evidenceCount: 0,
      revision: 1,
      createdAt: date,
      updatedAt: date
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
      title: "Response length",
      content: "Keep project responses concise.",
      sourceEvidenceID: nil,
      createdAt: date
    )
  )
  context.insert(
    ImportedDocumentRecord(
      id: documentID,
      title: "Project brief",
      sourceFilename: "brief.pdf",
      mimeType: "application/pdf",
      contentFingerprint: "project-document-fingerprint",
      characterCount: 120,
      pageCount: 1,
      ocrPageCount: 0,
      ocrFallbackPageCount: 0,
      createdAt: date,
      updatedAt: date
    )
  )

  for (index, resource) in [
    (ProjectResourceKind.conversation, conversationID),
    (.memory, memoryID),
    (.memoryTopic, topicID),
    (.document, documentID),
  ].enumerated() {
    context.insert(
      ProjectResourceBindingRecord(
        id: UUID(
          uuidString: String(
            format: "92000000-0000-0000-0000-%012d",
            index + 10
          )
        )!,
        resourceKind: resource.0,
        resourceID: resource.1,
        projectID: projectID,
        createdAt: date,
        updatedAt: date
      )
    )
  }
  try context.save()

  return ProjectBackupFixture(
    context: context,
    backupID: UUID(uuidString: "92000000-0000-0000-0000-000000000090")!,
    date: date,
    projectID: projectID,
    conversationID: conversationID,
    memoryID: memoryID,
    topicID: topicID
  )
}

private func projectBinding(
  kind: ProjectResourceKind,
  in records: [MosaicPortableExtensionRecord]
) throws -> MosaicPortableExtensionRecord {
  for record in records where ProjectPortableArchive.isOwned(record) {
    guard record.recordType == "resource_binding",
      let payload = try JSONSerialization.jsonObject(with: record.payload) as? [String: Any],
      payload["resourceKindRawValue"] as? String == kind.rawValue
    else { continue }
    return record
  }
  throw CocoaError(.fileNoSuchFile)
}

private func replacingProjectPayload(
  _ record: MosaicPortableExtensionRecord,
  id: UUID? = nil,
  mutate: (inout [String: Any]) throws -> Void
) throws -> MosaicPortableExtensionRecord {
  var payload = try #require(
    JSONSerialization.jsonObject(with: record.payload) as? [String: Any]
  )
  try mutate(&payload)
  return MosaicPortableExtensionRecord(
    namespace: record.namespace,
    recordType: record.recordType,
    recordVersion: record.recordVersion,
    id: id ?? record.id,
    payload: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
  )
}

private func decodeProjectTamper(
  _ snapshot: MosaicPortableBackupSnapshot,
  replacing original: MosaicPortableExtensionRecord,
  with replacement: MosaicPortableExtensionRecord
) throws -> MosaicPortableBackupSnapshot {
  var extensionRecords = snapshot.extensionRecords
  let index = try #require(extensionRecords.firstIndex { $0.id == original.id })
  extensionRecords[index] = replacement
  let tampered = projectBackupCopy(snapshot, extensionRecords: extensionRecords)
  return try MosaicPortableBackup.decode(
    MosaicPortableBackup.encodeUnchecked(snapshot: tampered, limits: .default)
  )
}

private func projectBackupCopy(
  _ snapshot: MosaicPortableBackupSnapshot,
  sourceSchemaVersion: String? = nil,
  memories: [MosaicPortableMemory]? = nil,
  extensionRecords: [MosaicPortableExtensionRecord]? = nil
) -> MosaicPortableBackupSnapshot {
  MosaicPortableBackupSnapshot(
    backupID: snapshot.backupID,
    createdAt: snapshot.createdAt,
    sourceSchemaVersion: sourceSchemaVersion ?? snapshot.sourceSchemaVersion,
    conversations: snapshot.conversations,
    messages: snapshot.messages,
    memories: memories ?? snapshot.memories,
    scheduledTasks: snapshot.scheduledTasks,
    providerConfigurations: snapshot.providerConfigurations,
    embeddingProfiles: snapshot.embeddingProfiles,
    importedDocuments: snapshot.importedDocuments,
    documentChunks: snapshot.documentChunks,
    requestContextEvents: snapshot.requestContextEvents,
    compactionArtifacts: snapshot.compactionArtifacts,
    conversationCompactionHeads: snapshot.conversationCompactionHeads,
    normalizedBackfillProgress: snapshot.normalizedBackfillProgress,
    extensionRecords: extensionRecords ?? snapshot.extensionRecords
  )
}

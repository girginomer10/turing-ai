import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite("Project resource bindings", .serialized)
@MainActor
struct ProjectBindingStoreTests {
  private let baseDate = Date(timeIntervalSince1970: 1_770_000_000)

  @Test("assignment, move, and removal keep exactly one binding per resource")
  func assignmentMoveAndRemovalAreUnique() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversation = ConversationRecord(title: "Project chat")
    let firstProject = ProjectRecord(name: "First")
    let secondProject = ProjectRecord(name: "Second")
    context.insert(conversation)
    context.insert(firstProject)
    context.insert(secondProject)
    try context.save()

    let created = try #require(
      try ProjectBindingStore.assign(
        resourceKind: .conversation,
        resourceID: conversation.id,
        to: firstProject.id,
        in: context,
        now: baseDate
      )
    )
    let originalID = created.id
    #expect(created.bindingKey == "conversation:\(conversation.id.uuidString.lowercased())")
    #expect(created.projectID == firstProject.id)

    let moved = try #require(
      try ProjectBindingStore.assign(
        resourceKind: .conversation,
        resourceID: conversation.id,
        to: secondProject.id,
        in: context,
        now: baseDate.addingTimeInterval(1)
      )
    )
    #expect(moved.id == originalID)
    #expect(moved.projectID == secondProject.id)
    #expect(moved.updatedAt == baseDate.addingTimeInterval(1))
    try context.save()

    #expect(try context.fetchCount(FetchDescriptor<ProjectResourceBindingRecord>()) == 1)
    #expect(
      try ProjectBindingStore.projectID(
        resourceKind: .conversation,
        resourceID: conversation.id,
        in: context
      ) == secondProject.id
    )

    #expect(
      try ProjectBindingStore.assign(
        resourceKind: .conversation,
        resourceID: conversation.id,
        to: nil,
        in: context,
        now: baseDate.addingTimeInterval(2)
      ) == nil
    )
    try context.save()
    #expect(try context.fetchCount(FetchDescriptor<ProjectResourceBindingRecord>()) == 0)
  }

  @Test("stale conversation assignment snapshots cannot overwrite a newer move")
  func conversationAssignmentCompareAndSwapRejectsStalePickerState() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let firstProject = ProjectRecord(name: "First")
    let secondProject = ProjectRecord(name: "Second")
    let staleDestination = ProjectRecord(name: "Stale destination")
    let conversation = ConversationRecord(title: "Project chat")
    context.insert(firstProject)
    context.insert(secondProject)
    context.insert(staleDestination)
    context.insert(conversation)
    try context.save()
    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: conversation.id,
      to: firstProject.id,
      in: context,
      now: baseDate
    )
    try context.save()
    let conversationID = conversation.id
    let secondProjectID = secondProject.id
    let staleDestinationID = staleDestination.id
    let staleContext = ModelContext(container)
    staleContext.autosaveEnabled = false
    let staleScope = try ProjectBindingStore.conversationScope(
      conversationID: conversationID,
      in: staleContext
    )
    _ = try #require(
      try ProjectBindingStore.binding(
        resourceKind: .conversation,
        resourceID: conversationID,
        in: staleContext,
        includesPendingChanges: false
      )
    )

    let writerContext = ModelContext(container)
    writerContext.autosaveEnabled = false
    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: conversationID,
      to: secondProjectID,
      in: writerContext,
      now: baseDate.addingTimeInterval(1)
    )
    try writerContext.save()

    #expect(throws: ProjectBindingError.staleConversationAssignment(conversationID)) {
      try ProjectBindingStore.assignConversation(
        conversationID: conversationID,
        to: staleDestinationID,
        expected: staleScope,
        in: staleContext,
        now: baseDate.addingTimeInterval(2)
      )
    }
    #expect(!staleContext.hasChanges)

    let verificationContext = ModelContext(container)
    #expect(
      try ProjectBindingStore.projectID(
        resourceKind: .conversation,
        resourceID: conversationID,
        in: verificationContext
      ) == secondProjectID
    )

    let currentContext = ModelContext(container)
    currentContext.autosaveEnabled = false
    let currentScope = try ProjectBindingStore.conversationScope(
      conversationID: conversationID,
      in: currentContext
    )
    _ = try ProjectBindingStore.assignConversation(
      conversationID: conversationID,
      to: staleDestinationID,
      expected: currentScope,
      in: currentContext,
      now: baseDate.addingTimeInterval(3)
    )
    try currentContext.save()
    #expect(
      try ProjectBindingStore.projectID(
        resourceKind: .conversation,
        resourceID: conversationID,
        in: ModelContext(container)
      ) == staleDestinationID
    )
  }

  @Test("project edits compare against freshly committed state")
  func projectEditCompareAndSwapRejectsAStaleEditor() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let project = ProjectRecord(
      name: "Original",
      instructions: "Original instructions",
      createdAt: baseDate,
      updatedAt: baseDate
    )
    context.insert(project)
    try context.save()
    let staleSnapshot = project.snapshot
    let projectID = project.id

    let writerContext = ModelContext(container)
    writerContext.autosaveEnabled = false
    _ = try ProjectBindingStore.updateProject(
      id: projectID,
      expected: staleSnapshot,
      name: "Current",
      instructions: "Current instructions",
      in: writerContext,
      now: baseDate.addingTimeInterval(1)
    )
    try writerContext.save()

    #expect(throws: ProjectBindingError.staleProjectEdit(projectID)) {
      try ProjectBindingStore.updateProject(
        id: projectID,
        expected: staleSnapshot,
        name: "Stale overwrite",
        instructions: "Stale instructions",
        in: context,
        now: baseDate.addingTimeInterval(2)
      )
    }
    #expect(!context.hasChanges)

    let verificationContext = ModelContext(container)
    var descriptor = FetchDescriptor<ProjectRecord>(predicate: #Predicate { $0.id == projectID })
    descriptor.fetchLimit = 1
    let current = try #require(verificationContext.fetch(descriptor).first)
    #expect(current.name == "Current")
    #expect(current.instructions == "Current instructions")
    #expect(current.updatedAt == baseDate.addingTimeInterval(1))
  }

  @Test("every supported resource kind resolves through a validated sidecar binding")
  func supportedResourceKindsRoundTrip() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let project = ProjectRecord(name: "Workspace")
    let conversation = ConversationRecord(title: "Chat")
    let memory = MemoryRecord(
      title: "Project preference",
      content: "Use the project vocabulary.",
      scope: .project,
      isUserApproved: true
    )
    let topic = MemoryTopicRecord(
      canonicalKey: "project:preference:vocabulary",
      title: "Project vocabulary",
      content: "Use Mosaic terminology.",
      kind: .preference,
      scope: .project,
      conversationID: nil,
      confidence: 0.95,
      importance: 0.8,
      stability: .stable
    )
    let document = ImportedDocumentRecord(
      title: "Project notes",
      sourceFilename: "notes.txt",
      mimeType: "text/plain",
      contentFingerprint: "project-notes-fingerprint",
      characterCount: 20
    )
    context.insert(project)
    context.insert(conversation)
    context.insert(memory)
    context.insert(topic)
    context.insert(document)
    try context.save()

    let resources: [(ProjectResourceKind, UUID)] = [
      (.conversation, conversation.id),
      (.memory, memory.id),
      (.memoryTopic, topic.id),
      (.document, document.id),
    ]
    for (kind, resourceID) in resources {
      _ = try ProjectBindingStore.assign(
        resourceKind: kind,
        resourceID: resourceID,
        to: project.id,
        in: context,
        now: baseDate
      )
    }
    try context.save()

    #expect(try context.fetchCount(FetchDescriptor<ProjectResourceBindingRecord>()) == 4)
    for kind in ProjectResourceKind.allCases {
      let ids = resources.filter { $0.0 == kind }.map(\.1)
      #expect(
        try ProjectBindingStore.projectIDs(
          resourceKind: kind,
          resourceIDs: ids,
          in: context
        ) == Dictionary(uniqueKeysWithValues: ids.map { ($0, project.id) })
      )
    }
  }

  @Test("missing resources and projects are rejected without partial bindings")
  func missingReferencesAreRejected() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let project = ProjectRecord(name: "Valid")
    let conversation = ConversationRecord(title: "Valid resource")
    context.insert(project)
    context.insert(conversation)
    try context.save()

    #expect(throws: ProjectBindingError.invalidResource) {
      try ProjectBindingStore.assign(
        resourceKind: .conversation,
        resourceID: UUID(),
        to: project.id,
        in: context
      )
    }

    let missingProjectID = UUID()
    #expect(throws: ProjectBindingError.projectUnavailable(missingProjectID)) {
      try ProjectBindingStore.assign(
        resourceKind: .conversation,
        resourceID: conversation.id,
        to: missingProjectID,
        in: context
      )
    }

    let globalMemory = MemoryRecord(
      title: "Global",
      content: "Not project scoped.",
      scope: .global,
      isUserApproved: true
    )
    context.insert(globalMemory)
    try context.save()
    #expect(throws: ProjectBindingError.invalidResource) {
      try ProjectBindingStore.assign(
        resourceKind: .memory,
        resourceID: globalMemory.id,
        to: project.id,
        in: context
      )
    }
    #expect(try context.fetchCount(FetchDescriptor<ProjectResourceBindingRecord>()) == 0)
  }

  @Test("exclusive automatic project memory follows a conversation without losing evidence")
  func exclusiveAutomaticTopicMovesAcrossProjectsAndNarrowsWhenUnassigned() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let coordinator = MosaicOperationCoordinator()
    let firstProject = ProjectRecord(name: "First")
    let secondProject = ProjectRecord(name: "Second")
    let conversation = ConversationRecord(title: "Project source")
    context.insert(firstProject)
    context.insert(secondProject)
    context.insert(conversation)
    try context.save()
    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: conversation.id,
      to: firstProject.id,
      in: context,
      now: baseDate
    )
    let topic = MemoryTopicRecord(
      canonicalKey:
        "project:\(firstProject.id.uuidString.lowercased()):preference:response_length",
      title: "Response length",
      content: "Use concise project responses.",
      kind: .preference,
      scope: .project,
      conversationID: nil,
      confidence: 0.95,
      importance: 0.8,
      stability: .stable,
      lastConfirmedAt: baseDate,
      evidenceCount: 1,
      createdAt: baseDate,
      updatedAt: baseDate
    )
    context.insert(topic)
    let evidence = insertEvidence(
      topic: topic,
      conversationID: conversation.id,
      content: "Keep answers concise in this project.",
      into: context
    )
    try context.save()
    _ = try ProjectBindingStore.assign(
      resourceKind: .memoryTopic,
      resourceID: topic.id,
      to: firstProject.id,
      in: context,
      now: baseDate
    )
    try context.save()

    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: conversation.id,
      to: secondProject.id,
      in: context,
      now: baseDate.addingTimeInterval(1)
    )
    try coordinator.saveSourceChanges(in: context)

    #expect(topic.scope == .project)
    #expect(topic.conversationID == nil)
    #expect(
      topic.canonicalKey
        == "project:\(secondProject.id.uuidString.lowercased()):preference:response_length"
    )
    #expect(
      try ProjectBindingStore.projectID(
        resourceKind: .conversation,
        resourceID: conversation.id,
        in: context
      ) == secondProject.id
    )
    #expect(
      try ProjectBindingStore.projectID(
        resourceKind: .memoryTopic,
        resourceID: topic.id,
        in: context
      ) == secondProject.id
    )
    #expect(evidence.topicID == topic.id)
    #expect(evidence.conversationID == conversation.id)
    #expect(topic.evidenceCount == 1)

    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: conversation.id,
      to: nil,
      in: context,
      now: baseDate.addingTimeInterval(2)
    )
    try coordinator.saveSourceChanges(in: context)

    #expect(topic.scope == .conversation)
    #expect(topic.conversationID == conversation.id)
    #expect(
      topic.canonicalKey
        == "conversation:\(conversation.id.uuidString.lowercased()):preference:response_length"
    )
    #expect(
      try ProjectBindingStore.projectID(
        resourceKind: .conversation,
        resourceID: conversation.id,
        in: context
      ) == nil
    )
    #expect(
      try ProjectBindingStore.projectID(
        resourceKind: .memoryTopic,
        resourceID: topic.id,
        in: context
      ) == nil
    )
    #expect(try context.fetchCount(FetchDescriptor<MemoryEvidenceRecord>()) == 1)
    #expect(topic.evidenceCount == 1)
  }

  @Test("assigning an unbound source narrows its exclusive automatic global topic")
  func exclusiveAutomaticGlobalTopicNarrowsToAssignedProject() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let project = ProjectRecord(name: "Destination")
    let conversation = ConversationRecord(title: "Unassigned source")
    let topic = MemoryTopicRecord(
      canonicalKey: "global:preference:response_length",
      title: "Response length",
      content: "Use concise responses.",
      kind: .preference,
      scope: .global,
      conversationID: nil,
      confidence: 0.95,
      importance: 0.8,
      stability: .stable,
      evidenceCount: 1,
      createdAt: baseDate,
      updatedAt: baseDate
    )
    context.insert(project)
    context.insert(conversation)
    context.insert(topic)
    let evidence = insertEvidence(
      topic: topic,
      conversationID: conversation.id,
      content: "Always keep answers concise.",
      into: context
    )
    try context.save()

    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: conversation.id,
      to: project.id,
      in: context,
      now: baseDate.addingTimeInterval(1)
    )
    try context.save()

    #expect(topic.scope == .project)
    #expect(topic.conversationID == nil)
    #expect(
      topic.canonicalKey
        == "project:\(project.id.uuidString.lowercased()):preference:response_length"
    )
    #expect(
      try ProjectBindingStore.projectID(
        resourceKind: .memoryTopic,
        resourceID: topic.id,
        in: context
      ) == project.id
    )
    #expect(evidence.topicID == topic.id)
    #expect(topic.evidenceCount == 1)
  }

  @Test("mixed-evidence automatic memory blocks a partial project move atomically")
  func mixedEvidenceTopicRejectsConversationMoveWithoutPartialChanges() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let sourceProject = ProjectRecord(name: "Source")
    let destinationProject = ProjectRecord(name: "Destination")
    let movingConversation = ConversationRecord(title: "Moving")
    let retainedConversation = ConversationRecord(title: "Retained")
    context.insert(sourceProject)
    context.insert(destinationProject)
    context.insert(movingConversation)
    context.insert(retainedConversation)
    try context.save()
    for conversation in [movingConversation, retainedConversation] {
      _ = try ProjectBindingStore.assign(
        resourceKind: .conversation,
        resourceID: conversation.id,
        to: sourceProject.id,
        in: context,
        now: baseDate
      )
    }
    let originalCanonicalKey =
      "project:\(sourceProject.id.uuidString.lowercased()):preference:response_length"
    let topic = MemoryTopicRecord(
      canonicalKey: originalCanonicalKey,
      title: "Response length",
      content: "Use concise project responses.",
      kind: .preference,
      scope: .project,
      conversationID: nil,
      confidence: 0.95,
      importance: 0.8,
      stability: .stable,
      evidenceCount: 2,
      createdAt: baseDate,
      updatedAt: baseDate
    )
    context.insert(topic)
    _ = insertEvidence(
      topic: topic,
      conversationID: movingConversation.id,
      content: "Use concise answers here.",
      into: context
    )
    _ = insertEvidence(
      topic: topic,
      conversationID: retainedConversation.id,
      content: "Use concise answers in this project.",
      createsRootRevision: false,
      into: context
    )
    try context.save()
    _ = try ProjectBindingStore.assign(
      resourceKind: .memoryTopic,
      resourceID: topic.id,
      to: sourceProject.id,
      in: context,
      now: baseDate
    )
    try context.save()

    #expect(throws: ProjectBindingError.mixedAutomaticMemoryEvidence(topic.id)) {
      try ProjectBindingStore.assign(
        resourceKind: .conversation,
        resourceID: movingConversation.id,
        to: destinationProject.id,
        in: context,
        now: baseDate.addingTimeInterval(1)
      )
    }

    #expect(topic.canonicalKey == originalCanonicalKey)
    #expect(topic.scope == .project)
    #expect(topic.evidenceCount == 2)
    #expect(
      try ProjectBindingStore.projectID(
        resourceKind: .conversation,
        resourceID: movingConversation.id,
        in: context,
        includesPendingChanges: true
      ) == sourceProject.id
    )
    #expect(
      try ProjectBindingStore.projectID(
        resourceKind: .memoryTopic,
        resourceID: topic.id,
        in: context,
        includesPendingChanges: true
      ) == sourceProject.id
    )
    #expect(!context.hasChanges)
  }

  @Test("the source commit gate rejects a forged cross-project evidence audience")
  func sourceCommitRejectsForgedCrossProjectAudience() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let sourceProject = ProjectRecord(name: "Source")
    let forgedProject = ProjectRecord(name: "Forged")
    let conversation = ConversationRecord(title: "Project source")
    context.insert(sourceProject)
    context.insert(forgedProject)
    context.insert(conversation)
    try context.save()
    let conversationBinding = try #require(
      try ProjectBindingStore.assign(
        resourceKind: .conversation,
        resourceID: conversation.id,
        to: sourceProject.id,
        in: context,
        now: baseDate
      )
    )
    let topic = MemoryTopicRecord(
      canonicalKey:
        "project:\(sourceProject.id.uuidString.lowercased()):preference:response_length",
      title: "Response length",
      content: "Use concise project responses.",
      kind: .preference,
      scope: .project,
      conversationID: nil,
      confidence: 0.95,
      importance: 0.8,
      stability: .stable,
      evidenceCount: 1,
      createdAt: baseDate,
      updatedAt: baseDate
    )
    context.insert(topic)
    _ = insertEvidence(
      topic: topic,
      conversationID: conversation.id,
      content: "Keep this project's answers concise.",
      into: context
    )
    try context.save()
    _ = try ProjectBindingStore.assign(
      resourceKind: .memoryTopic,
      resourceID: topic.id,
      to: sourceProject.id,
      in: context,
      now: baseDate
    )
    try context.save()

    conversationBinding.move(to: forgedProject.id, at: baseDate.addingTimeInterval(1))

    #expect(throws: ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)) {
      try MosaicOperationCoordinator().saveSourceChanges(in: context)
    }
    #expect(!context.hasChanges)
    #expect(
      try ProjectBindingStore.projectID(
        resourceKind: .conversation,
        resourceID: conversation.id,
        in: context
      ) == sourceProject.id
    )
    #expect(
      try ProjectBindingStore.projectID(
        resourceKind: .memoryTopic,
        resourceID: topic.id,
        in: context
      ) == sourceProject.id
    )
  }

  @Test("automatic lifecycle validation rejects missing evidence but permits a tombstone")
  func automaticLifecycleValidationRejectsBrokenActiveTopicAndPermitsForgottenTombstone()
    throws
  {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let activeTopic = MemoryTopicRecord(
      canonicalKey: "global:preference:missing_evidence",
      title: "Missing evidence",
      content: "This active topic has no supporting evidence.",
      kind: .preference,
      scope: .global,
      conversationID: nil,
      confidence: 0.95,
      importance: 0.8,
      stability: .stable,
      lastConfirmedAt: baseDate,
      evidenceCount: 0,
      createdAt: baseDate,
      updatedAt: baseDate
    )
    context.insert(activeTopic)

    #expect(throws: ProjectBindingError.invalidAutomaticMemoryAudience(activeTopic.id)) {
      try MosaicOperationCoordinator().saveSourceChanges(in: context)
    }
    #expect(try context.fetchCount(FetchDescriptor<MemoryTopicRecord>()) == 0)

    let tombstone = MemoryTopicRecord(
      canonicalKey: "global:preference:forgotten",
      title: "Forgotten",
      content: "The final source was deleted.",
      kind: .preference,
      scope: .global,
      conversationID: nil,
      status: .forgotten,
      confidence: 0.95,
      importance: 0.8,
      stability: .stable,
      isEnabled: false,
      lastConfirmedAt: baseDate,
      evidenceCount: 0,
      createdAt: baseDate,
      updatedAt: baseDate
    )
    context.insert(tombstone)
    context.insert(
      MemoryRevisionRecord(
        revisionKey: "\(tombstone.id.uuidString.lowercased())/1",
        topicID: tombstone.id,
        sequence: 1,
        kind: .created,
        previousTitle: nil,
        previousContent: nil,
        title: tombstone.title,
        content: tombstone.content,
        sourceEvidenceID: nil,
        createdAt: baseDate
      )
    )

    try MosaicOperationCoordinator().saveSourceChanges(in: context)
    #expect(try context.fetchCount(FetchDescriptor<MemoryTopicRecord>()) == 1)
  }

  @Test("an active automatic topic requires a surviving revision-to-evidence link")
  func activeAutomaticTopicRejectsDetachedRevisionEvidence() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversation = ConversationRecord(title: "Automatic source")
    let topic = MemoryTopicRecord(
      canonicalKey: "global:preference:detached_root",
      title: "Detached root",
      content: "The root revision lost its evidence reference.",
      kind: .preference,
      scope: .global,
      conversationID: nil,
      confidence: 0.95,
      importance: 0.8,
      stability: .stable,
      lastConfirmedAt: baseDate,
      evidenceCount: 1,
      createdAt: baseDate,
      updatedAt: baseDate
    )
    context.insert(conversation)
    context.insert(topic)
    _ = insertEvidence(
      topic: topic,
      conversationID: conversation.id,
      content: "Keep the evidence attached.",
      createsRootRevision: false,
      into: context
    )
    context.insert(
      MemoryRevisionRecord(
        revisionKey: "\(topic.id.uuidString.lowercased())/1",
        topicID: topic.id,
        sequence: 1,
        kind: .created,
        previousTitle: nil,
        previousContent: nil,
        title: topic.title,
        content: topic.content,
        sourceEvidenceID: nil,
        createdAt: baseDate
      )
    )

    #expect(throws: ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)) {
      try MosaicOperationCoordinator().saveSourceChanges(in: context)
    }
    #expect(try context.fetchCount(FetchDescriptor<MemoryTopicRecord>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<MemoryEvidenceRecord>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<MemoryRevisionRecord>()) == 0)
  }

  @Test("archived projects reject new and moved assignments")
  func archivedProjectAssignmentIsRejectedAtomically() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let activeProject = ProjectRecord(name: "Active")
    let archivedProject = ProjectRecord(name: "Archived", isArchived: true)
    let assignedConversation = ConversationRecord(title: "Already assigned")
    let unassignedConversation = ConversationRecord(title: "Unassigned")
    context.insert(activeProject)
    context.insert(archivedProject)
    context.insert(assignedConversation)
    context.insert(unassignedConversation)
    try context.save()

    let existing = try #require(
      try ProjectBindingStore.assign(
        resourceKind: .conversation,
        resourceID: assignedConversation.id,
        to: activeProject.id,
        in: context,
        now: baseDate
      )
    )
    try context.save()

    #expect(throws: ProjectBindingError.projectUnavailable(archivedProject.id)) {
      try ProjectBindingStore.assign(
        resourceKind: .conversation,
        resourceID: assignedConversation.id,
        to: archivedProject.id,
        in: context,
        now: baseDate.addingTimeInterval(1)
      )
    }
    #expect(throws: ProjectBindingError.projectUnavailable(archivedProject.id)) {
      try ProjectBindingStore.assign(
        resourceKind: .conversation,
        resourceID: unassignedConversation.id,
        to: archivedProject.id,
        in: context,
        now: baseDate.addingTimeInterval(1)
      )
    }

    #expect(existing.projectID == activeProject.id)
    #expect(existing.updatedAt == baseDate)
    #expect(try context.fetchCount(FetchDescriptor<ProjectResourceBindingRecord>()) == 1)
  }

  @discardableResult
  private func insertEvidence(
    topic: MemoryTopicRecord,
    conversationID: UUID,
    content: String,
    createsRootRevision: Bool = true,
    into context: ModelContext
  ) -> MemoryEvidenceRecord {
    let messageID = UUID()
    let source = AutomaticMemorySourceMessage(
      id: messageID,
      role: .user,
      content: content,
      createdAt: baseDate
    )
    let fingerprint = AutomaticMemorySourceFingerprint.make(messages: [source])
    context.insert(
      MessageRecord(
        id: messageID,
        conversationID: conversationID,
        role: .user,
        content: content,
        status: .complete,
        createdAt: baseDate
      )
    )
    let evidence = MemoryEvidenceRecord(
      evidenceKey:
        "\(topic.id.uuidString.lowercased())/\(messageID.uuidString.lowercased())/\(fingerprint)",
      topicID: topic.id,
      conversationID: conversationID,
      sourceMessageID: messageID,
      assistantMessageID: nil,
      excerpt: content,
      sourceFingerprint: fingerprint,
      providerConfigurationID: nil,
      providerKind: nil,
      providerDisplayName: nil,
      modelIdentifier: nil,
      confidence: 0.95,
      createdAt: baseDate
    )
    context.insert(evidence)
    if createsRootRevision {
      context.insert(
        MemoryRevisionRecord(
          revisionKey: "\(topic.id.uuidString.lowercased())/1",
          topicID: topic.id,
          sequence: 1,
          kind: .created,
          previousTitle: nil,
          previousContent: nil,
          title: topic.title,
          content: topic.content,
          sourceEvidenceID: evidence.id,
          createdAt: baseDate
        )
      )
    }
    return evidence
  }

  private func makeProjectAutomaticFixture() throws -> (
    context: ModelContext,
    topicID: UUID,
    evidenceID: UUID,
    rootRevisionID: UUID,
    conversationBindingID: UUID,
    topicBindingID: UUID
  ) {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let project = ProjectRecord(name: "Project")
    let conversation = ConversationRecord(title: "Evidence source")
    context.insert(project)
    context.insert(conversation)
    try context.save()
    let conversationBinding = try #require(
      try ProjectBindingStore.assign(
        resourceKind: .conversation,
        resourceID: conversation.id,
        to: project.id,
        in: context,
        now: baseDate
      )
    )
    let topic = MemoryTopicRecord(
      canonicalKey: "project:\(project.id.uuidString.lowercased()):preference:language",
      title: "Language",
      content: "Use Turkish in this project.",
      kind: .preference,
      scope: .project,
      conversationID: nil,
      confidence: 0.95,
      importance: 0.8,
      stability: .stable,
      lastConfirmedAt: baseDate,
      evidenceCount: 1,
      createdAt: baseDate,
      updatedAt: baseDate
    )
    context.insert(topic)
    let evidence = insertEvidence(
      topic: topic,
      conversationID: conversation.id,
      content: "Use Turkish in this project.",
      into: context
    )
    try context.save()
    let topicBinding = try #require(
      try ProjectBindingStore.assign(
        resourceKind: .memoryTopic,
        resourceID: topic.id,
        to: project.id,
        in: context,
        now: baseDate
      )
    )
    try context.save()
    let topicID = topic.id
    var revisionDescriptor = FetchDescriptor<MemoryRevisionRecord>(
      predicate: #Predicate { $0.topicID == topicID && $0.sequence == 1 }
    )
    revisionDescriptor.fetchLimit = 1
    let rootRevision = try #require(context.fetch(revisionDescriptor).first)
    return (
      context,
      topic.id,
      evidence.id,
      rootRevision.id,
      conversationBinding.id,
      topicBinding.id
    )
  }
}

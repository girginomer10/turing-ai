import Foundation
import SwiftData
import Testing

@testable import MosaicCore

struct AutomaticMemoryRetrievalTests {
  @MainActor
  @Test("recall exposes only active global and current-chat topics and revalidates their full text")
  func scopedTopicSnapshotAndPostReadValidation() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let currentConversation = ConversationRecord(title: "Current")
    let otherConversation = ConversationRecord(title: "Other")
    context.insert(currentConversation)
    context.insert(otherConversation)

    let date = Date(timeIntervalSince1970: 1_760_000_000)
    let global = topic(
      key: "global:preference:response.language",
      title: "Response language",
      content: "The user prefers replies in Turkish.",
      date: date
    )
    let current = topic(
      key: "conversation:\(currentConversation.id.uuidString.lowercased()):project:release",
      title: "Release",
      content: "This chat is planning the Mosaic release.",
      kind: .project,
      scope: .conversation,
      conversationID: currentConversation.id,
      date: date.addingTimeInterval(1)
    )
    let other = topic(
      key: "conversation:\(otherConversation.id.uuidString.lowercased()):project:private",
      title: "Other project",
      content: "This belongs only to another chat.",
      kind: .project,
      scope: .conversation,
      conversationID: otherConversation.id,
      date: date.addingTimeInterval(2)
    )
    let forgotten = MemoryTopicRecord(
      canonicalKey: "global:preference:old.editor",
      title: "Old editor",
      content: "The user preferred an old editor.",
      kind: .preference,
      scope: .global,
      conversationID: nil,
      status: .forgotten,
      confidence: 0.9,
      importance: 0.7,
      stability: .evolving,
      isEnabled: false,
      lastConfirmedAt: date,
      createdAt: date,
      updatedAt: date
    )
    context.insert(global)
    context.insert(current)
    context.insert(other)
    context.insert(forgotten)
    try context.save()

    let reader = SemanticRetrievalSourceReader(modelContainer: container)
    let snapshot = try await reader.snapshot(
      excluding: currentConversation.id,
      maximumCandidatesPerSource: 20,
      maximumProfiles: 4
    )
    let memoryCandidates = snapshot.candidates.filter { $0.source == .memoryTopic }
    #expect(Set(memoryCandidates.map(\.id)) == Set([global.id, current.id]))
    #expect(!memoryCandidates.map(\.id).contains(other.id))
    #expect(!memoryCandidates.map(\.id).contains(forgotten.id))
    #expect(memoryCandidates.first(where: { $0.id == global.id })?.memoryConfidence == 0.9)

    let versions = try await SemanticRetrievalComputeActor().versions(for: memoryCandidates)
    #expect(try await reader.validCandidateIDs(for: versions) == Set([global.id, current.id]))

    global.apply(
      title: "Preferred response language",
      content: global.content,
      confidence: global.confidence,
      importance: global.importance,
      stability: global.stability,
      status: global.status,
      isEnabled: global.isEnabled,
      evidenceCount: global.evidenceCount,
      revision: global.revision,
      at: date.addingTimeInterval(10)
    )
    try context.save()

    let validAfterTitleChange = try await reader.validCandidateIDs(for: versions)
    #expect(!validAfterTitleChange.contains(global.id))
    #expect(validAfterTitleChange.contains(current.id))
  }

  @Test("learned topics retain ranking metadata and explicit conflict precedence")
  func learnedTopicRendersAsInspectableContext() {
    let candidate = RetrievalCandidate(
      id: UUID(),
      source: .memoryTopic,
      containerID: UUID(),
      title: "Response language",
      content: "Response language: The user prefers replies in Turkish.",
      memoryConfidence: 0.96,
      memoryImportance: 0.85,
      createdAt: .now
    )

    let context = HybridMemoryRetriever(minimumLocalRelevance: 0).retrieve(
      query: "Which language should you use? Turkish please.",
      candidates: [candidate]
    )

    #expect(context.items.first?.source == .memoryTopic)
    #expect(context.items.first?.memoryConfidence == 0.96)
    #expect(context.items.first?.memoryImportance == 0.85)
    #expect(context.systemContent.contains("type=\"memory_topic\""))
    #expect(context.systemContent.contains("manually curated fact"))
    #expect(context.systemContent.contains("current user message always takes precedence"))
  }

  @MainActor
  @Test("consolidated evidence never leaks back through raw cross-chat recall")
  func forgottenTopicSuppressesItsRawEvidenceMessage() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let currentConversation = ConversationRecord(title: "Current")
    let sourceConversation = ConversationRecord(title: "Source")
    let sourceMessage = MessageRecord(
      conversationID: sourceConversation.id,
      role: .user,
      content: "My old editor preference was Vim.",
      status: .complete
    )
    let forgotten = MemoryTopicRecord(
      canonicalKey: "global:preference:editor",
      title: "Editor",
      content: "The user prefers Vim.",
      kind: .preference,
      scope: .global,
      conversationID: nil,
      status: .forgotten,
      confidence: 0.95,
      importance: 0.8,
      stability: .evolving,
      isEnabled: false,
      evidenceCount: 1
    )
    let fingerprint = AutomaticMemorySourceFingerprint.make(
      messages: [
        AutomaticMemorySourceMessage(
          id: sourceMessage.id,
          role: .user,
          content: sourceMessage.content,
          createdAt: sourceMessage.createdAt
        )
      ]
    )
    let evidence = MemoryEvidenceRecord(
      evidenceKey:
        "\(forgotten.id.uuidString.lowercased())/\(sourceMessage.id.uuidString.lowercased())/\(fingerprint)",
      topicID: forgotten.id,
      conversationID: sourceConversation.id,
      sourceMessageID: sourceMessage.id,
      assistantMessageID: nil,
      excerpt: sourceMessage.content,
      sourceFingerprint: fingerprint,
      providerConfigurationID: nil,
      providerKind: nil,
      providerDisplayName: nil,
      modelIdentifier: nil,
      confidence: 0.95
    )
    context.insert(currentConversation)
    context.insert(sourceConversation)
    context.insert(sourceMessage)
    context.insert(forgotten)
    context.insert(evidence)
    try context.save()

    let reader = SemanticRetrievalSourceReader(modelContainer: container)
    let snapshot = try await reader.snapshot(
      excluding: currentConversation.id,
      maximumCandidatesPerSource: 20,
      maximumProfiles: 4
    )
    #expect(!snapshot.candidates.contains { $0.id == sourceMessage.id })
    #expect(!snapshot.candidates.contains { $0.id == forgotten.id })
  }

  @MainActor
  @Test("project recall isolates chats, learned topics, and documents and revalidates moves")
  func projectRecallIsolationAndMoveRevalidation() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let projectA = ProjectRecord(name: "A")
    let projectB = ProjectRecord(name: "B")
    let target = ConversationRecord(title: "Target A")
    let chatA = ConversationRecord(title: "Chat A")
    let chatB = ConversationRecord(title: "Chat B")
    let personalChat = ConversationRecord(title: "Personal")
    [projectA, projectB].forEach(context.insert)
    [target, chatA, chatB, personalChat].forEach(context.insert)

    let messageA = MessageRecord(
      conversationID: chatA.id,
      role: .user,
      content: "Project A launch detail",
      status: .complete
    )
    let messageB = MessageRecord(
      conversationID: chatB.id,
      role: .user,
      content: "Project B private detail",
      status: .complete
    )
    let personalMessage = MessageRecord(
      conversationID: personalChat.id,
      role: .user,
      content: "Unassigned private detail",
      status: .complete
    )
    [messageA, messageB, personalMessage].forEach(context.insert)

    let date = Date(timeIntervalSince1970: 1_760_100_000)
    let globalTopic = topic(
      key: "global:preference:language",
      title: "Language",
      content: "Use Turkish.",
      date: date
    )
    let topicA = topic(
      key: "project:\(projectA.id.uuidString.lowercased()):fact:launch",
      title: "A launch",
      content: "Project A launches Friday.",
      scope: .project,
      date: date
    )
    let topicB = topic(
      key: "project:\(projectB.id.uuidString.lowercased()):fact:launch",
      title: "B launch",
      content: "Project B launches Monday.",
      scope: .project,
      date: date
    )
    [globalTopic, topicA, topicB].forEach(context.insert)

    let globalDocument = ImportedDocumentRecord(
      title: "Global guide",
      sourceFilename: "global.txt",
      mimeType: "text/plain",
      contentFingerprint: "global",
      characterCount: 12
    )
    let documentA = ImportedDocumentRecord(
      title: "A brief",
      sourceFilename: "a.txt",
      mimeType: "text/plain",
      contentFingerprint: "a",
      characterCount: 12
    )
    let documentB = ImportedDocumentRecord(
      title: "B brief",
      sourceFilename: "b.txt",
      mimeType: "text/plain",
      contentFingerprint: "b",
      characterCount: 12
    )
    [globalDocument, documentA, documentB].forEach(context.insert)
    let globalChunk = DocumentChunkRecord(
      documentID: globalDocument.id,
      chunkIndex: 0,
      content: "Global guide"
    )
    let chunkA = DocumentChunkRecord(
      documentID: documentA.id,
      chunkIndex: 0,
      content: "Project A brief"
    )
    let chunkB = DocumentChunkRecord(
      documentID: documentB.id,
      chunkIndex: 0,
      content: "Project B brief"
    )
    [globalChunk, chunkA, chunkB].forEach(context.insert)

    let targetBinding = ProjectResourceBindingRecord(
      resourceKind: .conversation,
      resourceID: target.id,
      projectID: projectA.id
    )
    context.insert(targetBinding)
    context.insert(
      ProjectResourceBindingRecord(
        resourceKind: .conversation,
        resourceID: chatA.id,
        projectID: projectA.id
      )
    )
    context.insert(
      ProjectResourceBindingRecord(
        resourceKind: .conversation,
        resourceID: chatB.id,
        projectID: projectB.id
      )
    )
    context.insert(
      ProjectResourceBindingRecord(
        resourceKind: .memoryTopic,
        resourceID: topicA.id,
        projectID: projectA.id
      )
    )
    context.insert(
      ProjectResourceBindingRecord(
        resourceKind: .memoryTopic,
        resourceID: topicB.id,
        projectID: projectB.id
      )
    )
    context.insert(
      ProjectResourceBindingRecord(
        resourceKind: .document,
        resourceID: documentA.id,
        projectID: projectA.id
      )
    )
    context.insert(
      ProjectResourceBindingRecord(
        resourceKind: .document,
        resourceID: documentB.id,
        projectID: projectB.id
      )
    )
    try context.save()

    let reader = SemanticRetrievalSourceReader(modelContainer: container)
    let snapshot = try await reader.snapshot(
      excluding: target.id,
      maximumCandidatesPerSource: 20,
      maximumProfiles: 0
    )
    let ids = Set(snapshot.candidates.map(\.id))
    #expect(ids.contains(messageA.id))
    #expect(!ids.contains(messageB.id))
    #expect(!ids.contains(personalMessage.id))
    #expect(ids.contains(globalTopic.id))
    #expect(ids.contains(topicA.id))
    #expect(!ids.contains(topicB.id))
    #expect(ids.contains(globalChunk.id))
    #expect(ids.contains(chunkA.id))
    #expect(!ids.contains(chunkB.id))

    let versions = try await SemanticRetrievalComputeActor().versions(
      for: snapshot.candidates,
      audienceScope: snapshot.audienceScope
    )
    #expect(try await reader.validCandidateIDs(for: versions) == ids)

    targetBinding.move(to: projectB.id)
    try context.save()
    #expect(try await reader.validCandidateIDs(for: versions).isEmpty)
  }

  @MainActor
  @Test("foreign project rows cannot consume a project's message or document scan budget")
  func projectSourcesArePartitionedBeforeBoundedScans() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let project = ProjectRecord(name: "Target")
    let foreignProject = ProjectRecord(name: "Foreign")
    let target = ConversationRecord(title: "Target chat")
    let source = ConversationRecord(title: "Target source")
    [project, foreignProject].forEach(context.insert)
    [target, source].forEach(context.insert)

    let baseDate = Date(timeIntervalSince1970: 1_760_200_000)
    let sourceMessage = MessageRecord(
      conversationID: source.id,
      role: .user,
      content: "Target project fact",
      createdAt: baseDate
    )
    context.insert(sourceMessage)
    context.insert(
      ProjectResourceBindingRecord(
        resourceKind: .conversation,
        resourceID: target.id,
        projectID: project.id
      )
    )
    context.insert(
      ProjectResourceBindingRecord(
        resourceKind: .conversation,
        resourceID: source.id,
        projectID: project.id
      )
    )

    let targetDocument = ImportedDocumentRecord(
      title: "Target document",
      sourceFilename: "target.txt",
      mimeType: "text/plain",
      contentFingerprint: "target",
      characterCount: 19,
      createdAt: baseDate,
      updatedAt: baseDate
    )
    let targetChunk = DocumentChunkRecord(
      documentID: targetDocument.id,
      chunkIndex: 0,
      content: "Target document fact",
      createdAt: baseDate
    )
    context.insert(targetDocument)
    context.insert(targetChunk)
    context.insert(
      ProjectResourceBindingRecord(
        resourceKind: .document,
        resourceID: targetDocument.id,
        projectID: project.id
      )
    )

    var foreignCandidateIDs: Set<UUID> = []
    for index in 1...4 {
      let date = baseDate.addingTimeInterval(Double(index))
      let conversation = ConversationRecord(title: "Foreign \(index)", createdAt: date)
      let message = MessageRecord(
        conversationID: conversation.id,
        role: .user,
        content: "Foreign message \(index)",
        createdAt: date
      )
      let document = ImportedDocumentRecord(
        title: "Foreign document \(index)",
        sourceFilename: "foreign-\(index).txt",
        mimeType: "text/plain",
        contentFingerprint: "foreign-\(index)",
        characterCount: 20,
        createdAt: date,
        updatedAt: date
      )
      let chunk = DocumentChunkRecord(
        documentID: document.id,
        chunkIndex: 0,
        content: "Foreign document fact \(index)",
        createdAt: date
      )
      context.insert(conversation)
      context.insert(message)
      context.insert(document)
      context.insert(chunk)
      context.insert(
        ProjectResourceBindingRecord(
          resourceKind: .conversation,
          resourceID: conversation.id,
          projectID: foreignProject.id
        )
      )
      context.insert(
        ProjectResourceBindingRecord(
          resourceKind: .document,
          resourceID: document.id,
          projectID: foreignProject.id
        )
      )
      foreignCandidateIDs.formUnion([message.id, chunk.id])
    }
    try context.save()

    let snapshot = try await SemanticRetrievalSourceReader(
      modelContainer: container
    ).snapshot(
      excluding: target.id,
      maximumCandidatesPerSource: 1,
      maximumProfiles: 0,
      limits: SemanticRetrievalSourceReadLimits(
        maximumBindingRecords: 16,
        maximumConversationRecords: 1,
        maximumMessageRecords: 1,
        maximumDocumentRecords: 1,
        maximumDocumentChunkRecords: 1
      )
    )

    let candidateIDs = Set(snapshot.candidates.map(\.id))
    #expect(candidateIDs.contains(sourceMessage.id))
    #expect(candidateIDs.contains(targetChunk.id))
    #expect(candidateIDs.isDisjoint(with: foreignCandidateIDs))
  }

  @MainActor
  @Test("project rows cannot consume the personal workspace scan budget")
  func personalSourcesArePartitionedBeforeBoundedScans() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let foreignProject = ProjectRecord(name: "Foreign")
    let target = ConversationRecord(title: "Personal target")
    let source = ConversationRecord(title: "Personal source")
    context.insert(foreignProject)
    context.insert(target)
    context.insert(source)

    let baseDate = Date(timeIntervalSince1970: 1_760_300_000)
    let sourceMessage = MessageRecord(
      conversationID: source.id,
      role: .user,
      content: "Personal workspace fact",
      createdAt: baseDate
    )
    let globalDocument = ImportedDocumentRecord(
      title: "Global document",
      sourceFilename: "global.txt",
      mimeType: "text/plain",
      contentFingerprint: "global",
      characterCount: 20,
      createdAt: baseDate,
      updatedAt: baseDate
    )
    let globalChunk = DocumentChunkRecord(
      documentID: globalDocument.id,
      chunkIndex: 0,
      content: "Global document fact",
      createdAt: baseDate
    )
    context.insert(sourceMessage)
    context.insert(globalDocument)
    context.insert(globalChunk)

    var foreignCandidateIDs: Set<UUID> = []
    for index in 1...4 {
      let date = baseDate.addingTimeInterval(Double(index))
      let conversation = ConversationRecord(title: "Foreign \(index)", createdAt: date)
      let message = MessageRecord(
        conversationID: conversation.id,
        role: .user,
        content: "Foreign message \(index)",
        createdAt: date
      )
      let document = ImportedDocumentRecord(
        title: "Foreign document \(index)",
        sourceFilename: "foreign-\(index).txt",
        mimeType: "text/plain",
        contentFingerprint: "foreign-\(index)",
        characterCount: 20,
        createdAt: date,
        updatedAt: date
      )
      let chunk = DocumentChunkRecord(
        documentID: document.id,
        chunkIndex: 0,
        content: "Foreign document fact \(index)",
        createdAt: date
      )
      context.insert(conversation)
      context.insert(message)
      context.insert(document)
      context.insert(chunk)
      context.insert(
        ProjectResourceBindingRecord(
          resourceKind: .conversation,
          resourceID: conversation.id,
          projectID: foreignProject.id
        )
      )
      context.insert(
        ProjectResourceBindingRecord(
          resourceKind: .document,
          resourceID: document.id,
          projectID: foreignProject.id
        )
      )
      foreignCandidateIDs.formUnion([message.id, chunk.id])
    }
    try context.save()

    let snapshot = try await SemanticRetrievalSourceReader(
      modelContainer: container
    ).snapshot(
      excluding: target.id,
      maximumCandidatesPerSource: 1,
      maximumProfiles: 0,
      limits: SemanticRetrievalSourceReadLimits(
        maximumBindingRecords: 16,
        maximumConversationRecords: 1,
        maximumMessageRecords: 1,
        maximumDocumentRecords: 1,
        maximumDocumentChunkRecords: 1
      )
    )

    let candidateIDs = Set(snapshot.candidates.map(\.id))
    #expect(candidateIDs.contains(sourceMessage.id))
    #expect(candidateIDs.contains(globalChunk.id))
    #expect(candidateIDs.isDisjoint(with: foreignCandidateIDs))
  }

  @MainActor
  private func topic(
    key: String,
    title: String,
    content: String,
    kind: MemoryTopicKind = .preference,
    scope: MemoryScope = .global,
    conversationID: UUID? = nil,
    date: Date
  ) -> MemoryTopicRecord {
    MemoryTopicRecord(
      canonicalKey: key,
      title: title,
      content: content,
      kind: kind,
      scope: scope,
      conversationID: conversationID,
      confidence: 0.9,
      importance: 0.8,
      stability: .stable,
      lastConfirmedAt: date,
      createdAt: date,
      updatedAt: date
    )
  }
}

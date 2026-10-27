import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite("Project request audience snapshots", .serialized)
@MainActor
struct ProjectContextSnapshotTests {
  @Test("binding moves and instruction edits invalidate a prepared request audience")
  func projectMutationsChangeTheRequestSnapshot() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversation = ConversationRecord(title: "Scoped request")
    let firstProject = ProjectRecord(
      name: "First",
      instructions: "Use first-project context.",
      createdAt: Date(timeIntervalSince1970: 1_770_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_770_000_000)
    )
    let secondProject = ProjectRecord(
      name: "Second",
      instructions: "Use second-project context.",
      createdAt: Date(timeIntervalSince1970: 1_770_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_770_000_000)
    )
    context.insert(conversation)
    context.insert(firstProject)
    context.insert(secondProject)
    try context.save()

    let repository = MosaicConversationReadRepository(modelContainer: container)
    let unassigned = try await repository.projectContextSnapshot(
      conversationID: conversation.id
    )
    #expect(unassigned.receipt == nil)
    #expect(unassigned.bindingID == nil)

    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: conversation.id,
      to: firstProject.id,
      in: context,
      now: Date(timeIntervalSince1970: 1_770_000_001)
    )
    try context.save()
    let prepared = try await repository.projectContextSnapshot(conversationID: conversation.id)
    #expect(prepared.receipt?.projectID == firstProject.id)
    #expect(prepared.receipt?.instructions == "Use first-project context.")

    firstProject.instructions = "Changed after preparation."
    firstProject.updatedAt = Date(timeIntervalSince1970: 1_770_000_002)
    try context.save()
    let edited = try await repository.projectContextSnapshot(conversationID: conversation.id)
    #expect(edited != prepared)
    #expect(edited.bindingID == prepared.bindingID)

    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: conversation.id,
      to: secondProject.id,
      in: context,
      now: Date(timeIntervalSince1970: 1_770_000_003)
    )
    try context.save()
    let moved = try await repository.projectContextSnapshot(conversationID: conversation.id)
    #expect(moved.receipt?.projectID == secondProject.id)
    #expect(moved != edited)

    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: conversation.id,
      to: firstProject.id,
      in: context,
      now: Date(timeIntervalSince1970: 1_770_000_004)
    )
    try context.save()
    let movedBack = try await repository.projectContextSnapshot(conversationID: conversation.id)
    #expect(movedBack.receipt?.projectID == firstProject.id)
    #expect(movedBack.bindingID == prepared.bindingID)
    #expect(movedBack.bindingUpdatedAt != prepared.bindingUpdatedAt)
    #expect(movedBack != prepared)
  }

  @Test("selected curated memory is revalidated for content and audience before sending")
  func curatedMemorySelectionIsRevalidated() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let project = ProjectRecord(name: "Target")
    let otherProject = ProjectRecord(name: "Other")
    let conversation = ConversationRecord(title: "Target chat")
    let originalContent = "Project-only anchor " + String(repeating: "x", count: 20_000)
    let memory = MemoryRecord(
      title: "Project fact",
      content: originalContent,
      scope: .project,
      isEnabled: true,
      isUserApproved: true
    )
    context.insert(project)
    context.insert(otherProject)
    context.insert(conversation)
    context.insert(memory)
    try context.save()
    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: conversation.id,
      to: project.id,
      in: context
    )
    _ = try ProjectBindingStore.assign(
      resourceKind: .memory,
      resourceID: memory.id,
      to: project.id,
      in: context
    )
    try context.save()

    let repository = MosaicConversationReadRepository(modelContainer: container)
    let selected = try await repository.curatedMemoryContext(conversationID: conversation.id)
    #expect(selected.includedMemories.map(\.id) == [memory.id])
    #expect(selected.includedMemories[0].content.count < originalContent.count)
    #expect(selected.includedMemories[0].sourceFingerprint != nil)
    #expect(
      try await repository.curatedMemoryContextIsCurrent(
        selected,
        conversationID: conversation.id,
        projectID: project.id
      )
    )

    memory.content = "Changed after context preparation."
    try context.save()
    #expect(
      try await !repository.curatedMemoryContextIsCurrent(
        selected,
        conversationID: conversation.id,
        projectID: project.id
      )
    )

    memory.content = originalContent
    _ = try ProjectBindingStore.assign(
      resourceKind: .memory,
      resourceID: memory.id,
      to: otherProject.id,
      in: context
    )
    try context.save()
    #expect(
      try await !repository.curatedMemoryContextIsCurrent(
        selected,
        conversationID: conversation.id,
        projectID: project.id
      )
    )
  }

  @Test("selected semantic excerpts are revalidated after an audience move")
  func retrievedSelectionIsRevalidated() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let project = ProjectRecord(name: "Target")
    let otherProject = ProjectRecord(name: "Other")
    let targetConversation = ConversationRecord(title: "Target chat")
    let sourceConversation = ConversationRecord(title: "Source chat")
    let sourceMessage = MessageRecord(
      conversationID: sourceConversation.id,
      role: .user,
      content: "The release codename is Lale.",
      status: .complete
    )
    context.insert(project)
    context.insert(otherProject)
    context.insert(targetConversation)
    context.insert(sourceConversation)
    context.insert(sourceMessage)
    try context.save()
    for conversation in [targetConversation, sourceConversation] {
      _ = try ProjectBindingStore.assign(
        resourceKind: .conversation,
        resourceID: conversation.id,
        to: project.id,
        in: context
      )
    }
    try context.save()
    let targetAudience = try await MosaicConversationReadRepository(
      modelContainer: container
    ).projectContextSnapshot(conversationID: targetConversation.id).audienceScope

    let candidate = RetrievalCandidate(
      id: sourceMessage.id,
      source: .conversationMessage,
      containerID: sourceConversation.id,
      title: sourceConversation.title,
      content: sourceMessage.content,
      createdAt: sourceMessage.createdAt
    )
    let selected = RetrievedContext(
      systemContent: "",
      items: [
        RetrievedContextItem(
          candidate: candidate,
          relevance: 1,
          sourceFingerprint: EmbeddingVectorCodec.fingerprint(for: candidate.content)
        )
      ]
    )
    #expect(
      await SemanticMemoryCoordinator.isCurrent(
        selected,
        audienceScope: targetAudience,
        in: context
      )
    )

    _ = try ProjectBindingStore.assign(
      resourceKind: .conversation,
      resourceID: sourceConversation.id,
      to: otherProject.id,
      in: context
    )
    try context.save()
    #expect(
      await !SemanticMemoryCoordinator.isCurrent(
        selected,
        audienceScope: targetAudience,
        in: context
      )
    )
  }

  @Test("topic title and content boundaries cannot collide during final validation")
  func topicFingerprintIsStructured() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let conversation = ConversationRecord(title: "Unassigned")
    let topic = MemoryTopicRecord(
      canonicalKey: "global:fact:collision-test",
      title: "a",
      content: "b: c",
      kind: .fact,
      scope: .global,
      conversationID: nil,
      origin: .manual,
      confidence: 1,
      importance: 1,
      stability: .stable
    )
    context.insert(conversation)
    context.insert(topic)
    try context.save()
    let candidate = RetrievalCandidate(
      id: topic.id,
      source: .memoryTopic,
      containerID: topic.id,
      title: topic.title,
      content: "\(topic.title): \(topic.content)",
      createdAt: topic.updatedAt
    )
    let selected = RetrievedContext(
      systemContent: "",
      items: [
        RetrievedContextItem(
          candidate: candidate,
          relevance: 1,
          sourceFingerprint: SemanticCandidateFingerprint.make(for: candidate)
        )
      ]
    )
    let audience = try await MosaicConversationReadRepository(
      modelContainer: container
    ).projectContextSnapshot(conversationID: conversation.id).audienceScope
    #expect(
      await SemanticMemoryCoordinator.isCurrent(
        selected,
        audienceScope: audience,
        in: context
      )
    )

    topic.apply(
      title: "a: b",
      content: "c",
      confidence: topic.confidence,
      importance: topic.importance,
      stability: topic.stability,
      status: topic.status,
      isEnabled: topic.isEnabled,
      evidenceCount: topic.evidenceCount,
      revision: topic.revision + 1,
      at: topic.updatedAt.addingTimeInterval(1)
    )
    try context.save()
    #expect("\(topic.title): \(topic.content)" == candidate.content)
    #expect(
      await !SemanticMemoryCoordinator.isCurrent(
        selected,
        audienceScope: audience,
        in: context
      )
    )
  }
}

import Foundation
import Testing

@testable import MosaicCore

@Suite("Project-aware curated memory context")
struct ProjectMemoryContextBuilderTests {
  @Test("global, matching project, and matching conversation memories remain isolated")
  func projectAndConversationAudienceIsolation() {
    let activeProjectID = UUID()
    let otherProjectID = UUID()
    let activeConversationID = UUID()
    let otherConversationID = UUID()
    let globalID = UUID()
    let activeProjectMemoryID = UUID()
    let activeConversationMemoryID = UUID()
    let memories = [
      memory(
        id: globalID,
        title: "Global",
        content: "Visible in every workspace.",
        scope: .global
      ),
      memory(
        id: activeProjectMemoryID,
        title: "Active project",
        content: "Visible only in the active project.",
        scope: .project,
        projectID: activeProjectID
      ),
      memory(
        title: "Other project",
        content: "Must not cross project boundaries.",
        scope: .project,
        projectID: otherProjectID
      ),
      memory(
        id: activeConversationMemoryID,
        title: "Active chat",
        content: "Visible only in the active chat.",
        scope: .conversation,
        conversationID: activeConversationID
      ),
      memory(
        title: "Other chat",
        content: "Must not cross chat boundaries.",
        scope: .conversation,
        conversationID: otherConversationID
      ),
    ]

    let context = MemoryContextBuilder().build(
      from: memories,
      for: activeConversationID,
      projectID: activeProjectID
    )

    #expect(
      Set(context.includedMemories.map(\.id))
        == Set([globalID, activeProjectMemoryID, activeConversationMemoryID])
    )
    #expect(context.systemContent.contains("Visible in every workspace."))
    #expect(context.systemContent.contains("Visible only in the active project."))
    #expect(context.systemContent.contains("Visible only in the active chat."))
    #expect(!context.systemContent.contains("Must not cross project boundaries."))
    #expect(!context.systemContent.contains("Must not cross chat boundaries."))
  }

  @Test("an unbound conversation never receives project memories")
  func unboundConversationUsesGlobalAndConversationOnly() {
    let conversationID = UUID()
    let globalID = UUID()
    let conversationMemoryID = UUID()
    let context = MemoryContextBuilder().build(
      from: [
        memory(
          id: globalID,
          title: "Global",
          content: "Global context.",
          scope: .global
        ),
        memory(
          title: "Project",
          content: "Project-only context.",
          scope: .project,
          projectID: UUID()
        ),
        memory(
          id: conversationMemoryID,
          title: "Conversation",
          content: "Conversation-only context.",
          scope: .conversation,
          conversationID: conversationID
        ),
      ],
      for: conversationID,
      projectID: nil
    )

    #expect(
      Set(context.includedMemories.map(\.id)) == Set([globalID, conversationMemoryID])
    )
    #expect(!context.systemContent.contains("Project-only context."))
  }

  @Test("project memories require an exact non-nil project identity")
  func projectIdentityMustMatchExactly() {
    let projectID = UUID()
    let projectMemoryID = UUID()
    let memories = [
      memory(
        id: projectMemoryID,
        title: "Project",
        content: "Exact project context.",
        scope: .project,
        projectID: projectID
      ),
      memory(
        title: "Malformed project memory",
        content: "Missing project identity.",
        scope: .project,
        projectID: nil
      ),
    ]

    let matching = MemoryContextBuilder().build(from: memories, projectID: projectID)
    let different = MemoryContextBuilder().build(from: memories, projectID: UUID())
    let unbound = MemoryContextBuilder().build(from: memories)

    #expect(matching.includedMemories.map(\.id) == [projectMemoryID])
    #expect(different.isEmpty)
    #expect(unbound.isEmpty)
  }

  private func memory(
    id: UUID = UUID(),
    title: String,
    content: String,
    scope: MemoryScope,
    projectID: UUID? = nil,
    conversationID: UUID? = nil
  ) -> MemorySnapshot {
    MemorySnapshot(
      id: id,
      title: title,
      content: content,
      scope: scope,
      projectID: projectID,
      conversationID: conversationID,
      isEnabled: true,
      isUserApproved: true,
      updatedAt: Date(timeIntervalSince1970: 1_770_000_000)
    )
  }
}

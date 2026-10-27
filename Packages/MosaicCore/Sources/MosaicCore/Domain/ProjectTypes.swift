import Foundation

/// The kinds of local source records that can belong to exactly one Mosaic project.
/// A missing binding means the resource lives in the personal/global workspace.
public enum ProjectResourceKind: String, Codable, CaseIterable, Sendable {
  case conversation
  case memory
  case memoryTopic = "memory_topic"
  case document
}

public struct MosaicProjectSnapshot: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let name: String
  public let instructions: String
  public let isArchived: Bool
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: UUID,
    name: String,
    instructions: String = "",
    isArchived: Bool = false,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.name = name
    self.instructions = instructions
    self.isArchived = isArchived
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct ProjectResourceBindingSnapshot: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let resourceKind: ProjectResourceKind
  public let resourceID: UUID
  public let projectID: UUID
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: UUID,
    resourceKind: ProjectResourceKind,
    resourceID: UUID,
    projectID: UUID,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.resourceKind = resourceKind
    self.resourceID = resourceID
    self.projectID = projectID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

/// Captures the project audience used while an asynchronous recall or memory-formation request
/// runs. Revalidation can reject output if another window moves the conversation meanwhile.
struct ConversationProjectScope: Hashable, Sendable {
  let conversationID: UUID
  let projectID: UUID?
  let bindingID: UUID?
  let bindingUpdatedAt: Date?
}

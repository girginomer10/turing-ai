import Foundation
import SwiftData

/// Copies a completed prefix into a new chat. Old messages, receipts and memory evidence
/// remain immutable. Copied turns contain no usage counters or receipts: no request ran twice.
@ModelActor
actor ConversationBranchStore {
  func create(sourceID: UUID, userMessageID: UUID, draft: String) throws -> UUID {
    try MosaicSourceFieldLimits.validateMessageContent(draft)
    guard
      let source = try modelContext.fetch(
        FetchDescriptor<ConversationRecord>(
          predicate: #Predicate { $0.id == sourceID })
      ).first,
      let anchor = try modelContext.fetch(
        FetchDescriptor<MessageRecord>(
          predicate: #Predicate { $0.id == userMessageID && $0.conversationID == sourceID })
      ).first,
      anchor.role == .user, anchor.status == .complete
    else { throw ConversationCompactionError.staleSource }
    let result = ConversationRecord(
      title: String((source.title + " · Alternative").prefix(160)),
      providerConfigurationID: source.providerConfigurationID,
      modelIdentifier: source.modelIdentifier,
      systemPrompt: source.systemPrompt, draftText: draft)
    modelContext.insert(result)
    do {
      let sourceMetadata = try modelContext.fetch(
        FetchDescriptor<ExperienceRecord>(
          predicate: #Predicate { $0.ownerID == sourceID && $0.category == "branch" })
      ).first
      let groupID =
        sourceMetadata.flatMap {
          try? JSONDecoder().decode(ExperienceValue.self, from: $0.payload).branchGroupID
        } ?? sourceID
      if sourceMetadata == nil {
        try ExperienceStore.save(
          ExperienceValue(
            id: UUID(), kind: .branch,
            conversationID: sourceID, branchGroupID: groupID), in: modelContext)
      }
      try ExperienceStore.save(
        ExperienceValue(
          id: UUID(), kind: .branch,
          conversationID: result.id, branchGroupID: groupID, originalConversationID: sourceID),
        in: modelContext)
      let key = ProjectResourceBindingRecord.makeBindingKey(
        resourceKind: .conversation, resourceID: sourceID)
      if let binding = try modelContext.fetch(
        FetchDescriptor<ProjectResourceBindingRecord>(
          predicate: #Predicate { $0.bindingKey == key })
      ).first {
        modelContext.insert(
          ProjectResourceBindingRecord(
            resourceKind: .conversation,
            resourceID: result.id, projectID: binding.projectID))
      }
      var offset = 0
      var reachedAnchor = false
      var previousCopyDate: Date?
      while !reachedAnchor {
        try Task.checkCancellation()
        var query = FetchDescriptor<MessageRecord>(
          predicate: #Predicate { $0.conversationID == sourceID },
          sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)])
        query.fetchLimit = 64
        query.fetchOffset = offset
        let rows = try modelContext.fetch(query)
        guard !rows.isEmpty else { throw ConversationCompactionError.staleSource }
        for row in rows {
          if row.id == userMessageID {
            reachedAnchor = true
            break
          }
          guard row.status == .complete else { continue }
          // Fresh UUIDs must not reorder a source prefix whose timestamps tie.
          let copyDate =
            previousCopyDate.map {
              max(row.createdAt, $0.addingTimeInterval(0.000001))
            } ?? row.createdAt
          previousCopyDate = copyDate
          let copy = MessageRecord(
            conversationID: result.id, role: row.role, content: row.content,
            providerConfigurationID: row.providerConfigurationID,
            providerKind: row.providerKindSnapshot,
            providerDisplayName: row.providerDisplayName, providerHost: row.providerHost,
            modelIdentifier: row.modelIdentifier, createdAt: copyDate,
            updatedAt: max(copyDate, row.updatedAt)
          )
          modelContext.insert(copy)
          try copyAttachments(from: row.id, to: copy.id, conversationID: result.id)
        }
        offset += rows.count
      }
      try copyAttachments(from: userMessageID, to: nil, conversationID: result.id)
      try modelContext.save()
      return result.id
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  private func copyAttachments(from messageID: UUID, to targetID: UUID?, conversationID: UUID)
    throws
  {
    let rows = try modelContext.fetch(
      FetchDescriptor<ExperienceRecord>(
        predicate: #Predicate { $0.messageID == messageID && $0.category == "attachment" }))
    guard rows.count <= 4 else { throw MosaicPortableBackupError.malformedEnvelope }
    for row in rows {
      var value = try JSONDecoder().decode(ExperienceValue.self, from: row.payload)
      value.id = UUID()
      value.conversationID = conversationID
      value.messageID = targetID
      try ExperienceStore.save(value, in: modelContext)
    }
  }
}

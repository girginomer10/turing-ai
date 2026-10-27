import Foundation
import SwiftData

/// Keeps automatically learned memory inside the audience of every conversation that supports it.
/// A topic with evidence from multiple conversations is never split implicitly: moving one of its
/// sources is rejected so the caller can ask the user to resolve the shared memory explicitly.
enum AutomaticMemoryProjectReconciler {
  private struct PlannedMutation {
    let topic: MemoryTopicRecord
    let existingBinding: ProjectResourceBindingRecord?
    let canonicalKey: String
    let scope: MemoryScope
    let conversationID: UUID?
    let projectID: UUID?
  }

  static func reconcileConversationMove(
    conversationID: UUID,
    from sourceProjectID: UUID?,
    to destinationProjectID: UUID?,
    in modelContext: ModelContext,
    now: Date
  ) throws {
    guard sourceProjectID != destinationProjectID else { return }

    let sourceID = conversationID
    var sourceEvidenceDescriptor = FetchDescriptor<MemoryEvidenceRecord>(
      predicate: #Predicate { $0.conversationID == sourceID }
    )
    sourceEvidenceDescriptor.includePendingChanges = true
    let sourceEvidence = try modelContext.fetch(sourceEvidenceDescriptor)
    let candidateTopicIDs = Set(sourceEvidence.map(\.topicID))
    guard !candidateTopicIDs.isEmpty else { return }

    var topicDescriptor = FetchDescriptor<MemoryTopicRecord>(
      predicate: #Predicate { candidateTopicIDs.contains($0.id) }
    )
    topicDescriptor.includePendingChanges = true
    let topics = try modelContext.fetch(topicDescriptor)
    let topicsByID = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0) })
    guard candidateTopicIDs.allSatisfy({ topicsByID[$0] != nil }) else {
      throw ProjectBindingError.invalidAutomaticMemoryAudience(conversationID)
    }

    let relevantTopics = topics.filter {
      $0.origin == .automatic && ($0.scope == .global || $0.scope == .project)
    }
    let relevantTopicIDs = Set(relevantTopics.map(\.id))
    guard !relevantTopicIDs.isEmpty else { return }
    try validateLiveAudience(topicIDs: relevantTopicIDs, in: modelContext)

    var allEvidenceDescriptor = FetchDescriptor<MemoryEvidenceRecord>(
      predicate: #Predicate { relevantTopicIDs.contains($0.topicID) }
    )
    allEvidenceDescriptor.includePendingChanges = true
    let allEvidence = try modelContext.fetch(allEvidenceDescriptor)
    let evidenceByTopic = Dictionary(grouping: allEvidence, by: \.topicID)
    let evidenceConversationIDs = Array(Set(allEvidence.map(\.conversationID)))
    let projectIDsByConversation = try ProjectBindingStore.projectIDs(
      resourceKind: .conversation,
      resourceIDs: evidenceConversationIDs,
      in: modelContext,
      includesPendingChanges: true
    )

    var plans: [PlannedMutation] = []
    for topic in relevantTopics {
      let evidence = evidenceByTopic[topic.id, default: []]
      guard !evidence.isEmpty, topic.evidenceCount == evidence.count else {
        throw ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)
      }
      let evidenceConversationSet = Set(evidence.map(\.conversationID))
      let existingBinding = try ProjectBindingStore.binding(
        resourceKind: .memoryTopic,
        resourceID: topic.id,
        in: modelContext,
        includesPendingChanges: true
      )

      switch topic.scope {
      case .global:
        guard existingBinding == nil,
          evidenceConversationSet.allSatisfy({ projectIDsByConversation[$0] == nil }),
          hasCanonicalPrefix(topic, projectID: nil)
        else {
          throw ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)
        }
        guard let destinationProjectID else { continue }
        guard evidenceConversationSet == Set([conversationID]) else {
          throw ProjectBindingError.mixedAutomaticMemoryEvidence(topic.id)
        }
        plans.append(
          PlannedMutation(
            topic: topic,
            existingBinding: nil,
            canonicalKey: try canonicalKey(
              for: topic,
              scope: .project,
              conversationID: nil,
              projectID: destinationProjectID
            ),
            scope: .project,
            conversationID: nil,
            projectID: destinationProjectID
          )
        )

      case .project:
        guard let existingBinding,
          let sourceProjectID,
          existingBinding.projectID == sourceProjectID,
          evidenceConversationSet.allSatisfy({
            projectIDsByConversation[$0] == sourceProjectID
          }),
          hasCanonicalPrefix(topic, projectID: sourceProjectID)
        else {
          throw ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)
        }
        guard evidenceConversationSet == Set([conversationID]) else {
          throw ProjectBindingError.mixedAutomaticMemoryEvidence(topic.id)
        }
        if let destinationProjectID {
          plans.append(
            PlannedMutation(
              topic: topic,
              existingBinding: existingBinding,
              canonicalKey: try canonicalKey(
                for: topic,
                scope: .project,
                conversationID: nil,
                projectID: destinationProjectID
              ),
              scope: .project,
              conversationID: nil,
              projectID: destinationProjectID
            )
          )
        } else {
          plans.append(
            PlannedMutation(
              topic: topic,
              existingBinding: existingBinding,
              canonicalKey: try canonicalKey(
                for: topic,
                scope: .conversation,
                conversationID: conversationID,
                projectID: nil
              ),
              scope: .conversation,
              conversationID: conversationID,
              projectID: nil
            )
          )
        }

      case .conversation:
        break
      }
    }

    try validateCanonicalDestinations(plans, in: modelContext)
    for plan in plans {
      plan.topic.reassignAutomaticAudience(
        canonicalKey: plan.canonicalKey,
        scope: plan.scope,
        conversationID: plan.conversationID,
        at: now
      )
      if let projectID = plan.projectID {
        if let binding = plan.existingBinding {
          binding.move(to: projectID, at: now)
        } else {
          modelContext.insert(
            ProjectResourceBindingRecord(
              resourceKind: .memoryTopic,
              resourceID: plan.topic.id,
              projectID: projectID,
              createdAt: now,
              updatedAt: now
            )
          )
        }
      } else if let binding = plan.existingBinding {
        modelContext.delete(binding)
      }
    }
  }

  static func validateLiveAudience(
    topicIDs: Set<UUID>,
    in modelContext: ModelContext
  ) throws {
    guard !topicIDs.isEmpty else { return }
    var topicDescriptor = FetchDescriptor<MemoryTopicRecord>(
      predicate: #Predicate { topicIDs.contains($0.id) }
    )
    topicDescriptor.includePendingChanges = true
    let topics = try modelContext.fetch(topicDescriptor)
    guard Set(topics.map(\.id)) == topicIDs else {
      throw ProjectBindingError.invalidAutomaticMemoryAudience(
        topicIDs.sorted { $0.uuidString < $1.uuidString }.first ?? UUID()
      )
    }
    let automaticTopics = topics.filter { $0.origin == .automatic }
    let automaticTopicIDs = Set(automaticTopics.map(\.id))
    guard !automaticTopicIDs.isEmpty else { return }

    var evidenceDescriptor = FetchDescriptor<MemoryEvidenceRecord>(
      predicate: #Predicate { automaticTopicIDs.contains($0.topicID) }
    )
    evidenceDescriptor.includePendingChanges = true
    let evidence = try modelContext.fetch(evidenceDescriptor)
    let evidenceByTopic = Dictionary(grouping: evidence, by: \.topicID)
    let conversationIDs = Array(Set(evidence.map(\.conversationID)))
    let projectIDsByConversation = try ProjectBindingStore.projectIDs(
      resourceKind: .conversation,
      resourceIDs: conversationIDs,
      in: modelContext,
      includesPendingChanges: true
    )
    var revisionDescriptor = FetchDescriptor<MemoryRevisionRecord>(
      predicate: #Predicate { automaticTopicIDs.contains($0.topicID) }
    )
    revisionDescriptor.includePendingChanges = true
    let revisionsByTopic = Dictionary(
      grouping: try modelContext.fetch(revisionDescriptor),
      by: \.topicID
    )

    for topic in automaticTopics {
      let topicEvidence = evidenceByTopic[topic.id, default: []]
      let topicEvidenceIDs = Set(topicEvidence.map(\.id))
      guard topic.evidenceCount == topicEvidence.count else {
        throw ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)
      }
      if topic.status == .active {
        let topicRevisions = revisionsByTopic[topic.id, default: []]
        let rootRevisions = topicRevisions.filter { $0.sequence == 1 }
        guard !topicEvidence.isEmpty,
          rootRevisions.count == 1,
          rootRevisions[0].kindRawValue == MemoryRevisionKind.created.rawValue,
          topicRevisions.contains(where: {
            $0.sourceEvidenceID.map(topicEvidenceIDs.contains) == true
          })
        else {
          throw ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)
        }
      }
      if topicEvidence.isEmpty {
        guard topic.status == .forgotten, !topic.isEnabled else {
          throw ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)
        }
      }

      let binding = try ProjectBindingStore.binding(
        resourceKind: .memoryTopic,
        resourceID: topic.id,
        in: modelContext,
        includesPendingChanges: true
      )
      switch topic.scope {
      case .global:
        guard binding == nil,
          topic.conversationID == nil,
          topicEvidence.allSatisfy({ projectIDsByConversation[$0.conversationID] == nil }),
          hasCanonicalPrefix(topic, projectID: nil)
        else {
          throw ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)
        }
      case .project:
        guard let projectID = binding?.projectID,
          topic.conversationID == nil,
          topicEvidence.allSatisfy({
            projectIDsByConversation[$0.conversationID] == projectID
          }),
          hasCanonicalPrefix(topic, projectID: projectID)
        else {
          throw ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)
        }
      case .conversation:
        guard let conversationID = topic.conversationID,
          binding == nil,
          topicEvidence.allSatisfy({ $0.conversationID == conversationID }),
          hasConversationCanonicalPrefix(topic, conversationID: conversationID)
        else {
          throw ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)
        }
      }
    }
  }

  static func validateLiveAudience(
    evidencedBy conversationID: UUID,
    in modelContext: ModelContext
  ) throws {
    let sourceID = conversationID
    var descriptor = FetchDescriptor<MemoryEvidenceRecord>(
      predicate: #Predicate { $0.conversationID == sourceID }
    )
    descriptor.includePendingChanges = true
    try validateLiveAudience(
      topicIDs: Set(try modelContext.fetch(descriptor).map(\.topicID)),
      in: modelContext
    )
  }

  private static func hasCanonicalPrefix(
    _ topic: MemoryTopicRecord,
    projectID: UUID?
  ) -> Bool {
    let prefix: String
    if let projectID {
      prefix = "project:\(projectID.uuidString.lowercased()):\(topic.kind.rawValue):"
    } else {
      prefix = "global:\(topic.kind.rawValue):"
    }
    return topic.canonicalKey.hasPrefix(prefix)
      && topic.canonicalKey.utf8.count > prefix.utf8.count
  }

  private static func hasConversationCanonicalPrefix(
    _ topic: MemoryTopicRecord,
    conversationID: UUID
  ) -> Bool {
    let prefix =
      "conversation:\(conversationID.uuidString.lowercased()):\(topic.kind.rawValue):"
    return topic.canonicalKey.hasPrefix(prefix)
      && topic.canonicalKey.utf8.count > prefix.utf8.count
  }

  private static func canonicalKey(
    for topic: MemoryTopicRecord,
    scope: MemoryScope,
    conversationID: UUID?,
    projectID: UUID?
  ) throws -> String {
    let sourcePrefix: String
    switch topic.scope {
    case .global:
      sourcePrefix = "global:\(topic.kind.rawValue):"
    case .project:
      guard let sourceProjectID = projectIDForCanonicalKey(topic.canonicalKey) else {
        throw ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)
      }
      sourcePrefix = "project:\(sourceProjectID.uuidString.lowercased()):\(topic.kind.rawValue):"
    case .conversation:
      throw ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)
    }
    guard topic.canonicalKey.hasPrefix(sourcePrefix) else {
      throw ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)
    }
    let suffix = String(topic.canonicalKey.dropFirst(sourcePrefix.count))
    guard !suffix.isEmpty else {
      throw ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)
    }

    let destinationPrefix: String
    switch scope {
    case .global:
      destinationPrefix = "global:\(topic.kind.rawValue):"
    case .project:
      guard let projectID else {
        throw ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)
      }
      destinationPrefix =
        "project:\(projectID.uuidString.lowercased()):\(topic.kind.rawValue):"
    case .conversation:
      guard let conversationID else {
        throw ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)
      }
      destinationPrefix =
        "conversation:\(conversationID.uuidString.lowercased()):\(topic.kind.rawValue):"
    }
    let value = destinationPrefix + suffix
    guard value.utf8.count <= MosaicSourceFieldLimits.maximumMemoryCanonicalKeyUTF8Bytes else {
      throw ProjectBindingError.invalidAutomaticMemoryAudience(topic.id)
    }
    return value
  }

  private static func projectIDForCanonicalKey(_ canonicalKey: String) -> UUID? {
    let components = canonicalKey.split(separator: ":", omittingEmptySubsequences: false)
    guard components.count >= 4, components[0] == "project",
      let projectID = UUID(uuidString: String(components[1]))
    else {
      return nil
    }
    return projectID
  }

  private static func validateCanonicalDestinations(
    _ plans: [PlannedMutation],
    in modelContext: ModelContext
  ) throws {
    var plannedKeys: Set<String> = []
    for plan in plans {
      guard plannedKeys.insert(plan.canonicalKey).inserted else {
        throw ProjectBindingError.automaticMemoryCanonicalConflict(plan.topic.id)
      }
      let key = plan.canonicalKey
      var descriptor = FetchDescriptor<MemoryTopicRecord>(
        predicate: #Predicate { $0.canonicalKey == key }
      )
      descriptor.fetchLimit = 1
      descriptor.includePendingChanges = true
      if let collision = try modelContext.fetch(descriptor).first,
        collision.id != plan.topic.id
      {
        throw ProjectBindingError.automaticMemoryCanonicalConflict(collision.id)
      }
    }
  }
}

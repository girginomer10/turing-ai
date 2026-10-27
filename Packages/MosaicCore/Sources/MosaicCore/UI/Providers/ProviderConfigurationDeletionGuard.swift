import Foundation
import SwiftData

struct ProviderConfigurationUsageSummary: Equatable, Sendable {
  let conversationCount: Int
  let scheduledTaskCount: Int
  let embeddingProfileCount: Int
  let memoryFormationJobCount: Int

  var isInUse: Bool {
    conversationCount > 0 || scheduledTaskCount > 0 || embeddingProfileCount > 0
  }

  var localizedDescription: String {
    let parts = [
      Self.countDescription(conversationCount, singular: "chat", plural: "chats"),
      Self.countDescription(
        scheduledTaskCount,
        singular: "automation",
        plural: "automations"
      ),
      Self.countDescription(
        embeddingProfileCount,
        singular: "embedding profile",
        plural: "embedding profiles"
      ),
    ].compactMap { $0 }

    let joined: String
    switch parts.count {
    case 0:
      joined = ""
    case 1:
      joined = parts[0]
    case 2:
      joined = "\(parts[0]) and \(parts[1])"
    default:
      joined = "\(parts.dropLast().joined(separator: ", ")), and \(parts.last!)"
    }

    return
      "This provider is still used by \(joined). Reassign or delete those items before deleting the provider."
  }

  private static func countDescription(
    _ count: Int,
    singular: String,
    plural: String
  ) -> String? {
    guard count > 0 else { return nil }
    return "\(count.formatted()) \(count == 1 ? singular : plural)"
  }
}

enum ProviderConfigurationDeletionGuardError: LocalizedError, Equatable {
  case inUse(ProviderConfigurationUsageSummary)

  var errorDescription: String? {
    switch self {
    case .inUse(let usage):
      usage.localizedDescription
    }
  }
}

/// Prevents deleting a provider while live user-editable records still point to it. Historical
/// message and audit snapshots intentionally keep their provider UUID as immutable provenance.
@MainActor
enum ProviderConfigurationDeletionGuard {
  static func validateCanDelete(
    configurationID: UUID,
    in modelContext: ModelContext
  ) throws {
    let usage = try usage(configurationID: configurationID, in: modelContext)
    guard !usage.isInUse else {
      throw ProviderConfigurationDeletionGuardError.inUse(usage)
    }
  }

  static func usage(
    configurationID: UUID,
    in modelContext: ModelContext
  ) throws -> ProviderConfigurationUsageSummary {
    let providerID = configurationID
    let conversations = FetchDescriptor<ConversationRecord>(
      predicate: #Predicate { $0.providerConfigurationID == providerID }
    )
    let scheduledTasks = FetchDescriptor<ScheduledTaskRecord>(
      predicate: #Predicate { $0.providerConfigurationID == providerID }
    )
    let embeddingProfiles = FetchDescriptor<EmbeddingProfileRecord>(
      predicate: #Predicate { $0.providerConfigurationID == providerID }
    )
    let pendingStatus = MemoryFormationJobStatus.pending.rawValue
    let generatingStatus = MemoryFormationJobStatus.generating.rawValue
    let failedStatus = MemoryFormationJobStatus.failed.rawValue
    let memoryFormationJobs = FetchDescriptor<MemoryFormationJobRecord>(
      predicate: #Predicate {
        $0.providerConfigurationID == providerID
          && ($0.statusRawValue == pendingStatus || $0.statusRawValue == generatingStatus
            || $0.statusRawValue == failedStatus)
      }
    )

    return try ProviderConfigurationUsageSummary(
      conversationCount: modelContext.fetchCount(conversations),
      scheduledTaskCount: modelContext.fetchCount(scheduledTasks),
      embeddingProfileCount: modelContext.fetchCount(embeddingProfiles),
      memoryFormationJobCount: modelContext.fetchCount(memoryFormationJobs)
    )
  }
}

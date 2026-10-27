import Foundation
import SwiftData

/// Repairs assistant rows whose owning process ended while a response was streaming. The initial
/// scan runs once per live-store generation, and a later operation-drain scan repairs terminal-save
/// failures without mistaking an active request owned by another window for a crash orphan.
@MainActor
final class ConversationInterruptedResponseRecovery {
  static let shared = ConversationInterruptedResponseRecovery()

  enum ScanReason: Sendable {
    /// The bounded cold-launch scan only needs to run once for a live-store generation.
    case generationOpened
    /// A provider operation just released its lease. Always rescan because its terminal save may
    /// have failed after the cold-launch scan completed, leaving a persisted streaming row behind.
    case operationsDrained
  }

  private struct StoreGeneration: Hashable {
    let containerID: ObjectIdentifier
    let generation: UInt64
  }

  private var completedGenerations: Set<StoreGeneration> = []

  @discardableResult
  func reconcile(
    in modelContext: ModelContext,
    sourceGeneration: UInt64,
    reason: ScanReason = .generationOpened,
    operationCoordinator: MosaicOperationCoordinator = .shared
  ) throws -> Int {
    let key = StoreGeneration(
      containerID: ObjectIdentifier(modelContext.container),
      generation: sourceGeneration
    )
    if reason == .generationOpened, completedGenerations.contains(key) { return 0 }
    guard operationCoordinator.activeOperations.isEmpty,
      !operationCoordinator.isSourceAccessBlocked
    else {
      return 0
    }

    let streamingStatus = MessageStatus.streaming.rawValue
    let assistantRole = MessageRole.assistant.rawValue
    var recoveredCount = 0

    do {
      while true {
        var descriptor = FetchDescriptor<MessageRecord>(
          predicate: #Predicate {
            $0.statusRawValue == streamingStatus && $0.roleRawValue == assistantRole
          },
          sortBy: [SortDescriptor(\MessageRecord.id)]
        )
        descriptor.fetchLimit = 128
        descriptor.includePendingChanges = false
        let interruptedMessages = try modelContext.fetch(descriptor)
        guard !interruptedMessages.isEmpty else { break }

        let recoveredAt = Date.now
        for message in interruptedMessages {
          message.status = .failed
          message.errorDescription =
            "Turing AI was interrupted before this response finished. You can try this request again."
          message.updatedAt = recoveredAt
        }
        try operationCoordinator.saveSourceChanges(in: modelContext)
        recoveredCount += interruptedMessages.count
      }
      completedGenerations.insert(key)
      return recoveredCount
    } catch {
      modelContext.rollback()
      throw error
    }
  }
}

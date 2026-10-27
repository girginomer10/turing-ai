import Foundation
import Observation

/// Keeps an in-process conversation request reachable after its originating detail view leaves the
/// navigation hierarchy. The operation coordinator still owns source-store exclusion; this registry
/// owns only user-visible activity and cancellation for the currently running task.
@Observable
@MainActor
final class ConversationRequestRegistry {
  static let shared = ConversationRequestRegistry()

  private(set) var activeConversationIDs: Set<UUID> = []

  @ObservationIgnored
  private var entries: [UUID: Entry] = [:]

  private struct Entry {
    let requestID: UUID
    let cancel: @MainActor () -> Void
  }

  @discardableResult
  func register(
    conversationID: UUID,
    requestID: UUID,
    cancel: @escaping @MainActor () -> Void
  ) -> Bool {
    guard entries[conversationID] == nil else { return false }
    entries[conversationID] = Entry(requestID: requestID, cancel: cancel)
    activeConversationIDs.insert(conversationID)
    return true
  }

  @discardableResult
  func transfer(
    conversationID: UUID,
    requestID: UUID,
    cancel: @escaping @MainActor () -> Void
  ) -> Bool {
    guard entries[conversationID]?.requestID == requestID else { return false }
    entries[conversationID] = Entry(requestID: requestID, cancel: cancel)
    return true
  }

  func finish(conversationID: UUID, requestID: UUID) {
    guard entries[conversationID]?.requestID == requestID else { return }
    entries[conversationID] = nil
    activeConversationIDs.remove(conversationID)
  }

  func cancel(conversationID: UUID) {
    entries[conversationID]?.cancel()
  }

  func isActive(conversationID: UUID) -> Bool {
    activeConversationIDs.contains(conversationID)
  }
}

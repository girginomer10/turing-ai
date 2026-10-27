import Foundation
import Testing

@testable import MosaicCore

@MainActor
struct LiveTranscriptionBackgroundTaskTests {
  @Test
  func repeatedBeginAndEndStayBalanced() {
    let provider = FakeBackgroundTaskProvider()
    let lease = LiveTranscriptionBackgroundDrainLease(provider: provider)
    let expiration = ExpirationRecorder()

    #expect(lease.begin { expiration.record() })
    #expect(lease.begin { expiration.record() })
    #expect(lease.isActive)
    #expect(provider.beginCount == 1)

    lease.end()
    lease.end()

    #expect(!lease.isActive)
    #expect(provider.endCount == 1)
    #expect(expiration.count == 0)
  }

  @Test
  func expirationEndsAssertionBeforeRunningFallback() {
    let provider = FakeBackgroundTaskProvider()
    let lease = LiveTranscriptionBackgroundDrainLease(provider: provider)
    let expiration = ExpirationRecorder()

    #expect(
      lease.begin {
        expiration.record(providerWasEnded: provider.endCount == 1)
      }
    )
    provider.expire()

    #expect(!lease.isActive)
    #expect(provider.endCount == 1)
    #expect(expiration.count == 1)
    #expect(expiration.providerWasEndedBeforeFallback)

    lease.end()
    #expect(provider.endCount == 1)
  }

  @Test
  func failedAcquisitionDoesNotCreateCleanupDebt() {
    let provider = FakeBackgroundTaskProvider(grantsTask: false)
    let lease = LiveTranscriptionBackgroundDrainLease(provider: provider)
    let expiration = ExpirationRecorder()

    #expect(!lease.begin { expiration.record() })
    #expect(!lease.isActive)
    lease.end()

    #expect(provider.beginCount == 1)
    #expect(provider.endCount == 0)
    #expect(expiration.count == 0)
  }

  @Test
  func finishingSessionRequestsProtectionWhenSceneStopsBeingActive() {
    #expect(
      ConversationLiveTranscriptionState.finishing.lifecycleAction(
        for: .sceneBecameInactive
      ) == .protectFinalization
    )
    #expect(
      ConversationLiveTranscriptionState.finishing.lifecycleAction(
        for: .sceneEnteredBackground
      ) == .protectFinalization
    )
    #expect(
      ConversationLiveTranscriptionState.finishing.lifecycleAction(
        for: .viewDisappeared
      ) == .none
    )
  }
}

@MainActor
private final class FakeBackgroundTaskProvider: LiveTranscriptionBackgroundTaskProviding {
  private let grantsTask: Bool
  private var expirationHandler: (@MainActor @Sendable () -> Void)?
  private var activeToken: UUID?

  private(set) var beginCount = 0
  private(set) var endCount = 0

  init(grantsTask: Bool = true) {
    self.grantsTask = grantsTask
  }

  func begin(
    name _: String,
    expirationHandler: @escaping @MainActor @Sendable () -> Void
  ) -> UUID? {
    beginCount += 1
    guard grantsTask else { return nil }
    let token = UUID()
    activeToken = token
    self.expirationHandler = expirationHandler
    return token
  }

  func end(_ token: UUID) {
    guard activeToken == token else { return }
    activeToken = nil
    expirationHandler = nil
    endCount += 1
  }

  func expire() {
    let handler = expirationHandler
    handler?()
  }
}

@MainActor
private final class ExpirationRecorder {
  private(set) var count = 0
  private(set) var providerWasEndedBeforeFallback = false

  func record(providerWasEnded: Bool = false) {
    count += 1
    providerWasEndedBeforeFallback = providerWasEnded
  }
}

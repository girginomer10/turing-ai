import Foundation

#if os(iOS)
  import UIKit
#endif

@MainActor
protocol LiveTranscriptionBackgroundTaskProviding: AnyObject {
  func begin(
    name: String,
    expirationHandler: @escaping @MainActor @Sendable () -> Void
  ) -> UUID?
  func end(_ token: UUID)
}

/// Owns at most one balanced, short-lived background execution assertion for the final transcript
/// drain. Expiration releases the system assertion before asking the caller to cancel its work.
@MainActor
final class LiveTranscriptionBackgroundDrainLease {
  private let provider: any LiveTranscriptionBackgroundTaskProviding
  private var token: UUID?
  private var expirationHandler: (@MainActor @Sendable () -> Void)?

  init(provider: any LiveTranscriptionBackgroundTaskProviding = SystemBackgroundTaskProvider.shared)
  {
    self.provider = provider
  }

  var isActive: Bool { token != nil }

  @discardableResult
  func begin(
    onExpiration: @escaping @MainActor @Sendable () -> Void
  ) -> Bool {
    if token != nil { return true }

    expirationHandler = onExpiration
    let acquiredToken = provider.begin(
      name: "Finish Live Transcription"
    ) { [weak self] in
      self?.expire()
    }
    guard let acquiredToken else {
      expirationHandler = nil
      return false
    }
    token = acquiredToken
    return true
  }

  func end() {
    guard let token else { return }
    self.token = nil
    expirationHandler = nil
    provider.end(token)
  }

  private func expire() {
    guard let token else { return }
    self.token = nil
    let expirationHandler = expirationHandler
    self.expirationHandler = nil
    provider.end(token)
    expirationHandler?()
  }
}

@MainActor
private final class SystemBackgroundTaskProvider: LiveTranscriptionBackgroundTaskProviding {
  static let shared = SystemBackgroundTaskProvider()

  #if os(iOS)
    private var identifiersByToken: [UUID: UIBackgroundTaskIdentifier] = [:]
  #endif

  func begin(
    name: String,
    expirationHandler: @escaping @MainActor @Sendable () -> Void
  ) -> UUID? {
    #if os(iOS)
      let token = UUID()
      let identifier = UIApplication.shared.beginBackgroundTask(
        withName: name
      ) { [weak self] in
        // The provider is a process singleton, but still end here first so a released UI lease can
        // never leave UIKit with an unbalanced assertion. The lease's matching end is idempotent.
        self?.end(token)
        expirationHandler()
      }
      guard identifier != .invalid else { return nil }
      identifiersByToken[token] = identifier
      return token
    #else
      return nil
    #endif
  }

  func end(_ token: UUID) {
    #if os(iOS)
      guard let identifier = identifiersByToken.removeValue(forKey: token) else { return }
      UIApplication.shared.endBackgroundTask(identifier)
    #endif
  }
}

import AuthenticationServices
import Foundation
import SwiftUI

@MainActor
@Observable
final class GoogleSignInSession: NSObject, ASWebAuthenticationPresentationContextProviding {
  var account: GoogleAccount?
  var isBusy = false
  var error: String?
  private var session: ASWebAuthenticationSession?
  private var signInTask: Task<Void, Never>?
  private var operationID: UUID?

  var isConfigured: Bool { GoogleOAuthConfiguration.bundled.isValid }
  func load() async {
    do { account = try await GoogleConnectionStore.shared.account() } catch {
      self.error = "The Google connection could not be read from Keychain. Please try again."
    }
  }
  func connect(services: Set<GoogleService>) {
    guard !isBusy else { return }
    let id = UUID()
    operationID = id
    isBusy = true
    error = nil
    signInTask = Task { @MainActor in
      defer {
        if operationID == id {
          isBusy = false
          session = nil
          signInTask = nil
        }
      }
      do {
        let attempt = try await GoogleConnectionStore.shared.beginAuthorization(
          configuration: .bundled, services: services)
        let url = try attempt.authorizationURL()
        let callback = try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<URL, Error>) in
          let auth = ASWebAuthenticationSession(
            url: url, callbackURLScheme: attempt.configuration.callbackScheme
          ) { @Sendable url, error in
            if let url {
              continuation.resume(returning: url)
            } else {
              continuation.resume(throwing: error ?? GoogleConnectionError.authorizationDenied)
            }
          }
          auth.presentationContextProvider = self
          auth.prefersEphemeralWebBrowserSession = false
          session = auth
          if !auth.start() {
            continuation.resume(throwing: GoogleConnectionError.authorizationDenied)
          }
        }
        try Task.checkCancellation()
        account = try await GoogleConnectionStore.shared.completeAuthorization(
          attempt, callback: callback)
      } catch is CancellationError {} catch {
        self.error =
          (error as? GoogleConnectionError)?.localizedDescription
          ?? "Google sign-in did not finish. Please try again."
      }
    }
  }
  func disconnect() {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    Task { @MainActor in
      defer { isBusy = false }
      do {
        try await GoogleConnectionStore.shared.disconnect()
        account = nil
      } catch {
        self.error = "The Google connection could not be removed from Keychain. Please try again."
      }
    }
  }
  func cancel() {
    signInTask?.cancel()
    session?.cancel()
  }
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    #if os(iOS)
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    #else
      NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    #endif
  }
}

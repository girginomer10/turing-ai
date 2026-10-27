import Foundation

/// Objective-C frameworks may call these handlers on arbitrary queues. Construct the callbacks
/// outside UI isolation; entering an inherited MainActor closure would trap before its Task runs.
public struct VoiceCallbackDelivery: Sendable {
  private let receive: @MainActor @Sendable (Result<Data, VoiceError>) -> Void

  public init(receive: @escaping @MainActor @Sendable (Result<Data, VoiceError>) -> Void) {
    self.receive = receive
  }

  public var replyHandler: @Sendable (Data) -> Void {
    { [receive] data in Task { @MainActor in receive(.success(data)) } }
  }

  public var errorHandler: @Sendable (any Error) -> Void {
    { [receive] _ in Task { @MainActor in receive(.failure(.disconnected)) } }
  }
}

import Foundation

/// Hardware boundary; the same conversation controller runs against deterministic audio in tests.
@MainActor public protocol VoiceAudioDevice: AnyObject {
  var queuedMilliseconds: Int { get }
  var playedMilliseconds: Int { get }
  var nextPlaybackMilliseconds: Int { get }
  var onPlaybackDrained: (@MainActor () -> Void)? { get set }
  func live() async throws -> AsyncThrowingStream<Data, Error>
  func playPCM(_ data: Data) throws
  func clearPlayback()
  func record() async throws
  func finishRecording() throws -> Data
  func playFile(_ data: Data, completion: @escaping () -> Void) async throws
  func stop()
}

public protocol LiveVoiceTransport: Sendable {
  func start() async throws -> AsyncThrowingStream<LiveVoiceEvent, Error>
  func sendAudio(_ data: Data) async throws
  func truncate(itemID: String, playedMilliseconds: Int) async throws
  func stop() async
}

extension LiveVoiceSession: LiveVoiceTransport {
  public func stop() { stop(error: nil) }
}

/// 24 kHz playback scheduling, including partially rendered buffers and gaps between responses.
/// Providers stream faster than speech: 20 seconds was insufficient for ordinary answers.
public struct VoicePlaybackQueue: Sendable {
  public static let maximumFrames = 24_000 * 120
  public private(set) var pendingFrames = 0
  public private(set) var tailFrame = 0
  public init() {}
  public mutating func schedule(frames: Int, renderedFrames: Int) throws {
    guard frames > 0, frames <= Self.maximumFrames - pendingFrames else {
      throw VoiceError.message(
        "The spoken response exceeded the two-minute playback limit. Try a shorter answer.")
    }
    tailFrame = max(tailFrame, max(0, renderedFrames)) + frames
    pendingFrames += frames
  }
  public mutating func completed(frames: Int) {
    pendingFrames = max(0, pendingFrames - max(0, frames))
  }
  public mutating func reset() {
    pendingFrames = 0
    tailFrame = 0
  }
}

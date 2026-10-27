import AVFoundation
import Foundation
import Testing

@testable import MosaicCore

struct LiveMicrophoneAudioSourceTests {
  @Test
  func permissionPreflightWaitsForFirstGrant() async throws {
    let authorizer = DeferredPermissionAuthorizer()
    let preflight = Task {
      try await LiveMicrophonePermissionPreflight.request {
        await authorizer.request()
      }
    }

    await authorizer.waitUntilRequested()
    await authorizer.resolve(true)

    try await preflight.value
  }

  @Test
  func permissionPreflightRejectsDenial() async {
    await #expect(throws: LiveMicrophoneAudioSourceError.permissionDenied) {
      try await LiveMicrophonePermissionPreflight.request { false }
    }
  }

  @Test
  func permissionPreflightHonorsCancellationAfterAuthorizationReturns() async {
    let authorizer = DeferredPermissionAuthorizer()
    let preflight = Task {
      try await LiveMicrophonePermissionPreflight.request {
        await authorizer.request()
      }
    }

    await authorizer.waitUntilRequested()
    preflight.cancel()
    await authorizer.resolve(true)

    await #expect(throws: CancellationError.self) {
      try await preflight.value
    }
  }

  @Test
  func cancelledSetupIsNotMisreportedAsAnInvalidProviderResponse() async {
    let validation = Task<Void, Error> {
      withUnsafeCurrentTask { task in
        task?.cancel()
      }
      try ConversationLiveTranscriptionSetupValidation.validate(didCompleteSetup: false)
    }

    await #expect(throws: CancellationError.self) {
      try await validation.value
    }
  }

  @Test
  func permissionPromptInactiveLifecycleDoesNotCancelButBackgroundDoes() {
    #expect(
      ConversationLiveTranscriptionState.requestingPermission.lifecycleAction(
        for: .sceneBecameInactive
      ) == .none
    )
    #expect(
      ConversationLiveTranscriptionState.requestingPermission.lifecycleAction(
        for: .sceneEnteredBackground
      ) == .cancelPermissionRequest
    )
    #expect(
      ConversationLiveTranscriptionState.requestingPermission.lifecycleAction(
        for: .viewDisappeared
      ) == .cancelPermissionRequest
    )
    #expect(
      ConversationLiveTranscriptionState.connecting.lifecycleAction(
        for: .sceneBecameInactive
      ) == .cancelSession
    )
    #expect(
      ConversationLiveTranscriptionState.listening.lifecycleAction(
        for: .sceneEnteredBackground
      ) == .finishRecording
    )
  }

  @Test
  func converts44100HzStereoBufferToMono16kPCM16() throws {
    try verifyStereoConversion(sampleRate: 44_100)
  }

  @Test
  func converts48000HzStereoBufferToMono16kPCM16() throws {
    try verifyStereoConversion(sampleRate: 48_000)
  }

  @Test
  func packetizesIrregularConverterOutputInto100MillisecondChunks() throws {
    var accumulator = LivePCM16ChunkAccumulator()
    var chunks: [LivePCM16AudioChunk] = []

    for frameCount in [1_365, 1_365, 2_048] {
      chunks.append(
        contentsOf: try accumulator.append(
          Data(repeating: 0x5A, count: frameCount * LivePCM16AudioChunk.bytesPerFrame)
        )
      )
    }
    let pendingRemainder = accumulator.takeRemainder()
    let remainder = try #require(pendingRemainder)

    #expect(chunks.count == 2)
    #expect(
      chunks.allSatisfy { $0.frameCount == LiveMicrophoneAudioSource.framesPerChunk }
    )
    #expect(remainder.frameCount == 1_578)
    #expect(
      chunks.reduce(remainder.frameCount, { $0 + $1.frameCount })
        == 1_365 + 1_365 + 2_048
    )
  }

  private func verifyStereoConversion(sampleRate: Double) throws {
    let inputFormat = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 2,
        interleaved: false
      )
    )
    let converter = try LivePCM16AudioConverter(inputFormat: inputFormat)
    let frameCount = AVAudioFrameCount(sampleRate / 10)
    let blockCount = 10
    var convertedData = Data()

    for blockIndex in 0..<blockCount {
      let inputBuffer = try #require(
        AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount)
      )
      inputBuffer.frameLength = frameCount

      let channels = try #require(inputBuffer.floatChannelData)
      for frame in 0..<Int(frameCount) {
        let absoluteFrame = blockIndex * Int(frameCount) + frame
        let phase = 2 * Float.pi * 440 * Float(absoluteFrame) / Float(sampleRate)
        channels[0][frame] = 0
        channels[1][frame] = sin(phase) * 0.5
      }
      convertedData.append(try converter.convert(inputBuffer))
    }
    convertedData.append(try converter.finish())

    let samples = decodeLittleEndianPCM16(convertedData)
    let expectedFrameCount = LiveMicrophoneAudioSource.framesPerChunk * blockCount

    #expect(convertedData.count.isMultiple(of: LivePCM16AudioChunk.bytesPerFrame))
    #expect(
      abs(samples.count - expectedFrameCount) < LiveMicrophoneAudioSource.framesPerChunk
    )
    #expect(samples.contains(where: { $0 > 1_000 }))
    #expect(samples.contains(where: { $0 < -1_000 }))
  }

  private func decodeLittleEndianPCM16(_ data: Data) -> [Int16] {
    stride(from: 0, to: data.count, by: LivePCM16AudioChunk.bytesPerFrame).map {
      offset in
      let bits = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
      return Int16(bitPattern: bits)
    }
  }
}

private actor DeferredPermissionAuthorizer {
  private var didReceiveRequest = false
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []
  private var resultContinuation: CheckedContinuation<Bool, Never>?

  func request() async -> Bool {
    didReceiveRequest = true
    let waiters = requestWaiters
    requestWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters {
      waiter.resume()
    }
    return await withCheckedContinuation { continuation in
      resultContinuation = continuation
    }
  }

  func waitUntilRequested() async {
    if didReceiveRequest { return }
    await withCheckedContinuation { continuation in
      requestWaiters.append(continuation)
    }
  }

  func resolve(_ granted: Bool) {
    resultContinuation?.resume(returning: granted)
    resultContinuation = nil
  }
}

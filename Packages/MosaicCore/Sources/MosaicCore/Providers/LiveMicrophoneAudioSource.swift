import AVFoundation
import Foundation

/// Errors raised while Mosaic owns a live microphone capture session.
public enum LiveMicrophoneAudioSourceError: Error, Equatable, Sendable {
  case permissionDenied
  case alreadyRunning
  case microphoneUnavailable
  case invalidInputFormat
  case captureFailed(String)
  case conversionFailed(String)
  case backpressure
  case interrupted
}

extension LiveMicrophoneAudioSourceError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .permissionDenied:
      "Allow microphone access in System Settings before starting live transcription."
    case .alreadyRunning:
      "Microphone capture is already running."
    case .microphoneUnavailable:
      "No microphone input is available."
    case .invalidInputFormat:
      "The microphone returned an unsupported audio format."
    case .captureFailed(let message), .conversionFailed(let message):
      message
    case .backpressure:
      "Live transcription could not keep up with microphone audio."
    case .interrupted:
      "Microphone capture was interrupted."
    }
  }
}

/// Captures the system microphone as bounded, signed PCM16 little-endian, mono, 16 kHz chunks.
///
/// Call `start()` once, consume the returned stream from a task, then call `stop()` when capture is
/// no longer needed. Cancelling the consuming task also tears down the capture session.
public actor LiveMicrophoneAudioSource {
  public typealias AudioStream = AsyncThrowingStream<LivePCM16AudioChunk, Error>

  public static let framesPerChunk = LivePCM16AudioChunk.sampleRate / 10
  public static let maximumBufferedChunkCount = 8

  private var captureSession: LiveMicrophoneCaptureSession?
  private var startIsInProgress = false
  private var cleanupInProgressCount = 0
  private var generation: UInt64 = 0

  public init() {}

  /// Requests microphone authorization without allocating an audio engine. Live transcription uses
  /// this preflight before opening its provider connection so the system permission alert cannot
  /// accidentally cancel a session that is already connecting.
  public static func requestPermission() async throws {
    try await LiveMicrophonePermissionPreflight.request {
      await requestMicrophonePermission()
    }
  }

  public func start() async throws -> AudioStream {
    guard !startIsInProgress, cleanupInProgressCount == 0 else {
      throw LiveMicrophoneAudioSourceError.alreadyRunning
    }

    startIsInProgress = true
    generation &+= 1
    let requestedGeneration = generation
    defer { startIsInProgress = false }

    if let captureSession {
      guard captureSession.isStopped else {
        throw LiveMicrophoneAudioSourceError.alreadyRunning
      }
      await captureSession.stop(deliveringRemainder: false)
      try Task.checkCancellation()
      guard requestedGeneration == generation else {
        throw CancellationError()
      }
      if self.captureSession === captureSession {
        self.captureSession = nil
      }
    }

    try await Self.requestPermission()
    guard requestedGeneration == generation else {
      throw CancellationError()
    }

    #if os(iOS)
      do {
        try Self.activateRecordingAudioSession()
      } catch {
        Self.deactivateRecordingAudioSession()
        throw LiveMicrophoneAudioSourceError.captureFailed(
          "Turing AI could not configure the recording audio session: \(error.localizedDescription)"
        )
      }
    #endif

    let session = LiveMicrophoneCaptureSession(
      deactivatesRecordingAudioSession: Self.deactivatesRecordingAudioSession
    )
    captureSession = session
    do {
      return try session.start()
    } catch {
      captureSession = nil
      await session.stop(deliveringRemainder: false)
      throw error
    }
  }

  /// Stops capture and waits until the input tap and audio engine have been torn down.
  public func stop() async {
    cleanupInProgressCount += 1
    defer { cleanupInProgressCount -= 1 }
    generation &+= 1
    let session = captureSession
    captureSession = nil
    await session?.stop(deliveringRemainder: true)
  }

  private static func requestMicrophonePermission() async -> Bool {
    switch AVAudioApplication.shared.recordPermission {
    case .granted:
      return true
    case .undetermined:
      return await AVAudioApplication.requestRecordPermission()
    case .denied:
      return false
    @unknown default:
      return false
    }
  }

  #if os(iOS)
    private static func activateRecordingAudioSession() throws {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.record, mode: .measurement)
      try audioSession.setPreferredSampleRate(Double(LivePCM16AudioChunk.sampleRate))
      try audioSession.setPreferredIOBufferDuration(0.1)
      try audioSession.setActive(true)
    }

    fileprivate static func deactivateRecordingAudioSession() {
      try? AVAudioSession.sharedInstance().setActive(
        false,
        options: .notifyOthersOnDeactivation
      )
    }
  #else
    private static let deactivatesRecordingAudioSession = false
  #endif
}

enum LiveMicrophonePermissionPreflight {
  static func request(
    using authorizer: @escaping @Sendable () async -> Bool
  ) async throws {
    let permissionGranted = await authorizer()
    try Task.checkCancellation()
    guard permissionGranted else {
      throw LiveMicrophoneAudioSourceError.permissionDenied
    }
  }
}

#if os(iOS)
  extension LiveMicrophoneAudioSource {
    fileprivate static let deactivatesRecordingAudioSession = true
  }
#endif

/// `AVAudioConverter` is stateful. A capture session serializes access to this helper with its
/// state lock so resampling remains continuous across successive hardware buffers.
final class LivePCM16AudioConverter {
  private static let maximumConversionPassCount = 8

  private let inputFormat: AVAudioFormat
  private let outputFormat: AVAudioFormat
  private let converter: AVAudioConverter

  init(inputFormat: AVAudioFormat) throws {
    guard inputFormat.sampleRate.isFinite,
      inputFormat.sampleRate > 0,
      inputFormat.channelCount > 0
    else {
      throw LiveMicrophoneAudioSourceError.invalidInputFormat
    }
    guard
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(LivePCM16AudioChunk.sampleRate),
        channels: AVAudioChannelCount(LivePCM16AudioChunk.channelCount),
        interleaved: false
      ),
      let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else {
      throw LiveMicrophoneAudioSourceError.invalidInputFormat
    }

    self.inputFormat = inputFormat
    self.outputFormat = outputFormat
    self.converter = converter
    converter.downmix = true
    converter.primeMethod = .none
  }

  func convert(_ inputBuffer: AVAudioPCMBuffer) throws -> Data {
    guard inputBuffer.format == inputFormat else {
      throw LiveMicrophoneAudioSourceError.invalidInputFormat
    }
    guard inputBuffer.frameLength > 0 else { return Data() }

    let ratio = outputFormat.sampleRate / inputFormat.sampleRate
    let estimatedFrameCount = ceil(Double(inputBuffer.frameLength) * ratio) + 32
    guard estimatedFrameCount.isFinite,
      estimatedFrameCount > 0,
      estimatedFrameCount <= Double(AVAudioFrameCount.max)
    else {
      throw LiveMicrophoneAudioSourceError.invalidInputFormat
    }
    let outputCapacity = AVAudioFrameCount(estimatedFrameCount)
    guard
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: outputCapacity
      )
    else {
      throw LiveMicrophoneAudioSourceError.conversionFailed(
        "Turing AI could not allocate a microphone conversion buffer."
      )
    }

    let inputProvider = LiveAudioConverterInputProvider(buffer: inputBuffer)
    var convertedData = Data()
    convertedData.reserveCapacity(Int(outputCapacity) * LivePCM16AudioChunk.bytesPerFrame)

    for _ in 0..<Self.maximumConversionPassCount {
      outputBuffer.frameLength = 0
      var conversionError: NSError?
      let status = converter.convert(to: outputBuffer, error: &conversionError) {
        _, inputStatus in
        inputProvider.nextBuffer(status: inputStatus)
      }

      if outputBuffer.frameLength > 0 {
        convertedData.append(try Self.encodeLittleEndianPCM16(outputBuffer))
      }

      switch status {
      case .haveData:
        continue
      case .inputRanDry, .endOfStream:
        return convertedData
      case .error:
        throw LiveMicrophoneAudioSourceError.conversionFailed(
          conversionError?.localizedDescription
            ?? "Turing AI could not convert microphone audio."
        )
      @unknown default:
        throw LiveMicrophoneAudioSourceError.conversionFailed(
          "Turing AI received an unknown audio conversion result."
        )
      }
    }

    throw LiveMicrophoneAudioSourceError.conversionFailed(
      "Microphone conversion did not consume its input within the safety limit."
    )
  }

  func finish() throws -> Data {
    let outputCapacity = AVAudioFrameCount(LivePCM16AudioChunk.maximumFrameCount)
    guard
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: outputCapacity
      )
    else {
      throw LiveMicrophoneAudioSourceError.conversionFailed(
        "Turing AI could not allocate a microphone conversion buffer."
      )
    }

    var convertedData = Data()
    for _ in 0..<Self.maximumConversionPassCount {
      outputBuffer.frameLength = 0
      var conversionError: NSError?
      let status = converter.convert(to: outputBuffer, error: &conversionError) {
        _, inputStatus in
        inputStatus.pointee = .endOfStream
        return nil
      }

      if outputBuffer.frameLength > 0 {
        convertedData.append(try Self.encodeLittleEndianPCM16(outputBuffer))
      }

      switch status {
      case .haveData:
        continue
      case .inputRanDry, .endOfStream:
        return convertedData
      case .error:
        throw LiveMicrophoneAudioSourceError.conversionFailed(
          conversionError?.localizedDescription
            ?? "Turing AI could not finish converting microphone audio."
        )
      @unknown default:
        throw LiveMicrophoneAudioSourceError.conversionFailed(
          "Turing AI received an unknown audio conversion result."
        )
      }
    }

    throw LiveMicrophoneAudioSourceError.conversionFailed(
      "Microphone conversion did not finish within the safety limit."
    )
  }

  private static func encodeLittleEndianPCM16(_ buffer: AVAudioPCMBuffer) throws -> Data {
    guard let channel = buffer.floatChannelData?.pointee else {
      throw LiveMicrophoneAudioSourceError.conversionFailed(
        "Turing AI could not read converted microphone samples."
      )
    }

    let frameCount = Int(buffer.frameLength)
    var data = Data(capacity: frameCount * LivePCM16AudioChunk.bytesPerFrame)
    for index in 0..<frameCount {
      let sample = channel[index]
      let finiteSample = sample.isFinite ? sample : 0
      let clampedSample = min(1, max(-1, finiteSample))
      let scaledSample =
        clampedSample >= 0
        ? (clampedSample * Float(Int16.max)).rounded()
        : (clampedSample * 32_768).rounded()
      let signedSample = Int16(clamping: Int(scaledSample))
      let bits = UInt16(bitPattern: signedSample)
      data.append(UInt8(truncatingIfNeeded: bits))
      data.append(UInt8(truncatingIfNeeded: bits >> 8))
    }
    return data
  }
}

private final class LiveAudioConverterInputProvider: @unchecked Sendable {
  private let lock = NSLock()
  private let buffer: AVAudioPCMBuffer
  private var suppliedBuffer = false

  init(buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }

  func nextBuffer(
    status: UnsafeMutablePointer<AVAudioConverterInputStatus>
  ) -> AVAudioBuffer? {
    lock.withLock {
      guard !suppliedBuffer else {
        status.pointee = .noDataNow
        return nil
      }
      suppliedBuffer = true
      status.pointee = .haveData
      return buffer
    }
  }
}

struct LivePCM16ChunkAccumulator {
  private static let bytesPerChunk =
    LiveMicrophoneAudioSource.framesPerChunk * LivePCM16AudioChunk.bytesPerFrame

  private var pendingData = Data()

  mutating func append(_ data: Data) throws -> [LivePCM16AudioChunk] {
    guard !data.isEmpty else { return [] }
    guard data.count.isMultiple(of: LivePCM16AudioChunk.bytesPerFrame) else {
      throw LiveMicrophoneAudioSourceError.conversionFailed(
        "Converted microphone audio contained an incomplete PCM frame."
      )
    }
    pendingData.append(data)

    var chunks: [LivePCM16AudioChunk] = []
    while pendingData.count >= Self.bytesPerChunk {
      let chunkData = pendingData.prefix(Self.bytesPerChunk)
      chunks.append(try LivePCM16AudioChunk(data: Data(chunkData)))
      pendingData.removeFirst(Self.bytesPerChunk)
    }
    return chunks
  }

  mutating func takeRemainder() -> LivePCM16AudioChunk? {
    defer { pendingData.removeAll(keepingCapacity: false) }
    guard !pendingData.isEmpty else { return nil }
    return try? LivePCM16AudioChunk(data: pendingData)
  }
}

private final class LiveMicrophoneCleanupResources: @unchecked Sendable {
  let engine: AVAudioEngine
  let tapWasInstalled: Bool
  let observerTokens: [NSObjectProtocol]
  let deactivatesRecordingAudioSession: Bool

  init(
    engine: AVAudioEngine,
    tapWasInstalled: Bool,
    observerTokens: [NSObjectProtocol],
    deactivatesRecordingAudioSession: Bool
  ) {
    self.engine = engine
    self.tapWasInstalled = tapWasInstalled
    self.observerTokens = observerTokens
    self.deactivatesRecordingAudioSession = deactivatesRecordingAudioSession
  }

  func perform() {
    engine.stop()
    if tapWasInstalled {
      engine.inputNode.removeTap(onBus: 0)
    }
    for token in observerTokens {
      NotificationCenter.default.removeObserver(token)
    }
    #if os(iOS)
      if deactivatesRecordingAudioSession {
        LiveMicrophoneAudioSource.deactivateRecordingAudioSession()
      }
    #endif
  }
}

private final class LiveMicrophoneCaptureSession: @unchecked Sendable {
  typealias AudioStream = LiveMicrophoneAudioSource.AudioStream
  typealias Continuation = AudioStream.Continuation

  private enum Lifecycle {
    case idle
    case running
    case stopped
  }

  private struct StopPayload {
    let continuation: Continuation?
    let finalChunks: [LivePCM16AudioChunk]
    let conversionError: Error?
    let resources: LiveMicrophoneCleanupResources
  }

  private let engine = AVAudioEngine()
  private let stateLock = NSLock()
  private let cleanupQueue = DispatchQueue(
    label: "com.omergirgin.mosaic.live-microphone-cleanup",
    qos: .userInitiated
  )
  private let deactivatesRecordingAudioSession: Bool

  private var lifecycle = Lifecycle.idle
  private var converter: LivePCM16AudioConverter?
  private var accumulator = LivePCM16ChunkAccumulator()
  private var continuation: Continuation?
  private var tapWasInstalled = false
  private var observerTokens: [NSObjectProtocol] = []

  init(deactivatesRecordingAudioSession: Bool) {
    self.deactivatesRecordingAudioSession = deactivatesRecordingAudioSession
  }

  deinit {
    requestStop(error: nil, deliveringRemainder: false)
  }

  var isStopped: Bool {
    stateLock.withLock { lifecycle == .stopped }
  }

  func start() throws -> AudioStream {
    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw LiveMicrophoneAudioSourceError.microphoneUnavailable
    }
    let converter = try LivePCM16AudioConverter(inputFormat: inputFormat)
    let streamPair = AudioStream.makeStream(
      bufferingPolicy: .bufferingOldest(
        LiveMicrophoneAudioSource.maximumBufferedChunkCount
      )
    )
    streamPair.continuation.onTermination = { [weak self] _ in
      self?.requestStop(error: nil, deliveringRemainder: false)
    }

    stateLock.withLock {
      lifecycle = .running
      self.converter = converter
      continuation = streamPair.continuation
    }

    inputNode.installTap(
      onBus: 0,
      bufferSize: Self.hardwareBufferSize(for: inputFormat),
      format: inputFormat
    ) { [weak self] buffer, _ in
      self?.consume(buffer)
    }
    stateLock.withLock { tapWasInstalled = true }

    do {
      engine.prepare()
      try engine.start()
      installInterruptionObservers()
      return streamPair.stream
    } catch {
      let sourceError = LiveMicrophoneAudioSourceError.captureFailed(
        "Turing AI could not start microphone capture: \(error.localizedDescription)"
      )
      requestStop(error: sourceError, deliveringRemainder: false)
      throw sourceError
    }
  }

  func stop(deliveringRemainder: Bool) async {
    requestStop(error: nil, deliveringRemainder: deliveringRemainder)
    await withCheckedContinuation { continuation in
      cleanupQueue.async {
        continuation.resume()
      }
    }
  }

  private static func hardwareBufferSize(for inputFormat: AVAudioFormat) -> AVAudioFrameCount {
    let desiredFrameCount = inputFormat.sampleRate / 10
    return AVAudioFrameCount(max(1, min(Double(AVAudioFrameCount.max), desiredFrameCount)))
  }

  private func installInterruptionObservers() {
    let engineToken = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self] _ in
      self?.requestStop(
        error: LiveMicrophoneAudioSourceError.interrupted,
        deliveringRemainder: false
      )
    }

    var tokens: [NSObjectProtocol] = [engineToken]
    #if os(iOS)
      let audioSessionToken = NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        queue: nil
      ) { [weak self] notification in
        guard
          let rawValue = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?
            .uintValue,
          AVAudioSession.InterruptionType(rawValue: rawValue) == .began
        else { return }
        self?.requestStop(
          error: LiveMicrophoneAudioSourceError.interrupted,
          deliveringRemainder: false
        )
      }
      tokens.append(audioSessionToken)
    #endif

    let shouldKeepTokens = stateLock.withLock {
      guard lifecycle == .running else { return false }
      observerTokens.append(contentsOf: tokens)
      return true
    }
    if !shouldKeepTokens {
      for token in tokens {
        NotificationCenter.default.removeObserver(token)
      }
    }
  }

  private func consume(_ inputBuffer: AVAudioPCMBuffer) {
    let conversionResult: Result<(Continuation, [LivePCM16AudioChunk]), Error>? =
      stateLock.withLock {
        guard lifecycle == .running, let converter, let continuation else {
          return nil
        }
        do {
          let data = try converter.convert(inputBuffer)
          return .success((continuation, try accumulator.append(data)))
        } catch {
          return .failure(error)
        }
      }

    guard let conversionResult else { return }

    switch conversionResult {
    case .failure(let error):
      let sourceError =
        error as? LiveMicrophoneAudioSourceError
        ?? LiveMicrophoneAudioSourceError.conversionFailed(error.localizedDescription)
      requestStop(error: sourceError, deliveringRemainder: false)
    case .success((let continuation, let chunks)):
      for chunk in chunks {
        switch continuation.yield(chunk) {
        case .enqueued:
          continue
        case .dropped:
          requestStop(
            error: LiveMicrophoneAudioSourceError.backpressure,
            deliveringRemainder: false
          )
          return
        case .terminated:
          requestStop(error: nil, deliveringRemainder: false)
          return
        @unknown default:
          requestStop(
            error: LiveMicrophoneAudioSourceError.backpressure,
            deliveringRemainder: false
          )
          return
        }
      }
    }
  }

  private func requestStop(error: Error?, deliveringRemainder: Bool) {
    let payload: StopPayload? = stateLock.withLock {
      guard lifecycle != .stopped else { return nil }
      lifecycle = .stopped

      var finalChunks: [LivePCM16AudioChunk] = []
      var conversionError: Error?
      if deliveringRemainder, error == nil, let converter {
        do {
          finalChunks.append(contentsOf: try accumulator.append(converter.finish()))
          if let remainder = accumulator.takeRemainder() {
            finalChunks.append(remainder)
          }
        } catch {
          conversionError = error
        }
      }
      let payload = StopPayload(
        continuation: continuation,
        finalChunks: finalChunks,
        conversionError: conversionError,
        resources: LiveMicrophoneCleanupResources(
          engine: engine,
          tapWasInstalled: tapWasInstalled,
          observerTokens: observerTokens,
          deactivatesRecordingAudioSession: deactivatesRecordingAudioSession
        )
      )
      converter = nil
      continuation = nil
      observerTokens.removeAll(keepingCapacity: false)
      tapWasInstalled = false
      return payload
    }
    guard let payload else { return }

    var terminalError = error ?? payload.conversionError
    finalChunkLoop: for chunk in payload.finalChunks {
      guard terminalError == nil else { break }
      switch payload.continuation?.yield(chunk) {
      case .enqueued:
        continue
      case .dropped:
        terminalError = LiveMicrophoneAudioSourceError.backpressure
      case .terminated, .none:
        break finalChunkLoop
      @unknown default:
        terminalError = LiveMicrophoneAudioSourceError.backpressure
      }
    }
    if let terminalError {
      payload.continuation?.finish(throwing: terminalError)
    } else {
      payload.continuation?.finish()
    }

    cleanupQueue.async {
      payload.resources.perform()
    }
  }

}

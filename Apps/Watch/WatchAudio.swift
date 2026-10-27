@preconcurrency import AVFoundation
import Foundation
import TuringVoice

private final class PCMConversion: @unchecked Sendable {
  let converter: AVAudioConverter
  private var suppliedInput = false
  let format: AVAudioFormat
  init(input: AVAudioFormat) throws {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
      let converter = AVAudioConverter(from: input, to: format)
    else { throw VoiceError.audioUnavailable }
    self.format = format
    self.converter = converter
  }
  func convert(_ input: AVAudioPCMBuffer) throws -> Data {
    let capacity =
      AVAudioFrameCount(ceil(Double(input.frameLength) * 24000 / input.format.sampleRate)) + 64
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      throw VoiceError.audioUnavailable
    }
    suppliedInput = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, state in
      if self.suppliedInput {
        state.pointee = .noDataNow
        return nil
      }
      self.suppliedInput = true
      state.pointee = .haveData
      return input
    }
    guard status != .error, error == nil, let samples = output.int16ChannelData else {
      throw VoiceError.audioUnavailable
    }
    return Data(bytes: samples[0], count: Int(output.frameLength) * 2)
  }
}

@MainActor
final class WatchAudio: NSObject, AVAudioPlayerDelegate, VoiceAudioDevice {
  private var activationTask: Task<Void, Error>?
  private var audioGeneration = UUID()
  private var tapInstalled = false
  private var engine: AVAudioEngine?
  private var node: AVAudioPlayerNode?
  private var input: AsyncThrowingStream<Data, Error>.Continuation?
  private var recorder: AVAudioRecorder?
  private var recordingURL: URL?
  private var filePlayer: AVAudioPlayer?
  private var playbackCompletion: (() -> Void)?
  private var playbackGeneration = UUID()
  private var playbackQueue = VoicePlaybackQueue()
  var onPlaybackDrained: (@MainActor () -> Void)?
  private let recordingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "TuringVoiceRecordings", isDirectory: true)
  private static var cleanedRecordings = false
  override init() {
    super.init()
    // Remove only this feature's abandoned recordings after an interrupted process.
    if !Self.cleanedRecordings {
      try? FileManager.default.removeItem(at: recordingsDirectory)
      Self.cleanedRecordings = true
    }
    try? FileManager.default.createDirectory(
      at: recordingsDirectory, withIntermediateDirectories: true)
  }
  var queuedMilliseconds: Int { max(0, playbackQueue.tailFrame - renderedFrames) / 24 }
  var nextPlaybackMilliseconds: Int { max(playbackQueue.tailFrame, renderedFrames) / 24 }
  private var renderedFrames: Int {
    guard let node, let time = node.lastRenderTime,
      let rendered = node.playerTime(forNodeTime: time)
    else { return 0 }
    return max(0, Int(Double(rendered.sampleTime) / rendered.sampleRate * 24000))
  }
  var playedMilliseconds: Int { renderedFrames / 24 }
  private func activate(record: Bool) async throws {
    let previous = activationTask
    let token = audioGeneration
    // Serialize activation completions: a cancelled permission/routing request must never
    // reactivate the microphone after Stop, or deactivate a newer session.
    let activation = Task { @MainActor in
      _ = try? await previous?.value
      try Task.checkCancellation()
      guard token == audioGeneration else { throw CancellationError() }
      if record {
        guard await AVAudioApplication.requestRecordPermission() else {
          throw VoiceError.audioUnavailable
        }
      }
      try Task.checkCancellation()
      guard token == audioGeneration else { throw CancellationError() }
      let session = AVAudioSession.sharedInstance()
      do {
        try session.setCategory(
          record ? .playAndRecord : .playback, mode: record ? .voiceChat : .default)
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          session.activate(options: []) { @Sendable active, error in
            if active {
              continuation.resume()
            } else {
              continuation.resume(throwing: error ?? VoiceError.audioUnavailable)
            }
          }
        }
        try Task.checkCancellation()
        guard token == audioGeneration else { throw CancellationError() }
      } catch {
        try? session.setActive(false)
        throw error
      }
    }
    activationTask = activation
    try await withTaskCancellationHandler {
      try await activation.value
      try Task.checkCancellation()
    } onCancel: {
      activation.cancel()
    }
  }
  func live() async throws -> AsyncThrowingStream<Data, Error> {
    stop()
    try await activate(record: true)
    let engine = AVAudioEngine()
    self.engine = engine
    let node = AVAudioPlayerNode()
    self.node = node
    engine.attach(node)
    guard let output = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1) else {
      throw VoiceError.audioUnavailable
    }
    engine.connect(node, to: engine.mainMixerNode, format: output)
    try engine.inputNode.setVoiceProcessingEnabled(true)
    let format = engine.inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.audioUnavailable }
    let conversion = try PCMConversion(input: format)
    let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(12))
    input = pair.continuation
    engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
      do {
        let bytes = try conversion.convert(buffer)
        if !bytes.isEmpty, case .dropped = pair.continuation.yield(bytes) {
          pair.continuation.finish(
            throwing: VoiceError.message(
              "The connection cannot keep up with live audio. Try again on a stronger network."))
        }
      } catch { pair.continuation.finish(throwing: VoiceError.audioUnavailable) }
    }
    tapInstalled = true
    engine.prepare()
    try engine.start()
    node.play()
    return pair.stream
  }
  func playPCM(_ data: Data) throws {
    guard let node, let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
      data.count.isMultiple(of: 2), data.count <= 2_097_152
    else { throw VoiceError.invalidResponse }
    let frames = data.count / 2
    guard frames > 0 else { return }
    guard
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
      let samples = buffer.floatChannelData
    else { throw VoiceError.responseTooLarge }
    buffer.frameLength = AVAudioFrameCount(frames)
    data.withUnsafeBytes { raw in
      for index in 0..<frames {
        let value = raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
        samples[0][index] = Float(Int16(littleEndian: value)) / 32768
      }
    }
    try playbackQueue.schedule(frames: frames, renderedFrames: renderedFrames)
    let generation = playbackGeneration
    node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
      @Sendable [weak self] _ in
      Task { @MainActor in
        guard let self, self.playbackGeneration == generation else { return }
        self.playbackQueue.completed(frames: frames)
        if self.playbackQueue.pendingFrames == 0 { self.onPlaybackDrained?() }
      }
    }
    if !node.isPlaying { node.play() }
  }
  func clearPlayback() {
    playbackGeneration = UUID()
    playbackQueue.reset()
    node?.stop()
    if engine?.isRunning == true { node?.play() }
  }
  func record() async throws {
    stop()
    try await activate(record: true)
    let url = recordingsDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(
      "m4a")
    recordingURL = url
    let recorder = try AVAudioRecorder(
      url: url,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000,
      ])
    self.recorder = recorder
    guard recorder.record(forDuration: 60) else { throw VoiceError.audioUnavailable }
  }
  func finishRecording() throws -> Data {
    recorder?.stop()
    recorder = nil
    guard let url = recordingURL else { throw VoiceError.audioUnavailable }
    defer {
      try? FileManager.default.removeItem(at: url)
      recordingURL = nil
    }
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    guard let count = values.fileSize, count > 0, count <= 8_388_608 else {
      throw VoiceError.responseTooLarge
    }
    return try Data(contentsOf: url)
  }
  func playFile(_ data: Data, completion: @escaping () -> Void) async throws {
    try await activate(record: false)
    let player = try AVAudioPlayer(data: data)
    filePlayer = player
    playbackCompletion = completion
    player.delegate = self
    guard player.play() else { throw VoiceError.audioUnavailable }
  }
  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    let identity = ObjectIdentifier(player)
    Task { @MainActor [weak self] in
      guard let self, let current = self.filePlayer, ObjectIdentifier(current) == identity else {
        return
      }
      let completion = self.playbackCompletion
      self.playbackCompletion = nil
      completion?()
    }
  }
  func stop() {
    audioGeneration = UUID()
    activationTask?.cancel()
    input?.finish()
    input = nil
    if let engine {
      if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
      engine.stop()
    }
    tapInstalled = false
    engine = nil
    node = nil
    playbackQueue.reset()
    playbackGeneration = UUID()
    recorder?.stop()
    recorder = nil
    if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
    recordingURL = nil
    filePlayer?.stop()
    filePlayer = nil
    playbackCompletion = nil
    try? AVAudioSession.sharedInstance().setActive(false)
  }
}

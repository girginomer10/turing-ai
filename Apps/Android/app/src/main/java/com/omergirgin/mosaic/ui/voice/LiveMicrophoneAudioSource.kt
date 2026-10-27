package com.omergirgin.mosaic.ui.voice

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.os.Build
import android.os.Process
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import com.omergirgin.mosaic.core.net.live.LivePcm16Chunk
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel

/** Failures raised while Turing AI owns a live microphone capture. */
class LiveMicrophoneException(val kind: Kind, message: String) : Exception(message) {
  enum class Kind { PERMISSION_DENIED, ALREADY_RUNNING, MICROPHONE_UNAVAILABLE, CAPTURE_FAILED, BACKPRESSURE, INTERRUPTED }

  companion object {
    fun of(kind: Kind) = LiveMicrophoneException(
      kind,
      when (kind) {
        Kind.PERMISSION_DENIED -> "Allow microphone access for Turing AI before starting live transcription."
        Kind.ALREADY_RUNNING -> "Microphone capture is already running."
        Kind.MICROPHONE_UNAVAILABLE -> "No microphone input is available."
        Kind.CAPTURE_FAILED -> "Turing AI could not record from the microphone."
        Kind.BACKPRESSURE -> "Live transcription could not keep up with microphone audio."
        Kind.INTERRUPTED -> "Microphone capture was interrupted by another app or a call."
      },
    )
  }
}

/**
 * Captures the microphone (VOICE_RECOGNITION source) as bounded, signed PCM16 little-endian,
 * mono, 16 kHz chunks of 100 ms. Hardware formats that are not 16 kHz mono are downmixed and
 * resampled statefully. At most [MAXIMUM_BUFFERED_CHUNKS] chunks wait for the consumer; a slower
 * consumer fails the stream with BACKPRESSURE instead of buffering without bound.
 *
 * [start] once, consume the returned channel, then [stop] (delivers the remaining partial chunk)
 * or [cancel]. Audio never leaves this class except through the channel and is never logged.
 */
class LiveMicrophoneAudioSource(context: Context) {
  private val appContext = context.applicationContext
  private val stopRequested = AtomicBoolean(false)
  private val deliverRemainder = AtomicBoolean(true)
  @Volatile private var stopError: LiveMicrophoneException? = null
  private var started = false

  /** Must be called off the main thread (opening the input can take tens of milliseconds). */
  @SuppressLint("MissingPermission") // Checked immediately before opening the input.
  fun start(): ReceiveChannel<LivePcm16Chunk> {
    check(!started) { "A microphone source is single-use." }
    started = true
    if (ContextCompat.checkSelfPermission(appContext, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
      throw LiveMicrophoneException.of(LiveMicrophoneException.Kind.PERMISSION_DENIED)
    }
    if (!captureInProgress.compareAndSet(false, true)) {
      throw LiveMicrophoneException.of(LiveMicrophoneException.Kind.ALREADY_RUNNING)
    }
    var record: AudioRecord? = null
    try {
      val (opened, format) = openInput()
      record = opened
      try {
        opened.startRecording()
      } catch (error: IllegalStateException) {
        throw LiveMicrophoneException.of(LiveMicrophoneException.Kind.CAPTURE_FAILED)
      }
      if (opened.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
        throw LiveMicrophoneException.of(LiveMicrophoneException.Kind.MICROPHONE_UNAVAILABLE)
      }
      val channel = Channel<LivePcm16Chunk>(MAXIMUM_BUFFERED_CHUNKS)
      val silencedWatcher = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        SilencedWatcher(appContext, opened.audioSessionId) { requestStop(LiveMicrophoneException.of(LiveMicrophoneException.Kind.INTERRUPTED)) }
          .also { it.register() }
      } else {
        null
      }
      Thread(
        { captureLoop(opened, format, channel, silencedWatcher) },
        "turing-live-microphone",
      ).apply {
        isDaemon = true
        start()
      }
      return channel
    } catch (error: Throwable) {
      record?.let { runCatching { it.stop() }; it.release() }
      captureInProgress.set(false)
      throw when (error) {
        is LiveMicrophoneException -> error
        is SecurityException -> LiveMicrophoneException.of(LiveMicrophoneException.Kind.PERMISSION_DENIED)
        else -> LiveMicrophoneException.of(LiveMicrophoneException.Kind.CAPTURE_FAILED)
      }
    }
  }

  /** Graceful: stops reading within one 100 ms read, delivers the remainder, then closes the stream. */
  fun stop() = requestStop(null)

  /** Immediate: no remainder is delivered. */
  fun cancel() {
    deliverRemainder.set(false)
    requestStop(null)
  }

  private fun requestStop(error: LiveMicrophoneException?) {
    if (error != null) {
      stopError = error
      deliverRemainder.set(false)
    }
    stopRequested.set(true)
  }

  @SuppressLint("MissingPermission")
  private fun openInput(): Pair<AudioRecord, CaptureFormat> {
    for (format in CANDIDATE_FORMATS) {
      val channelMask = if (format.channels == 1) AudioFormat.CHANNEL_IN_MONO else AudioFormat.CHANNEL_IN_STEREO
      val minimumBytes = AudioRecord.getMinBufferSize(format.sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT)
      if (minimumBytes <= 0) continue
      // Room for several 100 ms reads so a briefly delayed reader thread does not drop audio.
      val bufferBytes = max(minimumBytes, format.samplesPerRead * 2 * 4)
      val record = try {
        AudioRecord(
          MediaRecorder.AudioSource.VOICE_RECOGNITION,
          format.sampleRate,
          channelMask,
          AudioFormat.ENCODING_PCM_16BIT,
          bufferBytes,
        )
      } catch (error: IllegalArgumentException) {
        continue
      }
      if (record.state == AudioRecord.STATE_INITIALIZED) return record to format
      record.release()
    }
    throw LiveMicrophoneException.of(LiveMicrophoneException.Kind.MICROPHONE_UNAVAILABLE)
  }

  private fun captureLoop(
    record: AudioRecord,
    format: CaptureFormat,
    channel: Channel<LivePcm16Chunk>,
    silencedWatcher: SilencedWatcher?,
  ) {
    Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
    val converter = Pcm16MonoConverter(format.sampleRate, format.channels)
    val accumulator = Pcm16ChunkAccumulator()
    val samples = ShortArray(format.samplesPerRead)
    var failure: LiveMicrophoneException? = null
    var consumerGone = false

    fun deliver(chunks: List<LivePcm16Chunk>): Boolean {
      for (chunk in chunks) {
        val result = channel.trySend(chunk)
        if (result.isSuccess) continue
        if (result.isClosed) consumerGone = true else failure = LiveMicrophoneException.of(LiveMicrophoneException.Kind.BACKPRESSURE)
        return false
      }
      return true
    }

    try {
      while (!stopRequested.get()) {
        val read = record.read(samples, 0, samples.size, AudioRecord.READ_BLOCKING)
        if (read < 0) {
          failure = LiveMicrophoneException.of(LiveMicrophoneException.Kind.CAPTURE_FAILED)
          break
        }
        if (read == 0) {
          if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) break
          continue
        }
        if (!deliver(accumulator.append(converter.convert(samples, read)))) break
      }
      if (failure == null && !consumerGone && stopError == null && deliverRemainder.get()) {
        if (deliver(accumulator.append(converter.finish()))) {
          accumulator.takeRemainder()?.let { deliver(listOf(it)) }
        }
      }
    } catch (error: Throwable) {
      failure = LiveMicrophoneException.of(LiveMicrophoneException.Kind.CAPTURE_FAILED)
    } finally {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) silencedWatcher?.unregister()
      runCatching { record.stop() }
      record.release()
      captureInProgress.set(false)
      channel.close(stopError ?: failure)
    }
  }

  private class CaptureFormat(val sampleRate: Int, val channels: Int) {
    val samplesPerRead: Int get() = sampleRate / 10 * channels
  }

  /** Stops capture when the system silences this client (a call, or another app took the mic). */
  @RequiresApi(Build.VERSION_CODES.Q)
  private class SilencedWatcher(context: Context, private val sessionId: Int, private val onSilenced: () -> Unit) {
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val callback = object : AudioManager.AudioRecordingCallback() {
      override fun onRecordingConfigChanged(configs: List<AudioRecordingConfiguration>) {
        if (configs.any { it.clientAudioSessionId == sessionId && it.isClientSilenced }) onSilenced()
      }
    }

    fun register() {
      audioManager?.registerAudioRecordingCallback(callback, null)
    }

    fun unregister() {
      runCatching { audioManager?.unregisterAudioRecordingCallback(callback) }
    }
  }

  companion object {
    /** Eight 100 ms chunks (iOS `maximumBufferedChunkCount`). */
    const val MAXIMUM_BUFFERED_CHUNKS = 8

    /** One capture per process, like iOS's process-wide microphone operation. */
    private val captureInProgress = AtomicBoolean(false)

    /** Native 16 kHz mono first; 44.1 kHz mono is the only rate every device must support. */
    private val CANDIDATE_FORMATS = listOf(
      CaptureFormat(16_000, 1),
      CaptureFormat(48_000, 1),
      CaptureFormat(44_100, 1),
      CaptureFormat(48_000, 2),
      CaptureFormat(44_100, 2),
    )
  }
}

/** Downmixes interleaved PCM16 to mono and resamples to 16 kHz, returning little-endian PCM16 bytes. */
internal class Pcm16MonoConverter(inputRate: Int, private val channels: Int) {
  private val resampler = MonoResampler(inputRate, LivePcm16Chunk.SAMPLE_RATE)
  private var mono = FloatArray(0)

  fun convert(samples: ShortArray, count: Int): ByteArray {
    val frames = count / channels
    if (mono.size < frames) mono = FloatArray(frames)
    for (frame in 0 until frames) {
      var sum = 0f
      for (channel in 0 until channels) sum += samples[frame * channels + channel]
      mono[frame] = sum / channels / 32_768f
    }
    return encode(resampler.process(mono, frames))
  }

  fun finish(): ByteArray = encode(resampler.flush())

  private fun encode(output: FloatArray): ByteArray {
    val bytes = ByteArray(output.size * 2)
    for (index in output.indices) {
      val sample = output[index].let { if (it.isFinite()) it.coerceIn(-1f, 1f) else 0f }
      val scaled = if (sample >= 0) (sample * 32_767f).roundToInt() else (sample * 32_768f).roundToInt()
      val value = scaled.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
      bytes[index * 2] = (value and 0xFF).toByte()
      bytes[index * 2 + 1] = ((value shr 8) and 0xFF).toByte()
    }
    return bytes
  }
}

/**
 * Stateful band-limited resampler (Blackman-windowed sinc, 256 phases). Continuity across reads
 * is kept by carrying the filter history and the fractional read position between calls.
 */
internal class MonoResampler(inputRate: Int, outputRate: Int) {
  private val passthrough = inputRate == outputRate
  private val step = inputRate.toDouble() / outputRate
  private val halfTaps: Int
  private val kernels: Array<FloatArray>
  private var buffer = FloatArray(0)
  private var count = 0
  private var position = 0.0

  init {
    if (passthrough) {
      halfTaps = 0
      kernels = emptyArray()
    } else {
      // Cutoff just below the lower Nyquist frequency, in cycles per input sample.
      val cutoff = 0.5 / max(step, 1.0) * 0.92
      halfTaps = ceil(ZERO_CROSSINGS / (2 * cutoff)).toInt()
      kernels = Array(PHASES + 1) { phase ->
        val fraction = phase.toDouble() / PHASES
        val taps = DoubleArray(2 * halfTaps) { tap ->
          val distance = (tap - halfTaps + 1) - fraction
          val x = 2 * cutoff * distance
          val sinc = if (abs(x) < 1e-9) 1.0 else sin(PI * x) / (PI * x)
          val w = distance / halfTaps
          val window = 0.42 + 0.5 * cos(PI * w) + 0.08 * cos(2 * PI * w)
          2 * cutoff * sinc * window
        }
        val gain = taps.sum()
        FloatArray(taps.size) { (taps[it] / gain).toFloat() }
      }
      // Zero history so the first input sample can be the first output's center.
      buffer = FloatArray(4_096)
      count = halfTaps - 1
      position = (halfTaps - 1).toDouble()
    }
  }

  fun process(input: FloatArray, length: Int): FloatArray {
    if (passthrough) return input.copyOf(length)
    append(input, length)
    return drain()
  }

  /** Emits the tail held back for filter look-ahead. */
  fun flush(): FloatArray {
    if (passthrough) return FloatArray(0)
    append(FloatArray(halfTaps), halfTaps)
    return drain()
  }

  private fun append(input: FloatArray, length: Int) {
    if (count + length > buffer.size) buffer = buffer.copyOf(max(buffer.size * 2, count + length))
    System.arraycopy(input, 0, buffer, count, length)
    count += length
  }

  private fun drain(): FloatArray {
    val capacity = max(0, ((count - halfTaps - position) / step).toInt() + 2)
    val output = FloatArray(capacity)
    var produced = 0
    while (produced < capacity) {
      val center = floor(position).toInt()
      if (center + halfTaps >= count) break
      val kernel = kernels[((position - center) * PHASES).roundToInt()]
      val start = center - halfTaps + 1
      var sum = 0f
      for (tap in kernel.indices) sum += buffer[start + tap] * kernel[tap]
      output[produced++] = sum
      position += step
    }
    // Drop samples no future output can reach.
    val keepFrom = (floor(position).toInt() - halfTaps + 1).coerceIn(0, count)
    if (keepFrom > 0) {
      System.arraycopy(buffer, keepFrom, buffer, 0, count - keepFrom)
      count -= keepFrom
      position -= keepFrom
    }
    return if (produced == output.size) output else output.copyOf(produced)
  }

  private companion object {
    const val PHASES = 256
    const val ZERO_CROSSINGS = 8.0
  }
}

/** Splits converted PCM16 into exact 100 ms chunks, keeping a partial chunk for the next read. */
internal class Pcm16ChunkAccumulator {
  private val bytesPerChunk = LivePcm16Chunk.FRAMES_PER_CHUNK * LivePcm16Chunk.BYTES_PER_FRAME
  private var pending = ByteArray(bytesPerChunk * 2)
  private var pendingCount = 0

  fun append(data: ByteArray): List<LivePcm16Chunk> {
    if (data.isEmpty()) return emptyList()
    if (pendingCount + data.size > pending.size) pending = pending.copyOf(max(pending.size * 2, pendingCount + data.size))
    System.arraycopy(data, 0, pending, pendingCount, data.size)
    pendingCount += data.size
    val chunks = ArrayList<LivePcm16Chunk>(pendingCount / bytesPerChunk)
    var offset = 0
    while (pendingCount - offset >= bytesPerChunk) {
      chunks += LivePcm16Chunk(pending.copyOfRange(offset, offset + bytesPerChunk))
      offset += bytesPerChunk
    }
    if (offset > 0) {
      System.arraycopy(pending, offset, pending, 0, pendingCount - offset)
      pendingCount -= offset
    }
    return chunks
  }

  fun takeRemainder(): LivePcm16Chunk? {
    val usable = pendingCount - pendingCount % LivePcm16Chunk.BYTES_PER_FRAME
    val remainder = if (usable > 0) LivePcm16Chunk(pending.copyOf(usable)) else null
    pendingCount = 0
    return remainder
  }
}

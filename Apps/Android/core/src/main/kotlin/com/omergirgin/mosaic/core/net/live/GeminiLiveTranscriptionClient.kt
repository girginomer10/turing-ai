package com.omergirgin.mosaic.core.net.live

import com.omergirgin.mosaic.core.net.ProviderErrorSanitizer
import com.omergirgin.mosaic.core.net.ProviderHttp
import com.omergirgin.mosaic.core.net.ProviderTimeoutPolicy
import java.util.concurrent.TimeUnit
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString

/** Opens a WebSocket; injectable so the protocol can be exercised against a local mock server. */
internal fun interface LiveWebSocketConnector {
  fun open(request: Request, listener: WebSocketListener): WebSocket
}

/**
 * Shares the provider transport's pool and its no-redirect policy: a 3xx upgrade response fails
 * the handshake instead of replaying the key header elsewhere. Read/call timeouts cover only the
 * handshake (OkHttp clears them once the socket is upgraded); no cookies or cache are installed.
 */
internal object OkHttpLiveWebSocketConnector : LiveWebSocketConnector {
  private val client: OkHttpClient by lazy {
    ProviderHttp.client(ProviderTimeoutPolicy.MODEL_CATALOG)
      .newBuilder()
      .followRedirects(false)
      .followSslRedirects(false)
      .connectTimeout(30, TimeUnit.SECONDS)
      .readTimeout(30, TimeUnit.SECONDS)
      .writeTimeout(30, TimeUnit.SECONDS)
      .callTimeout(30, TimeUnit.SECONDS)
      .webSocketCloseTimeout(2, TimeUnit.SECONDS)
      .build()
  }

  override fun open(request: Request, listener: WebSocketListener): WebSocket = client.newWebSocket(request, listener)
}

/**
 * Gemini's dedicated speech-to-text WebSocket transport. It is separate from the chat provider
 * clients, so the resulting text can be sent to any configured chat provider.
 */
class GeminiLiveTranscriptionClient internal constructor(
  private val connector: LiveWebSocketConnector,
  private val endpoint: String,
  sessionDurationMillis: Long,
  finalizationTimeoutMillis: Long,
  setupTimeoutMillis: Long,
) {
  constructor() : this(
    connector = OkHttpLiveWebSocketConnector,
    endpoint = GeminiLiveWireProtocol.ENDPOINT,
    sessionDurationMillis = GeminiLiveWireProtocol.MAXIMUM_SESSION_MILLIS,
    finalizationTimeoutMillis = DEFAULT_FINALIZATION_TIMEOUT_MILLIS,
    setupTimeoutMillis = DEFAULT_SETUP_TIMEOUT_MILLIS,
  )

  private val sessionDurationMillis = sessionDurationMillis.coerceIn(1, GeminiLiveWireProtocol.MAXIMUM_SESSION_MILLIS)
  private val finalizationTimeoutMillis = finalizationTimeoutMillis.coerceIn(1, 30_000)
  private val setupTimeoutMillis = setupTimeoutMillis.coerceIn(1, 60_000)

  /**
   * Opens the fixed endpoint and sends the bounded setup. Returns immediately; wait for
   * [LiveTranscriptionEvent.SetupComplete] on [LiveTranscriptionSession.events] before sending audio.
   * Every failure is sanitized so the key never appears in a message.
   */
  fun connect(
    apiKey: String,
    configuration: LiveTranscriptionConfiguration = LiveTranscriptionConfiguration(),
  ): LiveTranscriptionSession {
    try {
      val request = GeminiLiveWireProtocol.webSocketRequest(apiKey, endpoint)
      val setupMessage = GeminiLiveWireProtocol.setupMessage(configuration)
      val session = GeminiLiveSession(
        apiKey = apiKey,
        durationMillis = sessionDurationMillis,
        finalizationTimeoutMillis = finalizationTimeoutMillis,
        setupTimeoutMillis = setupTimeoutMillis,
      )
      session.start(connector, request, setupMessage)
      return session
    } catch (error: Throwable) {
      throw sanitized(error, apiKey)
    }
  }

  companion object {
    const val DEFAULT_FINALIZATION_TIMEOUT_MILLIS = 12_000L
    const val DEFAULT_SETUP_TIMEOUT_MILLIS = 30_000L

    internal fun sanitized(error: Throwable, apiKey: String?): Throwable = when (error) {
      is CancellationException -> error
      is LiveTranscriptionException -> when (error.kind) {
        LiveTranscriptionException.Kind.INVALID_CONFIGURATION,
        LiveTranscriptionException.Kind.INVALID_AUDIO_CHUNK,
        LiveTranscriptionException.Kind.PROVIDER,
        LiveTranscriptionException.Kind.TRANSPORT ->
          LiveTranscriptionException(error.kind, LiveTranscriptionRedactor.sanitize(error.message.orEmpty(), apiKey))
        else -> error
      }
      // Transport failures reuse the provider mapper (timeouts, DNS, TLS, refused) without causes.
      else -> LiveTranscriptionException.transport(
        LiveTranscriptionRedactor.sanitize(ProviderErrorSanitizer.describe(error, apiKey), apiKey)
      )
    }
  }
}

private object CloseCode {
  const val NORMAL = 1000
  const val GOING_AWAY = 1001
  const val POLICY_VIOLATION = 1008
  const val MESSAGE_TOO_BIG = 1009
}

/** Bytes of queued outbound frames tolerated before failing with BACKPRESSURE (~12 s of audio). */
private const val MAXIMUM_OUTBOUND_QUEUE_BYTES = 512L * 1_024
private const val CLOSE_REASON = "Turing AI live transcription ended"
private const val ERROR_BODY_LIMIT = 16L * 1_024

/**
 * One Gemini Live session. OkHttp delivers listener callbacks on its reader thread; every state
 * change happens under [lock], and the bounded event channel is the only hand-off to the caller.
 */
private class GeminiLiveSession(
  private val apiKey: String,
  private val durationMillis: Long,
  private val finalizationTimeoutMillis: Long,
  private val setupTimeoutMillis: Long,
) : LiveTranscriptionSession {
  private enum class State { INITIALIZED, AWAITING_SETUP, READY, TERMINAL }

  private class FinalizationWaiter(
    val afterFinalTranscript: Long,
    val afterTurnCompletion: Long,
    val result: CompletableDeferred<LiveFinalizationResult> = CompletableDeferred(),
  ) {
    var timeout: Job? = null
  }

  private val lock = Any()
  private val channel = Channel<LiveTranscriptionEvent>(GeminiLiveWireProtocol.STREAM_BUFFER_LIMIT)
  private val timers = CoroutineScope(SupervisorJob() + Dispatchers.Default)

  private var state = State.INITIALIZED
  private var socket: WebSocket? = null
  private var audioEnded = false
  private var didReceiveGoAway = false
  private var transcriptByteCount = 0L
  private var finalTranscriptSequence = 0L
  private var turnCompletionSequence = 0L
  private var hasUnfinalizedInterim = false
  private var setupTimeout: Job? = null
  private val waiters = ArrayList<FinalizationWaiter>(1)

  override val events: ReceiveChannel<LiveTranscriptionEvent> get() = channel

  init {
    // A consumer that cancels the stream ends the session (iOS onTermination).
    channel.invokeOnClose { terminate(endReason = LiveTranscriptionEndReason.CANCELLED, closeCode = CloseCode.NORMAL) }
  }

  private val listener = object : WebSocketListener() {
    override fun onMessage(webSocket: WebSocket, text: String) = receive(LiveWebSocketMessage.Text(text))

    override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
      if (bytes.size > GeminiLiveWireProtocol.MAXIMUM_INBOUND_MESSAGE_BYTES) {
        fail(LiveTranscriptionException.of(LiveTranscriptionException.Kind.RESPONSE_TOO_LARGE))
      } else {
        receive(LiveWebSocketMessage.Binary(bytes.toByteArray()))
      }
    }

    override fun onClosing(webSocket: WebSocket, code: Int, reason: String) = remoteClosed(code, reason)

    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = remoteClosed(code, reason)

    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
      if (synchronized(lock) { state == State.TERMINAL }) return
      if (synchronized(lock) { didReceiveGoAway }) {
        terminate(closeCode = CloseCode.NORMAL)
        return
      }
      fail(handshakeOrTransportError(t, response))
    }
  }

  fun start(connector: LiveWebSocketConnector, request: Request, setupMessage: String) {
    synchronized(lock) {
      check(state == State.INITIALIZED)
      state = State.AWAITING_SETUP
    }
    startDeadline()
    val webSocket = connector.open(request, listener)
    val alreadyEnded = synchronized(lock) {
      socket = webSocket
      state == State.TERMINAL
    }
    if (alreadyEnded) {
      webSocket.cancel()
      throw LiveTranscriptionException.of(LiveTranscriptionException.Kind.SESSION_ENDED)
    }
    // OkHttp queues frames until the upgrade completes.
    if (!webSocket.send(setupMessage)) {
      val error = LiveTranscriptionException.of(LiveTranscriptionException.Kind.SESSION_ENDED)
      terminate(error = error, closeCode = CloseCode.GOING_AWAY)
      throw error
    }
    synchronized(lock) {
      if (state == State.AWAITING_SETUP) {
        setupTimeout = timers.launch {
          delay(setupTimeoutMillis)
          val expired = synchronized(lock) { state == State.AWAITING_SETUP }
          if (expired) {
            terminate(
              error = LiveTranscriptionException.of(LiveTranscriptionException.Kind.SETUP_TIMED_OUT),
              closeCode = CloseCode.GOING_AWAY,
            )
          }
        }
      }
    }
  }

  override fun send(chunk: LivePcm16Chunk) {
    val webSocket = readySocket()
    val message = GeminiLiveWireProtocol.audioMessage(chunk)
    if (webSocket.queueSize() + message.length > MAXIMUM_OUTBOUND_QUEUE_BYTES) {
      val error = LiveTranscriptionException.of(LiveTranscriptionException.Kind.BACKPRESSURE)
      terminate(error = error, closeCode = CloseCode.GOING_AWAY)
      throw error
    }
    if (!webSocket.send(message)) throw sendFailure()
  }

  override suspend fun endAudio(): LiveFinalizationResult {
    val webSocket = readySocket()
    val waiter = synchronized(lock) {
      if (audioEnded) throw LiveTranscriptionException.of(LiveTranscriptionException.Kind.SESSION_ENDED)
      audioEnded = true
      FinalizationWaiter(finalTranscriptSequence, turnCompletionSequence)
    }
    if (!webSocket.send(GeminiLiveWireProtocol.audioStreamEndMessage())) throw sendFailure()

    synchronized(lock) {
      if (finalTranscriptSequence > waiter.afterFinalTranscript) return LiveFinalizationResult.FINAL_TRANSCRIPT_RECEIVED
      if (state == State.TERMINAL) return resultAtTimeout(waiter.afterTurnCompletion)
      waiters += waiter
      waiter.timeout = timers.launch {
        delay(finalizationTimeoutMillis)
        completeTimedOut(waiter)
      }
    }
    try {
      return waiter.result.await()
    } catch (error: CancellationException) {
      completeTimedOut(waiter)
      terminate(endReason = LiveTranscriptionEndReason.CANCELLED, closeCode = CloseCode.GOING_AWAY)
      throw error
    }
  }

  override fun cancel() {
    terminate(endReason = LiveTranscriptionEndReason.CANCELLED, closeCode = CloseCode.NORMAL)
  }

  private fun readySocket(): WebSocket = synchronized(lock) {
    when (state) {
      State.INITIALIZED, State.AWAITING_SETUP ->
        throw LiveTranscriptionException.of(LiveTranscriptionException.Kind.SETUP_NOT_COMPLETE)
      State.TERMINAL -> throw LiveTranscriptionException.of(LiveTranscriptionException.Kind.SESSION_ENDED)
      State.READY -> Unit
    }
    if (audioEnded) throw LiveTranscriptionException.of(LiveTranscriptionException.Kind.SESSION_ENDED)
    socket ?: throw LiveTranscriptionException.of(LiveTranscriptionException.Kind.SESSION_ENDED)
  }

  /** OkHttp refuses a frame only when closing/failed or past its own 16 MiB queue. */
  private fun sendFailure(): LiveTranscriptionException {
    val ended = synchronized(lock) { state == State.TERMINAL }
    val error = LiveTranscriptionException.of(
      if (ended) LiveTranscriptionException.Kind.SESSION_ENDED else LiveTranscriptionException.Kind.BACKPRESSURE
    )
    terminate(error = error, closeCode = CloseCode.GOING_AWAY)
    return error
  }

  private fun receive(message: LiveWebSocketMessage) {
    if (synchronized(lock) { state == State.TERMINAL }) return
    try {
      val decoded = GeminiLiveWireProtocol.decodeServerMessage(message, redacting = apiKey)
      synchronized(lock) {
        if (state == State.TERMINAL) return
        consume(decoded)
      }
    } catch (error: ConsumerGone) {
      terminate(endReason = LiveTranscriptionEndReason.CANCELLED, closeCode = CloseCode.GOING_AWAY)
    } catch (error: Throwable) {
      fail(error)
    }
  }

  /** Must hold [lock]. Validates ordering and budgets exactly as iOS before emitting. */
  private fun consume(decoded: List<LiveTranscriptionEvent>) {
    for (event in decoded) {
      when (event) {
        LiveTranscriptionEvent.SetupComplete -> {
          if (state != State.AWAITING_SETUP) throw invalidResponse()
          state = State.READY
          setupTimeout?.cancel()
          setupTimeout = null
        }
        is LiveTranscriptionEvent.InterimTranscript, is LiveTranscriptionEvent.FinalTranscript -> {
          if (state != State.READY) throw invalidResponse()
          val text = if (event is LiveTranscriptionEvent.InterimTranscript) event.text else (event as LiveTranscriptionEvent.FinalTranscript).text
          val nextCount = transcriptByteCount + text.encodeToByteArray().size
          if (nextCount > GeminiLiveWireProtocol.MAXIMUM_TOTAL_TRANSCRIPT_BYTES) {
            throw LiveTranscriptionException.of(LiveTranscriptionException.Kind.RESPONSE_TOO_LARGE)
          }
          transcriptByteCount = nextCount
          if (event is LiveTranscriptionEvent.InterimTranscript) {
            hasUnfinalizedInterim = text.isNotBlank()
          } else {
            hasUnfinalizedInterim = false
            finalTranscriptSequence += 1
            resumeSatisfiedWaiters()
          }
        }
        LiveTranscriptionEvent.TurnComplete -> {
          if (state != State.READY) throw invalidResponse()
          turnCompletionSequence += 1
        }
        is LiveTranscriptionEvent.GoAway -> {
          if (state != State.READY) throw invalidResponse()
          didReceiveGoAway = true
        }
        is LiveTranscriptionEvent.DurationLimitApproaching, is LiveTranscriptionEvent.Ended -> throw invalidResponse()
      }
      emit(event)
    }
  }

  /** Must hold [lock]. A full buffer is backpressure; a cancelled consumer ends the session. */
  private fun emit(event: LiveTranscriptionEvent) {
    val result = channel.trySend(event)
    if (result.isSuccess) return
    if (result.isClosed) throw ConsumerGone()
    throw LiveTranscriptionException.of(LiveTranscriptionException.Kind.BACKPRESSURE)
  }

  private fun startDeadline() {
    if (durationMillis > GeminiLiveWireProtocol.WRAP_UP_LEAD_MILLIS) {
      timers.launch {
        delay(durationMillis - GeminiLiveWireProtocol.WRAP_UP_LEAD_MILLIS)
        try {
          synchronized(lock) {
            if (state != State.READY) return@launch
            emit(LiveTranscriptionEvent.DurationLimitApproaching(GeminiLiveWireProtocol.WRAP_UP_LEAD_MILLIS / 1_000.0))
          }
        } catch (error: Throwable) {
          if (error is ConsumerGone) cancel() else fail(error)
        }
      }
    }
    timers.launch {
      delay(durationMillis)
      terminate(endReason = LiveTranscriptionEndReason.DURATION_LIMIT_REACHED, closeCode = CloseCode.NORMAL)
    }
  }

  /** Must hold [lock]. */
  private fun resumeSatisfiedWaiters() {
    val satisfied = waiters.filter { finalTranscriptSequence > it.afterFinalTranscript }
    for (waiter in satisfied) {
      waiters.remove(waiter)
      waiter.timeout?.cancel()
      waiter.result.complete(LiveFinalizationResult.FINAL_TRANSCRIPT_RECEIVED)
    }
  }

  private fun completeTimedOut(waiter: FinalizationWaiter) {
    synchronized(lock) {
      if (!waiters.remove(waiter)) return
      waiter.timeout?.cancel()
      waiter.result.complete(resultAtTimeout(waiter.afterTurnCompletion))
    }
  }

  /** Must hold [lock]. Silence and completed turns are not reported as possible data loss. */
  private fun resultAtTimeout(afterTurnCompletion: Long): LiveFinalizationResult = when {
    hasUnfinalizedInterim -> LiveFinalizationResult.TIMED_OUT
    turnCompletionSequence > afterTurnCompletion -> LiveFinalizationResult.TURN_COMPLETED
    else -> LiveFinalizationResult.NOTHING_PENDING
  }

  private fun remoteClosed(code: Int, reason: String) {
    val (ended, goAway, audioDone) = synchronized(lock) { Triple(state == State.TERMINAL, didReceiveGoAway, audioEnded) }
    if (ended) return
    when {
      // A requested close after GoAway, or a normal close after end-of-audio, is not a failure.
      goAway || (audioDone && code == CloseCode.NORMAL) -> terminate(closeCode = CloseCode.NORMAL)
      reason.isNotBlank() -> fail(LiveTranscriptionException.provider(LiveTranscriptionRedactor.sanitize(reason, apiKey)))
      else -> fail(LiveTranscriptionException.transport("Gemini Live closed the connection (code $code)."))
    }
  }

  private fun fail(error: Throwable) {
    val safeError = GeminiLiveTranscriptionClient.sanitized(error, apiKey)
    terminate(error = safeError, closeCode = closeCodeFor(safeError))
  }

  private fun closeCodeFor(error: Throwable): Int = when ((error as? LiveTranscriptionException)?.kind) {
    LiveTranscriptionException.Kind.RESPONSE_TOO_LARGE -> CloseCode.MESSAGE_TOO_BIG
    LiveTranscriptionException.Kind.INVALID_RESPONSE, LiveTranscriptionException.Kind.PROVIDER -> CloseCode.POLICY_VIOLATION
    else -> CloseCode.GOING_AWAY
  }

  private fun handshakeOrTransportError(error: Throwable, response: Response?): Throwable {
    val status = response?.code
    if (status == null || status == 101) return error
    val body = runCatching { response.peekBody(ERROR_BODY_LIMIT).string() }.getOrDefault("")
    val providerText = ProviderErrorSanitizer.bodyMessage(body, apiKey)
    val message = when (status) {
      in 300..399 ->
        "Gemini Live redirected the connection (HTTP $status). Turing AI does not follow redirects, so the " +
          "Google API key stays on Google's fixed endpoint."
      401, 403 -> providerText.ifEmpty { "Google rejected the API key for Gemini Live (HTTP $status)." }
      429 -> providerText.ifEmpty { "Gemini Live is rate limiting requests. Try again shortly." }
      else -> providerText.ifEmpty { "Gemini Live returned HTTP $status." }
    }
    return if (status in 300..399) {
      LiveTranscriptionException.transport(message)
    } else {
      LiveTranscriptionException.provider(message)
    }
  }

  private fun terminate(
    error: Throwable? = null,
    endReason: LiveTranscriptionEndReason? = null,
    closeCode: Int,
  ) {
    val webSocket: WebSocket?
    synchronized(lock) {
      if (state == State.TERMINAL) return
      state = State.TERMINAL
      webSocket = socket
      for (waiter in waiters.toList()) {
        waiter.timeout?.cancel()
        waiter.result.complete(resultAtTimeout(waiter.afterTurnCompletion))
      }
      waiters.clear()
      if (endReason != null) channel.trySend(LiveTranscriptionEvent.Ended(endReason))
      channel.close(error)
    }
    timers.cancel()
    // Close handshake; OkHttp cancels the socket if Google does not answer within 2 s.
    if (webSocket != null && !webSocket.close(closeCode, CLOSE_REASON)) webSocket.cancel()
  }

  private fun invalidResponse() = LiveTranscriptionException.of(LiveTranscriptionException.Kind.INVALID_RESPONSE)

  /** The event consumer cancelled its channel. */
  private class ConsumerGone : RuntimeException() {
    override fun fillInStackTrace(): Throwable = this
  }
}

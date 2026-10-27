package com.omergirgin.mosaic.ui.voice

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import com.omergirgin.mosaic.core.chat.ProviderException
import com.omergirgin.mosaic.core.context.utf8Length
import com.omergirgin.mosaic.core.net.ProviderErrorSanitizer
import com.omergirgin.mosaic.core.net.live.GeminiLiveTranscriptionClient
import com.omergirgin.mosaic.core.net.live.LiveTranscriptAssembler
import com.omergirgin.mosaic.core.net.live.LiveTranscriptSnapshot
import com.omergirgin.mosaic.core.net.live.LiveTranscriptionConfiguration
import com.omergirgin.mosaic.core.net.live.LiveTranscriptionEndReason
import com.omergirgin.mosaic.core.net.live.LiveTranscriptionEvent
import com.omergirgin.mosaic.core.net.live.LiveTranscriptionException
import com.omergirgin.mosaic.core.net.live.LiveTranscriptionMode
import com.omergirgin.mosaic.core.net.live.LiveTranscriptionSession
import com.omergirgin.mosaic.core.net.live.joinTranscript
import com.omergirgin.mosaic.data.api.AppContainer
import com.omergirgin.mosaic.data.live.LiveTranscriptionTarget
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

enum class DictationPhase {
  IDLE,
  REQUESTING_PERMISSION,
  CONNECTING,
  LISTENING,
  FINISHING;

  val isActive: Boolean get() = this != IDLE
}

/** What the conversation screen offers for dictation; implemented over the chat view model. */
interface DictationHost {
  val openConversationId: StateFlow<String?>
  val isGenerating: StateFlow<Boolean>
  /** The chat-selected connection, preferred for dictation when it is an eligible Google one. */
  val chatProviderId: String?
  /** In-memory composer draft of the open conversation. */
  val draft: String
  fun replaceDraft(text: String)
  fun flushDraft()
  /** Writes finalized dictation into a conversation that is no longer on screen. */
  fun writeDetachedDraft(conversationId: String, previous: String, text: String)
}

/** A dialog the conversation screen shows after dictation ends with something to explain. */
data class DictationAlert(val message: String, val action: Action? = null) {
  enum class Action { OPEN_APP_SETTINGS, OPEN_PROVIDERS }
}

/**
 * Gemini Live dictation into the composer (iOS ConversationView live transcription). One session
 * at a time; all state lives on the main thread. Interim words render in the composer but are
 * never persisted; finalized segments are appended deterministically to the draft. Nothing is sent
 * to the chat provider until the person taps Send.
 */
class DictationController(
  private val container: AppContainer,
  private val scope: CoroutineScope,
  private val host: DictationHost,
  private val client: GeminiLiveTranscriptionClient = GeminiLiveTranscriptionClient(),
) {
  var phase by mutableStateOf(DictationPhase.IDLE)
    private set
  /** Conversation the active session writes into. */
  var conversationId by mutableStateOf<String?>(null)
    private set
  var interim by mutableStateOf("")
    private set
  var languageCode by mutableStateOf<String?>(null)
    private set
  /** e.g. "Google Gemini at generativelanguage.googleapis.com". */
  var destination by mutableStateOf("")
    private set
  var alert by mutableStateOf<DictationAlert?>(null)
    private set
  /** Set when the screen should launch the system permission request. */
  var permissionRequestPending by mutableStateOf(false)
    private set

  private var appContext: Context? = null
  private var preparing: Job? = null
  private var pendingTarget: LiveTranscriptionTarget? = null
  private var sessionJob: Job? = null
  private var activeSession: LiveTranscriptionSession? = null
  private var activeMicrophone: LiveMicrophoneAudioSource? = null

  fun isActiveFor(conversationId: String?): Boolean =
    phase.isActive && conversationId != null && this.conversationId == conversationId

  /** Composer text: the draft plus replaceable interim words while this chat is dictating. */
  fun composerText(draft: String, openConversationId: String?): String =
    if (isActiveFor(openConversationId) && interim.isNotEmpty()) joinTranscript(draft, interim) else draft

  /** The single start/stop control (iOS: a second stop during connect/finish cancels promptly). */
  fun toggle(context: Context) {
    when (phase) {
      DictationPhase.IDLE -> start(context)
      DictationPhase.REQUESTING_PERMISSION -> cancelPermissionRequest()
      DictationPhase.LISTENING -> finish()
      DictationPhase.CONNECTING, DictationPhase.FINISHING -> cancelNow()
    }
  }

  /** Backgrounding, leaving the chat, or switching chats: the same bounded graceful path as Stop. */
  fun stopForLifecycle() {
    when (phase) {
      DictationPhase.REQUESTING_PERMISSION -> cancelPermissionRequest()
      DictationPhase.CONNECTING -> cancelNow()
      DictationPhase.LISTENING -> finish()
      DictationPhase.FINISHING, DictationPhase.IDLE -> Unit
    }
  }

  fun dismissAlert() {
    alert = null
  }

  fun consumePermissionRequest() {
    permissionRequestPending = false
  }

  fun onPermissionResult(granted: Boolean, canAskAgain: Boolean) {
    if (phase != DictationPhase.REQUESTING_PERMISSION) return
    val target = pendingTarget
    if (!granted || target == null) {
      reset()
      alert = DictationAlert(
        if (canAskAgain) {
          "Turing AI needs microphone access to dictate. Audio is sent only to Google Gemini while you dictate."
        } else {
          "Microphone access is turned off for Turing AI. Allow it in the app's settings to dictate."
        },
        action = if (canAskAgain) null else DictationAlert.Action.OPEN_APP_SETTINGS,
      )
      return
    }
    // iOS parity: the connection may have changed while the permission prompt was open.
    preparing = scope.launch {
      val refreshed = eligibleConnection()
      if (phase != DictationPhase.REQUESTING_PERMISSION) return@launch
      if (refreshed?.providerId != target.providerId) {
        reset()
        alert = DictationAlert(
          "The Google Gemini connection changed while Turing AI was waiting for microphone permission. " +
            "Review the connection and try again."
        )
      } else {
        begin(refreshed)
      }
    }
  }

  private fun start(context: Context) {
    if (preparing?.isActive == true) return
    val conversation = host.openConversationId.value ?: return
    if (host.isGenerating.value) {
      alert = DictationAlert("Wait for the response to finish before dictating.")
      return
    }
    appContext = context.applicationContext
    alert = null
    preparing = scope.launch {
      val target = eligibleConnection()
      if (phase != DictationPhase.IDLE || host.openConversationId.value != conversation) return@launch
      if (target == null) {
        alert = DictationAlert(
          "Add and enable a Google Gemini connection with its official API endpoint before using live transcription.",
          action = DictationAlert.Action.OPEN_PROVIDERS,
        )
        return@launch
      }
      conversationId = conversation
      pendingTarget = target
      destination = "${target.displayName} at ${target.host}"
      val granted = ContextCompat.checkSelfPermission(context.applicationContext, Manifest.permission.RECORD_AUDIO) ==
        PackageManager.PERMISSION_GRANTED
      if (granted) {
        begin(target)
      } else {
        phase = DictationPhase.REQUESTING_PERMISSION
        permissionRequestPending = true
      }
    }
  }

  private suspend fun eligibleConnection(): LiveTranscriptionTarget? = try {
    container.liveTranscription.eligibleConnection(host.chatProviderId)
  } catch (error: CancellationException) {
    throw error
  } catch (error: Exception) {
    null
  }

  private fun begin(target: LiveTranscriptionTarget) {
    val conversation = conversationId ?: return reset()
    if (host.isGenerating.value || host.openConversationId.value != conversation) return reset()
    pendingTarget = null
    interim = ""
    languageCode = null
    phase = DictationPhase.CONNECTING
    // Assigned before it runs, so a cancel arriving during its first synchronous step finds it.
    val job = scope.launch(start = CoroutineStart.LAZY) { run(target, conversation) }
    sessionJob = job
    job.start()
  }

  /** Graceful stop: capture ends first, then end-of-audio and the bounded final-result drain. */
  private fun finish() {
    if (phase != DictationPhase.LISTENING) return
    phase = DictationPhase.FINISHING
    activeMicrophone?.stop()
  }

  /** Explicit cancellation keeps finalized text and discards speculative words immediately. */
  private fun cancelNow() {
    if (phase == DictationPhase.REQUESTING_PERMISSION) return cancelPermissionRequest()
    if (!phase.isActive && sessionJob == null) return
    phase = DictationPhase.FINISHING
    interim = ""
    sessionJob?.cancel()
    activeMicrophone?.cancel()
    activeSession?.cancel()
  }

  private fun cancelPermissionRequest() {
    preparing?.cancel()
    permissionRequestPending = false
    if (phase == DictationPhase.REQUESTING_PERMISSION) reset()
  }

  private fun reset() {
    phase = DictationPhase.IDLE
    conversationId = null
    pendingTarget = null
    interim = ""
    languageCode = null
    destination = ""
    permissionRequestPending = false
  }

  private suspend fun run(target: LiveTranscriptionTarget, conversation: String) {
    var apiKey: String? = null
    var session: LiveTranscriptionSession? = null
    var microphone: LiveMicrophoneAudioSource? = null
    var sender: Job? = null
    var detached = false
    var reachedDurationLimit = false
    var providerRequestedClose = false

    // Leaving the chat or a response starting in it ends dictation through the same paths as Stop.
    val watcher = scope.launch {
      combine(host.openConversationId, host.isGenerating) { open, generating -> open != conversation || generating }
        .first { it }
      stopForLifecycle()
    }

    try {
      val credential = withContext(Dispatchers.IO) { container.liveTranscription.resolveCredential(target.providerId) }
      apiKey = credential.apiKey
      destination = "${credential.target.displayName} at ${credential.target.host}"
      val connected = withContext(Dispatchers.IO) {
        client.connect(credential.apiKey, LiveTranscriptionConfiguration(mode = LiveTranscriptionMode.SMART))
      }
      session = connected
      activeSession = connected

      var setupComplete = false
      for (event in connected.events) {
        if (event is LiveTranscriptionEvent.SetupComplete) {
          setupComplete = true
          break
        }
      }
      // A transport that ends without throwing while cancelled is not a malformed response.
      currentCoroutineContext().ensureActive()
      if (!setupComplete) throw LiveTranscriptionException.of(LiveTranscriptionException.Kind.INVALID_RESPONSE)

      // The microphone opens only after Gemini confirmed the setup.
      val source = LiveMicrophoneAudioSource(checkNotNull(appContext))
      microphone = source
      activeMicrophone = source
      val audio = withContext(Dispatchers.IO) { source.start() }
      currentCoroutineContext().ensureActive()
      phase = DictationPhase.LISTENING

      val failure = AtomicReference<Throwable?>(null)
      val unconfirmedWords = AtomicBoolean(false)
      sender = scope.launch(Dispatchers.Default) {
        try {
          for (chunk in audio) connected.send(chunk)
          // Silence and completed turns are not data loss; only an unresolved interim is.
          if (connected.endAudio().mayHaveUnconfirmedWords) unconfirmedWords.set(true)
        } catch (error: CancellationException) {
          throw error
        } catch (error: LiveTranscriptionException) {
          // The session reports its own terminal state through the event stream.
          if (error.kind != LiveTranscriptionException.Kind.SESSION_ENDED) failure.compareAndSet(null, error)
        } catch (error: Throwable) {
          failure.compareAndSet(null, error)
        } finally {
          connected.cancel()
        }
      }

      val baseDraft = host.draft
      var lastApplied = baseDraft
      val assembler = LiveTranscriptAssembler()
      for (event in connected.events) {
        val snapshot = assembler.consume(event)
        if (!detached && host.openConversationId.value != conversation) detached = true
        lastApplied = apply(snapshot, conversation, baseDraft, lastApplied, detached)

        when (event) {
          is LiveTranscriptionEvent.DurationLimitApproaching -> {
            reachedDurationLimit = true
            finish()
          }
          is LiveTranscriptionEvent.GoAway -> {
            providerRequestedClose = true
            finish()
          }
          is LiveTranscriptionEvent.Ended ->
            if (event.reason == LiveTranscriptionEndReason.DURATION_LIMIT_REACHED) reachedDurationLimit = true
          else -> Unit
        }
      }

      // The session has ended: release capture and let the sender record its final result.
      source.cancel()
      withTimeoutOrNull(SENDER_SETTLE_MILLIS) { sender.join() }
      failure.get()?.let { throw it }
      val unconfirmedNote = if (unconfirmedWords.get()) " The last unconfirmed words may be missing." else ""
      when {
        reachedDurationLimit -> alert = DictationAlert(
          "Turing AI ended this recording before Gemini Live’s 10-minute session limit. Finalized text " +
            "remains in your draft; start the microphone again to continue.$unconfirmedNote"
        )
        // A provider-requested close is reported as such, never as a time limit.
        providerRequestedClose -> alert = DictationAlert(
          "Gemini Live asked to close this connection. Finalized text remains in your draft; start the " +
            "microphone again to continue.$unconfirmedNote"
        )
        unconfirmedWords.get() -> alert = DictationAlert(
          LiveTranscriptionException.defaultMessage(LiveTranscriptionException.Kind.FINALIZATION_TIMED_OUT)
        )
      }
    } catch (error: CancellationException) {
      // Explicit cancellation keeps finalized text and intentionally discards speculative text.
    } catch (error: Throwable) {
      alert = DictationAlert(describe(error, apiKey), action = settingsActionFor(error))
    } finally {
      watcher.cancel()
      sender?.cancel()
      microphone?.cancel()
      session?.cancel()
      activeMicrophone = null
      activeSession = null
      if (sessionJob == currentCoroutineContext()[Job]) sessionJob = null
      val wasOnScreen = host.openConversationId.value == conversation
      reset()
      if (wasOnScreen) host.flushDraft()
    }
  }

  /**
   * Applies one snapshot: finalized text goes into the draft (checked against the 512 KiB draft
   * limit and against edits made elsewhere), interim words only into the rendered composer.
   */
  private fun apply(
    snapshot: LiveTranscriptSnapshot,
    conversation: String,
    baseDraft: String,
    lastApplied: String,
    detached: Boolean,
  ): String {
    val finalizedDraft = joinTranscript(baseDraft, snapshot.finalizedText)
    val displayed = joinTranscript(finalizedDraft, snapshot.interimText.orEmpty())
    if (utf8Length(displayed) > DRAFT_LIMIT_BYTES) {
      throw DictationStopped(
        "The draft reached its ${DRAFT_LIMIT_BYTES / 1_024} KB limit, so live transcription stopped. " +
          "Finalized text remains in your draft."
      )
    }
    if (detached) {
      interim = ""
      if (finalizedDraft != lastApplied) host.writeDetachedDraft(conversation, lastApplied, finalizedDraft)
    } else {
      if (host.draft != lastApplied) {
        throw DictationStopped("The draft changed while dictating, so live transcription stopped without overwriting it.")
      }
      if (finalizedDraft != lastApplied) host.replaceDraft(finalizedDraft)
      interim = snapshot.interimText.orEmpty()
    }
    languageCode = snapshot.languageCode
    return finalizedDraft
  }

  private fun describe(error: Throwable, apiKey: String?): String {
    val raw = when (error) {
      is LiveTranscriptionException, is LiveMicrophoneException, is ProviderException, is DictationStopped ->
        error.message.orEmpty()
      else -> ProviderErrorSanitizer.describe(error, apiKey)
    }
    // Final pass: key redaction, control characters and length, whatever produced the text.
    return ProviderErrorSanitizer.bodyMessage(raw, apiKey).ifEmpty { "Live transcription stopped. Please try again." }
  }

  private fun settingsActionFor(error: Throwable): DictationAlert.Action? = when {
    error is LiveMicrophoneException && error.kind == LiveMicrophoneException.Kind.PERMISSION_DENIED ->
      DictationAlert.Action.OPEN_APP_SETTINGS
    error is ProviderException -> DictationAlert.Action.OPEN_PROVIDERS
    else -> null
  }

  private class DictationStopped(message: String) : Exception(message)

  companion object {
    /** iOS `MosaicSourceFieldLimits.maximumConversationDraftUTF8Bytes` (data FieldLimits.DRAFT_BYTES). */
    const val DRAFT_LIMIT_BYTES = 512 * 1_024
    private const val SENDER_SETTLE_MILLIS = 2_000L
  }
}

package com.omergirgin.mosaic.core.net

import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import com.omergirgin.mosaic.core.chat.StreamEvent
import com.omergirgin.mosaic.core.chat.TokenUsage
import com.omergirgin.mosaic.core.chat.WebSource
import com.omergirgin.mosaic.core.provider.ProviderKind
import kotlinx.serialization.json.JsonObject

/** Mosaic's persisted message limit; provider text beyond it is never accepted. */
internal const val MAX_STREAM_TEXT_BYTES: Int = 512 * 1_024
internal const val MAX_STREAM_CONTROL_EVENTS: Int = 4_096
internal const val MAX_CITATIONS_PER_EVENT: Int = 100

/**
 * Turns framed SSE events into validated [StreamEvent]s for one request:
 * decode -> MiniMax snapshot normalization -> deferred Chat Completions finish -> Gemini usage
 * coalescing -> citation de-duplication -> budget.
 */
internal class StreamEventPipeline(provider: ProviderKind, private val wire: ChatWireProtocol) {
  private val miniMax = if (provider == ProviderKind.MINIMAX) MiniMaxStreamNormalizer() else null
  private val completion = ChatCompletionCoordinator(enabled = wire.dialect == ChatDialect.OPENAI_CHAT_COMPLETIONS)
  private val usage = UsageCoalescer(enabled = wire.dialect == ChatDialect.GEMINI)
  private val budget = StreamEventBudget()
  private val emittedSources = HashSet<WebSource>()

  fun consume(event: SseEvent): List<StreamEvent> {
    // Spec-compliant: an event with an empty data buffer (e.g. a bare `event: ping`) is not dispatched.
    if (event.data.isEmpty()) return emptyList()
    val isDoneSentinel = event.data == "[DONE]"
    var events =
      if (isDoneSentinel) {
        listOf(StreamEvent.Completed(null))
      } else {
        val json = parseEventObject(event.data) ?: return emptyList()
        wire.decode(json)
      }
    miniMax?.let { events = it.normalize(events) }
    events = completion.consume(events, isExplicitEndMarker = isDoneSentinel)
    events = usage.consume(events)
    return budget.validated(withoutRepeatedSources(events))
  }

  /** Clean EOF: release a deferred Chat Completions finish, else flush any held Gemini usage. */
  fun finish(): List<StreamEvent> {
    val atEndOfStream = budget.validated(usage.consume(completion.finishAtEndOfStream()))
    if (atEndOfStream.any { it is StreamEvent.Completed }) return atEndOfStream
    return atEndOfStream + budget.validated(usage.finishAtEndOfStream())
  }

  private fun parseEventObject(data: String): JsonObject? {
    val json = ProviderJson.parse(data) as? JsonObject ?: return null
    providerErrorMessage(json)?.let { throw ProviderFailures.provider(it) }
    return json
  }

  /**
   * Responses API repeats every streamed annotation inside `response.completed`. Consumers dedupe
   * too, but dropping repeats here keeps them out of the control-event budget.
   */
  private fun withoutRepeatedSources(events: List<StreamEvent>): List<StreamEvent> {
    if (events.none { it is StreamEvent.Citations }) return events
    return events.mapNotNull { event ->
      if (event !is StreamEvent.Citations) return@mapNotNull event
      val fresh = event.sources.filter { emittedSources.add(it) }
      if (fresh.isEmpty()) null else StreamEvent.Citations(fresh)
    }
  }
}

/**
 * Bounds what an unconsumed stream can retain without a tiny event-count limit: providers often
 * send one event per token, so text is bounded by bytes and bookkeeping events by count.
 */
internal class StreamEventBudget {
  private var textByteCount = 0L
  private var controlEventCount = 0

  fun validated(events: List<StreamEvent>): List<StreamEvent> {
    val accepted = ArrayList<StreamEvent>(events.size)
    for (event in events) {
      when (event) {
        is StreamEvent.TextDelta -> {
          if (event.text.isEmpty()) continue
          textByteCount += event.text.utf8Size()
          if (textByteCount > MAX_STREAM_TEXT_BYTES) throw tooLarge()
        }
        is StreamEvent.Citations -> {
          if (event.sources.size > MAX_CITATIONS_PER_EVENT) throw tooLarge()
          controlEventCount += maxOf(1, event.sources.size)
          if (controlEventCount > MAX_STREAM_CONTROL_EVENTS) throw tooLarge()
        }
        is StreamEvent.Usage, is StreamEvent.Completed -> {
          controlEventCount += 1
          if (controlEventCount > MAX_STREAM_CONTROL_EVENTS) throw tooLarge()
        }
      }
      accepted += event
    }
    return accepted
  }

  private fun tooLarge() = ProviderFailures.of(ProviderErrorKind.RESPONSE_TOO_LARGE)
}

/**
 * Gemini attaches cumulative usage metadata to every chunk. Holding only the newest counters until
 * completion keeps a long valid response from exhausting the control-event budget, while still
 * delivering the final accounting before [StreamEvent.Completed].
 */
internal class UsageCoalescer(private val enabled: Boolean) {
  private var pending: TokenUsage? = null

  fun consume(events: List<StreamEvent>): List<StreamEvent> {
    if (!enabled) return events
    val output = ArrayList<StreamEvent>(events.size)
    var receivedCompletion = false
    var responseId: String? = null
    for (event in events) {
      when (event) {
        is StreamEvent.TextDelta, is StreamEvent.Citations -> output += event
        is StreamEvent.Usage ->
          pending =
            TokenUsage(
              inputTokens = event.usage.inputTokens ?: pending?.inputTokens,
              outputTokens = event.usage.outputTokens ?: pending?.outputTokens,
            )
        is StreamEvent.Completed -> {
          receivedCompletion = true
          responseId = event.responseId ?: responseId
        }
      }
    }
    if (receivedCompletion) {
      pending?.let { output += StreamEvent.Usage(it) }
      output += StreamEvent.Completed(responseId)
      pending = null
    }
    return output
  }

  fun finishAtEndOfStream(): List<StreamEvent> {
    if (!enabled) return emptyList()
    val usage = pending ?: return emptyList()
    pending = null
    return listOf(StreamEvent.Usage(usage))
  }
}

/**
 * Some OpenAI-compatible hosts omit `[DONE]` and signal success only through `finish_reason`.
 * That completion is deferred until the sentinel or a clean EOF so a trailing usage-only chunk
 * (`stream_options.include_usage`) is not lost.
 */
internal class ChatCompletionCoordinator(private val enabled: Boolean) {
  private var hasPendingCompletion = false
  private var pendingResponseId: String? = null

  fun consume(events: List<StreamEvent>, isExplicitEndMarker: Boolean): List<StreamEvent> {
    if (!enabled) return events
    val output = ArrayList<StreamEvent>(events.size + 1)
    var explicitResponseId: String? = null
    for (event in events) {
      if (event is StreamEvent.Completed) {
        if (isExplicitEndMarker) {
          explicitResponseId = event.responseId
        } else {
          hasPendingCompletion = true
          pendingResponseId = event.responseId ?: pendingResponseId
        }
      } else {
        output += event
      }
    }
    if (isExplicitEndMarker) {
      output += StreamEvent.Completed(pendingResponseId ?: explicitResponseId)
      hasPendingCompletion = false
      pendingResponseId = null
    }
    return output
  }

  fun finishAtEndOfStream(): List<StreamEvent> {
    if (!enabled || !hasPendingCompletion) return emptyList()
    val responseId = pendingResponseId
    hasPendingCompletion = false
    pendingResponseId = null
    return listOf(StreamEvent.Completed(responseId))
  }
}

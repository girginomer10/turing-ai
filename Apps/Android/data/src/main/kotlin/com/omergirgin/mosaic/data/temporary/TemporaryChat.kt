package com.omergirgin.mosaic.data.temporary

import com.omergirgin.mosaic.core.chat.ChatImageInput
import com.omergirgin.mosaic.core.chat.ChatMessage
import com.omergirgin.mosaic.core.chat.ChatRequest
import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.chat.ProviderClientFactory
import com.omergirgin.mosaic.core.chat.StreamEvent
import com.omergirgin.mosaic.core.context.AttachmentText
import com.omergirgin.mosaic.core.context.ContextCandidate
import com.omergirgin.mosaic.core.context.ContextLimitsResolver
import com.omergirgin.mosaic.core.context.ContextPlanner
import com.omergirgin.mosaic.core.context.ContextPlanningException
import com.omergirgin.mosaic.core.context.ContextStrategy
import com.omergirgin.mosaic.core.context.PromptLayers
import com.omergirgin.mosaic.core.context.utf8Length
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.profile
import com.omergirgin.mosaic.data.internal.ErrorSanitizer
import com.omergirgin.mosaic.data.internal.FieldLimits
import com.omergirgin.mosaic.data.model.Attachment
import com.omergirgin.mosaic.data.model.AttachmentKind
import com.omergirgin.mosaic.data.model.ModelChoice
import com.omergirgin.mosaic.data.repo.ProviderRepositoryImpl
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn

/** One turn of a Temporary Chat. It exists only in the caller's memory. */
data class TemporaryChatTurn(
  val id: String,
  val role: ChatRole,
  val text: String,
  val attachments: List<Attachment> = emptyList(),
)

/** What one temporary request sent. Shown during the session only; never stored. */
data class TemporaryRequestReceipt(
  val providerName: String,
  val providerKind: ProviderKind,
  val modelId: String,
  val destinationHost: String?,
  val messageCount: Int,
  val attachmentCount: Int,
  val photoCount: Int,
  val estimatedInputTokens: Int,
  val inputBudgetTokens: Int,
  val maximumOutputTokens: Int,
  val warnings: List<String>,
)

sealed interface TemporaryChatEvent {
  /** Planning passed and the request is about to open; nothing was sent before this. */
  data class Started(val receipt: TemporaryRequestReceipt) : TemporaryChatEvent
  data class TextDelta(val text: String) : TemporaryChatEvent
  data class Usage(val inputTokens: Int?, val outputTokens: Int?) : TemporaryChatEvent
  /** Terminal success. A stream that ends without it is a failure. */
  data object Completed : TemporaryChatEvent
}

/** A failure with user-facing text that is already sanitized (keys redacted). */
class TemporaryChatException(message: String) : Exception(message)

/**
 * Temporary Chat requests (iOS `TemporaryChatView.send`). The caller owns the whole transcript in
 * memory; this service resolves the selected model and its key, plans the request with the same
 * limits and estimator as saved chats, and streams the reply. It never touches the conversation
 * database, usage ledger, receipts, recall index, memory formation or model recents. There is no
 * system prompt, project, memory or recall layer: only the turns the person typed.
 */
interface TemporaryChatService {
  /** [turns] must end with the new user turn. Failures throw [TemporaryChatException]. */
  fun stream(choice: ModelChoice, turns: List<TemporaryChatTurn>): Flow<TemporaryChatEvent>
}

internal class TemporaryChatServiceImpl(private val providers: ProviderRepositoryImpl) : TemporaryChatService {

  override fun stream(choice: ModelChoice, turns: List<TemporaryChatTurn>): Flow<TemporaryChatEvent> = flow {
    var apiKey: String? = null
    try {
      require(turns.lastOrNull()?.role == ChatRole.USER) { "Type a message to send." }
      val model = providers.resolveModel(choice)
      val photoCount = turns.sumOf { turn -> turn.attachments.count { it.kind == AttachmentKind.IMAGE } }
      if (photoCount > 0 && !model.supportsImages) {
        throw TemporaryChatException("Choose a photo-capable model for this temporary chat.")
      }

      val limits = ContextLimitsResolver.resolve(
        model.limits.contextWindowTokens,
        model.limits.maximumOutputTokens,
        model.limitsSource,
      )
      val candidates = turns.map { turn ->
        val texts = turn.attachments.mapNotNull { attachment ->
          val text = attachment.extractedText
          if (attachment.kind == AttachmentKind.IMAGE || text.isNullOrBlank()) null
          else AttachmentText(attachment.fileName, attachment.mimeType, text)
        }
        ContextCandidate(
          id = turn.id,
          role = turn.role,
          content = PromptLayers.userContent(turn.text, texts),
          imageCount = turn.attachments.count { it.kind == AttachmentKind.IMAGE },
        )
      }
      // No summaries or recall: the whole session is sent, or the request fails before sending.
      val plan = try {
        ContextPlanner(limits.policy, warnings = limits.warnings).plan(candidates, systemPrompt = null)
      } catch (_: ContextPlanningException) {
        throw TemporaryChatException(LIMIT_REACHED)
      }
      if (plan.receipt.strategy != ContextStrategy.FULL) throw TemporaryChatException(LIMIT_REACHED)

      apiKey = providers.keyFor(model.provider, model.kind, required = model.kind.profile.requiresApiKey)
      val connection = model.connectionWithoutKey().copy(apiKey = apiKey)
      val attachmentsById = turns.associate { it.id to it.attachments }
      val request = ChatRequest(
        messages = candidates.map { candidate ->
          val images = attachmentsById[candidate.id].orEmpty().mapNotNull { attachment ->
            attachment.imageBase64?.takeIf { attachment.kind == AttachmentKind.IMAGE }
              ?.let { ChatImageInput(attachment.mimeType.ifBlank { "image/jpeg" }, it) }
          }
          ChatMessage(candidate.id, candidate.role, candidate.content, images)
        },
        systemPrompt = null,
        maxOutputTokens = limits.policy.maximumOutputTokens,
      )
      emit(
        TemporaryChatEvent.Started(
          TemporaryRequestReceipt(
            providerName = model.provider.displayName,
            providerKind = model.kind,
            modelId = model.modelId,
            destinationHost = model.destinationHost,
            messageCount = candidates.size,
            attachmentCount = turns.sumOf { it.attachments.size },
            photoCount = photoCount,
            estimatedInputTokens = plan.receipt.estimatedInputTokens,
            inputBudgetTokens = plan.receipt.inputBudgetTokens,
            maximumOutputTokens = limits.policy.maximumOutputTokens,
            warnings = plan.receipt.warnings,
          )
        )
      )

      var replyBytes = 0L
      ProviderClientFactory.make(connection).stream(request).collect { event ->
        when (event) {
          is StreamEvent.TextDelta -> if (event.text.isNotEmpty()) {
            replyBytes += utf8Length(event.text)
            if (replyBytes > FieldLimits.MESSAGE_CONTENT_BYTES) {
              throw TemporaryChatException("The reply exceeded Turing AI's 512 KB message limit.")
            }
            emit(TemporaryChatEvent.TextDelta(event.text))
          }
          is StreamEvent.Usage -> emit(TemporaryChatEvent.Usage(event.usage.inputTokens, event.usage.outputTokens))
          is StreamEvent.Completed -> emit(TemporaryChatEvent.Completed)
          // Temporary chats never request web search, so no citations are expected.
          is StreamEvent.Citations -> Unit
        }
      }
    } catch (error: CancellationException) {
      throw error
    } catch (error: TemporaryChatException) {
      throw error
    } catch (error: Exception) {
      throw TemporaryChatException(ErrorSanitizer.describe(error, apiKey))
    }
  }.flowOn(Dispatchers.IO)

  private companion object {
    const val LIMIT_REACHED =
      "This temporary chat reached the model's limit. Start a new temporary chat or choose a model with a larger context."
  }
}

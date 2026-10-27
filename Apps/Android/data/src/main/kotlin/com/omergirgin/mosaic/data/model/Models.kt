package com.omergirgin.mosaic.data.model

import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.chat.WebSource
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.data.recall.RecallReceipt

/** Immutable UI-facing snapshots. Room entities stay private to the data layer. IDs are UUID strings. */

data class ProviderConfig(
  val id: String,
  val kind: ProviderKind,
  val displayName: String,
  /** User override; null = preset default. */
  val baseUrl: String?,
  val isEnabled: Boolean,
  val hasApiKey: Boolean,
  val createdAt: Long,
  val updatedAt: Long,
)

data class ProviderModel(
  val providerId: String,
  val modelId: String,
  val isEnabled: Boolean,
  /** null = resolved from BundledModelCatalog. */
  val contextWindowTokens: Int? = null,
  val maximumOutputTokens: Int? = null,
  /** null = catalog heuristic; explicit override for custom deployments. */
  val supportsImages: Boolean? = null,
  /** Added by hand (exact ID) rather than from suggestions/discovery. */
  val isCustom: Boolean = false,
  val isDiscovered: Boolean = false,
)

/** Exact provider/model selection. */
data class ModelChoice(val providerId: String, val modelId: String)

/** One enabled model on one enabled chat-capable connection, ready for the picker. */
data class ModelOption(
  val choice: ModelChoice,
  val providerKind: ProviderKind,
  val providerName: String,
  val modelId: String,
  val contextWindowTokens: Int,
  val maximumOutputTokens: Int,
  val supportsImages: Boolean,
  val isFavorite: Boolean,
)

/** Create or update a connection. apiKey: null = keep current, "" = remove, else replace. */
data class ProviderDraft(
  val id: String?,
  val kind: ProviderKind,
  val displayName: String,
  val baseUrl: String?,
  val apiKey: String?,
  val isEnabled: Boolean = true,
  /** Models to enable when creating; ignored on update (use saveModels). */
  val initialModels: List<String> = emptyList(),
)

data class Project(
  val id: String,
  val name: String,
  val instructions: String,
  val isArchived: Boolean,
  /** Project default model override. */
  val defaultModel: ModelChoice?,
  val createdAt: Long,
  val updatedAt: Long,
)

data class Conversation(
  val id: String,
  val title: String,
  val projectId: String?,
  val systemPrompt: String?,
  val model: ModelChoice?,
  val draft: String,
  val isArchived: Boolean,
  val webSearchEnabled: Boolean,
  val createdAt: Long,
  val updatedAt: Long,
)

data class ConversationSummary(
  val id: String,
  val title: String,
  val projectId: String?,
  val projectName: String?,
  val preview: String,
  val updatedAt: Long,
  val isArchived: Boolean,
  val hasDraftOnly: Boolean,
)

enum class MessageStatus { COMPLETE, STREAMING, FAILED, CANCELLED }

data class Attachment(
  val id: String,
  val kind: AttachmentKind,
  val fileName: String,
  val mimeType: String,
  /** Extracted text for PDF/text attachments. */
  val extractedText: String? = null,
  /** Normalized JPEG bytes as base64 for photos. */
  val imageBase64: String? = null,
)

enum class AttachmentKind { IMAGE, PDF, TEXT }

data class Message(
  val id: String,
  val conversationId: String,
  val role: ChatRole,
  val content: String,
  val status: MessageStatus,
  val errorMessage: String?,
  val createdAt: Long,
  /** Provenance snapshot (assistant rows): never rewritten by later provider edits. */
  val providerKind: ProviderKind?,
  val providerName: String?,
  val modelId: String?,
  val destinationHost: String?,
  val inputTokens: Int?,
  val outputTokens: Int?,
  /** For retries: the earlier assistant attempt this one replaces in the transcript view. */
  val retryOfMessageId: String?,
  val attachments: List<Attachment> = emptyList(),
  val citations: List<WebSource> = emptyList(),
  /** Request-context receipt for assistant rows (what was sent). */
  val receipt: ContextReceipt? = null,
)

/** What the app actually sent for one answer (AI transparency). */
data class ContextReceipt(
  val projectName: String?,
  val projectInstructions: String?,
  val pinnedFacts: List<String>,
  val includedMessageIds: List<String>,
  val omittedMessageIds: List<String>,
  val estimatedInputTokens: Int,
  val inputBudgetTokens: Int,
  val warnings: List<String>,
  /** App-owned summary of older turns attached to (or attempted for) this answer; null = none. */
  val summary: ConversationSummaryReceipt? = null,
  /**
   * Messages represented by the summary instead of being sent raw. Disjoint from
   * [includedMessageIds] and [omittedMessageIds] (which now means "nothing sent").
   */
  val summarizedMessageIds: List<String> = emptyList(),
  /** Exact earlier user text from this chat recalled locally (oldest first). */
  val sameChatExcerpts: List<SameChatExcerpt> = emptyList(),
  /** Cross-chat, document and learned-topic recall (excerpts, engines, embedding hosts, fallbacks); null = none. */
  val recall: RecallReceipt? = null,
) {
  val summaryStatus: SummaryStatus get() = summary?.status ?: SummaryStatus.NONE
}

enum class SummaryStatus {
  NONE,
  /** A new summary was generated for this answer (one extra provider request). */
  GENERATED,
  /** An existing valid summary was reused (no extra request). */
  REUSED,
  /** A summary attempt failed or was skipped; [ConversationSummaryReceipt.error] says why. */
  FAILED,
  /** The reply was stopped while its summary request was running. */
  CANCELLED,
}

data class ConversationSummaryReceipt(
  val status: SummaryStatus,
  /** Readable summary that was actually sent; null when none was attached. */
  val text: String?,
  /**
   * Provenance of the attached summary. After a failed attempt this can be an older summary from
   * another provider; the attempt itself always used this answer's provider.
   */
  val providerName: String?,
  val providerKind: ProviderKind?,
  val modelId: String?,
  val host: String?,
  val summaryCreatedAt: Long?,
  /** Extra provider requests made for this answer (0 when reused or a duplicate was prevented). */
  val extraRequestCount: Int,
  /**
   * Reported usage of this answer's summary request (also recorded under "Compaction" usage). For
   * [SummaryStatus.REUSED] this is the original generation's usage, not a new charge.
   */
  val inputTokens: Int?,
  val outputTokens: Int?,
  val error: String?,
)

enum class SameChatRecallOrigin {
  /** The excerpt's message is represented by the summary. */
  SUMMARIZED,
  /** The excerpt's message was neither summarized nor sent raw. */
  OMITTED,
}

data class SameChatExcerpt(
  val messageId: String,
  val text: String,
  val origin: SameChatRecallOrigin,
  val createdAt: Long,
  val isTruncated: Boolean,
)

enum class MemoryScope { EVERYWHERE, PROJECT, CONVERSATION }

/** Curated (pinned) fact. */
data class MemoryFact(
  val id: String,
  val title: String,
  val content: String,
  val scope: MemoryScope,
  val projectId: String?,
  val conversationId: String?,
  val isEnabled: Boolean,
  val createdAt: Long,
  val updatedAt: Long,
)

data class AppSettings(
  val defaultModel: ModelChoice? = null,
  val advancedControls: Boolean = false,
  val favorites: Set<ModelChoice> = emptySet(),
  val recentModels: List<ModelChoice> = emptyList(),
  val hasCompletedOnboarding: Boolean = false,
  /** "Learn from new chats": one extra extraction request after each successful reply. */
  val automaticMemoryEnabled: Boolean = true,
  /**
   * Smart memory: one bounded relevance request with the selected chat model before recall
   * (device-local, on by default like iOS). Off = local matching and embedding profiles only.
   */
  val smartMemoryEnabled: Boolean = true,
)

data class UsageSummary(
  val providerName: String,
  val modelId: String,
  val requests: Int,
  val inputTokens: Long,
  val outputTokens: Long,
  /** null when no verified price exists. */
  val estimatedCostUsd: Double?,
  /** Connection that made the requests (custom rates are per connection and model). */
  val providerId: String? = null,
  /** Newest request's provider kind and host: official rates apply only to the preset's host. */
  val providerKind: ProviderKind? = null,
  val destinationHost: String? = null,
  /** The user's custom rates priced this line instead of the bundled list. */
  val usesCustomRate: Boolean = false,
  /** Requests left out of [estimatedCostUsd]: no applicable price or incomplete usage. */
  val unpricedRequests: Int = 0,
  /** Requests whose provider did not report complete token usage. */
  val unreportedRequests: Int = 0,
)

/** Reported usage for one request category ("Chat", "Compaction", "Memory", "Embeddings", ...). */
data class UsageCategorySummary(
  /** Stored category label; unknown labels are passed through unchanged. */
  val category: String,
  val requests: Int,
  val inputTokens: Long,
  val outputTokens: Long,
  /** Sum over priced requests; null when none in the category has a verified price. */
  val estimatedCostUsd: Double?,
  /** Requests left out of [estimatedCostUsd] (no verified price or incomplete usage). */
  val unpricedRequests: Int,
)

/**
 * A send/retry that could not start (nothing was sent to a provider, nothing was persisted), e.g.
 * no model selected, a photo for a text-only model, or a reply already running. Failures after
 * the request starts are recorded on the assistant row instead.
 */
data class ChatNotice(val conversationId: String, val message: String)

/**
 * Terminal result of `ChatEngine.runAndAwait` (unattended requests such as scheduled prompts).
 * [assistantMessageId] is null when the request was rejected before anything was persisted or
 * sent; [errorMessage] is then the same user-facing text a chat notice would show.
 */
data class GenerationOutcome(
  val status: MessageStatus,
  val assistantMessageId: String?,
  val errorMessage: String?,
)

package com.omergirgin.mosaic.data.db

import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.chat.WebSource
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.data.compaction.CompactionReceiptCodec
import com.omergirgin.mosaic.data.compaction.StoredSameChatExcerpt
import com.omergirgin.mosaic.data.compaction.StoredSummaryReceipt
import com.omergirgin.mosaic.data.model.Attachment
import com.omergirgin.mosaic.data.model.AttachmentKind
import com.omergirgin.mosaic.data.model.ContextReceipt
import com.omergirgin.mosaic.data.model.Conversation
import com.omergirgin.mosaic.data.model.ConversationSummary
import com.omergirgin.mosaic.data.model.MemoryFact
import com.omergirgin.mosaic.data.model.MemoryScope
import com.omergirgin.mosaic.data.model.Message
import com.omergirgin.mosaic.data.model.MessageStatus
import com.omergirgin.mosaic.data.model.ModelChoice
import com.omergirgin.mosaic.data.model.Project
import com.omergirgin.mosaic.data.model.ProviderModel
import com.omergirgin.mosaic.data.recall.RecallReceiptCodec
import com.omergirgin.mosaic.data.recall.StoredRecallReceipt
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

internal val StorageJson = Json {
  ignoreUnknownKeys = true
  encodeDefaults = false
  explicitNulls = false
}

@Serializable
internal data class StoredWebSource(val title: String? = null, val url: String)

/** Versioned on-disk receipt; field names are part of the storage format. */
@Serializable
internal data class StoredReceipt(
  val version: Int = 1,
  val projectName: String? = null,
  val projectInstructions: String? = null,
  val pinnedFacts: List<String> = emptyList(),
  val includedMessageIds: List<String> = emptyList(),
  val omittedMessageIds: List<String> = emptyList(),
  val estimatedInputTokens: Int = 0,
  val inputBudgetTokens: Int = 0,
  val warnings: List<String> = emptyList(),
  // Rolling compaction and same-chat recall (absent in older receipts).
  val summary: StoredSummaryReceipt? = null,
  val summarizedMessageIds: List<String> = emptyList(),
  val sameChatExcerpts: List<StoredSameChatExcerpt> = emptyList(),
  // Cross-chat/document/topic recall (absent in older receipts).
  val recall: StoredRecallReceipt? = null,
)

internal object Codecs {
  private val sourcesSerializer = ListSerializer(StoredWebSource.serializer())

  fun encodeCitations(sources: List<WebSource>): String? =
    if (sources.isEmpty()) null
    else StorageJson.encodeToString(sourcesSerializer, sources.map { StoredWebSource(it.title, it.url) })

  fun decodeCitations(json: String?): List<WebSource> {
    if (json.isNullOrEmpty()) return emptyList()
    return runCatching { StorageJson.decodeFromString(sourcesSerializer, json) }
      .getOrDefault(emptyList())
      .map { WebSource(it.title, it.url) }
  }

  fun encodeReceipt(receipt: ContextReceipt): String =
    StorageJson.encodeToString(
      StoredReceipt.serializer(),
      StoredReceipt(
        projectName = receipt.projectName,
        projectInstructions = receipt.projectInstructions,
        pinnedFacts = receipt.pinnedFacts,
        includedMessageIds = receipt.includedMessageIds,
        omittedMessageIds = receipt.omittedMessageIds,
        estimatedInputTokens = receipt.estimatedInputTokens,
        inputBudgetTokens = receipt.inputBudgetTokens,
        warnings = receipt.warnings,
        summary = CompactionReceiptCodec.store(receipt.summary),
        summarizedMessageIds = receipt.summarizedMessageIds,
        sameChatExcerpts = CompactionReceiptCodec.storeExcerpts(receipt.sameChatExcerpts),
        recall = receipt.recall?.let { RecallReceiptCodec.store(it) },
      ),
    )

  /** A malformed receipt is hidden rather than failing the whole transcript. */
  fun decodeReceipt(json: String): ContextReceipt? =
    runCatching { StorageJson.decodeFromString(StoredReceipt.serializer(), json) }.getOrNull()?.let {
      ContextReceipt(
        projectName = it.projectName,
        projectInstructions = it.projectInstructions,
        pinnedFacts = it.pinnedFacts,
        includedMessageIds = it.includedMessageIds,
        omittedMessageIds = it.omittedMessageIds,
        estimatedInputTokens = it.estimatedInputTokens,
        inputBudgetTokens = it.inputBudgetTokens,
        warnings = it.warnings,
        summary = CompactionReceiptCodec.load(it.summary),
        summarizedMessageIds = it.summarizedMessageIds,
        sameChatExcerpts = CompactionReceiptCodec.loadExcerpts(it.sameChatExcerpts),
        recall = it.recall?.let { stored -> RecallReceiptCodec.load(stored) },
      )
    }
}

internal fun choiceOf(providerId: String?, modelId: String?): ModelChoice? =
  if (providerId.isNullOrEmpty() || modelId.isNullOrEmpty()) null else ModelChoice(providerId, modelId)

internal fun ProviderModelEntity.toModel() = ProviderModel(
  providerId = providerId,
  modelId = modelId,
  isEnabled = isEnabled,
  contextWindowTokens = contextWindowTokens,
  maximumOutputTokens = maximumOutputTokens,
  supportsImages = supportsImages,
  isCustom = isCustom,
  isDiscovered = isDiscovered,
)

internal fun ProviderModel.toEntity(providerId: String) = ProviderModelEntity(
  providerId = providerId,
  modelId = modelId.trim(),
  isEnabled = isEnabled,
  contextWindowTokens = contextWindowTokens,
  maximumOutputTokens = maximumOutputTokens,
  supportsImages = supportsImages,
  isCustom = isCustom,
  isDiscovered = isDiscovered,
)

internal fun ProjectEntity.toModel() = Project(
  id = id,
  name = name,
  instructions = instructions,
  isArchived = isArchived,
  defaultModel = choiceOf(defaultProviderId, defaultModelId),
  createdAt = createdAt,
  updatedAt = updatedAt,
)

internal fun ConversationEntity.toModel() = Conversation(
  id = id,
  title = title,
  projectId = projectId,
  systemPrompt = systemPrompt,
  model = choiceOf(modelProviderId, modelId),
  draft = draft,
  isArchived = isArchived,
  webSearchEnabled = webSearchEnabled,
  createdAt = createdAt,
  updatedAt = updatedAt,
)

private val WHITESPACE = Regex("\\s+")

internal fun ConversationSummaryRow.toModel(): ConversationSummary {
  val draftOnly = !hasMessages
  val preview = (if (draftOnly) draftPreview else lastMessagePreview.orEmpty())
    .replace(WHITESPACE, " ")
    .trim()
  return ConversationSummary(
    id = id,
    title = title,
    projectId = projectId,
    projectName = projectName,
    preview = preview,
    updatedAt = updatedAt,
    isArchived = isArchived,
    hasDraftOnly = draftOnly,
  )
}

internal fun roleOf(raw: String): ChatRole = ChatRole.entries.firstOrNull { it.rawValue == raw } ?: ChatRole.ASSISTANT

internal fun statusOf(raw: String): MessageStatus =
  MessageStatus.entries.firstOrNull { it.name == raw } ?: MessageStatus.FAILED

internal fun AttachmentEntity.toModel() = Attachment(
  id = id,
  kind = AttachmentKind.entries.firstOrNull { it.name == kind } ?: AttachmentKind.TEXT,
  fileName = fileName,
  mimeType = mimeType,
  extractedText = extractedText,
  imageBase64 = imageBase64,
)

internal fun MessageEntity.toModel(attachments: List<Attachment>, receipt: ContextReceipt?) = Message(
  id = id,
  conversationId = conversationId,
  role = roleOf(role),
  content = content,
  status = statusOf(status),
  errorMessage = errorMessage,
  createdAt = createdAt,
  providerKind = providerKind?.let(ProviderKind::fromRawId),
  providerName = providerName,
  modelId = modelId,
  destinationHost = destinationHost,
  inputTokens = inputTokens,
  outputTokens = outputTokens,
  retryOfMessageId = retryOfMessageId,
  attachments = attachments,
  citations = Codecs.decodeCitations(citationsJson),
  receipt = receipt,
)

internal fun scopeOf(raw: String): MemoryScope =
  MemoryScope.entries.firstOrNull { it.name == raw } ?: MemoryScope.CONVERSATION

internal fun MemoryFactEntity.toModel() = MemoryFact(
  id = id,
  title = title,
  content = content,
  scope = scopeOf(scope),
  projectId = projectId,
  conversationId = conversationId,
  isEnabled = isEnabled,
  createdAt = createdAt,
  updatedAt = updatedAt,
)

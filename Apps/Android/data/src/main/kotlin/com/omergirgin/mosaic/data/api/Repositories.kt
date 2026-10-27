package com.omergirgin.mosaic.data.api

import android.net.Uri
import com.omergirgin.mosaic.core.chat.DiscoveredModel
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.data.backup.LibraryBackupRepository
import com.omergirgin.mosaic.data.branching.ConversationAlternativesRepository
import com.omergirgin.mosaic.data.connections.ConnectionsRepository
import com.omergirgin.mosaic.data.documents.DocumentChunkPreview
import com.omergirgin.mosaic.data.documents.DocumentDeletionListener
import com.omergirgin.mosaic.data.documents.DocumentImportListener
import com.omergirgin.mosaic.data.documents.DocumentImportProgress
import com.omergirgin.mosaic.data.documents.DocumentSummary
import com.omergirgin.mosaic.data.embeddings.DocumentIndexHealth
import com.omergirgin.mosaic.data.embeddings.DocumentIndexingStatus
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfile
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfileDraft
import com.omergirgin.mosaic.data.live.LiveTranscriptionCredential
import com.omergirgin.mosaic.data.live.LiveTranscriptionTarget
import com.omergirgin.mosaic.data.memory.AutomaticMemoryRepository
import com.omergirgin.mosaic.data.model.AppSettings
import com.omergirgin.mosaic.data.model.Attachment
import com.omergirgin.mosaic.data.model.ChatNotice
import com.omergirgin.mosaic.data.model.Conversation
import com.omergirgin.mosaic.data.model.ConversationSummary
import com.omergirgin.mosaic.data.model.GenerationOutcome
import com.omergirgin.mosaic.data.model.UsageCategorySummary
import com.omergirgin.mosaic.data.pricing.ModelPriceRepository
import com.omergirgin.mosaic.data.share.SharedItemsRepository
import com.omergirgin.mosaic.data.tasks.ScheduledTaskRepository
import com.omergirgin.mosaic.data.model.MemoryFact
import com.omergirgin.mosaic.data.model.MemoryScope
import com.omergirgin.mosaic.data.model.Message
import com.omergirgin.mosaic.data.model.ModelChoice
import com.omergirgin.mosaic.data.model.ModelOption
import com.omergirgin.mosaic.data.model.Project
import com.omergirgin.mosaic.data.model.ProviderConfig
import com.omergirgin.mosaic.data.model.ProviderDraft
import com.omergirgin.mosaic.data.model.ProviderModel
import com.omergirgin.mosaic.data.model.UsageSummary
import com.omergirgin.mosaic.data.temporary.TemporaryChatService
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow

interface ProviderRepository {
  fun observeProviders(): Flow<List<ProviderConfig>>
  fun observeProvider(id: String): Flow<ProviderConfig?>
  /** Saved catalog rows (enabled + customized + discovered). Suggestions are merged by the UI. */
  fun observeModels(providerId: String): Flow<List<ProviderModel>>
  /** Enabled models on enabled, chat-capable connections, sorted favorites → provider → model. */
  fun observeModelOptions(): Flow<List<ModelOption>>

  /** Validates the endpoint (HTTPS unless local network), stores the key bound to the endpoint. */
  suspend fun saveProvider(draft: ProviderDraft): ProviderConfig
  suspend fun deleteProvider(id: String)
  suspend fun setProviderEnabled(id: String, enabled: Boolean)
  /** Replaces the saved catalog rows for a provider (Manage Models → Save). */
  suspend fun saveModels(providerId: String, models: List<ProviderModel>)
  /** Live discovery where the preset supports it; newly discovered models stay disabled. */
  suspend fun discoverModels(providerId: String): List<DiscoveredModel>
  /** Sends a tiny request to verify key + endpoint + model. Returns a human-readable result. */
  suspend fun testConnection(providerId: String, modelId: String): Result<String>
  /** Resolves the endpoint-bound key. Throws ProviderException(MISSING_API_KEY) when required and absent. */
  suspend fun connection(choice: ModelChoice): ProviderConnection
}

interface ConversationRepository {
  /** Non-empty chats (messages, nonblank draft) only; [query] filters title + message text. */
  fun observeConversations(query: String = "", archived: Boolean = false, projectId: String? = null): Flow<List<ConversationSummary>>
  fun observeConversation(id: String): Flow<Conversation?>
  fun observeMessages(conversationId: String): Flow<List<Message>>

  /** Model defaults: explicit → project override → app default → most recent enabled. */
  suspend fun createConversation(projectId: String? = null, model: ModelChoice? = null): Conversation
  suspend fun updateDraft(id: String, draft: String)
  suspend fun rename(id: String, title: String)
  suspend fun setModel(id: String, choice: ModelChoice)
  suspend fun setSystemPrompt(id: String, prompt: String?)
  suspend fun setWebSearch(id: String, enabled: Boolean)
  /** Blocked (throws IllegalStateException) while a generation is running for the chat. */
  suspend fun moveToProject(id: String, projectId: String?)
  suspend fun setArchived(id: String, archived: Boolean)
  suspend fun delete(id: String)
  suspend fun deleteMessage(messageId: String)
}

interface ChatEngine {
  /** Conversation IDs with an in-flight generation. */
  val activeGenerations: StateFlow<Set<String>>

  /**
   * Persists the user message, plans context within the selected model limits (never truncating
   * a message; current + two newest completed turns preserved), streams the answer with
   * checkpointed persistence, records usage and a context receipt. Returns immediately; work runs
   * in the application scope so navigation does not cancel a paid request.
   */
  fun send(conversationId: String, text: String, attachments: List<Attachment> = emptyList())
  fun stop(conversationId: String)
  /** Appends a new assistant attempt for the user turn answered by [assistantMessageId]. */
  fun retry(conversationId: String, assistantMessageId: String)

  /**
   * Requests that were rejected before anything was persisted or sent (show as a snackbar). Hot;
   * collect while the chat screen is visible.
   */
  val notices: Flow<ChatNotice> get() = emptyFlow()

  /**
   * The [send] pipeline for unattended callers (scheduled prompts): same persistence, context,
   * receipt and usage, but suspends until the reply is terminal and returns the outcome instead of
   * posting a notice. Cancelling the caller does not cancel the request; it still finishes in the
   * application scope. Only [stop] (or deleting the chat) ends it early.
   */
  suspend fun runAndAwait(conversationId: String, text: String): GenerationOutcome
}

interface ProjectRepository {
  fun observeProjects(includeArchived: Boolean = false): Flow<List<Project>>
  fun observeProject(id: String): Flow<Project?>
  suspend fun saveProject(id: String?, name: String, instructions: String, defaultModel: ModelChoice?): Project
  suspend fun setArchived(id: String, archived: Boolean)
  suspend fun delete(id: String)
}

interface MemoryRepository {
  fun observeFacts(): Flow<List<MemoryFact>>
  suspend fun saveFact(fact: MemoryFact)
  suspend fun deleteFact(id: String)
  /** "Save to memory" from a message. */
  suspend fun saveFromMessage(messageId: String)
  /** "Save to memory" with an explicit audience (iOS offers Everywhere / project / this chat). */
  suspend fun saveFromMessage(messageId: String, scope: MemoryScope) = saveFromMessage(messageId)
  /** Facts visible to a conversation (Everywhere + its project + itself), enabled only. */
  suspend fun factsFor(conversationId: String, projectId: String?): List<MemoryFact>
}

interface SettingsRepository {
  val settings: Flow<AppSettings>
  suspend fun setDefaultModel(choice: ModelChoice?)
  suspend fun setAdvancedControls(enabled: Boolean)
  suspend fun toggleFavorite(choice: ModelChoice)
  suspend fun recordRecent(choice: ModelChoice)
  suspend fun setOnboardingCompleted(done: Boolean)
  /** Global automatic-memory switch (on by default). Existing learned topics stay recallable. */
  suspend fun setAutomaticMemoryEnabled(enabled: Boolean)
  /** Smart memory relevance check with the selected chat model (on by default, device-local). */
  suspend fun setSmartMemoryEnabled(enabled: Boolean)
}

/**
 * Imported documents (PDF with on-device OCR, Markdown, plain text) and their page-aware chunks.
 * Unlinked documents are available everywhere; linked ones only in their project.
 */
interface DocumentRepository {
  /** Newest first, with chunk counts, OCR/fallback page counts and project labels. */
  fun observeDocuments(): Flow<List<DocumentSummary>>
  fun observeDocument(id: String): Flow<DocumentSummary?>
  /** First [limit] chunks in order (read-only preview). */
  suspend fun previewChunks(id: String, limit: Int = 5): List<DocumentChunkPreview>

  /**
   * Cold flow: collecting it runs one sequential extract-and-commit batch (at most 8 files,
   * 50 MiB each, 100 MiB total) into [projectId] (null = Everywhere). Cancelling the collector
   * is Stop: already committed documents stay, and the last emitted tally is the honest partial
   * result. Batch-level problems (too many/too large files, unavailable project, another import
   * running) fail the flow; per-file problems are reported in the tally.
   */
  fun importDocuments(
    uris: List<Uri>,
    projectId: String?,
  ): Flow<DocumentImportProgress>

  suspend fun rename(id: String, title: String)
  suspend fun setEnabled(id: String, enabled: Boolean)
  /** null = Everywhere. Blocked (IllegalStateException) while an import or chat request runs. */
  suspend fun moveToProject(id: String, projectId: String?)
  /** Deletes the document and its chunks, then notifies deletion listeners. Same blocking rule as moves. */
  suspend fun delete(id: String)

  /** Seam for retrieval: drop derived vectors for deleted chunks. */
  fun addDeletionListener(listener: DocumentDeletionListener)
  /** Seam for retrieval: backfill vectors for newly committed documents. */
  fun addImportListener(listener: DocumentImportListener)
}

interface UsageRepository {
  /** Reported-token totals grouped by provider/model since [sinceMillis]. */
  fun observeUsage(sinceMillis: Long): Flow<List<UsageSummary>>
  /** The same records grouped by request category (chat, summaries, memory, embeddings, ...). */
  fun observeUsageByCategory(sinceMillis: Long): Flow<List<UsageCategorySummary>>
}

/** Manual DI root exposed to the UI. Implemented by the data layer (`DataContainer.create`). */
interface AppContainer {
  val providers: ProviderRepository
  val conversations: ConversationRepository
  val chat: ChatEngine
  val projects: ProjectRepository
  val memory: MemoryRepository
  val settings: SettingsRepository
  val usage: UsageRepository
  val documents: DocumentRepository
  /** Scheduled prompts (Automations). */
  val tasks: ScheduledTaskRepository
  /** Embedding profiles for smart recall and the rebuildable document-vector index. */
  val embeddingProfiles: EmbeddingProfileRepository
  /** Learned topics/events, their sources and history, and formation activity. */
  val automaticMemory: AutomaticMemoryRepository
  /** Custom per-model rates for Usage & cost (special tariffs; "Return to default"). */
  val prices: ModelPriceRepository
  /** Edit-and-branch alternatives ("Edit", "Ask another model", Alternatives list). */
  val alternatives: ConversationAlternativesRepository
  /** Temporary Chat requests; the session itself lives only in the caller's memory. */
  val temporaryChat: TemporaryChatService
  /** Local queue of content received from the system share sheet (Shared items). */
  val sharedItems: SharedItemsRepository
  /** The Google Gemini connection and key used for Gemini Live dictation. */
  val liveTranscription: LiveTranscriptionRepository
  /** Device-direct connections catalog, chat access, action reviews and per-answer activity. */
  val connections: ConnectionsRepository
  /** Portable `.mosaicbackup` export and verified restore (Data & Recovery). */
  val backup: LibraryBackupRepository
}

/**
 * Gemini Live dictation uses an enabled Google Gemini connection whose destination is exactly
 * Google's HTTPS Gemini origin, independent of the chat provider selected for the conversation.
 */
interface LiveTranscriptionRepository {
  /** The chat-selected connection when eligible, else the first eligible one; null when none. Reads no key. */
  suspend fun eligibleConnection(preferredProviderId: String?): LiveTranscriptionTarget?
  /** Re-validates eligibility and reads the endpoint-bound key; throws ProviderException otherwise. */
  suspend fun resolveCredential(providerId: String): LiveTranscriptionCredential
}

/**
 * Up to four enabled embedding profiles add semantic ranking to the always-available local
 * hybrid recall. Each profile is an isolated vector space; enabled profiles receive the recall
 * query and selected chat/document excerpts.
 */
interface EmbeddingProfileRepository {
  /** Most recently updated first. */
  fun observeProfiles(): Flow<List<EmbeddingProfile>>

  /**
   * Validates and saves; enabling a fifth profile throws IllegalStateException with
   * `EmbeddingProfilePolicy.LIMIT_DESCRIPTION`. An enabled document profile starts a backfill.
   */
  suspend fun saveProfile(draft: EmbeddingProfileDraft): EmbeddingProfile
  suspend fun setProfileEnabled(id: String, enabled: Boolean)
  /** Deletes the profile and its cached vectors; returns a warning when the cache could not be cleared. */
  suspend fun deleteProfile(id: String): String?

  /** Current/missing/stale/orphaned document vectors per active profile (bounded scans). */
  suspend fun documentIndexHealth(): DocumentIndexHealth
  /** Background backfill/rebuild progress and last result. */
  val documentIndexing: StateFlow<DocumentIndexingStatus>
  /** Embeds missing vectors for every enabled document (application scope; one at a time). */
  fun backfillDocuments()
  /** Clears active-profile document vectors and dangling entries, then re-embeds enabled documents. */
  fun rebuildDocumentIndex()
  /** Backfills specific documents (e.g. right after import); returns warnings. Never throws for provider failures. */
  suspend fun indexDocuments(documentIds: Collection<String>): List<String>
}

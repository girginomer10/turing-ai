package com.omergirgin.mosaic.data

import android.content.Context
import android.util.Log
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.preferencesDataStoreFile
import com.omergirgin.mosaic.data.api.AppContainer
import com.omergirgin.mosaic.data.api.ChatEngine
import com.omergirgin.mosaic.data.api.ConversationRepository
import com.omergirgin.mosaic.data.api.DocumentRepository
import com.omergirgin.mosaic.data.api.LiveTranscriptionRepository
import com.omergirgin.mosaic.data.backup.LibraryBackupRepository
import com.omergirgin.mosaic.data.backup.LibraryBackupRepositoryImpl
import com.omergirgin.mosaic.data.branching.ConversationAlternativesRepository
import com.omergirgin.mosaic.data.branching.ConversationAlternativesRepositoryImpl
import com.omergirgin.mosaic.data.connections.ConnectionsRepository
import com.omergirgin.mosaic.data.connections.ConnectionsRepositoryImpl
import com.omergirgin.mosaic.data.documents.DocumentRepositoryImpl
import com.omergirgin.mosaic.data.api.MemoryRepository
import com.omergirgin.mosaic.data.api.ProjectRepository
import com.omergirgin.mosaic.data.api.ProviderRepository
import com.omergirgin.mosaic.data.api.SettingsRepository
import com.omergirgin.mosaic.data.api.UsageRepository
import com.omergirgin.mosaic.data.chat.ChatEngineImpl
import com.omergirgin.mosaic.data.api.EmbeddingProfileRepository
import com.omergirgin.mosaic.data.embeddings.DocumentIndexer
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfileRepositoryImpl
import com.omergirgin.mosaic.data.embeddings.EmbeddingProfileResolver
import com.omergirgin.mosaic.data.embeddings.EmbeddingUsageRecorder
import com.omergirgin.mosaic.data.index.SemanticVectorStore
import com.omergirgin.mosaic.data.live.LiveTranscriptionRepositoryImpl
import com.omergirgin.mosaic.data.memory.AutomaticMemoryFormation
import com.omergirgin.mosaic.data.memory.AutomaticMemoryRecallSource
import com.omergirgin.mosaic.data.memory.AutomaticMemoryRepository
import com.omergirgin.mosaic.data.memory.AutomaticMemoryRepositoryImpl
import com.omergirgin.mosaic.data.pricing.ModelPriceRepository
import com.omergirgin.mosaic.data.pricing.ModelPriceRepositoryImpl
import com.omergirgin.mosaic.data.recall.DocumentRecallSource
import com.omergirgin.mosaic.data.recall.MessageRecallSource
import com.omergirgin.mosaic.data.recall.RecallCoordinator
import com.omergirgin.mosaic.data.recall.RecallSourceRegistry
import com.omergirgin.mosaic.data.chat.GenerationRegistry
import com.omergirgin.mosaic.data.compaction.CompactionStore
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.recall.SmartMemoryRecall
import com.omergirgin.mosaic.data.repo.ConversationRepositoryImpl
import com.omergirgin.mosaic.data.repo.MemoryRepositoryImpl
import com.omergirgin.mosaic.data.repo.ProjectRepositoryImpl
import com.omergirgin.mosaic.data.repo.ProviderRepositoryImpl
import com.omergirgin.mosaic.data.repo.UsageRepositoryImpl
import com.omergirgin.mosaic.data.security.SecretStore
import com.omergirgin.mosaic.data.settings.DataStoreSettingsRepository
import com.omergirgin.mosaic.data.share.SharedItemsRepository
import com.omergirgin.mosaic.data.share.SharedItemsRepositoryImpl
import com.omergirgin.mosaic.data.tasks.ScheduledTaskRepository
import com.omergirgin.mosaic.data.tasks.ScheduledTaskRepositoryImpl
import com.omergirgin.mosaic.data.temporary.TemporaryChatService
import com.omergirgin.mosaic.data.temporary.TemporaryChatServiceImpl
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Process-wide data root (manual DI). Created once from `Application`; every call returns the same
 * instance so there is exactly one Room database, one DataStore and one generation registry.
 */
object DataContainer {
  @Volatile private var instance: AppContainer? = null

  fun create(context: Context): AppContainer =
    instance ?: synchronized(this) { instance ?: build(context.applicationContext).also { instance = it } }

  private const val TAG = "TuringData"
  private const val INTERRUPTED_MESSAGE =
    "Turing AI was interrupted before this response finished. You can try this request again."

  private fun build(context: Context): AppContainer {
    val processStartedAt = System.currentTimeMillis()
    // Application scope: outlives screens so a paid request is never cancelled by navigation.
    // Failures are already persisted on their rows; only the type is logged (never content).
    val scope = CoroutineScope(
      SupervisorJob() + Dispatchers.Default +
        CoroutineExceptionHandler { _, error -> Log.w(TAG, "Background data task failed (${error.javaClass.simpleName}).") }
    )

    val database = MosaicDatabase.open(context)
    val secrets = SecretStore(context)
    val settings = DataStoreSettingsRepository(
      PreferenceDataStoreFactory.create(
        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
        produceFile = { context.preferencesDataStoreFile("turing_settings") },
      )
    )
    val registry = GenerationRegistry()
    val providers = ProviderRepositoryImpl(database, secrets, settings)

    // Process-death repair, exactly once per process and before any generation can start: no
    // request survives its process, so every STREAMING row left on disk is an orphan.
    val ready = scope.launch {
      runCatching { database.messages().failInterrupted(INTERRUPTED_MESSAGE, MonotonicClock.now()) }
      // Same repair for history-summary attempts: a dangling "generating" audit gets one "failed".
      runCatching { CompactionStore(database).reconcileInterrupted() }
    }
    // Blank chats from earlier sessions are not history entries; sweep them after the repair.
    scope.launch {
      ready.join()
      runCatching { database.conversations().deleteAbandoned(before = processStartedAt) }
    }

    // Smart recall: built-in earlier-chat and document sources; other features register more
    // (e.g. learned topics) with `recallSources.register(...)` before the first request.
    val recallSources = RecallSourceRegistry().apply {
      register(MessageRecallSource(database.recall(), this))
      register(DocumentRecallSource(database.recall()))
    }
    // Automatic memory: learned topics join recall, their evidence messages are suppressed from
    // raw recall, and interrupted formation attempts are reconciled once at startup.
    val automaticMemory = AutomaticMemoryFormation(database, providers, settings, scope)
      .also { it.startRecovery(ready) }
    val learnedTopicSource = AutomaticMemoryRecallSource(database).also { learnedTopics ->
      recallSources.register(learnedTopics)
      recallSources.messageSuppression = learnedTopics
    }
    // Rebuildable vector cache; opened lazily only when an embedding profile actually runs.
    val vectorStore = SemanticVectorStore(context)
    val embeddingResolver = EmbeddingProfileResolver(database, providers)
    val embeddingUsage = EmbeddingUsageRecorder(database)
    val recallCoordinator = RecallCoordinator(
      database, recallSources, embeddingResolver, vectorStore, embeddingUsage,
      // Smart memory: one bounded relevance request with the chat's model (device-local toggle).
      smartMemory = SmartMemoryRecall(
        database,
        enabled = { settings.settings.first().smartMemoryEnabled },
      ),
    )
    val embeddingProfiles = EmbeddingProfileRepositoryImpl(
      database,
      vectorStore,
      DocumentIndexer(database, embeddingResolver, vectorStore, embeddingUsage),
      scope,
    )

    val conversations = ConversationRepositoryImpl(
      database, providers, registry,
      // Derived vectors of a deleted chat's messages and chat-scoped topics, after the commit.
      afterConversationDeleted = { messageIds, topicIds -> embeddingProfiles.dropConversationVectors(messageIds, topicIds) },
    )
    // Device-direct connections (no relay server); the engine runs chat-time research through it.
    val connections = ConnectionsRepositoryImpl(context, database, scope)
    val chat = ChatEngineImpl(
      database, providers, settings, registry, scope, ready, recall = recallCoordinator,
      automaticMemory = automaticMemory,
      recordTopicUse = learnedTopicSource::recordUse,
      connectors = connections.chat,
    )

    val tasks = ScheduledTaskRepositoryImpl(context, database, providers, conversations, chat, scope, ready)
    // Portable backup: refuses to run beside provider work; restore re-syncs automation schedules.
    val backup = LibraryBackupRepositoryImpl(
      context, database, secrets, vectorStore,
      busyCheck = {
        if (registry.active.value.isNotEmpty() || tasks.activity.first().isNotEmpty()) {
          "Finish or stop active requests and data operations before creating or restoring a backup."
        } else {
          null
        }
      },
      afterRestore = { tasks.reconcileSchedule() },
    )

    return Container(
      providers = providers,
      conversations = conversations,
      chat = chat,
      tasks = tasks,
      projects = ProjectRepositoryImpl(database),
      memory = MemoryRepositoryImpl(database),
      settings = settings,
      usage = UsageRepositoryImpl(database),
      documents = DocumentRepositoryImpl(context, database, scope, isChatBusy = { registry.active.value.isNotEmpty() }),
      embeddingProfiles = embeddingProfiles,
      automaticMemory = AutomaticMemoryRepositoryImpl(database, automaticMemory),
      prices = ModelPriceRepositoryImpl(database),
      alternatives = ConversationAlternativesRepositoryImpl(database),
      // Never writes chats, usage, receipts, recall or memory: Temporary Chat stays in memory.
      temporaryChat = TemporaryChatServiceImpl(providers),
      sharedItems = SharedItemsRepositoryImpl(context, database, providers),
      liveTranscription = LiveTranscriptionRepositoryImpl(database, secrets),
      connections = connections,
      backup = backup,
    ).also { container ->
      // Keep the derived document-vector cache in step with imports and deletions.
      container.documents.addImportListener { ids -> embeddingProfiles.indexDocuments(ids) }
      container.documents.addDeletionListener { deletion -> embeddingProfiles.dropDocumentVectors(deletion.chunkIds) }
    }
  }

  private class Container(
    override val providers: ProviderRepository,
    override val conversations: ConversationRepository,
    override val chat: ChatEngine,
    override val tasks: ScheduledTaskRepository,
    override val projects: ProjectRepository,
    override val memory: MemoryRepository,
    override val settings: SettingsRepository,
    override val usage: UsageRepository,
    override val documents: DocumentRepository,
    override val embeddingProfiles: EmbeddingProfileRepository,
    override val automaticMemory: AutomaticMemoryRepository,
    override val prices: ModelPriceRepository,
    override val alternatives: ConversationAlternativesRepository,
    override val temporaryChat: TemporaryChatService,
    override val sharedItems: SharedItemsRepository,
    override val liveTranscription: LiveTranscriptionRepository,
    override val connections: ConnectionsRepository,
    override val backup: LibraryBackupRepository,
  ) : AppContainer
}

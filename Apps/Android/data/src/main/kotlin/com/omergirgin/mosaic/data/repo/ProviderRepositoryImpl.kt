package com.omergirgin.mosaic.data.repo

import androidx.room.withTransaction
import com.omergirgin.mosaic.core.chat.ChatMessage
import com.omergirgin.mosaic.core.chat.ChatRequest
import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.core.chat.CredentialBinding
import com.omergirgin.mosaic.core.chat.DiscoveredModel
import com.omergirgin.mosaic.core.chat.ProviderClientFactory
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import com.omergirgin.mosaic.core.chat.ProviderException
import com.omergirgin.mosaic.core.chat.StreamEvent
import com.omergirgin.mosaic.core.chat.TokenUsage
import com.omergirgin.mosaic.core.context.ContextLimitsSource
import com.omergirgin.mosaic.core.context.utf8Length
import com.omergirgin.mosaic.core.net.ModelCatalogSupport
import com.omergirgin.mosaic.core.provider.BundledModelCatalog
import com.omergirgin.mosaic.core.provider.ModelLimits
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.displayName
import com.omergirgin.mosaic.core.provider.profile
import com.omergirgin.mosaic.core.provider.supportsChat
import com.omergirgin.mosaic.core.provider.supportsModelDiscovery
import com.omergirgin.mosaic.data.api.ProviderRepository
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.ProviderEntity
import com.omergirgin.mosaic.data.db.ProviderModelEntity
import com.omergirgin.mosaic.data.db.UsageRecordEntity
import com.omergirgin.mosaic.data.db.toEntity
import com.omergirgin.mosaic.data.db.toModel
import com.omergirgin.mosaic.data.internal.EndpointValidation
import com.omergirgin.mosaic.data.internal.ErrorSanitizer
import com.omergirgin.mosaic.data.internal.FieldLimits
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.internal.newId
import com.omergirgin.mosaic.data.model.ModelChoice
import com.omergirgin.mosaic.data.model.ModelOption
import com.omergirgin.mosaic.data.model.ProviderConfig
import com.omergirgin.mosaic.data.model.ProviderDraft
import com.omergirgin.mosaic.data.model.ProviderModel
import com.omergirgin.mosaic.data.security.SecretStore
import com.omergirgin.mosaic.data.security.StoredKey
import com.omergirgin.mosaic.data.settings.DataStoreSettingsRepository
import java.io.IOException
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext

/** Everything the engine needs to know about one exact provider/model before a request. */
internal data class ResolvedModel(
  val provider: ProviderEntity,
  val kind: ProviderKind,
  val modelId: String,
  val limits: ModelLimits,
  val limitsSource: ContextLimitsSource,
  val supportsImages: Boolean,
) {
  val choice: ModelChoice get() = ModelChoice(provider.id, modelId)
  val destinationHost: String? get() = connectionWithoutKey().destinationHost

  fun connectionWithoutKey() = ProviderConnection(
    id = provider.id,
    displayName = provider.displayName,
    provider = kind,
    baseUrl = provider.baseUrl,
    modelId = modelId,
    contextWindowTokens = limits.contextWindowTokens,
    maximumOutputTokens = limits.maximumOutputTokens,
  )
}

internal class ProviderRepositoryImpl(
  private val db: MosaicDatabase,
  private val secrets: SecretStore,
  private val settings: DataStoreSettingsRepository,
) : ProviderRepository {
  private val dao = db.providers()

  override fun observeProviders(): Flow<List<ProviderConfig>> =
    combine(dao.observeAll(), secrets.changes) { rows, _ -> rows.map(::toConfig) }
      .distinctUntilChanged()
      // hasApiKey reads SharedPreferences; keep that off the collector (often main) thread.
      .flowOn(Dispatchers.Default)

  override fun observeProvider(id: String): Flow<ProviderConfig?> =
    combine(dao.observe(id), secrets.changes) { row, _ -> row?.let(::toConfig) }
      .distinctUntilChanged()
      .flowOn(Dispatchers.Default)

  override fun observeModels(providerId: String): Flow<List<ProviderModel>> =
    dao.observeModels(providerId).map { rows -> rows.map { it.toModel() } }.distinctUntilChanged()

  override fun observeModelOptions(): Flow<List<ModelOption>> =
    combine(dao.observeAll(), dao.observeEnabledModels(), settings.settings) { providers, models, appSettings ->
      buildOptions(providers, models, appSettings.favorites)
    }.distinctUntilChanged().flowOn(Dispatchers.Default)

  /** Current picker options (enabled models on enabled chat providers). */
  suspend fun currentOptions(): List<ModelOption> = observeModelOptions().first()

  override suspend fun saveProvider(draft: ProviderDraft): ProviderConfig {
    val kind = draft.kind
    val baseUrl = draft.baseUrl?.trim()?.takeIf { it.isNotEmpty() }
    if (baseUrl != null) {
      EndpointValidation.validate(baseUrl)
    } else if (kind.profile.baseUrl == null) {
      throw ProviderException(
        ProviderErrorKind.INVALID_ENDPOINT,
        "Enter the base URL for your ${kind.displayName} resource.",
      )
    }
    val displayName = draft.displayName.trim().ifEmpty { kind.displayName }
    FieldLimits.requireWithin(displayName, FieldLimits.PROJECT_NAME_BYTES, "The connection name")

    val existing = draft.id?.let { dao.get(it) }
    require(draft.id == null || existing != null) { "This provider connection no longer exists." }
    val id = existing?.id ?: newId()
    val newBinding = CredentialBinding.of(kind, baseUrl ?: kind.profile.baseUrl)
    val destinationChanged = existing != null && bindingOf(existing) != newBinding
    val kindChanged = existing != null && kindOf(existing) != kind

    val newKey = draft.apiKey?.trim()?.takeIf { it.isNotEmpty() }
    val removeKey = draft.apiKey != null && newKey == null
    if (kind.profile.requiresApiKey && newKey == null && (existing == null || !removeKey)) {
      when {
        existing == null -> throw missingKey("Enter an API key for this provider. It is stored encrypted on this device.")
        // A key authorized for one destination is never carried to another (iOS parity).
        destinationChanged -> throw missingKey("The provider address changed. Re-enter the API key for the new destination.")
        !secrets.hasKey(id, newBinding) -> throw missingKey("Enter an API key for this provider. It is stored encrypted on this device.")
      }
    }

    val now = MonotonicClock.now()
    val entity = ProviderEntity(
      id = id,
      kind = kind.rawId,
      displayName = displayName,
      baseUrl = baseUrl,
      isEnabled = draft.isEnabled,
      createdAt = existing?.createdAt ?: now,
      updatedAt = now,
    )

    // Write the credential first, then commit metadata; on failure restore the exact prior bytes.
    val credentialChanged = newKey != null || removeKey || destinationChanged
    val previousCredential = if (credentialChanged) secrets.snapshot(id) else null
    when {
      newKey != null -> secrets.write(id, newKey, newBinding)
      removeKey || destinationChanged -> secrets.remove(id)
    }
    try {
      db.withTransaction {
        if (existing == null) dao.insert(entity) else dao.upsert(entity)
        if (existing == null || kindChanged) {
          // Changing the provider type resets its models together with endpoint and key.
          dao.deleteModels(id)
          dao.upsertModels(initialModels(kind, draft.initialModels).map { it.toEntity(id) })
        }
      }
    } catch (error: Throwable) {
      if (previousCredential != null) {
        withContext(NonCancellable) { runCatching { secrets.restore(id, previousCredential) } }
      }
      throw error
    }
    return toConfig(entity)
  }

  override suspend fun deleteProvider(id: String) {
    db.withTransaction {
      dao.clearConversationChoices(id)
      dao.clearProjectChoices(id)
      dao.delete(id)
    }
    // Only after the metadata delete committed: a failed delete must not orphan a usable row
    // without its key. Not cancellable so a committed delete never leaves a key behind.
    withContext(NonCancellable) {
      secrets.remove(id)
      runCatching { settings.forgetProvider(id) }
    }
  }

  override suspend fun setProviderEnabled(id: String, enabled: Boolean) {
    dao.setEnabled(id, enabled, MonotonicClock.now())
  }

  override suspend fun saveModels(providerId: String, models: List<ProviderModel>) {
    requireNotNull(dao.get(providerId)) { "This provider connection no longer exists." }
    val rows = models
      .map { it.toEntity(providerId) }
      .onEach(::validate)
      .associateBy { it.modelId } // last row wins for duplicate IDs
      .values
      .toList()
    db.withTransaction {
      dao.deleteModels(providerId)
      dao.upsertModels(rows)
    }
  }

  override suspend fun discoverModels(providerId: String): List<DiscoveredModel> {
    val provider = requireNotNull(dao.get(providerId)) { "This provider connection no longer exists." }
    val kind = kindOf(provider)
    if (!kind.supportsModelDiscovery) {
      throw ProviderException(
        ProviderErrorKind.MODEL_CATALOG_UNAVAILABLE,
        "This provider does not publish a compatible model catalog. Enter an exact model ID instead.",
      )
    }
    val saved = dao.models(providerId)
    val anyModel = saved.firstOrNull { it.isEnabled }?.modelId ?: BundledModelCatalog.defaultModel(kind)
    val keyless = connectionFor(provider, kind, anyModel, null, null)
    // AI/ML API's public catalog is fetched without a credential, so no key is read for it.
    val key = if (ModelCatalogSupport.usesUnauthenticatedPublicCatalog(keyless)) {
      null
    } else {
      keyFor(provider, kind, required = kind.profile.requiresApiKey)
    }
    val connection = keyless.copy(apiKey = key)
    val discovered = try {
      ProviderClientFactory.make(connection).listModels()
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      throw sanitized(error, key)
    }

    // Merge: new IDs are added disabled (discovery never enables a model or grants access).
    val existing = saved.associateBy { it.modelId }
    val updates = discovered
      .asSequence()
      .filter { isValidModelId(it.id) }
      .distinctBy { it.id }
      .take(MAX_DISCOVERED_MODELS)
      .mapNotNull { model ->
        val current = existing[model.id]
        when {
          current == null -> {
            // Discovery-reported limits are exact for this account; only keep them when the
            // bundled catalog has no documented values for the ID.
            val documented = BundledModelCatalog.documentedLimits(kind, model.id)
            ProviderModelEntity(
              providerId = providerId,
              modelId = model.id,
              isEnabled = false,
              contextWindowTokens = if (documented == null) model.contextWindowTokens?.takeIf { it > 0 } else null,
              maximumOutputTokens = if (documented == null) model.maximumOutputTokens?.takeIf { it > 0 } else null,
              supportsImages = null,
              isCustom = false,
              isDiscovered = true,
            )
          }
          !current.isDiscovered -> current.copy(isDiscovered = true)
          else -> null
        }
      }
      .toList()
    if (updates.isNotEmpty()) dao.upsertModels(updates)
    return discovered
  }

  override suspend fun testConnection(providerId: String, modelId: String): Result<String> {
    var key: String? = null
    return try {
      val provider = requireNotNull(dao.get(providerId)) { "This provider connection no longer exists." }
      val kind = kindOf(provider)
      val model = modelId.trim()
      val keyless = connectionFor(provider, kind, model, null, null)

      // AI/ML API's public catalog proves reachability only; iOS says so instead of claiming the
      // key was verified, and never reads the key for it.
      if (kind.supportsModelDiscovery && ModelCatalogSupport.usesUnauthenticatedPublicCatalog(keyless)) {
        val listed = ProviderClientFactory.make(keyless).listModels()
        return Result.success(listingMessage(listed, model, keyVerified = false))
      }

      key = keyFor(provider, kind, required = kind.profile.requiresApiKey)
      val client = ProviderClientFactory.make(keyless.copy(apiKey = key))

      // iOS verifies a connection by listing models: free, and proves endpoint + key.
      if (kind.supportsModelDiscovery) {
        val listed = try {
          client.listModels()
        } catch (error: ProviderException) {
          if (error.kind != ProviderErrorKind.MODEL_CATALOG_UNAVAILABLE || model.isEmpty()) throw error
          null
        }
        if (listed != null) return Result.success(listingMessage(listed, model, keyVerified = true))
      }

      // No usable catalog: send one tiny request to the exact model instead.
      if (model.isEmpty()) throw ProviderException(ProviderErrorKind.MISSING_MODEL, "Enter or choose a model ID.")
      if (!kind.supportsChat) {
        throw ProviderException(
          ProviderErrorKind.CHAT_UNAVAILABLE,
          "This provider is configured for embeddings and cannot send chat messages.",
        )
      }
      Result.success(probe(provider, kind, model, key))
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      Result.failure(sanitized(error, key))
    }
  }

  override suspend fun connection(choice: ModelChoice): ProviderConnection {
    val resolved = resolveModel(choice)
    val key = keyFor(resolved.provider, resolved.kind, required = resolved.kind.profile.requiresApiKey)
    return resolved.connectionWithoutKey().copy(apiKey = key)
  }

  /**
   * Validates that [choice] is an enabled model on an enabled chat connection and resolves its
   * limits: per-field saved override, else the bundled exact-model-or-conservative policy.
   */
  suspend fun resolveModel(choice: ModelChoice): ResolvedModel {
    val unavailable = ProviderException(
      ProviderErrorKind.MISSING_MODEL,
      "This model is disabled or unavailable. Choose an enabled model, or enable it in Providers.",
    )
    val provider = dao.get(choice.providerId) ?: throw unavailable
    val kind = kindOf(provider)
    if (!kind.supportsChat) {
      throw ProviderException(
        ProviderErrorKind.CHAT_UNAVAILABLE,
        "This provider connection is for embeddings and cannot send chat messages.",
      )
    }
    val row = dao.model(provider.id, choice.modelId)
    if (!provider.isEnabled || row == null || !row.isEnabled || choice.modelId.isBlank()) throw unavailable
    return resolve(provider, kind, row)
  }

  /** Default chain: explicit → project override → app default → most recent → first option. */
  suspend fun defaultChoice(explicit: ModelChoice?, projectDefault: ModelChoice?): ModelChoice? {
    if (explicit != null) return explicit
    val options = currentOptions()
    val enabled = options.mapTo(HashSet()) { it.choice }
    val appSettings = settings.settings.first()
    return sequenceOf(projectDefault, appSettings.defaultModel).firstOrNull { it != null && it in enabled }
      ?: appSettings.recentModels.firstOrNull { it in enabled }
      ?: options.firstOrNull()?.choice
  }

  /** Reads the endpoint-bound key; fails closed with a re-entry message on any mismatch. */
  suspend fun keyFor(provider: ProviderEntity, kind: ProviderKind, required: Boolean): String? =
    when (val stored = secrets.read(provider.id, bindingOf(provider))) {
      is StoredKey.Present -> stored.apiKey
      StoredKey.Missing ->
        if (required) throw missingKey("Add an API key for this provider before sending a message.") else null
      StoredKey.BindingMismatch ->
        if (required) {
          throw missingKey(
            "The saved API key belongs to a different provider destination. Re-enter the key for this connection."
          )
        } else {
          null
        }
      StoredKey.Unreadable ->
        if (required) {
          throw missingKey("The saved API key can no longer be read on this device. Re-enter it in Providers.")
        } else {
          null
        }
    }

  // region helpers

  private fun buildOptions(
    providers: List<ProviderEntity>,
    models: List<ProviderModelEntity>,
    favorites: Set<ModelChoice>,
  ): List<ModelOption> {
    val usable = providers.filter { it.isEnabled && kindOf(it).supportsChat }.associateBy { it.id }
    return models
      .mapNotNull { row ->
        val provider = usable[row.providerId] ?: return@mapNotNull null
        if (!row.isEnabled || row.modelId.isBlank()) return@mapNotNull null
        val resolved = resolve(provider, kindOf(provider), row)
        ModelOption(
          choice = resolved.choice,
          providerKind = resolved.kind,
          providerName = provider.displayName,
          modelId = row.modelId,
          contextWindowTokens = resolved.limits.contextWindowTokens,
          maximumOutputTokens = resolved.limits.maximumOutputTokens,
          supportsImages = resolved.supportsImages,
          isFavorite = resolved.choice in favorites,
        )
      }
      .sortedWith(
        compareByDescending<ModelOption> { it.isFavorite }
          .thenBy(String.CASE_INSENSITIVE_ORDER) { it.providerName }
          .thenBy { it.choice.providerId }
          .thenBy(String.CASE_INSENSITIVE_ORDER) { it.modelId }
      )
  }

  private fun resolve(provider: ProviderEntity, kind: ProviderKind, row: ProviderModelEntity): ResolvedModel {
    val catalog = BundledModelCatalog.resolvedLimits(kind, row.modelId)
    val hasOverride = row.contextWindowTokens != null || row.maximumOutputTokens != null
    val source = when {
      hasOverride -> ContextLimitsSource.SAVED_OVERRIDE
      BundledModelCatalog.documentedLimits(kind, row.modelId) != null -> ContextLimitsSource.DOCUMENTED
      else -> ContextLimitsSource.CONSERVATIVE_FALLBACK
    }
    return ResolvedModel(
      provider = provider,
      kind = kind,
      modelId = row.modelId,
      limits = ModelLimits(
        contextWindowTokens = row.contextWindowTokens ?: catalog.contextWindowTokens,
        maximumOutputTokens = row.maximumOutputTokens ?: catalog.maximumOutputTokens,
      ),
      limitsSource = source,
      supportsImages = row.supportsImages ?: BundledModelCatalog.supportsImages(kind, row.modelId),
    )
  }

  private fun initialModels(kind: ProviderKind, requested: List<String>): List<ProviderModel> {
    if (!kind.supportsChat) return emptyList()
    val ids = requested.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
      .ifEmpty { listOf(BundledModelCatalog.defaultModel(kind)).filter { it.isNotBlank() } }
    val suggested = BundledModelCatalog.models(kind).toSet()
    return ids.map { id ->
      ProviderModel(providerId = "", modelId = id, isEnabled = true, isCustom = id !in suggested)
    }.onEach { validate(it.toEntity("")) }
  }

  private fun validate(row: ProviderModelEntity) {
    require(isValidModelId(row.modelId)) { "Enter a model ID without line breaks (at most 2 KB)." }
    require(row.contextWindowTokens == null || row.contextWindowTokens > 0) { "The context window must be positive." }
    require(row.maximumOutputTokens == null || row.maximumOutputTokens > 0) { "The output limit must be positive." }
  }

  private fun isValidModelId(id: String): Boolean =
    id.isNotBlank() && utf8Length(id) <= FieldLimits.MODEL_ID_BYTES && id.none { it == '\n' || it == '\r' }

  private fun toConfig(entity: ProviderEntity): ProviderConfig = ProviderConfig(
    id = entity.id,
    kind = kindOf(entity),
    displayName = entity.displayName,
    baseUrl = entity.baseUrl,
    isEnabled = entity.isEnabled,
    hasApiKey = secrets.hasKey(entity.id, bindingOf(entity)),
    createdAt = entity.createdAt,
    updatedAt = entity.updatedAt,
  )

  private fun connectionFor(
    provider: ProviderEntity,
    kind: ProviderKind,
    modelId: String,
    limits: ModelLimits?,
    key: String?,
  ) = ProviderConnection(
    id = provider.id,
    displayName = provider.displayName,
    provider = kind,
    baseUrl = provider.baseUrl,
    modelId = modelId,
    contextWindowTokens = limits?.contextWindowTokens,
    maximumOutputTokens = limits?.maximumOutputTokens,
    apiKey = key,
  )

  private suspend fun probe(provider: ProviderEntity, kind: ProviderKind, model: String, key: String?): String {
    val connection = connectionFor(provider, kind, model, null, key)
    val request = ChatRequest(
      messages = listOf(ChatMessage(id = newId(), role = ChatRole.USER, content = "Reply with the single word OK.")),
      // Small but not tiny: reasoning models can reject very low output caps.
      maxOutputTokens = 256,
    )
    var usage = TokenUsage()
    var receivedText = false
    var completed = false
    try {
      ProviderClientFactory.make(connection).stream(request).collect { event ->
        when (event) {
          is StreamEvent.TextDelta -> if (event.text.isNotBlank()) receivedText = true
          is StreamEvent.Usage -> usage = TokenUsage(
            inputTokens = event.usage.inputTokens ?: usage.inputTokens,
            outputTokens = event.usage.outputTokens ?: usage.outputTokens,
          )
          is StreamEvent.Completed -> completed = true
          is StreamEvent.Citations -> Unit
        }
      }
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      // A model that answered but stopped early (e.g. output cap) still proves key + endpoint.
      if (!receivedText) throw error
    } finally {
      if (usage.inputTokens != null || usage.outputTokens != null) {
        withContext(NonCancellable) {
          runCatching {
            db.usage().insert(
              UsageRecordEntity(
                id = newId(),
                providerId = provider.id,
                providerKind = kind.rawId,
                providerName = provider.displayName,
                modelId = model,
                destinationHost = connection.destinationHost,
                category = "Connection test",
                inputTokens = usage.inputTokens,
                outputTokens = usage.outputTokens,
                conversationId = null,
                messageId = null,
                createdAt = MonotonicClock.now(),
              )
            )
          }
        }
      }
    }
    return if (receivedText || completed) "Connected. $model responded." else
      "Connected, but $model returned no text. Check that the model ID is a chat model."
  }

  /** iOS `ProviderConnectionTestSemantics.successMessage`, plus an exact-model check. */
  private fun listingMessage(listed: List<DiscoveredModel>, model: String, keyVerified: Boolean): String {
    val count = listed.distinctBy { it.id }.size
    val noun = if (count == 1) "model" else "models"
    if (!keyVerified) {
      return if (count == 0) {
        "Public model catalog is reachable, but it returned no models. The API key was not sent or verified; enter a model ID manually."
      } else {
        "Public model catalog is reachable. Found $count $noun. The API key was not sent or verified."
      }
    }
    if (count == 0) return "Connected, but the provider returned no models. Enter a model ID manually."
    val base = "Connected. Found $count $noun."
    if (model.isEmpty() || listed.any { it.id == model }) return base
    return "$base “$model” is not in the provider's list; check the exact model ID."
  }

  private fun sanitized(error: Exception, key: String?): ProviderException {
    val message = ErrorSanitizer.describe(error, key)
    return if (error is ProviderException) {
      ProviderException(error.kind, message, error.httpStatus)
    } else {
      val kind = if (error is IOException) ProviderErrorKind.CONNECTIVITY else ProviderErrorKind.PROVIDER
      ProviderException(kind, message)
    }
  }

  private fun missingKey(message: String) = ProviderException(ProviderErrorKind.MISSING_API_KEY, message)

  // endregion

  companion object {
    private const val MAX_DISCOVERED_MODELS = 10_000

    /** Unknown raw IDs (from a newer build) map to Custom, whose binding never matches a preset key. */
    internal fun kindOf(entity: ProviderEntity): ProviderKind =
      ProviderKind.fromRawId(entity.kind) ?: ProviderKind.CUSTOM

    internal fun bindingOf(entity: ProviderEntity): CredentialBinding {
      val kind = kindOf(entity)
      return CredentialBinding.of(kind, entity.baseUrl?.takeIf { it.isNotBlank() } ?: kind.profile.baseUrl)
    }
  }
}

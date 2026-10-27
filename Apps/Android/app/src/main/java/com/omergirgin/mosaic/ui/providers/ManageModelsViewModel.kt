package com.omergirgin.mosaic.ui.providers

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.ProviderException
import com.omergirgin.mosaic.core.net.ModelCatalogSupport
import com.omergirgin.mosaic.core.provider.BundledModelCatalog
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.data.api.ProviderRepository
import com.omergirgin.mosaic.data.model.ProviderConfig
import com.omergirgin.mosaic.data.model.ProviderModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Where a row came from; drives its label and whether it must be persisted. */
internal data class ModelRowInfo(
  val id: String,
  val isSuggested: Boolean,
  val isCustom: Boolean,
  val isDiscovered: Boolean,
  val displayName: String? = null,
)

/** Per-model overrides; null fields fall back to the bundled catalog. */
internal data class ModelOverride(
  val contextWindow: Int? = null,
  val maximumOutput: Int? = null,
  val supportsImages: Boolean? = null,
) {
  val isEmpty: Boolean get() = contextWindow == null && maximumOutput == null && supportsImages == null
  val hasLimits: Boolean get() = contextWindow != null || maximumOutput != null
}

internal sealed interface RefreshState {
  data object Idle : RefreshState
  data object Refreshing : RefreshState
  data class Success(val message: String) : RefreshState
  data class Failure(val message: String) : RefreshState
}

/**
 * Draft of one connection's model catalog: bundled suggestions, saved rows and live discovery
 * merged into one list. Nothing is written until Save, which replaces the saved rows at once.
 * Catalogs can hold thousands of IDs, so filtering runs off the main thread.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal class ManageModelsViewModel(
  private val providers: ProviderRepository,
  private val providerId: String,
) : ViewModel() {

  var isLoading by mutableStateOf(true)
    private set
  var notFound by mutableStateOf(false)
    private set
  var config by mutableStateOf<ProviderConfig?>(null)
    private set

  var infos by mutableStateOf<Map<String, ModelRowInfo>>(emptyMap())
    private set
  var orderedIds by mutableStateOf<List<String>>(emptyList())
    private set
  var enabled by mutableStateOf<Set<String>>(emptySet())
    private set
  var overrides by mutableStateOf<Map<String, ModelOverride>>(emptyMap())
    private set
  /** Rows whose limits were reported by the account's catalog rather than set by the user. */
  var accountLimitIds by mutableStateOf<Set<String>>(emptySet())
    private set

  var query by mutableStateOf("")
  var enabledOnly by mutableStateOf(false)
  var visibleIds by mutableStateOf<List<String>>(emptyList())
    private set

  var refreshState by mutableStateOf<RefreshState>(RefreshState.Idle)
    private set
  var catalogUnavailable by mutableStateOf(false)
    private set
  /** AI/ML API lists its catalog publicly: a refresh then proves reachability, not the key. */
  var usesPublicCatalog by mutableStateOf(false)
    private set
  var customModelText by mutableStateOf("")
  var customModelIssue by mutableStateOf<String?>(null)
    private set
  /** Incremented when the list should scroll to the top (a new exact ID is pinned there). */
  var scrollToTopRequests by mutableIntStateOf(0)
    private set

  var isSaving by mutableStateOf(false)
    private set
  var saved by mutableStateOf(false)
    private set
  var errorMessage by mutableStateOf<String?>(null)

  private var suggestions: List<String> = emptyList()
  /** Exact IDs added in this session stay at the top so the user sees what they just added. */
  private var pinnedIds: List<String> = emptyList()
  private var initialEnabled: Set<String> = emptySet()
  private var initialOverrides: Map<String, ModelOverride> = emptyMap()
  private var refreshJob: Job? = null

  init {
    viewModelScope.launch {
      try {
        val current = providers.observeProvider(providerId).first()
        if (current == null) {
          notFound = true
          return@launch
        }
        config = current
        usesPublicCatalog = runCatching {
          ModelCatalogSupport.usesUnauthenticatedPublicCatalog(
            ProviderConnection(current.id, current.displayName, current.kind, current.baseUrl, modelId = ""),
          )
        }.getOrDefault(false)
        load(current.kind, providers.observeModels(providerId).first())
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        errorMessage = providerErrorMessage(e)
      } finally {
        isLoading = false
      }
    }
    viewModelScope.launch {
      snapshotFlow { Triple(orderedIds, query.trim(), if (enabledOnly) enabled else null) }
        .mapLatest { (ids, text, onlyEnabled) ->
          withContext(Dispatchers.Default) {
            ids.filter { id ->
              (onlyEnabled == null || id in onlyEnabled) && (text.isEmpty() || id.contains(text, ignoreCase = true))
            }
          }
        }
        .collect { visibleIds = it }
    }
  }

  val kind: ProviderKind? get() = config?.kind

  val isDirty: Boolean get() = enabled != initialEnabled || overrides != initialOverrides || pinnedIds.isNotEmpty()

  fun setEnabled(id: String, value: Boolean) {
    enabled = if (value) enabled + id else enabled - id
  }

  fun applyOverride(id: String, override: ModelOverride) {
    if (overrides[id] == override) return
    overrides = if (override.isEmpty) overrides - id else overrides + (id to override)
    accountLimitIds = accountLimitIds - id
  }

  fun refresh() {
    if (refreshState == RefreshState.Refreshing) return
    refreshJob?.cancel()
    refreshState = RefreshState.Refreshing
    refreshJob = viewModelScope.launch {
      try {
        val found = providers.discoverModels(providerId)
        // Discovery already persisted new rows (disabled, with account-reported limits for IDs the
        // bundled catalog doesn't document). Merge those rows so Save keeps their limits.
        val persisted = providers.observeModels(providerId).first().associateBy { it.modelId }
        val current = infos
        val currentOverrides = overrides
        val result = withContext(Dispatchers.Default) {
          val next = LinkedHashMap(current)
          val reported = HashMap<String, ModelOverride>()
          for (model in found) {
            val id = model.id.trim()
            if (id.isEmpty()) continue
            val existing = next[id]
            if (existing == null) {
              // Newly discovered models stay disabled until the user enables them.
              next[id] = ModelRowInfo(id, isSuggested = false, isCustom = false, isDiscovered = true, displayName = model.displayName)
              val row = persisted[id]
              val limits = ModelOverride(row?.contextWindowTokens, row?.maximumOutputTokens, row?.supportsImages)
              if (!limits.isEmpty && id !in currentOverrides) reported[id] = limits
            } else {
              next[id] = existing.copy(isDiscovered = true, displayName = existing.displayName ?: model.displayName)
            }
          }
          Triple(next, reported, order(next.keys))
        }
        val (merged, reported, order) = result
        infos = merged
        orderedIds = order
        if (reported.isNotEmpty()) {
          // Already saved by discovery, so these are part of the baseline, not unsaved edits.
          overrides = overrides + reported
          initialOverrides = initialOverrides + reported
          accountLimitIds = accountLimitIds + reported.keys
        }
        catalogUnavailable = false
        val count = found.size
        val foundLabel = if (count == 1) "1 model" else "$count models"
        refreshState = RefreshState.Success(
          when {
            // A public catalog is fetched without the key, so success says nothing about the key.
            usesPublicCatalog && count == 0 ->
              "Public model catalog is reachable, but it returned no models. The API key was not sent or verified; enter a model ID manually."
            usesPublicCatalog ->
              "Public model catalog is reachable. Found $foundLabel. The API key was not sent or verified. New models stay disabled until you enable them."
            count == 0 -> "Connected, but the service returned no models. Enter an exact model ID instead."
            else -> "Connected. Found $foundLabel. New models stay disabled until you enable them."
          },
        )
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        if (e is ProviderException && e.kind == ProviderErrorKind.MODEL_CATALOG_UNAVAILABLE) catalogUnavailable = true
        refreshState = RefreshState.Failure(providerErrorMessage(e, ErrorContext.DISCOVERY))
      }
    }
  }

  fun addCustomModel() {
    val issue = modelIdIssue(customModelText)
    if (issue != null) {
      customModelIssue = issue
      return
    }
    val id = customModelText.trim()
    customModelText = ""
    customModelIssue = null
    enabled = enabled + id
    if (infos[id] == null) {
      infos = infos + (id to ModelRowInfo(id, isSuggested = false, isCustom = true, isDiscovered = false))
      pinnedIds = listOf(id) + pinnedIds
      orderedIds = listOf(id) + orderedIds.filter { it != id }
      query = ""
      scrollToTopRequests++
    } else {
      // Already listed (suggested or discovered): reveal it instead of adding a duplicate.
      query = id
    }
  }

  fun clearCustomModelIssue() {
    customModelIssue = null
  }

  fun save() {
    val kind = kind ?: return
    if (isSaving) return
    for ((id, override) in overrides) {
      if (!override.hasLimits) continue
      val defaults = BundledModelCatalog.resolvedLimits(kind, id)
      RequestLimitPolicy.validationIssue(
        override.contextWindow ?: defaults.contextWindowTokens,
        override.maximumOutput ?: defaults.maximumOutputTokens,
      )?.let {
        errorMessage = "$id: $it"
        return
      }
    }
    isSaving = true
    val ids = orderedIds
    val rowInfo = infos
    val enabledNow = enabled
    val overridesNow = overrides
    viewModelScope.launch {
      try {
        val rows = withContext(Dispatchers.Default) {
          ids.mapNotNull { id ->
            val info = rowInfo[id] ?: return@mapNotNull null
            val override = overridesNow[id]
            val isOn = id in enabledNow
            // Untouched suggestions are re-merged from the bundled catalog, so they need no row.
            if (!isOn && override == null && !info.isCustom && !info.isDiscovered) return@mapNotNull null
            ProviderModel(
              providerId = providerId,
              modelId = id,
              isEnabled = isOn,
              contextWindowTokens = override?.contextWindow,
              maximumOutputTokens = override?.maximumOutput,
              supportsImages = override?.supportsImages,
              isCustom = info.isCustom,
              isDiscovered = info.isDiscovered,
            )
          }
        }
        withContext(NonCancellable) { providers.saveModels(providerId, rows) }
        saved = true
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        errorMessage = providerErrorMessage(e)
      } finally {
        isSaving = false
      }
    }
  }

  private fun load(kind: ProviderKind, savedRows: List<ProviderModel>) {
    suggestions = BundledModelCatalog.models(kind)
    val map = LinkedHashMap<String, ModelRowInfo>()
    suggestions.forEach { map[it] = ModelRowInfo(it, isSuggested = true, isCustom = false, isDiscovered = false) }
    val loadedOverrides = HashMap<String, ModelOverride>()
    val fromAccount = HashSet<String>()
    for (row in savedRows) {
      val existing = map[row.modelId]
      map[row.modelId] = ModelRowInfo(
        id = row.modelId,
        isSuggested = existing != null,
        isCustom = row.isCustom,
        isDiscovered = row.isDiscovered,
      )
      val override = ModelOverride(row.contextWindowTokens, row.maximumOutputTokens, row.supportsImages)
      if (!override.isEmpty) loadedOverrides[row.modelId] = override
      // Discovery stores account-reported limits only for IDs the bundled catalog does not document.
      if (override.hasLimits && row.isDiscovered && !row.isCustom && existing == null &&
        BundledModelCatalog.documentedLimits(kind, row.modelId) == null
      ) {
        fromAccount += row.modelId
      }
    }
    infos = map
    enabled = savedRows.filter { it.isEnabled }.map { it.modelId }.toSet()
    overrides = loadedOverrides
    accountLimitIds = fromAccount
    orderedIds = order(map.keys)
    initialEnabled = enabled
    initialOverrides = overrides
  }

  /** Session-added IDs, then curated suggestions in catalog order, then everything else A–Z. */
  private fun order(all: Collection<String>): List<String> {
    val present = all.toHashSet()
    val head = (pinnedIds + suggestions).filter { it in present }.distinct()
    val headSet = head.toHashSet()
    return head + all.filter { it !in headSet }.sortedWith(String.CASE_INSENSITIVE_ORDER)
  }
}

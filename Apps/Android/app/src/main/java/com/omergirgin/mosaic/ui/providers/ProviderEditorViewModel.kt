package com.omergirgin.mosaic.ui.providers

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.omergirgin.mosaic.core.chat.CredentialBinding
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import com.omergirgin.mosaic.core.chat.ProviderException
import com.omergirgin.mosaic.core.net.ModelCatalogSupport
import com.omergirgin.mosaic.core.provider.BundledModelCatalog
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.profile
import com.omergirgin.mosaic.core.provider.supportsChat
import com.omergirgin.mosaic.core.provider.supportsModelDiscovery
import com.omergirgin.mosaic.data.api.ProviderRepository
import com.omergirgin.mosaic.data.model.ProviderConfig
import com.omergirgin.mosaic.data.model.ProviderDraft
import com.omergirgin.mosaic.data.model.ProviderModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal sealed interface ConnectionTestState {
  data object Idle : ConnectionTestState
  data object Testing : ConnectionTestState
  data class Success(val message: String) : ConnectionTestState
  data class Failure(val message: String) : ConnectionTestState
}

internal sealed interface EditorEvent {
  data class Saved(val providerId: String, val openModels: Boolean) : EditorEvent
  data object Deleted : EditorEvent
}

/**
 * State for adding or editing one connection. The API key lives only in memory here: it is never
 * prefilled from storage, never put in saved state, and is cleared after saving or on teardown.
 */
internal class ProviderEditorViewModel(
  private val providers: ProviderRepository,
  val providerId: String?,
  initialKind: ProviderKind?,
  private val suggestedModel: String?,
) : ViewModel() {

  var isLoading by mutableStateOf(providerId != null)
    private set
  var notFound by mutableStateOf(false)
    private set
  var original by mutableStateOf<ProviderConfig?>(null)
    private set
  var savedModels by mutableStateOf<List<ProviderModel>>(emptyList())
    private set

  var kind by mutableStateOf(initialKind ?: ProviderKind.OPENAI)
    private set
  var displayName by mutableStateOf("")
  var endpoint by mutableStateOf("")
  /** Simple view shows standard addresses read-only until the user asks to change them. */
  var endpointUnlocked by mutableStateOf(false)
  var apiKey by mutableStateOf("")
  var replacingKey by mutableStateOf(false)
  var isEnabled by mutableStateOf(true)

  /** Model choices used when creating a connection or after changing its service type. */
  var modelCandidates by mutableStateOf<List<String>>(emptyList())
    private set
  var selectedModels by mutableStateOf<Set<String>>(emptySet())
    private set
  var customModelText by mutableStateOf("")
  var customModelIssue by mutableStateOf<String?>(null)
    private set

  var isSaving by mutableStateOf(false)
    private set
  var isRemovingKey by mutableStateOf(false)
    private set
  var isDeleting by mutableStateOf(false)
    private set
  var errorMessage by mutableStateOf<String?>(null)
  /** Save failures that belong to one field are shown under that field, not in a dialog. */
  var endpointServerIssue by mutableStateOf<String?>(null)
  var keyServerIssue by mutableStateOf<String?>(null)
  var event by mutableStateOf<EditorEvent?>(null)
    private set

  var testModel by mutableStateOf<String?>(null)
  var testState by mutableStateOf<ConnectionTestState>(ConnectionTestState.Idle)
    private set
  private var testJob: Job? = null

  private var initialKindValue = kind
  private var initialName = ""
  private var initialEndpoint = ""
  private var initialEnabled = true
  private var initialSelected = emptySet<String>()

  init {
    if (providerId == null) {
      displayName = kind.profile.displayName
      endpoint = kind.profile.baseUrl.orEmpty()
      resetModelSelection(kind, preferredModel = suggestedModel)
      captureInitialValues()
    } else {
      viewModelScope.launch {
        providers.observeProvider(providerId).collect { config ->
          if (config == null) {
            // Our own delete also ends here; the Deleted event handles that navigation.
            if (!isDeleting) notFound = true
            isLoading = false
            return@collect
          }
          val first = original == null
          original = config
          if (first) {
            kind = config.kind
            displayName = config.displayName
            endpoint = config.baseUrl ?: config.kind.profile.baseUrl.orEmpty()
            isEnabled = config.isEnabled
            captureInitialValues()
            isLoading = false
          }
        }
      }
      viewModelScope.launch {
        providers.observeModels(providerId).collect { models ->
          savedModels = models
          val enabled = models.filter { it.isEnabled }.map { it.modelId }
          if (testModel == null || testModel !in enabled) testModel = enabled.firstOrNull()
        }
      }
    }
  }

  val isNew: Boolean get() = providerId == null
  val kindChanged: Boolean get() = original?.let { it.kind != kind } ?: false
  val needsModelSelection: Boolean get() = (isNew || kindChanged) && kind.supportsChat
  val enabledModelCount: Int get() = savedModels.count { it.isEnabled }
  val enabledModelIds: List<String> get() = savedModels.filter { it.isEnabled }.map { it.modelId }

  val hasSavedKey: Boolean get() = original?.hasApiKey == true

  /**
   * AI/ML API publishes its catalog without authentication, so a test of the saved connection
   * proves reachability only; the UI must not claim the key was verified.
   */
  val usesPublicCatalog: Boolean
    get() {
      val saved = original ?: return false
      return runCatching {
        ModelCatalogSupport.usesUnauthenticatedPublicCatalog(
          ProviderConnection(saved.id, saved.displayName, saved.kind, saved.baseUrl, modelId = testModel.orEmpty()),
        )
      }.getOrDefault(false)
    }

  /**
   * A stored key is bound to the exact service + endpoint. When either changes it must never be
   * sent to the new destination: the user enters a replacement or the old key is removed on save.
   */
  val destinationChanged: Boolean
    get() {
      val saved = original ?: return false
      val before = CredentialBinding.of(saved.kind, saved.baseUrl ?: saved.kind.profile.baseUrl)
      val after = CredentialBinding.of(kind, EndpointForm.effective(kind, endpoint))
      return before != after
    }

  val savedKeyUsable: Boolean get() = hasSavedKey && !destinationChanged
  val showsKeyField: Boolean get() = !savedKeyUsable || replacingKey

  val endpointIssue: String? get() = EndpointForm.issue(kind, endpoint)

  val validationIssue: String?
    get() {
      if (kind == ProviderKind.CUSTOM && displayName.isBlank()) return "Enter a display name."
      endpointIssue?.let { return it }
      if (kind.profile.requiresApiKey && apiKey.isBlank()) {
        if (hasSavedKey && destinationChanged) return "Enter an API key for ${kind.profile.displayName}."
        if (!savedKeyUsable) return "Enter an API key."
      }
      // Services with a live catalog may start empty: Manage Models opens right after saving.
      if (needsModelSelection && selectedModels.isEmpty() && !kind.supportsModelDiscovery) {
        return "Choose at least one model, or add an exact model ID."
      }
      return null
    }

  val isDirty: Boolean
    get() = apiKey.isNotBlank() ||
      kind != initialKindValue ||
      displayName != initialName ||
      endpoint.trim() != initialEndpoint.trim() ||
      isEnabled != initialEnabled ||
      (needsModelSelection && selectedModels != initialSelected)

  val isBusy: Boolean get() = isSaving || isRemovingKey || isDeleting

  fun changeKind(newKind: ProviderKind) {
    if (newKind == kind) return
    val previous = kind
    cancelTest()
    if (displayName.isBlank() || displayName == previous.profile.displayName) {
      displayName = newKind.profile.displayName
    }
    // Endpoint, model and limits form one provider-specific destination. Carrying any of them
    // across a type change could route a newly entered key to the previous host or pick an
    // incompatible model, so the whole destination resets together (iOS parity).
    kind = newKind
    endpoint = if (newKind == original?.kind) {
      original?.baseUrl ?: newKind.profile.baseUrl.orEmpty()
    } else {
      newKind.profile.baseUrl.orEmpty()
    }
    endpointUnlocked = false
    apiKey = ""
    replacingKey = false
    endpointServerIssue = null
    keyServerIssue = null
    resetModelSelection(newKind, preferredModel = null)
  }

  fun toggleModel(modelId: String, selected: Boolean) {
    selectedModels = if (selected) selectedModels + modelId else selectedModels - modelId
  }

  fun addCustomModel() {
    val issue = modelIdIssue(customModelText)
    if (issue != null) {
      customModelIssue = issue
      return
    }
    val id = customModelText.trim()
    if (id !in modelCandidates) modelCandidates = listOf(id) + modelCandidates
    selectedModels = selectedModels + id
    customModelText = ""
    customModelIssue = null
  }

  fun clearCustomModelIssue() {
    customModelIssue = null
  }

  fun save() {
    validationIssue?.let {
      errorMessage = it
      return
    }
    if (isBusy) return
    isSaving = true
    endpointServerIssue = null
    keyServerIssue = null
    val key = apiKey.trim()
    val currentKind = kind
    val models = selectedModels.toList()
    val draft = ProviderDraft(
      id = providerId,
      kind = currentKind,
      displayName = DisplayNamePolicy.resolved(currentKind, displayName),
      baseUrl = EndpointForm.draftValue(currentKind, endpoint),
      apiKey = when {
        key.isNotEmpty() -> key
        // Remove a key bound to the previous destination instead of silently keeping it around.
        hasSavedKey && destinationChanged -> ""
        else -> null
      },
      isEnabled = isEnabled,
      // Also sent on a type change: the repository resets the catalog together with the destination.
      initialModels = if ((isNew || kindChanged) && currentKind.supportsChat) models else emptyList(),
    )
    val resetCatalog = kindChanged && currentKind.supportsChat
    val openModels = needsModelSelection && models.isEmpty()
    viewModelScope.launch {
      try {
        // Persisting must complete even if the screen goes away mid-save.
        val saved = withContext(NonCancellable) {
          val result = providers.saveProvider(draft)
          if (resetCatalog && models.isNotEmpty()) {
            val suggestions = BundledModelCatalog.models(currentKind).toSet()
            providers.saveModels(
              result.id,
              models.map { ProviderModel(result.id, it, isEnabled = true, isCustom = it !in suggestions) },
            )
          }
          result
        }
        apiKey = ""
        event = EditorEvent.Saved(saved.id, openModels)
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        showSaveFailure(e, key)
      } finally {
        isSaving = false
      }
    }
  }

  fun removeSavedKey() {
    val saved = original ?: return
    if (isBusy) return
    isRemovingKey = true
    cancelTest()
    viewModelScope.launch {
      try {
        // Built from the stored connection, not the form, so unsaved edits are not applied here.
        withContext(NonCancellable) {
          providers.saveProvider(
            ProviderDraft(
              id = saved.id,
              kind = saved.kind,
              displayName = saved.displayName,
              baseUrl = saved.baseUrl,
              apiKey = "",
              isEnabled = saved.isEnabled,
            ),
          )
        }
        replacingKey = false
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        errorMessage = providerErrorMessage(e)
      } finally {
        isRemovingKey = false
      }
    }
  }

  fun delete() {
    val id = providerId ?: return
    if (isBusy) return
    isDeleting = true
    cancelTest()
    viewModelScope.launch {
      try {
        withContext(NonCancellable) { providers.deleteProvider(id) }
        event = EditorEvent.Deleted
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        isDeleting = false
        errorMessage = providerErrorMessage(e)
      }
    }
  }

  fun testConnection() {
    val id = providerId ?: return
    val model = testModel ?: return
    testJob?.cancel()
    testState = ConnectionTestState.Testing
    testJob = viewModelScope.launch {
      testState = try {
        providers.testConnection(id, model).fold(
          onSuccess = { ConnectionTestState.Success(it.ifBlank { "Connected. $model responded." }) },
          onFailure = { ConnectionTestState.Failure(providerErrorMessage(it, ErrorContext.TEST)) },
        )
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        ConnectionTestState.Failure(providerErrorMessage(e, ErrorContext.TEST))
      }
    }
  }

  private fun showSaveFailure(error: Exception, key: String) {
    val providerError = error as? ProviderException
    // Repository messages are already user-readable and sanitized; redact the typed key anyway.
    val specific = providerError?.message?.takeIf { it.isNotBlank() }?.let {
      if (key.isBlank()) it else it.replace(key, "••••")
    }
    when (providerError?.kind) {
      ProviderErrorKind.INVALID_ENDPOINT, ProviderErrorKind.INSECURE_ENDPOINT -> {
        endpointUnlocked = true
        endpointServerIssue = specific ?: providerErrorMessage(error, redacting = key)
      }
      ProviderErrorKind.MISSING_API_KEY -> keyServerIssue = specific ?: providerErrorMessage(error, redacting = key)
      else -> errorMessage = providerErrorMessage(error, redacting = key)
    }
  }

  fun consumeEvent() {
    event = null
  }

  private fun cancelTest() {
    testJob?.cancel()
    testJob = null
    testState = ConnectionTestState.Idle
  }

  private fun resetModelSelection(kind: ProviderKind, preferredModel: String?) {
    val preferred = preferredModel?.trim()?.takeIf { it.isNotEmpty() }
    val suggestions = BundledModelCatalog.models(kind)
    modelCandidates = (listOfNotNull(preferred) + suggestions).distinct()
    val first = preferred ?: BundledModelCatalog.defaultModel(kind).takeIf { it.isNotBlank() }
    selectedModels = if (kind.supportsChat) setOfNotNull(first) else emptySet()
    customModelText = ""
    customModelIssue = null
  }

  private fun captureInitialValues() {
    initialKindValue = kind
    initialName = displayName
    initialEndpoint = endpoint
    initialEnabled = isEnabled
    initialSelected = selectedModels
  }

  override fun onCleared() {
    apiKey = ""
  }
}

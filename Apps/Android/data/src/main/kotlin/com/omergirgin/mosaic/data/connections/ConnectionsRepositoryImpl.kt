package com.omergirgin.mosaic.data.connections

import android.content.Context
import com.omergirgin.mosaic.core.chat.WebSource
import com.omergirgin.mosaic.core.connections.ConnectionActionReceipt
import com.omergirgin.mosaic.core.connections.ConnectorCredential
import com.omergirgin.mosaic.core.connections.ConnectorException
import com.omergirgin.mosaic.core.connections.ConnectorExecutor
import com.omergirgin.mosaic.core.connections.ConnectorHttp
import com.omergirgin.mosaic.core.connections.ConnectorId
import com.omergirgin.mosaic.core.connections.ConnectorJson
import com.omergirgin.mosaic.core.connections.ConnectorOAuth
import com.omergirgin.mosaic.core.connections.ConnectorSelection
import com.omergirgin.mosaic.core.connections.ConnectorStore
import com.omergirgin.mosaic.core.connections.ConnectorTool
import com.omergirgin.mosaic.core.connections.ConnectorToolCall
import com.omergirgin.mosaic.core.connections.ConnectorTransport
import com.omergirgin.mosaic.core.connections.OAuthAttempt
import com.omergirgin.mosaic.core.connections.arrayValue
import com.omergirgin.mosaic.core.connections.encoded
import com.omergirgin.mosaic.core.connections.get
import com.omergirgin.mosaic.core.connections.objectValue
import com.omergirgin.mosaic.core.connections.stringValue
import com.omergirgin.mosaic.data.BuildConfig
import com.omergirgin.mosaic.data.db.MosaicDatabase
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.minutes
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonElement

internal class ConnectionsRepositoryImpl(
  context: Context,
  private val db: MosaicDatabase,
  private val scope: CoroutineScope,
  internal val transport: ConnectorTransport = ConnectorHttp(),
) : ConnectionsRepository {
  internal val store = ConnectorStore(ConnectionVault(context), transport)
  internal val preferences = ConnectionPreferences(context)
  internal val device = DeviceConnections(context)
  internal val pdf = PdfboxTextReader(context)
  internal val approvals = ConnectorApprovals()
  private val refreshTick = MutableStateFlow(0L)
  private val _progress = MutableStateFlow<Map<String, String>>(emptyMap())
  override val progress: StateFlow<Map<String, String>> = _progress.asStateFlow()

  /** Chat-time research entry point used by the chat engine. */
  val chat = ConnectorChatHook(this, db)

  init {
    // Per-chat choices of deleted chats are device settings with no owner left; drop them.
    scope.launch(Dispatchers.IO) {
      runCatching {
        for (id in preferences.chatIds()) if (db.conversations().get(id) == null) preferences.setChat(id, null)
      }
    }
  }

  // region statuses and selections

  override fun observeStatuses(): Flow<List<ConnectionStatus>> =
    combine(store.changes, refreshTick) { _, _ -> statuses() }.distinctUntilChanged().flowOn(Dispatchers.IO)

  override fun refreshStatuses() = refreshTick.update { it + 1 }

  internal suspend fun statuses(): List<ConnectionStatus> = ConnectorId.entries.map { service ->
    val credential = store.credential(service)
    ConnectionStatus(
      service = service,
      generation = credential?.id,
      label = credential?.label,
      permissionNeeded = credential != null && service.isDevice && !device.isAuthorized(service),
    )
  }

  override fun observeDefaults(): Flow<ConnectorSelection> =
    preferences.version.map { preferences.defaults() }.distinctUntilChanged()

  override suspend fun setDefault(service: ConnectorId, enabled: Boolean) {
    val generation = if (enabled) currentGeneration(service) else null
    preferences.setDefaults(preferences.defaults().with(service, generation))
  }

  override fun observeChatAccess(conversationId: String): Flow<ChatConnectionAccess> =
    preferences.version.map {
      val custom = preferences.chatOverride(conversationId)
      ChatConnectionAccess(custom ?: preferences.defaults(), custom != null)
    }.distinctUntilChanged()

  override suspend fun setChatAccess(conversationId: String, service: ConnectorId, enabled: Boolean) {
    val generation = if (enabled) currentGeneration(service) else null
    // Changing one switch materializes the inherited defaults into this chat's own choice.
    preferences.setChat(conversationId, preferences.effective(conversationId).with(service, generation))
  }

  override suspend fun resetChatAccess(conversationId: String) = preferences.setChat(conversationId, null)

  /** Only a live, permitted connection can be bound; its generation pins the exact account. */
  private suspend fun currentGeneration(service: ConnectorId): String {
    val generation = store.generation(service) ?: throw ConnectorException(ConnectorException.Kind.DISCONNECTED)
    if (service.isDevice && !device.isAuthorized(service)) throw ConnectorException(ConnectorException.Kind.DENIED)
    return generation
  }

  // endregion

  // region connecting

  override suspend fun connectWithToken(service: ConnectorId, token: String) {
    if (!service.supportsToken) throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
    val secret = token.trim()
    val attempt = store.begin(service)
    try {
      val label = ConnectorExecutor.verify(service, secret, transport)
      store.save(ConnectorCredential(token = secret, label = label), service, attempt)
    } catch (error: Throwable) {
      store.cancel(service, attempt)
      throw error
    }
  }

  override fun devicePermissions(service: ConnectorId): Array<String> = device.permissions(service)

  override suspend fun connectDevice(service: ConnectorId) {
    if (!service.isDevice) throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
    if (!device.isAuthorized(service)) throw ConnectorException(ConnectorException.Kind.DENIED)
    // Re-checking permission keeps the existing generation; only a first grant creates one.
    if (store.generation(service) == null) {
      val attempt = store.begin(service)
      try {
        store.save(ConnectorCredential(token = "", label = "This device"), service, attempt)
      } catch (error: Throwable) {
        store.cancel(service, attempt)
        throw error
      }
    }
    refreshStatuses()
  }

  override suspend fun disconnect(service: ConnectorId) {
    if ((signIn.value as? SignInState.InBrowser)?.service?.credentialKey == service.credentialKey) cancelSignIn()
    store.disconnect(service)
    preferences.removeEverywhere(service.credentialKey)
  }

  override fun buildClientId(service: ConnectorId): String = when {
    service.isMicrosoft -> BuildConfig.TURING_MICROSOFT_CLIENT_ID
    service == ConnectorId.DROPBOX -> BuildConfig.TURING_DROPBOX_CLIENT_ID
    else -> ""
  }

  override fun effectiveClientId(service: ConnectorId): String =
    preferences.clientId(service).ifBlank { buildClientId(service) }

  override fun developerClientId(service: ConnectorId): String = preferences.clientId(service)

  override suspend fun setDeveloperClientId(service: ConnectorId, value: String) {
    val trimmed = value.trim()
    if (trimmed.length > 256 || !trimmed.all { it.isLetterOrDigit() || it in "-_." }) {
      throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
    }
    preferences.setClientId(service, trimmed)
  }

  // endregion

  // region OAuth

  private class PendingSignIn(val service: ConnectorId, val operation: String, val attempt: OAuthAttempt)

  private val signInLock = Mutex()
  private var pendingSignIn: PendingSignIn? = null
  private var signInJob: Job? = null
  private val _signIn = MutableStateFlow<SignInState>(SignInState.Idle)
  override val signIn: StateFlow<SignInState> = _signIn.asStateFlow()

  override suspend fun beginSignIn(service: ConnectorId): String {
    if (!service.supportsOAuth) throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
    if (service.needsClientRegistration && effectiveClientId(service).isBlank()) {
      throw ConnectorException(ConnectorException.Kind.CONFIGURATION)
    }
    cancelSignIn()
    _signIn.value = SignInState.Preparing(service)
    val operation = store.begin(service)
    return try {
      val attempt = ConnectorOAuth.prepare(service, effectiveClientId(service), transport)
      val url = attempt.authorizationUrl()
      signInLock.withLock { pendingSignIn = PendingSignIn(service, operation, attempt) }
      _signIn.value = SignInState.InBrowser(service)
      url
    } catch (error: Throwable) {
      store.cancel(service, operation)
      _signIn.value = if (error is CancellationException) SignInState.Idle
      else SignInState.Failed(service, (error as? ConnectorException)?.message ?: SIGN_IN_FAILED)
      throw error
    }
  }

  override fun handleRedirect(uri: String) {
    signInJob = scope.launch {
      val pending = signInLock.withLock { pendingSignIn.also { pendingSignIn = null } } ?: return@launch
      _signIn.value = SignInState.Finishing(pending.service)
      try {
        val credential = ConnectorOAuth.exchange(pending.attempt, uri, transport, System.currentTimeMillis())
        val label = ConnectorExecutor.verify(pending.service, credential.token, transport)
        store.save(credential.copy(label = label), pending.service, pending.operation)
        _signIn.value = SignInState.Completed(pending.service)
      } catch (error: CancellationException) {
        store.cancel(pending.service, pending.operation)
        throw error
      } catch (error: Exception) {
        store.cancel(pending.service, pending.operation)
        _signIn.value = SignInState.Failed(pending.service, (error as? ConnectorException)?.message ?: SIGN_IN_FAILED)
      }
    }
  }

  override fun cancelSignIn() {
    signInJob?.cancel()
    signInJob = null
    val pending = pendingSignIn
    pendingSignIn = null
    if (pending != null) scope.launch { store.cancel(pending.service, pending.operation) }
    _signIn.value = SignInState.Idle
  }

  override fun acknowledgeSignIn() {
    val state = _signIn.value
    if (state is SignInState.Completed || state is SignInState.Failed) _signIn.value = SignInState.Idle
  }

  // endregion

  // region chat-time state

  override val pendingReview: StateFlow<ConnectorReview?> get() = approvals.pending

  override fun resolveReview(id: String, approved: Boolean) = approvals.resolve(id, approved)

  internal fun setProgress(messageId: String, text: String?) = _progress.update {
    if (text == null) it - messageId else it + (messageId to text)
  }

  override fun observeActivity(messageId: String): Flow<ConnectionActivity?> =
    combine(db.connections().observeActivity(messageId), db.connections().observeReceipts(messageId)) { activity, receipts ->
      if (activity == null && receipts.isEmpty()) return@combine null
      ConnectionActivity(
        messageId = messageId,
        notice = activity?.notice,
        services = activity?.servicesJson?.let(::decodeServices).orEmpty(),
        sources = activity?.sourcesJson?.let(::decodeSources).orEmpty(),
        receipts = receipts.mapNotNull(::receipt),
      )
    }.distinctUntilChanged().flowOn(Dispatchers.IO)

  private fun decodeServices(raw: String): List<ConnectorId> =
    runCatching { ConnectorJson.parse(raw).arrayValue?.mapNotNull { it.stringValue?.let(ConnectorId::fromRawId) } }.getOrNull().orEmpty()

  private fun decodeSources(raw: String): List<WebSource> =
    runCatching {
      ConnectorJson.parse(raw).arrayValue?.mapNotNull { item ->
        val url = item["url"].stringValue ?: return@mapNotNull null
        WebSource(item["title"].stringValue, url)
      }
    }.getOrNull().orEmpty()

  private fun receipt(entity: ConnectionActionReceiptEntity): ConnectionActionReceipt? {
    val service = ConnectorId.fromRawId(entity.service) ?: return null
    val outcome = runCatching { ConnectionActionReceipt.Outcome.valueOf(entity.outcome) }.getOrNull() ?: return null
    val arguments = runCatching { ConnectorJson.parse(entity.argumentsJson) }.getOrNull() ?: return null
    return ConnectionActionReceipt(entity.id, service, entity.tool, arguments, outcome, entity.updatedAt, entity.summary)
  }

  // endregion

  private companion object {
    const val SIGN_IN_FAILED = "Sign-in did not finish. Please try again."
  }
}

/**
 * One review at a time (iOS `ConnectorApprovalCoordinator`). A request that nobody answers within
 * ten minutes is declined; cancelling the chat request declines too. Declining sends nothing.
 */
internal class ConnectorApprovals {
  private val lock = Mutex()
  private val _pending = MutableStateFlow<ConnectorReview?>(null)
  val pending: StateFlow<ConnectorReview?> = _pending.asStateFlow()
  @Volatile private var current: Pair<String, CompletableDeferred<Boolean>>? = null

  suspend fun request(conversationId: String, tool: ConnectorTool, call: ConnectorToolCall): Boolean = lock.withLock {
    val id = UUID.randomUUID().toString()
    val answer = CompletableDeferred<Boolean>()
    current = id to answer
    _pending.value = ConnectorReview(id, conversationId, tool.service, tool.name, tool.description, fields(call.arguments))
    try {
      withTimeoutOrNull(10.minutes) { answer.await() } ?: false
    } finally {
      current = null
      _pending.update { if (it?.id == id) null else it }
    }
  }

  fun resolve(id: String, approved: Boolean) {
    val pending = current ?: return
    if (pending.first == id) pending.second.complete(approved)
  }

  private fun fields(arguments: JsonElement): List<Pair<String, String>> =
    arguments.objectValue?.entries?.sortedBy { it.key }?.map { (key, value) -> key to (value.stringValue ?: value.encoded) }.orEmpty()
}

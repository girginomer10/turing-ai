package com.omergirgin.mosaic.core.connections

import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Device-local credential. [id] is the connection generation: reconnecting creates a new one, so
 * chat selections bound to the old generation can never silently use a replacement account.
 */
@Serializable
data class ConnectorCredential(
  val id: String = UUID.randomUUID().toString(),
  val token: String,
  val label: String,
  val refreshToken: String? = null,
  /** Epoch milliseconds; null = no known expiry. */
  val expiresAt: Long? = null,
  val clientId: String? = null,
  val tokenEndpoint: String? = null,
  val resource: String? = null,
) {
  override fun toString(): String = "ConnectorCredential(id=$id, label=•••, token=•••)"
}

/** Encrypted device storage. Calls are synchronous so a write completes inside the store's lock. */
interface ConnectorVault {
  fun load(key: String): ConnectorCredential?
  fun save(value: ConnectorCredential, key: String)
  fun clear(key: String)
  /** Generation of the stored credential without decrypting it (validation runs often). */
  fun generation(key: String): String? = load(key)?.id
}

/**
 * Revision-bound sign-in and single-flight refresh (iOS `ConnectorStore`). Every vault mutation
 * happens under [lock]: a sign-in only saves if its attempt is still current, and a refresh only
 * saves if the same credential generation is still stored and the refresh was not superseded, so
 * a suspended refresh or sign-in can never resurrect a disconnected or replaced account.
 */
class ConnectorStore(
  private val vault: ConnectorVault,
  private val transport: ConnectorTransport,
  private val clock: () -> Long = System::currentTimeMillis,
) {
  private class PendingRefresh(val id: String, val credentialId: String, val task: Deferred<ConnectorCredential>)

  private val lock = Mutex()
  private val attempts = HashMap<String, String>()
  private val refreshing = HashMap<String, PendingRefresh>()
  private val refreshScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private val _changes = MutableStateFlow(0L)

  /** Bumps after every saved or removed credential so the UI can reload statuses. */
  val changes: StateFlow<Long> = _changes.asStateFlow()

  suspend fun credential(service: ConnectorId): ConnectorCredential? = io { lock.withLock { vault.load(service.credentialKey) } }

  suspend fun generation(service: ConnectorId): String? = io { lock.withLock { vault.generation(service.credentialKey) } }

  suspend fun begin(service: ConnectorId): String = lock.withLock {
    UUID.randomUUID().toString().also { attempts[service.credentialKey] = it }
  }

  suspend fun save(credential: ConnectorCredential, service: ConnectorId, attempt: String) {
    currentCoroutineContext().ensureActive()
    io {
      lock.withLock {
        val key = service.credentialKey
        if (attempts[key] != attempt) throw ConnectorException(ConnectorException.Kind.CHANGED)
        refreshing.remove(key)?.task?.cancel()
        vault.save(credential, key)
        attempts.remove(key)
      }
    }
    _changes.update { it + 1 }
  }

  suspend fun cancel(service: ConnectorId, attempt: String) = lock.withLock {
    if (attempts[service.credentialKey] == attempt) attempts.remove(service.credentialKey)
  }

  suspend fun disconnect(service: ConnectorId) {
    io {
      lock.withLock {
        val key = service.credentialKey
        attempts.remove(key)
        refreshing.remove(key)?.task?.cancel()
        vault.clear(key)
      }
    }
    _changes.update { it + 1 }
  }

  suspend fun validate(service: ConnectorId, id: String) {
    currentCoroutineContext().ensureActive()
    io {
      lock.withLock {
        if (vault.generation(service.credentialKey) != id) throw ConnectorException(ConnectorException.Kind.CHANGED)
      }
    }
  }

  /** Current access token for generation [id], refreshing (once, shared) within 60 s of expiry. */
  suspend fun token(service: ConnectorId, id: String): String {
    val key = service.credentialKey
    val pending = io {
      lock.withLock {
        val current = vault.load(key) ?: throw ConnectorException(ConnectorException.Kind.DISCONNECTED)
        if (current.id != id) throw ConnectorException(ConnectorException.Kind.CHANGED)
        val expiry = current.expiresAt
        if (expiry == null || expiry > clock() + 60_000) return@withLock current.token
        refreshing[key]?.takeIf { it.credentialId == current.id } ?: startRefresh(service, current).also { refreshing[key] = it }
      }
    }
    if (pending is String) return pending
    pending as PendingRefresh
    val fresh = try {
      pending.task.await()
    } catch (error: CancellationException) {
      currentCoroutineContext().ensureActive()
      // The shared refresh was cancelled by a disconnect or a new sign-in, not by this caller.
      throw ConnectorException(ConnectorException.Kind.CHANGED)
    }
    validate(service, id)
    return fresh.token
  }

  private fun startRefresh(service: ConnectorId, current: ConnectorCredential): PendingRefresh {
    val key = service.credentialKey
    val refreshId = UUID.randomUUID().toString()
    val task = refreshScope.async {
      val refresh = current.refreshToken
      val clientId = current.clientId
      val endpoint = current.tokenEndpoint
      val hosts = ConnectorOAuth.allowedHosts(service)
      try {
        if (refresh == null || clientId == null || endpoint == null || !ConnectorHttp.isAllowed(endpoint, hosts)) {
          throw ConnectorException(ConnectorException.Kind.DISCONNECTED)
        }
        val fields = mutableMapOf("grant_type" to "refresh_token", "refresh_token" to refresh, "client_id" to clientId)
        current.resource?.let { fields["resource"] = it }
        val response = transport.send(ConnectorRequest.form(endpoint, fields), hosts, 32_768)
        if (response.status == 400 || response.status == 401) throw ConnectorException(ConnectorException.Kind.DISCONNECTED)
        val fresh = ConnectorOAuth.credential(ConnectorJson.parse(response.requireSuccess()), current, clock())
        // Persist rotation here (not in the caller) so a cancelled caller can't lose a rotated token.
        lock.withLock {
          if (refreshing[key]?.id == refreshId && vault.generation(key) == current.id) vault.save(fresh, key)
        }
        fresh
      } finally {
        withContext(NonCancellable) {
          lock.withLock { if (refreshing[key]?.id == refreshId) refreshing.remove(key) }
        }
      }
    }
    return PendingRefresh(refreshId, current.id, task)
  }

  private suspend fun <T> io(block: suspend () -> T): T = withContext(Dispatchers.IO) { block() }
}

/**
 * Device-only selection bound to concrete connection generations (iOS `ConnectorSelection`).
 * Defaults and per-chat overrides share these semantics.
 */
data class ConnectorSelection(val bindings: Map<ConnectorId, String> = emptyMap()) {
  val raw: String
    get() = JsonObject(
      bindings.entries.sortedBy { it.key.rawId }.associate { it.key.rawId to JsonPrimitive(it.value) }
    ).encoded

  fun with(service: ConnectorId, generation: String?): ConnectorSelection =
    ConnectorSelection(if (generation == null) bindings - service else bindings + (service to generation))

  companion object {
    fun parse(raw: String?): ConnectorSelection {
      if (raw.isNullOrBlank()) return ConnectorSelection()
      val obj = runCatching { ConnectorJson.parse(raw) }.getOrNull().objectValue ?: return ConnectorSelection()
      return ConnectorSelection(
        obj.mapNotNull { (key, value) ->
          val id = ConnectorId.fromRawId(key) ?: return@mapNotNull null
          val generation = value.stringValue?.takeIf { it.length in 1..64 } ?: return@mapNotNull null
          id to generation
        }.toMap()
      )
    }
  }
}

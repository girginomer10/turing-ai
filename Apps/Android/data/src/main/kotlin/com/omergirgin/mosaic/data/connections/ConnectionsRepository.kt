package com.omergirgin.mosaic.data.connections

import com.omergirgin.mosaic.core.chat.WebSource
import com.omergirgin.mosaic.core.connections.ConnectionActionReceipt
import com.omergirgin.mosaic.core.connections.ConnectorId
import com.omergirgin.mosaic.core.connections.ConnectorSelection
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/** Stored connection for one catalog entry (no credential material). */
data class ConnectionStatus(
  val service: ConnectorId,
  /** Connection generation; null when this device has no credential for the service. */
  val generation: String?,
  /** Verified account label (email, workspace or tool count). */
  val label: String?,
  /** Device connection whose Android permission was revoked after connecting. */
  val permissionNeeded: Boolean = false,
) {
  val isConnected: Boolean get() = generation != null && !permissionNeeded
}

/** Effective access for one chat; [isCustom] = false means it follows the device defaults. */
data class ChatConnectionAccess(val selection: ConnectorSelection, val isCustom: Boolean)

/** OAuth sign-in progress for the browser leg (Custom Tab → custom-scheme redirect). */
sealed interface SignInState {
  data object Idle : SignInState
  data class Preparing(val service: ConnectorId) : SignInState
  data class InBrowser(val service: ConnectorId) : SignInState
  data class Finishing(val service: ConnectorId) : SignInState
  data class Completed(val service: ConnectorId) : SignInState
  data class Failed(val service: ConnectorId, val message: String) : SignInState
}

/** One exact non-read call waiting for review. Declining or dismissing sends nothing. */
data class ConnectorReview(
  val id: String,
  val conversationId: String,
  val service: ConnectorId,
  val toolName: String,
  val toolDescription: String,
  /** Argument name → exact value (strings verbatim, other JSON encoded). */
  val fields: List<Pair<String, String>>,
)

/** What connected services contributed to one answer. */
data class ConnectionActivity(
  val messageId: String,
  val notice: String?,
  val services: List<ConnectorId>,
  val sources: List<WebSource>,
  val receipts: List<ConnectionActionReceipt>,
)

/**
 * Device-direct connections (no Turing relay): catalog statuses, token/OAuth/device sign-in,
 * defaults and per-chat access, the review queue for non-read actions, and per-answer activity.
 * Failures surface as `ConnectorException` with a user-presentable message.
 */
interface ConnectionsRepository {
  fun observeStatuses(): Flow<List<ConnectionStatus>>
  /** Re-reads permission-dependent statuses (e.g. after returning from system settings). */
  fun refreshStatuses()

  fun observeDefaults(): Flow<ConnectorSelection>
  suspend fun setDefault(service: ConnectorId, enabled: Boolean)
  fun observeChatAccess(conversationId: String): Flow<ChatConnectionAccess>
  suspend fun setChatAccess(conversationId: String, service: ConnectorId, enabled: Boolean)
  /** Drops the chat's own choice so it follows the defaults again. */
  suspend fun resetChatAccess(conversationId: String)

  /** Verifies a personal token against the service before storing it. */
  suspend fun connectWithToken(service: ConnectorId, token: String)
  /** Android runtime permissions to request after the person taps Allow access. */
  fun devicePermissions(service: ConnectorId): Array<String>
  /** Records a device connection once its permission is granted (throws DENIED otherwise). */
  suspend fun connectDevice(service: ConnectorId)
  suspend fun disconnect(service: ConnectorId)

  /** Public client ID bundled with this build (empty = owner has not registered the app). */
  fun buildClientId(service: ConnectorId): String
  /** Developer-registration override (advanced controls), else the build value. */
  fun effectiveClientId(service: ConnectorId): String
  fun developerClientId(service: ConnectorId): String
  suspend fun setDeveloperClientId(service: ConnectorId, value: String)

  val signIn: StateFlow<SignInState>
  /** Discovery/registration, then returns the authorization URL to open in a Custom Tab. */
  suspend fun beginSignIn(service: ConnectorId): String
  /** Called by the redirect activity with the exact callback URI. Unsolicited callbacks are ignored. */
  fun handleRedirect(uri: String)
  fun cancelSignIn()
  fun acknowledgeSignIn()

  val pendingReview: StateFlow<ConnectorReview?>
  fun resolveReview(id: String, approved: Boolean)
  /** Live progress line per assistant message while connected services are being used. */
  val progress: StateFlow<Map<String, String>>
  fun observeActivity(messageId: String): Flow<ConnectionActivity?>
}

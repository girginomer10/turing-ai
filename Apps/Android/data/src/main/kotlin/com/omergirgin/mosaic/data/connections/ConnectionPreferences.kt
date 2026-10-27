package com.omergirgin.mosaic.data.connections

import android.content.Context
import android.content.SharedPreferences
import com.omergirgin.mosaic.core.connections.ConnectorId
import com.omergirgin.mosaic.core.connections.ConnectorSelection
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * Device-only connection choices: chat defaults, per-chat overrides (absent = inherit defaults) and
 * developer client IDs. Only stable connector IDs and generation UUIDs are stored — never
 * credentials — and none of it is exported or backed up.
 */
internal class ConnectionPreferences(context: Context) {
  private val prefs = context.applicationContext.getSharedPreferences("turing_connection_prefs", Context.MODE_PRIVATE)
  private val _version = MutableStateFlow(0L)
  val version: StateFlow<Long> = _version.asStateFlow()

  @Synchronized
  fun defaults(): ConnectorSelection = ConnectorSelection.parse(prefs.getString(DEFAULTS, null))

  @Synchronized
  fun setDefaults(selection: ConnectorSelection) = write { putString(DEFAULTS, selection.raw) }

  /** The chat's own choice, or null when it inherits the defaults. */
  @Synchronized
  fun chatOverride(conversationId: String): ConnectorSelection? =
    prefs.getString(chatKey(conversationId), null)?.let(ConnectorSelection::parse)

  @Synchronized
  fun effective(conversationId: String): ConnectorSelection = chatOverride(conversationId) ?: defaults()

  @Synchronized
  fun setChat(conversationId: String, selection: ConnectorSelection?) = write {
    if (selection == null) remove(chatKey(conversationId)) else putString(chatKey(conversationId), selection.raw)
  }

  /** Conversations that have their own choice (for pruning deleted chats). */
  @Synchronized
  fun chatIds(): List<String> = prefs.all.keys.filter { it.startsWith(CHAT_PREFIX) }.map { it.removePrefix(CHAT_PREFIX) }

  /** Drops every binding that shares [credentialKey] (one Microsoft sign-in serves five services). */
  @Synchronized
  fun removeEverywhere(credentialKey: String) {
    val editor = prefs.edit()
    fun strip(raw: String?): String? {
      val selection = ConnectorSelection.parse(raw)
      val kept = selection.bindings.filterKeys { it.credentialKey != credentialKey }
      return if (kept.size == selection.bindings.size) null else ConnectorSelection(kept).raw
    }
    for ((key, value) in prefs.all) {
      if (key != DEFAULTS && !key.startsWith(CHAT_PREFIX)) continue
      strip(value as? String)?.let { editor.putString(key, it) }
    }
    editor.commit()
    _version.update { it + 1 }
  }

  @Synchronized
  fun clientId(service: ConnectorId): String = prefs.getString(CLIENT_PREFIX + service.credentialKey, null).orEmpty()

  @Synchronized
  fun setClientId(service: ConnectorId, value: String) = write {
    if (value.isBlank()) remove(CLIENT_PREFIX + service.credentialKey) else putString(CLIENT_PREFIX + service.credentialKey, value.trim())
  }

  private fun write(block: SharedPreferences.Editor.() -> Unit) {
    prefs.edit().apply(block).commit()
    _version.update { it + 1 }
  }

  private fun chatKey(conversationId: String) = CHAT_PREFIX + conversationId

  private companion object {
    const val DEFAULTS = "defaults"
    const val CHAT_PREFIX = "chat."
    const val CLIENT_PREFIX = "client."
  }
}

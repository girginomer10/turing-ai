package com.omergirgin.mosaic.data.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.stringPreferencesKey
import com.omergirgin.mosaic.data.api.SettingsRepository
import com.omergirgin.mosaic.data.model.AppSettings
import com.omergirgin.mosaic.data.model.ModelChoice
import java.io.IOException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/** App-local preferences (never part of a portable backup, like iOS). */
internal class DataStoreSettingsRepository(private val store: DataStore<Preferences>) : SettingsRepository {

  override val settings: Flow<AppSettings> = store.data
    // A corrupt or unreadable preferences file falls back to defaults instead of crashing the UI.
    .catch { error -> if (error is IOException) emit(emptyPreferences()) else throw error }
    .map(::decode)
    .distinctUntilChanged()

  override suspend fun setDefaultModel(choice: ModelChoice?) {
    store.edit { prefs ->
      if (choice == null) prefs.remove(DEFAULT_MODEL) else prefs[DEFAULT_MODEL] = encode(listOf(choice))
    }
  }

  override suspend fun setAdvancedControls(enabled: Boolean) {
    store.edit { it[ADVANCED_CONTROLS] = enabled }
  }

  override suspend fun toggleFavorite(choice: ModelChoice) {
    store.edit { prefs ->
      val favorites = decodeList(prefs[FAVORITES])
      prefs[FAVORITES] = encode(if (choice in favorites) favorites - choice else favorites + choice)
    }
  }

  override suspend fun recordRecent(choice: ModelChoice) {
    store.edit { prefs ->
      val recents = listOf(choice) + decodeList(prefs[RECENTS]).filterNot { it == choice }
      prefs[RECENTS] = encode(recents.take(MAX_RECENTS))
    }
  }

  override suspend fun setAutomaticMemoryEnabled(enabled: Boolean) {
    store.edit { it[AUTOMATIC_MEMORY] = enabled }
  }

  override suspend fun setSmartMemoryEnabled(enabled: Boolean) {
    store.edit { it[SMART_MEMORY] = enabled }
  }

  override suspend fun setOnboardingCompleted(done: Boolean) {
    store.edit { it[ONBOARDING_DONE] = done }
  }

  /** Drops every choice that points at a deleted provider. */
  suspend fun forgetProvider(providerId: String) {
    store.edit { prefs ->
      prune(prefs, DEFAULT_MODEL, providerId)
      prune(prefs, FAVORITES, providerId)
      prune(prefs, RECENTS, providerId)
    }
  }

  private fun prune(prefs: MutablePreferences, key: Preferences.Key<String>, providerId: String) {
    val current = decodeList(prefs[key])
    val kept = current.filterNot { it.providerId == providerId }
    if (kept.size == current.size) return
    if (kept.isEmpty()) prefs.remove(key) else prefs[key] = encode(kept)
  }

  private fun decode(prefs: Preferences) = AppSettings(
    defaultModel = decodeList(prefs[DEFAULT_MODEL]).firstOrNull(),
    advancedControls = prefs[ADVANCED_CONTROLS] ?: false,
    favorites = decodeList(prefs[FAVORITES]).toSet(),
    recentModels = decodeList(prefs[RECENTS]),
    hasCompletedOnboarding = prefs[ONBOARDING_DONE] ?: false,
    automaticMemoryEnabled = prefs[AUTOMATIC_MEMORY] ?: true,
    smartMemoryEnabled = prefs[SMART_MEMORY] ?: true,
  )

  @Serializable
  private data class StoredChoice(val p: String, val m: String)

  // JSON rather than a delimiter: model IDs may contain ':', '/', '@' and other separators.
  private fun encode(choices: Collection<ModelChoice>): String =
    json.encodeToString(serializer, choices.map { StoredChoice(it.providerId, it.modelId) })

  private fun decodeList(raw: String?): List<ModelChoice> {
    if (raw.isNullOrEmpty()) return emptyList()
    return runCatching { json.decodeFromString(serializer, raw) }
      .getOrDefault(emptyList())
      .filter { it.p.isNotEmpty() && it.m.isNotEmpty() }
      .map { ModelChoice(it.p, it.m) }
      .distinct()
  }

  private companion object {
    const val MAX_RECENTS = 12
    val DEFAULT_MODEL = stringPreferencesKey("default_model")
    val ADVANCED_CONTROLS = booleanPreferencesKey("advanced_controls")
    val FAVORITES = stringPreferencesKey("favorite_models")
    val RECENTS = stringPreferencesKey("recent_models")
    val ONBOARDING_DONE = booleanPreferencesKey("onboarding_completed")
    val AUTOMATIC_MEMORY = booleanPreferencesKey("automatic_memory_enabled")
    val SMART_MEMORY = booleanPreferencesKey("smart_memory_enabled")
    val json = Json { ignoreUnknownKeys = true }
    val serializer = ListSerializer(StoredChoice.serializer())
  }
}

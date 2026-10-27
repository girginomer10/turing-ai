package com.omergirgin.mosaic.data.live

import com.omergirgin.mosaic.core.chat.ProviderErrorKind
import com.omergirgin.mosaic.core.chat.ProviderException
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.profile
import com.omergirgin.mosaic.core.provider.supportsLiveTranscription
import com.omergirgin.mosaic.data.api.LiveTranscriptionRepository
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.ProviderEntity
import com.omergirgin.mosaic.data.repo.ProviderRepositoryImpl
import com.omergirgin.mosaic.data.security.SecretStore
import com.omergirgin.mosaic.data.security.StoredKey
import java.net.URI
import kotlinx.coroutines.flow.first

/** A Google Gemini connection that may be used for live transcription (no key material). */
data class LiveTranscriptionTarget(
  val providerId: String,
  val displayName: String,
  /** Always Google's fixed Gemini origin host. */
  val host: String,
)

/** The connection plus its endpoint-bound key. [toString] never prints the key. */
class LiveTranscriptionCredential(val target: LiveTranscriptionTarget, val apiKey: String) {
  override fun toString(): String = "LiveTranscriptionCredential(target=$target, apiKey=••••)"
}

/**
 * iOS `isEligibleLiveTranscriptionProvider`: an enabled Google record whose resolved destination
 * is exactly `https://generativelanguage.googleapis.com` (default port). The chat-selected
 * connection wins when eligible; otherwise the first eligible one in provider-list order.
 */
internal class LiveTranscriptionRepositoryImpl(
  private val db: MosaicDatabase,
  private val secrets: SecretStore,
) : LiveTranscriptionRepository {

  override suspend fun eligibleConnection(preferredProviderId: String?): LiveTranscriptionTarget? {
    val eligible = db.providers().observeAll().first().filter(::isEligible)
    val chosen = eligible.firstOrNull { it.id == preferredProviderId } ?: eligible.firstOrNull()
    return chosen?.let(::target)
  }

  override suspend fun resolveCredential(providerId: String): LiveTranscriptionCredential {
    val provider = db.providers().get(providerId)?.takeIf(::isEligible)
      ?: throw ProviderException(
        ProviderErrorKind.INVALID_ENDPOINT,
        "The Google Gemini connection changed. Review the connection and try again.",
      )
    val key = when (val stored = secrets.read(provider.id, ProviderRepositoryImpl.bindingOf(provider))) {
      is StoredKey.Present -> stored.apiKey
      StoredKey.Missing -> throw missingKey("Add a Google API key to this Gemini connection before using live transcription.")
      StoredKey.BindingMismatch ->
        throw missingKey("The saved API key belongs to a different destination. Re-enter the key for this Gemini connection.")
      StoredKey.Unreadable -> throw missingKey("The saved Google API key can no longer be read on this device. Re-enter it in Providers.")
    }
    if (key.isBlank()) throw missingKey("Add a Google API key to this Gemini connection before using live transcription.")
    return LiveTranscriptionCredential(target(provider), key)
  }

  private fun target(provider: ProviderEntity) =
    LiveTranscriptionTarget(providerId = provider.id, displayName = provider.displayName, host = GEMINI_HOST)

  private fun isEligible(provider: ProviderEntity): Boolean {
    val kind = ProviderRepositoryImpl.kindOf(provider)
    if (!provider.isEnabled || kind != ProviderKind.GOOGLE || !kind.supportsLiveTranscription) return false
    val destination = provider.baseUrl?.takeIf { it.isNotBlank() } ?: kind.profile.baseUrl ?: return false
    val uri = runCatching { URI(destination.trim()) }.getOrNull() ?: return false
    return uri.scheme.equals("https", ignoreCase = true) &&
      uri.host?.lowercase() == GEMINI_HOST &&
      uri.rawUserInfo == null &&
      (uri.port == -1 || uri.port == 443)
  }

  private fun missingKey(message: String) = ProviderException(ProviderErrorKind.MISSING_API_KEY, message)

  private companion object {
    const val GEMINI_HOST = "generativelanguage.googleapis.com"
  }
}

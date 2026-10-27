package com.omergirgin.mosaic.data.embeddings

import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.context.utf8Length
import com.omergirgin.mosaic.core.net.embeddings.EmbeddingBatchPolicy
import com.omergirgin.mosaic.core.net.embeddings.EmbeddingInputFormatter
import com.omergirgin.mosaic.core.provider.profile
import com.omergirgin.mosaic.core.provider.supportsEmbeddings
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.ProviderEntity
import com.omergirgin.mosaic.data.db.UsageRecordEntity
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.internal.newId
import com.omergirgin.mosaic.data.repo.ProviderRepositoryImpl
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/** An enabled profile with its provider snapshot, endpoint-bound key and vector-space identity. */
internal class AuthenticatedProfile(
  val profile: EmbeddingProfileEntity,
  /** Provider row as read for this job; any later change makes the job's results stale. */
  val provider: ProviderEntity,
  val connection: ProviderConnection,
  val spaceId: String,
) {
  val modelId: String get() = profile.modelId
}

/**
 * Resolves profiles to authenticated embedding connections through the same endpoint-bound key
 * path as chat, and revalidates them after network suspensions.
 */
internal class EmbeddingProfileResolver(
  private val db: MosaicDatabase,
  private val providers: ProviderRepositoryImpl,
) {
  private val profileDao = db.embeddingProfiles()

  fun isUsable(provider: ProviderEntity?): Boolean =
    provider != null && provider.isEnabled && ProviderRepositoryImpl.kindOf(provider).supportsEmbeddings

  suspend fun provider(profile: EmbeddingProfileEntity): ProviderEntity? =
    profile.providerId?.let { db.providers().get(it) }

  fun spaceId(provider: ProviderEntity, modelId: String): String {
    val kind = ProviderRepositoryImpl.kindOf(provider)
    val resolvedBaseUrl = provider.baseUrl?.takeIf { it.isNotBlank() } ?: kind.profile.baseUrl
    return EmbeddingInputFormatter.spaceIdentifier(kind, resolvedBaseUrl, modelId)
  }

  /** Throws `ProviderException(MISSING_API_KEY)` when the preset requires a key that is unavailable. */
  suspend fun authenticate(profile: EmbeddingProfileEntity, provider: ProviderEntity): AuthenticatedProfile {
    val kind = ProviderRepositoryImpl.kindOf(provider)
    val key = providers.keyFor(provider, kind, required = kind.profile.requiresApiKey)
    val connection = ProviderConnection(
      id = provider.id,
      displayName = provider.displayName,
      provider = kind,
      baseUrl = provider.baseUrl,
      modelId = profile.modelId,
      apiKey = key,
    )
    return AuthenticatedProfile(profile, provider, connection, spaceId(provider, profile.modelId))
  }

  /** True while the profile, its provider and the vector-space identity are exactly unchanged. */
  suspend fun isCurrent(job: AuthenticatedProfile): Boolean {
    val profile = profileDao.get(job.profile.id) ?: return false
    if (profile != job.profile || !profile.isEnabled || profile.providerId != job.provider.id) return false
    val provider = db.providers().get(job.provider.id) ?: return false
    if (provider != job.provider || !isUsable(provider)) return false
    return spaceId(provider, profile.modelId) == job.spaceId
  }
}

/** Records reported embedding tokens as "Embeddings" usage; bookkeeping never fails a request. */
internal class EmbeddingUsageRecorder(private val db: MosaicDatabase) {
  suspend fun record(job: AuthenticatedProfile, inputTokens: Int?, conversationId: String?) {
    if (inputTokens == null) return
    withContext(NonCancellable) {
      runCatching {
        db.usage().insert(
          UsageRecordEntity(
            id = newId(),
            providerId = job.provider.id,
            providerKind = job.connection.provider.rawId,
            providerName = job.provider.displayName,
            modelId = job.modelId,
            destinationHost = job.connection.destinationHost,
            category = CATEGORY,
            inputTokens = inputTokens,
            outputTokens = null,
            conversationId = conversationId,
            messageId = null,
            createdAt = MonotonicClock.now(),
          )
        )
      }
    }
  }

  companion object {
    const val CATEGORY = "Embeddings"
  }
}

/**
 * Splits items into request batches of at most [maximumCount] inputs and the client's UTF-8 byte
 * ceiling, preserving order. A single input above the ceiling cannot be embedded and is skipped
 * (it stays available to local lexical recall).
 */
internal fun <T> embeddingBatches(items: List<T>, maximumCount: Int, text: (T) -> String): List<List<T>> {
  val batches = ArrayList<List<T>>()
  var current = ArrayList<T>()
  var currentBytes = 0L
  for (item in items) {
    val bytes = utf8Length(text(item)).toLong()
    if (bytes == 0L || bytes > EmbeddingBatchPolicy.MAXIMUM_BATCH_UTF8_BYTES) continue
    if (current.size >= maximumCount || currentBytes + bytes > EmbeddingBatchPolicy.MAXIMUM_BATCH_UTF8_BYTES) {
      if (current.isNotEmpty()) batches += current
      current = ArrayList()
      currentBytes = 0
    }
    current += item
    currentBytes += bytes
  }
  if (current.isNotEmpty()) batches += current
  return batches
}

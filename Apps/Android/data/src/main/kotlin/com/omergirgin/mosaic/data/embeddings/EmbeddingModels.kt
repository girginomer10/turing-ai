package com.omergirgin.mosaic.data.embeddings

/** UI-facing embedding profile (one provider connection + one embedding model = one vector space). */
data class EmbeddingProfile(
  val id: String,
  val displayName: String,
  /** null when the provider connection was deleted. */
  val providerId: String?,
  val modelId: String,
  val weight: Double,
  val isEnabled: Boolean,
  val indexesConversations: Boolean,
  val indexesDocuments: Boolean,
  val createdAt: Long,
  val updatedAt: Long,
)

/** Create ([id] null) or update a profile. */
data class EmbeddingProfileDraft(
  val id: String?,
  val displayName: String,
  val providerId: String,
  val modelId: String,
  val weight: Double = 1.0,
  val isEnabled: Boolean = true,
  val indexesConversations: Boolean = true,
  val indexesDocuments: Boolean = true,
)

object EmbeddingProfilePolicy {
  /** Up to four enabled profiles run in parallel; the editor prevents a fifth. */
  const val MAXIMUM_ENABLED_PROFILES: Int = 4
  const val MINIMUM_WEIGHT: Double = 0.25
  const val MAXIMUM_WEIGHT: Double = 2.0
  const val LIMIT_DESCRIPTION: String =
    "Turing AI can use up to four embedding models at once. Disable another model before enabling this one."
}

enum class EmbeddingProfileAvailability { AVAILABLE, PROVIDER_UNAVAILABLE, PROFILE_LIMIT_EXCEEDED }

/** Document-vector coverage for one enabled, document-indexing profile. */
data class DocumentProfileHealth(
  val profileId: String,
  val displayName: String,
  val availability: EmbeddingProfileAvailability,
  val indexedDocumentCount: Int,
  val validVectorCount: Int,
  val missingVectorCount: Int,
  val staleVectorCount: Int,
) {
  val expectedVectorCount: Int get() = validVectorCount + missingVectorCount + staleVectorCount
  val needsAttention: Boolean
    get() = availability != EmbeddingProfileAvailability.AVAILABLE || missingVectorCount > 0 || staleVectorCount > 0
}

/** Health of the rebuildable document-vector cache; stale data is never reported as ready. */
data class DocumentIndexHealth(
  val enabledDocumentCount: Int,
  val chunkCount: Int,
  val storedVectorCount: Int,
  val orphanVectorCount: Int,
  val profiles: List<DocumentProfileHealth>,
  /** The persistent cache could not be opened; vectors last only for this session. */
  val isTemporary: Boolean,
) {
  val validVectorCount: Int get() = profiles.sumOf { it.validVectorCount }
  val expectedVectorCount: Int get() = profiles.sumOf { it.expectedVectorCount }
  val missingVectorCount: Int get() = profiles.sumOf { it.missingVectorCount }
  val staleVectorCount: Int get() = profiles.sumOf { it.staleVectorCount }
  val needsAttention: Boolean get() = isTemporary || orphanVectorCount > 0 || profiles.any { it.needsAttention }
  val canRebuild: Boolean
    get() = orphanVectorCount > 0 ||
      (chunkCount > 0 && profiles.any { it.availability == EmbeddingProfileAvailability.AVAILABLE })
}

enum class DocumentIndexingOutcome { SUCCESS, WARNING, FAILURE }

/** Background document indexing/rebuild state (one operation at a time). */
data class DocumentIndexingStatus(
  val isRunning: Boolean = false,
  val outcome: DocumentIndexingOutcome? = null,
  val message: String? = null,
)

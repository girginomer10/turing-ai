package com.omergirgin.mosaic.data.pricing

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Query
import androidx.room.Upsert
import com.omergirgin.mosaic.core.provider.BundledModelCatalog
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.UsageRecordEntity
import com.omergirgin.mosaic.data.embeddings.EmbeddingUsageRecorder
import com.omergirgin.mosaic.data.internal.FieldLimits
import com.omergirgin.mosaic.data.internal.MonotonicClock
import java.time.Instant
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/** Custom USD-per-million-token rates for one connection's model (a special account tariff). */
data class ModelPriceOverride(
  val providerId: String,
  val modelId: String,
  val inputPerMillion: Double,
  val outputPerMillion: Double,
  val updatedAt: Long,
)

/**
 * Per-model custom rates for Usage & cost (iOS per-model price preferences). Overrides take
 * precedence over the bundled list, also price custom endpoints, keep working after the bundled
 * list expires, and recalculate retained history. They outlive their connection so history from
 * a deleted connection keeps its custom estimate.
 */
interface ModelPriceRepository {
  fun observeOverrides(): Flow<List<ModelPriceOverride>>

  /** Both rates are required; zero is allowed. Throws IllegalArgumentException for invalid values. */
  suspend fun setOverride(providerId: String, modelId: String, inputPerMillion: Double, outputPerMillion: Double)

  /** "Return to default": removes only the custom rates; estimates use the bundled list again. */
  suspend fun resetOverride(providerId: String, modelId: String)
}

/**
 * Durable custom rates. Room (not DataStore) because, like iOS, they belong to the portable
 * library and are exported with backups. Additive table; no foreign key, by design (see above).
 */
@Entity(tableName = "model_price_overrides", primaryKeys = ["providerId", "modelId"])
internal data class ModelPriceOverrideEntity(
  val providerId: String,
  val modelId: String,
  val inputPerMillion: Double,
  val outputPerMillion: Double,
  val updatedAt: Long,
)

@Dao
internal interface ModelPriceOverrideDao {
  @Query("SELECT * FROM model_price_overrides ORDER BY providerId, modelId")
  fun observeAll(): Flow<List<ModelPriceOverrideEntity>>

  @Query("SELECT * FROM model_price_overrides ORDER BY providerId, modelId")
  suspend fun all(): List<ModelPriceOverrideEntity>

  @Upsert
  suspend fun upsert(entity: ModelPriceOverrideEntity)

  @Query("DELETE FROM model_price_overrides WHERE providerId = :providerId AND modelId = :modelId")
  suspend fun delete(providerId: String, modelId: String)
}

internal class ModelPriceRepositoryImpl(private val db: MosaicDatabase) : ModelPriceRepository {
  private val dao = db.priceOverrides()

  override fun observeOverrides(): Flow<List<ModelPriceOverride>> =
    dao.observeAll().map { rows -> rows.map { it.toModel() } }.distinctUntilChanged()

  override suspend fun setOverride(providerId: String, modelId: String, inputPerMillion: Double, outputPerMillion: Double) {
    require(providerId.isNotBlank() && modelId.isNotEmpty()) { "Choose a model before setting rates." }
    FieldLimits.requireWithin(modelId, FieldLimits.MODEL_ID_BYTES, "The model ID")
    require(UsagePricing.isValidRate(inputPerMillion) && UsagePricing.isValidRate(outputPerMillion)) {
      "Enter valid nonnegative USD rates."
    }
    dao.upsert(ModelPriceOverrideEntity(providerId, modelId, inputPerMillion, outputPerMillion, MonotonicClock.now()))
  }

  override suspend fun resetOverride(providerId: String, modelId: String) {
    dao.delete(providerId, modelId)
  }
}

private fun ModelPriceOverrideEntity.toModel() =
  ModelPriceOverride(providerId, modelId, inputPerMillion, outputPerMillion, updatedAt)

/** Estimate for one usage record. */
internal class UsageEstimate(
  /** null when the request is left out of the estimate. */
  val costUsd: Double?,
  val usesCustomRate: Boolean,
  /** The provider did not report complete token usage for this request. */
  val isUnreported: Boolean,
)

/**
 * iOS `UsageReportReader`/`UsageReportView` cost rules, applied per request:
 * - a custom rate prices every request of that connection/model at a flat per-token rate
 *   (unreported counts contribute nothing but stay flagged);
 * - otherwise the bundled rate must match the request's provider kind, official host and exact
 *   model, be valid now (current rates recalculate history), and both counts must be reported;
 *   tiers, caps and peak windows use the request's own size and time.
 */
internal object UsagePricing {
  fun isValidRate(value: Double): Boolean = value.isFinite() && value >= 0 && value <= 1_000_000

  fun overrideKey(providerId: String, modelId: String): String = "$providerId\u0000$modelId"

  fun estimate(record: UsageRecordEntity, override: ModelPriceOverrideEntity?, pricedAt: Instant): UsageEstimate {
    val input = record.inputTokens?.coerceIn(0, MAXIMUM_TOKENS)
    // Embedding requests have no output tokens; a missing output count is not missing usage.
    val outputApplies = record.category != EmbeddingUsageRecorder.CATEGORY
    val output = if (outputApplies) record.outputTokens?.coerceIn(0, MAXIMUM_TOKENS) else 0
    val unreported = input == null || output == null
    if (override != null && isValidRate(override.inputPerMillion) && isValidRate(override.outputPerMillion)) {
      val cost = ((input ?: 0).toDouble() * override.inputPerMillion + (output ?: 0).toDouble() * override.outputPerMillion) /
        1_000_000
      return UsageEstimate(cost, usesCustomRate = true, isUnreported = unreported)
    }
    if (input == null || output == null || !outputApplies) return UsageEstimate(null, false, unreported)
    val kind = ProviderKind.fromRawId(record.providerKind) ?: return UsageEstimate(null, false, unreported)
    val cost = BundledModelCatalog.estimateCostUsd(
      kind = kind,
      modelId = record.modelId,
      host = record.destinationHost,
      inputTokens = input.toLong(),
      outputTokens = output.toLong(),
      at = Instant.ofEpochMilli(record.createdAt),
      pricedAt = pricedAt,
    )
    return UsageEstimate(cost, false, unreported)
  }

  private const val MAXIMUM_TOKENS = 1_000_000_000
}

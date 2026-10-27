package com.omergirgin.mosaic.data.repo

import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.data.api.UsageRepository
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.UsageRecordEntity
import com.omergirgin.mosaic.data.model.UsageCategorySummary
import com.omergirgin.mosaic.data.model.UsageSummary
import com.omergirgin.mosaic.data.pricing.ModelPriceOverrideEntity
import com.omergirgin.mosaic.data.pricing.UsageEstimate
import com.omergirgin.mosaic.data.pricing.UsagePricing
import java.time.Instant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map

/**
 * Reported-token totals per provider/model. Costs follow the iOS rules (`UsagePricing`): the
 * user's custom per-model rates take precedence; otherwise only the preset's official host is
 * priced from the bundled list (a custom endpoint may bill differently), with rates valid now so
 * current rates recalculate retained history, and tiers/caps/peak multipliers per request.
 */
internal class UsageRepositoryImpl(private val db: MosaicDatabase) : UsageRepository {

  /** Custom rates by connection + model; any change reprices the retained history. */
  private val customRates: Flow<Map<String, ModelPriceOverrideEntity>> =
    db.priceOverrides().observeAll()
      .map { rows -> rows.associateBy { UsagePricing.overrideKey(it.providerId, it.modelId) } }

  override fun observeUsage(sinceMillis: Long): Flow<List<UsageSummary>> =
    combine(db.usage().observeSince(sinceMillis), customRates, ::summarize)
      .distinctUntilChanged()
      .flowOn(Dispatchers.Default)

  private fun summarize(rows: List<UsageRecordEntity>, rates: Map<String, ModelPriceOverrideEntity>): List<UsageSummary> {
    val pricedAt = Instant.now()
    return rows
      .groupBy { Triple(it.providerId, it.providerName, it.modelId) }
      .map { (key, records) ->
        var cost = 0.0
        var pricedRequests = 0
        var usesCustomRate = false
        var unreported = 0
        for (record in records) {
          val estimate = estimate(record, rates, pricedAt)
          if (estimate.usesCustomRate) usesCustomRate = true
          if (estimate.isUnreported) unreported++
          cost += estimate.costUsd ?: continue
          pricedRequests++
        }
        // Rows arrive ordered by createdAt: the last one carries the newest kind/host snapshot.
        val newest = records.last()
        UsageSummary(
          providerName = key.second,
          modelId = key.third,
          requests = records.size,
          inputTokens = records.sumOf { (it.inputTokens ?: 0).coerceAtLeast(0).toLong() },
          outputTokens = records.sumOf { (it.outputTokens ?: 0).coerceAtLeast(0).toLong() },
          // Null (not $0) when nothing in the group has a verified or custom price.
          estimatedCostUsd = if (pricedRequests > 0) cost else null,
          providerId = key.first,
          providerKind = ProviderKind.fromRawId(newest.providerKind),
          destinationHost = newest.destinationHost,
          usesCustomRate = usesCustomRate,
          unpricedRequests = records.size - pricedRequests,
          unreportedRequests = unreported,
        )
      }
      .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER, UsageSummary::providerName).thenBy { it.modelId })
  }

  override fun observeUsageByCategory(sinceMillis: Long): Flow<List<UsageCategorySummary>> =
    combine(db.usage().observeSince(sinceMillis), customRates, ::summarizeCategories)
      .distinctUntilChanged()
      .flowOn(Dispatchers.Default)

  /** Same per-request estimate as [summarize], grouped by the stored category label. */
  private fun summarizeCategories(
    rows: List<UsageRecordEntity>,
    rates: Map<String, ModelPriceOverrideEntity>,
  ): List<UsageCategorySummary> {
    val pricedAt = Instant.now()
    return rows
      .groupBy { it.category.trim().ifEmpty { "Other" } }
      .map { (category, records) ->
        val estimates = records.mapNotNull { estimate(it, rates, pricedAt).costUsd }
        UsageCategorySummary(
          category = category,
          requests = records.size,
          inputTokens = records.sumOf { (it.inputTokens ?: 0).coerceAtLeast(0).toLong() },
          outputTokens = records.sumOf { (it.outputTokens ?: 0).coerceAtLeast(0).toLong() },
          estimatedCostUsd = if (estimates.isNotEmpty()) estimates.sum() else null,
          unpricedRequests = records.size - estimates.size,
        )
      }
      .sortedWith(compareByDescending<UsageCategorySummary> { it.requests }.thenBy { it.category })
  }

  /** Estimate for one record: custom rate first, else the bundled price valid at [pricedAt]. */
  private fun estimate(
    record: UsageRecordEntity,
    rates: Map<String, ModelPriceOverrideEntity>,
    pricedAt: Instant,
  ): UsageEstimate {
    val custom = record.providerId?.let { rates[UsagePricing.overrideKey(it, record.modelId)] }
    return UsagePricing.estimate(record, custom, pricedAt)
  }
}

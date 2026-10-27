package com.omergirgin.mosaic.core.provider

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.URI
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.EnumMap
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Context-window and output limits for one exact provider/model pair. */
data class ModelLimits(val contextWindowTokens: Int, val maximumOutputTokens: Int)

/** Per-million-token USD prices from the bundled ModelPrices.json. */
data class ModelPrice(
  val inputPerMillion: Double,
  val outputPerMillion: Double,
  val cachedInputPerMillion: Double? = null,
  val source: String? = null,
  val validUntil: String? = null,
  val tiers: List<ModelPriceTier> = emptyList(),
  /** Automatic estimates require no more input tokens than this per request. */
  val maximumInputTokens: Long? = null,
  /** Weekday peak multiplier (UTC 01:00–04:00 and 06:00–10:00), e.g. DeepSeek off-peak pricing. */
  val weekdayPeakMultiplier: Double? = null,
)

data class ModelPriceTier(val fromInputTokens: Long, val inputPerMillion: Double, val outputPerMillion: Double)

/** One row of the bundled price list, for a "reviewed public prices" screen. */
data class PricedModel(val kind: ProviderKind, val modelId: String, val price: ModelPrice)

/**
 * Offline model suggestions, limits and prices shipped with the app (same JSON as iOS
 * `Resources/ProviderModels.json` and `ModelPrices.json`, loaded once from the classpath under
 * `/turing/`). Ports iOS `BundledProviderModelCatalog`, `ProviderModelOptionCatalog`,
 * `ProviderModelMetadataRegistry`, `ModelImageCapability` and `ModelPriceCatalog`.
 *
 * Everything here is a discovery aid, never an account entitlement: a listed model may be
 * unavailable to a given key, and an unlisted one may work fine.
 */
object BundledModelCatalog {
  /** Dated suggestion list for a preset, most-preferred first. Never grants account access. */
  fun models(kind: ProviderKind): List<String> =
    modelData.suggestions[kind]?.takeIf { it.isNotEmpty() } ?: kind.profile.suggestedModels

  fun defaultModel(kind: ProviderKind): String = models(kind).firstOrNull().orEmpty()

  /** Bundled embedding model IDs for a preset (empty when the catalog lists none). */
  fun embeddingModels(kind: ProviderKind): List<String> = modelData.entries[kind]?.embeddingModels.orEmpty()

  /** Exact documentation-backed limits when known, else null. */
  fun documentedLimits(kind: ProviderKind, modelId: String): ModelLimits? {
    val identifier = modelId.trim()
    modelData.entries[kind]?.limits?.get(identifier)?.let {
      return ModelLimits(it.contextWindowTokens, it.maximumOutputTokens)
    }
    return when (kind) {
      ProviderKind.OPENAI ->
        when (identifier) {
          "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.4" -> LARGE_OPENAI_LIMITS
          "gpt-5.4-mini", "gpt-5.4-nano" -> COMPACT_OPENAI_LIMITS
          else -> null
        }
      ProviderKind.ANTHROPIC ->
        when (identifier) {
          "claude-sonnet-5", "claude-opus-5", "claude-fable-5-1" -> CURRENT_CLAUDE_LIMITS
          "claude-haiku-4-5-20251001" -> CLAUDE_HAIKU_45_LIMITS
          else -> null
        }
      else -> null
    }
  }

  /**
   * Exact-model-or-conservative policy: documented limits when known; the preset's default model
   * gets the preset's suggested limits; anything else (custom deployment names, older records)
   * gets a conservative fallback derived from the preset — 32,768/4,096 for hosted presets and
   * 8,192/2,048 for local/custom ones (iOS parity). A provider-wide maximum is never assumed to
   * apply to every model the provider hosts.
   */
  fun resolvedLimits(kind: ProviderKind, modelId: String): ModelLimits {
    documentedLimits(kind, modelId)?.let { return it }
    val default = defaultModel(kind)
    if (default.isNotEmpty() && modelId.trim() == default) {
      return ModelLimits(kind.profile.suggestedContextWindowTokens, kind.profile.suggestedMaximumOutputTokens)
    }
    return conservativeFallback(kind)
  }

  /**
   * Limits to keep after the user switches models: each value the user left at the previous
   * model's default follows the new model's default; hand-tuned values are preserved.
   */
  fun limitsAfterModelChange(
    current: ModelLimits,
    kind: ProviderKind,
    previousModelId: String,
    newModelId: String,
  ): ModelLimits {
    val previous = resolvedLimits(kind, previousModelId)
    val next = resolvedLimits(kind, newModelId)
    return ModelLimits(
      contextWindowTokens =
        if (current.contextWindowTokens == previous.contextWindowTokens) next.contextWindowTokens
        else current.contextWindowTokens,
      maximumOutputTokens =
        if (current.maximumOutputTokens == previous.maximumOutputTokens) next.maximumOutputTokens
        else current.maximumOutputTokens,
    )
  }

  /**
   * Model choices for an editor without treating any source as exhaustive: curated suggestions
   * first, then discovered IDs sorted, and an arbitrary selected ID kept visible at the top even
   * when neither list knows it. Blank IDs and duplicates are dropped.
   */
  fun mergeModelOptions(suggested: List<String>, discovered: List<String>, selected: String? = null): List<String> {
    val seen = HashSet<String>()
    val identifiers = ArrayList<String>(suggested.size + discovered.size + 1)
    fun appendUnique(identifier: String) {
      if (identifier.isNotBlank() && seen.add(identifier)) identifiers.add(identifier)
    }
    suggested.forEach(::appendUnique)
    discovered.sorted().forEach(::appendUnique)
    if (selected != null && selected.isNotBlank() && seen.add(selected)) identifiers.add(0, selected)
    return identifiers
  }

  /**
   * Conservative photo-capable heuristic used by the model chooser. Arbitrary gateway or
   * deployment IDs need an explicit per-model override (stored by the data layer).
   */
  fun supportsImages(kind: ProviderKind, modelId: String): Boolean {
    val model = modelId.lowercase()
    if (NON_IMAGE_MARKERS.any { it in model }) return false
    return when (kind) {
      ProviderKind.OPENAI ->
        model.startsWith("gpt-4o") || model.startsWith("gpt-4.1") || model.startsWith("gpt-5") ||
          model.startsWith("gpt-6") || model == "o3" || model == "o4-mini"
      // Includes the Claude 5 family, which the older iOS heuristic does not list yet.
      ProviderKind.ANTHROPIC ->
        model.startsWith("claude-3") || model.startsWith("claude-sonnet-4") ||
          model.startsWith("claude-opus-4") || model.startsWith("claude-haiku-4") ||
          model.startsWith("claude-sonnet-5") || model.startsWith("claude-opus-5") ||
          model.startsWith("claude-fable-5") || model.startsWith("claude-haiku-5")
      ProviderKind.GOOGLE -> model.startsWith("gemini-2") || model.startsWith("gemini-3")
      else -> false
    }
  }

  /**
   * Reviewed public list price, assuming the connection uses the preset's default endpoint.
   * Null for presets without a fixed endpoint, unknown models, or once the reviewed prices expire.
   */
  fun price(kind: ProviderKind, modelId: String): ModelPrice? =
    price(kind, modelId, host = kind.profile.baseUrl, now = Instant.now())

  /**
   * iOS-parity lookup: prices apply only when the request actually went to the preset's default
   * host (a custom base URL may be a proxy with different billing) and the review is still valid.
   * [host] may be a bare host name or a full URL.
   */
  fun price(kind: ProviderKind, modelId: String, host: String?, now: Instant = Instant.now()): ModelPrice? =
    rate(kind, modelId, host, now)?.toModelPrice(priceData.catalog?.validUntil)

  /**
   * Estimated USD cost for one request, applying input tiers, the per-model input cap and any
   * weekday peak multiplier. Null when no valid price applies or the input exceeds the priced range.
   * [at] is the request time (peak windows); [pricedAt] decides which rates are valid. Usage
   * reports pass "now" so current rates recalculate retained history, like iOS.
   */
  fun estimateCostUsd(
    kind: ProviderKind,
    modelId: String,
    host: String?,
    inputTokens: Long,
    outputTokens: Long,
    at: Instant = Instant.now(),
    pricedAt: Instant = at,
  ): Double? = rate(kind, modelId, host, pricedAt)?.estimate(inputTokens, outputTokens, at)

  /** Every reviewed price row in catalog order (one row per model ID). */
  fun allPrices(): List<PricedModel> {
    val catalog = priceData.catalog ?: return emptyList()
    return catalog.rates.flatMap { rate ->
      val price = rate.toModelPrice(catalog.validUntil)
      rate.models.map { PricedModel(rate.kind, it, price) }
    }
  }

  /** True when the bundled prices are missing, invalid, or past their review deadline. */
  val isPriceCatalogOutdated: Boolean
    get() {
      val catalog = priceData.catalog ?: return true
      return !Instant.now().isBefore(catalog.expiresAt)
    }

  /** Review date of the bundled price list, or "" when unavailable. */
  val pricesVerifiedAt: String get() = priceData.catalog?.verifiedAt.orEmpty()

  /** Review date of the bundled model catalog (ProviderModels.json), or "" when unavailable. */
  val verifiedAt: String get() = modelData.verifiedAt

  /** Lowercased host from a bare host or URL; null for anything ambiguous (paths, userinfo, ports). */
  fun normalizedHost(value: String): String? {
    if ("://" in value) return runCatching { URI(value).host }.getOrNull()?.lowercase()
    if ('/' in value || '@' in value || ':' in value) return null
    return value.lowercase()
  }

  // ---- Limits ----

  private val LARGE_OPENAI_LIMITS = ModelLimits(1_050_000, 128_000)
  private val COMPACT_OPENAI_LIMITS = ModelLimits(400_000, 128_000)
  private val CURRENT_CLAUDE_LIMITS = ModelLimits(1_000_000, 128_000)
  private val CLAUDE_HAIKU_45_LIMITS = ModelLimits(200_000, 64_000)

  private val NON_IMAGE_MARKERS = listOf("audio", "transcribe", "tts", "realtime", "embedding")

  /** Clamps the preset's suggestion into a safe window and leaves headroom for the prompt. */
  private fun conservativeFallback(kind: ProviderKind): ModelLimits {
    val profile = kind.profile
    val contextWindow = profile.suggestedContextWindowTokens.coerceIn(2_048, 32_768)
    val safetyMargin = (contextWindow / 8).coerceIn(512, 2_048)
    val maximumSafeOutput = maxOf(128, contextWindow - safetyMargin - 1)
    val maximumOutput = minOf(4_096, maxOf(128, profile.suggestedMaximumOutputTokens), maximumSafeOutput)
    return ModelLimits(contextWindow, maximumOutput)
  }

  // ---- Prices ----

  private fun rate(kind: ProviderKind, modelId: String, host: String?, now: Instant): Rate? {
    host ?: return null
    val presetHost = kind.profile.baseUrl?.let { runCatching { URI(it).host }.getOrNull() }?.lowercase()
    val requestHost = normalizedHost(host)
    if (presetHost == null || requestHost != presetHost) return null
    val catalog = priceData.catalog ?: return null
    if (!now.isBefore(catalog.expiresAt)) return null
    val rate = priceData.rates["${kind.rawId}/$modelId"] ?: return null
    if (rate.expiresAt != null && !now.isBefore(rate.expiresAt)) return null
    return rate
  }

  /** Midnight UTC at the start of the given ISO date; malformed dates count as already expired. */
  private fun deadline(value: String): Instant =
    runCatching { LocalDate.parse(value).atStartOfDay(ZoneOffset.UTC).toInstant() }.getOrDefault(Instant.MIN)

  private class Rate(
    val kind: ProviderKind,
    val models: List<String>,
    val input: Double,
    val output: Double,
    val source: String,
    val tiers: List<TierJson>,
    val maximumInput: Long?,
    val weekdayPeakMultiplier: Double?,
    val validUntil: String?,
  ) {
    val expiresAt: Instant? = validUntil?.let(::deadline)

    fun estimate(inputTokens: Long, outputTokens: Long, at: Instant): Double? {
      if (inputTokens < 0 || outputTokens < 0) return null
      if (maximumInput != null && inputTokens > maximumInput) return null
      val tier = tiers.lastOrNull { inputTokens >= it.fromInput }
      var multiplier = 1.0
      if (weekdayPeakMultiplier != null) {
        // Peak windows are published in UTC: Monday–Friday, 01:00–04:00 and 06:00–10:00.
        val utc = at.atZone(ZoneOffset.UTC)
        val weekday = utc.dayOfWeek != DayOfWeek.SATURDAY && utc.dayOfWeek != DayOfWeek.SUNDAY
        val hour = utc.hour
        if (weekday && (hour in 1..3 || hour in 6..9)) multiplier = weekdayPeakMultiplier
      }
      return (inputTokens.toDouble() * (tier?.input ?: input) + outputTokens.toDouble() * (tier?.output ?: output)) *
        multiplier / 1_000_000
    }

    /** The effective expiry is whichever comes first: this rate's or the whole catalog's. */
    fun toModelPrice(catalogValidUntil: String?): ModelPrice =
      ModelPrice(
        inputPerMillion = input,
        outputPerMillion = output,
        source = source,
        validUntil = listOfNotNull(validUntil, catalogValidUntil).minOrNull(),
        tiers = tiers.map { ModelPriceTier(it.fromInput, it.input, it.output) },
        maximumInputTokens = maximumInput,
        weekdayPeakMultiplier = weekdayPeakMultiplier,
      )
  }

  private class PriceCatalog(val verifiedAt: String, val validUntil: String, val rates: List<Rate>) {
    val expiresAt: Instant = deadline(validUntil)
  }

  private class PriceData(val catalog: PriceCatalog?, val rates: Map<String, Rate>)

  private val priceData: PriceData by lazy {
    val catalog = loadPriceCatalog()
    val rates = HashMap<String, Rate>()
    // First occurrence wins for duplicate provider/model pairs (iOS parity).
    catalog?.rates?.forEach { rate -> rate.models.forEach { rates.putIfAbsent("${rate.kind.rawId}/$it", rate) } }
    PriceData(catalog, rates)
  }

  /**
   * Rejects the whole file when any row looks wrong (non-HTTPS source, absurd or negative rates),
   * so a bad edit can never surface a partially trusted price list.
   */
  private fun loadPriceCatalog(): PriceCatalog? {
    val bytes = readResource("/turing/ModelPrices.json", maxBytes = 2_000_000) ?: return null
    val decoded = runCatching { json.decodeFromString<PriceCatalogJson>(bytes.decodeToString()) }.getOrNull()
      ?: return null
    if (decoded.entries.size > 10_000) return null
    fun validPrice(value: Double) = value.isFinite() && value >= 0 && value <= 1_000_000
    val valid = decoded.entries.all { rate ->
      val source = runCatching { URI(rate.source) }.getOrNull()
      source?.scheme == "https" && source.host != null && rate.models.isNotEmpty() &&
        validPrice(rate.input) && validPrice(rate.output) &&
        rate.tiers.orEmpty().all { it.fromInput >= 0 && validPrice(it.input) && validPrice(it.output) }
    }
    if (!valid) return null
    val rates = decoded.entries.mapNotNull { rate ->
      val kind = ProviderKind.fromRawId(rate.provider) ?: return@mapNotNull null
      Rate(
        kind = kind,
        models = rate.models,
        input = rate.input,
        output = rate.output,
        source = rate.source,
        tiers = rate.tiers.orEmpty(),
        maximumInput = rate.maximumInput,
        weekdayPeakMultiplier = rate.weekdayPeakMultiplier,
        validUntil = rate.validUntil,
      )
    }
    return PriceCatalog(decoded.verifiedAt, decoded.validUntil, rates)
  }

  // ---- Model catalog ----

  private class ModelData(
    val verifiedAt: String,
    val entries: Map<ProviderKind, EntryJson>,
    val suggestions: Map<ProviderKind, List<String>>,
  )

  private val modelData: ModelData by lazy {
    val bytes = readResource("/turing/ProviderModels.json", maxBytes = Int.MAX_VALUE)
    val decoded = bytes?.let { runCatching { json.decodeFromString<ModelCatalogJson>(it.decodeToString()) }.getOrNull() }
    val entries = EnumMap<ProviderKind, EntryJson>(ProviderKind::class.java)
    decoded?.providers?.forEach { entry ->
      val kind = ProviderKind.fromRawId(entry.provider) ?: return@forEach
      entries.putIfAbsent(kind, entry)
    }
    // Curated picks the catalog still lists come first; every bundled ID follows, sorted.
    val suggestions = EnumMap<ProviderKind, List<String>>(ProviderKind::class.java)
    entries.forEach { (kind, entry) ->
      val bundled = entry.models.toHashSet()
      val preferred = kind.profile.suggestedModels.filter { it in bundled }
      suggestions[kind] = mergeModelOptions(suggested = preferred, discovered = entry.models)
    }
    ModelData(decoded?.verifiedAt.orEmpty(), entries, suggestions)
  }

  // ---- Loading ----

  private val json = Json { ignoreUnknownKeys = true }

  private fun readResource(path: String, maxBytes: Int): ByteArray? =
    runCatching {
      BundledModelCatalog::class.java.getResourceAsStream(path)?.use { it.readCapped(maxBytes) }
    }.getOrNull()

  /**
   * Reads at most [maxBytes]; returns null when the stream is larger, matching the iOS size guard.
   * Manual loop because `InputStream.readNBytes` only exists on Android API 33+.
   */
  private fun InputStream.readCapped(maxBytes: Int): ByteArray? {
    val out = ByteArrayOutputStream()
    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
    while (true) {
      val read = read(buffer)
      if (read < 0) break
      if (out.size().toLong() + read > maxBytes) return null
      out.write(buffer, 0, read)
    }
    return out.toByteArray()
  }

  @Serializable
  private class ModelCatalogJson(val verifiedAt: String, val providers: List<EntryJson>)

  @Serializable
  private class EntryJson(
    val provider: String,
    val models: List<String>,
    val embeddingModels: List<String>? = null,
    val limits: Map<String, LimitsJson>? = null,
  )

  @Serializable
  private class LimitsJson(val contextWindowTokens: Int, val maximumOutputTokens: Int)

  @Serializable
  private class PriceCatalogJson(val verifiedAt: String, val validUntil: String, val entries: List<RateJson>)

  @Serializable
  private class RateJson(
    val provider: String,
    val models: List<String>,
    val input: Double,
    val output: Double,
    val source: String,
    val tiers: List<TierJson>? = null,
    val maximumInput: Long? = null,
    val weekdayPeakMultiplier: Double? = null,
    val validUntil: String? = null,
  )

  @Serializable
  private class TierJson(val fromInput: Long, val input: Double, val output: Double)
}

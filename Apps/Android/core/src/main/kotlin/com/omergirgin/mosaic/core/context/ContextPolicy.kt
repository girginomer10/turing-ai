package com.omergirgin.mosaic.core.context

import java.text.NumberFormat
import java.util.Locale

/** Provider-independent limits that keep one chat request inside a conservative context window. */
class ContextPolicy(
  contextWindowTokens: Int = 32_768,
  maximumOutputTokens: Int = 4_096,
  safetyMarginTokens: Int = 2_048,
  minimumRecentTurns: Int = 2,
) {
  val contextWindowTokens: Int = contextWindowTokens.coerceAtLeast(1)
  val maximumOutputTokens: Int = maximumOutputTokens.coerceAtLeast(1)
  val safetyMarginTokens: Int = safetyMarginTokens.coerceAtLeast(0)
  /** Completed prior turns that are always kept verbatim, in addition to the current user turn. */
  val minimumRecentTurns: Int = minimumRecentTurns.coerceAtLeast(1)

  val availableInputTokens: Int
    get() = (contextWindowTokens - maximumOutputTokens - safetyMarginTokens).coerceAtLeast(1)
}

/** Where the model limits for one request came from; drives the receipt disclosure. */
enum class ContextLimitsSource {
  /** The person saved explicit limits for this exact provider/model. */
  SAVED_OVERRIDE,
  /** Documentation-backed limits from the bundled catalog. */
  DOCUMENTED,
  /** Unknown model: the conservative fallback policy was used. */
  CONSERVATIVE_FALLBACK,
}

data class ResolvedContextLimits(val policy: ContextPolicy, val warnings: List<String>)

/**
 * Port of iOS `ProviderConversationContextLimits`: clamps saved/derived limits into a policy with
 * a positive input budget and a 512–2,048 token safety margin.
 */
object ContextLimitsResolver {
  fun resolve(
    contextWindowTokens: Int,
    maximumOutputTokens: Int,
    source: ContextLimitsSource,
  ): ResolvedContextLimits {
    val contextWindow = maxOf(2_048, contextWindowTokens)
    val safetyMargin = (contextWindow / 8).coerceIn(512, 2_048)
    val maximumAllowedOutput = maxOf(128, contextWindow - safetyMargin - 1)
    val maximumOutput = minOf(maxOf(128, maximumOutputTokens), maximumAllowedOutput)

    val warnings = buildList {
      if (source == ContextLimitsSource.CONSERVATIVE_FALLBACK) {
        add(
          "This model has no documented limits, so Turing AI used a " +
            "${formatted(contextWindow)}-token context and ${formatted(maximumOutput)}-token output. " +
            "Review them in Providers if the model supports more."
        )
      }
      if (contextWindow != contextWindowTokens || maximumOutput != maximumOutputTokens) {
        add("The model limits were adjusted to keep a positive input budget.")
      }
    }

    return ResolvedContextLimits(
      policy = ContextPolicy(
        contextWindowTokens = contextWindow,
        maximumOutputTokens = maximumOutput,
        safetyMarginTokens = safetyMargin,
        minimumRecentTurns = 2,
      ),
      warnings = warnings,
    )
  }

  private fun formatted(value: Int): String = NumberFormat.getIntegerInstance(Locale.US).format(value)
}

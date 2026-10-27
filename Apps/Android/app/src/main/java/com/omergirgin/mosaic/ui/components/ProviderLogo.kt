package com.omergirgin.mosaic.ui.components

import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.omergirgin.mosaic.R
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.displayName

/**
 * Fixed-footprint provider mark (port of iOS `ProviderLogoTile`). Bundled logos keep their original
 * colors on a neutral white plate so they stay legible in both light and dark themes; the
 * theme-aware OpenRouter/Tinfoil marks and kinds without artwork sit on a tone-tinted tile instead.
 * Announced to accessibility services as the provider's display name.
 */
@Composable
fun ProviderLogo(kind: ProviderKind, modifier: Modifier = Modifier, size: Dp = 28.dp) {
  val name = kind.displayName
  val tint = kind.identityTint
  val darkTheme = MaterialTheme.colorScheme.surface.luminance() < 0.5f
  val artworkScale =
    when (kind) {
      ProviderKind.OPENROUTER -> 0.62f
      ProviderKind.TINFOIL -> 0.80f
      ProviderKind.CUSTOM -> 0.54f
      else -> 0.76f
    }
  // Tinfoil's published brand minimum is 32 rendered pixels, so tiny tiles use the fallback icon.
  val artworkPx = with(LocalDensity.current) { (size * artworkScale).toPx() }
  val artwork = logoDrawable(kind, darkTheme)?.takeUnless { kind == ProviderKind.TINFOIL && artworkPx < 32f }
  val usesOriginalColorPlate = artwork != null && kind !in TONE_TILE_KINDS
  val shape = RoundedCornerShape(size * 0.28f)

  Box(
    modifier =
      modifier
        .size(size)
        .clip(shape)
        .background(if (usesOriginalColorPlate) Color.White else tint.copy(alpha = 0.13f))
        .border(
          width = 0.75.dp,
          color = if (usesOriginalColorPlate) PLATE_STROKE else tint.copy(alpha = 0.24f),
          shape = shape,
        )
        .clearAndSetSemantics {
          contentDescription = name
          role = Role.Image
        },
    contentAlignment = Alignment.Center,
  ) {
    if (artwork != null) {
      Image(
        painter = painterResource(artwork),
        contentDescription = null,
        contentScale = ContentScale.Fit,
        modifier = Modifier.size(size * artworkScale),
      )
    } else {
      Icon(
        imageVector = kind.fallbackIcon,
        contentDescription = null,
        tint = tint,
        modifier = Modifier.size(size * 0.5f),
      )
    }
  }
}

/**
 * Logo plus title and optional subtitle, read as one accessibility element (port of iOS
 * `ProviderIdentityView`). [title] defaults to the preset's display name.
 */
@Composable
fun ProviderIdentity(
  kind: ProviderKind,
  modifier: Modifier = Modifier,
  title: String? = null,
  subtitle: String? = null,
  logoSize: Dp = 40.dp,
) {
  val resolvedTitle = title ?: kind.displayName
  val label = if (subtitle.isNullOrEmpty()) resolvedTitle else "$resolvedTitle, $subtitle"
  Row(
    modifier = modifier.clearAndSetSemantics { contentDescription = label },
    horizontalArrangement = Arrangement.spacedBy(maxOf(10.dp, logoSize * 0.28f)),
    verticalAlignment = Alignment.CenterVertically,
  ) {
    ProviderLogo(kind = kind, size = logoSize)
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
      Text(
        text = resolvedTitle,
        style =
          if (logoSize >= 48.dp) MaterialTheme.typography.titleMedium
          else MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold),
        color = MaterialTheme.colorScheme.onSurface,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
      )
      if (!subtitle.isNullOrEmpty()) {
        Text(
          text = subtitle,
          style = MaterialTheme.typography.bodyMedium,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
          maxLines = 2,
          overflow = TextOverflow.Ellipsis,
        )
      }
    }
  }
}

/** Marks drawn in a single theme-specific color rather than fixed multicolor artwork. */
private val TONE_TILE_KINDS = setOf(ProviderKind.OPENROUTER, ProviderKind.TINFOIL, ProviderKind.CUSTOM)

/** iOS `Color.gray.opacity(0.20)`. */
private val PLATE_STROKE = Color(0xFF8E8E93).copy(alpha = 0.20f)

/**
 * Explicit mapping (no `getIdentifier`) so R8 resource shrinking can see every logo is used.
 * OpenRouter and Tinfoil ship light/dark vector variants; custom endpoints have no artwork.
 */
@DrawableRes
private fun logoDrawable(kind: ProviderKind, darkTheme: Boolean): Int? =
  when (kind) {
    ProviderKind.OPENAI -> R.drawable.provider_logo_openai
    ProviderKind.ANTHROPIC -> R.drawable.provider_logo_anthropic
    ProviderKind.GOOGLE -> R.drawable.provider_logo_google
    ProviderKind.XAI -> R.drawable.provider_logo_xai
    ProviderKind.META -> R.drawable.provider_logo_meta
    ProviderKind.MISTRAL -> R.drawable.provider_logo_mistral
    ProviderKind.COHERE -> R.drawable.provider_logo_cohere
    ProviderKind.DEEPSEEK -> R.drawable.provider_logo_deepseek
    ProviderKind.QWEN -> R.drawable.provider_logo_qwen
    ProviderKind.KIMI -> R.drawable.provider_logo_kimi
    ProviderKind.ZAI -> R.drawable.provider_logo_zai
    ProviderKind.MINIMAX -> R.drawable.provider_logo_minimax
    ProviderKind.AI21 -> R.drawable.provider_logo_ai21
    ProviderKind.GROQ -> R.drawable.provider_logo_groq
    ProviderKind.TOGETHER_AI -> R.drawable.provider_logo_together_ai
    ProviderKind.FIREWORKS_AI -> R.drawable.provider_logo_fireworks_ai
    ProviderKind.CEREBRAS -> R.drawable.provider_logo_cerebras
    ProviderKind.SAMBANOVA -> R.drawable.provider_logo_sambanova
    ProviderKind.NVIDIA_NIM -> R.drawable.provider_logo_nvidia_nim
    ProviderKind.NEBIUS -> R.drawable.provider_logo_nebius
    ProviderKind.HYPERBOLIC -> R.drawable.provider_logo_hyperbolic
    ProviderKind.BASETEN -> R.drawable.provider_logo_baseten
    ProviderKind.SCALEWAY -> R.drawable.provider_logo_scaleway
    ProviderKind.DIGITALOCEAN -> R.drawable.provider_logo_digitalocean
    ProviderKind.FEATHERLESS_AI -> R.drawable.provider_logo_featherless_ai
    ProviderKind.CHUTES -> R.drawable.provider_logo_chutes
    ProviderKind.SILICONFLOW -> R.drawable.provider_logo_siliconflow
    ProviderKind.PERPLEXITY -> R.drawable.provider_logo_perplexity
    ProviderKind.HUGGINGFACE -> R.drawable.provider_logo_huggingface
    ProviderKind.OPENROUTER ->
      if (darkTheme) R.drawable.provider_logo_openrouter_dark else R.drawable.provider_logo_openrouter
    ProviderKind.AIML_API -> R.drawable.provider_logo_aiml_api
    ProviderKind.MICROSOFT_FOUNDRY -> R.drawable.provider_logo_microsoft_foundry
    ProviderKind.AMAZON_BEDROCK -> R.drawable.provider_logo_amazon_bedrock
    ProviderKind.DEEPINFRA -> R.drawable.provider_logo_deepinfra
    ProviderKind.TINFOIL -> if (darkTheme) R.drawable.provider_logo_tinfoil_dark else R.drawable.provider_logo_tinfoil
    ProviderKind.VERCEL_AI -> R.drawable.provider_logo_vercel_ai
    ProviderKind.NOVITA_AI -> R.drawable.provider_logo_novita_ai
    ProviderKind.TENCENT_TOKENHUB -> R.drawable.provider_logo_tencent_tokenhub
    ProviderKind.BAIDU_QIANFAN -> R.drawable.provider_logo_baidu_qianfan
    ProviderKind.POE -> R.drawable.provider_logo_poe
    ProviderKind.VOYAGE_AI -> R.drawable.provider_logo_voyage_ai
    ProviderKind.JINA_AI -> R.drawable.provider_logo_jina_ai
    ProviderKind.OLLAMA -> R.drawable.provider_logo_ollama
    ProviderKind.LM_STUDIO -> R.drawable.provider_logo_lm_studio
    ProviderKind.LOCAL_AI -> R.drawable.provider_logo_local_ai
    ProviderKind.VLLM -> R.drawable.provider_logo_vllm
    ProviderKind.SGLANG -> R.drawable.provider_logo_sglang
    ProviderKind.LLAMA_CPP -> R.drawable.provider_logo_llama_cpp
    ProviderKind.JAN -> R.drawable.provider_logo_jan
    ProviderKind.CUSTOM -> null
  }

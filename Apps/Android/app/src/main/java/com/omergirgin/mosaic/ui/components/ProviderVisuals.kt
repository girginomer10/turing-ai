package com.omergirgin.mosaic.ui.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.AltRoute
import androidx.compose.material.icons.rounded.AccountTree
import androidx.compose.material.icons.rounded.Air
import androidx.compose.material.icons.rounded.AllInclusive
import androidx.compose.material.icons.rounded.Adjust
import androidx.compose.material.icons.rounded.Apps
import androidx.compose.material.icons.rounded.ArrowCircleDown
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.AutoAwesomeMotion
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.Celebration
import androidx.compose.material.icons.rounded.ChangeHistory
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Cloud
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.DesktopMac
import androidx.compose.material.icons.rounded.Diamond
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.ElectricBolt
import androidx.compose.material.icons.rounded.FontDownload
import androidx.compose.material.icons.rounded.Forum
import androidx.compose.material.icons.rounded.GpsFixed
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Hexagon
import androidx.compose.material.icons.rounded.HistoryEdu
import androidx.compose.material.icons.rounded.Hive
import androidx.compose.material.icons.rounded.Hub
import androidx.compose.material.icons.rounded.Inventory2
import androidx.compose.material.icons.rounded.KeyboardCommandKey
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material.icons.rounded.Layers
import androidx.compose.material.icons.rounded.Memory
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.NightsStay
import androidx.compose.material.icons.rounded.Psychology
import androidx.compose.material.icons.rounded.Sailing
import androidx.compose.material.icons.rounded.SentimentSatisfied
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.Terminal
import androidx.compose.material.icons.rounded.Thunderstorm
import androidx.compose.material.icons.rounded.Toll
import androidx.compose.material.icons.rounded.TravelExplore
import androidx.compose.material.icons.rounded.ViewInAr
import androidx.compose.material.icons.rounded.WaterDrop
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.ProviderVisualTone
import com.omergirgin.mosaic.core.provider.profile

/**
 * Identity tint for a provider tone (iOS `ProviderKind.identityTint`). PRIMARY follows the
 * theme's foreground so it stays legible in light and dark; ACCENT follows the app accent.
 */
@Composable
@ReadOnlyComposable
fun ProviderVisualTone.color(): Color =
  when (this) {
    ProviderVisualTone.PRIMARY -> MaterialTheme.colorScheme.onSurface
    ProviderVisualTone.ACCENT -> MaterialTheme.colorScheme.primary
    ProviderVisualTone.RED -> Color(red = 0.84f, green = 0.20f, blue = 0.22f)
    ProviderVisualTone.ORANGE -> Color(red = 0.93f, green = 0.43f, blue = 0.12f)
    ProviderVisualTone.YELLOW -> Color(red = 0.82f, green = 0.62f, blue = 0.04f)
    ProviderVisualTone.GREEN -> Color(red = 0.17f, green = 0.58f, blue = 0.29f)
    ProviderVisualTone.TEAL -> Color(red = 0.00f, green = 0.45f, blue = 0.43f)
    ProviderVisualTone.BLUE -> Color(red = 0.16f, green = 0.43f, blue = 0.86f)
    ProviderVisualTone.INDIGO -> Color(red = 0.31f, green = 0.34f, blue = 0.78f)
    ProviderVisualTone.PURPLE -> Color(red = 0.50f, green = 0.35f, blue = 0.85f)
    ProviderVisualTone.PINK -> Color(red = 0.83f, green = 0.25f, blue = 0.53f)
    ProviderVisualTone.BROWN -> Color(red = 0.68f, green = 0.35f, blue = 0.20f)
  }

/** Theme-aware identity tint for a provider preset. */
val ProviderKind.identityTint: Color
  @Composable @ReadOnlyComposable get() = profile.visualTone.color()

/**
 * Material stand-in for the SF Symbol iOS shows when a preset has no usable artwork (always for
 * custom endpoints; Tinfoil below its minimum logo size).
 */
val ProviderKind.fallbackIcon: ImageVector
  get() =
    when (this) {
      ProviderKind.OPENAI -> Icons.Rounded.AutoAwesome
      ProviderKind.ANTHROPIC -> Icons.Rounded.FontDownload
      ProviderKind.GOOGLE -> Icons.Rounded.Diamond
      ProviderKind.XAI -> Icons.Rounded.Close
      ProviderKind.META -> Icons.Rounded.AllInclusive
      ProviderKind.MISTRAL -> Icons.Rounded.Air
      ProviderKind.COHERE -> Icons.Rounded.KeyboardCommandKey
      ProviderKind.DEEPSEEK -> Icons.Rounded.GpsFixed
      ProviderKind.QWEN -> Icons.Rounded.Adjust
      ProviderKind.KIMI -> Icons.Rounded.NightsStay
      ProviderKind.ZAI -> Icons.Rounded.Toll
      ProviderKind.MINIMAX -> Icons.Rounded.MonitorHeart
      ProviderKind.AI21 -> Icons.Rounded.Psychology
      ProviderKind.GROQ -> Icons.Rounded.Speed
      ProviderKind.TOGETHER_AI -> Icons.Rounded.Hub
      ProviderKind.FIREWORKS_AI -> Icons.Rounded.Celebration
      ProviderKind.CEREBRAS -> Icons.Rounded.Memory
      ProviderKind.SAMBANOVA -> Icons.Rounded.GraphicEq
      ProviderKind.NVIDIA_NIM -> Icons.Rounded.Layers
      ProviderKind.NEBIUS -> Icons.Rounded.Hexagon
      ProviderKind.HYPERBOLIC -> Icons.Rounded.Hive
      ProviderKind.BASETEN -> Icons.Rounded.ViewInAr
      ProviderKind.SCALEWAY -> Icons.Rounded.Thunderstorm
      ProviderKind.DIGITALOCEAN -> Icons.Rounded.WaterDrop
      ProviderKind.FEATHERLESS_AI -> Icons.Rounded.HistoryEdu
      ProviderKind.CHUTES -> Icons.Rounded.ArrowCircleDown
      ProviderKind.SILICONFLOW -> Icons.Rounded.AccountTree
      ProviderKind.PERPLEXITY -> Icons.Rounded.TravelExplore
      ProviderKind.HUGGINGFACE -> Icons.Rounded.SentimentSatisfied
      ProviderKind.OPENROUTER -> Icons.AutoMirrored.Rounded.AltRoute
      ProviderKind.AIML_API -> Icons.Rounded.Share
      ProviderKind.MICROSOFT_FOUNDRY -> Icons.Rounded.GridView
      ProviderKind.AMAZON_BEDROCK -> Icons.Rounded.Inventory2
      ProviderKind.DEEPINFRA -> Icons.Rounded.ElectricBolt
      ProviderKind.TINFOIL -> Icons.Rounded.Cloud
      ProviderKind.VERCEL_AI -> Icons.Rounded.ChangeHistory
      ProviderKind.NOVITA_AI -> Icons.Rounded.AutoAwesomeMotion
      ProviderKind.TENCENT_TOKENHUB -> Icons.Rounded.Cloud
      ProviderKind.BAIDU_QIANFAN -> Icons.Rounded.Psychology
      ProviderKind.POE -> Icons.Rounded.Forum
      ProviderKind.VOYAGE_AI -> Icons.Rounded.Sailing
      ProviderKind.JINA_AI -> Icons.Rounded.Apps
      ProviderKind.OLLAMA -> Icons.Rounded.Computer
      ProviderKind.LM_STUDIO -> Icons.Rounded.DesktopMac
      ProviderKind.LOCAL_AI -> Icons.Rounded.Dns
      ProviderKind.VLLM -> Icons.Rounded.Speed
      ProviderKind.SGLANG -> Icons.Rounded.Bolt
      ProviderKind.LLAMA_CPP -> Icons.Rounded.Terminal
      ProviderKind.JAN -> Icons.Rounded.Laptop
      ProviderKind.CUSTOM -> Icons.Rounded.Language
    }

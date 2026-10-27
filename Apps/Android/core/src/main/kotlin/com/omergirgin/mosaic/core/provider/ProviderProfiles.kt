package com.omergirgin.mosaic.core.provider

import com.omergirgin.mosaic.core.provider.ProviderCapability.CHAT
import com.omergirgin.mosaic.core.provider.ProviderCapability.EMBEDDINGS
import com.omergirgin.mosaic.core.provider.ProviderCapability.LIVE_TRANSCRIPTION
import com.omergirgin.mosaic.core.provider.ProviderCapability.MODEL_DISCOVERY
import java.util.EnumMap

/**
 * Static preset for this provider. Exact port of iOS `ProviderKind.providerProfile`
 * (`Providers/ProviderCatalog.swift`). Profiles are built once and cached, so this is cheap to
 * call from composition and hot request paths.
 */
val ProviderKind.profile: ProviderProfile get() = profileCache.getValue(this)

/** Dedicated live-transcription model for presets that support it (iOS parity). */
val ProviderKind.defaultLiveTranscriptionModel: String?
  get() = if (supportsLiveTranscription) "gemini-3.5-transcribe-live" else null

private val profileCache: Map<ProviderKind, ProviderProfile> by lazy {
  ProviderKind.entries.associateWithTo(EnumMap(ProviderKind::class.java)) { buildProfile(it) }
}

private fun buildProfile(kind: ProviderKind): ProviderProfile =
  when (kind) {
    ProviderKind.OPENAI ->
      ProviderProfile(
        displayName = "OpenAI",
        category = ProviderCategory.MODEL_LABS,
        serviceSummary = "OpenAI-hosted chat and embedding models",
        baseUrl = "https://api.openai.com/v1",
        suggestedModels =
          listOf("gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano"),
        capabilities = setOf(CHAT, EMBEDDINGS),
        defaultEmbeddingModel = "text-embedding-3-small",
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        suggestedContextWindowTokens = 1_050_000,
        suggestedMaximumOutputTokens = 128_000,
        logoName = "provider_logo_openai",
        visualTone = ProviderVisualTone.PRIMARY,
      )
    ProviderKind.ANTHROPIC ->
      ProviderProfile(
        displayName = "Anthropic",
        category = ProviderCategory.MODEL_LABS,
        serviceSummary = "Claude models through Anthropic’s API",
        baseUrl = "https://api.anthropic.com/v1",
        suggestedModels =
          listOf("claude-sonnet-5", "claude-opus-5", "claude-fable-5-1", "claude-haiku-4-5-20251001"),
        capabilities = setOf(CHAT, MODEL_DISCOVERY),
        authenticationStyle = ProviderAuthenticationStyle.ANTHROPIC,
        modelCatalogKind = ProviderModelCatalogKind.ANTHROPIC,
        suggestedContextWindowTokens = 1_000_000,
        suggestedMaximumOutputTokens = 128_000,
        logoName = "provider_logo_anthropic",
        visualTone = ProviderVisualTone.BROWN,
      )
    ProviderKind.GOOGLE ->
      ProviderProfile(
        displayName = "Google Gemini",
        category = ProviderCategory.MODEL_LABS,
        serviceSummary = "Gemini chat, embeddings, and dedicated live transcription",
        baseUrl = "https://generativelanguage.googleapis.com/v1beta",
        suggestedModels = listOf("gemini-3.8-flash", "gemini-3.5-flash-lite"),
        capabilities = setOf(CHAT, EMBEDDINGS, MODEL_DISCOVERY, LIVE_TRANSCRIPTION),
        defaultEmbeddingModel = "gemini-embedding-2",
        authenticationStyle = ProviderAuthenticationStyle.GOOGLE,
        modelCatalogKind = ProviderModelCatalogKind.GEMINI,
        logoName = "provider_logo_google",
        visualTone = ProviderVisualTone.BLUE,
      )
    ProviderKind.XAI ->
      ProviderProfile(
        displayName = "xAI",
        category = ProviderCategory.MODEL_LABS,
        serviceSummary = "Grok models through xAI’s API",
        baseUrl = "https://api.x.ai/v1",
        suggestedModels = listOf("grok-4.6"),
        capabilities = setOf(CHAT, MODEL_DISCOVERY),
        modelCatalogKind = ProviderModelCatalogKind.XAI,
        logoName = "provider_logo_xai",
        visualTone = ProviderVisualTone.PRIMARY,
      )
    ProviderKind.META ->
      ProviderProfile(
        displayName = "Meta Model API",
        category = ProviderCategory.MODEL_LABS,
        serviceSummary = "Muse Spark and Meta-hosted models",
        baseUrl = "https://api.meta.ai/v1",
        suggestedModels = listOf("muse-spark-1.2", "muse-spark-1.1"),
        capabilities = setOf(CHAT),
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_meta",
        visualTone = ProviderVisualTone.BLUE,
      )
    ProviderKind.MISTRAL ->
      ProviderProfile(
        displayName = "Mistral AI",
        category = ProviderCategory.MODEL_LABS,
        serviceSummary = "Mistral-hosted chat and embedding models",
        baseUrl = "https://api.mistral.ai/v1",
        suggestedModels = listOf("mistral-large-latest", "mistral-small-latest"),
        capabilities = setOf(CHAT, EMBEDDINGS, MODEL_DISCOVERY),
        defaultEmbeddingModel = "mistral-embed",
        modelCatalogKind = ProviderModelCatalogKind.MISTRAL,
        includesStreamingUsage = true,
        logoName = "provider_logo_mistral",
        visualTone = ProviderVisualTone.ORANGE,
      )
    ProviderKind.COHERE ->
      ProviderProfile(
        displayName = "Cohere",
        category = ProviderCategory.MODEL_LABS,
        serviceSummary = "Command chat and Cohere embedding models",
        baseUrl = "https://api.cohere.ai/compatibility/v1",
        suggestedModels = listOf("command-a-plus-05-2026"),
        capabilities = setOf(CHAT, EMBEDDINGS, MODEL_DISCOVERY),
        defaultEmbeddingModel = "embed-v4.0",
        modelCatalogKind = ProviderModelCatalogKind.COHERE,
        logoName = "provider_logo_cohere",
        visualTone = ProviderVisualTone.GREEN,
      )
    ProviderKind.DEEPSEEK ->
      ProviderProfile(
        displayName = "DeepSeek",
        category = ProviderCategory.MODEL_LABS,
        serviceSummary = "DeepSeek chat and reasoning models",
        baseUrl = "https://api.deepseek.com/v1",
        suggestedModels = listOf("deepseek-v4-pro", "deepseek-v4-flash"),
        capabilities = setOf(CHAT, MODEL_DISCOVERY),
        logoName = "provider_logo_deepseek",
        visualTone = ProviderVisualTone.BLUE,
      )
    ProviderKind.QWEN ->
      ProviderProfile(
        displayName = "Alibaba Qwen",
        category = ProviderCategory.MODEL_LABS,
        serviceSummary = "Qwen models through Alibaba Model Studio",
        baseUrl = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        suggestedModels = listOf("qwen3.8-max", "qwen3.8-flash"),
        capabilities = setOf(CHAT, EMBEDDINGS),
        defaultEmbeddingModel = "qwen3.7-text-embedding",
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_qwen",
        visualTone = ProviderVisualTone.PURPLE,
      )
    ProviderKind.KIMI ->
      ProviderProfile(
        displayName = "Moonshot Kimi",
        category = ProviderCategory.MODEL_LABS,
        serviceSummary = "Kimi models through Moonshot AI",
        baseUrl = "https://api.moonshot.ai/v1",
        suggestedModels = listOf("kimi-k3", "kimi-k2.7-code", "kimi-k2.6"),
        capabilities = setOf(CHAT, MODEL_DISCOVERY),
        logoName = "provider_logo_kimi",
        visualTone = ProviderVisualTone.INDIGO,
      )
    ProviderKind.ZAI ->
      ProviderProfile(
        displayName = "Z.AI",
        category = ProviderCategory.MODEL_LABS,
        serviceSummary = "GLM chat and reasoning models",
        baseUrl = "https://api.z.ai/api/paas/v4",
        suggestedModels = listOf("glm-5.3-flash", "glm-5.3"),
        capabilities = setOf(CHAT),
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_zai",
        visualTone = ProviderVisualTone.BLUE,
      )
    ProviderKind.MINIMAX ->
      ProviderProfile(
        displayName = "MiniMax",
        category = ProviderCategory.MODEL_LABS,
        serviceSummary = "MiniMax chat and reasoning models",
        baseUrl = "https://api.minimax.io/v1",
        suggestedModels = listOf("MiniMax-M3", "MiniMax-M2.7"),
        capabilities = setOf(CHAT, MODEL_DISCOVERY),
        logoName = "provider_logo_minimax",
        visualTone = ProviderVisualTone.RED,
      )
    ProviderKind.AI21 ->
      ProviderProfile(
        displayName = "AI21 Labs",
        category = ProviderCategory.MODEL_LABS,
        serviceSummary = "Jamba models through AI21 Studio",
        baseUrl = "https://api.ai21.com/studio/v1",
        suggestedModels = listOf("jamba-mini-2-2026-01", "jamba-large-1.7-2025-07"),
        capabilities = setOf(CHAT),
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_ai21",
        visualTone = ProviderVisualTone.PURPLE,
      )
    ProviderKind.GROQ ->
      ProviderProfile(
        displayName = "Groq",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "Fast hosted inference across open models",
        baseUrl = "https://api.groq.com/openai/v1",
        suggestedModels = listOf("openai/gpt-oss-120b", "openai/gpt-oss-20b"),
        capabilities = setOf(CHAT),
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_groq",
        visualTone = ProviderVisualTone.ORANGE,
      )
    ProviderKind.TOGETHER_AI ->
      ProviderProfile(
        displayName = "Together AI",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "Serverless chat and embedding model inference",
        baseUrl = "https://api.together.xyz/v1",
        suggestedModels = listOf("openai/gpt-oss-120b", "openai/gpt-oss-20b"),
        capabilities = setOf(CHAT, EMBEDDINGS, MODEL_DISCOVERY),
        defaultEmbeddingModel = "intfloat/multilingual-e5-large-instruct",
        modelCatalogKind = ProviderModelCatalogKind.TOP_LEVEL_ARRAY,
        logoName = "provider_logo_together_ai",
        visualTone = ProviderVisualTone.PURPLE,
      )
    ProviderKind.FIREWORKS_AI ->
      ProviderProfile(
        displayName = "Fireworks AI",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "Serverless chat and embedding model inference",
        baseUrl = "https://api.fireworks.ai/inference/v1",
        suggestedModels = listOf("accounts/fireworks/models/gpt-oss-120b"),
        capabilities = setOf(CHAT, EMBEDDINGS, MODEL_DISCOVERY),
        defaultEmbeddingModel = "fireworks/qwen3-embedding-8b",
        modelCatalogKind = ProviderModelCatalogKind.FIREWORKS,
        logoName = "provider_logo_fireworks_ai",
        visualTone = ProviderVisualTone.RED,
      )
    ProviderKind.CEREBRAS ->
      ProviderProfile(
        displayName = "Cerebras",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "High-speed hosted model inference",
        baseUrl = "https://api.cerebras.ai/v1",
        suggestedModels = listOf("gpt-oss-120b"),
        capabilities = setOf(CHAT, MODEL_DISCOVERY),
        logoName = "provider_logo_cerebras",
        visualTone = ProviderVisualTone.ORANGE,
      )
    ProviderKind.SAMBANOVA ->
      ProviderProfile(
        displayName = "SambaNova Cloud",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "SambaNova-hosted open model inference",
        baseUrl = "https://api.sambanova.ai/v1",
        suggestedModels = listOf("gpt-oss-120b"),
        capabilities = setOf(CHAT),
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_sambanova",
        visualTone = ProviderVisualTone.PINK,
      )
    ProviderKind.NVIDIA_NIM ->
      ProviderProfile(
        displayName = "NVIDIA NIM",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "NVIDIA-hosted NIM chat and retrieval models",
        baseUrl = "https://integrate.api.nvidia.com/v1",
        suggestedModels = listOf("openai/gpt-oss-20b", "meta/muse-glimmer-30b"),
        capabilities = setOf(CHAT, EMBEDDINGS),
        defaultEmbeddingModel = "nvidia/nemotron-3-embed-1b",
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_nvidia_nim",
        visualTone = ProviderVisualTone.GREEN,
      )
    ProviderKind.NEBIUS ->
      ProviderProfile(
        displayName = "Nebius Token Factory",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "Serverless and dedicated model inference",
        baseUrl = "https://api.tokenfactory.nebius.com/v1",
        suggestedModels = listOf("openai/gpt-oss-120b"),
        capabilities = setOf(CHAT),
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_nebius",
        visualTone = ProviderVisualTone.PURPLE,
      )
    ProviderKind.HYPERBOLIC ->
      ProviderProfile(
        displayName = "Hyperbolic",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "Open model inference through Hyperbolic",
        baseUrl = "https://api.hyperbolic.xyz/v1",
        suggestedModels = listOf("meta-llama/Llama-3.3-70B-Instruct"),
        capabilities = setOf(CHAT),
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_hyperbolic",
        visualTone = ProviderVisualTone.ORANGE,
      )
    ProviderKind.BASETEN ->
      ProviderProfile(
        displayName = "Baseten",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "Enabled shared model APIs from Baseten",
        baseUrl = "https://inference.baseten.co/v1",
        suggestedModels = listOf("zai-org/GLM-5.3", "deepseek-ai/DeepSeek-V4-Pro-0813"),
        capabilities = setOf(CHAT),
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_baseten",
        visualTone = ProviderVisualTone.INDIGO,
      )
    ProviderKind.SCALEWAY ->
      ProviderProfile(
        displayName = "Scaleway Generative APIs",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "Scaleway-hosted chat and embedding model inference",
        baseUrl = "https://api.scaleway.ai/v1",
        suggestedModels = listOf("deepseek-v4-flash-0731", "glm-5.2"),
        capabilities = setOf(CHAT, EMBEDDINGS),
        defaultEmbeddingModel = "qwen3-embedding-8b",
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_scaleway",
        visualTone = ProviderVisualTone.PURPLE,
      )
    ProviderKind.DIGITALOCEAN ->
      ProviderProfile(
        displayName = "DigitalOcean Gradient AI",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "Gradient AI chat and embedding inference",
        baseUrl = "https://inference.do-ai.run/v1",
        suggestedModels = listOf("glm-5.3"),
        capabilities = setOf(CHAT, EMBEDDINGS),
        defaultEmbeddingModel = "qwen3-embedding-0.6b",
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_digitalocean",
        visualTone = ProviderVisualTone.BLUE,
      )
    ProviderKind.FEATHERLESS_AI ->
      ProviderProfile(
        displayName = "Featherless.ai",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "Serverless chat inference across open models",
        baseUrl = "https://api.featherless.ai/v1",
        suggestedModels = emptyList(),
        capabilities = setOf(CHAT, MODEL_DISCOVERY),
        modelCatalogKind = ProviderModelCatalogKind.FEATHERLESS,
        logoName = "provider_logo_featherless_ai",
        visualTone = ProviderVisualTone.ORANGE,
      )
    ProviderKind.CHUTES ->
      ProviderProfile(
        displayName = "Chutes",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "OpenAI-compatible chat inference through Chutes",
        baseUrl = "https://llm.chutes.ai/v1",
        suggestedModels = listOf("Qwen/Qwen3.5-397B-A17B-TEE", "zai-org/GLM-5.2-TEE"),
        capabilities = setOf(CHAT, MODEL_DISCOVERY),
        modelCatalogKind = ProviderModelCatalogKind.TOP_LEVEL_TEXT_OUTPUT,
        logoName = "provider_logo_chutes",
        visualTone = ProviderVisualTone.TEAL,
      )
    ProviderKind.SILICONFLOW ->
      ProviderProfile(
        displayName = "SiliconFlow",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "Global hosted chat and embedding models",
        baseUrl = "https://api.siliconflow.com/v1",
        suggestedModels = listOf("Qwen/Qwen3-32B"),
        capabilities = setOf(CHAT, EMBEDDINGS, MODEL_DISCOVERY),
        defaultEmbeddingModel = "Qwen/Qwen3-Embedding-8B",
        modelCatalogKind = ProviderModelCatalogKind.SILICON_FLOW,
        logoName = "provider_logo_siliconflow",
        visualTone = ProviderVisualTone.BLUE,
      )
    ProviderKind.PERPLEXITY ->
      ProviderProfile(
        displayName = "Perplexity Sonar",
        category = ProviderCategory.MODEL_GATEWAYS,
        serviceSummary = "Web-grounded Sonar answer models",
        baseUrl = "https://api.perplexity.ai",
        suggestedModels = listOf("sonar", "sonar-pro", "sonar-deep-research", "sonar-reasoning-pro"),
        capabilities = setOf(CHAT),
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_perplexity",
        visualTone = ProviderVisualTone.TEAL,
      )
    ProviderKind.HUGGINGFACE ->
      ProviderProfile(
        displayName = "Hugging Face",
        category = ProviderCategory.MODEL_GATEWAYS,
        serviceSummary = "Inference Providers routing across hosted models",
        baseUrl = "https://router.huggingface.co/v1",
        suggestedModels = listOf("openai/gpt-oss-120b:fastest", "openai/gpt-oss-120b:cerebras"),
        capabilities = setOf(CHAT, MODEL_DISCOVERY),
        modelCatalogKind = ProviderModelCatalogKind.ARCHITECTURE_TEXT_OUTPUT,
        logoName = "provider_logo_huggingface",
        visualTone = ProviderVisualTone.YELLOW,
      )
    ProviderKind.OPENROUTER ->
      ProviderProfile(
        displayName = "OpenRouter",
        category = ProviderCategory.MODEL_GATEWAYS,
        serviceSummary = "One API for chat and embedding models from multiple providers",
        baseUrl = "https://openrouter.ai/api/v1",
        suggestedModels = listOf("openai/gpt-5.6", "anthropic/claude-sonnet-5", "google/gemini-3.8-flash"),
        capabilities = setOf(CHAT, EMBEDDINGS, MODEL_DISCOVERY),
        defaultEmbeddingModel = "openai/text-embedding-3-small",
        modelCatalogKind = ProviderModelCatalogKind.OPEN_ROUTER,
        includesStreamingUsage = true,
        logoName = "provider_logo_openrouter",
        visualTone = ProviderVisualTone.PURPLE,
      )
    ProviderKind.AIML_API ->
      ProviderProfile(
        displayName = "AI/ML API",
        category = ProviderCategory.MODEL_GATEWAYS,
        serviceSummary = "Unified chat and embedding models through AI/ML API",
        baseUrl = "https://api.aimlapi.com/v1",
        suggestedModels = emptyList(),
        capabilities = setOf(CHAT, EMBEDDINGS, MODEL_DISCOVERY),
        defaultEmbeddingModel = "text-embedding-3-small",
        modelCatalogKind = ProviderModelCatalogKind.AIML_API,
        logoName = "provider_logo_aiml_api",
        visualTone = ProviderVisualTone.INDIGO,
      )
    ProviderKind.MICROSOFT_FOUNDRY ->
      ProviderProfile(
        displayName = "Microsoft Foundry",
        category = ProviderCategory.MODEL_GATEWAYS,
        serviceSummary = "Azure OpenAI v1 deployments with a resource-specific endpoint",
        baseUrl = null,
        suggestedModels = emptyList(),
        capabilities = setOf(CHAT, EMBEDDINGS),
        authenticationStyle = ProviderAuthenticationStyle.API_KEY_HEADER,
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_microsoft_foundry",
        visualTone = ProviderVisualTone.BLUE,
      )
    ProviderKind.AMAZON_BEDROCK ->
      ProviderProfile(
        displayName = "Amazon Bedrock",
        category = ProviderCategory.MODEL_GATEWAYS,
        serviceSummary = "Bedrock chat models through a regional OpenAI-compatible endpoint",
        baseUrl = null,
        suggestedModels = listOf("openai.gpt-oss-120b"),
        capabilities = setOf(CHAT),
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_amazon_bedrock",
        visualTone = ProviderVisualTone.ORANGE,
      )
    ProviderKind.DEEPINFRA ->
      ProviderProfile(
        displayName = "DeepInfra",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "Hosted open models for chat and embeddings",
        baseUrl = "https://api.deepinfra.com/v1/openai",
        suggestedModels = listOf("deepseek-ai/DeepSeek-V4-Flash-0731"),
        capabilities = setOf(CHAT, EMBEDDINGS, MODEL_DISCOVERY),
        defaultEmbeddingModel = "Qwen/Qwen3-Embedding-8B",
        modelCatalogKind = ProviderModelCatalogKind.DEEP_INFRA,
        includesStreamingUsage = true,
        logoName = "provider_logo_deepinfra",
        visualTone = ProviderVisualTone.BLUE,
      )
    ProviderKind.TINFOIL ->
      ProviderProfile(
        displayName = "Tinfoil",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "Privacy-focused hosted model inference",
        baseUrl = "https://inference.tinfoil.sh/v1",
        suggestedModels = listOf("gpt-oss-120b"),
        capabilities = setOf(CHAT, EMBEDDINGS, MODEL_DISCOVERY),
        defaultEmbeddingModel = "nomic-embed-text",
        modelCatalogKind = ProviderModelCatalogKind.TINFOIL,
        includesStreamingUsage = true,
        logoName = "provider_logo_tinfoil",
        visualTone = ProviderVisualTone.TEAL,
      )
    ProviderKind.VERCEL_AI ->
      ProviderProfile(
        displayName = "Vercel AI Gateway",
        category = ProviderCategory.MODEL_GATEWAYS,
        serviceSummary = "Unified chat and embedding models through Vercel AI Gateway",
        baseUrl = "https://ai-gateway.vercel.sh/v1",
        suggestedModels = listOf("openai/gpt-5.6-sol", "anthropic/claude-opus-5"),
        capabilities = setOf(CHAT, EMBEDDINGS, MODEL_DISCOVERY),
        defaultEmbeddingModel = "openai/text-embedding-3-small",
        modelCatalogKind = ProviderModelCatalogKind.VERCEL,
        includesStreamingUsage = true,
        logoName = "provider_logo_vercel_ai",
        visualTone = ProviderVisualTone.PRIMARY,
      )
    ProviderKind.NOVITA_AI ->
      ProviderProfile(
        displayName = "Novita AI",
        category = ProviderCategory.INFERENCE_CLOUDS,
        serviceSummary = "OpenAI-compatible hosted LLM and embedding inference",
        baseUrl = "https://api.novita.ai/openai/v1",
        suggestedModels = listOf("zai-org/glm-5.3-flash", "deepseek/deepseek-v4-pro"),
        capabilities = setOf(CHAT, EMBEDDINGS),
        defaultEmbeddingModel = "baai/bge-m3",
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        includesStreamingUsage = true,
        logoName = "provider_logo_novita_ai",
        visualTone = ProviderVisualTone.PURPLE,
      )
    ProviderKind.TENCENT_TOKENHUB ->
      ProviderProfile(
        displayName = "Tencent TokenHub",
        category = ProviderCategory.MODEL_GATEWAYS,
        serviceSummary = "Tencent and third-party chat and embedding models",
        baseUrl = "https://tokenhub-intl.tencentmaas.com/v1",
        suggestedModels = listOf("deepseek-v4-flash", "hy3"),
        capabilities = setOf(CHAT, EMBEDDINGS, MODEL_DISCOVERY),
        defaultEmbeddingModel = "kinfra-text-embedding-0.6b",
        modelCatalogKind = ProviderModelCatalogKind.TENCENT_TOKEN_HUB,
        logoName = "provider_logo_tencent_tokenhub",
        visualTone = ProviderVisualTone.BLUE,
      )
    ProviderKind.BAIDU_QIANFAN ->
      ProviderProfile(
        displayName = "Baidu Qianfan",
        category = ProviderCategory.MODEL_GATEWAYS,
        serviceSummary = "ERNIE and third-party models through Baidu Qianfan",
        baseUrl = "https://qianfan.baidubce.com/v2",
        suggestedModels = listOf("ernie-5.0", "deepseek-v4-pro"),
        capabilities = setOf(CHAT, EMBEDDINGS, MODEL_DISCOVERY),
        defaultEmbeddingModel = "embedding-v1",
        modelCatalogKind = ProviderModelCatalogKind.BAIDU_QIANFAN,
        logoName = "provider_logo_baidu_qianfan",
        visualTone = ProviderVisualTone.BLUE,
      )
    ProviderKind.POE ->
      ProviderProfile(
        displayName = "Poe",
        category = ProviderCategory.MODEL_GATEWAYS,
        serviceSummary = "Text models and public bots available through Poe",
        baseUrl = "https://api.poe.com/v1",
        suggestedModels = listOf("Claude-Sonnet-4.6", "GPT-5.4"),
        capabilities = setOf(CHAT, MODEL_DISCOVERY),
        modelCatalogKind = ProviderModelCatalogKind.POE,
        logoName = "provider_logo_poe",
        visualTone = ProviderVisualTone.PURPLE,
      )
    ProviderKind.VOYAGE_AI ->
      ProviderProfile(
        displayName = "Voyage AI",
        category = ProviderCategory.RETRIEVAL,
        serviceSummary = "Dedicated semantic embedding models",
        baseUrl = "https://api.voyageai.com/v1",
        suggestedModels = listOf("voyage-4", "voyage-4-large"),
        capabilities = setOf(EMBEDDINGS),
        defaultEmbeddingModel = "voyage-4",
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_voyage_ai",
        visualTone = ProviderVisualTone.BLUE,
      )
    ProviderKind.JINA_AI ->
      ProviderProfile(
        displayName = "Jina AI",
        category = ProviderCategory.RETRIEVAL,
        serviceSummary = "Text embedding models for semantic retrieval",
        baseUrl = "https://api.jina.ai/v1",
        suggestedModels = listOf("jina-embeddings-v5-text-small", "jina-embeddings-v5-omni-small"),
        capabilities = setOf(EMBEDDINGS),
        defaultEmbeddingModel = "jina-embeddings-v5-text-small",
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        logoName = "provider_logo_jina_ai",
        visualTone = ProviderVisualTone.PURPLE,
      )
    ProviderKind.OLLAMA ->
      localProfile(
        displayName = "Ollama",
        serviceSummary = "Models served by Ollama on this device or your network",
        baseUrl = "http://127.0.0.1:11434/v1",
        suggestedModels = listOf("llama3.2"),
        defaultEmbeddingModel = "embeddinggemma",
        logoName = "provider_logo_ollama",
      )
    ProviderKind.LM_STUDIO ->
      localProfile(
        displayName = "LM Studio",
        serviceSummary = "Models served by LM Studio",
        baseUrl = "http://127.0.0.1:1234/v1",
        modelCatalogKind = ProviderModelCatalogKind.LM_STUDIO,
        logoName = "provider_logo_lm_studio",
      )
    ProviderKind.LOCAL_AI ->
      localProfile(
        displayName = "LocalAI",
        serviceSummary = "OpenAI-compatible LocalAI models",
        baseUrl = "http://127.0.0.1:8080/v1",
        logoName = "provider_logo_local_ai",
      )
    ProviderKind.VLLM ->
      localProfile(
        displayName = "vLLM",
        serviceSummary = "Models served by a local or network vLLM server",
        baseUrl = "http://127.0.0.1:8000/v1",
        logoName = "provider_logo_vllm",
      )
    ProviderKind.SGLANG ->
      localProfile(
        displayName = "SGLang",
        serviceSummary = "Models served by an SGLang runtime",
        baseUrl = "http://127.0.0.1:30000/v1",
        logoName = "provider_logo_sglang",
      )
    ProviderKind.LLAMA_CPP ->
      localProfile(
        displayName = "llama.cpp",
        serviceSummary = "Models served by llama.cpp's local server",
        baseUrl = "http://127.0.0.1:8080/v1",
        logoName = "provider_logo_llama_cpp",
      )
    ProviderKind.JAN ->
      localProfile(
        displayName = "Jan",
        serviceSummary = "Models served by Jan's local API",
        baseUrl = "http://127.0.0.1:1337/v1",
        logoName = "provider_logo_jan",
      )
    ProviderKind.CUSTOM ->
      ProviderProfile(
        displayName = "Custom OpenAI-compatible",
        category = ProviderCategory.CUSTOM,
        serviceSummary = "Any OpenAI-compatible chat or embedding endpoint",
        baseUrl = null,
        suggestedModels = emptyList(),
        capabilities = setOf(CHAT, EMBEDDINGS),
        requiresApiKey = false,
        modelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
        suggestedContextWindowTokens = 8_192,
        suggestedMaximumOutputTokens = 2_048,
        // No bundled artwork exists for custom endpoints; the UI falls back to a network icon.
        logoName = "provider_logo_custom",
        visualTone = ProviderVisualTone.ACCENT,
      )
  }

/**
 * Shared shape of every local runtime: keyless, conservative 8K/2K limits, and model discovery
 * only when the runtime exposes a catalog format Turing understands.
 */
private fun localProfile(
  displayName: String,
  serviceSummary: String,
  baseUrl: String,
  suggestedModels: List<String> = emptyList(),
  defaultEmbeddingModel: String? = null,
  modelCatalogKind: ProviderModelCatalogKind = ProviderModelCatalogKind.UNAVAILABLE,
  logoName: String,
): ProviderProfile =
  ProviderProfile(
    displayName = displayName,
    category = ProviderCategory.LOCAL,
    serviceSummary = serviceSummary,
    baseUrl = baseUrl,
    suggestedModels = suggestedModels,
    capabilities =
      if (modelCatalogKind == ProviderModelCatalogKind.UNAVAILABLE) setOf(CHAT, EMBEDDINGS)
      else setOf(CHAT, EMBEDDINGS, MODEL_DISCOVERY),
    defaultEmbeddingModel = defaultEmbeddingModel,
    requiresApiKey = false,
    modelCatalogKind = modelCatalogKind,
    suggestedContextWindowTokens = 8_192,
    suggestedMaximumOutputTokens = 2_048,
    logoName = logoName,
    visualTone = ProviderVisualTone.PRIMARY,
  )

package com.omergirgin.mosaic.core.provider

/**
 * The 50 curated provider presets. Raw IDs match the iOS `ProviderKind` raw values exactly so
 * portable `.mosaicbackup` archives and model catalogs stay interchangeable between platforms.
 */
enum class ProviderKind(val rawId: String) {
  OPENAI("openai"),
  ANTHROPIC("anthropic"),
  GOOGLE("google"),
  XAI("xai"),
  META("meta"),
  MISTRAL("mistral"),
  COHERE("cohere"),
  DEEPSEEK("deepseek"),
  QWEN("qwen"),
  KIMI("kimi"),
  ZAI("zai"),
  MINIMAX("minimax"),
  AI21("ai21"),
  GROQ("groq"),
  TOGETHER_AI("together_ai"),
  FIREWORKS_AI("fireworks_ai"),
  CEREBRAS("cerebras"),
  SAMBANOVA("sambanova"),
  NVIDIA_NIM("nvidia_nim"),
  NEBIUS("nebius"),
  HYPERBOLIC("hyperbolic"),
  BASETEN("baseten"),
  SCALEWAY("scaleway"),
  DIGITALOCEAN("digitalocean"),
  FEATHERLESS_AI("featherless_ai"),
  CHUTES("chutes"),
  SILICONFLOW("siliconflow"),
  PERPLEXITY("perplexity"),
  HUGGINGFACE("huggingface"),
  OPENROUTER("openrouter"),
  AIML_API("aiml_api"),
  MICROSOFT_FOUNDRY("microsoft_foundry"),
  AMAZON_BEDROCK("amazon_bedrock"),
  DEEPINFRA("deepinfra"),
  TINFOIL("tinfoil"),
  VERCEL_AI("vercel_ai"),
  NOVITA_AI("novita_ai"),
  TENCENT_TOKENHUB("tencent_tokenhub"),
  BAIDU_QIANFAN("baidu_qianfan"),
  POE("poe"),
  VOYAGE_AI("voyage_ai"),
  JINA_AI("jina_ai"),
  OLLAMA("ollama"),
  LM_STUDIO("lm_studio"),
  LOCAL_AI("local_ai"),
  VLLM("vllm"),
  SGLANG("sglang"),
  LLAMA_CPP("llama_cpp"),
  JAN("jan"),
  CUSTOM("custom");

  companion object {
    fun fromRawId(rawId: String): ProviderKind? = entries.firstOrNull { it.rawId == rawId }

    fun inCategory(category: ProviderCategory): List<ProviderKind> =
      entries.filter { it.profile.category == category }
  }
}

enum class ProviderCategory(val displayName: String) {
  MODEL_LABS("Model Labs"),
  INFERENCE_CLOUDS("Inference Clouds"),
  MODEL_GATEWAYS("Model Gateways"),
  RETRIEVAL("Embeddings & Retrieval"),
  LOCAL("Local Runtimes"),
  CUSTOM("Custom"),
}

enum class ProviderCapability { CHAT, EMBEDDINGS, MODEL_DISCOVERY, LIVE_TRANSCRIPTION }

enum class ProviderAuthenticationStyle { BEARER, API_KEY_HEADER, ANTHROPIC, GOOGLE }

enum class ProviderModelCatalogKind {
  STANDARD,
  ARCHITECTURE_TEXT_OUTPUT,
  TOP_LEVEL_TEXT_OUTPUT,
  OPEN_ROUTER,
  TOP_LEVEL_ARRAY,
  ANTHROPIC,
  GEMINI,
  XAI,
  MISTRAL,
  DEEP_INFRA,
  TINFOIL,
  FIREWORKS,
  COHERE,
  FEATHERLESS,
  AIML_API,
  SILICON_FLOW,
  VERCEL,
  TENCENT_TOKEN_HUB,
  BAIDU_QIANFAN,
  POE,
  LM_STUDIO,
  UNAVAILABLE,
}

enum class ProviderVisualTone { PRIMARY, ACCENT, RED, ORANGE, YELLOW, GREEN, TEAL, BLUE, INDIGO, PURPLE, PINK, BROWN }

/** Static description of one preset. Mirrors iOS `ProviderProfile`. */
data class ProviderProfile(
  val displayName: String,
  val category: ProviderCategory,
  val serviceSummary: String,
  /** Default base URL; null when the user must supply a resource-specific endpoint. */
  val baseUrl: String?,
  val suggestedModels: List<String>,
  val capabilities: Set<ProviderCapability>,
  val defaultEmbeddingModel: String? = null,
  val requiresApiKey: Boolean = true,
  val authenticationStyle: ProviderAuthenticationStyle = ProviderAuthenticationStyle.BEARER,
  val modelCatalogKind: ProviderModelCatalogKind = ProviderModelCatalogKind.STANDARD,
  val includesStreamingUsage: Boolean = false,
  val suggestedContextWindowTokens: Int = 32_768,
  val suggestedMaximumOutputTokens: Int = 4_096,
  /** Logo resource base name, e.g. "provider_logo_openai" (Android drawable naming). */
  val logoName: String,
  val visualTone: ProviderVisualTone,
)

val ProviderKind.displayName: String get() = profile.displayName
val ProviderKind.category: ProviderCategory get() = profile.category
val ProviderKind.supportsChat: Boolean get() = ProviderCapability.CHAT in profile.capabilities
val ProviderKind.supportsEmbeddings: Boolean get() = ProviderCapability.EMBEDDINGS in profile.capabilities
val ProviderKind.supportsModelDiscovery: Boolean
  get() = ProviderCapability.MODEL_DISCOVERY in profile.capabilities
val ProviderKind.supportsLiveTranscription: Boolean
  get() = ProviderCapability.LIVE_TRANSCRIPTION in profile.capabilities
val ProviderKind.isLocalRuntime: Boolean get() = profile.category == ProviderCategory.LOCAL

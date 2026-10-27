import Foundation

/// The small set of wire-level variations behind Mosaic's curated provider presets.
/// Provider identity stays separate from transport so adding another OpenAI-compatible host does
/// not duplicate request or streaming code.
enum ProviderAuthenticationStyle: Sendable {
  case bearer
  case apiKeyHeader
  case anthropic
  case google
}

enum ProviderModelCatalogKind: Equatable, Sendable {
  case standard
  case architectureTextOutput
  case topLevelTextOutput
  case openRouter
  case topLevelArray
  case anthropic
  case gemini
  case xAI
  case mistral
  case deepInfra
  case tinfoil
  case fireworks
  case cohere
  case featherless
  case aimlAPI
  case siliconFlow
  case vercel
  case tencentTokenHub
  case baiduQianfan
  case poe
  case lmStudio
  case unavailable
}

enum ProviderVisualTone: Sendable {
  case primary
  case accent
  case red
  case orange
  case yellow
  case green
  case teal
  case blue
  case indigo
  case purple
  case pink
  case brown
}

struct ProviderProfile: Sendable {
  let displayName: String
  let category: ProviderCategory
  let serviceSummary: String
  let baseURL: String?
  let suggestedModels: [String]
  let capabilities: ProviderCapabilities
  let defaultEmbeddingModel: String?
  let requiresAPIKey: Bool
  let authenticationStyle: ProviderAuthenticationStyle
  let modelCatalogKind: ProviderModelCatalogKind
  let includesStreamingUsage: Bool
  let suggestedContextWindowTokens: Int
  let suggestedMaximumOutputTokens: Int
  let logoAssetName: String
  let symbolName: String
  let visualTone: ProviderVisualTone

  init(
    displayName: String,
    category: ProviderCategory,
    serviceSummary: String,
    baseURL: String?,
    suggestedModels: [String],
    capabilities: ProviderCapabilities,
    defaultEmbeddingModel: String? = nil,
    requiresAPIKey: Bool = true,
    authenticationStyle: ProviderAuthenticationStyle = .bearer,
    modelCatalogKind: ProviderModelCatalogKind = .standard,
    includesStreamingUsage: Bool = false,
    suggestedContextWindowTokens: Int = 32_768,
    suggestedMaximumOutputTokens: Int = 4_096,
    logoAssetName: String,
    symbolName: String,
    visualTone: ProviderVisualTone
  ) {
    self.displayName = displayName
    self.category = category
    self.serviceSummary = serviceSummary
    self.baseURL = baseURL
    self.suggestedModels = suggestedModels
    self.capabilities = capabilities
    self.defaultEmbeddingModel = defaultEmbeddingModel
    self.requiresAPIKey = requiresAPIKey
    self.authenticationStyle = authenticationStyle
    self.modelCatalogKind = modelCatalogKind
    self.includesStreamingUsage = includesStreamingUsage
    self.suggestedContextWindowTokens = suggestedContextWindowTokens
    self.suggestedMaximumOutputTokens = suggestedMaximumOutputTokens
    self.logoAssetName = logoAssetName
    self.symbolName = symbolName
    self.visualTone = visualTone
  }
}

extension ProviderKind {
  var providerProfile: ProviderProfile {
    switch self {
    case .openAI:
      ProviderProfile(
        displayName: "OpenAI",
        category: .modelLabs,
        serviceSummary: "OpenAI-hosted chat and embedding models",
        baseURL: "https://api.openai.com/v1",
        suggestedModels: [
          "gpt-5.6-sol",
          "gpt-5.6-terra",
          "gpt-5.6-luna",
          "gpt-5.4",
          "gpt-5.4-mini",
          "gpt-5.4-nano",
        ],
        capabilities: [.chat, .embeddings],
        defaultEmbeddingModel: "text-embedding-3-small",
        modelCatalogKind: .unavailable,
        suggestedContextWindowTokens: 1_050_000,
        suggestedMaximumOutputTokens: 128_000,
        logoAssetName: "ProviderLogoOpenAI",
        symbolName: "sparkles",
        visualTone: .primary
      )
    case .anthropic:
      ProviderProfile(
        displayName: "Anthropic",
        category: .modelLabs,
        serviceSummary: "Claude models through Anthropic’s API",
        baseURL: "https://api.anthropic.com/v1",
        suggestedModels: [
          "claude-sonnet-5",
          "claude-opus-5",
          "claude-fable-5-1",
          "claude-haiku-4-5-20251001",
        ],
        capabilities: [.chat, .modelDiscovery],
        authenticationStyle: .anthropic,
        modelCatalogKind: .anthropic,
        suggestedContextWindowTokens: 1_000_000,
        suggestedMaximumOutputTokens: 128_000,
        logoAssetName: "ProviderLogoAnthropic",
        symbolName: "a.square",
        visualTone: .brown
      )
    case .google:
      ProviderProfile(
        displayName: "Google Gemini",
        category: .modelLabs,
        serviceSummary: "Gemini chat, embeddings, and dedicated live transcription",
        baseURL: "https://generativelanguage.googleapis.com/v1beta",
        suggestedModels: ["gemini-3.8-flash", "gemini-3.5-flash-lite"],
        capabilities: [.chat, .embeddings, .modelDiscovery, .liveTranscription],
        defaultEmbeddingModel: "gemini-embedding-2",
        authenticationStyle: .google,
        modelCatalogKind: .gemini,
        logoAssetName: "ProviderLogoGoogle",
        symbolName: "diamond",
        visualTone: .blue
      )
    case .xAI:
      ProviderProfile(
        displayName: "xAI",
        category: .modelLabs,
        serviceSummary: "Grok models through xAI’s API",
        baseURL: "https://api.x.ai/v1",
        suggestedModels: ["grok-4.6"],
        capabilities: [.chat, .modelDiscovery],
        modelCatalogKind: .xAI,
        logoAssetName: "ProviderLogoXAI",
        symbolName: "xmark",
        visualTone: .primary
      )
    case .meta:
      ProviderProfile(
        displayName: "Meta Model API",
        category: .modelLabs,
        serviceSummary: "Muse Spark and Meta-hosted models",
        baseURL: "https://api.meta.ai/v1",
        suggestedModels: ["muse-spark-1.2", "muse-spark-1.1"],
        capabilities: [.chat],
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoMeta",
        symbolName: "infinity",
        visualTone: .blue
      )
    case .mistral:
      ProviderProfile(
        displayName: "Mistral AI",
        category: .modelLabs,
        serviceSummary: "Mistral-hosted chat and embedding models",
        baseURL: "https://api.mistral.ai/v1",
        suggestedModels: ["mistral-large-latest", "mistral-small-latest"],
        capabilities: [.chat, .embeddings, .modelDiscovery],
        defaultEmbeddingModel: "mistral-embed",
        modelCatalogKind: .mistral,
        includesStreamingUsage: true,
        logoAssetName: "ProviderLogoMistral",
        symbolName: "wind",
        visualTone: .orange
      )
    case .cohere:
      ProviderProfile(
        displayName: "Cohere",
        category: .modelLabs,
        serviceSummary: "Command chat and Cohere embedding models",
        baseURL: "https://api.cohere.ai/compatibility/v1",
        suggestedModels: ["command-a-plus-05-2026"],
        capabilities: [.chat, .embeddings, .modelDiscovery],
        defaultEmbeddingModel: "embed-v4.0",
        modelCatalogKind: .cohere,
        logoAssetName: "ProviderLogoCohere",
        symbolName: "command",
        visualTone: .green
      )
    case .deepSeek:
      ProviderProfile(
        displayName: "DeepSeek",
        category: .modelLabs,
        serviceSummary: "DeepSeek chat and reasoning models",
        baseURL: "https://api.deepseek.com/v1",
        suggestedModels: ["deepseek-v4-pro", "deepseek-v4-flash"],
        capabilities: [.chat, .modelDiscovery],
        logoAssetName: "ProviderLogoDeepSeek",
        symbolName: "scope",
        visualTone: .blue
      )
    case .qwen:
      ProviderProfile(
        displayName: "Alibaba Qwen",
        category: .modelLabs,
        serviceSummary: "Qwen models through Alibaba Model Studio",
        baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        suggestedModels: ["qwen3.8-max", "qwen3.8-flash"],
        capabilities: [.chat, .embeddings],
        defaultEmbeddingModel: "qwen3.7-text-embedding",
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoQwen",
        symbolName: "q.circle",
        visualTone: .purple
      )
    case .kimi:
      ProviderProfile(
        displayName: "Moonshot Kimi",
        category: .modelLabs,
        serviceSummary: "Kimi models through Moonshot AI",
        baseURL: "https://api.moonshot.ai/v1",
        suggestedModels: ["kimi-k3", "kimi-k2.7-code", "kimi-k2.6"],
        capabilities: [.chat, .modelDiscovery],
        logoAssetName: "ProviderLogoKimi",
        symbolName: "moon.stars",
        visualTone: .indigo
      )
    case .zAI:
      ProviderProfile(
        displayName: "Z.AI",
        category: .modelLabs,
        serviceSummary: "GLM chat and reasoning models",
        baseURL: "https://api.z.ai/api/paas/v4",
        suggestedModels: ["glm-5.3-flash", "glm-5.3"],
        capabilities: [.chat],
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoZAI",
        symbolName: "z.circle",
        visualTone: .blue
      )
    case .miniMax:
      ProviderProfile(
        displayName: "MiniMax",
        category: .modelLabs,
        serviceSummary: "MiniMax chat and reasoning models",
        baseURL: "https://api.minimax.io/v1",
        suggestedModels: ["MiniMax-M3", "MiniMax-M2.7"],
        capabilities: [.chat, .modelDiscovery],
        logoAssetName: "ProviderLogoMiniMax",
        symbolName: "waveform.path.ecg",
        visualTone: .red
      )
    case .ai21:
      ProviderProfile(
        displayName: "AI21 Labs",
        category: .modelLabs,
        serviceSummary: "Jamba models through AI21 Studio",
        baseURL: "https://api.ai21.com/studio/v1",
        suggestedModels: ["jamba-mini-2-2026-01", "jamba-large-1.7-2025-07"],
        capabilities: [.chat],
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoAI21",
        symbolName: "brain",
        visualTone: .purple
      )
    case .groq:
      ProviderProfile(
        displayName: "Groq",
        category: .inferenceClouds,
        serviceSummary: "Fast hosted inference across open models",
        baseURL: "https://api.groq.com/openai/v1",
        suggestedModels: ["openai/gpt-oss-120b", "openai/gpt-oss-20b"],
        capabilities: [.chat],
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoGroq",
        symbolName: "g.circle",
        visualTone: .orange
      )
    case .togetherAI:
      ProviderProfile(
        displayName: "Together AI",
        category: .inferenceClouds,
        serviceSummary: "Serverless chat and embedding model inference",
        baseURL: "https://api.together.xyz/v1",
        suggestedModels: ["openai/gpt-oss-120b", "openai/gpt-oss-20b"],
        capabilities: [.chat, .embeddings, .modelDiscovery],
        defaultEmbeddingModel: "intfloat/multilingual-e5-large-instruct",
        modelCatalogKind: .topLevelArray,
        logoAssetName: "ProviderLogoTogetherAI",
        symbolName: "point.3.connected.trianglepath.dotted",
        visualTone: .purple
      )
    case .fireworksAI:
      ProviderProfile(
        displayName: "Fireworks AI",
        category: .inferenceClouds,
        serviceSummary: "Serverless chat and embedding model inference",
        baseURL: "https://api.fireworks.ai/inference/v1",
        suggestedModels: ["accounts/fireworks/models/gpt-oss-120b"],
        capabilities: [.chat, .embeddings, .modelDiscovery],
        defaultEmbeddingModel: "fireworks/qwen3-embedding-8b",
        modelCatalogKind: .fireworks,
        logoAssetName: "ProviderLogoFireworksAI",
        symbolName: "fireworks",
        visualTone: .red
      )
    case .cerebras:
      ProviderProfile(
        displayName: "Cerebras",
        category: .inferenceClouds,
        serviceSummary: "High-speed hosted model inference",
        baseURL: "https://api.cerebras.ai/v1",
        suggestedModels: ["gpt-oss-120b"],
        capabilities: [.chat, .modelDiscovery],
        logoAssetName: "ProviderLogoCerebras",
        symbolName: "cpu",
        visualTone: .orange
      )
    case .sambaNova:
      ProviderProfile(
        displayName: "SambaNova Cloud",
        category: .inferenceClouds,
        serviceSummary: "SambaNova-hosted open model inference",
        baseURL: "https://api.sambanova.ai/v1",
        suggestedModels: ["gpt-oss-120b"],
        capabilities: [.chat],
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoSambaNova",
        symbolName: "waveform",
        visualTone: .pink
      )
    case .nvidiaNIM:
      ProviderProfile(
        displayName: "NVIDIA NIM",
        category: .inferenceClouds,
        serviceSummary: "NVIDIA-hosted NIM chat and retrieval models",
        baseURL: "https://integrate.api.nvidia.com/v1",
        suggestedModels: ["openai/gpt-oss-20b", "meta/muse-glimmer-30b"],
        capabilities: [.chat, .embeddings],
        defaultEmbeddingModel: "nvidia/nemotron-3-embed-1b",
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoNVIDIANIM",
        symbolName: "square.stack.3d.up",
        visualTone: .green
      )
    case .nebius:
      ProviderProfile(
        displayName: "Nebius Token Factory",
        category: .inferenceClouds,
        serviceSummary: "Serverless and dedicated model inference",
        baseURL: "https://api.tokenfactory.nebius.com/v1",
        suggestedModels: ["openai/gpt-oss-120b"],
        capabilities: [.chat],
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoNebius",
        symbolName: "hexagon",
        visualTone: .purple
      )
    case .hyperbolic:
      ProviderProfile(
        displayName: "Hyperbolic",
        category: .inferenceClouds,
        serviceSummary: "Open model inference through Hyperbolic",
        baseURL: "https://api.hyperbolic.xyz/v1",
        suggestedModels: ["meta-llama/Llama-3.3-70B-Instruct"],
        capabilities: [.chat],
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoHyperbolic",
        symbolName: "circle.hexagongrid",
        visualTone: .orange
      )
    case .baseten:
      ProviderProfile(
        displayName: "Baseten",
        category: .inferenceClouds,
        serviceSummary: "Enabled shared model APIs from Baseten",
        baseURL: "https://inference.baseten.co/v1",
        suggestedModels: ["zai-org/GLM-5.3", "deepseek-ai/DeepSeek-V4-Pro-0813"],
        capabilities: [.chat],
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoBaseten",
        symbolName: "square.3.layers.3d",
        visualTone: .indigo
      )
    case .scaleway:
      ProviderProfile(
        displayName: "Scaleway Generative APIs",
        category: .inferenceClouds,
        serviceSummary: "Scaleway-hosted chat and embedding model inference",
        baseURL: "https://api.scaleway.ai/v1",
        suggestedModels: ["deepseek-v4-flash-0731", "glm-5.2"],
        capabilities: [.chat, .embeddings],
        defaultEmbeddingModel: "qwen3-embedding-8b",
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoScaleway",
        symbolName: "cloud.bolt",
        visualTone: .purple
      )
    case .digitalOcean:
      ProviderProfile(
        displayName: "DigitalOcean Gradient AI",
        category: .inferenceClouds,
        serviceSummary: "Gradient AI chat and embedding inference",
        baseURL: "https://inference.do-ai.run/v1",
        suggestedModels: ["glm-5.3"],
        capabilities: [.chat, .embeddings],
        defaultEmbeddingModel: "qwen3-embedding-0.6b",
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoDigitalOcean",
        symbolName: "drop",
        visualTone: .blue
      )
    case .featherlessAI:
      ProviderProfile(
        displayName: "Featherless.ai",
        category: .inferenceClouds,
        serviceSummary: "Serverless chat inference across open models",
        baseURL: "https://api.featherless.ai/v1",
        suggestedModels: [],
        capabilities: [.chat, .modelDiscovery],
        modelCatalogKind: .featherless,
        logoAssetName: "ProviderLogoFeatherlessAI",
        symbolName: "feather",
        visualTone: .orange
      )
    case .chutes:
      ProviderProfile(
        displayName: "Chutes",
        category: .inferenceClouds,
        serviceSummary: "OpenAI-compatible chat inference through Chutes",
        baseURL: "https://llm.chutes.ai/v1",
        suggestedModels: ["Qwen/Qwen3.5-397B-A17B-TEE", "zai-org/GLM-5.2-TEE"],
        capabilities: [.chat, .modelDiscovery],
        modelCatalogKind: .topLevelTextOutput,
        logoAssetName: "ProviderLogoChutes",
        symbolName: "arrow.down.forward.circle",
        visualTone: .teal
      )
    case .siliconFlow:
      ProviderProfile(
        displayName: "SiliconFlow",
        category: .inferenceClouds,
        serviceSummary: "Global hosted chat and embedding models",
        baseURL: "https://api.siliconflow.com/v1",
        suggestedModels: ["Qwen/Qwen3-32B"],
        capabilities: [.chat, .embeddings, .modelDiscovery],
        defaultEmbeddingModel: "Qwen/Qwen3-Embedding-8B",
        modelCatalogKind: .siliconFlow,
        logoAssetName: "ProviderLogoSiliconFlow",
        symbolName: "flowchart",
        visualTone: .blue
      )
    case .perplexity:
      ProviderProfile(
        displayName: "Perplexity Sonar",
        category: .modelGateways,
        serviceSummary: "Web-grounded Sonar answer models",
        baseURL: "https://api.perplexity.ai",
        suggestedModels: ["sonar", "sonar-pro", "sonar-deep-research", "sonar-reasoning-pro"],
        capabilities: [.chat],
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoPerplexity",
        symbolName: "magnifyingglass.circle",
        visualTone: .teal
      )
    case .huggingFace:
      ProviderProfile(
        displayName: "Hugging Face",
        category: .modelGateways,
        serviceSummary: "Inference Providers routing across hosted models",
        baseURL: "https://router.huggingface.co/v1",
        suggestedModels: ["openai/gpt-oss-120b:fastest", "openai/gpt-oss-120b:cerebras"],
        capabilities: [.chat, .modelDiscovery],
        modelCatalogKind: .architectureTextOutput,
        logoAssetName: "ProviderLogoHuggingFace",
        symbolName: "face.smiling",
        visualTone: .yellow
      )
    case .openRouter:
      ProviderProfile(
        displayName: "OpenRouter",
        category: .modelGateways,
        serviceSummary: "One API for chat and embedding models from multiple providers",
        baseURL: "https://openrouter.ai/api/v1",
        suggestedModels: [
          "openai/gpt-5.6", "anthropic/claude-sonnet-5", "google/gemini-3.8-flash",
        ],
        capabilities: [.chat, .embeddings, .modelDiscovery],
        defaultEmbeddingModel: "openai/text-embedding-3-small",
        modelCatalogKind: .openRouter,
        includesStreamingUsage: true,
        logoAssetName: "ProviderLogoOpenRouter",
        symbolName: "arrow.triangle.branch",
        visualTone: .purple
      )
    case .aimlAPI:
      ProviderProfile(
        displayName: "AI/ML API",
        category: .modelGateways,
        serviceSummary: "Unified chat and embedding models through AI/ML API",
        baseURL: "https://api.aimlapi.com/v1",
        suggestedModels: [],
        capabilities: [.chat, .embeddings, .modelDiscovery],
        defaultEmbeddingModel: "text-embedding-3-small",
        modelCatalogKind: .aimlAPI,
        logoAssetName: "ProviderLogoAIMLAPI",
        symbolName: "point.3.filled.connected.trianglepath.dotted",
        visualTone: .indigo
      )
    case .microsoftFoundry:
      ProviderProfile(
        displayName: "Microsoft Foundry",
        category: .modelGateways,
        serviceSummary: "Azure OpenAI v1 deployments with a resource-specific endpoint",
        baseURL: nil,
        suggestedModels: [],
        capabilities: [.chat, .embeddings],
        authenticationStyle: .apiKeyHeader,
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoMicrosoftFoundry",
        symbolName: "square.grid.2x2",
        visualTone: .blue
      )
    case .amazonBedrock:
      ProviderProfile(
        displayName: "Amazon Bedrock",
        category: .modelGateways,
        serviceSummary: "Bedrock chat models through a regional OpenAI-compatible endpoint",
        baseURL: nil,
        suggestedModels: ["openai.gpt-oss-120b"],
        capabilities: [.chat],
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoAmazonBedrock",
        symbolName: "shippingbox",
        visualTone: .orange
      )
    case .deepInfra:
      ProviderProfile(
        displayName: "DeepInfra",
        category: .inferenceClouds,
        serviceSummary: "Hosted open models for chat and embeddings",
        baseURL: "https://api.deepinfra.com/v1/openai",
        suggestedModels: ["deepseek-ai/DeepSeek-V4-Flash-0731"],
        capabilities: [.chat, .embeddings, .modelDiscovery],
        defaultEmbeddingModel: "Qwen/Qwen3-Embedding-8B",
        modelCatalogKind: .deepInfra,
        includesStreamingUsage: true,
        logoAssetName: "ProviderLogoDeepInfra",
        symbolName: "bolt.horizontal.circle",
        visualTone: .blue
      )
    case .tinfoil:
      ProviderProfile(
        displayName: "Tinfoil",
        category: .inferenceClouds,
        serviceSummary: "Privacy-focused hosted model inference",
        baseURL: "https://inference.tinfoil.sh/v1",
        suggestedModels: ["gpt-oss-120b"],
        capabilities: [.chat, .embeddings, .modelDiscovery],
        defaultEmbeddingModel: "nomic-embed-text",
        modelCatalogKind: .tinfoil,
        includesStreamingUsage: true,
        logoAssetName: "ProviderLogoTinfoil",
        symbolName: "cloud",
        visualTone: .teal
      )
    case .vercelAI:
      ProviderProfile(
        displayName: "Vercel AI Gateway",
        category: .modelGateways,
        serviceSummary: "Unified chat and embedding models through Vercel AI Gateway",
        baseURL: "https://ai-gateway.vercel.sh/v1",
        suggestedModels: ["openai/gpt-5.6-sol", "anthropic/claude-opus-5"],
        capabilities: [.chat, .embeddings, .modelDiscovery],
        defaultEmbeddingModel: "openai/text-embedding-3-small",
        modelCatalogKind: .vercel,
        includesStreamingUsage: true,
        logoAssetName: "ProviderLogoVercelAI",
        symbolName: "triangle.fill",
        visualTone: .primary
      )
    case .novitaAI:
      ProviderProfile(
        displayName: "Novita AI",
        category: .inferenceClouds,
        serviceSummary: "OpenAI-compatible hosted LLM and embedding inference",
        baseURL: "https://api.novita.ai/openai/v1",
        suggestedModels: ["zai-org/glm-5.3-flash", "deepseek/deepseek-v4-pro"],
        capabilities: [.chat, .embeddings],
        defaultEmbeddingModel: "baai/bge-m3",
        modelCatalogKind: .unavailable,
        includesStreamingUsage: true,
        logoAssetName: "ProviderLogoNovitaAI",
        symbolName: "sparkles.rectangle.stack",
        visualTone: .purple
      )
    case .tencentTokenHub:
      ProviderProfile(
        displayName: "Tencent TokenHub",
        category: .modelGateways,
        serviceSummary: "Tencent and third-party chat and embedding models",
        baseURL: "https://tokenhub-intl.tencentmaas.com/v1",
        suggestedModels: ["deepseek-v4-flash", "hy3"],
        capabilities: [.chat, .embeddings, .modelDiscovery],
        defaultEmbeddingModel: "kinfra-text-embedding-0.6b",
        modelCatalogKind: .tencentTokenHub,
        logoAssetName: "ProviderLogoTencentTokenHub",
        symbolName: "cloud",
        visualTone: .blue
      )
    case .baiduQianfan:
      ProviderProfile(
        displayName: "Baidu Qianfan",
        category: .modelGateways,
        serviceSummary: "ERNIE and third-party models through Baidu Qianfan",
        baseURL: "https://qianfan.baidubce.com/v2",
        suggestedModels: ["ernie-5.0", "deepseek-v4-pro"],
        capabilities: [.chat, .embeddings, .modelDiscovery],
        defaultEmbeddingModel: "embedding-v1",
        modelCatalogKind: .baiduQianfan,
        logoAssetName: "ProviderLogoBaiduQianfan",
        symbolName: "brain.head.profile",
        visualTone: .blue
      )
    case .poe:
      ProviderProfile(
        displayName: "Poe",
        category: .modelGateways,
        serviceSummary: "Text models and public bots available through Poe",
        baseURL: "https://api.poe.com/v1",
        suggestedModels: ["Claude-Sonnet-4.6", "GPT-5.4"],
        capabilities: [.chat, .modelDiscovery],
        modelCatalogKind: .poe,
        logoAssetName: "ProviderLogoPoe",
        symbolName: "bubble.left.and.bubble.right",
        visualTone: .purple
      )
    case .voyageAI:
      ProviderProfile(
        displayName: "Voyage AI",
        category: .retrieval,
        serviceSummary: "Dedicated semantic embedding models",
        baseURL: "https://api.voyageai.com/v1",
        suggestedModels: ["voyage-4", "voyage-4-large"],
        capabilities: [.embeddings],
        defaultEmbeddingModel: "voyage-4",
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoVoyageAI",
        symbolName: "sailboat",
        visualTone: .blue
      )
    case .jinaAI:
      ProviderProfile(
        displayName: "Jina AI",
        category: .retrieval,
        serviceSummary: "Text embedding models for semantic retrieval",
        baseURL: "https://api.jina.ai/v1",
        suggestedModels: ["jina-embeddings-v5-text-small", "jina-embeddings-v5-omni-small"],
        capabilities: [.embeddings],
        defaultEmbeddingModel: "jina-embeddings-v5-text-small",
        modelCatalogKind: .unavailable,
        logoAssetName: "ProviderLogoJinaAI",
        symbolName: "square.grid.3x3",
        visualTone: .purple
      )
    case .ollama:
      localProfile(
        displayName: "Ollama",
        serviceSummary: "Models served by Ollama on this Mac or network",
        baseURL: "http://127.0.0.1:11434/v1",
        suggestedModels: ["llama3.2"],
        defaultEmbeddingModel: "embeddinggemma",
        logoAssetName: "ProviderLogoOllama",
        symbolName: "desktopcomputer"
      )
    case .lmStudio:
      localProfile(
        displayName: "LM Studio",
        serviceSummary: "Models served by LM Studio",
        baseURL: "http://127.0.0.1:1234/v1",
        modelCatalogKind: .lmStudio,
        logoAssetName: "ProviderLogoLMStudio",
        symbolName: "macstudio"
      )
    case .localAI:
      localProfile(
        displayName: "LocalAI",
        serviceSummary: "OpenAI-compatible LocalAI models",
        baseURL: "http://127.0.0.1:8080/v1",
        logoAssetName: "ProviderLogoLocalAI",
        symbolName: "server.rack"
      )
    case .vLLM:
      localProfile(
        displayName: "vLLM",
        serviceSummary: "Models served by a local or network vLLM server",
        baseURL: "http://127.0.0.1:8000/v1",
        logoAssetName: "ProviderLogoVLLM",
        symbolName: "speedometer"
      )
    case .sglang:
      localProfile(
        displayName: "SGLang",
        serviceSummary: "Models served by an SGLang runtime",
        baseURL: "http://127.0.0.1:30000/v1",
        logoAssetName: "ProviderLogoSGLang",
        symbolName: "bolt.square"
      )
    case .llamaCpp:
      localProfile(
        displayName: "llama.cpp",
        serviceSummary: "Models served by llama.cpp's local server",
        baseURL: "http://127.0.0.1:8080/v1",
        logoAssetName: "ProviderLogoLlamaCpp",
        symbolName: "terminal"
      )
    case .jan:
      localProfile(
        displayName: "Jan",
        serviceSummary: "Models served by Jan's local API",
        baseURL: "http://127.0.0.1:1337/v1",
        logoAssetName: "ProviderLogoJan",
        symbolName: "laptopcomputer"
      )
    case .custom:
      ProviderProfile(
        displayName: "Custom OpenAI-compatible",
        category: .custom,
        serviceSummary: "Any OpenAI-compatible chat or embedding endpoint",
        baseURL: nil,
        suggestedModels: [],
        capabilities: [.chat, .embeddings],
        requiresAPIKey: false,
        modelCatalogKind: .unavailable,
        suggestedContextWindowTokens: 8_192,
        suggestedMaximumOutputTokens: 2_048,
        logoAssetName: "ProviderLogoCustom",
        symbolName: "network",
        visualTone: .accent
      )
    }
  }

  public var category: ProviderCategory { providerProfile.category }
  public var capabilities: ProviderCapabilities { providerProfile.capabilities }
  public var supportsChat: Bool { capabilities.contains(.chat) }
  public var supportsEmbeddings: Bool { capabilities.contains(.embeddings) }
  /// Providers with a documented rerank endpoint: Cohere, Jina, Voyage, DeepInfra (its native
  /// inference route), and the self-hosted runtimes that serve `/rerank` (llama.cpp, vLLM, LocalAI)
  /// or a custom compatible host.
  public var supportsReranking: Bool {
    switch self {
    case .cohere, .voyageAI, .jinaAI, .deepInfra, .llamaCpp, .vLLM, .localAI, .custom: true
    default: false
    }
  }
  public var supportsModelDiscovery: Bool { capabilities.contains(.modelDiscovery) }
  public var supportsLiveTranscription: Bool { capabilities.contains(.liveTranscription) }
  public var suggestedModelIdentifiers: [String] {
    BundledProviderModelCatalog.models(for: self)
  }
  public var defaultModelIdentifier: String { suggestedModelIdentifiers.first ?? "" }
  public var defaultEmbeddingModelIdentifier: String? { providerProfile.defaultEmbeddingModel }
  /// A reranker to start from. benchmarks/memory measured Voyage rerank-2.5 (MRR@10 0.995), Cohere
  /// rerank-v4.0-pro (0.981; rerank-v3.5 0.968) and DeepInfra Qwen3-Reranker-8B (0.980; the
  /// Nemotron reranker scored 0.982 but returns raw logits, which makes a minimum relevance
  /// meaningless). Jina's suggestion was not measured.
  public var defaultRerankModelIdentifier: String? {
    switch self {
    case .voyageAI: "rerank-2.5"
    case .cohere: "rerank-v4.0-pro"
    case .jinaAI: "jina-reranker-v2-base-multilingual"
    case .deepInfra: "Qwen/Qwen3-Reranker-8B"
    default: nil
    }
  }
  public var defaultLiveTranscriptionModelIdentifier: String? {
    supportsLiveTranscription ? "gemini-3.5-transcribe-live" : nil
  }
  public var defaultBaseURL: URL? { providerProfile.baseURL.flatMap(URL.init(string:)) }
  public var requiresAPIKey: Bool { providerProfile.requiresAPIKey }
  public var suggestedContextWindowTokens: Int {
    providerProfile.suggestedContextWindowTokens
  }
  public var suggestedMaximumOutputTokens: Int {
    providerProfile.suggestedMaximumOutputTokens
  }
  public var symbolName: String { providerProfile.symbolName }
  public var logoAssetName: String { providerProfile.logoAssetName }
  var serviceSummary: String { providerProfile.serviceSummary }
  var authenticationStyle: ProviderAuthenticationStyle { providerProfile.authenticationStyle }
  var modelCatalogKind: ProviderModelCatalogKind { providerProfile.modelCatalogKind }
  var includesStreamingUsage: Bool { providerProfile.includesStreamingUsage }
  var visualTone: ProviderVisualTone { providerProfile.visualTone }

  public static func cases(in category: ProviderCategory) -> [ProviderKind] {
    allCases.filter { $0.category == category }
  }

  private func localProfile(
    displayName: String,
    serviceSummary: String,
    baseURL: String,
    suggestedModels: [String] = [],
    defaultEmbeddingModel: String? = nil,
    modelCatalogKind: ProviderModelCatalogKind = .unavailable,
    logoAssetName: String,
    symbolName: String
  ) -> ProviderProfile {
    ProviderProfile(
      displayName: displayName,
      category: .local,
      serviceSummary: serviceSummary,
      baseURL: baseURL,
      suggestedModels: suggestedModels,
      capabilities: modelCatalogKind == .unavailable
        ? [.chat, .embeddings]
        : [.chat, .embeddings, .modelDiscovery],
      defaultEmbeddingModel: defaultEmbeddingModel,
      requiresAPIKey: false,
      modelCatalogKind: modelCatalogKind,
      suggestedContextWindowTokens: 8_192,
      suggestedMaximumOutputTokens: 2_048,
      logoAssetName: logoAssetName,
      symbolName: symbolName,
      visualTone: .primary
    )
  }
}

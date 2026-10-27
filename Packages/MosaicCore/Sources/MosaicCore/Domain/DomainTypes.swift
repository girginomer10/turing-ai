import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case openAI = "openai"
  case anthropic
  case google
  case xAI = "xai"
  case meta
  case mistral
  case cohere
  case deepSeek = "deepseek"
  case qwen
  case kimi
  case zAI = "zai"
  case miniMax = "minimax"
  case ai21
  case groq
  case togetherAI = "together_ai"
  case fireworksAI = "fireworks_ai"
  case cerebras
  case sambaNova = "sambanova"
  case nvidiaNIM = "nvidia_nim"
  case nebius
  case hyperbolic
  case baseten
  case scaleway
  case digitalOcean = "digitalocean"
  case featherlessAI = "featherless_ai"
  case chutes
  case siliconFlow = "siliconflow"
  case perplexity
  case huggingFace = "huggingface"
  case openRouter = "openrouter"
  case aimlAPI = "aiml_api"
  case microsoftFoundry = "microsoft_foundry"
  case amazonBedrock = "amazon_bedrock"
  case deepInfra = "deepinfra"
  case tinfoil
  case vercelAI = "vercel_ai"
  case novitaAI = "novita_ai"
  case tencentTokenHub = "tencent_tokenhub"
  case baiduQianfan = "baidu_qianfan"
  case poe
  case voyageAI = "voyage_ai"
  case jinaAI = "jina_ai"
  case ollama
  case lmStudio = "lm_studio"
  case localAI = "local_ai"
  case vLLM = "vllm"
  case sglang
  case llamaCpp = "llama_cpp"
  case jan
  case custom

  public var id: String { rawValue }

  public var displayName: String { providerProfile.displayName }
}

public enum ProviderCategory: String, CaseIterable, Identifiable, Sendable {
  case modelLabs
  case inferenceClouds
  case modelGateways
  case retrieval
  case local
  case custom

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .modelLabs: "Model Labs"
    case .inferenceClouds: "Inference Clouds"
    case .modelGateways: "Model Gateways"
    case .retrieval: "Embeddings & Retrieval"
    case .local: "Local Runtimes"
    case .custom: "Custom"
    }
  }
}

public struct ProviderCapabilities: OptionSet, Hashable, Sendable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static let chat = ProviderCapabilities(rawValue: 1 << 0)
  public static let embeddings = ProviderCapabilities(rawValue: 1 << 1)
  public static let modelDiscovery = ProviderCapabilities(rawValue: 1 << 2)
  public static let liveTranscription = ProviderCapabilities(rawValue: 1 << 3)
}

public enum EmbeddingBackend: String, Codable, CaseIterable, Identifiable, Sendable {
  case provider

  public var id: String { rawValue }
}

public enum RetrievalSourceKind: String, Codable, CaseIterable, Sendable {
  case conversationMessage = "conversation_message"
  case documentChunk = "document_chunk"
  case memoryTopic = "memory_topic"
}

public struct EmbeddingProfileSnapshot: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let displayName: String
  public let backend: EmbeddingBackend
  public let providerConfigurationID: UUID?
  public let modelIdentifier: String
  public let weight: Double
  public let isEnabled: Bool
  public let indexesConversations: Bool
  public let indexesDocuments: Bool

  public init(
    id: UUID,
    displayName: String,
    backend: EmbeddingBackend,
    providerConfigurationID: UUID?,
    modelIdentifier: String,
    weight: Double,
    isEnabled: Bool,
    indexesConversations: Bool,
    indexesDocuments: Bool
  ) {
    self.id = id
    self.displayName = displayName
    self.backend = backend
    self.providerConfigurationID = providerConfigurationID
    self.modelIdentifier = modelIdentifier
    self.weight = weight
    self.isEnabled = isEnabled
    self.indexesConversations = indexesConversations
    self.indexesDocuments = indexesDocuments
  }
}

public enum MessageRole: String, Codable, CaseIterable, Sendable {
  case system
  case user
  case assistant
  case tool
}

public enum MessageStatus: String, Codable, CaseIterable, Sendable {
  case pending
  case streaming
  case complete
  case failed
  case cancelled
}

public enum MemoryScope: String, Codable, CaseIterable, Sendable {
  case global
  case project
  case conversation
}

public enum ScheduleRecurrence: String, Codable, CaseIterable, Sendable {
  case once
  case daily
  case weekly
}

public enum ScheduledTaskStatus: String, Codable, CaseIterable, Sendable {
  case active
  case paused
  case completed
  case failed
}

/// A non-secret pointer that lets the app locate a provider credential in Keychain.
public struct ProviderCredentialReference: Hashable, Codable, Sendable {
  public let configurationID: UUID

  public init(configurationID: UUID) {
    self.configurationID = configurationID
  }

  public var account: String { configurationID.uuidString.lowercased() }
}

public struct MemorySnapshot: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let title: String
  public let content: String
  public let scope: MemoryScope
  /// Resolved from the additive project-binding table. Historical MemoryRecord rows stay frozen.
  public let projectID: UUID?
  public let conversationID: UUID?
  public let isEnabled: Bool
  public let isUserApproved: Bool
  public let updatedAt: Date
  /// Fingerprint of the complete authoritative source row before prompt-size truncation.
  public let sourceFingerprint: String?

  public init(
    id: UUID = UUID(),
    title: String,
    content: String,
    scope: MemoryScope = .global,
    projectID: UUID? = nil,
    conversationID: UUID? = nil,
    isEnabled: Bool = true,
    isUserApproved: Bool = false,
    updatedAt: Date = .now,
    sourceFingerprint: String? = nil
  ) {
    self.id = id
    self.title = title
    self.content = content
    self.scope = scope
    self.projectID = projectID
    self.conversationID = conversationID
    self.isEnabled = isEnabled
    self.isUserApproved = isUserApproved
    self.updatedAt = updatedAt
    self.sourceFingerprint = sourceFingerprint
  }
}

public struct IncludedMemory: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let title: String
  public let content: String
  public let scope: MemoryScope
  /// Fingerprint of the complete source row; rendered title/content may be safely truncated.
  public let sourceFingerprint: String?

  public init(
    id: UUID,
    title: String,
    content: String,
    scope: MemoryScope,
    sourceFingerprint: String? = nil
  ) {
    self.id = id
    self.title = title
    self.content = content
    self.scope = scope
    self.sourceFingerprint = sourceFingerprint
  }
}

public struct RetrievalCandidate: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let source: RetrievalSourceKind
  public let containerID: UUID
  public let title: String
  public let content: String
  public let pageNumber: Int?
  public let isOCRDerived: Bool?
  public let memoryConfidence: Double?
  public let memoryImportance: Double?
  public let memoryKind: MemoryTopicKind?
  public let memoryLastConfirmedAt: Date?
  public let createdAt: Date

  public init(
    id: UUID,
    source: RetrievalSourceKind,
    containerID: UUID,
    title: String,
    content: String,
    pageNumber: Int? = nil,
    isOCRDerived: Bool? = nil,
    memoryConfidence: Double? = nil,
    memoryImportance: Double? = nil,
    memoryKind: MemoryTopicKind? = nil,
    memoryLastConfirmedAt: Date? = nil,
    createdAt: Date
  ) {
    self.id = id
    self.source = source
    self.containerID = containerID
    self.title = title
    self.content = content
    self.pageNumber = pageNumber
    self.isOCRDerived = isOCRDerived
    self.memoryConfidence = memoryConfidence
    self.memoryImportance = memoryImportance
    self.memoryKind = memoryKind
    self.memoryLastConfirmedAt = memoryLastConfirmedAt
    self.createdAt = createdAt
  }
}

public struct RetrievedContextItem: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let source: RetrievalSourceKind
  public let containerID: UUID
  public let title: String
  public let content: String
  public let pageNumber: Int?
  public let isOCRDerived: Bool?
  public let memoryConfidence: Double?
  public let memoryImportance: Double?
  public let memoryKind: MemoryTopicKind?
  public let memoryLastConfirmedAt: Date?
  public let createdAt: Date
  public let relevance: Double
  /// Fingerprint of the complete authoritative candidate before excerpt truncation.
  public let sourceFingerprint: String?

  public init(
    candidate: RetrievalCandidate,
    relevance: Double,
    sourceFingerprint: String? = nil
  ) {
    id = candidate.id
    source = candidate.source
    containerID = candidate.containerID
    title = candidate.title
    content = candidate.content
    pageNumber = candidate.pageNumber
    isOCRDerived = candidate.isOCRDerived
    memoryConfidence = candidate.memoryConfidence
    memoryImportance = candidate.memoryImportance
    memoryKind = candidate.memoryKind
    memoryLastConfirmedAt = candidate.memoryLastConfirmedAt
    createdAt = candidate.createdAt
    self.relevance = relevance
    self.sourceFingerprint = sourceFingerprint
  }
}

/// Exact past-chat and document excerpts automatically attached to one request.
public struct RetrievedContext: Hashable, Codable, Sendable {
  public let systemContent: String
  public let items: [RetrievedContextItem]
  public let embeddingProfilesUsed: [String]
  public let warnings: [String]

  public init(
    systemContent: String,
    items: [RetrievedContextItem],
    embeddingProfilesUsed: [String] = [],
    warnings: [String] = []
  ) {
    self.systemContent = systemContent
    self.items = items
    self.embeddingProfilesUsed = embeddingProfilesUsed
    self.warnings = warnings
  }

  public var isEmpty: Bool { items.isEmpty }

  public static let empty = RetrievedContext(systemContent: "", items: [])
}

/// The generated system context and the exact memories used to build it.
/// `includedMemories` is intentionally public so the UI can disclose the source context.
public struct MemoryContext: Hashable, Codable, Sendable {
  public let systemContent: String
  public let includedMemories: [IncludedMemory]

  public init(systemContent: String, includedMemories: [IncludedMemory]) {
    self.systemContent = systemContent
    self.includedMemories = includedMemories
  }

  public var isEmpty: Bool { includedMemories.isEmpty }

  public static let empty = MemoryContext(systemContent: "", includedMemories: [])
}

/// Immutable disclosure of the exact local context attached to one provider request.
public enum ConversationContextStrategy: String, Hashable, Codable, Sendable {
  case full
  case recentOnly = "recent_only"
  case summaryAndRecent = "summary_and_recent"
}

/// Immutable disclosure of which conversation messages fit into one provider request.
public struct ConversationContextReceipt: Hashable, Codable, Sendable {
  public let strategy: ConversationContextStrategy
  public let originalMessageCount: Int
  public let includedMessageIDs: [UUID]
  public let omittedMessageIDs: [UUID]
  /// Raw messages represented by an app-owned rolling summary instead of being sent verbatim.
  /// Optional so receipts written before conversation compaction remain decodable.
  public let summarizedMessageIDs: [UUID]?
  /// Older user messages reattached as exact, untrusted historical excerpts.
  /// Optional so receipts written before same-conversation recall remain decodable.
  public let recalledMessageIDs: [UUID]?
  public let estimatedInputTokens: Int
  public let contextWindowTokens: Int
  public let maximumOutputTokens: Int
  public let safetyMarginTokens: Int
  public let warnings: [String]

  public init(
    strategy: ConversationContextStrategy,
    originalMessageCount: Int,
    includedMessageIDs: [UUID],
    omittedMessageIDs: [UUID],
    summarizedMessageIDs: [UUID]? = nil,
    recalledMessageIDs: [UUID]? = nil,
    estimatedInputTokens: Int,
    contextWindowTokens: Int,
    maximumOutputTokens: Int,
    safetyMarginTokens: Int,
    warnings: [String] = []
  ) {
    self.strategy = strategy
    self.originalMessageCount = originalMessageCount
    self.includedMessageIDs = includedMessageIDs
    self.omittedMessageIDs = omittedMessageIDs
    self.summarizedMessageIDs = summarizedMessageIDs
    self.recalledMessageIDs = recalledMessageIDs
    self.estimatedInputTokens = estimatedInputTokens
    self.contextWindowTokens = contextWindowTokens
    self.maximumOutputTokens = maximumOutputTokens
    self.safetyMarginTokens = safetyMarginTokens
    self.warnings = warnings
  }

  public var includedMessageCount: Int { includedMessageIDs.count }
  public var omittedMessageCount: Int { omittedMessageIDs.count }
  public var summarizedMessageCount: Int { summarizedMessageIDs?.count ?? 0 }
  public var recalledMessageCount: Int { recalledMessageIDs?.count ?? 0 }
}

public enum ConversationCompactionAttemptStatus: String, Hashable, Codable, Sendable {
  case generating
  case generated
  case reused
  case failed
  case cancelled
}

/// Immutable audit information for the extra model request used to compress older chat turns.
/// It contains no credential and never replaces the raw local messages.
public struct ConversationCompactionReceipt: Hashable, Codable, Sendable {
  public let attemptID: UUID
  public let status: ConversationCompactionAttemptStatus
  public let compactionID: UUID?
  public let summaryText: String?
  public let coveredMessageIDs: [UUID]
  /// Raw source messages offered to the new attempt. During an extension this is only the new
  /// delta because the older covered prefix is represented by the previous summary.
  public let attemptedMessageIDs: [UUID]?
  /// Provenance of the summary actually attached to the final answer request. These can differ
  /// from the attempt fields below when a failed extension falls back to an older valid summary.
  public let activeSummaryProviderConfigurationID: UUID?
  public let activeSummaryProviderKind: ProviderKind?
  public let activeSummaryProviderDisplayName: String?
  public let activeSummaryProviderEndpoint: String?
  public let activeSummaryModelIdentifier: String?
  public let activeSummaryCreatedAt: Date?
  public let providerConfigurationID: UUID
  public let providerKind: ProviderKind
  public let providerDisplayName: String
  public let providerEndpoint: String
  public let modelIdentifier: String
  public let providerMessageID: String?
  public let inputTokenCount: Int?
  public let outputTokenCount: Int?
  public let estimatedInputTokensBefore: Int
  public let estimatedInputTokensAfter: Int?
  public let extraRequestCount: Int
  public let errorDescription: String?
  public let warnings: [String]
  public let createdAt: Date

  public init(
    attemptID: UUID,
    status: ConversationCompactionAttemptStatus,
    compactionID: UUID? = nil,
    summaryText: String? = nil,
    coveredMessageIDs: [UUID] = [],
    attemptedMessageIDs: [UUID]? = nil,
    activeSummaryProviderConfigurationID: UUID? = nil,
    activeSummaryProviderKind: ProviderKind? = nil,
    activeSummaryProviderDisplayName: String? = nil,
    activeSummaryProviderEndpoint: String? = nil,
    activeSummaryModelIdentifier: String? = nil,
    activeSummaryCreatedAt: Date? = nil,
    providerConfigurationID: UUID,
    providerKind: ProviderKind,
    providerDisplayName: String,
    providerEndpoint: String,
    modelIdentifier: String,
    providerMessageID: String? = nil,
    inputTokenCount: Int? = nil,
    outputTokenCount: Int? = nil,
    estimatedInputTokensBefore: Int,
    estimatedInputTokensAfter: Int? = nil,
    extraRequestCount: Int,
    errorDescription: String? = nil,
    warnings: [String] = [],
    createdAt: Date = .now
  ) {
    self.attemptID = attemptID
    self.status = status
    self.compactionID = compactionID
    self.summaryText = summaryText
    self.coveredMessageIDs = coveredMessageIDs
    self.attemptedMessageIDs = attemptedMessageIDs
    self.activeSummaryProviderConfigurationID = activeSummaryProviderConfigurationID
    self.activeSummaryProviderKind = activeSummaryProviderKind
    self.activeSummaryProviderDisplayName = activeSummaryProviderDisplayName
    self.activeSummaryProviderEndpoint = activeSummaryProviderEndpoint
    self.activeSummaryModelIdentifier = activeSummaryModelIdentifier
    self.activeSummaryCreatedAt = activeSummaryCreatedAt
    self.providerConfigurationID = providerConfigurationID
    self.providerKind = providerKind
    self.providerDisplayName = providerDisplayName
    self.providerEndpoint = providerEndpoint
    self.modelIdentifier = modelIdentifier
    self.providerMessageID = providerMessageID
    self.inputTokenCount = inputTokenCount
    self.outputTokenCount = outputTokenCount
    self.estimatedInputTokensBefore = estimatedInputTokensBefore
    self.estimatedInputTokensAfter = estimatedInputTokensAfter
    self.extraRequestCount = extraRequestCount
    self.errorDescription = errorDescription
    self.warnings = warnings
    self.createdAt = createdAt
  }

  public func updatingEstimatedInputTokensAfter(
    _ estimatedInputTokensAfter: Int?
  ) -> ConversationCompactionReceipt {
    ConversationCompactionReceipt(
      attemptID: attemptID,
      status: status,
      compactionID: compactionID,
      summaryText: summaryText,
      coveredMessageIDs: coveredMessageIDs,
      attemptedMessageIDs: attemptedMessageIDs,
      activeSummaryProviderConfigurationID: activeSummaryProviderConfigurationID,
      activeSummaryProviderKind: activeSummaryProviderKind,
      activeSummaryProviderDisplayName: activeSummaryProviderDisplayName,
      activeSummaryProviderEndpoint: activeSummaryProviderEndpoint,
      activeSummaryModelIdentifier: activeSummaryModelIdentifier,
      activeSummaryCreatedAt: activeSummaryCreatedAt,
      providerConfigurationID: providerConfigurationID,
      providerKind: providerKind,
      providerDisplayName: providerDisplayName,
      providerEndpoint: providerEndpoint,
      modelIdentifier: modelIdentifier,
      providerMessageID: providerMessageID,
      inputTokenCount: inputTokenCount,
      outputTokenCount: outputTokenCount,
      estimatedInputTokensBefore: estimatedInputTokensBefore,
      estimatedInputTokensAfter: estimatedInputTokensAfter,
      extraRequestCount: extraRequestCount,
      errorDescription: errorDescription,
      warnings: warnings,
      createdAt: createdAt
    )
  }
}

public struct ProjectContextReceipt: Hashable, Codable, Sendable {
  public let projectID: UUID
  public let name: String
  /// Exact user-authored project instructions included in this provider request.
  public let instructions: String

  public init(projectID: UUID, name: String, instructions: String) {
    self.projectID = projectID
    self.name = name
    self.instructions = instructions
  }
}

public struct RequestContextReceipt: Hashable, Codable, Sendable {
  public let curatedContext: MemoryContext
  public let retrievedContext: RetrievedContext
  /// Optional so request receipts written before projects remain decodable.
  public let projectContext: ProjectContextReceipt?
  public let conversationContext: ConversationContextReceipt?
  /// Exact older user excerpts recalled from this same conversation as untrusted history.
  /// Optional so receipts written before same-conversation recall remain decodable.
  public let sameConversationRecall: SameConversationRecallReceipt?
  /// Optional for backward compatibility with receipts created before rolling compaction.
  public let conversationCompaction: ConversationCompactionReceipt?
  public let createdAt: Date

  public init(
    curatedContext: MemoryContext,
    retrievedContext: RetrievedContext,
    projectContext: ProjectContextReceipt? = nil,
    conversationContext: ConversationContextReceipt? = nil,
    sameConversationRecall: SameConversationRecallReceipt? = nil,
    conversationCompaction: ConversationCompactionReceipt? = nil,
    createdAt: Date = .now
  ) {
    self.curatedContext = curatedContext
    self.retrievedContext = retrievedContext
    self.projectContext = projectContext
    self.conversationContext = conversationContext
    self.sameConversationRecall = sameConversationRecall
    self.conversationCompaction = conversationCompaction
    self.createdAt = createdAt
  }

  public static let empty = RequestContextReceipt(
    curatedContext: .empty,
    retrievedContext: .empty
  )
}

public typealias AIProviderKind = ProviderKind
public typealias RecurrenceRule = ScheduleRecurrence

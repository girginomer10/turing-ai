import Foundation

/// Provider-independent limits used to keep one chat request inside a conservative context window.
public struct ConversationContextPolicy: Hashable, Codable, Sendable {
  public let contextWindowTokens: Int
  public let maximumOutputTokens: Int
  public let safetyMarginTokens: Int
  public let minimumRecentTurns: Int

  public init(
    contextWindowTokens: Int = 32_768,
    maximumOutputTokens: Int = 4_096,
    safetyMarginTokens: Int = 2_048,
    minimumRecentTurns: Int = 2
  ) {
    self.contextWindowTokens = max(1, contextWindowTokens)
    self.maximumOutputTokens = max(1, maximumOutputTokens)
    self.safetyMarginTokens = max(0, safetyMarginTokens)
    self.minimumRecentTurns = max(1, minimumRecentTurns)
  }

  public var availableInputTokens: Int {
    max(1, contextWindowTokens - maximumOutputTokens - safetyMarginTokens)
  }

  public static let conservativeDefault = ConversationContextPolicy()
}

/// Resolves the limits saved with a provider configuration. Older records use clearly disclosed
/// provider-category suggestions until the person reviews and saves explicit model limits.
public struct ProviderConversationContextLimits: Sendable {
  public let policy: ConversationContextPolicy
  public let warnings: [String]

  public init(configuration: ProviderConnection) {
    let modelDefaults = ProviderModelMetadataRegistry.defaultLimits(
      for: configuration.provider,
      modelIdentifier: configuration.modelIdentifier
    )
    let requestedWindow = configuration.contextWindowTokens ?? modelDefaults.contextWindowTokens
    let requestedOutput =
      configuration.maximumOutputTokens ?? modelDefaults.maximumOutputTokens
    let contextWindow = max(2_048, requestedWindow)
    let safetyMargin = max(512, min(2_048, contextWindow / 8))
    let maximumAllowedOutput = max(128, contextWindow - safetyMargin - 1)
    let maximumOutput = min(max(128, requestedOutput), maximumAllowedOutput)
    let hasSavedLimits =
      configuration.contextWindowTokens != nil && configuration.maximumOutputTokens != nil

    var warnings = [String]()
    if hasSavedLimits {
      warnings.append(
        "Turing AI used the model limits saved in this provider configuration. Review them whenever you change the model."
      )
    } else {
      warnings.append(
        "This older provider configuration has no saved model limits, so Turing AI used a \(contextWindow.formatted())-token context and \(maximumOutput.formatted())-token output fallback. Review these values in Provider settings."
      )
    }
    if contextWindow != requestedWindow || maximumOutput != requestedOutput {
      warnings.append("Invalid saved limits were adjusted to keep a positive input budget.")
    }
    warnings.append(
      "Input size uses a conservative byte-based estimate because providers tokenize text differently."
    )

    policy = ConversationContextPolicy(
      contextWindowTokens: contextWindow,
      maximumOutputTokens: maximumOutput,
      safetyMarginTokens: safetyMargin,
      minimumRecentTurns: 2
    )
    self.warnings = warnings
  }
}

public struct ConversationContextPlan: Hashable, Sendable {
  public let messages: [AIChatMessage]
  public let receipt: ConversationContextReceipt

  public init(messages: [AIChatMessage], receipt: ConversationContextReceipt) {
    self.messages = messages
    self.receipt = receipt
  }
}

public enum ConversationContextPlannerError: Error, Equatable, Sendable {
  case missingCurrentUserMessage
  case requiredContentExceedsBudget(requiredTokens: Int, availableTokens: Int)
}

extension ConversationContextPlannerError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .missingCurrentUserMessage:
      "Turing AI could not find the current user message for this request."
    case .requiredContentExceedsBudget(let requiredTokens, let availableTokens):
      "The current message and attached context need about \(requiredTokens) input tokens, but the safe request budget is \(availableTokens). Shorten the message or remove some attached context, then try again. No chat-generation request was sent."
    }
  }
}

/// A deterministic, deliberately conservative estimator. Exact tokenization varies by provider,
/// so receipts always label these values as estimates.
public struct ConservativeTokenEstimator: Hashable, Sendable {
  public let messageFramingTokens: Int
  public let systemFramingTokens: Int

  public init(messageFramingTokens: Int = 8, systemFramingTokens: Int = 4) {
    self.messageFramingTokens = max(0, messageFramingTokens)
    self.systemFramingTokens = max(0, systemFramingTokens)
  }

  public func estimate(text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    // A byte-count upper bound intentionally overestimates ordinary prose while remaining safe
    // for high-token-density code, JSON, base64-like text, emoji, and unknown tokenizers.
    return text.utf8.count
  }

  public func estimate(message: AIChatMessage) -> Int {
    messageFramingTokens + estimate(text: message.content) + max(
      0, message.content.components(separatedBy: ChatAttachmentStore.imageMarker).count - 1) * 4_096
  }

  public func estimate(systemPrompt: String?) -> Int {
    guard let systemPrompt, !systemPrompt.isEmpty else { return 0 }
    return systemFramingTokens + estimate(text: systemPrompt)
  }
}

/// Selects one contiguous suffix of complete conversation turns. It never truncates message text,
/// never creates holes in history, and always protects the newest user turns.
public struct ConversationContextPlanner: Sendable {
  public let policy: ConversationContextPolicy
  public let estimator: ConservativeTokenEstimator
  public let warnings: [String]

  public init(
    policy: ConversationContextPolicy = .conservativeDefault,
    estimator: ConservativeTokenEstimator = ConservativeTokenEstimator(),
    warnings: [String] = [
      "Turing AI used fallback model limits for this request. Review the provider’s context settings."
    ]
  ) {
    self.policy = policy
    self.estimator = estimator
    self.warnings = warnings
  }

  public func plan(
    messages: [AIChatMessage],
    systemPrompt: String?
  ) throws -> ConversationContextPlan {
    guard let finalMessage = messages.last, finalMessage.role == .user else {
      throw ConversationContextPlannerError.missingCurrentUserMessage
    }

    let systemTokens = estimator.estimate(systemPrompt: systemPrompt)
    let messageCosts = messages.map(estimator.estimate(message:))
    let allMessagesTokens = messageCosts.reduce(0, +)
    let allInputTokens = systemTokens + allMessagesTokens
    let inputBudget = policy.availableInputTokens

    if allInputTokens <= inputBudget {
      return ConversationContextPlan(
        messages: messages,
        receipt: receipt(
          strategy: .full,
          allMessages: messages,
          includedMessages: messages,
          estimatedInputTokens: allInputTokens
        )
      )
    }

    let turnStarts = userTurnStartIndices(in: messages)
    // `minimumRecentTurns` describes completed prior turns. The pending current user turn is
    // protected in addition to those turns.
    let protectedTurnOffset = max(0, turnStarts.count - (policy.minimumRecentTurns + 1))
    let protectedStart = turnStarts[protectedTurnOffset]
    let protectedTokens = systemTokens + messageCosts[protectedStart...].reduce(0, +)

    guard protectedTokens <= inputBudget else {
      throw ConversationContextPlannerError.requiredContentExceedsBudget(
        requiredTokens: protectedTokens,
        availableTokens: inputBudget
      )
    }

    var includedStart = protectedStart
    var estimatedInputTokens = protectedTokens
    let earlierTurnStarts = Array(turnStarts[..<protectedTurnOffset])

    for turnStart in earlierTurnStarts.reversed() {
      let turnEnd = includedStart
      let turnTokens = messageCosts[turnStart..<turnEnd].reduce(0, +)
      guard estimatedInputTokens + turnTokens <= inputBudget else { break }
      estimatedInputTokens += turnTokens
      includedStart = turnStart
    }

    // A malformed leading assistant-only prefix is included only when the full request fits. Once
    // compaction is needed, the selected suffix starts on a user turn and remains conversationally
    // coherent.
    let includedMessages = Array(messages[includedStart...])
    return ConversationContextPlan(
      messages: includedMessages,
      receipt: receipt(
        strategy: .recentOnly,
        allMessages: messages,
        includedMessages: includedMessages,
        estimatedInputTokens: estimatedInputTokens
      )
    )
  }

  private func userTurnStartIndices(in messages: [AIChatMessage]) -> [Int] {
    let starts = messages.indices.filter { messages[$0].role == .user }
    // The final-message guard above guarantees at least one user turn.
    return starts.isEmpty ? [messages.index(before: messages.endIndex)] : starts
  }

  private func receipt(
    strategy: ConversationContextStrategy,
    allMessages: [AIChatMessage],
    includedMessages: [AIChatMessage],
    estimatedInputTokens: Int
  ) -> ConversationContextReceipt {
    let includedIDs = includedMessages.map(\.id)
    let includedIDSet = Set(includedIDs)
    let omittedIDs = allMessages.lazy.map(\.id).filter { !includedIDSet.contains($0) }
    return ConversationContextReceipt(
      strategy: strategy,
      originalMessageCount: allMessages.count,
      includedMessageIDs: includedIDs,
      omittedMessageIDs: Array(omittedIDs),
      estimatedInputTokens: estimatedInputTokens,
      contextWindowTokens: policy.contextWindowTokens,
      maximumOutputTokens: policy.maximumOutputTokens,
      safetyMarginTokens: policy.safetyMarginTokens,
      warnings: warnings
    )
  }
}

#if DEBUG
  import Foundation
  import SwiftData

  /// Synthetic, in-memory UI regression fixture. No credentials, Google reads or provider calls.
  @MainActor
  enum MessageSourcesPreview {
    static func seed(in context: ModelContext) throws -> UUID {
      let conversation = ConversationRecord(title: "Sources layout check")
      context.insert(conversation)
      if ProcessInfo.processInfo.arguments.contains("--composer-local-preview") {
        let provider = ProviderConfigurationRecord(
          displayName: "Local UI fixture", provider: .ollama,
          modelIdentifier: "fixture", baseURL: URL(string: "http://127.0.0.1:19423/v1"))
        context.insert(provider)
        conversation.providerConfigurationID = provider.id
        conversation.modelIdentifier = provider.modelIdentifier
      }
      let paused = ProcessInfo.processInfo.arguments.contains("--gmail-paused-preview")
      for index in (paused ? [23] : Array(0..<24)) {
        let message = MessageRecord(
          conversationID: conversation.id,
          role: index.isMultiple(of: 2) ? .user : .assistant,
          content: index == 23
            ? "I found several relevant items. Open Sources to inspect the original links.\n\nThis is a synthetic layout check; no personal email was accessed."
            : "Layout check \(index + 1). "
              + String(repeating: "A longer message tests scrolling with wrapped text. ", count: 5),
          createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        context.insert(message)
        if index == 23 {
          let sources = (0..<100).map { item in
            WebSource(
              title: "Fixture \(item + 1): "
                + String(
                  repeating: "A source with a long descriptive title. ", count: item == 0 ? 8 : 1),
              url: "https://example.com/source/\(item + 1)")
          }
          try ExperienceStore.save(
            ExperienceValue(
              id: ExperienceValue.modelID("web:" + message.id.uuidString), kind: .webSources,
              conversationID: conversation.id, messageID: message.id,
              sources: paused ? [] : sources,
              searchedServices: paused ? [.gmail] : [.gmail, .drive],
              searchNotice: paused
                ? "Gmail: inspected 30 message headers; processed 20 body excerpts. Search paused at the time/context/cost budget. Say ‘continue’ to resume while this chat remains open."
                : nil), in: context)
        }
      }
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: context)
      return conversation.id
    }
  }
#endif

import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@MainActor
@Suite("Provider configuration deletion guard", .serialized)
struct ProviderConfigurationDeletionGuardTests {
  @Test
  func unusedProviderCanBeDeleted() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let providerID = UUID()

    #expect(
      try ProviderConfigurationDeletionGuard.usage(
        configurationID: providerID,
        in: context
      )
        == ProviderConfigurationUsageSummary(
          conversationCount: 0,
          scheduledTaskCount: 0,
          embeddingProfileCount: 0,
          memoryFormationJobCount: 0
        ))
    try ProviderConfigurationDeletionGuard.validateCanDelete(
      configurationID: providerID,
      in: context
    )
  }

  @Test
  func liveReferencesBlockDeletionWithActionableCounts() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let providerID = UUID()
    context.insert(
      ConversationRecord(providerConfigurationID: providerID, modelIdentifier: "chat-model")
    )
    context.insert(
      ScheduledTaskRecord(
        title: "Daily brief",
        prompt: "Summarize",
        providerConfigurationID: providerID,
        scheduledAt: .now
      )
    )
    context.insert(
      ScheduledTaskRecord(
        title: "Weekly brief",
        prompt: "Summarize",
        providerConfigurationID: providerID,
        scheduledAt: .now
      )
    )
    context.insert(
      EmbeddingProfileRecord(
        displayName: "Recall",
        providerConfigurationID: providerID,
        modelIdentifier: "embed-model"
      )
    )
    context.insert(memoryFormationJob(providerID: providerID, status: .pending))

    let expected = ProviderConfigurationUsageSummary(
      conversationCount: 1,
      scheduledTaskCount: 2,
      embeddingProfileCount: 1,
      memoryFormationJobCount: 1
    )
    #expect(
      try ProviderConfigurationDeletionGuard.usage(
        configurationID: providerID,
        in: context
      ) == expected)

    do {
      try ProviderConfigurationDeletionGuard.validateCanDelete(
        configurationID: providerID,
        in: context
      )
      Issue.record("Expected live provider references to block deletion")
    } catch let error as ProviderConfigurationDeletionGuardError {
      #expect(error == .inUse(expected))
      #expect(
        error.localizedDescription
          == "This provider is still used by 1 chat, 2 automations, and 1 embedding profile. Reassign or delete those items before deleting the provider."
      )
    }
  }

  @Test
  func retryableMemoryFormationJobsAreReportedWithoutBlockingDeletion() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let providerID = UUID()
    context.insert(memoryFormationJob(providerID: providerID, status: .pending))
    context.insert(memoryFormationJob(providerID: providerID, status: .generating))
    context.insert(memoryFormationJob(providerID: providerID, status: .failed))
    context.insert(memoryFormationJob(providerID: providerID, status: .complete))
    context.insert(memoryFormationJob(providerID: providerID, status: .rejected))

    let usage = try ProviderConfigurationDeletionGuard.usage(
      configurationID: providerID,
      in: context
    )

    #expect(usage.memoryFormationJobCount == 3)
    #expect(!usage.isInUse)
    try ProviderConfigurationDeletionGuard.validateCanDelete(
      configurationID: providerID,
      in: context
    )
  }

  @Test
  func historicalMessageSnapshotsDoNotBlockDeletion() throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let providerID = UUID()
    context.insert(
      MessageRecord(
        conversationID: UUID(),
        role: .assistant,
        content: "Historical output",
        providerConfigurationID: providerID,
        providerKind: .openAI,
        providerDisplayName: "OpenAI",
        modelIdentifier: "gpt-example"
      )
    )

    #expect(
      try ProviderConfigurationDeletionGuard.usage(
        configurationID: providerID,
        in: context
      ).isInUse == false)
  }

  private func memoryFormationJob(
    providerID: UUID,
    status: MemoryFormationJobStatus
  ) -> MemoryFormationJobRecord {
    MemoryFormationJobRecord(
      jobKey: UUID().uuidString,
      conversationID: UUID(),
      throughUserMessageID: UUID(),
      assistantMessageID: UUID(),
      sourceFingerprint: UUID().uuidString,
      promptVersion: "test-prompt-v1",
      status: status,
      providerConfigurationID: providerID
    )
  }
}

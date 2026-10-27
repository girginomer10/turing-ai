import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite("Mosaic V4 schema migration", .serialized)
@MainActor
struct MosaicSchemaV4MigrationTests {
  @Test("a populated V3 store preserves memory and reopens with project and audit rows")
  func populatedV3MigratesAndReopensWithV4Rows() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Mosaic-V3-to-V4-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("Mosaic.store")
    let date = Date(timeIntervalSince1970: 1_771_000_000)
    let conversationID = UUID()
    let userMessageID = UUID()
    let assistantMessageID = UUID()
    let curatedMemoryID = UUID()
    let topicID = UUID()
    let evidenceID = UUID()
    let revisionID = UUID()
    let jobID = UUID()
    let jobKey = "v3-job-\(UUID().uuidString.lowercased())"
    let sourceFingerprint = String(repeating: "a", count: 64)

    try autoreleasepool {
      let v3Schema = Schema(versionedSchema: MosaicSchemaV3.self)
      let configuration = ModelConfiguration(
        "Mosaic",
        schema: v3Schema,
        url: storeURL,
        cloudKitDatabase: .none
      )
      let container = try ModelContainer(for: v3Schema, configurations: [configuration])
      let context = container.mainContext
      context.insert(
        ConversationRecord(
          id: conversationID,
          title: "V3 conversation",
          modelIdentifier: "v3-model",
          createdAt: date,
          updatedAt: date
        )
      )
      context.insert(
        MessageRecord(
          id: userMessageID,
          conversationID: conversationID,
          role: .user,
          content: "Kalıcı tercihim Türkçe.",
          createdAt: date,
          updatedAt: date
        )
      )
      context.insert(
        MessageRecord(
          id: assistantMessageID,
          conversationID: conversationID,
          role: .assistant,
          content: "Anladım.",
          createdAt: date.addingTimeInterval(1),
          updatedAt: date.addingTimeInterval(1)
        )
      )
      context.insert(
        MemoryRecord(
          id: curatedMemoryID,
          title: "Language",
          content: "The user prefers Turkish.",
          scope: .global,
          isEnabled: true,
          isUserApproved: true,
          createdAt: date,
          updatedAt: date
        )
      )
      context.insert(
        MemoryTopicRecord(
          id: topicID,
          canonicalKey: "global:preference:response_language",
          title: "Response language",
          content: "The user prefers Turkish responses.",
          kind: .preference,
          scope: .global,
          conversationID: nil,
          confidence: 0.95,
          importance: 0.8,
          stability: .stable,
          lastConfirmedAt: date,
          evidenceCount: 1,
          revision: 1,
          createdAt: date,
          updatedAt: date
        )
      )
      context.insert(
        MemoryEvidenceRecord(
          id: evidenceID,
          evidenceKey: "\(topicID.uuidString.lowercased())/v3-evidence",
          topicID: topicID,
          conversationID: conversationID,
          sourceMessageID: userMessageID,
          assistantMessageID: assistantMessageID,
          excerpt: "Kalıcı tercihim Türkçe.",
          sourceFingerprint: sourceFingerprint,
          providerConfigurationID: nil,
          providerKind: .openAI,
          providerDisplayName: "OpenAI",
          modelIdentifier: "v3-model",
          confidence: 0.95,
          createdAt: date
        )
      )
      context.insert(
        MemoryRevisionRecord(
          id: revisionID,
          revisionKey: "\(topicID.uuidString.lowercased())/1",
          topicID: topicID,
          sequence: 1,
          kind: .created,
          previousTitle: nil,
          previousContent: nil,
          title: "Response language",
          content: "The user prefers Turkish responses.",
          sourceEvidenceID: evidenceID,
          createdAt: date
        )
      )
      context.insert(
        MemoryFormationJobRecord(
          id: jobID,
          jobKey: jobKey,
          conversationID: conversationID,
          throughUserMessageID: userMessageID,
          assistantMessageID: assistantMessageID,
          sourceFingerprint: sourceFingerprint,
          promptVersion: AutomaticMemoryExtractionPrompt.version,
          status: .complete,
          attemptCount: 1,
          providerKind: .openAI,
          providerDisplayName: "OpenAI",
          modelIdentifier: "v3-model",
          providerEndpoint: "https://api.openai.com:443/v1",
          outputFingerprint: String(repeating: "b", count: 64),
          startedAt: date,
          completedAt: date.addingTimeInterval(2),
          createdAt: date,
          updatedAt: date.addingTimeInterval(2)
        )
      )
      try context.save()
    }

    let projectID = UUID()
    let auditID = UUID()
    try autoreleasepool {
      let migrated = try MosaicSchema.makeModelContainer(storeURL: storeURL)
      let context = migrated.mainContext
      #expect(
        try context.fetch(FetchDescriptor<ConversationRecord>()).map(\.id)
          == [conversationID]
      )
      #expect(
        Set(try context.fetch(FetchDescriptor<MessageRecord>()).map(\.id))
          == Set([userMessageID, assistantMessageID])
      )
      #expect(try context.fetch(FetchDescriptor<MemoryRecord>()).map(\.id) == [curatedMemoryID])
      #expect(try context.fetch(FetchDescriptor<MemoryTopicRecord>()).map(\.id) == [topicID])
      #expect(try context.fetch(FetchDescriptor<MemoryEvidenceRecord>()).map(\.id) == [evidenceID])
      #expect(try context.fetch(FetchDescriptor<MemoryRevisionRecord>()).map(\.id) == [revisionID])
      #expect(try context.fetch(FetchDescriptor<MemoryFormationJobRecord>()).map(\.id) == [jobID])
      #expect(try context.fetchCount(FetchDescriptor<ProjectRecord>()) == 0)
      #expect(try context.fetchCount(FetchDescriptor<ProjectResourceBindingRecord>()) == 0)
      #expect(try context.fetchCount(FetchDescriptor<MemoryFormationAuditRecord>()) == 0)

      let project = ProjectRecord(
        id: projectID,
        name: "Migrated workspace",
        instructions: "Use the project's terminology.",
        createdAt: date.addingTimeInterval(3),
        updatedAt: date.addingTimeInterval(3)
      )
      context.insert(project)
      _ = try ProjectBindingStore.assign(
        resourceKind: .conversation,
        resourceID: conversationID,
        to: projectID,
        in: context,
        now: date.addingTimeInterval(3)
      )
      let audit = MemoryFormationAuditRecord(
        id: auditID,
        jobID: jobID,
        jobKey: jobKey,
        attemptCount: 1,
        outcome: .complete,
        providerConfigurationID: nil,
        providerKind: .openAI,
        providerDisplayName: "OpenAI",
        modelIdentifier: "v3-model",
        providerEndpoint: "https://api.openai.com:443/v1",
        providerMessageID: "memory-response-id",
        requestStarted: true,
        inputTokenCount: 120,
        outputTokenCount: 30,
        providerRequestCount: 1,
        cumulativeInputTokenCount: 120,
        cumulativeOutputTokenCount: 30,
        didDiscardInvalidTelemetry: false,
        errorDescription: nil,
        startedAt: date,
        finishedAt: date.addingTimeInterval(2),
        createdAt: date.addingTimeInterval(2),
        updatedAt: date.addingTimeInterval(2)
      )
      try MosaicSourceFieldLimits.validateMemoryFormationAudit(audit)
      context.insert(audit)
      try context.save()
    }

    try autoreleasepool {
      let reopened = try MosaicSchema.makeModelContainer(storeURL: storeURL)
      let context = reopened.mainContext
      let project = try #require(context.fetch(FetchDescriptor<ProjectRecord>()).first)
      #expect(project.id == projectID)
      #expect(project.name == "Migrated workspace")
      #expect(
        try ProjectBindingStore.projectID(
          resourceKind: .conversation,
          resourceID: conversationID,
          in: context
        ) == projectID
      )
      let audit = try #require(
        context.fetch(FetchDescriptor<MemoryFormationAuditRecord>()).first
      )
      #expect(audit.id == auditID)
      #expect(audit.jobID == jobID)
      #expect(audit.outcome == .complete)
      #expect(audit.providerRequestCount == 1)
      #expect(audit.cumulativeInputTokenCount == 120)
      #expect(audit.cumulativeOutputTokenCount == 30)

      #expect(
        try context.fetch(FetchDescriptor<ConversationRecord>()).map(\.id)
          == [conversationID]
      )
      #expect(try context.fetch(FetchDescriptor<MemoryRecord>()).map(\.id) == [curatedMemoryID])
      #expect(try context.fetch(FetchDescriptor<MemoryTopicRecord>()).map(\.id) == [topicID])
      #expect(try context.fetch(FetchDescriptor<MemoryEvidenceRecord>()).map(\.id) == [evidenceID])
      #expect(try context.fetch(FetchDescriptor<MemoryRevisionRecord>()).map(\.id) == [revisionID])
      #expect(try context.fetch(FetchDescriptor<MemoryFormationJobRecord>()).map(\.id) == [jobID])
    }
  }
}

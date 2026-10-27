import Foundation
import SwiftData
import Testing

@testable import MosaicCore

@Suite("Mosaic V3 schema migration", .serialized)
@MainActor
struct MosaicSchemaV3MigrationTests {
  @Test("a populated V2 store migrates in place, preserves rows, and reopens with V3 memory")
  func populatedV2MigratesAndReopensWithAutomaticMemoryRows() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Mosaic-V2-to-V3-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("Mosaic.store")
    let conversationID = UUID()
    let messageID = UUID()
    let legacyMemoryID = UUID()
    let progressKey = "v2-progress-\(UUID().uuidString.lowercased())"

    try autoreleasepool {
      let v2Schema = Schema(versionedSchema: MosaicSchemaV2.self)
      let configuration = ModelConfiguration(
        "Mosaic",
        schema: v2Schema,
        url: storeURL,
        cloudKitDatabase: .none
      )
      let container = try ModelContainer(
        for: v2Schema,
        configurations: [configuration]
      )
      let context = container.mainContext
      context.insert(
        ConversationRecord(
          id: conversationID,
          title: "V2 conversation",
          modelIdentifier: "legacy-model"
        )
      )
      context.insert(
        MessageRecord(
          id: messageID,
          conversationID: conversationID,
          role: .user,
          content: "V2 source message"
        )
      )
      context.insert(
        MemoryRecord(
          id: legacyMemoryID,
          title: "Legacy memory",
          content: "This curated memory must survive V3.",
          scope: .global,
          isEnabled: true,
          isUserApproved: true
        )
      )
      context.insert(NormalizedContextBackfillProgressRecord(migrationKey: progressKey))
      try context.save()
    }

    let topicID = UUID()
    try autoreleasepool {
      let migrated = try MosaicSchema.makeModelContainer(storeURL: storeURL)
      let context = migrated.mainContext
      #expect(
        try context.fetch(FetchDescriptor<ConversationRecord>()).map(\.id)
          == [conversationID]
      )
      #expect(try context.fetch(FetchDescriptor<MessageRecord>()).map(\.id) == [messageID])
      #expect(try context.fetch(FetchDescriptor<MemoryRecord>()).map(\.id) == [legacyMemoryID])
      #expect(
        try context.fetch(FetchDescriptor<NormalizedContextBackfillProgressRecord>())
          .map(\.migrationKey) == [progressKey]
      )
      #expect(try context.fetchCount(FetchDescriptor<MemoryTopicRecord>()) == 0)
      #expect(try context.fetchCount(FetchDescriptor<MemoryEvidenceRecord>()) == 0)
      #expect(try context.fetchCount(FetchDescriptor<MemoryRevisionRecord>()) == 0)
      #expect(try context.fetchCount(FetchDescriptor<MemoryFormationJobRecord>()) == 0)

      let date = Date(timeIntervalSince1970: 1_760_000_000)
      context.insert(
        MemoryTopicRecord(
          id: topicID,
          canonicalKey: "global:fact:migration.probe",
          title: "Migration probe",
          content: "V3 automatic memory can be persisted after migration.",
          kind: .fact,
          scope: .global,
          conversationID: nil,
          confidence: 0.9,
          importance: 0.7,
          stability: .stable,
          lastConfirmedAt: date,
          createdAt: date,
          updatedAt: date
        )
      )
      try context.save()
    }

    try autoreleasepool {
      let reopened = try MosaicSchema.makeModelContainer(storeURL: storeURL)
      let context = reopened.mainContext
      let topic = try #require(
        context.fetch(
          FetchDescriptor<MemoryTopicRecord>(
            predicate: #Predicate { $0.id == topicID }
          )
        ).first
      )
      #expect(topic.canonicalKey == "global:fact:migration.probe")
      #expect(topic.content == "V3 automatic memory can be persisted after migration.")
      #expect(
        try context.fetch(FetchDescriptor<ConversationRecord>()).map(\.id)
          == [conversationID]
      )
      #expect(try context.fetch(FetchDescriptor<MessageRecord>()).map(\.id) == [messageID])
      #expect(try context.fetch(FetchDescriptor<MemoryRecord>()).map(\.id) == [legacyMemoryID])
      #expect(
        try context.fetch(FetchDescriptor<NormalizedContextBackfillProgressRecord>())
          .map(\.migrationKey) == [progressKey]
      )
    }
  }
}

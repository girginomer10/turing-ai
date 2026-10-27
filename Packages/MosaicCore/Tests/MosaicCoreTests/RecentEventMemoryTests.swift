import Foundation
import SwiftData
import Testing

@testable import MosaicCore

struct RecentEventMemoryTests {
  @Test func referencesUseBoundedUserContextWithoutContaminatingUnrelatedQuestions() {
    let messages = [
      AIChatMessage(role: .user, content: "Sokakta yavru kediler buldum."),
      AIChatMessage(role: .assistant, content: "An unsupported assumption"),
      AIChatMessage(role: .user, content: "Küçüklere ne alayım?"),
    ]
    let query = MemoryRecallQuery.make(current: "Küçüklere ne alayım?", messages: messages)
    #expect(query.contains("yavru kediler"))
    #expect(!query.contains("unsupported"))
    #expect(
      MemoryRecallQuery.make(current: "Quarterly revenue", messages: messages)
        == "Quarterly revenue")
    #expect(
      MemoryRecallQuery.make(current: "Onlara ne alayım?", messages: []) == "Onlara ne alayım?")
    #expect(
      MemoryRecallQuery.make(
        current: "Onlara ne alayım?",
        messages: [
          AIChatMessage(role: .user, content: String(repeating: "a", count: 10_000))
        ]
      ).count < 1_000)
  }

  @Test func eventsFadeStayRelevantAndCannotFillTheContext() {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    func candidate(age: Double, kind: MemoryTopicKind = .event) -> RetrievalCandidate {
      let id = UUID()
      let date = now.addingTimeInterval(-age * 86_400)
      return RetrievalCandidate(
        id: id, source: .memoryTopic, containerID: id,
        title: "Kittens", content: "Kittens: The user found kittens on the street.",
        memoryConfidence: 0.95, memoryImportance: 0.7,
        memoryKind: kind, memoryLastConfirmedAt: date, createdAt: date)
    }
    let recent = candidate(age: 0)
    let old = candidate(age: 90)
    let retriever = HybridMemoryRetriever(referenceDate: now)
    let result = retriever.retrieve(
      query: "kittens", candidates: [old, recent], semanticScoreSets: [])
    #expect(result.items.map(\.id) == [recent.id, old.id])
    #expect(result.items[0].relevance > result.items[1].relevance)
    #expect(result.systemContent.contains("memory_layer=\"event\""))
    #expect(result.systemContent.contains("not a permanent fact"))
    let many = retriever.retrieve(
      query: "kittens", candidates: (0..<12).map { candidate(age: Double($0)) },
      semanticScoreSets: [])
    #expect(many.items.count == 2)
    #expect(
      retriever.retrieve(
        query: "quarterly revenue projections", candidates: [recent], semanticScoreSets: []
      ).items.isEmpty)
    #expect(RecentEventMemoryPolicy.relevanceWeight(lastConfirmedAt: now, now: now) == 1)
  }

  @Test func aSpecificOldEventIsStillFoundButAFadedWeakMatchIsNot() {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    func event(_ title: String, _ content: String, age: Double) -> RetrievalCandidate {
      let id = UUID()
      let date = now.addingTimeInterval(-age * 86_400)
      return RetrievalCandidate(
        id: id, source: .memoryTopic, containerID: id, title: title, content: content,
        memoryConfidence: 0.9, memoryImportance: 0.7, memoryKind: .event,
        memoryLastConfirmedAt: date, createdAt: date)
    }
    let specific = event(
      "Root canal", "Root canal appointment with Dr. Kaya on the second Tuesday.", age: 200)
    let weak = event("Tooth", "The user's dad mentioned a sore tooth appointment.", age: 2)
    let candidates = [weak, specific]
    let standard = HybridMemoryRetriever(referenceDate: now)
    let legacy = HybridMemoryRetriever(referenceDate: now, eventFade: .legacy)
    let query = "root canal appointment Dr. Kaya"
    #expect(
      standard.retrieve(query: query, candidates: candidates).items.first?.id == specific.id)
    // The shield keeps the exact old event first; without it the 200-day fade buries it.
    let legacyFirst = legacy.retrieve(query: query, candidates: candidates).items.first?.id
    #expect(legacyFirst != specific.id)
    // Outside the top ranks a long-faded event still loses to a fresher, equally good match.
    let a = event("Kittens", "Kittens: the user found kittens on the street.", age: 1)
    let b = event("Kittens", "Kittens: the user found kittens near the bakery.", age: 1)
    let c = event("Kittens", "Kittens: the user found kittens in the garden.", age: 1)
    let old = event("Kittens", "Kittens: the user found kittens at the harbour.", age: 400)
    let wide = HybridMemoryRetriever(
      referenceDate: now, maximumItems: 10, maximumItemsPerContainer: 10)
    let ranked = wide.retrieve(query: "kittens", candidates: [old, a, b, c]).items.map(\.id)
    #expect(ranked.last == old.id || !ranked.contains(old.id))
  }

  @MainActor
  @Test func eventMetadataAndUpdatesRemainVisibleInRecallAndBackup() async throws {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let chat = ConversationRecord()
    context.insert(chat)
    let now = Date.now
    let topic = MemoryTopicRecord(
      canonicalKey: "global:event:found_kittens",
      title: "Found kittens", content: "The user reported finding kittens.", kind: .event,
      scope: .global, conversationID: nil, origin: .manual, confidence: 0.9,
      importance: 0.7, stability: .evolving, lastConfirmedAt: now, createdAt: now, updatedAt: now)
    context.insert(topic)
    try context.save()
    context.insert(
      MemoryRevisionRecord(
        revisionKey: "\(topic.id.uuidString.lowercased())/1",
        topicID: topic.id, sequence: 1, kind: .created, previousTitle: nil, previousContent: nil,
        title: topic.title, content: topic.content, sourceEvidenceID: nil, createdAt: now))
    let originalContent = topic.content
    topic.apply(
      title: topic.title, content: "The user reported that the kittens were rehomed.",
      confidence: 0.95, importance: 0.7, stability: .evolving, status: .active,
      isEnabled: true, evidenceCount: 0, revision: 2, at: now.addingTimeInterval(1))
    try context.save()
    let reader = SemanticRetrievalSourceReader(modelContainer: container)
    let snapshot = try await reader.snapshot(
      excluding: chat.id, maximumCandidatesPerSource: 20, maximumProfiles: 4)
    let candidate = try #require(snapshot.candidates.first { $0.id == topic.id })
    #expect(candidate.memoryKind == .event)
    #expect(candidate.memoryLastConfirmedAt == topic.lastConfirmedAt)
    #expect(candidate.content.contains("rehomed"))
    context.insert(
      MemoryRevisionRecord(
        revisionKey: "\(topic.id.uuidString.lowercased())/2", topicID: topic.id, sequence: 2,
        kind: .userEdited,
        previousTitle: topic.title, previousContent: originalContent, title: topic.title,
        content: topic.content,
        sourceEvidenceID: nil, createdAt: topic.updatedAt))
    try context.save()
    let data = try MosaicPortableBackup.export(from: context)
    let plan = try MosaicPortableBackup.prepareRestore(from: data)
    let restored = try MosaicSchema.makeModelContainer(inMemory: true)
    try MosaicPortableBackup.replaceLiveStore(using: plan, in: restored.mainContext)
    let saved = try #require(restored.mainContext.fetch(FetchDescriptor<MemoryTopicRecord>()).first)
    #expect(saved.kind == .event)
    #expect(saved.content == topic.content)
    #expect(saved.lastConfirmedAt.timeIntervalSince(topic.lastConfirmedAt).magnitude < 0.001)
  }
}

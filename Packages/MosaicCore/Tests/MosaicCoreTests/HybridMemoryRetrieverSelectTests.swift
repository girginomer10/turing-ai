import Foundation
import Testing

@testable import MosaicCore

struct HybridMemoryRetrieverSelectTests {
  private let now = Date(timeIntervalSince1970: 1_780_000_000)

  private func candidate(
    _ text: String, container: UUID = UUID(), kind: MemoryTopicKind? = nil,
    source: RetrievalSourceKind = .memoryTopic, age: Double = 1
  ) -> RetrievalCandidate {
    let date = now.addingTimeInterval(-age * 86_400)
    return RetrievalCandidate(
      id: UUID(), source: source, containerID: container, title: "", content: text,
      memoryKind: kind, memoryLastConfirmedAt: kind == nil ? nil : date, createdAt: date)
  }

  @Test func scoresDecideTheOrderAndUnscoredCandidatesAreNotSelected() {
    let a = candidate("alpha")
    let b = candidate("beta")
    let c = candidate("gamma")
    let retriever = HybridMemoryRetriever(referenceDate: now)
    let result = retriever.select(rankedBy: [a.id: 0.2, b.id: 0.9], from: [a, b, c])
    #expect(result.items.map(\.id) == [b.id, a.id])
    #expect(result.items[0].relevance == 0.9)
    #expect(result.systemContent.contains("beta"))
    #expect(!result.systemContent.contains("gamma"))
  }

  @Test func equalScoresKeepTheCallersFirstStageOrder() {
    let first = candidate("first stage winner", age: 400)
    let second = candidate("newer but ranked lower")
    let retriever = HybridMemoryRetriever(referenceDate: now)
    let result = retriever.select(
      rankedBy: [first.id: 1, second.id: 1], from: [first, second])
    #expect(result.items.map(\.id) == [first.id, second.id])
  }

  @Test func oldEventsAreNotFadedBecauseTheJudgeAlreadySeparatedRelevance() {
    let old = candidate("Root canal appointment", kind: .event, age: 300)
    let recent = candidate("Dad has a sore tooth", kind: .event, age: 1)
    let retriever = HybridMemoryRetriever(referenceDate: now)
    let result = retriever.select(rankedBy: [old.id: 0.97, recent.id: 0.4], from: [recent, old])
    #expect(result.items.first?.id == old.id)
    #expect(result.items.first?.relevance == 0.97)
  }

  @Test func containerAndItemLimitsStillApply() {
    let shared = UUID()
    let same = (0..<4).map {
      candidate("note \($0)", container: shared, source: .conversationMessage)
    }
    let others = (0..<8).map { candidate("other \($0)") }
    var scores: [UUID: Double] = [:]
    for (index, item) in (same + others).enumerated() { scores[item.id] = 1 - Double(index) / 100 }
    let result = HybridMemoryRetriever(referenceDate: now).select(
      rankedBy: scores, from: same + others)
    #expect(result.items.count == 6)
    #expect(result.items.filter { $0.containerID == shared }.count == 2)
  }

  @Test func nothingScoredMeansNothingInjected() {
    let result = HybridMemoryRetriever(referenceDate: now).select(
      rankedBy: [:], from: [candidate("anything")])
    #expect(result.items.isEmpty)
    #expect(result.systemContent.isEmpty)
  }
}

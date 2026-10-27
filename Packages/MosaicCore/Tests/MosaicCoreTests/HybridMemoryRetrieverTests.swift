import Foundation
import Testing

@testable import MosaicCore

struct HybridMemoryRetrieverTests {
  @Test
  func findsRelevantTurkishPastMessageAndRejectsUnrelatedText() {
    let pet = RetrievalCandidate(
      id: UUID(),
      source: .conversationMessage,
      containerID: UUID(),
      title: "Evcil hayvanlar",
      content: "Köpeğimin adı Luna ve tavuklu mamayı seviyor.",
      createdAt: .now.addingTimeInterval(-86_400)
    )
    let unrelated = RetrievalCandidate(
      id: UUID(),
      source: .conversationMessage,
      containerID: UUID(),
      title: "Bütçe",
      content: "Ağustos ayı faturalarını tabloya aktardım.",
      createdAt: .now
    )

    let context = HybridMemoryRetriever().retrieve(
      query: "Luna için hangi mamayı almalıyım?",
      candidates: [unrelated, pet]
    )

    #expect(context.items.first?.id == pet.id)
    #expect(context.systemContent.contains("Köpeğimin adı Luna"))
    #expect(!context.systemContent.contains("Ağustos ayı"))
  }

  @Test
  func semanticRankCanSurfaceAParaphraseAcrossModelSpace() {
    let paraphrase = RetrievalCandidate(
      id: UUID(),
      source: .conversationMessage,
      containerID: UUID(),
      title: "Travel",
      content: "I avoid flying in the early morning.",
      createdAt: .now
    )
    let lexical = RetrievalCandidate(
      id: UUID(),
      source: .conversationMessage,
      containerID: UUID(),
      title: "Work",
      content: "The morning report is ready.",
      createdAt: .now
    )
    let scores = SemanticScoreSet(
      profileName: "Qwen",
      weight: 2,
      scores: [paraphrase.id: 0.91, lexical.id: 0.22]
    )

    let context = HybridMemoryRetriever(minimumLocalRelevance: 0).retrieve(
      query: "Gece uçuşlarını tercih ediyor muyum?",
      candidates: [lexical, paraphrase],
      semanticScoreSets: [scores]
    )

    #expect(context.items.first?.id == paraphrase.id)
    #expect(context.embeddingProfilesUsed == ["Qwen"])
  }

  @Test
  func weakSemanticRanksDoNotInjectUnrelatedContext() {
    let first = candidate(content: "Borsa kapanış verileri", container: UUID())
    let second = candidate(content: "Bahçe sulama programı", container: UUID())
    let scores = SemanticScoreSet(
      profileName: "Unavailable semantic space",
      scores: [first.id: -0.05, second.id: 0.04]
    )

    let context = HybridMemoryRetriever(
      minimumLocalRelevance: 1,
      minimumSemanticSimilarity: 0.20
    ).retrieve(
      query: "Köpeğimin alerjisi neydi?",
      candidates: [first, second],
      semanticScoreSets: [scores]
    )

    #expect(context.items.isEmpty)
    #expect(context.systemContent.isEmpty)
  }

  @Test
  func diversifiesSourcesAndHonorsCharacterBudget() {
    let container = UUID()
    let other = UUID()
    let candidates = [
      candidate(content: "Mosaic hafıza ayarı birinci açıklama", container: container),
      candidate(content: "Mosaic hafıza ayarı ikinci açıklama", container: container),
      candidate(content: "Mosaic hafıza ayarı üçüncü açıklama", container: container),
      candidate(content: "Mosaic hafıza ayarı başka belgeden", container: other),
    ]
    let context = HybridMemoryRetriever(
      maximumItems: 4,
      maximumCharacters: 80,
      maximumItemsPerContainer: 2,
      minimumLocalRelevance: 0
    ).retrieve(query: "Mosaic hafıza ayarı", candidates: candidates)

    #expect(context.items.filter { $0.containerID == container }.count <= 2)
    #expect(context.items.reduce(0) { $0 + $1.content.count } <= 80)
  }

  @Test
  func truncatedExcerptRetainsTheCompleteSourceFingerprint() throws {
    let fullContent = "release anchor " + String(repeating: "very-long-context ", count: 700)
    let source = candidate(content: fullContent, container: UUID())
    let context = HybridMemoryRetriever(
      maximumItems: 1,
      maximumCharacters: 80,
      minimumLocalRelevance: 0
    ).retrieve(query: "release anchor", candidates: [source])

    let item = try #require(context.items.first)
    #expect(item.content.count <= 80)
    #expect(item.content != fullContent)
    #expect(item.sourceFingerprint == EmbeddingVectorCodec.fingerprint(for: fullContent))
  }

  @Test
  func memoryTopicFingerprintSeparatesAmbiguousTitleContentBoundaries() {
    let first = SemanticCandidateFingerprint.topic(title: "a", content: "b: c")
    let second = SemanticCandidateFingerprint.topic(title: "a: b", content: "c")

    #expect(first != second)
  }

  @Test
  func vectorCodecRoundTripsAndRejectsWrongDimension() {
    let vector: [Float] = [0.25, -1.5, 3.75]
    let data = EmbeddingVectorCodec.encode(vector)
    #expect(EmbeddingVectorCodec.decode(data, dimensions: 3) == vector)
    #expect(EmbeddingVectorCodec.decode(data, dimensions: 2) == nil)
    #expect(!EmbeddingVectorCodec.isValidEncoding(byteCount: 0, dimensions: Int.max))
    #expect(
      EmbeddingVectorCodec.fingerprint(for: "same") == EmbeddingVectorCodec.fingerprint(for: "same")
    )
  }

  @Test
  func recalledOCRChunkKeepsInspectableProvenance() throws {
    let candidate = RetrievalCandidate(
      id: UUID(),
      source: .documentChunk,
      containerID: UUID(),
      title: "Scanned contract",
      content: "Payment is due on the fifteenth day.",
      pageNumber: 3,
      isOCRDerived: true,
      createdAt: .now
    )

    let context = HybridMemoryRetriever(minimumLocalRelevance: 0).retrieve(
      query: "When is payment due?",
      candidates: [candidate]
    )

    #expect(context.items.first?.isOCRDerived == true)
    #expect(context.systemContent.contains("page=\"3\""))
    #expect(context.systemContent.contains("extraction=\"ocr\""))

    let encoded = try JSONEncoder().encode(try #require(context.items.first))
    var legacyObject = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    legacyObject.removeValue(forKey: "isOCRDerived")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    let decodedLegacyItem = try JSONDecoder().decode(
      RetrievedContextItem.self,
      from: legacyData
    )
    #expect(decodedLegacyItem.isOCRDerived == nil)
  }

  private func candidate(content: String, container: UUID) -> RetrievalCandidate {
    RetrievalCandidate(
      id: UUID(),
      source: .documentChunk,
      containerID: container,
      title: "Source",
      content: content,
      createdAt: .now
    )
  }
}

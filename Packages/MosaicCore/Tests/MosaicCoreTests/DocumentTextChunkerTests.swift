import Testing

@testable import MosaicCore

struct DocumentTextChunkerTests {
  @Test
  func chunkingIsDeterministicBoundedAndKeepsPageMetadata() {
    let text = Array(repeating: "Türkçe belge içeriği ve önemli bir ayrıntı.", count: 80)
      .joined(separator: " ")
    let chunker = DocumentTextChunker(maximumCharacters: 400, overlapCharacters: 60)

    let first = chunker.chunks(
      from: [(page: 7, text: text)],
      ocrPageNumbers: [7]
    )
    let second = chunker.chunks(
      from: [(page: 7, text: text)],
      ocrPageNumbers: [7]
    )

    #expect(first == second)
    #expect(first.count > 1)
    #expect(first.allSatisfy { $0.content.count <= 400 })
    #expect(first.allSatisfy { $0.pageNumber == 7 })
    #expect(first.allSatisfy { $0.isOCRDerived })
    #expect(first.map(\.index) == Array(first.indices))
  }
}

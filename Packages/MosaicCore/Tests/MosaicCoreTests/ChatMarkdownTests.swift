import Testing

@testable import MosaicCore

@Suite("Chat Markdown blocks")
struct ChatMarkdownTests {
  @Test func headingAndFencedCodeKeepStructureAndWhitespace() {
    let blocks = MosaicMarkdown.parse("# Review\n\n```swift\nlet value = 1\n  print(value)\n```\n")
    #expect(
      blocks == [
        .heading(1, "Review"), .code(language: "swift", text: "let value = 1\n  print(value)\n"),
      ])
  }

  @Test func tablesRemainSeparateCells() {
    let blocks = MosaicMarkdown.parse(
      "| Item | Status |\n| --- | --- |\n| A | **Ready** |\n| B | Waiting |")
    #expect(
      blocks == [
        .table(headers: ["Item", "Status"], rows: [["A", "**Ready**"], ["B", "Waiting"]])
      ])
  }

  @Test func listsQuotesAndInlineEmphasisSurvive() {
    let blocks = MosaicMarkdown.parse(
      "3. **First**\n4. Second\n\n> Quoted [link](https://example.com)\n\n---")
    #expect(
      blocks == [
        .list(
          start: 3, items: [[.paragraph("**First**")], [.paragraph("Second")]], checked: [nil, nil]),
        .quote([.paragraph("Quoted [link](https://example.com)")]), .rule,
      ])
  }

  @Test func incompleteStreamingFenceKeepsCodeReadable() {
    #expect(
      MosaicMarkdown.parse("```swift\nlet value = 1\n") == [
        .code(language: "swift", text: "let value = 1\n")
      ])
  }

  @Test func htmlIsInertLiteralContent() {
    let blocks = MosaicMarkdown.parse("<script>alert('test')</script>")
    guard case .literal(let text) = blocks.first else {
      Issue.record("HTML must stay inert")
      return
    }
    #expect(text.contains("<script>"))
  }
}

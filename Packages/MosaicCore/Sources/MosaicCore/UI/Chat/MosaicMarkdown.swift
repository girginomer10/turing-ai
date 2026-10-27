import Foundation
import Markdown
import SwiftUI

indirect enum MosaicMarkdownBlock: Equatable, Sendable {
  case paragraph(String)
  case heading(Int, String)
  case code(language: String?, text: String)
  case list(start: Int?, items: [[MosaicMarkdownBlock]], checked: [Bool?])
  case quote([MosaicMarkdownBlock])
  case table(headers: [String], rows: [[String]])
  case rule
  case literal(String)
}

enum MosaicMarkdown {
  static func parse(_ source: String) -> [MosaicMarkdownBlock] {
    blocks(in: Document(parsing: source), depth: 0)
  }

  private static func inline(_ markup: any Markup) -> String {
    markup.children.map { $0.detachedFromParent.format() }.joined()
  }

  private static func blocks(in markup: any Markup, depth: Int) -> [MosaicMarkdownBlock] {
    guard depth < 64 else { return [.literal(markup.format())] }
    return markup.children.map { child in
      switch child {
      case let value as Paragraph:
        return .paragraph(inline(value))
      case let value as Heading:
        return .heading(value.level, inline(value))
      case let value as CodeBlock:
        return .code(language: value.language, text: value.code)
      case let value as OrderedList:
        let items = value.children.compactMap { $0 as? ListItem }
        return .list(
          start: Int(clamping: value.startIndex),
          items: items.map { blocks(in: $0, depth: depth + 1) },
          checked: items.map { $0.checkbox.map { $0 == .checked } })
      case let value as UnorderedList:
        let items = value.children.compactMap { $0 as? ListItem }
        return .list(
          start: nil, items: items.map { blocks(in: $0, depth: depth + 1) },
          checked: items.map { $0.checkbox.map { $0 == .checked } })
      case let value as BlockQuote:
        return .quote(blocks(in: value, depth: depth + 1))
      case let value as Markdown.Table:
        return .table(
          headers: value.head.cells.map { inline($0) },
          rows: value.body.rows.map { $0.cells.map { inline($0) } })
      case is ThematicBreak:
        return .rule
      default:
        // HTML/directives remain inert text; rendering a model reply never loads a web view.
        return .literal(child.format())
      }
    }
  }
}

struct MosaicMarkdownView: View {
  let source: String
  @State private var rendered: [MosaicMarkdownBlock]?

  var body: some View {
    MosaicMarkdownBlocksView(blocks: rendered ?? [.literal(source)])
      .textSelection(.enabled)
      .task(id: source) {
        let source = source
        let blocks = await Task.detached(priority: .userInitiated) {
          MosaicMarkdown.parse(source)
        }.value
        guard !Task.isCancelled else { return }
        rendered = blocks
      }
  }
}

private struct MosaicMarkdownBlocksView: View {
  let blocks: [MosaicMarkdownBlock]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(blocks.indices, id: \.self) { index in
        MosaicMarkdownBlockView(block: blocks[index])
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MosaicMarkdownBlockView: View {
  let block: MosaicMarkdownBlock

  var body: some View {
    switch block {
    case .paragraph(let text):
      inline(text).fixedSize(horizontal: false, vertical: true)
    case .heading(let level, let text):
      inline(text)
        .font(level == 1 ? .title : (level == 2 ? .title2 : .headline))
        .fontWeight(.semibold)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    case .code(let language, let text):
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          SwiftUI.Text(language.flatMap { $0.isEmpty ? nil : $0 } ?? "Code")
            .font(.caption.weight(.semibold))
          Spacer()
          Button {
            MosaicClipboard.copy(text)
          } label: {
            Label("Copy code", systemImage: "doc.on.doc")
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .mosaicControlTarget()
        }
        ScrollView(.horizontal) {
          SwiftUI.Text(verbatim: text)
            .font(.system(.body, design: .monospaced))
            .fixedSize(horizontal: true, vertical: true)
            .padding(.bottom, 6)
        }
        .accessibilityLabel("Code block")
      }
      .padding(12)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    case .list(let start, let items, let checked):
      VStack(alignment: .leading, spacing: 8) {
        ForEach(items.indices, id: \.self) { index in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let checked = checked[index] {
              Image(systemName: checked ? "checkmark.square" : "square")
                .accessibilityLabel(checked ? "Checked" : "Unchecked")
            } else {
              SwiftUI.Text(
                start.map { "\($0.addingReportingOverflow(index).partialValue)." } ?? "•"
              )
              .monospacedDigit()
            }
            MosaicMarkdownBlocksView(blocks: items[index])
          }
        }
      }
    case .quote(let children):
      HStack(alignment: .top, spacing: 12) {
        RoundedRectangle(cornerRadius: 2).fill(.secondary).frame(width: 3)
        MosaicMarkdownBlocksView(blocks: children)
      }
      .fixedSize(horizontal: false, vertical: true)
    case .table(let headers, let rows):
      ScrollView(.horizontal) {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
          GridRow {
            ForEach(headers.indices, id: \.self) { index in
              inline(headers[index]).fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
                .frame(minWidth: 100, maxWidth: 260, alignment: .leading)
            }
          }
          Divider().gridCellUnsizedAxes(.horizontal)
          ForEach(rows.indices, id: \.self) { row in
            GridRow {
              ForEach(rows[row].indices, id: \.self) { column in
                inline(rows[row][column])
                  .frame(minWidth: 100, maxWidth: 260, alignment: .leading)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }
        .padding(12)
      }
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    case .rule:
      Divider()
    case .literal(let text):
      SwiftUI.Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func inline(_ text: String) -> SwiftUI.Text {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    return SwiftUI.Text(
      (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
  }
}

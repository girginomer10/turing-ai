import Foundation
import Testing

@testable import MosaicCore

struct SSEParserTests {
  @Test
  func joinsMultilineDataAndResets() {
    var parser = SSEParser()
    #expect(parser.consume(line: "event: update") == nil)
    #expect(parser.consume(line: "data: first") == nil)
    #expect(parser.consume(line: "data: second") == nil)

    let event = parser.consume(line: "")

    #expect(event == ServerSentEvent(name: "update", data: "first\nsecond", id: nil))
    #expect(parser.consume(line: "") == nil)
  }

  @Test
  func ignoresCommentLines() {
    var parser = SSEParser()
    #expect(parser.consume(line: ": keep-alive") == nil)
    #expect(parser.consume(line: "") == nil)
  }

  @Test
  func boundedByteDecoderPreservesSplitUTF8AndCRLF() throws {
    var decoder = BoundedSSEStreamDecoder()
    var events: [ServerSentEvent] = []

    for byte in Data("event: update\r\ndata: Türkçe 🧩\r\n\r\n".utf8) {
      if let event = try decoder.consume(byte: byte) {
        events.append(event)
      }
    }
    events.append(contentsOf: try decoder.finish())

    #expect(
      events == [ServerSentEvent(name: "update", data: "Türkçe 🧩", id: nil)]
    )
  }

  @Test
  func boundedByteDecoderAcceptsStandardCarriageReturnLineEndings() throws {
    var decoder = BoundedSSEStreamDecoder()
    var events: [ServerSentEvent] = []

    for byte in Data("event: update\rdata: first\rdata: second\r\r".utf8) {
      if let event = try decoder.consume(byte: byte) {
        events.append(event)
      }
    }
    events.append(contentsOf: try decoder.finish())

    #expect(
      events == [ServerSentEvent(name: "update", data: "first\nsecond", id: nil)]
    )
  }

  @Test
  func boundedByteDecoderRejectsOversizedLines() throws {
    var decoder = BoundedSSEStreamDecoder()
    for _ in 0..<(256 * 1_024) {
      _ = try decoder.consume(byte: 0x61)
    }

    #expect(throws: ProviderClientError.responseTooLarge) {
      try decoder.consume(byte: 0x61)
    }
  }
}

import Foundation
import Testing

@testable import MosaicCore

struct MosaicSourceFieldLimitsTests {
  @Test
  func acceptsBoundarySizedMessageAndRejectsNextByte() throws {
    try MosaicSourceFieldLimits.validateMessageContent(
      String(
        repeating: "x",
        count: MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes
      )
    )

    #expect(throws: MosaicSourceFieldLimitError.self) {
      try MosaicSourceFieldLimits.validateMessageContent(
        String(
          repeating: "x",
          count: MosaicSourceFieldLimits.maximumMessageContentUTF8Bytes + 1
        )
      )
    }
  }

  @Test
  func countsMemoryLimitsInUTF8Bytes() throws {
    let emoji = "🧠"
    let validTitle = String(
      repeating: emoji,
      count: MosaicSourceFieldLimits.maximumMemoryTitleUTF8Bytes / emoji.utf8.count
    )
    try MosaicSourceFieldLimits.validateMemory(title: validTitle, content: "fact")

    #expect(throws: MosaicSourceFieldLimitError.self) {
      try MosaicSourceFieldLimits.validateMemory(
        title: validTitle + emoji,
        content: "fact"
      )
    }
  }
}

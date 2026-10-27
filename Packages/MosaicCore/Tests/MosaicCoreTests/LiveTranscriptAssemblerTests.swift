import Testing

@testable import MosaicCore

struct LiveTranscriptAssemblerTests {
  @Test
  func interimHypothesesReplaceInsteadOfAccumulate() throws {
    var assembler = LiveTranscriptAssembler()

    _ = try assembler.consume(
      .interimTranscript(text: "Mer", languageCode: "tr-TR")
    )
    let updated = try assembler.consume(
      .interimTranscript(text: "Merhaba dünya", languageCode: "tr-TR")
    )

    #expect(updated.finalizedText.isEmpty)
    #expect(updated.interimText == "Merhaba dünya")
    #expect(updated.displayText == "Merhaba dünya")
    #expect(updated.languageCode == "tr-TR")
  }

  @Test
  func finalSegmentsCommitAndClearSpeculativeText() throws {
    var assembler = LiveTranscriptAssembler()

    _ = try assembler.consume(
      .interimTranscript(text: "Merhaba dü", languageCode: nil)
    )
    let firstFinal = try assembler.consume(
      .finalTranscript(text: " Merhaba dünya ", languageCode: "tr-TR")
    )
    let secondFinal = try assembler.consume(
      .finalTranscript(text: "Bugün nasılsın", languageCode: nil)
    )
    let punctuated = try assembler.consume(
      .finalTranscript(text: "?", languageCode: nil)
    )

    #expect(firstFinal.interimText == nil)
    #expect(secondFinal.finalizedText == "Merhaba dünya Bugün nasılsın")
    #expect(punctuated.finalizedText == "Merhaba dünya Bugün nasılsın?")
    #expect(punctuated.displayText == punctuated.finalizedText)
    #expect(punctuated.languageCode == "tr-TR")
  }

  @Test
  func controlEventsDoNotAccidentallyCommitInterimText() throws {
    var assembler = LiveTranscriptAssembler()
    _ = try assembler.consume(
      .interimTranscript(text: "speculative", languageCode: "en-US")
    )

    #expect(try assembler.consume(.turnComplete).interimText == "speculative")
    #expect(
      try assembler.consume(.goAway(timeLeftSeconds: 5)).interimText == "speculative"
    )
    let ended = try assembler.consume(.ended(reason: .cancelled))

    #expect(ended.finalizedText.isEmpty)
    #expect(ended.interimText == nil)
    #expect(ended.displayText.isEmpty)
  }

  @Test
  func byteLimitFailureLeavesThePreviousSnapshotIntact() throws {
    var assembler = try LiveTranscriptAssembler(maximumTranscriptBytes: 10)
    let initial = try assembler.consume(
      .finalTranscript(text: "12345", languageCode: nil)
    )

    #expect(throws: LiveTranscriptionError.responseTooLarge) {
      try assembler.consume(
        .interimTranscript(text: "67890", languageCode: nil)
      )
    }
    #expect(assembler.snapshot == initial)
  }

  @Test
  func resetClearsAllTranscriptState() throws {
    var assembler = LiveTranscriptAssembler()
    _ = try assembler.consume(
      .finalTranscript(text: "Remember me", languageCode: "en-US")
    )

    assembler.reset()

    #expect(assembler.snapshot.finalizedText.isEmpty)
    #expect(assembler.snapshot.interimText == nil)
    #expect(assembler.snapshot.languageCode == nil)
  }
}

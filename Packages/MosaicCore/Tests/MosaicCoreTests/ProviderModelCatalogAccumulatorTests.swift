import Testing

@testable import MosaicCore

struct ProviderModelCatalogAccumulatorTests {
  @Test
  func acceptsIdentifierAtExactUTF8ByteLimit() throws {
    let identifier = String(repeating: "é", count: 512)
    var accumulator = ProviderModelCatalogAccumulator(
      maximumPageCount: 1,
      maximumModelCount: 1,
      maximumIdentifierByteCount: 1_024,
      maximumTotalIdentifierByteCount: 1_024
    )

    #expect(identifier.utf8.count == 1_024)
    #expect(
      try accumulator.consume(
        ProviderModelCatalogPage(modelIdentifiers: [identifier], nextCursor: nil)
      ) == nil
    )
    #expect(accumulator.modelIdentifiers == [identifier])
  }

  @Test
  func rejectsIdentifierOneUTF8ByteOverLimitWithoutPartialMutation() throws {
    let oversizedIdentifier = String(repeating: "é", count: 512) + "x"
    var accumulator = ProviderModelCatalogAccumulator(
      maximumPageCount: 1,
      maximumModelCount: 1,
      maximumIdentifierByteCount: 1_024,
      maximumTotalIdentifierByteCount: 1_024
    )

    #expect(oversizedIdentifier.utf8.count == 1_025)
    #expect(throws: ProviderClientError.responseTooLarge) {
      try accumulator.consume(
        ProviderModelCatalogPage(
          modelIdentifiers: ["valid-model", oversizedIdentifier],
          nextCursor: nil
        )
      )
    }
    #expect(accumulator.modelIdentifiers.isEmpty)

    #expect(
      try accumulator.consume(
        ProviderModelCatalogPage(modelIdentifiers: ["valid-model"], nextCursor: nil)
      ) == nil
    )
  }

  @Test
  func rejectsControlCharactersWithoutPartialMutation() throws {
    var accumulator = ProviderModelCatalogAccumulator(
      maximumPageCount: 1,
      maximumModelCount: 2
    )

    #expect(throws: ProviderClientError.invalidResponse) {
      try accumulator.consume(
        ProviderModelCatalogPage(
          modelIdentifiers: ["valid-model", "header\nmodel"],
          nextCursor: nil
        )
      )
    }
    #expect(accumulator.modelIdentifiers.isEmpty)
  }

  @Test
  func rejectsEmptyOrWhitespaceOnlyIdentifiersWithoutPartialMutation() {
    for invalidIdentifier in ["", "   ", "\t"] {
      var accumulator = ProviderModelCatalogAccumulator(
        maximumPageCount: 1,
        maximumModelCount: 2
      )

      #expect(throws: ProviderClientError.invalidResponse) {
        try accumulator.consume(
          ProviderModelCatalogPage(
            modelIdentifiers: ["valid-model", invalidIdentifier],
            nextCursor: nil
          )
        )
      }
      #expect(accumulator.modelIdentifiers.isEmpty)
    }
  }

  @Test
  func enforcesExactAggregateUTF8ByteLimitAcrossDeduplicatedPages() throws {
    var accumulator = ProviderModelCatalogAccumulator(
      maximumPageCount: 3,
      maximumModelCount: 4,
      maximumIdentifierByteCount: 8,
      maximumTotalIdentifierByteCount: 8
    )

    #expect(
      try accumulator.consume(
        ProviderModelCatalogPage(modelIdentifiers: ["abc", "dé"], nextCursor: "next")
      ) == "next"
    )
    #expect(
      try accumulator.consume(
        ProviderModelCatalogPage(modelIdentifiers: ["abc", "xy"], nextCursor: "last")
      ) == "last"
    )
    #expect(accumulator.modelIdentifiers == ["abc", "dé", "xy"])

    #expect(throws: ProviderClientError.responseTooLarge) {
      try accumulator.consume(
        ProviderModelCatalogPage(modelIdentifiers: ["z"], nextCursor: nil)
      )
    }
    #expect(accumulator.modelIdentifiers == ["abc", "dé", "xy"])

    #expect(
      try accumulator.consume(
        ProviderModelCatalogPage(modelIdentifiers: ["abc"], nextCursor: nil)
      ) == nil
    )
    #expect(accumulator.modelIdentifiers == ["abc", "dé", "xy"])
  }

  @Test
  func preservesSortedDeduplicationAndPagination() throws {
    var accumulator = ProviderModelCatalogAccumulator(
      maximumPageCount: 3,
      maximumModelCount: 3,
      maximumIdentifierByteCount: 32,
      maximumTotalIdentifierByteCount: 21
    )

    #expect(
      try accumulator.consume(
        ProviderModelCatalogPage(modelIdentifiers: ["model-b", "model-a"], nextCursor: "next")
      ) == "next"
    )
    #expect(
      try accumulator.consume(
        ProviderModelCatalogPage(modelIdentifiers: ["model-c", "model-a"], nextCursor: nil)
      ) == nil
    )
    #expect(accumulator.modelIdentifiers == ["model-a", "model-b", "model-c"])
  }
}

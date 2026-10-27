import Foundation
import SwiftData
import Testing

@testable import MosaicCore

struct ModelPriceCatalogTests {
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  @Test func catalogHasUniqueVerifiedFinitePrices() throws {
    let catalog = try #require(ModelPriceCatalog.catalog)
    let keys = catalog.entries.flatMap { r in r.models.map { r.provider.rawValue + "/" + $0 } }
    #expect(keys.count > 400)
    #expect(Set(keys).count == keys.count)
    #expect(catalog.entries.allSatisfy { $0.source.scheme == "https" })
  }
  @Test func providerAndActualHostMustMatchAndUnknownModelsStayUnknown() throws {
    let now = date("2026-09-05T12:00:00Z")
    let native = try #require(
      ModelPriceCatalog.rate(provider: .openAI, host: "api.openai.com", model: "gpt-4o", now: now))
    #expect(native.input == 2.5 && native.output == 10)
    #expect(
      ModelPriceCatalog.rate(
        provider: .openAI, host: "proxy.example.com", model: "gpt-4o", now: now) == nil)
    #expect(
      ModelPriceCatalog.rate(
        provider: .openRouter, host: "openrouter.ai", model: "gpt-4o", now: now) == nil)
    #expect(ModelPriceCatalog.rate(provider: .openAI, host: nil, model: "gpt-4o", now: now) == nil)
    #expect(
      ModelPriceCatalog.rate(
        provider: .openAI, host: "api.openai.com", model: "gpt-4o-future-custom", now: now) == nil)
    #expect(
      ModelPriceCatalog.rate(
        provider: .openAI, host: "api.openai.com", model: "gpt-4o-2024-05-13", now: now) == nil)
  }
  @Test func longContextBoundaryAndWeekdayTariffsUseEachRequest() throws {
    let now = date("2026-09-05T12:00:00Z")
    let rate = try #require(
      ModelPriceCatalog.rate(
        provider: .google, host: "generativelanguage.googleapis.com", model: "gemini-2.5-pro",
        now: now))
    #expect(rate.estimate(input: 200_000, output: 1000, at: now) == 0.26)
    let long = try #require(rate.estimate(input: 200_001, output: 1000, at: now))
    #expect(abs(long - 0.5150025) < 0.00000001)
    let ds = try #require(
      ModelPriceCatalog.rate(
        provider: .deepSeek, host: "api.deepseek.com", model: "deepseek-v4-flash", now: now))
    #expect(ds.estimate(input: 1_000_000, output: 0, at: date("2026-09-07T01:00:00Z")) == 0.44)
    #expect(ds.estimate(input: 1_000_000, output: 0, at: date("2026-09-07T04:00:00Z")) == 0.22)
    #expect(ds.estimate(input: 1_000_000, output: 0, at: date("2026-09-05T01:00:00Z")) == 0.22)
  }
  @Test func staleAndExpiredPromotionalPricesFailClosed() {
    #expect(
      ModelPriceCatalog.rate(
        provider: .openAI, host: "api.openai.com", model: "gpt-5.6-sol",
        now: date("2026-11-21T00:00:00Z")) == nil)
    #expect(
      ModelPriceCatalog.rate(
        provider: .openAI, host: "api.openai.com", model: "gpt-4o",
        now: date("2026-12-05T00:00:00Z")) == nil)
  }
  @MainActor @Test func reportPricesIndividualRequestsWithoutPromotingMonthlyTotalsToLongContext()
    async throws
  {
    let container = try MosaicSchema.makeModelContainer(inMemory: true)
    let context = container.mainContext
    let chat = ConversationRecord()
    context.insert(chat)
    let day = date("2026-09-05T12:00:00Z")
    for _ in 0..<2 {
      context.insert(
        MessageRecord(
          conversationID: chat.id, role: .assistant, content: "Synthetic answer",
          providerKind: .google, providerDisplayName: "Google",
          providerHost: "generativelanguage.googleapis.com", modelIdentifier: "gemini-2.5-pro",
          inputTokenCount: 150_000, outputTokenCount: 1000, createdAt: day))
    }
    // An identical model name on another host must not inherit Google's list rate.
    context.insert(
      MessageRecord(
        conversationID: chat.id, role: .assistant, content: "Proxy answer", providerKind: .google,
        providerDisplayName: "Google", providerHost: "proxy.example.com",
        modelIdentifier: "gemini-2.5-pro", inputTokenCount: 150_000, outputTokenCount: 1000,
        createdAt: day))
    try context.save()
    let lines = try await UsageReportReader(modelContainer: container).report(
      start: day.addingTimeInterval(-1), end: day.addingTimeInterval(1), pricingDate: day)
    #expect(lines.count == 2)
    let native = try #require(
      lines.first { $0.providerHost == "generativelanguage.googleapis.com" })
    #expect(abs((native.automaticCost ?? -1) - 0.395) < 0.0000001)
    #expect(native.unpricedRequests == 0)
    #expect(lines.first { $0.providerHost == "proxy.example.com" }?.automaticCost == nil)
  }
}

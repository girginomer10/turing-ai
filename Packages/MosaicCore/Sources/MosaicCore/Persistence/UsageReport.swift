import Foundation
import SwiftData
import TuringVoice

struct UsageLine: Identifiable, Sendable {
  var id: String {
    "\(providerID?.uuidString ?? "unknown")/\(providerKind?.rawValue ?? "unknown")/\(providerHost ?? "unknown")/\(model)/\(category)"
  }
  let providerID: UUID?
  let providerName: String
  let model: String
  let category: String
  var providerKind: ProviderKind?
  var providerHost: String?
  var automaticCost: Double?
  var unpricedRequests = 0
  var requests = 0
  var input: Int64 = 0
  var output: Int64 = 0
  var unknown = 0
  var usesAudioRates = false
  var pendingRequests = 0
  var audioSeconds = 0.0
  func cost(inputRate: Double?, outputRate: Double?) -> Double? {
    guard let inputRate, let outputRate, inputRate.isFinite, outputRate.isFinite,
      inputRate >= 0, outputRate >= 0
    else { return nil }
    return (Double(input) * inputRate + Double(output) * outputRate) / 1_000_000
  }
}

@ModelActor
actor UsageReportReader {
  private struct Event: Decodable { let conversationCompaction: Compaction? }
  private struct Compaction: Decodable {
    let attemptID: UUID
    let providerConfigurationID: UUID
    let providerDisplayName: String
    let modelIdentifier: String
    let providerKind: ProviderKind?
    let providerEndpoint: String?
    let inputTokenCount: Int?
    let outputTokenCount: Int?
    let extraRequestCount: Int
    let createdAt: Date
  }
  func report(start: Date, end: Date, pricingDate: Date = .now) throws -> [UsageLine] {
    var lines: [String: UsageLine] = [:]
    func add(
      _ providerID: UUID?, _ providerName: String?, _ model: String?, _ category: String,
      _ input: Int?, _ output: Int?, requests: Int = 1,
      kind: ProviderKind? = nil, host: String? = nil, at date: Date = .now,
      voice: VoiceUsageEntry? = nil
    ) {
      var line = UsageLine(
        providerID: providerID, providerName: providerName ?? "Provider",
        model: model ?? "Unknown model", category: category, providerKind: kind,
        providerHost: host.flatMap(ModelPriceCatalog.normalizedHost))
      line = lines[line.id] ?? line
      line.requests += requests
      line.input += Int64(max(0, min(input ?? 0, 1_000_000_000)))
      line.output += Int64(max(0, min(output ?? 0, 1_000_000_000)))
      let audioUsage = voice.flatMap { $0.category == "Watch chat" ? nil : $0 }
      if let voice, !voice.finished { line.pendingRequests += requests }
      if let audioUsage {
        line.usesAudioRates = true
        line.audioSeconds += audioUsage.tokens.seconds ?? 0
        if let cost = VoiceAudioPrices.estimate(audioUsage, now: pricingDate) {
          line.automaticCost = (line.automaticCost ?? 0) + cost
        } else {
          line.unpricedRequests += requests
          line.unknown += requests
        }
      } else if let input, let output,
        let rate = ModelPriceCatalog.rate(
          provider: kind, host: host, model: line.model, now: pricingDate),
        let cost = rate.estimate(input: input, output: output, at: date)
      {
        line.automaticCost = (line.automaticCost ?? 0) + cost
      } else {
        line.unpricedRequests += requests
        if input == nil || output == nil { line.unknown += requests }
      }
      lines[line.id] = line
    }
    var summaries: [UUID: (Compaction, Int)] = [:]
    try each(
      FetchDescriptor<MessageRecord>(
        predicate: #Predicate {
          $0.roleRawValue == "assistant" && $0.createdAt >= start && $0.createdAt < end
        })
    ) { row in
      // Branch prefix copies intentionally have neither counters nor receipts.
      if row.inputTokenCount != nil || row.outputTokenCount != nil || row.contextReceiptData != nil
      {
        add(
          row.providerConfigurationID, row.providerDisplayName, row.modelIdentifier, "Chat",
          row.inputTokenCount, row.outputTokenCount, kind: row.providerKindSnapshot,
          host: row.providerHost, at: row.createdAt)
      }
      if let data = row.contextReceiptData,
        let event = try? JSONDecoder().decode(Event.self, from: data),
        let summary = event.conversationCompaction, summary.extraRequestCount > 0
      {
        summaries[summary.attemptID] = (summary, -1)
      }
    }
    try each(
      FetchDescriptor<RequestContextEventRecord>(
        predicate: #Predicate { $0.createdAt >= start && $0.createdAt < end })
    ) { row in
      guard let event = try? JSONDecoder().decode(Event.self, from: row.payloadData),
        let summary = event.conversationCompaction, summary.extraRequestCount > 0,
        row.eventSequence >= (summaries[summary.attemptID]?.1 ?? -1)
      else { return }
      summaries[summary.attemptID] = (summary, row.eventSequence)
    }
    for (summary, _) in summaries.values where summary.createdAt >= start && summary.createdAt < end
    {
      add(
        summary.providerConfigurationID, summary.providerDisplayName, summary.modelIdentifier,
        "Summarization", summary.inputTokenCount, summary.outputTokenCount,
        kind: summary.providerKind, host: summary.providerEndpoint, at: summary.createdAt)
    }
    try each(
      FetchDescriptor<MemoryFormationAuditRecord>(
        predicate: #Predicate { $0.finishedAt >= start && $0.finishedAt < end })
    ) { row in
      guard row.providerRequestCount > 0 else { return }
      // Each shipped audit contains cumulative retries, dated at the last attempt. Label this
      // explicitly; it cannot be reconstructed into an exact historic billing timeline.
      if row.providerRequestCount == 1 {
        add(
          row.providerConfigurationID, row.providerDisplayName, row.modelIdentifier,
          "Memory formation", row.inputTokenCount, row.outputTokenCount,
          kind: row.providerKindRawValue.flatMap(ProviderKind.init(rawValue:)),
          host: row.providerEndpoint, at: row.finishedAt)
      } else {
        add(
          nil, "Historical retries", "Unallocated", "Memory formation · cumulative retries",
          row.cumulativeInputTokenCount, row.cumulativeOutputTokenCount,
          requests: row.providerRequestCount)
      }
    }
    let names = Dictionary(
      uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<ProviderConfigurationRecord>())
        .map { ($0.id, $0.displayName) })
    try each(FetchDescriptor<ExperienceRecord>(predicate: #Predicate { $0.category == "usage" })) {
      row in
      let value = try JSONDecoder().decode(ExperienceValue.self, from: row.payload)
      guard let date = value.usageDate, date >= start, date < end else { return }
      add(
        value.providerID, value.providerID.flatMap { names[$0] }, value.model,
        value.usageCategory ?? "Other", value.inputTokens, value.outputTokens,
        kind: value.usageProviderKind, host: value.usageProviderHost, at: date,
        voice: value.watchUsage)
    }
    return lines.values.sorted {
      ($0.category, $0.providerName, $0.model) < ($1.category, $1.providerName, $1.model)
    }
  }
  private func each<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, body: (T) throws -> Void)
    throws
  {
    var descriptor = descriptor
    descriptor.fetchLimit = 64
    descriptor.includePendingChanges = false
    var offset = 0
    while true {
      try Task.checkCancellation()
      descriptor.fetchOffset = offset
      let rows = try modelContext.fetch(descriptor)
      if rows.isEmpty { break }
      for row in rows { try body(row) }
      offset += rows.count
    }
  }
}

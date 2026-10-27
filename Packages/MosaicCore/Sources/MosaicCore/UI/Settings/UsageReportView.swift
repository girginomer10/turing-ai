import SwiftData
import SwiftUI
import TuringVoice

struct UsageReportView: View {
  @AppStorage(InterfacePreferences.advancedControlsKey) private var advancedControls = false
  @Environment(\.modelContext) private var context
  @Query(filter: #Predicate<ExperienceRecord> { $0.category == "model" }) private var prices:
    [ExperienceRecord]
  @State private var coordinator = MosaicOperationCoordinator.shared
  @State private var period = "Month"
  @State private var date = Date.now
  @State private var lines: [UsageLine] = []
  @State private var loading = false
  @State private var error: String?
  @State private var editingRate: UsageLine?
  var body: some View {
    List {
      Section {
        Picker("Period", selection: $period) {
          Text("Daily").tag("Day")
          Text("Monthly").tag("Month")
        }.pickerStyle(.segmented)
        DatePicker("Date", selection: $date, displayedComponents: .date)
      }
      if advancedControls {
        Section {
          NavigationLink("Model price list") { ModelPriceListView() }
          Text(
            "Official list prices are included. Special account rates can be overridden per model."
          )
          .font(.footnote).foregroundStyle(.secondary)
          if ModelPriceCatalog.isOutdated {
            Text(
              "The bundled price list needs an app update. Automatic estimates are paused; custom rates still work."
            )
            .font(.footnote).foregroundStyle(.orange)
          }
        }
      }
      if loading { ProgressView("Reading usage…") }
      if let error { Text(error).foregroundStyle(.red) }
      Section(advancedControls ? "Reported usage" : "Estimated spending") {
        if advancedControls {
          LabeledContent(
            "Input tokens", value: lines.reduce(Int64(0), { $0 + $1.input }).formatted())
          LabeledContent(
            "Output tokens", value: lines.reduce(Int64(0), { $0 + $1.output }).formatted())
        }
        let priced = lines.compactMap { cost($0) }
        if !priced.isEmpty {
          LabeledContent(
            "Estimated subtotal",
            value: priced.reduce(0, +).formatted(
              .currency(code: "USD").precision(.fractionLength(2...4))))
        }
        Text(
          advancedControls
            ? "Estimated from retained usage and published standard paid-tier rates, or your custom rates. Watch voice includes reported audio and cached-token usage or published duration estimates. Discounts, tax and untracked search, embedding or request fees are excluded. Other chat estimates do not adjust for caching. This is not your provider bill. Temporary chats leave no usage history."
            : "An estimate from saved chats and Watch usage, using published or custom prices. Missing usage, taxes and extra service fees are excluded. Temporary chats leave no usage history. Your provider’s bill is the final amount."
        )
        .font(.footnote).foregroundStyle(.secondary)
      }
      if !advancedControls {
        Section("By model") {
          ForEach(lines) { line in
            VStack(alignment: .leading, spacing: 5) {
              Text(line.model).font(.headline)
              Text(line.providerName + " · " + line.category).font(.caption).foregroundStyle(
                .secondary)
              Text(
                cost(line).map {
                  $0.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
                } ?? "Cost unavailable")
              if line.unknown > 0 || line.unpricedRequests > 0 || line.pendingRequests > 0 {
                Text(
                  "Some usage is incomplete or unpriced. The subtotal may be lower than your bill."
                )
                .font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
        if ModelPriceCatalog.isOutdated {
          Text("Update the app to refresh prices. Some estimates are unavailable.").foregroundStyle(
            .secondary)
        }
      }
      if advancedControls {
        ForEach(lines) { line in
          Section(line.category) {
            VStack(alignment: .leading, spacing: 6) {
              Text(line.model).font(.headline)
              Text(line.providerName).font(.subheadline).foregroundStyle(.secondary)
              Text(
                "\(line.requests) requests · \(line.input.formatted()) input · \(line.output.formatted()) output"
              ).font(.caption)
              if line.audioSeconds > 0 {
                Text(
                  "\(line.audioSeconds.formatted(.number.precision(.fractionLength(1)))) seconds · duration-based estimate"
                ).font(.caption).foregroundStyle(.secondary)
              }
              if line.pendingRequests > 0 {
                Text("\(line.pendingRequests) sessions or requests have not reported completion")
                  .font(.caption).foregroundStyle(.secondary)
              }
              if line.usesAudioRates {
                Link(
                  "Official audio rates · verified " + VoiceAudioPrices.verifiedAt,
                  destination: VoiceAudioPrices.source(provider: line.providerKind?.rawValue ?? "")
                )
                .font(.caption)
              }
              if line.unknown > 0 {
                Text("\(line.unknown) requests have incomplete usage reports").font(.caption)
                  .foregroundStyle(.secondary)
              }
              if let cost = cost(line) {
                Text(cost.formatted(.currency(code: "USD").precision(.fractionLength(2...5))))
              }
              if hasCustomRate(line) {
                Text("Custom rates").font(.caption).foregroundStyle(.secondary)
              } else if let rate = rate(line) {
                Link(
                  "Official rates · verified \(ModelPriceCatalog.catalog?.verifiedAt ?? "")",
                  destination: rate.source
                )
                .font(.caption)
              }
              if !hasCustomRate(line), line.unpricedRequests > 0 {
                Text(
                  "\(line.unpricedRequests) requests excluded: price or complete usage unavailable"
                )
                .font(.caption).foregroundStyle(.secondary)
              }
              if cost(line) == nil {
                Text("Cost unavailable").font(.subheadline).foregroundStyle(.secondary)
              }
              if line.providerID != nil && !line.usesAudioRates {
                Button("Model rates") { editingRate = line }.frame(minHeight: 44)
              }
            }
          }
        }
      }
      if lines.isEmpty, !loading {
        Text("No retained usage for this period.").foregroundStyle(.secondary)
      }
      if advancedControls {
        Text(
          "Historical memory retries are cumulative and shown on their last attempt date. Their model allocation is unknown, so they are excluded from the estimated subtotal. Changing rates recalculates the estimate for retained history."
        )
        .font(.footnote).foregroundStyle(.secondary)
      }
    }.navigationTitle(advancedControls ? "Usage & Cost" : "Spending")
      .task(
        id:
          "\(period)-\(date)-\(coordinator.sourceActivityRevision)-\(coordinator.isSourceAccessBlocked)"
      ) {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        await load()
      }
      .refreshable { await load() }
      .sheet(item: $editingRate) { line in
        ModelRateView(line: line, existing: preference(line), official: rate(line))
      }
  }
  private func preference(_ line: UsageLine) -> ExperienceValue? {
    prices.compactMap { try? JSONDecoder().decode(ExperienceValue.self, from: $0.payload) }
      .first { $0.providerID == line.providerID && $0.model == line.model }
  }
  private func cost(_ line: UsageLine) -> Double? {
    let rates = preference(line)
    if hasCustomRate(line) {
      return line.cost(
        inputRate: rates?.inputPricePerMillion, outputRate: rates?.outputPricePerMillion)
    }
    return line.automaticCost
  }
  private func hasCustomRate(_ line: UsageLine) -> Bool {
    guard !line.usesAudioRates else { return false }
    let value = preference(line)
    return value?.inputPricePerMillion != nil || value?.outputPricePerMillion != nil
  }
  private func rate(_ line: UsageLine) -> ModelPriceCatalog.Rate? {
    ModelPriceCatalog.rate(provider: line.providerKind, host: line.providerHost, model: line.model)
  }
  private func load() async {
    guard !MosaicOperationCoordinator.shared.isSourceAccessBlocked else { return }
    loading = true
    defer { loading = false }
    let interval = Calendar.current.dateInterval(of: period == "Day" ? .day : .month, for: date)!
    do {
      let container = context.container
      let reader = await Task.detached { UsageReportReader(modelContainer: container) }.value
      let report = try await reader.report(
        start: interval.start, end: interval.end)
      try Task.checkCancellation()
      lines = report
      error = nil
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }
}

private struct ModelRateView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context
  let line: UsageLine
  let existing: ExperienceValue?
  let official: ModelPriceCatalog.Rate?
  @State private var input = ""
  @State private var output = ""
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        if let official {
          Section("Official standard rates") {
            ModelPriceDetails(rate: official)
            Button("Use official rates") { saveRates(input: nil, output: nil) }
          }
        }
        Section(line.model) {
          TextField("USD per 1M input tokens", text: $input)
          TextField("USD per 1M output tokens", text: $output)
          Text(
            "Enter your account's standard rates. Discounts and non-token fees are not included."
          ).font(.footnote)
        }
        if let error { Text(error).foregroundStyle(.red) }
      }.navigationTitle("Model rates")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
        }
    }.onAppear {
      input = (existing?.inputPricePerMillion ?? official?.input).map { String($0) } ?? ""
      output = (existing?.outputPricePerMillion ?? official?.output).map { String($0) } ?? ""
    }
    #if os(macOS)
      .frame(minWidth: 460, minHeight: 300)
    #endif
  }
  private func save() {
    guard !MosaicOperationCoordinator.shared.isSourceAccessBlocked, line.providerID != nil,
      let inputRate = Double(input.replacingOccurrences(of: ",", with: ".")),
      let outputRate = Double(output.replacingOccurrences(of: ",", with: ".")),
      [inputRate, outputRate].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000 })
    else {
      error = "Enter valid nonnegative USD rates."
      return
    }
    saveRates(input: inputRate, output: outputRate)
  }
  private func saveRates(input inputRate: Double?, output outputRate: Double?) {
    guard !MosaicOperationCoordinator.shared.isSourceAccessBlocked, let id = line.providerID else {
      return
    }
    do {
      var value =
        existing
        ?? ExperienceValue(
          id: ExperienceValue.modelID(ProviderModelRecord.key(providerID: id, model: line.model)),
          kind: .model, providerID: id, model: line.model)
      value.inputPricePerMillion = inputRate
      value.outputPricePerMillion = outputRate
      value.updatedAt = .now
      try ExperienceStore.save(value, in: context)
      try MosaicOperationCoordinator.shared.saveSourceChanges(in: context)
      dismiss()
    } catch {
      context.rollback()
      self.error = error.localizedDescription
    }
  }
}

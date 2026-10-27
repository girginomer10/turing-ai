import SwiftUI

struct ModelPriceListView: View {
  @State private var search = ""
  private struct Item: Identifiable {
    let model: String
    let rate: ModelPriceCatalog.Rate
    var id: String { rate.provider.rawValue + "/" + model }
  }
  private var items: [Item] {
    (ModelPriceCatalog.catalog?.entries ?? []).flatMap { rate in
      rate.models.map { Item(model: $0, rate: rate) }
    }.filter {
      search.isEmpty
        || ($0.model + " " + $0.rate.provider.displayName)
          .localizedCaseInsensitiveContains(search)
    }.sorted { ($0.rate.provider.displayName, $0.model) < ($1.rate.provider.displayName, $1.model) }
  }
  var body: some View {
    List {
      Section {
        Text(
          "USD per million tokens · verified \(ModelPriceCatalog.catalog?.verifiedAt ?? "unavailable")"
        )
        Text(
          "Published standard paid-tier prices. Your account may have free usage or discounts. Unlisted models and custom endpoints stay unpriced. Prices are updated with the app; older history is estimated using this list."
        )
        .font(.footnote).foregroundStyle(.secondary)
      }
      ForEach(items) { item in
        DisclosureGroup {
          ModelPriceDetails(rate: item.rate)
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(item.model).foregroundStyle(.primary)
            Text(item.rate.provider.displayName).font(.caption).foregroundStyle(.secondary)
            Text("Input $\(item.rate.input.formatted()) · Output $\(item.rate.output.formatted())")
              .font(.caption)
          }.padding(.vertical, 4)
        }
      }
    }.navigationTitle("Model prices")
      .searchable(text: $search, prompt: "Model or provider")
  }
}

struct ModelPriceDetails: View {
  let rate: ModelPriceCatalog.Rate
  var body: some View {
    LabeledContent(
      "Input / 1M",
      value: rate.input.formatted(.currency(code: "USD").precision(.fractionLength(2...5))))
    LabeledContent(
      "Output / 1M",
      value: rate.output.formatted(.currency(code: "USD").precision(.fractionLength(2...5))))
    ForEach(rate.tiers ?? [], id: \.fromInput) { tier in
      Text(
        "From \(tier.fromInput.formatted()) input tokens per request: $\(tier.input.formatted()) input / $\(tier.output.formatted()) output per 1M."
      )
      .font(.footnote)
    }
    if let maximum = rate.maximumInput {
      Text(
        "Automatic estimates require no more than \(maximum.formatted()) input tokens per request."
      ).font(.footnote)
    }
    if rate.weekdayPeakMultiplier != nil {
      Text("Weekdays 01:00–04:00 and 06:00–10:00 UTC: double the displayed off-peak rates.").font(
        .footnote)
    }
    Link("Official pricing source", destination: rate.source)
  }
}

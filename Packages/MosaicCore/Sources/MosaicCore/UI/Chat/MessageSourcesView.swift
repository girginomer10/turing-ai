import SwiftUI

/// A value snapshot isolates the presented panel from live SwiftData/scroll-layout updates.
struct MessageSourcesSnapshot: Identifiable, Equatable {
  let id: UUID
  let sources: [WebSource]
  let services: [GoogleService]
  let searchNotice: String?
  let actions: [ConnectionActionReceipt]

  init(
    id: UUID, sources: [WebSource], services: [GoogleService] = [], searchNotice: String? = nil,
    actions: [ConnectionActionReceipt] = []
  ) {
    self.actions = actions
    self.searchNotice = searchNotice
    self.id = id
    self.sources = Array(sources.filter(\.isValid).prefix(100))
    self.services = GoogleService.allCases.filter { services.contains($0) }
  }

  var title: String {
    if sources.isEmpty, !actions.isEmpty { return "Connection activity" }
    if sources.isEmpty { return searchNotice == nil ? "No matching sources" : "Search details" }
    return sources.count == 1 ? "1 source" : "\(sources.count) sources"
  }
  var serviceTitle: String { services.map(\.title).joined(separator: " + ") }
}

struct MessageSearchActivityView: View {
  let progress: GoogleSearchProgress
  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small).accessibilityHidden(true)
      Text(progress.title).font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(minHeight: 44, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("message-search-activity")
  }
}

struct MessageSourcesButton: View {
  let snapshot: MessageSourcesSnapshot
  let open: () -> Void
  var body: some View {
    Button(action: open) {
      HStack(spacing: 7) {
        Image(
          systemName: snapshot.services.count == 1
            ? snapshot.services[0].symbol : "doc.text.magnifyingglass"
        )
        .accessibilityHidden(true)
        Text(
          snapshot.services.count != 1
            ? snapshot.title : "\(snapshot.serviceTitle) · \(snapshot.title)"
        )
        .multilineTextAlignment(.leading).lineLimit(nil).fixedSize(
          horizontal: false, vertical: true)
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(
          true)
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .frame(minHeight: 44)
      .background(.quaternary.opacity(0.5), in: Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Sources, \(snapshot.title)")
    .accessibilityHint("Opens the sources used for this response")
    .accessibilityIdentifier("message-sources")
  }
}

struct MessageSourcesView: View {
  @Environment(\.dismiss) private var dismiss
  let snapshot: MessageSourcesSnapshot
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if !snapshot.serviceTitle.isEmpty {
            Label("\(snapshot.serviceTitle) search", systemImage: "magnifyingglass")
              .font(.subheadline).foregroundStyle(.secondary)
          }
          if let notice = snapshot.searchNotice {
            Text(notice).font(.footnote).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          if !snapshot.actions.isEmpty {
            ForEach(snapshot.actions) { action in
              DisclosureGroup {
                Text(action.summary).font(.footnote).foregroundStyle(.secondary)
                ForEach((action.arguments.object ?? [:]).keys.sorted(), id: \.self) { key in
                  VStack(alignment: .leading, spacing: 4) {
                    Text(key).font(.caption).foregroundStyle(.secondary)
                    Text(action.arguments[key].string ?? action.arguments[key].encoded)
                      .textSelection(.enabled)
                  }.padding(.vertical, 4)
                }
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(
                    action.service.title + " · "
                      + action.tool.replacingOccurrences(of: "_", with: " "))
                  Text(action.statusTitle).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          }
          if snapshot.sources.isEmpty && snapshot.actions.isEmpty {
            ContentUnavailableView(
              snapshot.title, systemImage: "magnifyingglass",
              description: Text(
                snapshot.searchNotice == nil
                  ? "The search completed without a matching email or file."
                  : "No source links are available. See the search coverage above."))
          } else if !snapshot.sources.isEmpty {
            Text("Sources used for this response. Open a source to view the original.")
              .font(.subheadline).foregroundStyle(.secondary)
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(snapshot.sources.enumerated()), id: \.offset) { index, source in
                if let url = URL(string: source.url) {
                  Link(destination: url) {
                    HStack(alignment: .top, spacing: 12) {
                      Text("\(index + 1)").font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary).frame(minWidth: 18).padding(.top, 3)
                      VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: source.title).font(.body.weight(.medium)).foregroundStyle(
                          .primary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        Text(url.host ?? "Source").font(.caption).foregroundStyle(.secondary)
                      }.frame(maxWidth: .infinity, alignment: .leading)
                      Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                  }.buttonStyle(.plain)
                  if index < snapshot.sources.count - 1 { Divider() }
                }
              }
            }
          }
        }.padding(20).frame(maxWidth: 700, alignment: .leading).frame(maxWidth: .infinity)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Sources list")
      .accessibilityIdentifier("message-sources-list")
      .navigationTitle("Sources")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    .modifier(NativeSourceLinks())
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    #if os(macOS)
      .frame(minWidth: 400, idealWidth: 520, minHeight: 360)
    #endif
  }
}

/// Prefer the app associated with an original source link, then the system web handler.
/// mailto: is deliberately not used: it composes a new message rather than opening the source.
struct NativeSourceLinks: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
      content.environment(
        \.openURL,
        OpenURLAction { url in
          guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            return .systemAction
          }
          Task { @MainActor in
            let opened = await UIApplication.shared.open(url, options: [.universalLinksOnly: true])
            if !opened { await UIApplication.shared.open(url) }
          }
          return .handled
        })
    #else
      content
    #endif
  }
}

import SwiftUI

public struct TuringBrandMark: View {
  private let size: CGFloat

  public init(size: CGFloat = 36) {
    self.size = size
  }

  public var body: some View {
    Image("TuringBrand", bundle: .module)
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
      .accessibilityHidden(true)
  }
}

struct ProviderPill: View {
  let provider: ProviderKind
  let model: String

  var body: some View {
    HStack(spacing: 6) {
      ProviderLogoTile(provider: provider, size: 22)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(model.isEmpty ? "Choose Model" : model)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(provider.displayName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .lineLimit(1)
    .font(.caption.weight(.medium))
    .foregroundStyle(Color.primary)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(provider.displayName), model \(model)")
  }
}

struct MosaicEmptyState<Actions: View>: View {
  let symbol: String
  let title: String
  let message: String
  @ViewBuilder let actions: Actions

  init(
    symbol: String,
    title: String,
    message: String,
    @ViewBuilder actions: () -> Actions
  ) {
    self.symbol = symbol
    self.title = title
    self.message = message
    self.actions = actions()
  }

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: symbol)
    } description: {
      Text(message)
    } actions: {
      actions
    }
  }
}

extension View {
  @ViewBuilder
  func mosaicCard() -> some View {
    padding(16)
      .background(
        Color.secondary.opacity(0.07),
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
      }
  }

  @ViewBuilder
  func mosaicControlTarget() -> some View {
    #if os(iOS)
      frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    #else
      frame(minWidth: 28, minHeight: 28)
    #endif
  }
}

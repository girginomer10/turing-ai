import SwiftUI

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

/// A consistent, accessible identity treatment for an AI provider.
///
/// Provider marks can be added to either app target's asset catalog using the
/// names exposed by ``ProviderKind/logoAssetName``. Until a mark is available,
/// Mosaic uses an SF Symbol fallback without changing layout or accessibility.
public struct ProviderIdentityView: View {
  private let provider: ProviderKind
  private let title: String
  private let subtitle: String?
  private let logoSize: CGFloat

  public init(
    provider: ProviderKind,
    title: String? = nil,
    subtitle: String? = nil,
    logoSize: CGFloat = 40
  ) {
    self.provider = provider
    self.title = title ?? provider.displayName
    self.subtitle = subtitle
    self.logoSize = logoSize
  }

  public var body: some View {
    HStack(alignment: .center, spacing: max(10, logoSize * 0.28)) {
      ProviderLogoTile(provider: provider, size: logoSize)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(logoSize >= 48 ? .headline : .body.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(2)

        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    guard let subtitle, !subtitle.isEmpty else { return title }
    return "\(title), \(subtitle)"
  }
}

/// A fixed-footprint provider mark that supports real assets and a built-in fallback.
public struct ProviderLogoTile: View {
  @Environment(\.displayScale) private var displayScale
  private let provider: ProviderKind
  private let size: CGFloat

  public init(provider: ProviderKind, size: CGFloat = 40) {
    self.provider = provider
    self.size = size
  }

  public var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        .fill(usesOriginalColorPlate ? Color.white : provider.identityTint.opacity(0.13))

      RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        .stroke(
          usesOriginalColorPlate ? Color.gray.opacity(0.20) : provider.identityTint.opacity(0.24),
          lineWidth: 0.75)

      artwork
        .frame(width: size * artworkScale, height: size * artworkScale)
    }
    .frame(width: size, height: size)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(provider.displayName)
  }

  @ViewBuilder
  private var artwork: some View {
    if let image = platformImage(named: provider.logoAssetName) {
      image
        .resizable()
        .renderingMode(.original)
        .scaledToFit()
    } else {
      Image(systemName: provider.symbolName)
        .font(.system(size: size * 0.42, weight: .semibold))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(provider.identityTint)
    }
  }

  private var artworkScale: CGFloat {
    switch provider {
    case .openRouter: 0.62
    case .tinfoil: 0.80
    case .custom: 0.54
    default: 0.76
    }
  }

  // Original multicolor/site icons have fixed colors. A neutral light plate
  // keeps those marks legible in either app theme without recoloring them.
  private var usesOriginalColorPlate: Bool {
    provider != .custom && provider != .openRouter && provider != .tinfoil
  }

  private func platformImage(named name: String) -> Image? {
    // The published 32 px minimum applies to rendered pixels, not points.
    // Compact Retina controls can therefore use the official mark too.
    if provider == .tinfoil, size * artworkScale * displayScale < 32 { return nil }

    #if os(iOS)
      guard let image = UIImage(named: name) else { return nil }
      return Image(uiImage: image)
    #elseif os(macOS)
      guard let image = NSImage(named: NSImage.Name(name)) else { return nil }
      return Image(nsImage: image)
    #else
      return nil
    #endif
  }
}

extension ProviderKind {
  var identityTint: Color {
    switch visualTone {
    case .primary: .primary
    case .accent: .accentColor
    case .red: Color(red: 0.84, green: 0.20, blue: 0.22)
    case .orange: Color(red: 0.93, green: 0.43, blue: 0.12)
    case .yellow: Color(red: 0.82, green: 0.62, blue: 0.04)
    case .green: Color(red: 0.17, green: 0.58, blue: 0.29)
    case .teal: Color(red: 0.00, green: 0.45, blue: 0.43)
    case .blue: Color(red: 0.16, green: 0.43, blue: 0.86)
    case .indigo: Color(red: 0.31, green: 0.34, blue: 0.78)
    case .purple: Color(red: 0.50, green: 0.35, blue: 0.85)
    case .pink: Color(red: 0.83, green: 0.25, blue: 0.53)
    case .brown: Color(red: 0.68, green: 0.35, blue: 0.20)
    }
  }
}

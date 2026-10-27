import SwiftUI

@MainActor
public struct MosaicSettingsView: View {
  public init() {}

  public var body: some View {
    NavigationStack {
      Form {
        InterfaceModeSection()
        NavigationLink("AI models & accounts") { ProviderLibraryView() }
        NavigationLink("Connections") { ConnectionsView() }
      }
      .formStyle(.grouped)
      .navigationTitle("Settings")
    }
    .mosaicSettingsFrame()
  }
}

extension View {
  @ViewBuilder
  fileprivate func mosaicSettingsFrame() -> some View {
    #if os(macOS)
      frame(minWidth: 580, idealWidth: 660, minHeight: 520, idealHeight: 680)
    #else
      self
    #endif
  }
}

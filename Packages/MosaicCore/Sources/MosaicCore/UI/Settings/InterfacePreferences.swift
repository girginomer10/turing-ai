import SwiftUI

/// Presentation only: changing this preference never changes connections, permissions or data.
enum InterfacePreferences {
  static let advancedControlsKey = "turing.interface.advancedControls"
}

struct InterfaceModeSection: View {
  @AppStorage(InterfacePreferences.advancedControlsKey) private var advanced = false

  var body: some View {
    Section {
      Toggle("Show advanced controls", isOn: $advanced)
        .accessibilityIdentifier("interface.advancedControls")
    } header: {
      Text("Appearance & controls")
    } footer: {
      Text(
        "Simple view keeps everyday features easy to find. Advanced controls add custom connections, model limits and detailed usage. Switching views keeps your chats, memory, permissions and saved settings unchanged. This choice applies to this device."
      )
    }
  }
}

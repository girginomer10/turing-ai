import Foundation
import MosaicCore
import SwiftData
import SwiftUI

@main
struct MosaicMacApp: App {
  private let usesInMemoryStore: Bool
  @State private var storeLaunch: MosaicStoreLaunch

  init() {
    LocalNotificationService.installForegroundPresentationDelegate()
    let arguments = ProcessInfo.processInfo.arguments
    let usesInMemoryStore = arguments.contains("--in-memory")
    self.usesInMemoryStore = usesInMemoryStore
    #if DEBUG
      let initialLaunch: MosaicStoreLaunch =
        arguments.contains("--simulate-store-failure")
        ? .recovery(MosaicStoreFailure(diagnosticCode: "Simulated store-open failure"))
        : MosaicModelContainer.open(inMemory: usesInMemoryStore)
      _storeLaunch = State(initialValue: initialLaunch)
    #else
      _storeLaunch = State(
        initialValue: MosaicModelContainer.open(inMemory: usesInMemoryStore)
      )
    #endif
  }

  var body: some Scene {
    WindowGroup {
      appContent
    }
    .defaultSize(width: 1_180, height: 760)
    .commands {
      MosaicCommands(isEnabled: storeLaunch.isReady)
    }

    Settings {
      settingsContent
    }
  }

  @ViewBuilder
  private var appContent: some View {
    switch storeLaunch {
    case .ready(let modelContainer):
      MosaicRootView()
        .modelContainer(modelContainer)
    case .recovery(let failure):
      recoveryView(failure)
    }
  }

  @ViewBuilder
  private var settingsContent: some View {
    switch storeLaunch {
    case .ready(let modelContainer):
      MosaicSettingsView()
        .modelContainer(modelContainer)
    case .recovery(let failure):
      recoveryView(failure)
        .frame(minWidth: 580, minHeight: 520)
    }
  }

  private func recoveryView(_ failure: MosaicStoreFailure) -> some View {
    MosaicStoreRecoveryView(
      failure: failure,
      retry: {
        storeLaunch = MosaicModelContainer.open(inMemory: usesInMemoryStore)
      },
      restoreBackup: { url in
        _ = try await MosaicLaunchRecovery.restorePortableBackup(
          at: url,
          inMemory: usesInMemoryStore,
          afterActivation: { container in
            try? await SemanticIndexStore.clearAllAsync()
            MosaicOperationCoordinator.shared.markSourceStoreReplaced()
            storeLaunch = .ready(container)
          }
        )
      }
    )
  }
}

private struct MosaicCommands: Commands {
  let isEnabled: Bool

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Chat") {
        NotificationCenter.default.post(name: .mosaicNewChat, object: nil)
      }
      .keyboardShortcut("n")
      .disabled(!isEnabled)
    }
  }
}

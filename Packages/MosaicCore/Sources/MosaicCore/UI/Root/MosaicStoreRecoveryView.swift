import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  fileprivate static let mosaicLaunchRecoveryBackup = UTType(
    exportedAs: MosaicPortableBackup.formatIdentifier,
    conformingTo: .data
  )
}

/// A SwiftData-independent launch surface. It is safe to render when the main model container
/// could not be created.
@MainActor
public struct MosaicStoreRecoveryView: View {
  private let failure: MosaicStoreFailure
  private let retry: () -> Void
  private let restoreBackup: (URL) async throws -> Void

  @State private var showImporter = false
  @State private var isRestoring = false
  @State private var restoreTask: Task<Void, Never>?
  @State private var restoreErrorMessage: String?
  @State private var launchRecoveryCoordinator = MosaicLaunchRecoveryCoordinator.shared

  public init(
    failure: MosaicStoreFailure,
    retry: @escaping () -> Void,
    restoreBackup: @escaping (URL) async throws -> Void
  ) {
    self.failure = failure
    self.retry = retry
    self.restoreBackup = restoreBackup
  }

  public var body: some View {
    ViewThatFits(in: .vertical) {
      recoveryContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      ScrollView {
        recoveryContent
          .frame(maxWidth: .infinity)
      }
    }
    .fileImporter(
      isPresented: $showImporter,
      allowedContentTypes: [.mosaicLaunchRecoveryBackup],
      allowsMultipleSelection: false,
      onCompletion: importBackup
    )
    .alert("Restore failed", isPresented: restoreErrorIsPresented) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(restoreErrorMessage ?? "Please choose a valid Turing AI backup and try again.")
    }
    .onDisappear {
      restoreTask?.cancel()
    }
  }

  private var recoveryContent: some View {
    VStack(spacing: 22) {
      TuringBrandMark(size: 52)

      VStack(spacing: 8) {
        Text("Turing AI couldn’t open your local data")
          .font(.title2.bold())
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)

        Text(
          "Your existing conversations and settings were not deleted or replaced. Check that this device has free storage, then try again."
        )
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      }

      VStack(spacing: 12) {
        Button(action: { showImporter = true }) {
          if restoreIsInProgress {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text("Restoring Backup…")
            }
          } else {
            Label("Restore from Backup", systemImage: "externaldrive.badge.plus")
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(restoreIsInProgress)
        .mosaicControlTarget()

        Button("Try Again", systemImage: "arrow.clockwise") {
          guard !launchRecoveryCoordinator.isRestoring else { return }
          retry()
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(restoreIsInProgress)
        .mosaicControlTarget()

        Text(
          "A backup is restored into a new local library. The library that failed to open stays untouched."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 420)
      }

      DisclosureGroup("Technical details") {
        Text(failure.diagnosticCode)
          .fontDesign(.monospaced)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: 420)
      .mosaicControlTarget()
    }
    .frame(maxWidth: 520)
    .padding(32)
  }

  private func importBackup(_ result: Result<[URL], Error>) {
    guard !launchRecoveryCoordinator.isRestoring else {
      restoreErrorMessage = MosaicLaunchRecoveryError.restoreAlreadyInProgress.localizedDescription
      return
    }
    switch result {
    case .success(let urls):
      guard let url = urls.first else {
        restoreErrorMessage = "No backup file was selected."
        return
      }
      restoreTask?.cancel()
      isRestoring = true
      restoreErrorMessage = nil
      restoreTask = Task { @MainActor in
        defer {
          isRestoring = false
          restoreTask = nil
        }
        do {
          try await restoreBackup(url)
        } catch is CancellationError {
          return
        } catch {
          restoreErrorMessage = error.localizedDescription
        }
      }
    case .failure(let error):
      restoreErrorMessage = error.localizedDescription
    }
  }

  private var restoreErrorIsPresented: Binding<Bool> {
    Binding(
      get: { restoreErrorMessage != nil },
      set: { if !$0 { restoreErrorMessage = nil } }
    )
  }

  private var restoreIsInProgress: Bool {
    isRestoring || launchRecoveryCoordinator.isRestoring
  }
}

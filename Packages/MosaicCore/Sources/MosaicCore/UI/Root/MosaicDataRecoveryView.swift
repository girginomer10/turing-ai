import Accessibility
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  fileprivate static let mosaicPortableBackup = UTType(
    exportedAs: "com.omergirgin.mosaic.backup",
    conformingTo: .data
  )
}

private struct MosaicBackupDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.mosaicPortableBackup] }

  let data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

private actor MosaicBackupFileReader {
  static let shared = MosaicBackupFileReader()

  func read(_ url: URL) throws -> Data {
    try Task.checkCancellation()
    let maximumBytes = MosaicPortableBackupLimits.default.maximumTotalBytes
    let hasScopedAccess = url.startAccessingSecurityScopedResource()
    defer {
      if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
    }
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    if let fileSize = values.fileSize, fileSize > maximumBytes {
      throw MosaicPortableBackupError.backupTooLarge(
        actual: fileSize,
        maximum: maximumBytes
      )
    }
    guard values.isRegularFile != false else {
      throw CocoaError(.fileReadCorruptFile)
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = Data()
    data.reserveCapacity(min(values.fileSize ?? 0, maximumBytes))
    while true {
      try Task.checkCancellation()
      let remaining = maximumBytes - data.count
      let chunk = try handle.read(upToCount: min(1_048_576, remaining + 1)) ?? Data()
      guard !chunk.isEmpty else { break }
      guard chunk.count <= remaining else {
        throw MosaicPortableBackupError.backupTooLarge(
          actual: data.count + chunk.count,
          maximum: maximumBytes
        )
      }
      data.append(chunk)
    }
    return data
  }
}

private struct PendingMosaicRestore: Identifiable {
  let plan: MosaicPortableRestorePlan
  var id: UUID { plan.backupID }
}

@MainActor
struct MosaicDataRecoveryView: View {
  @Environment(\.modelContext) private var modelContext

  @State private var operationCoordinator = MosaicOperationCoordinator.shared
  @State private var isPreparingExport = false
  @State private var isPreparingRestore = false
  @State private var isCancellingPreparation = false
  @State private var isApplyingRestore = false
  @State private var preparationTask: Task<Void, Never>?
  @State private var showExporter = false
  @State private var showImporter = false
  @State private var exportDocument: MosaicBackupDocument?
  @State private var exportFilename = "Turing AI Backup"
  @State private var pendingRestore: PendingMosaicRestore?
  @State private var showFinalRestoreConfirmation = false
  @State private var statusMessage: String?
  @State private var errorMessage: String?
  @State private var restoreErrorMessage: String?

  var body: some View {
    Form {
      Section("Portable backup") {
        LabeledContent {
          Image(systemName: "externaldrive.badge.checkmark")
            .font(.title2)
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
        } label: {
          Text("Your Turing AI library")
            .font(.headline)
          Text(
            "Conversations, memories, imported document text, provider settings, context receipts, and automation definitions."
          )
          .font(.subheadline)
          .foregroundStyle(Color.primary)
        }

        Button {
          prepareExport()
        } label: {
          Label("Create Backup", systemImage: "square.and.arrow.up")
        }
        .disabled(isBusy || hasActiveProviderWork || operationCoordinator.isSourceStoreUnavailable)

        Text("API keys and the rebuildable semantic vector cache are never included.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      if operationCoordinator.isSourceStoreUnavailable {
        Section("Recovery required") {
          Label(
            "Turing AI could not verify a complete local library generation. Normal chats and edits are blocked.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.red)
          Text(
            "Choose a valid backup below to retry recovery. This protection remains active after relaunch and clears only after Turing AI verifies a complete replacement."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }

      Section("Restore") {
        Button {
          showImporter = true
        } label: {
          Label("Choose Backup to Restore", systemImage: "square.and.arrow.down")
        }
        .disabled(isBusy || hasActiveProviderWork)

        Text(
          "Turing AI verifies the file checksum and imports it into an isolated staging database before offering to replace this library."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      if isBusy {
        Section {
          HStack(spacing: 12) {
            HStack(spacing: 12) {
              ProgressView()
              Text(progressLabel)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if isPreparingExport || isPreparingRestore {
              Button("Cancel", role: .cancel) {
                cancelPreparation()
              }
              .disabled(isCancellingPreparation)
            }
          }
        }
      }

      if hasActiveProviderWork {
        Section {
          Label(
            "Finish or stop active requests and data operations before creating or restoring a backup.",
            systemImage: "hourglass"
          )
          .foregroundStyle(.secondary)
        }
      }

      if let statusMessage {
        Section("Last result") {
          Label(statusMessage, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.secondary)
        }
      }

      Section("Recovery behavior") {
        Label("Imported provider connections receive new local identities.", systemImage: "key")
        Label("Restored providers stay disabled until you review them.", systemImage: "power")
        Label("Provider keys must be entered again in Keychain.", systemImage: "lock")
        Label(
          "Imported automations stay paused until you review them.", systemImage: "pause.circle")
        Label(
          "Search vectors rebuild from source data when needed.", systemImage: "arrow.clockwise")
      }
      .font(.subheadline)
    }
    .formStyle(.grouped)
    .navigationTitle("Data & Recovery")
    .fileExporter(
      isPresented: $showExporter,
      document: exportDocument,
      contentTypes: [.mosaicPortableBackup],
      defaultFilename: exportFilename
    ) { result in
      exportDocument = nil
      switch result {
      case .success:
        reportResult("Portable backup saved.")
      case .failure(let error):
        errorMessage = error.localizedDescription
      }
    } onCancellation: {
      exportDocument = nil
    }
    .fileImporter(
      isPresented: $showImporter,
      allowedContentTypes: [.mosaicPortableBackup],
      allowsMultipleSelection: false,
      onCompletion: importBackup
    )
    .sheet(item: $pendingRestore) { pending in
      restoreConfirmation(for: pending)
    }
    .alert("Data operation failed", isPresented: errorIsPresented) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "Please try again.")
    }
    .onDisappear {
      preparationTask?.cancel()
    }
  }

  private var isBusy: Bool {
    isPreparingExport || isPreparingRestore || isApplyingRestore
  }

  private var hasActiveProviderWork: Bool {
    !operationCoordinator.activeOperations.isEmpty
  }

  private var progressLabel: String {
    if isCancellingPreparation { return "Stopping preparation…" }
    if isPreparingExport { return "Preparing and verifying backup…" }
    if isPreparingRestore { return "Validating in an isolated database…" }
    return "Replacing the local library…"
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  @ViewBuilder
  private func restoreConfirmation(for pending: PendingMosaicRestore) -> some View {
    let snapshot = pending.plan.snapshot
    NavigationStack {
      Form {
        Section("Verified backup") {
          LabeledContent("Created") {
            Text(snapshot.createdAt, format: .dateTime.year().month().day().hour().minute())
          }
          LabeledContent("Conversations", value: snapshot.conversations.count.formatted())
          LabeledContent("Messages", value: snapshot.messages.count.formatted())
          LabeledContent("Pinned memories", value: snapshot.memories.count.formatted())
          LabeledContent(
            "Learned topics",
            value: AutomaticMemoryPortableArchive.topicCount(in: snapshot.extensionRecords)
              .formatted()
          )
          LabeledContent("Documents", value: snapshot.importedDocuments.count.formatted())
          LabeledContent("Providers", value: snapshot.providerConfigurations.count.formatted())
          LabeledContent("Automations", value: snapshot.scheduledTasks.count.formatted())
        }

        Section("Before you restore") {
          Text(
            "This replaces the current local library. Provider keys are not in the backup; restored providers stay disabled and every restored automation remains paused until you review them."
          )
          .foregroundStyle(.secondary)

          if hasActiveProviderWork {
            Label(
              "Finish or stop active requests and data operations before continuing.",
              systemImage: "hourglass"
            )
            .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Restore Backup?")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { pendingRestore = nil }
            .disabled(isApplyingRestore)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Continue") {
            showFinalRestoreConfirmation = true
          }
          .disabled(isApplyingRestore || hasActiveProviderWork)
        }
      }
      .interactiveDismissDisabled(isApplyingRestore)
      .overlay {
        if isApplyingRestore {
          ProgressView("Restoring…")
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
      }
      .alert("Replace Current Library?", isPresented: $showFinalRestoreConfirmation) {
        Button("Replace Library", role: .destructive) {
          applyRestore(pending.plan)
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "Current conversations, memories, documents, providers, and automations can’t be recovered unless you already made a backup."
        )
      }
      .alert("Restore failed", isPresented: restoreErrorIsPresented) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(restoreErrorMessage ?? "Please try again.")
      }
    }
    #if os(macOS)
      .frame(minWidth: 420, minHeight: 430)
    #endif
  }

  private func prepareExport() {
    guard !isBusy else { return }
    guard !operationCoordinator.isSourceStoreUnavailable else {
      errorMessage =
        "Turing AI cannot export an unverified library. Restore a valid backup before creating another backup."
      return
    }
    isPreparingExport = true
    isCancellingPreparation = false
    statusMessage = nil
    preparationTask = Task { @MainActor in
      defer {
        isPreparingExport = false
        isCancellingPreparation = false
        preparationTask = nil
      }
      guard !operationCoordinator.isSourceStoreUnavailable else {
        errorMessage =
          "Turing AI cannot export an unverified library. Restore a valid backup before creating another backup."
        return
      }
      guard operationCoordinator.beginVerifiedSourceSnapshotMaintenance() else {
        errorMessage = "Finish active requests and data operations before creating a backup."
        return
      }
      do {
        defer { operationCoordinator.endExclusiveMaintenance() }
        let data = try await MosaicPortableBackup.exportAsync(from: modelContext)
        try Task.checkCancellation()
        exportDocument = MosaicBackupDocument(data: data)
        exportFilename = Self.backupFilename(at: .now)
        showExporter = true
      } catch is CancellationError {
        return
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func importBackup(_ result: Result<[URL], Error>) {
    guard !isBusy else { return }
    switch result {
    case .failure(let error):
      if (error as NSError).code == NSUserCancelledError { return }
      errorMessage = error.localizedDescription
    case .success(let urls):
      guard let url = urls.first else { return }
      isPreparingRestore = true
      isCancellingPreparation = false
      statusMessage = nil
      preparationTask = Task { @MainActor in
        defer {
          isPreparingRestore = false
          isCancellingPreparation = false
          preparationTask = nil
        }
        do {
          let data = try await MosaicBackupFileReader.shared.read(url)
          try Task.checkCancellation()
          let plan = try await MosaicPortableBackup.prepareRestoreAsync(from: data)
          try Task.checkCancellation()
          pendingRestore = PendingMosaicRestore(plan: plan)
        } catch is CancellationError {
          return
        } catch {
          errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func applyRestore(_ plan: MosaicPortableRestorePlan) {
    guard !isApplyingRestore else { return }
    isApplyingRestore = true
    Task { @MainActor in
      defer { isApplyingRestore = false }
      guard operationCoordinator.beginExclusiveMaintenance() else {
        restoreErrorMessage =
          "Finish active requests and data operations before restoring a backup."
        return
      }
      var semanticIndexWasCleared = true
      do {
        defer { operationCoordinator.endExclusiveMaintenance() }
        if operationCoordinator.isSourceStoreUnavailable {
          modelContext.rollback()
        } else {
          try operationCoordinator.flushSourceChangesForVerifiedSnapshot(in: modelContext)
        }
        try await MosaicPortableBackup.replaceLiveStoreAsync(using: plan, in: modelContext)
        do {
          try await SemanticIndexStore.clearAllAsync()
        } catch {
          semanticIndexWasCleared = false
        }
      } catch {
        modelContext.rollback()
        if let backupError = error as? MosaicPortableBackupError,
          backupError == .liveStoreRecoveryFailed
        {
          operationCoordinator.markSourceStoreUnavailable()
        }
        restoreErrorMessage = error.localizedDescription
        return
      }
      operationCoordinator.markSourceStoreReplaced()
      pendingRestore = nil
      reportResult(
        semanticIndexWasCleared
          ? "Library restored. Review and re-enable providers, re-enter their keys, and review paused automations before using them."
          : "Library restored with providers disabled and automations paused. The rebuildable search cache could not be cleared and will be revalidated before use."
      )
    }
  }

  private func cancelPreparation() {
    guard isPreparingExport || isPreparingRestore else { return }
    isCancellingPreparation = true
    preparationTask?.cancel()
  }

  private func reportResult(_ message: String) {
    statusMessage = message
    AccessibilityNotification.Announcement(message).post()
  }

  private var restoreErrorIsPresented: Binding<Bool> {
    Binding(
      get: { restoreErrorMessage != nil },
      set: { if !$0 { restoreErrorMessage = nil } }
    )
  }

  private static func backupFilename(at date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    return "Turing AI-Backup-\(formatter.string(from: date))"
  }
}

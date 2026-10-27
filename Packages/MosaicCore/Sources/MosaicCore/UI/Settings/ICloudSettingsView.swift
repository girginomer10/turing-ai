import SwiftData
import SwiftUI

struct ICloudSettingsView: View {
  @Environment(\.modelContext) private var modelContext
  @State private var sync = ICloudLibraryCoordinator.shared
  var body: some View {
    Form {
      Section {
        Toggle("Sync with iCloud", isOn: $sync.enabled)
          .disabled(sync.isSyncing)
      } footer: {
        Text(
          "Keep chats, memories, projects, model preferences and attachments in your own private iCloud account. Turing AI has no sync server. API keys stay in this device’s Keychain; add them separately on another device. Scheduled runs remain on the device where you created them."
        )
      }
      Section("Status") {
        Label(
          sync.status, systemImage: sync.isSyncing ? "arrow.triangle.2.circlepath.icloud" : "icloud"
        )
        .fixedSize(horizontal: false, vertical: true)
        if let date = sync.lastSync {
          LabeledContent("Last sync", value: date.formatted(date: .abbreviated, time: .shortened))
        }
        Button("Sync Now") { Task { await sync.sync(in: modelContext) } }.disabled(
          !sync.enabled || sync.isSyncing)
        Text(
          "Sync runs while the app is open and connected. Changes made offline stay on this device until the next successful sync. Only changed items are transferred. The library limit is 128 MB of record data; larger libraries remain usable locally. Update all devices to this version before enabling sync. Older cloud versions can occupy additional iCloud storage."
        ).font(.footnote).foregroundStyle(.secondary)
      }
      if !sync.conflicts.isEmpty {
        Section("Choose a version") {
          ForEach(sync.conflicts.prefix(20)) { conflict in
            VStack(alignment: .leading, spacing: 12) {
              Text(conflict.title.capitalized).font(.headline)
              Text("This device").font(.subheadline.bold())
              Text(CloudConflict.preview(conflict.local)).font(.caption).textSelection(.enabled)
              Button("Keep this device's version") {
                Task { await sync.resolve(conflict, useLocal: true, in: modelContext) }
              }.disabled(sync.isSyncing)
              Divider()
              Text("iCloud").font(.subheadline.bold())
              Text(CloudConflict.preview(conflict.remote)).font(.caption).textSelection(.enabled)
              Button("Keep iCloud's version") {
                Task { await sync.resolve(conflict, useLocal: false, in: modelContext) }
              }.disabled(sync.isSyncing)
            }.padding(.vertical, 8)
          }
          if sync.conflicts.count > 20 {
            Text("More conflicts will appear after these are resolved.").font(.caption)
          }
          if let backup = sync.conflictBackup {
            ShareLink("Save this device's version", item: backup)
          }
        }
      }
      if let backup = sync.recoveryBackup {
        Section("Recovery") {
          ShareLink("Save the library from before the last sync", item: backup)
          Text(
            "When two devices change the same item, choose the version to keep below. Both versions are preserved locally before you choose. A recovery backup is also kept before applying downloaded changes."
          ).font(.footnote)
        }
      }
    }
    .navigationTitle("iCloud")
    .onChange(of: sync.enabled) { _, enabled in
      if enabled { Task { await sync.sync(in: modelContext) } }
    }
  }
}

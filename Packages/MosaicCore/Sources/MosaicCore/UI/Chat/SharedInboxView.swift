import SwiftData
import SwiftUI

struct SharedInboxView: View {
  @Environment(\.modelContext) private var context
  let open: (UUID) -> Void
  @State private var items: [SharedInboxItem] = []
  @State private var error: String?
  @State private var busy = false
  var body: some View {
    List {
      Text(
        "Items from the iPhone share menu wait here until you review them. Nothing is sent to a provider automatically."
      ).font(.subheadline).foregroundStyle(.secondary)
      if busy { ProgressView("Preparing draft…") }
      if let error { Text(error).foregroundStyle(.red) }
      ForEach(items) { item in
        Section(item.createdAt.formatted(date: .abbreviated, time: .shortened)) {
          if !item.prompt.isEmpty { Text(item.prompt) }
          ForEach(Array(item.files.enumerated()), id: \.offset) { _, file in
            Label(file.displayName, systemImage: "doc")
          }
          Button("Open as a new draft") { prepare(item) }.disabled(busy)
          Button("Remove", role: .destructive) {
            do {
              try SharedInbox.remove(item.id, in: SharedInbox.directory())
              load()
            } catch { self.error = error.localizedDescription }
          }.disabled(busy)
        }
      }
      if items.isEmpty, !busy {
        ContentUnavailableView(
          "No shared items", systemImage: "square.and.arrow.down",
          description: Text("Use Share → Turing AI in Safari, Photos or Files."))
      }
    }.navigationTitle("Shared items").task { load() }.refreshable { load() }
  }
  private func load() {
    do {
      items = try SharedInbox.items(in: SharedInbox.directory())
      error = nil
    } catch { self.error = error.localizedDescription }
  }
  private func prepare(_ item: SharedInboxItem) {
    guard !busy, !MosaicOperationCoordinator.shared.isSourceAccessBlocked else { return }
    busy = true
    Task { @MainActor in
      defer { busy = false }
      let coordinator = MosaicOperationCoordinator.shared
      let generation = coordinator.sourceStoreGenerationRevision
      let id = item.id  // Stable identity makes a crash after save/before inbox cleanup idempotent.
      do {
        let directory = try SharedInbox.directory().appendingPathComponent(id.uuidString)
        let values = try await Task.detached {
          try item.files.map { file in
            var value = try ChatAttachmentStore.importFile(
              directory.appendingPathComponent(file.storedName), conversationID: id)
            value.filename = file.displayName
            return value
          }
        }.value
        guard generation == coordinator.sourceStoreGenerationRevision,
          !coordinator.isSourceAccessBlocked
        else { throw ConversationCompactionError.staleSource }
        if try context.fetchCount(
          FetchDescriptor<ConversationRecord>(predicate: #Predicate { $0.id == id })) == 0
        {
          let providers = try context.fetch(FetchDescriptor<ProviderConfigurationRecord>())
          let models = try context.fetch(FetchDescriptor<ProviderModelRecord>())
          let choice = ExperienceStore.defaultChoice(
            projectID: nil,
            choices: ProviderModelStore.choices(providers: providers, models: models),
            values: try ExperienceStore.preferences(in: context))
          let chat = ConversationRecord(
            id: id, title: String((item.files.first?.displayName ?? "Shared items").prefix(160)),
            providerConfigurationID: choice?.providerID,
            modelIdentifier: choice?.modelIdentifier ?? "", draftText: item.prompt)
          do {
            context.insert(chat)
            for value in values { try ExperienceStore.save(value, in: context) }
            try coordinator.saveSourceChanges(in: context)
          } catch {
            context.rollback()
            throw error
          }
        }
        try SharedInbox.remove(id, in: SharedInbox.directory())
        load()
        open(id)
      } catch { self.error = error.localizedDescription }
    }
  }
}

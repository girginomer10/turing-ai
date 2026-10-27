import SwiftData
import SwiftUI

struct ConversationAlternativesView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context
  @Query(filter: #Predicate<ExperienceRecord> { $0.category == "branch" }) private var links:
    [ExperienceRecord]
  let conversationID: UUID
  let open: (UUID) -> Void
  var body: some View {
    NavigationStack {
      List {
        ForEach(alternatives, id: \.id) { item in
          Button {
            dismiss()
            open(item.id)
          } label: {
            HStack {
              Text(item.title).foregroundStyle(.primary)
              Spacer()
              if item.id == conversationID { Image(systemName: "checkmark") }
            }.frame(minHeight: 44)
          }
        }
        if alternatives.isEmpty {
          Text("Edit a message or ask another model to create an alternative.").foregroundStyle(
            .secondary)
        }
      }.navigationTitle("Alternatives")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
    }
  }
  private var alternatives: [ConversationRecord] {
    let values = links.compactMap {
      try? JSONDecoder().decode(ExperienceValue.self, from: $0.payload)
    }
    guard let group = values.first(where: { $0.conversationID == conversationID })?.branchGroupID
    else { return [] }
    return values.filter { $0.branchGroupID == group }.compactMap { value in
      guard let id = value.conversationID else { return nil }
      return try? context.fetch(
        FetchDescriptor<ConversationRecord>(predicate: #Predicate { $0.id == id })
      ).first
    }.sorted { $0.createdAt < $1.createdAt }
  }
}

struct MessageEditView: View {
  @Environment(\.dismiss) private var dismiss
  @State var text: String
  let create: (String) -> Void
  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        Text(
          "Your original conversation is preserved. Continue from this message in a new alternative."
        )
        .font(.subheadline).foregroundStyle(.secondary)
        TextEditor(text: $text).font(.body).accessibilityLabel("Edited message")
      }.padding().navigationTitle("Edit message")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Continue") {
              create(text)
              dismiss()
            }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
    }
    #if os(macOS)
      .frame(minWidth: 460, minHeight: 400)
    #endif
  }
}

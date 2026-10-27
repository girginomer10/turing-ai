import SwiftData
import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

struct ChatAttachmentStrip: View {
  @Query private var records: [ExperienceRecord]
  @State private var preview: ExperienceValue?
  init(messageID: UUID) {
    _records = Query(
      filter: #Predicate<ExperienceRecord> {
        $0.messageID == messageID && $0.category == "attachment"
      })
  }
  private var values: [ExperienceValue] {
    records.compactMap { try? JSONDecoder().decode(ExperienceValue.self, from: $0.payload) }
  }
  var body: some View {
    ForEach(values, id: \.id) { value in
      Button {
        preview = value
      } label: {
        VStack(alignment: .leading, spacing: 6) {
          if let data = value.bytes {
            AttachmentImage(data: data).frame(maxHeight: 180).clipShape(
              RoundedRectangle(cornerRadius: 12))
          }
          Label(value.filename ?? "Attachment", systemImage: value.isImage ? "photo" : "doc.text")
            .font(.caption).lineLimit(2)
        }.frame(minHeight: 44, alignment: .leading)
      }.buttonStyle(.plain).accessibilityLabel("Open \(value.filename ?? "attachment")")
    }
    .sheet(item: $preview) { value in AttachmentPreview(value: value) }
  }
}
extension ExperienceValue: Identifiable {}

private struct AttachmentPreview: View {
  @Environment(\.dismiss) private var dismiss
  let value: ExperienceValue
  var body: some View {
    NavigationStack {
      ScrollView {
        if let data = value.bytes { AttachmentImage(data: data) }
        if let text = value.extractedText { Text(text).textSelection(.enabled).padding() }
      }
      .navigationTitle(value.filename ?? "Attachment")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    #if os(macOS)
      .frame(minWidth: 500, minHeight: 450)
    #endif
  }
}
private struct AttachmentImage: View {
  let data: Data
  var body: some View {
    #if os(iOS)
      if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() }
    #else
      if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() }
    #endif
  }
}

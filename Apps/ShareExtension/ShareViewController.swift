import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
  private let prompt = UITextView()
  private let status = UILabel()
  private let saveButton = UIButton(type: .system)
  private var prepared: SharedInboxItem?
  private var staging: URL?
  private var work: Task<Void, Never>?
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let title = UILabel()
    title.text = "Send to Turing AI"
    title.font = .preferredFont(forTextStyle: .title2)
    title.adjustsFontForContentSizeCategory = true
    status.text = "Preparing shared items…"
    status.numberOfLines = 0
    status.font = .preferredFont(forTextStyle: .subheadline)
    status.adjustsFontForContentSizeCategory = true
    prompt.font = .preferredFont(forTextStyle: .body)
    prompt.adjustsFontForContentSizeCategory = true
    prompt.accessibilityLabel = "Optional question"
    prompt.layer.cornerRadius = 12
    prompt.backgroundColor = .secondarySystemBackground
    prompt.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    saveButton.setTitle("Save draft", for: .normal)
    saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
    saveButton.isEnabled = false
    saveButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    let cancel = UIButton(type: .system)
    cancel.setTitle("Cancel", for: .normal)
    cancel.addTarget(self, action: #selector(cancelShare), for: .touchUpInside)
    cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    let stack = UIStackView(arrangedSubviews: [title, status, prompt, saveButton, cancel])
    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
      stack.leadingAnchor.constraint(
        equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(
        equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
    ])
    work = Task { await prepare() }
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    work?.cancel()
    if let staging { try? FileManager.default.removeItem(at: staging) }
  }

  private func prepare() async {
    do {
      let directory = try SharedInbox.directory()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      guard try SharedInbox.items(in: directory).count < 10 else {
        throw NSError(
          domain: "Share", code: 1,
          userInfo: [
            NSLocalizedDescriptionKey: "Open Turing AI and clear Shared items before adding more."
          ])
      }
      let id = UUID()
      let stage = directory.appendingPathComponent(id.uuidString + ".pending")
      try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
      staging = stage
      var files: [SharedInboxItem.File] = []
      let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap {
        $0.attachments ?? []
      }
      guard !providers.isEmpty, providers.count <= 4 else { throw CocoaError(.fileReadTooLarge) }
      for provider in providers {
        try Task.checkCancellation()
        if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
          let item = try await load(provider, type: UTType.propertyList.identifier)
          if case .page(let page) = item, let text = page["text"] {
            let name = "\(files.count).txt"
            let content =
              "Shared web page: \(page["title"] ?? "Page")\nURL: \(page["url"] ?? "")\n\n"
              + String(text.prefix(200_000))
            try Data(content.utf8).write(to: stage.appendingPathComponent(name), options: .atomic)
            files.append(.init(storedName: name, displayName: "Web page.txt"))
            continue
          }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
          !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        {
          let item = try await load(provider, type: UTType.url.identifier)
          guard case .url(let url) = item,
            ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
            url.absoluteString.utf8.count <= 8192
          else { throw CocoaError(.fileReadUnsupportedScheme) }
          let name = "\(files.count).txt"
          try Data("Shared link (page text was not provided): \(url.absoluteString)".utf8).write(
            to: stage.appendingPathComponent(name), options: .atomic)
          files.append(.init(storedName: name, displayName: "Shared link.txt"))
          continue
        }
        if let type = [UTType.image, .pdf, .plainText].first(where: {
          provider.hasItemConformingToTypeIdentifier($0.identifier)
        }) {
          let result = try await copyFile(
            provider, type: type.identifier, directory: stage, index: files.count)
          files.append(result)
          continue
        }
        throw CocoaError(.fileReadUnknown)
      }
      try Task.checkCancellation()
      guard !files.isEmpty else { throw CocoaError(.fileReadUnknown) }
      prepared = SharedInboxItem(id: id, createdAt: .now, prompt: "", files: files)
      status.text =
        "\(files.count) item(s) ready. Add a question, then save. Open Turing AI → Shared items to review and send."
      saveButton.isEnabled = true
    } catch is CancellationError {} catch { status.text = error.localizedDescription }
  }
  // File representations are copied inside the callback, before the provider invalidates its URL.
  private func copyFile(_ provider: NSItemProvider, type: String, directory: URL, index: Int)
    async throws -> SharedInboxItem.File
  {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
        do {
          if let error { throw error }
          guard let url, let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size <= 30 * 1_024 * 1_024
          else { throw CocoaError(.fileReadTooLarge) }
          let name =
            "\(index)."
            + (url.pathExtension.isEmpty
              ? (UTType(type)?.preferredFilenameExtension ?? "txt")
              : String(url.pathExtension.prefix(12)))
          try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(name))
          continuation.resume(
            returning: .init(
              storedName: name, displayName: String(url.lastPathComponent.prefix(200))))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
  private enum Loaded: Sendable {
    case page([String: String])
    case url(URL)
    case unsupported
  }
  private func load(_ provider: NSItemProvider, type: String) async throws -> Loaded {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        if let url = item as? URL {
          continuation.resume(returning: .url(url))
          return
        }
        if let dictionary = item as? NSDictionary,
          let page = dictionary[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: String]
        {
          continuation.resume(returning: .page(page))
          return
        }
        continuation.resume(returning: .unsupported)
      }
    }
  }
  @objc private func save() {
    guard var item = prepared, let staging else { return }
    do {
      guard prompt.text.utf8.count <= 32_000 else { throw CocoaError(.fileReadTooLarge) }
      item.prompt = prompt.text
      try JSONEncoder().encode(item).write(
        to: staging.appendingPathComponent("item.json"), options: .atomic)
      try FileManager.default.moveItem(
        at: staging,
        to: staging.deletingLastPathComponent().appendingPathComponent(item.id.uuidString))
      self.staging = nil
      saveButton.isEnabled = false
      extensionContext?.completeRequest(returningItems: nil)
    } catch { status.text = error.localizedDescription }
  }
  @objc private func cancelShare() {
    work?.cancel()
    if let staging { try? FileManager.default.removeItem(at: staging) }
    extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
  }
}

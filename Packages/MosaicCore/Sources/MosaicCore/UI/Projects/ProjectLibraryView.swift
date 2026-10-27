import SwiftData
import SwiftUI

@MainActor
struct ProjectLibraryView: View {
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \ProjectRecord.updatedAt, order: .reverse)
  private var projects: [ProjectRecord]

  let newChat: (UUID) -> Void

  @State private var operationCoordinator = MosaicOperationCoordinator.shared
  @State private var editingProject: MosaicProjectSnapshot?
  @State private var isCreatingProject = false
  @State private var errorMessage: String?

  var body: some View {
    List {
      if activeProjects.isEmpty {
        ContentUnavailableView {
          Label("No Projects", systemImage: "folder")
        } description: {
          Text("Group related chats, memories, and documents behind one recall boundary.")
        } actions: {
          Button("New Project") { isCreatingProject = true }
            .buttonStyle(.borderedProminent)
            .disabled(operationCoordinator.isSourceAccessBlocked)
        }
      } else {
        Section("Active") {
          ForEach(activeProjects) { project in
            ProjectLibraryRow(
              project: project.snapshot,
              newChat: { newChat(project.id) },
              edit: { editingProject = project.snapshot },
              archive: { setArchived(true, project: project) }
            )
          }
        }
      }

      if !archivedProjects.isEmpty {
        Section("Archived") {
          ForEach(archivedProjects) { project in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Label(project.name, systemImage: "archivebox")
              Spacer(minLength: 8)
              Button("Unarchive") { setArchived(false, project: project) }
                .buttonStyle(.borderless)
            }
            .contextMenu {
              Button("Edit", systemImage: "pencil") {
                editingProject = project.snapshot
              }
              Button("Unarchive", systemImage: "tray.and.arrow.up") {
                setArchived(false, project: project)
              }
            }
          }
        }
      }
    }
    .navigationTitle("Projects")
    .toolbar {
      ToolbarItem(id: "project-add", placement: .primaryAction) {
        Button {
          isCreatingProject = true
        } label: {
          Label("New Project", systemImage: "plus")
        }
        .disabled(operationCoordinator.isSourceAccessBlocked)
        .mosaicControlTarget()
      }
    }
    .sheet(isPresented: $isCreatingProject) {
      ProjectEditorView(project: nil)
    }
    .sheet(item: $editingProject) { project in
      ProjectEditorView(project: project)
    }
    .alert("Project couldn’t be updated", isPresented: errorIsPresented) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "Please try again.")
    }
  }

  private var activeProjects: [ProjectRecord] {
    projects.filter { !$0.isArchived }
  }

  private var archivedProjects: [ProjectRecord] {
    projects.filter(\.isArchived)
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private func setArchived(_ archived: Bool, project: ProjectRecord) {
    guard !operationCoordinator.isSourceAccessBlocked,
      operationCoordinator.activeOperations.isEmpty
    else { return }
    project.isArchived = archived
    project.updatedAt = .now
    do {
      try operationCoordinator.saveSourceChanges(in: modelContext)
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }
}

@MainActor
private struct ProjectLibraryRow: View {
  let project: MosaicProjectSnapshot
  let newChat: () -> Void
  let edit: () -> Void
  let archive: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Label(project.name, systemImage: "folder.fill")
          .font(.headline)
        Spacer(minLength: 8)
        Menu {
          Button("New Chat", systemImage: "square.and.pencil", action: newChat)
          Button("Edit", systemImage: "pencil", action: edit)
          Divider()
          Button("Archive", systemImage: "archivebox", action: archive)
        } label: {
          Label("Project Actions", systemImage: "ellipsis.circle")
            .labelStyle(.iconOnly)
        }
        .mosaicControlTarget()
        .accessibilityLabel("Actions for \(project.name)")
      }

      if !project.instructions.isEmpty {
        Text(project.instructions)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }

      Button(action: newChat) {
        Label("New Chat in Project", systemImage: "plus.bubble")
      }
      .buttonStyle(.borderless)
      .mosaicControlTarget()
    }
    .padding(.vertical, 5)
    .accessibilityElement(children: .contain)
  }
}

@MainActor
struct ProjectDetailView: View {
  @Environment(\.modelContext) private var modelContext
  @Query private var providers: [ProviderConfigurationRecord]
  @Query private var models: [ProviderModelRecord]
  @State private var choosingDefault = false
  @Query private var projects: [ProjectRecord]
  @Query private var bindings: [ProjectResourceBindingRecord]

  let newChat: (UUID) -> Void

  @State private var editingProject: MosaicProjectSnapshot?

  init(projectID: UUID, newChat: @escaping (UUID) -> Void) {
    let targetID = projectID
    var projectDescriptor = FetchDescriptor<ProjectRecord>(
      predicate: #Predicate { $0.id == targetID }
    )
    projectDescriptor.fetchLimit = 1
    _projects = Query(projectDescriptor)

    let conversationKind = ProjectResourceKind.conversation.rawValue
    _bindings = Query(
      filter: #Predicate<ProjectResourceBindingRecord> {
        $0.projectID == targetID && $0.resourceKindRawValue == conversationKind
      }
    )
    self.newChat = newChat
  }

  var body: some View {
    if let project = projects.first {
      List {
        Section("Project") {
          Label(project.name, systemImage: "folder.fill")
            .font(.title3.weight(.semibold))
          if project.instructions.isEmpty {
            Text("No project instructions")
              .foregroundStyle(.secondary)
          } else {
            Text(project.instructions)
              .textSelection(.enabled)
          }
          Button("Default model") { choosingDefault = true }
            .sheet(isPresented: $choosingDefault) {
              ChatModelSelectionView(
                choices: ProviderModelStore.choices(providers: providers, models: models),
                selectedID: ((try? ExperienceStore.preferences(in: modelContext)) ?? []).first {
                  $0.kind == .projectDefault && $0.projectID == project.id
                }?.selectionKey, defaultProjectID: project.id, choosingProjectDefault: true
              ) { _ in }
            }
          LabeledContent("Chats", value: bindings.count.formatted())
          LabeledContent("Recall boundary", value: "This project only")
        }

        Section {
          Button {
            newChat(project.id)
          } label: {
            Label("New Chat in Project", systemImage: "square.and.pencil")
          }
          .buttonStyle(.borderedProminent)
          .disabled(project.isArchived)

          Button {
            editingProject = project.snapshot
          } label: {
            Label("Edit Project", systemImage: "pencil")
          }
        } footer: {
          Text(
            project.isArchived
              ? "Archived projects stay attached to their existing chats and knowledge, but cannot receive new items."
              : "Project chats recall only this project’s chats and documents, plus memories marked Everywhere."
          )
        }
      }
      .navigationTitle(project.name)
      .sheet(item: $editingProject) { snapshot in
        ProjectEditorView(project: snapshot)
      }
    } else {
      ContentUnavailableView("Project Not Found", systemImage: "folder.badge.questionmark")
    }
  }
}

@MainActor
private struct ProjectEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  let project: MosaicProjectSnapshot?

  @State private var operationCoordinator = MosaicOperationCoordinator.shared
  @State private var name: String
  @State private var instructions: String
  @State private var errorMessage: String?
  @State private var sourceGenerationAtOpen: UInt64

  init(project: MosaicProjectSnapshot?) {
    self.project = project
    _name = State(initialValue: project?.name ?? "")
    _instructions = State(initialValue: project?.instructions ?? "")
    _sourceGenerationAtOpen = State(
      initialValue: MosaicOperationCoordinator.shared.sourceStoreGenerationRevision
    )
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Project") {
          TextField("Name", text: $name, prompt: Text("Product launch"))
            .textContentType(.none)
          TextEditor(text: $instructions)
            .frame(minHeight: 130)
            .accessibilityLabel("Project instructions")
        }
        Section {
          Label("Project-only recall", systemImage: "lock.square.stack")
          Text(
            "Chats and documents assigned here can be recalled by other chats in this project, never by a different project. Everywhere memories remain available."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        } header: {
          Text("Memory boundary")
        }
      }
      .navigationTitle(project == nil ? "New Project" : "Edit Project")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: save)
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
        }
      }
      .interactiveDismissDisabled(hasUnsavedChanges)
      .onChange(of: operationCoordinator.sourceStoreGenerationRevision) { _, revision in
        guard revision != sourceGenerationAtOpen else { return }
        errorMessage =
          ProjectBindingError.staleProjectEdit(project?.id ?? UUID())
          .localizedDescription
      }
      .alert("Project couldn’t be saved", isPresented: errorIsPresented) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "Please try again.")
      }
    }
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedInstructions: String {
    instructions.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSave: Bool {
    !trimmedName.isEmpty
      && trimmedName.utf8.count <= MosaicSourceFieldLimits.maximumProjectNameUTF8Bytes
      && trimmedInstructions.utf8.count
        <= MosaicSourceFieldLimits.maximumProjectInstructionsUTF8Bytes
      && !operationCoordinator.isSourceAccessBlocked
      && operationCoordinator.activeOperations.isEmpty
      && sourceGenerationAtOpen == operationCoordinator.sourceStoreGenerationRevision
  }

  private var hasUnsavedChanges: Bool {
    name != (project?.name ?? "") || instructions != (project?.instructions ?? "")
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private func save() {
    guard canSave else { return }
    do {
      guard sourceGenerationAtOpen == operationCoordinator.sourceStoreGenerationRevision
      else {
        throw ProjectBindingError.staleProjectEdit(project?.id ?? UUID())
      }
      try MosaicSourceFieldLimits.validateProject(
        name: trimmedName,
        instructions: trimmedInstructions
      )
      if let project {
        try ProjectBindingStore.updateProject(
          id: project.id,
          expected: project,
          name: trimmedName,
          instructions: trimmedInstructions,
          in: modelContext
        )
      } else {
        modelContext.insert(
          ProjectRecord(name: trimmedName, instructions: trimmedInstructions)
        )
      }
      try operationCoordinator.saveSourceChanges(in: modelContext)
      dismiss()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }
}

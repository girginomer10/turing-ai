import SwiftUI

struct ConnectionsView: View {
  @State private var query = ""
  @State private var connected: Set<ConnectorID> = []
  private var visible: [ConnectorID] {
    ConnectorID.allCases.filter {
      query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
    }
  }
  var body: some View {
    List {
      if query.isEmpty || "Google Gmail Drive".localizedCaseInsensitiveContains(query) {
        Section("Google account") {
          NavigationLink {
            GoogleConnectionsView()
          } label: {
            Label("Gmail & Google Drive", systemImage: "envelope")
          }
        }
      }
      Section("Apple · On this device") {
        ForEach(visible.filter(\.isApple)) { row($0) }
      }
      Section("Accounts & apps") {
        ForEach(visible.filter { !$0.isApple }) { row($0) }
      }
      Section {
        Text(
          "Connections go directly from this device to the service. Relevant results are shared with the model you choose only when chat access is enabled. Account credentials stay in Keychain on this device."
        )
        Text(
          "Saved answers and source links follow your chat backup and iCloud settings. Connecting does not import an entire account into memory."
        )
      }.font(.footnote).foregroundStyle(.secondary)
    }
    .navigationTitle("Connections")
    .searchable(text: $query, prompt: "Find a connection")
    .task { await reload() }
  }
  private func row(_ service: ConnectorID) -> some View {
    NavigationLink {
      ConnectorDetailView(service: service)
    } label: {
      HStack(alignment: .center, spacing: 12) {
        Image(systemName: service.symbol).frame(width: 26).foregroundStyle(.tint)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(service.title)
          Text(connected.contains(service) ? "Connected" : "Not connected")
            .font(.caption).foregroundStyle(.secondary)
        }
      }.padding(.vertical, 4)
    }
  }
  private func reload() async {
    var result = Set<ConnectorID>()
    for service in ConnectorID.allCases {
      if (try? await ConnectorStore.shared.credential(service)) != nil,
        !service.isApple || AppleConnections.authorized(service)
      {
        result.insert(service)
      }
    }
    connected = result
  }
}

struct ConnectorDetailView: View {
  @AppStorage(InterfacePreferences.advancedControlsKey) private var advancedControls = false
  @Environment(\.openURL) private var openURL
  let service: ConnectorID
  @State private var connectionID: UUID?
  @State private var accountLabel = ""
  @State private var token = ""
  @State private var clientID = ""
  @State private var busy = false
  @State private var connectionTask: Task<Void, Never>?
  @State private var startedGoogleConnect = false
  @State private var error: String?
  @State private var signIn = ConnectorSignIn()
  @State private var google = GoogleSignInSession()
  @State private var confirmingDisconnect = false
  @AppStorage("turing.connections.defaults") private var defaults = ""
  private var selection: ConnectorSelection { .init(raw: defaults) }
  var body: some View {
    Form {
      Section {
        Label(service.title, systemImage: service.symbol).font(.headline)
        if connectionID != nil {
          Label(
            service.isApple && !AppleConnections.authorized(service)
              ? "Permission needed" : "Connected", systemImage: "checkmark.circle")
          if !service.isApple && service.googleService == nil {
            Text(accountLabel).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        if service.isApple {
          Text(
            "Uses \(service.title.replacingOccurrences(of: "Apple ", with: "").lowercased()) available on this device, including accounts synchronized by Apple. Nothing is copied into a separate server."
          )
          Button(connectionID == nil ? "Allow access" : "Check permission") { connectNative() }
        } else if let scope = service.googleService {
          if let account = google.account { Text(account.email).foregroundStyle(.secondary) }
          if google.account?.supports(scope) == true {
            Button("Use this Google connection") { connectGoogle() }
          } else {
            Button("Connect with Google") {
              let existing = Set(
                GoogleService.allCases.filter { google.account?.supports($0) == true })
              startedGoogleConnect = true
              google.connect(services: existing.union([scope]))
            }
            Text(
              "Google will ask for read access to \(service.title). Existing Gmail and Drive permissions are preserved."
            )
            .font(.footnote).foregroundStyle(.secondary)
          }
        } else {
          if service.supportsOAuth {
            Button(connectionID == nil ? "Sign in" : "Reconnect or change account") {
              signIn.connect(service, clientID: clientID) { await reload() }
            }
            .disabled(
              (service.isMicrosoft || service == .dropbox)
                && clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if (service.isMicrosoft || service == .dropbox)
              && clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
              Text(
                "This connection still needs app setup. Developer setup is available with advanced controls in Settings."
              )
              .font(.footnote).foregroundStyle(.secondary)
            }
            if advancedControls && (service.isMicrosoft || service == .dropbox) {
              DisclosureGroup("Connection setup") {
                TextField("Public client ID", text: $clientID).autocorrectionDisabled()
                Text(
                  "Register Turing AI once as a native public app. No client secret is used. End users sign in to that registration."
                )
                Text("Redirect: com.omergirgin.turing:/oauth/" + service.credentialKey).font(
                  .footnote
                ).textSelection(.enabled)
                Button("Save public client ID") {
                  UserDefaults.standard.set(
                    clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                    forKey: "turing.connection.client." + service.credentialKey)
                }
                Link("Open developer settings", destination: service.helpURL)
              }
            }
          }
          if service.supportsToken {
            VStack(alignment: .leading, spacing: 12) {
              Text("Personal account token").font(.subheadline.weight(.semibold))
              SecureField("Access token", text: $token).autocorrectionDisabled()
              Button("Verify and connect") { connectToken() }.disabled(
                token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              Link("Get a token from \(service.title)", destination: service.helpURL)
              Text(
                "Use a token for your own account with only the permissions you want to grant. The token is verified before it is stored."
              )
              .font(.footnote).foregroundStyle(.secondary)
            }
          }
        }
      }.disabled(busy || signIn.busy || google.isBusy)
      if let id = connectionID {
        Section {
          Toggle(
            "Use in chats by default",
            isOn: Binding(
              get: { selection.bindings[service] == id },
              set: { enabled in
                var updated = selection
                if enabled {
                  updated.bindings[service] = id
                } else {
                  updated.bindings.removeValue(forKey: service)
                }
                defaults = updated.raw
              })
          )
          .disabled(service.isApple && !AppleConnections.authorized(service))
        } footer: {
          Text(
            "When relevant to a message, selected results go to that chat’s AI provider. Change access for one chat from + → Connections. Planner and answer tokens count toward Usage & Cost."
          )
        }
      }
      Section("Available actions") {
        Text(capabilities)
        if service.isApple || service.mcpURL != nil || service == .todoist {
          Text(
            "Actions that change data require a review of the exact request before they run. Some unfamiliar remote tools also ask for review."
          )
        }
        if service.isMicrosoft {
          Text(
            "Outlook, Microsoft To Do and OneDrive share one Microsoft sign-in. Each service has its own chat access switch. Organization policies may require administrator consent."
          )
        }
      }.font(.footnote)
      if busy || signIn.busy || google.isBusy {
        Section {
          ProgressView("Connecting…")
          Button("Cancel") {
            connectionTask?.cancel()
            signIn.cancel()
            google.cancel()
          }
        }
      }
      if let message = error ?? signIn.error ?? google.error {
        Section {
          Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
          #if os(iOS)
            if service.isApple {
              Button("Open Apple Settings") {
                openURL(URL(string: UIApplication.openSettingsURLString)!)
              }
            }
          #endif
        }
      }
      if connectionID != nil {
        Section {
          Button("Disconnect from this device", role: .destructive) { confirmingDisconnect = true }
        } footer: {
          Text(
            service.isApple
              ? "Stops access in Turing AI. Manage the system permission separately in Apple Settings. Saved answers remain in chats."
              : "Removes the device’s credentials and stops new requests. Saved answers remain in chats. Revoke the service’s permission separately in your account settings."
          )
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(service.title)
    .task {
      clientID =
        UserDefaults.standard.string(forKey: "turing.connection.client." + service.credentialKey)
        ?? Bundle.main.object(
          forInfoDictionaryKey: service.isMicrosoft
            ? "TuringMicrosoftClientID" : "TuringDropboxClientID") as? String ?? ""
      await google.load()
      await reload()
    }
    .onChange(of: google.account) { _, account in
      if startedGoogleConnect, let scope = service.googleService, account?.supports(scope) == true {
        startedGoogleConnect = false
        connectGoogle()
      }
    }
    .onDisappear {
      connectionTask?.cancel()
      signIn.cancel()
      google.cancel()
      token = ""
    }
    .confirmationDialog(
      service.isMicrosoft
        ? "Disconnect Microsoft and its services from this device?"
        : "Disconnect \(service.title)?", isPresented: $confirmingDisconnect,
      titleVisibility: .visible
    ) {
      Button("Disconnect", role: .destructive) {
        Task {
          do {
            try await ConnectorStore.shared.disconnect(service)
            var updated = selection
            for id in ConnectorID.allCases where id.credentialKey == service.credentialKey {
              updated.bindings.removeValue(forKey: id)
            }
            defaults = updated.raw
            await reload()
          } catch { self.error = "The connection could not be removed from Keychain." }
        }
      }
    }
  }
  private var capabilities: String {
    if service == .appleCalendar {
      return
        "Search events by date and text. Create an event in a chosen calendar after review. Invitations and recurring-event changes are not enabled."
    }
    if service == .appleReminders {
      return
        "Search reminders by list, date or text. Create a reminder or mark one completed after review."
    }
    if service == .appleContacts {
      return
        "Find permitted contacts by name. Create a contact after review. Contact notes are not read."
    }
    if service.mcpURL != nil {
      return
        "Uses \(service.title)’s hosted MCP service. Available search, read and change tools are discovered from the permissions granted to your account."
    }
    if service == .todoist {
      return
        "Find projects and tasks, search by date or filter, read comments, create tasks and complete tasks."
    }
    if service == .oneDrive {
      return
        "Search and browse files. Read selected small text, Markdown, CSV, JSON and PDF files. PDF extraction is limited to selectable text; scans and Office documents are not parsed."
    }
    if service == .dropbox {
      return
        "Search and browse files. Read selected small text, Markdown, CSV, JSON and PDF files. PDF extraction is limited to selectable text; scans and Office documents are not parsed."
    }
    return
      "Search and read permitted records with date filters and pagination where the service supports them. Changes are not enabled for this connection."
  }
  private func reload() async {
    do {
      let credential = try await ConnectorStore.shared.credential(service)
      connectionID = credential?.id
      accountLabel = credential?.label ?? ""
    } catch { self.error = "The connection could not be read from Keychain." }
  }
  private func connectNative() {
    busy = true
    error = nil
    connectionTask = Task {
      let attempt = await ConnectorStore.shared.begin(service)
      defer { busy = false }
      do {
        try await AppleConnections.shared.requestAccess(service)
        if connectionID == nil {
          try await ConnectorStore.shared.save(
            .init(token: "", label: "This device"), service: service, attempt: attempt)
        } else {
          await ConnectorStore.shared.cancel(service, attempt: attempt)
        }
        await reload()
      } catch {
        await ConnectorStore.shared.cancel(service, attempt: attempt)
        self.error =
          (error as? ConnectorError)?.localizedDescription
          ?? "Apple access was not granted. Check the permission in Settings."
      }
    }
  }
  private func connectGoogle() {
    busy = true
    error = nil
    connectionTask = Task {
      let attempt = await ConnectorStore.shared.begin(service)
      defer { busy = false }
      do {
        guard let scope = service.googleService,
          let account = try await GoogleConnectionStore.shared.account(), account.supports(scope)
        else { throw ConnectorError.disconnected }
        try await ConnectorStore.shared.save(
          .init(token: "", label: account.subject), service: service, attempt: attempt)
        await reload()
      } catch {
        await ConnectorStore.shared.cancel(service, attempt: attempt)
        self.error = "Reconnect Google with this service’s permission."
      }
    }
  }
  private func connectToken() {
    busy = true
    error = nil
    let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
    connectionTask = Task {
      let attempt = await ConnectorStore.shared.begin(service)
      defer {
        busy = false
        token = ""
      }
      do {
        let label = try await ConnectorExecutor.verify(service, token: secret)
        try await ConnectorStore.shared.save(
          .init(token: secret, label: label), service: service, attempt: attempt)
        await reload()
      } catch {
        await ConnectorStore.shared.cancel(service, attempt: attempt)
        self.error =
          (error as? ConnectorError)?.localizedDescription
          ?? "The connection could not be verified."
      }
    }
  }
}

struct ConnectorChatSection: View {
  @Binding var selection: ConnectorSelection
  @State private var connections: [ConnectorID: UUID] = [:]
  var body: some View {
    Section("Other connections") {
      ForEach(ConnectorID.allCases.filter { connections[$0] != nil }) { service in
        Toggle(
          isOn: Binding(
            get: { selection.bindings[service] == connections[service] },
            set: { enabled in
              if enabled {
                selection.bindings[service] = connections[service]
              } else {
                selection.bindings.removeValue(forKey: service)
              }
            })
        ) { Label(service.title, systemImage: service.symbol) }
      }
      NavigationLink("Manage all connections") { ConnectionsView() }
    }
    .task {
      var current: [ConnectorID: UUID] = [:]
      for service in ConnectorID.allCases {
        if let credential = try? await ConnectorStore.shared.credential(service),
          !service.isApple || AppleConnections.authorized(service)
        {
          current[service] = credential.id
        }
      }
      connections = current
    }
  }
}

@MainActor @Observable
final class ConnectorApprovalCoordinator {
  struct Pending: Identifiable {
    let id = UUID()
    let tool: ConnectorTool
    let call: ConnectorToolCall
  }
  var pending: Pending?
  private var continuation: CheckedContinuation<Bool, Never>?
  func request(_ tool: ConnectorTool, call: ConnectorToolCall) async -> Bool {
    finish(false)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        pending = .init(tool: tool, call: call)
        if Task.isCancelled { finish(false) }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finish(false) }
    }
  }
  func finish(_ approved: Bool) {
    let saved = continuation
    continuation = nil
    pending = nil
    saved?.resume(returning: approved)
  }
}
struct ConnectorApprovalView: View {
  let pending: ConnectorApprovalCoordinator.Pending
  let resolve: (Bool) -> Void
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Label(pending.tool.service.title, systemImage: pending.tool.service.symbol).font(
            .headline)
          Text(pending.tool.name.replacingOccurrences(of: "_", with: " "))
          Text(pending.tool.description).font(.footnote).foregroundStyle(.secondary)
        }
        Section("Request to review") {
          ForEach((pending.call.arguments.object ?? [:]).keys.sorted(), id: \.self) { key in
            VStack(alignment: .leading, spacing: 6) {
              Text(key.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(
                .secondary)
              Text(pending.call.arguments[key].string ?? pending.call.arguments[key].encoded)
                .textSelection(.enabled)
            }.padding(.vertical, 4)
          }
        }
        Section {
          Text(
            "Allow this exact request once. It may change data in your connected account. Check the target and content before continuing."
          ).font(.footnote)
        }
        Button("Allow once") { resolve(true) }.buttonStyle(.borderedProminent)
        Button("Decline", role: .cancel) { resolve(false) }
      }
      .navigationTitle("Review action")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { resolve(false) } }
      }
    }
    #if os(macOS)
      .frame(minWidth: 500, minHeight: 500)
    #endif
  }
}

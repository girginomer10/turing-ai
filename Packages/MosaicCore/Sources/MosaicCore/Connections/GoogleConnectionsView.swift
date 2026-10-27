import SwiftUI

struct GoogleConnectionsView: View {
  @State private var signIn = GoogleSignInSession()
  @State private var services: Set<GoogleService> = [.gmail, .drive]
  @State private var confirmingDisconnect = false
  @AppStorage("turing.google.defaultServices") private var defaultServices = ""
  @AppStorage("turing.google.defaultSubject") private var defaultSubject = ""
  var body: some View {
    Form {
      Section {
        Label("Google", systemImage: "person.crop.circle")
          .font(.headline)
        if let account = signIn.account {
          Text(account.email).textSelection(.enabled)
          ForEach(GoogleService.allCases) { service in
            Label(
              service.title + (account.supports(service) ? " · Connected" : " · Not connected"),
              systemImage: account.supports(service) ? "checkmark.circle" : "minus.circle")
          }
        } else {
          Text("Connect Gmail and Google Drive to find answers in your email and files.")
        }
      }
      Section {
        ForEach(GoogleService.allCases) { service in
          Toggle(
            service.title,
            isOn: Binding(
              get: { services.contains(service) },
              set: {
                if $0 { services.insert(service) } else { services.remove(service) }
              }))
        }
        Button(signIn.account == nil ? "Connect Google account" : "Reconnect or change account") {
          signIn.connect(services: services)
        }
        .disabled(signIn.isBusy || !signIn.isConfigured || services.isEmpty)
        if signIn.isBusy {
          ProgressView("Connecting…")
          Button("Cancel sign-in") { signIn.cancel() }
        }
        if !signIn.isConfigured {
          Text(
            "Google account connection will be available after the app’s Google sign-in setup is complete."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
      } header: {
        Text("Allow read access")
      } footer: {
        Text(
          "Turing AI reads through Google’s APIs directly from this device. It cannot send email, change files, or delete items. Access stays on this device in Apple Keychain."
        )
      }
      if let account = signIn.account {
        Section {
          ForEach([GoogleService.gmail, .drive]) { service in
            Toggle(
              service.title,
              isOn: Binding(
                get: {
                  defaultSubject == account.subject
                    && defaultServices.split(separator: ",").contains(Substring(service.rawValue))
                },
                set: { enabled in
                  var selected =
                    defaultSubject == account.subject
                    ? Set(defaultServices.split(separator: ",").map(String.init)) : []
                  if enabled {
                    selected.insert(service.rawValue)
                  } else {
                    selected.remove(service.rawValue)
                  }
                  defaultSubject = account.subject
                  defaultServices = selected.sorted().joined(separator: ",")
                })
            )
            .disabled(!account.supports(service))
          }
        } header: {
          Text("Use in chats by default")
        } footer: {
          Text(
            "When your message needs email or files, send relevant search excerpts to the selected AI provider. Applies to chats without a custom choice. You can turn access off for any chat from + → Connections. Search and answer tokens count toward Usage & Cost."
          )
        }
      }
      Section {
        Text(
          "Connecting your Google account grants the app read access. Turn on Use in chats by default above, or enable a service for one chat from + → Connections."
        )
        Text(
          "Sources and answers saved in a chat follow your chat backup and iCloud settings. Your entire mailbox and Drive are never imported into memory."
        )
        Link(
          "Manage Google account access",
          destination: URL(string: "https://myaccount.google.com/connections")!)
      } header: {
        Text("About connected sources")
      }
      if signIn.account != nil {
        Section {
          Button("Disconnect from this device", role: .destructive) { confirmingDisconnect = true }
            .disabled(signIn.isBusy)
        } footer: {
          Text(
            "Removes this device’s access tokens. Previously saved answers and source links remain in chats. You can revoke Google’s permission separately using Manage Google account access."
          )
        }
      }
      if let error = signIn.error {
        Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Google")
    .task {
      await signIn.load()
      if let account = signIn.account {
        services = Set(GoogleService.allCases.filter { account.supports($0) })
      }
    }
    .onDisappear { signIn.cancel() }
    .confirmationDialog(
      "Disconnect Google from this device?", isPresented: $confirmingDisconnect,
      titleVisibility: .visible
    ) {
      Button("Disconnect", role: .destructive) { signIn.disconnect() }
    }
  }
}

struct GoogleChatConnectionsView: View {
  @Binding var otherSelection: ConnectorSelection
  @Environment(\.dismiss) private var dismiss
  @Binding var selection: Set<GoogleService>
  @Binding var selectedSubject: String
  let providerName: String
  @State private var signIn = GoogleSignInSession()
  var body: some View {
    NavigationStack {
      Form {
        Section {
          if let account = signIn.account {
            Text(account.email).font(.subheadline).foregroundStyle(.secondary)
            ForEach([GoogleService.gmail, .drive]) { service in
              Toggle(
                isOn: Binding(
                  get: { selection.contains(service) },
                  set: {
                    selectedSubject = account.subject
                    if $0 { selection.insert(service) } else { selection.remove(service) }
                  })
              ) { Label(service.title, systemImage: service.symbol) }
              .disabled(!account.supports(service))
            }
          } else {
            Text("Connect your Google account to search your email and files from this chat.")
          }
          NavigationLink("Manage connections") { GoogleConnectionsView() }
        } header: {
          Text("Use in this chat")
        } footer: {
          Text(
            "When relevant to your message, Turing AI searches the enabled services and sends selected excerpts to \(providerName). Search and answer tokens count toward Usage & Cost. These choices apply on this device."
          )
        }
        ConnectorChatSection(selection: $otherSelection)
        if let error = signIn.error { Text(error).foregroundStyle(.red) }
      }
      .navigationTitle("Connections")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .task {
        await signIn.load()
        if let account = signIn.account, !selectedSubject.isEmpty,
          account.subject != selectedSubject
        {
          selection = []
        }
      }
    }
    .presentationDetents([.medium, .large])
    #if os(macOS)
      .frame(minWidth: 480, minHeight: 460)
    #endif
  }
}

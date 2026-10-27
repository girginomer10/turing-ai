#if os(iOS)
  import Foundation
  import Observation
  import SwiftData
  import SwiftUI
  import TuringVoice
  @preconcurrency import WatchConnectivity

  @MainActor @Observable
  final class WatchCompanionCoordinator: NSObject, WCSessionDelegate {
    static let shared = WatchCompanionCoordinator()
    var status = "Open Turing AI on your Watch, then sync."
    var busy = false
    var enabled = UserDefaults.standard.bool(forKey: "watchVoiceAccessEnabled")
    private var context: ModelContext?
    var liveModelRevision = 0
    func liveEnabled(provider: UUID, model: String) -> Bool {
      UserDefaults.standard.object(forKey: "watchLive." + provider.uuidString + "." + model)
        as? Bool ?? true
    }
    func setLiveEnabled(_ enabled: Bool, provider: UUID, model: String) {
      UserDefaults.standard.set(enabled, forKey: "watchLive." + provider.uuidString + "." + model)
      liveModelRevision += 1
      status = "Sync to apply the live model selection on Watch."
    }
    func attach(_ context: ModelContext) {
      self.context = context
      guard WCSession.isSupported() else { return }
      WCSession.default.delegate = self
      if WCSession.default.activationState == .notActivated { WCSession.default.activate() }
    }
    func setEnabled(_ value: Bool) {
      enabled = value
      UserDefaults.standard.set(value, forKey: "watchVoiceAccessEnabled")
      try? WCSession.default.updateApplicationContext([
        "voiceAccess": value, "changedAt": Date().timeIntervalSince1970,
      ])
      if !value {
        status = "Access disabled. The Watch will remove copied keys when it reconnects."
      }
    }
    func sync() {
      guard enabled, !busy else { return }
      guard WCSession.default.isPaired, WCSession.default.isWatchAppInstalled,
        WCSession.default.isReachable
      else {
        status = "Install and open Turing AI on your paired Watch, then try again."
        return
      }
      busy = true
      status = "Syncing…"
      Task { @MainActor in
        do {
          let data = try await snapshot()
          guard enabled else { throw VoiceError.invalidConfiguration }
          let delivery = VoiceCallbackDelivery { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let reply):
              self.status =
                reply == Data("ok".utf8)
                ? "Models and keys synced to Apple Watch."
                : "Watch could not save the configuration. Unlock it and retry."
            case .failure: self.status = "Sync failed. Keep both apps open and try again."
            }
          }
          WCSession.default.sendMessageData(
            data, replyHandler: delivery.replyHandler, errorHandler: delivery.errorHandler)
        } catch {
          busy = false
          status = error.localizedDescription
        }
      }
    }
    private func snapshot() async throws -> Data {
      guard enabled, let context,
        MosaicOperationCoordinator.shared.beginVerifiedSourceSnapshotMaintenance()
      else {
        throw VoiceError.message("Finish active requests and try syncing again.")
      }
      defer { MosaicOperationCoordinator.shared.endExclusiveMaintenance() }
      let providers = try context.fetch(FetchDescriptor<ProviderConfigurationRecord>())
      let models = try context.fetch(FetchDescriptor<ProviderModelRecord>())
      let choices = ProviderModelStore.choices(providers: providers, models: models)
      var endpoints: [VoiceEndpoint] = []
      for provider in providers where provider.isEnabled && provider.provider.supportsChat {
        let connection = ProviderConnection(configuration: provider)
        guard let url = connection.resolvedBaseURL, url.scheme == "https",
          let key = try await SecurityKeychain.shared.apiKey(
            for: provider.id, expectedBinding: connection.credentialBinding), !key.isEmpty
        else { continue }
        endpoints.append(
          VoiceEndpoint(
            id: provider.id, provider: provider.provider.rawValue,
            name: provider.displayName, baseURL: url, apiKey: key,
            models: Array(
              Set(choices.filter { $0.providerID == provider.id }.map(\.modelIdentifier))
            ).sorted(),
            enabledLiveModels: VoiceEndpoint(
              id: provider.id, provider: provider.provider.rawValue, name: provider.displayName,
              baseURL: url, apiKey: key, models: []
            ).supportedLiveModels.filter {
              liveEnabled(provider: provider.id, model: $0)
            }))
      }
      guard enabled else { throw VoiceError.invalidConfiguration }
      let data = try JSONEncoder().encode(VoiceConfiguration(endpoints: endpoints).validated())
      guard data.count <= 60_000 else {
        throw VoiceError.message(
          "Too many enabled models for one Watch sync. Disable unused models and retry.")
      }
      return data
    }
    private func modelAllowed(providerID: UUID, model: String, in context: ModelContext) -> Bool {
      guard let providers = try? context.fetch(FetchDescriptor<ProviderConfigurationRecord>()),
        let provider = providers.first(where: { $0.id == providerID && $0.isEnabled }),
        let models = try? context.fetch(FetchDescriptor<ProviderModelRecord>())
      else { return false }
      let connection = ProviderConnection(configuration: provider)
      guard let url = connection.resolvedBaseURL, url.scheme == "https" else { return false }
      let endpoint = VoiceEndpoint(
        id: providerID, provider: provider.provider.rawValue, name: provider.displayName,
        baseURL: url, apiKey: "validation-only", models: [])
      if endpoint.supportedLiveModels.contains(model) {
        return liveEnabled(provider: providerID, model: model)
      }
      return ProviderModelStore.choices(providers: providers, models: models).contains {
        $0.providerID == providerID && $0.modelIdentifier == model
      }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
      guard let data = userInfo[WatchUsageDelivery.payloadKey] as? Data else { return }
      Task { @MainActor in
        guard enabled, let context else { return }
        do {
          let transfer = try WatchUsageDelivery.decode(data)
          let coordinator = MosaicOperationCoordinator.shared
          guard coordinator.beginVerifiedSourceSnapshotMaintenance() else { return }
          defer { coordinator.endExclusiveMaintenance() }
          let reply = try WatchPhoneLibrary(container: context.container).upload(
            transfer, commit: coordinator.flushSourceChangesForVerifiedSnapshot)
          WCSession.default.transferUserInfo([
            WatchUsageDelivery.receiptKey: try WatchSyncWire.encode(reply)
          ])
        } catch {
          // No acknowledgement until the durable save succeeds. Watch retains and retries its outbox.
          status = "Watch usage is waiting to sync. Open both apps to retry."
        }
      }
    }
    nonisolated func session(
      _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
      error: Error?
    ) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func session(
      _ session: WCSession, didReceiveMessageData messageData: Data,
      replyHandler: @escaping (Data) -> Void
    ) {
      let reply = CompanionReply(replyHandler)
      Task { @MainActor in
        if messageData == Data("request-voice-config-v1".utf8) {
          do { reply.send(try await snapshot()) } catch { reply.send(Data()) }
          return
        }
        do {
          let request = try WatchSyncWire.request(messageData)
          guard enabled, let context,
            MosaicOperationCoordinator.shared.beginVerifiedSourceSnapshotMaintenance()
          else {
            reply.send(try WatchSyncWire.encode(WatchSyncReply(status: "busy")))
            return
          }
          let library = WatchPhoneLibrary(container: context.container)
          let result: WatchSyncReply
          do {
            switch request.operation {
            case "upload":
              guard let transfer = request.transfer else { throw VoiceError.invalidConfiguration }
              result = try library.upload(
                transfer,
                commit: MosaicOperationCoordinator.shared.flushSourceChangesForVerifiedSnapshot)
            case "list":
              result = try library.list(before: request.before, beforeID: request.beforeID)
            case "context":
              guard let id = request.chatID else { throw VoiceError.invalidConfiguration }
              if let providerID = request.providerID, let model = request.model,
                !modelAllowed(providerID: providerID, model: model, in: context)
              {
                result = WatchSyncReply(status: "modelDisabled")
              } else if request.newChat {
                result = WatchSyncReply(
                  context: try await library.memoryContext(id: id, query: request.query ?? ""))
              } else {
                result = try await library.detail(
                  id: id, before: request.before, beforeID: request.beforeID,
                  query: request.query ?? "")
              }
            default: throw VoiceError.invalidConfiguration
            }
          } catch {
            MosaicOperationCoordinator.shared.endExclusiveMaintenance()
            throw error
          }
          MosaicOperationCoordinator.shared.endExclusiveMaintenance()
          guard enabled else { throw VoiceError.invalidConfiguration }
          reply.send(try WatchSyncWire.encode(result))
          if result.status == "ok", let transfer = request.transfer, transfer.message != nil {
            Task { await library.formPendingMemory(chatID: transfer.chat.id) }
          }
        } catch {
          reply.send((try? WatchSyncWire.encode(WatchSyncReply(status: "retry"))) ?? Data())
        }
      }
    }
  }
  private struct CompanionReply: @unchecked Sendable {
    let send: (Data) -> Void
    init(_ send: @escaping (Data) -> Void) { self.send = send }
  }

  struct WatchSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var providers: [ProviderConfigurationRecord]
    @State private var companion = WatchCompanionCoordinator.shared
    var body: some View {
      Form {
        Section {
          Toggle(
            "Apple Watch voice access",
            isOn: Binding(get: { companion.enabled }, set: { companion.setEnabled($0) }))
          Button("Sync models and keys to Watch", systemImage: "applewatch") { companion.sync() }
            .disabled(!companion.enabled || companion.busy)
          if companion.busy { ProgressView() }
          Text(companion.status).font(.footnote).foregroundStyle(.secondary)
        } footer: {
          Text(
            "Copies your enabled HTTPS providers and their API keys to your paired Watch’s secure Keychain. After setup, the Watch connects directly using its own internet connection. Resync after changing models or keys."
          )
        }
        Section("Live models") {
          ForEach(
            providers.filter { $0.isEnabled && ($0.provider == .openAI || $0.provider == .google) }
          ) { provider in
            let identifiers =
              provider.provider == .openAI
              ? ["gpt-realtime-2.1", "gpt-realtime-2.1-mini"] : ["gemini-3.1-flash-live-preview"]
            ForEach(identifiers, id: \.self) { model in
              Toggle(
                isOn: Binding(
                  get: {
                    _ = companion.liveModelRevision
                    return companion.liveEnabled(provider: provider.id, model: model)
                  }, set: { companion.setLiveEnabled($0, provider: provider.id, model: model) })
              ) {
                VStack(alignment: .leading) {
                  Text(model)
                  Text(provider.displayName).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          }
          Text(
            "Recorded conversations use the enabled models in Providers. Change models on Watch without losing conversation history. Sync after changing this selection."
          ).font(.footnote).foregroundStyle(.secondary)
        }
        Section("Two ways to talk") {
          Label("Live conversation · OpenAI or Gemini", systemImage: "waveform")
          Label("Record → review transcript → send → hear the answer", systemImage: "mic")
          Text(
            "Recorded mode uses OpenAI for transcription and AI-generated speech, with any synced chat model for the answer. Requires your own provider balance. Watch chat, live audio, transcription and speech are included in Usage & Cost after syncing. Missing provider usage is marked as incomplete."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
          Text(
            "Watch and iPhone share saved conversations. Watch keeps an offline copy and queues messages and usage until iPhone is reachable. Relevant memory is fetched from iPhone before a request; saved Watch turns use the same automatic memory setting. Your existing iCloud library carries synced conversations to your other devices. Raw recordings are removed after transcription or cancellation."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Apple Watch")
      .onAppear { companion.attach(context) }
    }
  }
#endif

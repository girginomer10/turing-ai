import Foundation
import SwiftUI

/// Editorial guidance, never evidence of the connected account's plan, remaining quota or price.
/// Recheck the linked official sources before updating any model or allowance.
struct FreeProviderOption: Identifiable {
  let provider: ProviderKind
  let modelID: String
  let models: String
  let allowance: String
  let setup: String
  let payment: String
  let dataUse: String
  let setupURL: URL
  let limitsURL: URL
  let termsURL: URL
  let privacyURL: URL
  var id: String { provider.rawValue }

  static let checkedOn = "2026-09-07"
  static let options: [Self] = [
    .init(
      provider: .groq, modelID: "openai/gpt-oss-20b",
      models: "GPT-OSS 20B and 120B",
      allowance:
        "Published Free Plan limits for each listed model: 30 requests/minute, 1,000 requests/day, 8,000 tokens/minute and 200,000 tokens/day. Limits are shared within your organization; any limit can stop requests earlier.",
      setup:
        "Sign in or create a GroqCloud account. Create an API key in the console, then return here to add it.",
      payment:
        "Choose the Free Plan. Check your account before enabling paid services; this guide cannot verify your billing plan.",
      dataUse:
        "Groq retains usage metadata. Inference content is not retained by default, with exceptions for certain features, troubleshooting and abuse investigation. Review your data controls.",
      setupURL: URL(string: "https://console.groq.com/docs/quickstart")!,
      limitsURL: URL(string: "https://console.groq.com/docs/rate-limits")!,
      termsURL: URL(string: "https://console.groq.com/docs/legal")!,
      privacyURL: URL(string: "https://console.groq.com/docs/your-data")!
    ),
    .init(
      provider: .google, modelID: "gemini-3.5-flash-lite",
      models: "Gemini 3.5 Flash-Lite",
      allowance:
        "A free API tier is listed for this model. Exact request and token limits depend on your project and are shown in AI Studio. Quotas are per project, not per key; capacity is not guaranteed.",
      setup:
        "Use your Google account to sign in to AI Studio. Review Google's terms, create or select a project, and create an API key. Your Gmail connection in Turing does not create this key.",
      payment:
        "Check that your project is on Free Tier. Linking billing changes the project's plan; a free-tier model can still be billed on a paid project.",
      dataUse:
        "Google's unpaid-service terms allow product improvement and human review of content and say not to submit personal, sensitive or confidential information. Regional exceptions apply. The terms require age 18+ and paid services for API clients made available to users in the EEA, UK or Switzerland. Adding your own key does not remove these restrictions. Review memory and connection access before sending anything.",
      setupURL: URL(string: "https://ai.google.dev/gemini-api/docs/api-key")!,
      limitsURL: URL(string: "https://ai.google.dev/gemini-api/docs/rate-limits")!,
      termsURL: URL(string: "https://ai.google.dev/gemini-api/terms")!,
      privacyURL: URL(string: "https://ai.google.dev/gemini-api/docs/pricing")!
    ),
    .init(
      provider: .openRouter, modelID: "openrouter/free",
      models: "Free model router · openrouter/free",
      allowance:
        "The published free-model allowance is 50 requests/day across free models for accounts below the purchase threshold. The FAQ lists 1,000/day after purchasing at least 10 credits. Availability varies; this guide does not show your remaining allowance.",
      setup:
        "Sign in or create an OpenRouter account, then create an API key. Add it here and keep the free router or select a currently listed :free model variant.",
      payment:
        "Free variants are separate from paid models. The larger free-model allowance requires a purchase; it is not the zero-spend starting allowance.",
      dataUse:
        "OpenRouter forwards requests to model providers. Retention and training policies differ by the selected provider; review the model's policy and your privacy settings before including private information.",
      setupURL: URL(string: "https://openrouter.ai/settings/keys")!,
      limitsURL: URL(string: "https://openrouter.ai/docs/faq")!,
      termsURL: URL(string: "https://openrouter.ai/terms")!,
      privacyURL: URL(string: "https://openrouter.ai/privacy")!
    ),
    .init(
      provider: .mistral, modelID: "mistral-small-latest",
      models: "Mistral Small · check current account access",
      allowance:
        "Studio Free mode includes limited API usage for evaluation. Current model access and usage limits are shown in your account; no fixed remaining allowance is assumed here.",
      setup:
        "Sign in or create a Mistral account. Open Studio > API Keys > Create new key. Set a name and expiry, copy the key, and return here.",
      payment:
        "Mistral's setup guide lists Free mode with no credit card required. Verify the mode in your own account before using the API.",
      dataUse:
        "Review Mistral's current service terms and privacy information for your account and plan before sending personal data. Free usage is not a promise of private processing.",
      setupURL: URL(
        string:
          "https://docs.mistral.ai/getting-started/quickstarts/studio/activate-and-generate-api-key"
      )!,
      limitsURL: URL(string: "https://docs.mistral.ai/admin/billing-usage/usage-limits")!,
      termsURL: URL(string: "https://legal.mistral.ai/terms/get-started/")!,
      privacyURL: URL(string: "https://legal.mistral.ai/terms/get-started/")!
    ),
  ]
}

struct FreeProviderGuideView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("Start with your own free account")
            .font(.title2.bold())
          Text(
            "Choose a service, get your own API key, then add it to Turing. Your key stays in Apple Keychain; requests use your provider account. Turing does not supply credits or create accounts for you."
          )
        }
        Section("Explore services") {
          ForEach(FreeProviderOption.options) { option in
            NavigationLink {
              FreeProviderDetailView(option: option)
            } label: {
              HStack(alignment: .top, spacing: 12) {
                ProviderLogoTile(provider: option.provider, size: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                  Text(option.provider.displayName).font(.headline)
                  Text(option.models).font(.subheadline).foregroundStyle(.secondary)
                  Text("Free plan available · conditions apply").font(.caption).foregroundStyle(
                    .secondary)
                }
              }
              .padding(.vertical, 6)
            }
            .accessibilityIdentifier("freeOptions.\(option.id)")
          }
        }
        Section {
          Text(
            "Published allowances are not your remaining quota. One chat message can trigger several API requests for memory or tools. Your other apps may use the same account limits."
          )
          Text(
            "A free plan listing does not verify your key's billing plan. Check the official pages and your account before sending requests. This guide never switches your plan or accepts provider terms for you."
          )
        } header: {
          Text("Before you connect")
        } footer: {
          Text(
            "Sources checked \(FreeProviderOption.checkedOn). Models, availability and limits can change. Open a service to check its current official information."
          )
        }
      }
      .navigationTitle("Free options")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
    #if os(macOS)
      .frame(minWidth: 440, idealWidth: 540, minHeight: 480, idealHeight: 640)
    #endif
  }
}

private struct FreeProviderDetailView: View {
  let option: FreeProviderOption
  @State private var addingKey = false

  var body: some View {
    List {
      Section("Models") {
        Text(option.models).font(.headline)
        Text(option.allowance)
        Link("Official models and limits", destination: option.limitsURL)
        if option.provider == .google {
          Link("Model pricing and free-tier availability", destination: option.privacyURL)
        }
      }
      Section("1. Get your key") {
        Text(option.setup)
        Text(option.payment).foregroundStyle(.secondary)
        Link("Open official key setup", destination: option.setupURL)
          .frame(minHeight: 44)
      }
      Section("Data and eligibility") {
        Text(option.dataUse)
        Link("Provider terms", destination: option.termsURL)
        if option.provider != .google {
          Link("Privacy and data information", destination: option.privacyURL)
        }
      }
      Section {
        Text(
          "After creating your key, add it using the existing secure connection form. Check which models are enabled before saving. Turing cannot verify that the key is on a free plan."
        )
        Button("Add my API key", systemImage: "key") { addingKey = true }
          .frame(minHeight: 44)
          .accessibilityIdentifier("freeOptions.addKey")
      } header: {
        Text("2. Connect to Turing")
      } footer: {
        Text(
          "Sources checked \(FreeProviderOption.checkedOn). These are published plan details, not a live quota meter or a guarantee of free access."
        )
      }
    }
    .navigationTitle(option.provider.displayName)
    .sheet(isPresented: $addingKey) {
      ProviderConfigurationEditorView(configuration: nil, suggestion: option)
    }
  }
}

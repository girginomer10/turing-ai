package com.omergirgin.mosaic.ui.providers

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.core.provider.profile
import com.omergirgin.mosaic.ui.components.ProviderLogo
import com.omergirgin.mosaic.ui.settings.EmptyState
import com.omergirgin.mosaic.ui.settings.ExternalLinkRow
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsParagraph
import com.omergirgin.mosaic.ui.settings.SettingsScaffold

/**
 * Editorial guidance, never evidence of the connected account's plan, remaining quota or price.
 * Recheck the linked official sources before updating any model or allowance (same content and
 * date as iOS FreeProviderGuideView).
 */
internal data class FreeProviderOption(
  val kind: ProviderKind,
  val modelId: String,
  val models: String,
  val allowance: String,
  val setup: String,
  val payment: String,
  val dataUse: String,
  val setupUrl: String,
  val limitsUrl: String,
  val termsUrl: String,
  val privacyUrl: String,
) {
  companion object {
    const val CHECKED_ON = "2026-09-07"

    val options: List<FreeProviderOption> = listOf(
      FreeProviderOption(
        kind = ProviderKind.GROQ,
        modelId = "openai/gpt-oss-20b",
        models = "GPT-OSS 20B and 120B",
        allowance = "Published Free Plan limits for each listed model: 30 requests/minute, 1,000 requests/day, " +
          "8,000 tokens/minute and 200,000 tokens/day. Limits are shared within your organization; any limit " +
          "can stop requests earlier.",
        setup = "Sign in or create a GroqCloud account. Create an API key in the console, then return here to add it.",
        payment = "Choose the Free Plan. Check your account before enabling paid services; this guide cannot " +
          "verify your billing plan.",
        dataUse = "Groq retains usage metadata. Inference content is not retained by default, with exceptions for " +
          "certain features, troubleshooting and abuse investigation. Review your data controls.",
        setupUrl = "https://console.groq.com/docs/quickstart",
        limitsUrl = "https://console.groq.com/docs/rate-limits",
        termsUrl = "https://console.groq.com/docs/legal",
        privacyUrl = "https://console.groq.com/docs/your-data",
      ),
      FreeProviderOption(
        kind = ProviderKind.GOOGLE,
        modelId = "gemini-3.5-flash-lite",
        models = "Gemini 3.5 Flash-Lite",
        allowance = "A free API tier is listed for this model. Exact request and token limits depend on your " +
          "project and are shown in AI Studio. Quotas are per project, not per key; capacity is not guaranteed.",
        // iOS also notes that its Gmail connection does not create this key; Android has no Gmail
        // connection, so that sentence is omitted here.
        setup = "Use your Google account to sign in to AI Studio. Review Google's terms, create or select a " +
          "project, and create an API key.",
        payment = "Check that your project is on Free Tier. Linking billing changes the project's plan; a " +
          "free-tier model can still be billed on a paid project.",
        dataUse = "Google's unpaid-service terms allow product improvement and human review of content and say " +
          "not to submit personal, sensitive or confidential information. Regional exceptions apply. The terms " +
          "require age 18+ and paid services for API clients made available to users in the EEA, UK or " +
          "Switzerland. Adding your own key does not remove these restrictions. Review memory and connection " +
          "access before sending anything.",
        setupUrl = "https://ai.google.dev/gemini-api/docs/api-key",
        limitsUrl = "https://ai.google.dev/gemini-api/docs/rate-limits",
        termsUrl = "https://ai.google.dev/gemini-api/terms",
        privacyUrl = "https://ai.google.dev/gemini-api/docs/pricing",
      ),
      FreeProviderOption(
        kind = ProviderKind.OPENROUTER,
        // The free router, never a paid default (PRODUCT.md free-provider guide).
        modelId = "openrouter/free",
        models = "Free model router · openrouter/free",
        allowance = "The published free-model allowance is 50 requests/day across free models for accounts " +
          "below the purchase threshold. The FAQ lists 1,000/day after purchasing at least 10 credits. " +
          "Availability varies; this guide does not show your remaining allowance.",
        setup = "Sign in or create an OpenRouter account, then create an API key. Add it here and keep the free " +
          "router or select a currently listed :free model variant.",
        payment = "Free variants are separate from paid models. The larger free-model allowance requires a " +
          "purchase; it is not the zero-spend starting allowance.",
        dataUse = "OpenRouter forwards requests to model providers. Retention and training policies differ by the " +
          "selected provider; review the model's policy and your privacy settings before including private " +
          "information.",
        setupUrl = "https://openrouter.ai/settings/keys",
        limitsUrl = "https://openrouter.ai/docs/faq",
        termsUrl = "https://openrouter.ai/terms",
        privacyUrl = "https://openrouter.ai/privacy",
      ),
      FreeProviderOption(
        kind = ProviderKind.MISTRAL,
        modelId = "mistral-small-latest",
        models = "Mistral Small · check current account access",
        allowance = "Studio Free mode includes limited API usage for evaluation. Current model access and usage " +
          "limits are shown in your account; no fixed remaining allowance is assumed here.",
        setup = "Sign in or create a Mistral account. Open Studio > API Keys > Create new key. Set a name and " +
          "expiry, copy the key, and return here.",
        payment = "Mistral's setup guide lists Free mode with no credit card required. Verify the mode in your " +
          "own account before using the API.",
        dataUse = "Review Mistral's current service terms and privacy information for your account and plan " +
          "before sending personal data. Free usage is not a promise of private processing.",
        setupUrl = "https://docs.mistral.ai/getting-started/quickstarts/studio/activate-and-generate-api-key",
        limitsUrl = "https://docs.mistral.ai/admin/billing-usage/usage-limits",
        termsUrl = "https://legal.mistral.ai/terms/get-started/",
        privacyUrl = "https://legal.mistral.ai/terms/get-started/",
      ),
    )

    fun forKind(kind: ProviderKind?): FreeProviderOption? = options.firstOrNull { it.kind == kind }
  }
}

@Composable
internal fun FreeProviderGuideScreen(onBack: () -> Unit, onOpenOption: (ProviderKind) -> Unit) {
  SettingsScaffold(title = "Free options", onBack = onBack) { padding ->
    LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 32.dp)) {
      item(key = "intro") {
        Text(
          "Start with your own free account",
          style = MaterialTheme.typography.headlineSmall,
          modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp).semantics { heading() },
        )
        SettingsParagraph(
          "Choose a service, get your own API key, then add it to Turing. Your key stays on this device, " +
            "protected by Android Keystore; requests use your provider account. Turing does not supply credits " +
            "or create accounts for you.",
        )
      }
      item(key = "services-header") { SectionHeader("Explore services") }
      items(FreeProviderOption.options, key = { it.kind.rawId }) { option ->
        ListItem(
          leadingContent = { ProviderLogo(option.kind, size = 36.dp) },
          headlineContent = { Text(option.kind.profile.displayName) },
          supportingContent = { Text("${option.models}\nFree plan available · conditions apply") },
          trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
          modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 72.dp)
            .clickable(role = Role.Button) { onOpenOption(option.kind) },
        )
      }
      item(key = "before") {
        SectionHeader("Before you connect")
        SettingsParagraph(
          "Published allowances are not your remaining quota. One chat message can trigger several API requests " +
            "for memory or tools. Your other apps may use the same account limits.",
        )
        SettingsParagraph(
          "A free plan listing does not verify your key's billing plan. Check the official pages and your account " +
            "before sending requests. This guide never switches your plan or accepts provider terms for you.",
        )
        SectionFooter(
          "Sources checked ${FreeProviderOption.CHECKED_ON}. Models, availability and limits can change. Open a " +
            "service to check its current official information.",
        )
      }
    }
  }
}

@Composable
internal fun FreeProviderDetailScreen(
  kind: ProviderKind?,
  onBack: () -> Unit,
  onAddKey: (ProviderKind, String) -> Unit,
) {
  val option = FreeProviderOption.forKind(kind)
  SettingsScaffold(title = option?.kind?.profile?.displayName ?: "Free options", onBack = onBack) { padding ->
    if (option == null) {
      EmptyState(
        title = "Guide unavailable",
        message = "This service is no longer part of the free options guide.",
        modifier = Modifier.padding(padding),
      ) { OutlinedButton(onClick = onBack) { Text("Go back") } }
      return@SettingsScaffold
    }
    LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 32.dp)) {
      item(key = "models") {
        SectionHeader("Models")
        Text(
          option.models,
          style = MaterialTheme.typography.titleMedium,
          modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
        )
        SettingsParagraph(option.allowance)
        ExternalLinkRow("Official models and limits", option.limitsUrl)
        if (option.kind == ProviderKind.GOOGLE) {
          ExternalLinkRow("Model pricing and free-tier availability", option.privacyUrl)
        }
      }
      item(key = "key") {
        SectionHeader("1. Get your key")
        SettingsParagraph(option.setup)
        SettingsParagraph(option.payment, color = MaterialTheme.colorScheme.onSurfaceVariant)
        ExternalLinkRow("Open official key setup", option.setupUrl)
      }
      item(key = "data") {
        SectionHeader("Data and eligibility")
        SettingsParagraph(option.dataUse)
        ExternalLinkRow("Provider terms", option.termsUrl)
        if (option.kind != ProviderKind.GOOGLE) {
          ExternalLinkRow("Privacy and data information", option.privacyUrl)
        }
      }
      item(key = "connect") {
        SectionHeader("2. Connect to Turing")
        SettingsParagraph(
          "After creating your key, add it using the secure connection form. Check which models are enabled " +
            "before saving. Turing cannot verify that the key is on a free plan.",
        )
        Button(
          onClick = { onAddKey(option.kind, option.modelId) },
          modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp).heightIn(min = 48.dp),
        ) {
          Icon(Icons.Outlined.Key, contentDescription = null)
          Spacer(Modifier.width(8.dp))
          Text("Add my API key")
        }
        HorizontalDivider(Modifier.padding(top = 8.dp))
        SectionFooter(
          "Sources checked ${FreeProviderOption.CHECKED_ON}. These are published plan details, not a live quota " +
            "meter or a guarantee of free access.",
        )
      }
    }
  }
}

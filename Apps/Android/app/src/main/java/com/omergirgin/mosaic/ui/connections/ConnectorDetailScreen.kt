package com.omergirgin.mosaic.ui.connections

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.core.connections.ConnectorException
import com.omergirgin.mosaic.core.connections.ConnectorId
import com.omergirgin.mosaic.data.connections.ConnectionStatus
import com.omergirgin.mosaic.data.connections.SignInState
import com.omergirgin.mosaic.data.model.AppSettings
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.settings.ConfirmDialog
import com.omergirgin.mosaic.ui.settings.ExternalLinkRow
import com.omergirgin.mosaic.ui.settings.SectionFooter
import com.omergirgin.mosaic.ui.settings.SectionHeader
import com.omergirgin.mosaic.ui.settings.SettingsParagraph
import com.omergirgin.mosaic.ui.settings.SettingsScaffold
import com.omergirgin.mosaic.ui.settings.SettingsSwitchRow
import com.omergirgin.mosaic.ui.settings.StatusLine
import com.omergirgin.mosaic.ui.settings.StatusTone
import com.omergirgin.mosaic.ui.settings.openExternalUrl
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Token verification, OAuth sign-in, device permission, chat defaults and disconnect for one service. */
@Composable
internal fun ConnectorDetailScreen(service: ConnectorId, onBack: () -> Unit) {
  val container = LocalAppContainer.current
  val repository = container.connections
  val context = LocalContext.current
  val scope = rememberCoroutineScope()
  val statuses by remember(repository) { repository.observeStatuses() }.collectAsStateWithLifecycle(initialValue = null)
  val defaults by remember(repository) { repository.observeDefaults() }.collectAsStateWithLifecycle(initialValue = null)
  val settings by remember(container) { container.settings.settings }.collectAsStateWithLifecycle(initialValue = AppSettings())
  val signIn by repository.signIn.collectAsStateWithLifecycle()
  val status = statuses?.firstOrNull { it.service == service }
  var token by remember { mutableStateOf("") }
  var busy by remember { mutableStateOf(false) }
  var job by remember { mutableStateOf<Job?>(null) }
  var error by remember { mutableStateOf<String?>(null) }
  var confirmingDisconnect by rememberSaveable { mutableStateOf(false) }
  var clientIdDraft by rememberSaveable(service) { mutableStateOf(repository.developerClientId(service)) }
  var clientIdVersion by remember { mutableIntStateOf(0) }
  val effectiveClientId = remember(service, clientIdVersion) { repository.effectiveClientId(service) }
  val needsSetup = service.needsClientRegistration && effectiveClientId.isBlank()
  val signInActive = signIn.let {
    (it is SignInState.Preparing && it.service == service) || (it is SignInState.InBrowser && it.service == service) ||
      (it is SignInState.Finishing && it.service == service)
  }

  LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { repository.refreshStatuses() }
  // Leaving the screen cancels in-flight verification and forgets the typed token.
  DisposableEffect(Unit) { onDispose { job?.cancel(); token = "" } }
  LaunchedEffect(signIn) {
    val state = signIn
    if (state is SignInState.Failed && state.service.credentialKey == service.credentialKey) {
      error = state.message
      repository.acknowledgeSignIn()
    } else if (state is SignInState.Completed && state.service.credentialKey == service.credentialKey) {
      error = null
      repository.acknowledgeSignIn()
    }
  }

  fun run(block: suspend () -> Unit) {
    if (busy) return
    busy = true
    error = null
    job = scope.launch {
      try {
        block()
      } catch (cancelled: CancellationException) {
        throw cancelled
      } catch (failure: ConnectorException) {
        error = failure.message
      } catch (_: Exception) {
        error = "The connection could not be completed. Please try again."
      } finally {
        busy = false
      }
    }
  }

  // A denied permission surfaces as DENIED from connectDevice and creates no connection.
  val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
    run { repository.connectDevice(service) }
  }

  SettingsScaffold(title = service.title, onBack = onBack) { padding ->
    LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 32.dp)) {
      item(key = "header") {
        ListItem(
          leadingContent = { Icon(service.icon, contentDescription = null) },
          headlineContent = { Text(service.title, style = MaterialTheme.typography.titleMedium) },
          supportingContent = { Text(status.summary(needsSetup)) },
        )
        val label = status?.label
        if (status?.generation != null && !service.isDevice && !label.isNullOrBlank()) SettingsParagraph(label)
      }

      when {
        service.isDevice -> item(key = "device") {
          DeviceSection(service, status, busy) { permissionLauncher.launch(repository.devicePermissions(service)) }
        }
        else -> {
          if (service.supportsOAuth) item(key = "oauth") {
            OAuthSection(
              service = service,
              connected = status?.generation != null,
              needsSetup = needsSetup,
              signIn = signIn,
              enabled = !busy && !signInActive,
              onSignIn = {
                run {
                  val url = repository.beginSignIn(service)
                  openAuthorization(context, url)
                }
              },
              onCancel = { repository.cancelSignIn() },
            )
          }
          if (service.needsClientRegistration && settings.advancedControls) item(key = "setup") {
            DeveloperSetup(
              service = service,
              value = clientIdDraft,
              onValueChange = { clientIdDraft = it },
              onSave = {
                run {
                  repository.setDeveloperClientId(service, clientIdDraft)
                  clientIdVersion++
                }
              },
            )
          }
          if (service.supportsToken) item(key = "token") {
            TokenSection(
              service = service,
              token = token,
              onTokenChange = { token = it },
              enabled = !busy && !signInActive,
              onVerify = {
                val secret = token
                run {
                  try {
                    repository.connectWithToken(service, secret)
                  } finally {
                    token = ""
                  }
                }
              },
            )
          }
        }
      }

      if (busy) item(key = "busy") {
        Row(
          Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
          verticalAlignment = Alignment.CenterVertically,
          horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
          CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
          Text("Connecting…", modifier = Modifier.weight(1f))
          TextButton(onClick = { job?.cancel(); repository.cancelSignIn() }) { Text("Cancel") }
        }
      }
      error?.let { message ->
        item(key = "error") {
          StatusLine(message, StatusTone.ERROR)
          if (service.isDevice) {
            TextButton(onClick = { openAppSettings(context) }, modifier = Modifier.padding(horizontal = 8.dp)) {
              Text("Open app settings")
            }
          }
        }
      }

      val generation = status?.generation
      if (generation != null) {
        item(key = "default") {
          SectionHeader("Chats")
          SettingsSwitchRow(
            title = "Use in chats by default",
            checked = defaults?.bindings?.get(service) == generation,
            enabled = status.isConnected,
            onCheckedChange = { enabled ->
              scope.launch {
                runCatching { withContext(NonCancellable) { repository.setDefault(service, enabled) } }
                  .onFailure { error = (it as? ConnectorException)?.message ?: "The setting couldn't be saved." }
              }
            },
          )
          SectionFooter(
            "When relevant to a message, selected results go to that chat's AI provider. Change access for one chat " +
              "from + → Connections. Planner and answer tokens count toward Usage & cost.",
          )
        }
      }

      item(key = "actions") {
        SectionHeader("Available actions")
        SettingsParagraph(capabilities(service))
        if (service.isDevice || service.mcpUrl != null || service == ConnectorId.TODOIST) {
          SectionFooter(
            "Actions that change data require a review of the exact request before they run. Some unfamiliar remote " +
              "tools also ask for review.",
          )
        }
        if (service.isMicrosoft) {
          SectionFooter(
            "Outlook, Microsoft To Do and OneDrive share one Microsoft sign-in. Each service has its own chat access " +
              "switch. Organization policies may require administrator consent.",
          )
        }
      }

      if (generation != null) {
        item(key = "disconnect") {
          HorizontalDivider(Modifier.padding(top = 16.dp))
          TextButton(
            onClick = { confirmingDisconnect = true },
            enabled = !busy,
            modifier = Modifier.padding(horizontal = 8.dp).heightIn(min = 48.dp),
          ) { Text("Disconnect from this device", color = MaterialTheme.colorScheme.error) }
          SectionFooter(
            if (service.isDevice) {
              "Stops access in Turing AI. Manage the Android permission separately in system settings. Saved answers remain in chats."
            } else {
              "Removes this device's credentials and stops new requests. Saved answers remain in chats. Revoke the " +
                "service's permission separately in your account settings."
            },
          )
        }
      }
    }
  }

  if (confirmingDisconnect) {
    ConfirmDialog(
      title = if (service.isMicrosoft) "Disconnect Microsoft and its services from this device?" else "Disconnect ${service.title}?",
      message = "Chats stop using this connection. Saved answers stay in your chats.",
      confirmLabel = "Disconnect",
      onConfirm = {
        confirmingDisconnect = false
        scope.launch {
          runCatching { withContext(NonCancellable) { repository.disconnect(service) } }
            .onFailure { error = "The connection could not be removed from this device." }
        }
      },
      onDismiss = { confirmingDisconnect = false },
    )
  }
}

@Composable
private fun DeviceSection(service: ConnectorId, status: ConnectionStatus?, busy: Boolean, onAllow: () -> Unit) {
  Column {
    SettingsParagraph(
      if (service == ConnectorId.DEVICE_CALENDAR) {
        "Uses calendars available on this device through Android's calendar provider, including accounts synced to " +
          "it. Nothing is copied to a separate server."
      } else {
        "Uses contacts stored on this device through Android's contacts provider, including synced accounts. " +
          "Nothing is copied to a separate server."
      },
    )
    Button(
      onClick = onAllow,
      enabled = !busy,
      modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp).heightIn(min = 48.dp),
    ) { Text(if (status?.generation == null) "Allow access" else "Check permission") }
    SectionFooter("Android asks for permission only after you tap the button. A denied permission doesn't create a connection.")
  }
}

@Composable
private fun OAuthSection(
  service: ConnectorId,
  connected: Boolean,
  needsSetup: Boolean,
  signIn: SignInState,
  enabled: Boolean,
  onSignIn: () -> Unit,
  onCancel: () -> Unit,
) {
  Column {
    Button(
      onClick = onSignIn,
      enabled = enabled && !needsSetup,
      modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp).heightIn(min = 48.dp),
    ) { Text(if (connected) "Reconnect or change account" else "Sign in") }
    when {
      needsSetup -> SectionFooter(
        "Sign-in isn't available in this build: Turing AI hasn't been registered with " +
          (if (service.isMicrosoft) "Microsoft" else "Dropbox") + " yet. The app uses a public client with no secret, " +
          "and people sign in to that one registration. Developer setup is available with advanced controls in Settings.",
      )
      signIn is SignInState.InBrowser && signIn.service.credentialKey == service.credentialKey -> {
        StatusLine("Finish signing in in the browser. You'll return here automatically.", StatusTone.NEUTRAL)
        TextButton(onClick = onCancel, modifier = Modifier.padding(horizontal = 8.dp)) { Text("Cancel sign-in") }
      }
      signIn is SignInState.Finishing && signIn.service.credentialKey == service.credentialKey ->
        StatusLine("Verifying the account…", StatusTone.NEUTRAL)
      service.mcpUrl != null -> SectionFooter(
        "Opens ${service.title}'s own sign-in page. The app registers itself as a public client with " +
          "${service.title}; some organizations must approve new apps first.",
      )
    }
  }
}

@Composable
private fun DeveloperSetup(service: ConnectorId, value: String, onValueChange: (String) -> Unit, onSave: () -> Unit) {
  Column {
    SectionHeader("Connection setup (developer)")
    OutlinedTextField(
      value = value,
      onValueChange = onValueChange,
      singleLine = true,
      label = { Text("Public client ID") },
      modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
    )
    SectionFooter(
      "Register Turing AI once as a native public app. No client secret is used. Redirect: ${service.redirectUri}",
    )
    OutlinedButton(onClick = onSave, modifier = Modifier.padding(horizontal = 16.dp).heightIn(min = 48.dp)) {
      Text("Save public client ID")
    }
    ExternalLinkRow("Open developer settings", service.helpUrl)
  }
}

@Composable
private fun TokenSection(service: ConnectorId, token: String, onTokenChange: (String) -> Unit, enabled: Boolean, onVerify: () -> Unit) {
  Column {
    SectionHeader("Personal account token")
    OutlinedTextField(
      value = token,
      onValueChange = onTokenChange,
      singleLine = true,
      label = { Text("Access token") },
      visualTransformation = PasswordVisualTransformation(),
      keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
      enabled = enabled,
      modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
    )
    Button(
      onClick = onVerify,
      enabled = enabled && token.isNotBlank(),
      modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp).heightIn(min = 48.dp),
    ) { Text("Verify and connect") }
    ExternalLinkRow("Get a token from ${service.title}", service.helpUrl)
    SectionFooter(
      "Use a token for your own account with only the permissions you want to grant. The token is verified with " +
        "${service.title} before it is stored on this device.",
    )
  }
}

private fun capabilities(service: ConnectorId): String = when {
  service == ConnectorId.DEVICE_CALENDAR ->
    "Search events by date and text. Create an event in a chosen calendar after review. Invitations and recurring-event changes are not enabled."
  service == ConnectorId.DEVICE_CONTACTS ->
    "Find contacts by name. Create a contact after review. Contact notes are not read."
  service.mcpUrl != null ->
    "Uses ${service.title}'s hosted MCP service. Available search, read and change tools are discovered from the permissions granted to your account."
  service == ConnectorId.TODOIST ->
    "Find projects and tasks, search by date or filter, read comments, create tasks and complete tasks."
  service == ConnectorId.ONEDRIVE || service == ConnectorId.DROPBOX ->
    "Search and browse files. Read selected small text, Markdown, CSV, JSON and PDF files. PDF extraction is limited to selectable text; scans and Office documents are not parsed."
  else ->
    "Search and read permitted records with date filters and pagination where the service supports them. Changes are not enabled for this connection."
}

/** The browser leg runs in a Custom Tab; the redirect returns to OAuthRedirectActivity. */
private fun openAuthorization(context: Context, url: String) {
  try {
    CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, url.toUri())
  } catch (_: ActivityNotFoundException) {
    openExternalUrl(context, url)
  }
}

private fun openAppSettings(context: Context) {
  val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
  runCatching { context.startActivity(intent) }
}

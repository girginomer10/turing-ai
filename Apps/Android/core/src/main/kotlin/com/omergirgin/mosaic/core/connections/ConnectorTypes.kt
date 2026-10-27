package com.omergirgin.mosaic.core.connections

import com.omergirgin.mosaic.core.chat.WebSource
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** Icon family for a catalog entry (the UI maps it to an icon). */
enum class ConnectorKind { CALENDAR, TASKS, CONTACTS, MAIL, FILES, CODE, CLOUD, BOOKMARKS, TABLE, WORKSPACE }

/**
 * Stable identifiers are device settings, never credentials.
 *
 * Android catalog differences from iOS: Google (Gmail, Drive, Calendar, Tasks) is not available on
 * Android yet; Apple Reminders has no Android system equivalent and is absent; Apple Calendar and
 * Contacts map to the Android Calendar and Contacts providers ([DEVICE_CALENDAR], [DEVICE_CONTACTS]).
 */
enum class ConnectorId(val rawId: String, val title: String, val kind: ConnectorKind) {
  TODOIST("todoist", "Todoist", ConnectorKind.TASKS),
  LINEAR("linear", "Linear", ConnectorKind.WORKSPACE),
  NOTION("notion", "Notion", ConnectorKind.WORKSPACE),
  ATLASSIAN("atlassian", "Jira & Confluence", ConnectorKind.WORKSPACE),
  CLOUDFLARE("cloudflare", "Cloudflare", ConnectorKind.CLOUD),
  GITHUB("github", "GitHub", ConnectorKind.CODE),
  OUTLOOK_MAIL("outlookMail", "Outlook Mail", ConnectorKind.MAIL),
  OUTLOOK_CALENDAR("outlookCalendar", "Outlook Calendar", ConnectorKind.CALENDAR),
  OUTLOOK_CONTACTS("outlookContacts", "Outlook Contacts", ConnectorKind.CONTACTS),
  MICROSOFT_TODO("microsoftToDo", "Microsoft To Do", ConnectorKind.TASKS),
  ONEDRIVE("oneDrive", "OneDrive", ConnectorKind.FILES),
  DROPBOX("dropbox", "Dropbox", ConnectorKind.FILES),
  READWISE("readwise", "Readwise", ConnectorKind.BOOKMARKS),
  AIRTABLE("airtable", "Airtable", ConnectorKind.TABLE),
  CLICKUP("clickup", "ClickUp", ConnectorKind.TASKS),
  RAINDROP("raindrop", "Raindrop.io", ConnectorKind.BOOKMARKS),
  DEVICE_CALENDAR("deviceCalendar", "Device Calendar", ConnectorKind.CALENDAR),
  DEVICE_CONTACTS("deviceContacts", "Device Contacts", ConnectorKind.CONTACTS);

  val isDevice: Boolean get() = this == DEVICE_CALENDAR || this == DEVICE_CONTACTS

  val isMicrosoft: Boolean
    get() = this == OUTLOOK_MAIL || this == OUTLOOK_CALENDAR || this == OUTLOOK_CONTACTS ||
      this == MICROSOFT_TODO || this == ONEDRIVE

  /** One Microsoft sign-in is shared by five independently enabled services. */
  val credentialKey: String get() = if (isMicrosoft) "microsoft" else rawId

  /** Vendor-hosted MCP endpoint (Streamable HTTP). Todoist uses its REST API with a token. */
  val mcpUrl: String?
    get() = when (this) {
      LINEAR -> "https://mcp.linear.app/mcp"
      NOTION -> "https://mcp.notion.com/mcp"
      ATLASSIAN -> "https://mcp.atlassian.com/v2/mcp"
      CLOUDFLARE -> "https://mcp.cloudflare.com/mcp"
      GITHUB -> "https://api.githubcopilot.com/mcp/"
      else -> null
    }

  val supportsToken: Boolean
    get() = !isDevice && !isMicrosoft && this != NOTION && this != DROPBOX

  val supportsOAuth: Boolean
    get() = this == LINEAR || this == NOTION || this == ATLASSIAN || this == CLOUDFLARE || this == DROPBOX || isMicrosoft

  /** Sign-in requires a public client ID registered by the app owner (no DCR). */
  val needsClientRegistration: Boolean get() = isMicrosoft || this == DROPBOX

  val helpUrl: String
    get() = when (this) {
      TODOIST -> "https://app.todoist.com/app/settings/integrations/developer"
      LINEAR -> "https://linear.app/settings/api"
      NOTION -> "https://developers.notion.com/guides/mcp/build-mcp-client"
      ATLASSIAN -> "https://id.atlassian.com/manage-profile/security/api-tokens"
      CLOUDFLARE -> "https://dash.cloudflare.com/profile/api-tokens"
      GITHUB -> "https://github.com/settings/personal-access-tokens"
      READWISE -> "https://readwise.io/access_token"
      AIRTABLE -> "https://airtable.com/create/tokens"
      CLICKUP -> "https://developer.clickup.com/docs/authentication"
      RAINDROP -> "https://app.raindrop.io/settings/integrations"
      DROPBOX -> "https://www.dropbox.com/developers/apps"
      else -> "https://entra.microsoft.com/"
    }

  /** Exact custom-scheme redirect, bound to the provider (one Microsoft redirect for all five). */
  val redirectUri: String get() = "$REDIRECT_SCHEME:/oauth/$credentialKey"

  companion object {
    const val REDIRECT_SCHEME = "com.omergirgin.turing"

    fun fromRawId(raw: String): ConnectorId? = entries.firstOrNull { it.rawId == raw }
  }
}

data class ConnectorTool(
  val service: ConnectorId,
  val name: String,
  val description: String,
  val inputSchema: JsonObject,
  /** Only app-owned descriptors can mark a tool safe. Remote annotations are never authority. */
  val needsApproval: Boolean = true,
) {
  val id: String get() = service.rawId + ":" + name
}

data class ConnectorToolCall(val tool: String, val arguments: JsonElement)

class ConnectorResult(val value: JsonElement, val sources: List<WebSource> = emptyList())

/** User-presentable failures. Messages never contain tokens, URLs or response bodies. */
class ConnectorException(val kind: Kind, val status: Int? = null) : Exception(describe(kind, status)) {
  enum class Kind {
    DISCONNECTED, CHANGED, INVALID_RESPONSE, INVALID_ARGUMENTS, TOO_LARGE, DENIED, CONFIGURATION, HTTP,
    REMOTE_FAILURE, NETWORK,
  }

  companion object {
    fun describe(kind: Kind, status: Int?): String = when (kind) {
      Kind.DISCONNECTED -> "Connect this account in Settings → Connections first."
      Kind.CHANGED -> "Connection access changed during this request. Please try again."
      Kind.INVALID_RESPONSE -> "The service returned an unsupported response. Please reconnect or try again."
      Kind.INVALID_ARGUMENTS -> "The model could not prepare a valid connection request. Try a more specific request."
      Kind.TOO_LARGE -> "The result exceeds the reading budget. Narrow the search or date range."
      Kind.DENIED -> "Access was not granted. You can change the permission in Settings."
      Kind.CONFIGURATION ->
        "This sign-in needs a public client ID or an approved callback address. Open Connection setup."
      Kind.HTTP -> "The service returned HTTP ${status ?: 0}. Check account permissions and try again."
      Kind.REMOTE_FAILURE -> "The service could not complete this action. Check the result before retrying a change."
      Kind.NETWORK -> "The service could not be reached. Check your network connection and try again."
    }
  }
}

/** Durable outcome record for a reviewed (non-read) operation. Persisted before the request is sent. */
data class ConnectionActionReceipt(
  val id: String,
  val service: ConnectorId,
  val tool: String,
  val arguments: JsonElement,
  val outcome: Outcome,
  val date: Long,
  val summary: String,
) {
  enum class Outcome { STARTED, SUCCEEDED, FAILED, DECLINED, UNCERTAIN }

  val statusTitle: String
    get() = when (outcome) {
      Outcome.STARTED, Outcome.UNCERTAIN -> "Check the service before retrying"
      Outcome.SUCCEEDED -> "Completed"
      Outcome.FAILED -> "Service reported a failure"
      Outcome.DECLINED -> "Declined · Not executed"
    }
}

package com.omergirgin.mosaic.core.connections

import kotlinx.serialization.json.JsonElement

/**
 * Platform bridge for on-device sources (Android Calendar/Contacts providers). Only bounded JSON
 * crosses it; provider cursors and rows stay inside the implementation.
 */
interface DeviceConnectorBridge {
  /** Runtime permission currently granted (rechecked before every access). */
  fun isAuthorized(service: ConnectorId): Boolean
  suspend fun call(tool: ConnectorTool, arguments: JsonElement): ConnectorResult
}

/** App-owned tool descriptors for device connections (iOS `AppleConnections.tools`). */
object DeviceConnectorTools {
  fun tools(service: ConnectorId): List<ConnectorTool> {
    fun tool(name: String, description: String, required: List<String>, fields: Map<String, String>, write: Boolean = false) =
      ConnectorTool(service, name, description, stringToolSchema(fields, required), needsApproval = write)
    return when (service) {
      ConnectorId.DEVICE_CALENDAR -> listOf(
        tool("calendars", "List device calendars and whether they allow changes.", emptyList(), emptyMap()),
        tool(
          "events",
          "Read events in a date range of at most 366 days. Only calendars on this device. Results are paginated by offset.",
          listOf("start", "end"),
          mapOf(
            "start" to "ISO8601 start with timezone", "end" to "ISO8601 end with timezone",
            "calendarId" to "Optional calendar ID", "query" to "Optional title/location search",
            "offset" to "Next offset from previous result",
          ),
        ),
        tool(
          "create_event",
          "Create a calendar event after user review. No attendees, invitations or recurrence.",
          listOf("title", "start", "end"),
          mapOf(
            "title" to "Event title", "start" to "ISO8601 start", "end" to "ISO8601 end",
            "calendarId" to "Optional destination calendar ID, otherwise default",
            "notes" to "Optional notes", "location" to "Optional location",
          ),
          write = true,
        ),
      )
      ConnectorId.DEVICE_CONTACTS -> listOf(
        tool(
          "search",
          "Find contacts by name among contacts on this device. A nonempty name is required; results are paginated.",
          listOf("query"), mapOf("query" to "Person or organization name", "offset" to "Next offset"),
        ),
        tool(
          "create_contact", "Create one contact after user review.", listOf("givenName"),
          mapOf(
            "givenName" to "Given name", "familyName" to "Family name", "email" to "Optional email",
            "phone" to "Optional phone number", "organization" to "Optional organization",
          ),
          write = true,
        ),
      )
      else -> emptyList()
    }
  }
}

package com.omergirgin.mosaic.data.connections

import android.Manifest
import android.content.ContentProviderOperation
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import android.provider.ContactsContract
import androidx.core.content.ContextCompat
import com.omergirgin.mosaic.core.connections.ConnectorException
import com.omergirgin.mosaic.core.connections.ConnectorId
import com.omergirgin.mosaic.core.connections.ConnectorResult
import com.omergirgin.mosaic.core.connections.ConnectorSchema
import com.omergirgin.mosaic.core.connections.ConnectorText
import com.omergirgin.mosaic.core.connections.ConnectorTool
import com.omergirgin.mosaic.core.connections.DeviceConnectorBridge
import com.omergirgin.mosaic.core.connections.get
import com.omergirgin.mosaic.core.connections.jsonObject
import com.omergirgin.mosaic.core.connections.stringValue
import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive

/**
 * Android Calendar and Contacts providers (the iOS EventKit/Contacts connections). Cursors and rows
 * stay inside this class; only bounded JSON leaves it. Nothing is imported in bulk, contact notes
 * are never read, and writes happen only for an approved, exact call.
 */
internal class DeviceConnections(context: Context) : DeviceConnectorBridge {
  private val context = context.applicationContext
  private val resolver get() = context.contentResolver

  fun permissions(service: ConnectorId): Array<String> = when (service) {
    ConnectorId.DEVICE_CALENDAR -> arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR)
    ConnectorId.DEVICE_CONTACTS -> arrayOf(Manifest.permission.READ_CONTACTS, Manifest.permission.WRITE_CONTACTS)
    else -> emptyArray()
  }

  override fun isAuthorized(service: ConnectorId): Boolean = when (service) {
    ConnectorId.DEVICE_CALENDAR -> granted(Manifest.permission.READ_CALENDAR)
    ConnectorId.DEVICE_CONTACTS -> granted(Manifest.permission.READ_CONTACTS)
    else -> false
  }

  private fun granted(permission: String) =
    ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

  override suspend fun call(tool: ConnectorTool, arguments: JsonElement): ConnectorResult = withContext(Dispatchers.IO) {
    if (!isAuthorized(tool.service)) throw ConnectorException(ConnectorException.Kind.DENIED)
    ConnectorSchema.validate(arguments, tool.inputSchema)
    val args = Args(arguments)
    try {
      when (tool.service to tool.name) {
        ConnectorId.DEVICE_CALENDAR to "calendars" -> args.page(calendars().map { it.json() })
        ConnectorId.DEVICE_CALENDAR to "events" -> events(args)
        ConnectorId.DEVICE_CALENDAR to "create_event" -> createEvent(args)
        ConnectorId.DEVICE_CONTACTS to "search" -> searchContacts(args)
        ConnectorId.DEVICE_CONTACTS to "create_contact" -> createContact(args)
        else -> throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
      }
    } catch (_: SecurityException) {
      // Permission revoked between the check and the provider call.
      throw ConnectorException(ConnectorException.Kind.DENIED)
    }
  }

  // region calendar

  private class DeviceCalendar(val id: Long, val title: String, val writable: Boolean, val visible: Boolean, val primary: Boolean) {
    fun json() = jsonObject("id" to JsonPrimitive(id.toString()), "title" to JsonPrimitive(title), "writable" to JsonPrimitive(writable))
  }

  private fun calendars(): List<DeviceCalendar> {
    val projection = arrayOf(
      CalendarContract.Calendars._ID,
      CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
      CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
      CalendarContract.Calendars.VISIBLE,
      CalendarContract.Calendars.IS_PRIMARY,
    )
    val result = ArrayList<DeviceCalendar>()
    resolver.query(CalendarContract.Calendars.CONTENT_URI, projection, null, null, CalendarContract.Calendars._ID)?.use { cursor ->
      while (cursor.moveToNext() && result.size < 500) {
        result += DeviceCalendar(
          id = cursor.getLong(0),
          title = cursor.getString(1).orEmpty(),
          writable = cursor.getInt(2) >= CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR,
          visible = cursor.getInt(3) != 0,
          primary = !cursor.isNull(4) && cursor.getInt(4) != 0,
        )
      }
    }
    return result
  }

  private fun selectedCalendar(id: String?): DeviceCalendar? {
    if (id == null) return null
    val numeric = id.toLongOrNull() ?: throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    return calendars().firstOrNull { it.id == numeric } ?: throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
  }

  private suspend fun events(args: Args): ConnectorResult {
    val start = args.date("start")
    val end = args.date("end")
    if (start == null || end == null || !end.isAfter(start) || ChronoUnit.SECONDS.between(start, end) > 366L * 86_400) {
      throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    }
    val calendar = selectedCalendar(args.string("calendarId"))
    val query = args.string("query").orEmpty()
    val uri = CalendarContract.Instances.CONTENT_URI.buildUpon().also {
      ContentUris.appendId(it, start.toEpochMilli())
      ContentUris.appendId(it, end.toEpochMilli())
    }.build()
    val projection = arrayOf(
      CalendarContract.Instances.EVENT_ID,
      CalendarContract.Instances.TITLE,
      CalendarContract.Instances.BEGIN,
      CalendarContract.Instances.END,
      CalendarContract.Instances.ALL_DAY,
      CalendarContract.Instances.CALENDAR_DISPLAY_NAME,
      CalendarContract.Instances.EVENT_LOCATION,
      CalendarContract.Instances.DESCRIPTION,
    )
    val selection = calendar?.let { "${CalendarContract.Instances.CALENDAR_ID} = ?" }
    val selectionArgs = calendar?.let { arrayOf(it.id.toString()) }
    val values = ArrayList<JsonElement>()
    var scanned = 0
    resolver.query(
      uri, projection, selection, selectionArgs,
      "${CalendarContract.Instances.BEGIN} ASC, ${CalendarContract.Instances.EVENT_ID} ASC",
    )?.use { cursor ->
      while (cursor.moveToNext()) {
        if (++scanned > MAXIMUM_ROWS) throw ConnectorException(ConnectorException.Kind.TOO_LARGE)
        if (scanned % 200 == 0) currentCoroutineContext().ensureActive()
        val title = cursor.getString(1).orEmpty()
        val location = cursor.getString(6).orEmpty()
        if (query.isNotEmpty() && !title.contains(query, ignoreCase = true) && !location.contains(query, ignoreCase = true)) continue
        val allDay = cursor.getInt(4) != 0
        values += jsonObject(
          "id" to JsonPrimitive(cursor.getLong(0).toString()),
          "title" to JsonPrimitive(title),
          "start" to JsonPrimitive(format(cursor.getLong(2), allDay)),
          "end" to JsonPrimitive(format(cursor.getLong(3), allDay)),
          "allDay" to JsonPrimitive(allDay),
          "calendar" to JsonPrimitive(cursor.getString(5).orEmpty()),
          "location" to JsonPrimitive(location),
          "notes" to JsonPrimitive(ConnectorText.bounded(cursor.getString(7).orEmpty(), 4_000)),
        )
      }
    }
    return args.page(values)
  }

  /** All-day instances are stored at UTC midnight; report them as plain dates. */
  private fun format(millis: Long, allDay: Boolean): String =
    if (allDay) Instant.ofEpochMilli(millis).atOffset(ZoneOffset.UTC).toLocalDate().toString()
    else Instant.ofEpochMilli(millis).truncatedTo(ChronoUnit.SECONDS).toString()

  private fun createEvent(args: Args): ConnectorResult {
    if (!granted(Manifest.permission.WRITE_CALENDAR)) throw ConnectorException(ConnectorException.Kind.DENIED)
    val title = args.string("title")?.takeIf { it.isNotBlank() } ?: throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    val start = args.date("start")
    val end = args.date("end")
    if (start == null || end == null || !end.isAfter(start)) throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    val all = calendars()
    val destination = selectedCalendar(args.string("calendarId"))
      ?: all.firstOrNull { it.primary && it.writable && it.visible }
      ?: all.firstOrNull { it.writable && it.visible }
    if (destination == null || !destination.writable) throw ConnectorException(ConnectorException.Kind.DENIED)
    val values = ContentValues().apply {
      put(CalendarContract.Events.CALENDAR_ID, destination.id)
      put(CalendarContract.Events.TITLE, title)
      put(CalendarContract.Events.DTSTART, start.toEpochMilli())
      put(CalendarContract.Events.DTEND, end.toEpochMilli())
      put(CalendarContract.Events.EVENT_TIMEZONE, ZoneId.systemDefault().id)
      args.string("notes")?.let { put(CalendarContract.Events.DESCRIPTION, it) }
      args.string("location")?.let { put(CalendarContract.Events.EVENT_LOCATION, it) }
    }
    val inserted = resolver.insert(CalendarContract.Events.CONTENT_URI, values)
      ?: throw ConnectorException(ConnectorException.Kind.REMOTE_FAILURE)
    return ConnectorResult(
      jsonObject(
        "created" to JsonPrimitive(true),
        "id" to JsonPrimitive(ContentUris.parseId(inserted).toString()),
        "title" to JsonPrimitive(title),
        "calendar" to JsonPrimitive(destination.title),
      )
    )
  }

  // endregion

  // region contacts

  private suspend fun searchContacts(args: Args): ConnectorResult {
    val query = args.string("query")?.trim()?.takeIf { it.isNotEmpty() }
      ?: throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    // Name matching only (Contacts filter URI), like CNContact.predicateForContacts(matchingName:).
    val uri = ContactsContract.Contacts.CONTENT_FILTER_URI.buildUpon().appendPath(query).build()
    val ids = ArrayList<Long>()
    resolver.query(uri, arrayOf(ContactsContract.Contacts._ID), null, null, ContactsContract.Contacts._ID)?.use { cursor ->
      while (cursor.moveToNext()) {
        if (ids.size >= MAXIMUM_ROWS) throw ConnectorException(ConnectorException.Kind.TOO_LARGE)
        ids += cursor.getLong(0)
      }
    }
    val unique = ids.distinct().sorted()
    val offset = args.offset()
    val pageIds = unique.drop(offset).take(PAGE_SIZE)
    currentCoroutineContext().ensureActive()
    val details = contactDetails(pageIds)
    val items = pageIds.map { id -> details[id]?.json(id) ?: Contact().json(id) }
    return ConnectorResult(
      jsonObject(
        "items" to JsonArray(items),
        "totalMatches" to JsonPrimitive(unique.size),
        "next_offset" to if (offset + pageIds.size < unique.size) JsonPrimitive((offset + pageIds.size).toString()) else JsonNull,
      )
    )
  }

  private class Contact {
    var givenName = ""
    var familyName = ""
    var organization = ""
    val emails = ArrayList<String>()
    val phones = ArrayList<String>()

    fun json(id: Long) = jsonObject(
      "id" to JsonPrimitive(id.toString()),
      "givenName" to JsonPrimitive(givenName),
      "familyName" to JsonPrimitive(familyName),
      "organization" to JsonPrimitive(organization),
      "emails" to JsonArray(emails.take(20).map(::JsonPrimitive)),
      "phones" to JsonArray(phones.take(20).map(::JsonPrimitive)),
    )
  }

  /** Name, email, phone and organization rows only — the Note mimetype is never requested. */
  private fun contactDetails(ids: List<Long>): Map<Long, Contact> {
    if (ids.isEmpty()) return emptyMap()
    val types = listOf(
      ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE,
      ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE,
      ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE,
      ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE,
    )
    val selection = "${ContactsContract.Data.CONTACT_ID} IN (${ids.joinToString(",") { "?" }}) AND " +
      "${ContactsContract.Data.MIMETYPE} IN (${types.joinToString(",") { "?" }})"
    val projection = arrayOf(
      ContactsContract.Data.CONTACT_ID, ContactsContract.Data.MIMETYPE,
      ContactsContract.Data.DATA1, ContactsContract.Data.DATA2, ContactsContract.Data.DATA3,
    )
    val result = HashMap<Long, Contact>()
    resolver.query(
      ContactsContract.Data.CONTENT_URI, projection, selection,
      (ids.map { it.toString() } + types).toTypedArray(), ContactsContract.Data._ID,
    )?.use { cursor ->
      while (cursor.moveToNext()) {
        val contact = result.getOrPut(cursor.getLong(0)) { Contact() }
        when (cursor.getString(1)) {
          ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE -> {
            if (contact.givenName.isEmpty()) contact.givenName = cursor.getString(3).orEmpty()
            if (contact.familyName.isEmpty()) contact.familyName = cursor.getString(4).orEmpty()
          }
          ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE -> cursor.getString(2)?.let { contact.emails += it }
          ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE -> cursor.getString(2)?.let { contact.phones += it }
          ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE ->
            if (contact.organization.isEmpty()) contact.organization = cursor.getString(2).orEmpty()
        }
      }
    }
    return result
  }

  private fun createContact(args: Args): ConnectorResult {
    if (!granted(Manifest.permission.WRITE_CONTACTS)) throw ConnectorException(ConnectorException.Kind.DENIED)
    val given = args.string("givenName")?.takeIf { it.isNotBlank() } ?: throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    val data = ContactsContract.Data.CONTENT_URI
    val operations = arrayListOf(
      // Device-local raw contact (no sync account).
      ContentProviderOperation.newInsert(ContactsContract.RawContacts.CONTENT_URI)
        .withValue(ContactsContract.RawContacts.ACCOUNT_TYPE, null)
        .withValue(ContactsContract.RawContacts.ACCOUNT_NAME, null)
        .build(),
      ContentProviderOperation.newInsert(data)
        .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
        .withValue(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE)
        .withValue(ContactsContract.CommonDataKinds.StructuredName.GIVEN_NAME, given)
        .withValue(ContactsContract.CommonDataKinds.StructuredName.FAMILY_NAME, args.string("familyName").orEmpty())
        .build(),
    )
    args.string("email")?.takeIf { it.isNotBlank() }?.let {
      operations += ContentProviderOperation.newInsert(data)
        .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
        .withValue(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE)
        .withValue(ContactsContract.CommonDataKinds.Email.ADDRESS, it)
        .withValue(ContactsContract.CommonDataKinds.Email.TYPE, ContactsContract.CommonDataKinds.Email.TYPE_OTHER)
        .build()
    }
    args.string("phone")?.takeIf { it.isNotBlank() }?.let {
      operations += ContentProviderOperation.newInsert(data)
        .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
        .withValue(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE)
        .withValue(ContactsContract.CommonDataKinds.Phone.NUMBER, it)
        .withValue(ContactsContract.CommonDataKinds.Phone.TYPE, ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE)
        .build()
    }
    args.string("organization")?.takeIf { it.isNotBlank() }?.let {
      operations += ContentProviderOperation.newInsert(data)
        .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
        .withValue(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE)
        .withValue(ContactsContract.CommonDataKinds.Organization.COMPANY, it)
        .build()
    }
    val results = resolver.applyBatch(ContactsContract.AUTHORITY, operations)
    val rawId = results.firstOrNull()?.uri?.let(ContentUris::parseId) ?: throw ConnectorException(ConnectorException.Kind.REMOTE_FAILURE)
    var contactId = rawId
    resolver.query(
      ContentUris.withAppendedId(ContactsContract.RawContacts.CONTENT_URI, rawId),
      arrayOf(ContactsContract.RawContacts.CONTACT_ID), null, null, null,
    )?.use { if (it.moveToFirst() && !it.isNull(0)) contactId = it.getLong(0) }
    return ConnectorResult(jsonObject("created" to JsonPrimitive(true), "id" to JsonPrimitive(contactId.toString())))
  }

  // endregion

  /** Validated string arguments plus offset pagination (iOS parity: 50 per page). */
  private class Args(private val value: JsonElement) {
    fun string(key: String): String? = value[key].stringValue

    /** ISO 8601 with an offset; a local date-time without one is read in the device time zone. */
    fun date(key: String): Instant? {
      val text = string(key) ?: return null
      return runCatching { OffsetDateTime.parse(text).toInstant() }.getOrNull()
        ?: runCatching { ZonedDateTime.parse(text).toInstant() }.getOrNull()
        ?: runCatching { Instant.parse(text) }.getOrNull()
        ?: runCatching { LocalDateTime.parse(text).atZone(ZoneId.systemDefault()).toInstant() }.getOrNull()
        ?: throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    }

    fun offset(): Int {
      val offset = string("offset")?.let { it.toIntOrNull() ?: -1 } ?: 0
      if (offset !in 0..100_000) throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
      return offset
    }

    fun page(values: List<JsonElement>): ConnectorResult {
      val offset = offset()
      val selected = values.drop(offset).take(PAGE_SIZE)
      return ConnectorResult(
        jsonObject(
          "items" to JsonArray(selected),
          "totalMatches" to JsonPrimitive(values.size),
          "next_offset" to if (offset + selected.size < values.size) JsonPrimitive((offset + selected.size).toString()) else JsonNull,
        )
      )
    }
  }

  private companion object {
    const val PAGE_SIZE = 50
    /** Rows scanned per call; a wider range must be narrowed instead of read wholesale. */
    const val MAXIMUM_ROWS = 10_000
  }
}

@preconcurrency import Contacts
@preconcurrency import EventKit
import Foundation

/// EventKit/Contacts objects stay inside the actor or their API callback. Only bounded JSON crosses
/// isolation. No full-library import, contact notes entitlement, or credentials leave the device.
actor AppleConnections {
  static let shared = AppleConnections()
  private let events = EKEventStore()
  private let contacts = CNContactStore()
  static func authorized(_ service: ConnectorID) -> Bool {
    switch service {
    case .appleCalendar: EKEventStore.authorizationStatus(for: .event) == .fullAccess
    case .appleReminders: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    case .appleContacts:
      CNContactStore.authorizationStatus(for: .contacts) == .authorized
        || CNContactStore.authorizationStatus(for: .contacts).rawValue == 4  // limited on iOS 18+
    default: false
    }
  }
  func requestAccess(_ service: ConnectorID) async throws {
    let granted: Bool
    switch service {
    case .appleCalendar: granted = try await events.requestFullAccessToEvents()
    case .appleReminders: granted = try await events.requestFullAccessToReminders()
    case .appleContacts: granted = try await contacts.requestAccess(for: .contacts)
    default: throw ConnectorError.invalidArguments
    }
    guard granted, Self.authorized(service) else { throw ConnectorError.denied }
  }
  static func tools(_ service: ConnectorID) -> [ConnectorTool] {
    func tool(
      _ name: String, _ description: String, _ required: [String], _ fields: [String: String],
      write: Bool = false
    ) -> ConnectorTool {
      .init(
        service: service, name: name, description: description,
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object(
            fields.mapValues {
              .object([
                "type": .string("string"), "description": .string($0), "maxLength": .number(4096),
              ])
            }),
          "required": .array(required.map(ConnectorJSON.string)),
          "additionalProperties": .bool(false),
        ]), needsApproval: write)
    }
    switch service {
    case .appleCalendar:
      return [
        tool("calendars", "List device calendars and whether they allow changes.", [], [:]),
        tool(
          "events",
          "Read events in a date range of at most 366 days. Only authorized calendars. Results are paginated by offset.",
          ["start", "end"],
          [
            "start": "ISO8601 start with timezone", "end": "ISO8601 end with timezone",
            "calendarId": "Optional calendar ID", "query": "Optional title/location search",
            "offset": "Next offset from previous result",
          ]),
        tool(
          "create_event",
          "Create a calendar event after user review. No attendees, invitations or recurrence.",
          ["title", "start", "end"],
          [
            "title": "Event title", "start": "ISO8601 start", "end": "ISO8601 end",
            "calendarId": "Optional destination calendar ID, otherwise default",
            "notes": "Optional notes", "location": "Optional location",
          ], write: true),
      ]
    case .appleReminders:
      return [
        tool("lists", "List reminder lists and whether they allow changes.", [], [:]),
        tool(
          "reminders",
          "Find reminders, optionally by list, due range, text and completed status. Paginate with offset.",
          [],
          [
            "listId": "Optional list ID", "query": "Optional title search",
            "start": "Optional ISO8601 due lower bound", "end": "Optional ISO8601 due upper bound",
            "completed": "true or false, default false", "offset": "Next offset",
          ]),
        tool(
          "create_reminder", "Create a reminder after user review.", ["title"],
          [
            "title": "Reminder title", "listId": "Optional destination list ID",
            "due": "Optional ISO8601 due time", "notes": "Optional notes",
          ], write: true),
        tool(
          "complete_reminder", "Mark this exact reminder completed after user review.", ["id"],
          ["id": "Reminder identifier"], write: true),
      ]
    case .appleContacts:
      return [
        tool(
          "search",
          "Find contacts by name among contacts the user has allowed. A nonempty name is required; results are paginated.",
          ["query"], ["query": "Person or organization name", "offset": "Next offset"]),
        tool(
          "create_contact", "Create one contact after user review.", ["givenName"],
          [
            "givenName": "Given name", "familyName": "Family name", "email": "Optional email",
            "phone": "Optional phone number", "organization": "Optional organization",
          ], write: true),
      ]
    default: return []
    }
  }
  func call(_ tool: ConnectorTool, arguments: ConnectorJSON) async throws -> ConnectorResult {
    guard Self.authorized(tool.service) else { throw ConnectorError.denied }
    try ConnectorSchema.validate(arguments, schema: tool.inputSchema)
    func string(_ key: String) -> String? { arguments[key].string }
    func date(_ key: String) throws -> Date? {
      guard let text = string(key) else { return nil }
      guard let value = ISO8601DateFormatter().date(from: text) else {
        throw ConnectorError.invalidArguments
      }
      return value
    }
    let offset = Int(string("offset") ?? "0") ?? -1
    guard (0...100_000).contains(offset) else { throw ConnectorError.invalidArguments }
    func page(_ values: [ConnectorJSON]) -> ConnectorResult {
      let selected = Array(values.dropFirst(offset).prefix(50))
      return .init(
        value: .object([
          "items": .array(selected), "totalMatches": .number(Double(values.count)),
          "next_offset": offset + selected.count < values.count
            ? .string(String(offset + selected.count)) : .null,
        ]))
    }
    switch (tool.service, tool.name) {
    case (.appleCalendar, "calendars"), (.appleReminders, "lists"):
      let type: EKEntityType = tool.service == .appleCalendar ? .event : .reminder
      return page(
        events.calendars(for: type).map {
          .object([
            "id": .string($0.calendarIdentifier), "title": .string($0.title),
            "writable": .bool($0.allowsContentModifications),
          ])
        })
    case (.appleCalendar, "events"):
      guard let start = try date("start"), let end = try date("end"), end > start,
        end.timeIntervalSince(start) <= 366 * 86400
      else { throw ConnectorError.invalidArguments }
      let calendars = try selectedCalendars(id: string("calendarId"), type: .event)
      let predicate = events.predicateForEvents(withStart: start, end: end, calendars: calendars)
      let query = string("query") ?? ""
      let values = events.events(matching: predicate).filter {
        query.isEmpty || ($0.title ?? "").localizedCaseInsensitiveContains(query)
          || ($0.location ?? "").localizedCaseInsensitiveContains(query)
      }.sorted {
        ($0.startDate, $0.calendarItemIdentifier) < ($1.startDate, $1.calendarItemIdentifier)
      }
      return page(
        values.map { event in
          .object([
            "id": .string(event.calendarItemIdentifier), "title": .string(event.title ?? ""),
            "start": .string(event.startDate.ISO8601Format()),
            "end": .string(event.endDate.ISO8601Format()),
            "allDay": .bool(event.isAllDay), "calendar": .string(event.calendar.title),
            "location": .string(event.location ?? ""),
            "notes": .string(GoogleWire.bounded(event.notes ?? "", bytes: 4000)),
          ])
        })
    case (.appleReminders, "reminders"):
      let calendars = try selectedCalendars(id: string("listId"), type: .reminder)
      let start = try date("start")
      let end = try date("end")
      if let start, let end, end <= start { throw ConnectorError.invalidArguments }
      let query = string("query") ?? ""
      let completed = string("completed") == "true"
      let predicate = events.predicateForReminders(in: calendars)
      let values: [ConnectorJSON] = await withCheckedContinuation { continuation in
        events.fetchReminders(matching: predicate) { reminders in
          let values = (reminders ?? []).filter { reminder in
            guard reminder.isCompleted == completed,
              query.isEmpty || (reminder.title ?? "").localizedCaseInsensitiveContains(query)
            else { return false }
            let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            if let start, due == nil || due! < start { return false }
            if let end, due == nil || due! >= end { return false }
            return true
          }.sorted { $0.calendarItemIdentifier < $1.calendarItemIdentifier }.map {
            reminder -> ConnectorJSON in
            let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            return .object([
              "id": .string(reminder.calendarItemIdentifier),
              "title": .string(reminder.title ?? ""),
              "list": .string(reminder.calendar.title), "completed": .bool(reminder.isCompleted),
              "due": due.map { .string($0.ISO8601Format()) } ?? .null,
              "notes": .string(GoogleWire.bounded(reminder.notes ?? "", bytes: 4000)),
            ])
          }
          continuation.resume(returning: values)
        }
      }
      try Task.checkCancellation()
      guard Self.authorized(tool.service) else { throw ConnectorError.denied }
      return page(values)
    case (.appleContacts, "search"):
      guard let query = string("query"),
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw ConnectorError.invalidArguments }
      let keys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor, CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
      ]
      let values = try contacts.unifiedContacts(
        matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys
      )
      .sorted { $0.identifier < $1.identifier }.map { contact -> ConnectorJSON in
        .object([
          "id": .string(contact.identifier), "givenName": .string(contact.givenName),
          "familyName": .string(contact.familyName),
          "organization": .string(contact.organizationName),
          "emails": .array(contact.emailAddresses.map { .string($0.value as String) }),
          "phones": .array(contact.phoneNumbers.map { .string($0.value.stringValue) }),
        ])
      }
      return page(values)
    case (.appleCalendar, "create_event"):
      guard let title = string("title"),
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let start = try date("start"), let end = try date("end"), end > start
      else { throw ConnectorError.invalidArguments }
      let calendar = try destination(id: string("calendarId"), type: .event)
      let event = EKEvent(eventStore: events)
      event.calendar = calendar
      event.title = title
      event.startDate = start
      event.endDate = end
      event.notes = string("notes")
      event.location = string("location")
      try Task.checkCancellation()
      try events.save(event, span: .thisEvent, commit: true)
      return .init(
        value: .object([
          "created": .bool(true), "id": .string(event.calendarItemIdentifier),
          "title": .string(title),
        ]))
    case (.appleReminders, "create_reminder"):
      guard let title = string("title"),
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw ConnectorError.invalidArguments }
      let reminder = EKReminder(eventStore: events)
      reminder.calendar = try destination(id: string("listId"), type: .reminder)
      reminder.title = title
      reminder.notes = string("notes")
      if let due = try date("due") {
        reminder.dueDateComponents = Calendar.current.dateComponents(
          [.year, .month, .day, .hour, .minute, .timeZone], from: due)
      }
      try Task.checkCancellation()
      try events.save(reminder, commit: true)
      return .init(
        value: .object([
          "created": .bool(true), "id": .string(reminder.calendarItemIdentifier),
          "title": .string(title),
        ]))
    case (.appleReminders, "complete_reminder"):
      guard let id = string("id"),
        let reminder = events.calendarItem(withIdentifier: id) as? EKReminder,
        reminder.calendar.allowsContentModifications
      else { throw ConnectorError.invalidArguments }
      reminder.isCompleted = true
      try Task.checkCancellation()
      try events.save(reminder, commit: true)
      return .init(value: .object(["completed": .bool(true), "id": .string(id)]))
    case (.appleContacts, "create_contact"):
      guard let given = string("givenName"),
        !given.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw ConnectorError.invalidArguments }
      let contact = CNMutableContact()
      contact.givenName = given
      contact.familyName = string("familyName") ?? ""
      contact.organizationName = string("organization") ?? ""
      if let email = string("email") {
        contact.emailAddresses = [.init(label: CNLabelOther, value: email as NSString)]
      }
      if let phone = string("phone") {
        contact.phoneNumbers = [
          .init(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))
        ]
      }
      let request = CNSaveRequest()
      request.add(contact, toContainerWithIdentifier: nil)
      try Task.checkCancellation()
      try contacts.execute(request)
      return .init(value: .object(["created": .bool(true), "id": .string(contact.identifier)]))
    default: throw ConnectorError.invalidArguments
    }
  }
  private func selectedCalendars(id: String?, type: EKEntityType) throws -> [EKCalendar]? {
    guard let id else { return nil }
    guard let calendar = events.calendars(for: type).first(where: { $0.calendarIdentifier == id })
    else { throw ConnectorError.invalidArguments }
    return [calendar]
  }
  private func destination(id: String?, type: EKEntityType) throws -> EKCalendar {
    let calendar =
      try selectedCalendars(id: id, type: type)?.first
      ?? (type == .event
        ? events.defaultCalendarForNewEvents : events.defaultCalendarForNewReminders())
    guard let calendar, calendar.allowsContentModifications else { throw ConnectorError.denied }
    return calendar
  }
}

import Foundation

// Wire models for the PRO manual-reminders surface (web `/pro/reminders`) — the
// pro's own follow-up / rebook / product-check-in to-dos, distinct from the
// appointment-reminder CADENCE (`ProReminderSettings`). Backed by routes that
// already exist, so this is an iOS-only port — no backend change:
//   • GET  /api/v1/pro/reminders              → { reminders: [reminder] }
//   • POST /api/v1/pro/reminders              (form-encoded) → { id }   (create)
//   • POST /api/v1/pro/reminders/{id}/complete → { id }               (mark done)
// Instants (`dueAt`, `completedAt`, the linked booking's `scheduledFor`) are
// ISO-8601 UTC strings resolved to a display time at the edge (`Wire`). The linked
// client's name is plaintext on the row (the web page reads it directly).

/// GET /api/v1/pro/reminders → the pro's reminders, `dueAt` ascending. The route
/// returns every reminder (open + completed); the view splits them client-side,
/// mirroring the web page.
public struct ProRemindersResponse: Decodable, Sendable {
    public let reminders: [ProReminder]

    public init(reminders: [ProReminder]) {
        self.reminders = reminders
    }
}

/// One reminder row (a display subset of the full backend record). `type` is kept
/// a raw `String` — the create form only makes `GENERAL` reminders, but the list
/// can surface system-made ones (AFTERCARE / REBOOK / PRODUCT_FOLLOWUP / LICENSE).
public struct ProReminder: Decodable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let body: String?
    public let type: String
    public let dueAt: String
    public let completedAt: String?
    public let client: ProReminderClient?
    public let booking: ProReminderBooking?

    /// A reminder is "done" once the server has stamped `completedAt`.
    public var isCompleted: Bool { completedAt != nil }

    public init(
        id: String,
        title: String,
        body: String?,
        type: String,
        dueAt: String,
        completedAt: String?,
        client: ProReminderClient?,
        booking: ProReminderBooking?
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.type = type
        self.dueAt = dueAt
        self.completedAt = completedAt
        self.client = client
        self.booking = booking
    }
}

/// The optional client a reminder is linked to. First/last name are plaintext on
/// the row; either may be absent for a shadow client.
public struct ProReminderClient: Decodable, Sendable, Identifiable {
    public let id: String
    public let firstName: String?
    public let lastName: String?

    /// "First Last", trimmed — empty when the client has no name yet.
    public var displayName: String {
        "\(firstName ?? "") \(lastName ?? "")"
            .trimmingCharacters(in: .whitespaces)
    }

    public init(id: String, firstName: String?, lastName: String?) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
    }
}

/// The optional booking a reminder is anchored to — used for a "Booking: <service>
/// on <when>" line. Rendered in the booking's own zone when present.
public struct ProReminderBooking: Decodable, Sendable {
    public let scheduledFor: String?
    public let locationTimeZone: String?
    public let service: ProReminderBookingService?

    public init(
        scheduledFor: String?,
        locationTimeZone: String?,
        service: ProReminderBookingService?
    ) {
        self.scheduledFor = scheduledFor
        self.locationTimeZone = locationTimeZone
        self.service = service
    }
}

public struct ProReminderBookingService: Decodable, Sendable {
    public let name: String?

    public init(name: String?) {
        self.name = name
    }
}

/// `POST /api/v1/pro/reminders` and `.../complete` both echo `{ ok, id }`.
struct ProReminderMutationResponse: Decodable {
    let id: String
}

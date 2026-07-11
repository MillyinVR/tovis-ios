import Foundation

// Wire models for the client aftercare inbox — GET /api/v1/client/aftercare.
// The inbox is the client's reverse-chrono list of every aftercare summary
// they've received (the AFTERCARE_READY notification feed), each enriched with
// its visit's canonical title / pro display name / timezone + the pro-chosen
// before/after pair. Mirrors web `lib/dto/clientAftercareInbox.ts`
// (`ClientAftercareInboxDTO`), which the web /client/aftercare page renders
// server-side. Decode-only; the top-level `{ ok, items }` envelope's `ok` flag
// is simply ignored (unknown key). Each row taps through to that booking's
// detail focused on the aftercare step — the same destination as the web "Open"
// CTA (`/client/bookings/{id}?step=aftercare`).

/// Envelope for `GET /api/v1/client/aftercare` → `{ ok, items }`.
struct ClientAftercareInboxResponse: Decodable, Sendable {
    let items: [ClientAftercareInboxItem]
}

/// One aftercare-inbox row. Mirrors `ClientAftercareInboxItemDTO`. Every field is
/// defensively decoded (server-driven, additive) so a new backend value can't
/// wedge the list.
public struct ClientAftercareInboxItem: Decodable, Sendable, Identifiable {
    /// The AFTERCARE_READY notification id — the stable list identity.
    public let notificationId: String
    /// The visit this aftercare belongs to; nil if the notification lost its link.
    public let bookingId: String?
    /// The AftercareSummary id, when present on the notification.
    public let aftercareId: String?
    /// Canonical booking title (service + add-ons), or a fallback.
    public let title: String
    /// The pro's profile id for a profile deep-link, or nil.
    public let proId: String?
    /// The pro's public display name (honors nameDisplay), or "Your pro".
    public let proName: String
    /// The visit instant (ISO), or nil.
    public let scheduledFor: String?
    /// The booking's sanitized IANA timezone for rendering `scheduledFor`.
    public let timeZone: String
    /// The pro-chosen (or earliest) before/after pair, or nil when none.
    public let beforeAfter: ClientAftercareBeforeAfter?
    /// The aftercare rebook mode ("NONE" / "RECOMMENDED_WINDOW" /
    /// "BOOKED_NEXT_APPOINTMENT"), driving the row hint; nil when unset. Raw
    /// string — unknown values fall through to the notes hint.
    public let rebookMode: String?
    /// The pro's recommended rebook date (ISO), when set.
    public let rebookedFor: String?
    /// The notification body copy the pro wrote, or nil.
    public let body: String?
    /// True while the client hasn't opened this aftercare (drives the NEW pill).
    public let unread: Bool
    /// When the aftercare landed in the inbox (ISO).
    public let createdAt: String

    public var id: String { notificationId }

    private enum CodingKeys: String, CodingKey {
        case notificationId, bookingId, aftercareId, title, proId, proName
        case scheduledFor, timeZone, beforeAfter, rebookMode, rebookedFor
        case body, unread, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notificationId = try c.decode(String.self, forKey: .notificationId)
        bookingId = try c.decodeIfPresent(String.self, forKey: .bookingId)
        aftercareId = try c.decodeIfPresent(String.self, forKey: .aftercareId)
        // Defensive fallbacks mirror the web loader's own fallbacks so a partial
        // row still renders rather than failing the whole list decode.
        title = (try? c.decode(String.self, forKey: .title)) ?? "Aftercare"
        proId = try c.decodeIfPresent(String.self, forKey: .proId)
        proName = (try? c.decode(String.self, forKey: .proName)) ?? "Your pro"
        scheduledFor = try c.decodeIfPresent(String.self, forKey: .scheduledFor)
        timeZone = (try? c.decode(String.self, forKey: .timeZone)) ?? "UTC"
        beforeAfter = try? c.decodeIfPresent(ClientAftercareBeforeAfter.self, forKey: .beforeAfter)
        rebookMode = try c.decodeIfPresent(String.self, forKey: .rebookMode)
        rebookedFor = try c.decodeIfPresent(String.self, forKey: .rebookedFor)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        unread = (try? c.decode(Bool.self, forKey: .unread)) ?? false
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
    }

    public init(
        notificationId: String,
        bookingId: String?,
        aftercareId: String?,
        title: String,
        proId: String?,
        proName: String,
        scheduledFor: String?,
        timeZone: String,
        beforeAfter: ClientAftercareBeforeAfter?,
        rebookMode: String?,
        rebookedFor: String?,
        body: String?,
        unread: Bool,
        createdAt: String
    ) {
        self.notificationId = notificationId
        self.bookingId = bookingId
        self.aftercareId = aftercareId
        self.title = title
        self.proId = proId
        self.proName = proName
        self.scheduledFor = scheduledFor
        self.timeZone = timeZone
        self.beforeAfter = beforeAfter
        self.rebookMode = rebookMode
        self.rebookedFor = rebookedFor
        self.body = body
        self.unread = unread
        self.createdAt = createdAt
    }

    /// The row's hint line — mirrors web `aftercareInboxHintMode`: a recommended
    /// booking window, a recommended rebook date, or plain aftercare notes.
    public enum Hint: Sendable {
        case recommendedWindow
        case recommendedDate
        case notes
    }

    public var hint: Hint {
        if rebookMode?.uppercased() == "RECOMMENDED_WINDOW" { return .recommendedWindow }
        return (rebookedFor?.isEmpty == false) ? .recommendedDate : .notes
    }
}

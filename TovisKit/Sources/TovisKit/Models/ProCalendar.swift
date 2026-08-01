import Foundation

// Wire models for the PRO calendar — GET /api/v1/pro/calendar.
// Mirrors the inline payload in `app/api/v1/pro/calendar/route.ts` (CalendarEvent
// = BookingEvent | BlockEvent, CalendarStats, the management buckets). Only the
// subset the native agenda renders is modeled; unknown keys are ignored and
// nullable fields are Swift optionals (BLOCK events carry no timeZone/locationType).

/// `GET /api/v1/pro/calendar` → the calendar payload (envelope spread).
public struct ProCalendarResponse: Decodable, Sendable {
    public let timeZone: String?
    public let viewportTimeZone: String?
    public let needsTimeZoneSetup: Bool?
    public let events: [ProCalendarEvent]
    public let stats: ProCalendarStats
    public let management: ProCalendarManagement
    /// Whether new bookings auto-accept (drives the calendar's auto-accept bar).
    public let autoAcceptBookings: Bool?
    /// Which locations these events were drawn from — `"ALL"` or `"LOCATION"`
    /// (K3). **ABSENT on a pre-K3 server**, which always filtered to exactly one
    /// location, so read it through `isAllLocations`: anything that is not
    /// literally `ALL` — including nothing at all — is a FILTERED feed. Taking an
    /// old server's one-location answer for "everything" would tell the pro their
    /// day is empty at a location the request never asked about, which is the bug
    /// this scope exists to fix, inverted.
    public let scope: String?

    /// True only when the server CONFIRMS it answered for every location.
    ///
    /// Read this — never the client's own "I asked for all" flag — before
    /// claiming a mixed feed on screen (e.g. the per-location chips): what the
    /// request wanted and what the server did are two different facts, and only
    /// the second one is on the wire. [[two-states-owning-one-selection]]
    public var isAllLocations: Bool { scope?.uppercased() == "ALL" }
}

/// `PATCH /api/v1/pro/settings` → `{ professionalProfile: { autoAcceptBookings } }`.
public struct ProSettingsResponse: Decodable, Sendable {
    public struct Profile: Decodable, Sendable {
        public let autoAcceptBookings: Bool
    }
    public let professionalProfile: Profile
}

/// `PATCH /api/v1/pro/settings` body — currently just the auto-accept flag.
struct ProSettingsUpdateRequest: Encodable {
    let autoAcceptBookings: Bool
}

/// One calendar occupancy — a booking, a personal block, or a client's live
/// checkout reservation. The discriminator is `kind`
/// ("BOOKING" | "BLOCK" | "HOLD").
public struct ProCalendarEvent: Decodable, Sendable, Identifiable {
    public let id: String
    /// BLOCK events only: the bare block id. The calendar API namespaces a block
    /// event's `id` as `block:{id}` (so it can't collide with a booking id) and
    /// also sends the bare `blockId`; the block routes (`…/blocked/{id}`) expect
    /// the bare id. nil for bookings. Use `calendarBlockId` to resolve it safely.
    public let blockId: String?
    public let kind: String
    public let startsAt: String
    public let endsAt: String
    public let title: String
    public let clientName: String
    public let status: String
    public let durationMinutes: Int
    /// Booking events carry the resolved viewport timezone; blocks don't.
    public let timeZone: String?
    public let locationType: String?
    /// WHICH location this occupancy is at. Always present on a booking; nullable
    /// on a block (a null block is the pro's time at EVERY location) and on a
    /// hold; absent entirely on a synthetic waitlist row. Needed once the feed can
    /// span locations (K3/K4) — that is the only way a tile can say where it is.
    public let locationId: String?
    /// The event's local date in the viewport zone — used to group the agenda.
    public let localDateKey: String
    /// ClientProfile id — present only when the pro may open this client's chart
    /// (server-gated, so nil means "render the name as plain text, no link").
    public let clientProfileId: String?
    /// Waitlist rows only: human label for the client's preferred time
    /// (e.g. "Any time", "Morning", "Jun 14").
    public let preferenceLabel: String?
    /// Waitlist rows only: web deep-link (`/pro/bookings/new?...`) carrying the
    /// client + offering the pro can offer a matching slot for. nil when the pro
    /// has no active offering for the requested service.
    ///
    /// ⚠️ This is the *fallback* action, not the primary one — following it books
    /// the appointment outright. Prefer `canOfferWaitlistTime` + the offer sheet,
    /// which proposes a time the client confirms (and which reserves the slot
    /// meanwhile). Web's `ManagementModal` orders the two the same way.
    public let offerHref: String?
    /// Waitlist rows only: the bare waitlist entry id (the row's `id` is namespaced
    /// `waitlist:{id}`), which `POST /pro/waitlist/{entryId}/offer` expects.
    public let waitlistEntryId: String?
    /// Waitlist rows only: the service the client is waiting for.
    public let serviceId: String?
    /// Waitlist rows only: the pro's active offering for `serviceId`, or nil when
    /// they have none — in which case there is nothing to offer at all.
    public let offeringId: String?
    /// Waitlist rows only: a time already offered to this client and still
    /// awaiting their answer. Present ⇒ show it instead of an offer action, so the
    /// pro can't quietly stack a second offer on the same entry.
    public let pendingOffer: ProWaitlistPendingOffer?
    /// BOOKING events only (K1/K2): the at-a-glance payment state, derived by
    /// web's ONE helper and rendered verbatim (`display` hides unknown kinds).
    /// Absent on blocks, holds and waitlist rows.
    public let paymentBadge: ProPaymentBadge?
    /// BOOKING events only (K5/K6): the NR/NNR/RR/RNR client-relationship mark,
    /// a per-booking SNAPSHOT mapped server-side and rendered verbatim.
    /// Absent on blocks, holds and waitlist rows.
    public let relationshipBadge: ProRelationshipBadge?
    /// BOOKING events only (K7/K8/K9): the pro's colour for this booking's
    /// service, resolved server-side by the one helper and painted on the tile's
    /// leading stripe — the SERVICE channel, while status keeps the fill (D2).
    ///
    /// 🔴 ABSENT is the common case and means NO COLOUR: a pro who hasn't picked
    /// one has no colour, and inventing a default hue would be a lie about which
    /// service this is. Read it through `serviceSwatchId`.
    public let serviceSwatch: ProServiceSwatch?
    /// BOOKING events only (K11/K13): whether the CLIENT said they're coming,
    /// derived server-side by web's one helper and rendered as the tile's
    /// CORNER GLYPH — the confirmation channel K7's budget reserved.
    ///
    /// 🔴 ABSENT is the common case and means "nobody asked": web omits the key
    /// entirely for NOT_REQUESTED, which is every booking while the loop flag
    /// is off. Absent must decode fine and render NOTHING. Read it through
    /// `clientConfirmationDisplay`.
    public let clientConfirmation: ProClientConfirmation?
    /// BOOKING events only (K15/K17-A): a consent form one of this appointment's
    /// services requires and this client has not signed. A TEXT CHIP — never a
    /// colour, and never a second warning glyph, because the conflict triangle
    /// owns that shape (K7's channel budget).
    ///
    /// 🔴 ABSENT is the common case and means nothing is outstanding: web omits
    /// the key entirely, which is every booking until a pro binds a form to a
    /// service. Absent must decode fine and render NOTHING. Read it through
    /// `consentRequirementDisplay`.
    public let consentRequirement: ProConsentRequirement?
    /// BOOKING events only (K19-C/K20): this appointment is one occurrence of a
    /// recurring series. Rendered in the tile's TIME ROW beside the location
    /// chip — deliberately NOT a sixth chip and NOT a second corner glyph; see
    /// `ProRecurringMark` for the channel call.
    ///
    /// 🔴 ABSENT is the common case and means "not part of a series", which is
    /// every booking while `ENABLE_RECURRING_APPOINTMENTS` is unset. Absent must
    /// decode fine and render NOTHING. Read it through `recurringDisplay`.
    public let recurring: ProRecurringMark?

    public var isBooking: Bool { kind == "BOOKING" }
    public var isBlock: Bool { kind == "BLOCK" }
    public var isWaitlist: Bool { status == "WAITLIST" }

    /// A client's LIVE checkout reservation (B5) — read-only occupancy, so the
    /// pro's day tells the truth about what their time is doing.
    ///
    /// Deliberately anonymous server-side: `clientName` is a fixed label and no
    /// `clientProfileId` is sent, because a hold means somebody is mid-checkout
    /// this minute and the pro is told the slot is spoken for, not who is
    /// hesitating over it. It cannot be opened, dragged or resized — there is no
    /// pro-facing endpoint that takes a hold id, and it expires on its own.
    ///
    /// ⚠️ A hold is NOT a block. It must never fall into an `isBlock ? … : …`
    /// else-branch that assumes "booking", nor into a block's tap/edit path.
    public var isHold: Bool { kind == "HOLD" }

    /// The bare block id for block operations (`GET`/`PATCH`/`DELETE …/blocked/{id}`),
    /// which expect the un-namespaced id. Prefers the API's `blockId`, else strips a
    /// `block:` prefix off `id`, else falls back to `id`. Only meaningful for blocks.
    public var calendarBlockId: String {
        if let blockId, !blockId.isEmpty { return blockId }
        let prefix = "block:"
        if id.hasPrefix(prefix) { return String(id.dropFirst(prefix.count)) }
        return id
    }

    /// The swatch this tile's SERVICE stripe should paint, or nil to keep the
    /// status tone.
    ///
    /// Gated on `isBooking` deliberately, mirroring web's EventCard: a block is
    /// the pro's own time and a hold is a stranger mid-checkout — neither is a
    /// service, so neither may claim the service channel even if a future server
    /// were to send the field on one.
    public var serviceSwatchId: String? {
        guard isBooking else { return nil }
        return serviceSwatch?.id
    }

    /// The client-confirmation state this tile should mark, or nil to mark
    /// nothing.
    ///
    /// Gated on `isBooking` for the same reason `serviceSwatchId` is, mirroring
    /// web's EventCard (`ev.kind === 'BOOKING' && …`): a block is the pro's own
    /// time and a hold is a stranger mid-checkout — neither has a client who
    /// could be asked, so neither may claim the confirmation channel even if a
    /// future server were to send the field on one. `significant` is the web
    /// helper's own call about what is worth showing (NOT_REQUESTED is not);
    /// this view never second-guesses it.
    public var clientConfirmationDisplay: ProClientConfirmation.Display? {
        guard isBooking, let display = clientConfirmation?.display, display.significant
        else { return nil }
        return display
    }

    /// The unsigned-consent mark this tile should print, or nil to print
    /// nothing.
    ///
    /// Gated on `isBooking` for the same reason the two above are, mirroring
    /// web's EventCard (`ev.kind === 'BOOKING' && ev.consentRequirement`): a
    /// block is the pro's own time and a hold is a stranger mid-checkout —
    /// neither has a client who could sign anything.
    ///
    /// `significant` is web's helper deciding that an appointment which has
    /// already started is not worth warning about; this never second-guesses it.
    /// ⚠️ That gate is right HERE and wrong on the session hub, whose list is a
    /// different field for exactly that reason.
    public var consentRequirementDisplay: ProConsentRequirement.Display? {
        guard isBooking, let display = consentRequirement?.display, display.significant
        else { return nil }
        return display
    }

    /// The recurring mark this tile should print, or nil to print nothing.
    ///
    /// Gated on `isBooking` for the same reason the three above are, mirroring
    /// web's EventCard (`ev.kind === 'BOOKING' ? ev.recurring : null`): a block
    /// is the pro's own time and a hold is a stranger mid-checkout — neither is
    /// an occurrence of anything.
    ///
    /// 🔴 No `significant` check, and that is not an omission: `ProRecurringMark`
    /// carries no such flag, because recurrence is a fact rather than a warning
    /// that goes stale. A completed occurrence still says it was one.
    public var recurringDisplay: ProRecurringMark.Display? {
        guard isBooking else { return nil }
        return recurring?.display
    }

    /// Whether this row can be offered a concrete time the client then confirms.
    /// Mirrors web `ManagementModal`'s `canOfferTime`: a waitlist row that carries
    /// both an entry id and an active offering. A row without an offering has
    /// nothing bookable behind it, so neither platform offers an action for it.
    public var canOfferWaitlistTime: Bool {
        isWaitlist
            && !(waitlistEntryId?.isEmpty ?? true)
            && !(serviceId?.isEmpty ?? true)
            && !(offeringId?.isEmpty ?? true)
    }
}

public struct ProCalendarStats: Decodable, Sendable {
    public let todaysBookings: Int
    public let availableHours: Double?
    public let pendingRequests: Int
    public let blockedHours: Double
}

/// The management buckets the web surfaces in the side panel / stats tiles.
public struct ProCalendarManagement: Decodable, Sendable {
    public let todaysBookings: [ProCalendarEvent]
    public let pendingRequests: [ProCalendarEvent]
    public let waitlistToday: [ProCalendarEvent]
    public let blockedToday: [ProCalendarEvent]
}

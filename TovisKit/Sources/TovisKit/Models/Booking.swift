import Foundation

// Wire models for the booking flow — availability (bootstrap/day), holds, and
// finalize. Mirrors the web AvailabilityDrawer contract + lib/dto/holds.ts and
// the finalize route. Only the rendered subset is modeled.

// MARK: - Availability: bootstrap (GET /api/v1/availability/bootstrap)

public struct AvailabilityBootstrap: Decodable, Sendable {
    public let timeZone: String
    public let serviceName: String?
    public let request: AvailabilityRequestEcho
    public let availableDays: [AvailabilityDaySummary]
    public let selectedDay: AvailabilitySelectedDay?
    public let offering: AvailabilityOffering?

    /// The look this booking started from — the sheet's cover photo and the
    /// add-ons step's context thumbnail. Null when the flow was entered from a
    /// pro's profile rather than from a look, which the sheet renders as its
    /// cover-less header rather than an empty photo well.
    ///
    /// Optional (not just nullable) because a server that predates web #889 omits
    /// the key entirely — an absent cover must degrade to the plain header, never
    /// to a decode failure that takes the whole booking flow down.
    public let cover: AvailabilityCover?

    /// Reassurance chips under the service line (`lib/booking/trustSignals.ts`).
    /// Optional for the same reason as `cover`.
    public let trust: AvailabilityTrust?

    /// The pro this sheet is booking with. Only the bits the header renders —
    /// the caller already carries the display name.
    public let primaryPro: AvailabilityPrimaryPro?

    /// The pro's bookable salon/suite options. Match on `request.locationId` to
    /// find the one this booking is going to — an in-salon appointment's address
    /// belongs to the pro's LOCATION, and without it a confirmation can only say
    /// "In salon", which is a mode and not somewhere you can navigate to.
    /// Empty for a mobile booking, whose address is the client's own.
    public let locationOptions: [AvailabilityLocationOption]?

    /// A MOBILE pro's travel reach ("Travels up to 12 mi around Brooklyn, NY").
    /// Present in BOTH modes on the wire (the pro's reach is already in hand the
    /// moment the client toggles to Mobile), but only rendered in MOBILE mode —
    /// SALON mode names the salon itself instead. Null for a pro who has
    /// published neither a radius nor a base city/state.
    public let serviceArea: AvailabilityServiceArea?

    /// Where this booking is actually going, when the pro has a salon row for it.
    public func bookableLocation() -> AvailabilityLocationOption? {
        locationOptions?.first { $0.id == request.locationId }
    }
}

/// One bookable salon/suite for the primary pro. Wire twin of
/// `AvailabilityLocationOption`.
public struct AvailabilityLocationOption: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let city: String?
    public let state: String?
    public let formattedAddress: String?

    /// The coarse place ("Brooklyn, NY"), sent whenever the location has a city
    /// or state — published address or not. Render this when `formattedAddress`
    /// is null rather than showing no location at all (Tori, 2026-08-14: a
    /// client who doesn't know where a pro is located won't book).
    public let areaLabel: String?

    /// The full street address when the server has one, else the coarse area,
    /// else whatever locates this place — never the salon's NAME, which is a
    /// label and not an address.
    public var addressLine: String? {
        if let formatted = formattedAddress?.trimmedOrNil { return formatted }
        if let area = areaLabel?.trimmedOrNil { return area }
        let parts = [city?.trimmedOrNil, state?.trimmedOrNil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// A MOBILE pro's reach: how far they travel, and from where. Wire twin of
/// `AvailabilityServiceArea` (`lib/booking/AvailabilityDrawer/types.ts`).
///
/// Deliberately carries NO address — a mobile base is very often the pro's
/// home. Null radius/area both absent means the pro has published neither.
public struct AvailabilityServiceArea: Decodable, Sendable {
    public let radiusMiles: Int?
    public let areaLabel: String?
}

/// Wire twin of `AvailabilityCover` (the drawer's `types.ts`).
public struct AvailabilityCover: Decodable, Sendable {
    /// The downscaled `feed` render of the look when one can be derived, else
    /// the stored original (`lib/booking/bookingCover.ts`).
    public let imageUrl: String?
    /// The stored original, ONLY when `imageUrl` is a derived render of it —
    /// the render endpoint is a documented Pro-plan feature while the project
    /// is on Free, so a cover must be able to fall back the way the feed does
    /// (`LookFeedImage.fallbackURL`). nil when `imageUrl` already IS the
    /// original, so nothing retries the same URL.
    public let fallbackImageUrl: String?
    public let lookName: String?
}

/// Wire twin of `AvailabilityTrust`. Every field is nullable on purpose: a chip
/// whose signal is unknown is not rendered, rather than rendered as a zero.
public struct AvailabilityTrust: Decodable, Sendable {
    public let verified: Bool
    public let completedBookings: Int?
    public let rating: AvailabilityTrustRating?
    public let freeCancellationHours: Int?

    public init(
        verified: Bool,
        completedBookings: Int? = nil,
        rating: AvailabilityTrustRating? = nil,
        freeCancellationHours: Int? = nil
    ) {
        self.verified = verified
        self.completedBookings = completedBookings
        self.rating = rating
        self.freeCancellationHours = freeCancellationHours
    }
}

public struct AvailabilityTrustRating: Decodable, Sendable {
    public let average: Double
    public let count: Int

    public init(average: Double, count: Int) {
        self.average = average
        self.count = count
    }
}

public struct AvailabilityPrimaryPro: Decodable, Sendable {
    public let id: String
    public let avatarUrl: String?
}

/// Echo of the resolved request — notably `locationId`, which bootstrap resolves
/// for us (we don't have to pass one) and which `day`/`hold` then need.
public struct AvailabilityRequestEcho: Decodable, Sendable {
    public let professionalId: String
    public let serviceId: String
    public let offeringId: String?
    public let locationType: String
    public let locationId: String
    public let durationMinutes: Int
}

public struct AvailabilityDaySummary: Decodable, Sendable, Identifiable {
    public let date: String   // YYYY-MM-DD (pro timezone)
    public let slotCount: Int
    public var id: String { date }
}

public struct AvailabilitySelectedDay: Decodable, Sendable {
    public let date: String
    public let slots: [String] // ISO-8601 instants
}

public struct AvailabilityOffering: Decodable, Sendable {
    public let id: String
    public let salonPriceStartingAt: String?
    public let mobilePriceStartingAt: String?
    public let salonDurationMinutes: Int?
    public let mobileDurationMinutes: Int?
}

// MARK: - Availability: day (GET /api/v1/availability/day)

public struct AvailabilityDay: Decodable, Sendable {
    public let date: String
    public let timeZone: String
    public let slots: [String] // ISO-8601 instants
}

// MARK: - Offering add-ons (GET /api/v1/offerings/add-ons)

struct OfferingAddOnsResponse: Decodable, Sendable {
    let addOns: [BookingAddOn]
    /// The pro's no-show / late-cancel fee policy the client must agree to before
    /// booking (M15), formatted for display, or null when the pro charges no fees.
    /// Optional so older servers that omit it still decode. When present, the
    /// confirm flow shows it + requires the agreement toggle.
    let cancellationPolicy: String?
}

/// The confirm-flow needs both the add-ons and the pro's fee policy from one call.
public struct OfferingAddOnsResult: Sendable {
    public let addOns: [BookingAddOn]
    public let cancellationPolicy: String?
}

/// A selectable add-on for an offering in a given location mode. The `id` is the
/// OfferingAddOn link id — that's what goes back into finalize's `addOnIds`
/// (NOT `serviceId`). Add-ons don't affect the hold (same as web): they're only
/// applied at finalize, and the server derives the total duration/price.
///
/// `isRecommended` and `isPreselected` are two INDEPENDENT flags, not one:
/// `isRecommended` drives the "Recommended" badge only, while `isPreselected` is
/// the pro's own opt-in for "starts ticked" (Tori, 2026-08-14 — a recommended
/// add-on does NOT auto pre-select). Web reads exactly this split; keep the two
/// apart here or the pro's pre-select choice silently does nothing on iOS.
///
/// `isPreselected` decodes defensively (`decodeIfPresent ?? false`) because a
/// server predating the field sends no such key: a required decode would fail
/// the WHOLE add-ons response and leave the picker empty. `isRecommended` stays
/// a required decode — it has always been on the wire, and defaulting it would
/// mask a real server regression rather than tolerate an old one.
public struct BookingAddOn: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let serviceId: String
    public let title: String
    public let group: String?
    public let price: String   // formatted money, e.g. "25.00"
    public let minutes: Int
    public let sortOrder: Int
    public let isRecommended: Bool
    public let isPreselected: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        serviceId = try c.decode(String.self, forKey: .serviceId)
        title = try c.decode(String.self, forKey: .title)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        price = try c.decode(String.self, forKey: .price)
        minutes = try c.decode(Int.self, forKey: .minutes)
        sortOrder = try c.decode(Int.self, forKey: .sortOrder)
        isRecommended = try c.decode(Bool.self, forKey: .isRecommended)
        isPreselected = try c.decodeIfPresent(Bool.self, forKey: .isPreselected) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, serviceId, title, group, price, minutes, sortOrder
        case isRecommended, isPreselected
    }
}

// MARK: - Holds (POST /api/v1/holds)

struct CreateHoldRequest: Encodable, Sendable {
    let offeringId: String
    let locationType: String
    /// A HINT, not a requirement: `POST /holds` reads it with `pickString` and
    /// falls back to the pro's bookable location when it is absent. Omitted
    /// rather than sent blank when the caller has no id — the claim sheet has one
    /// only for SALON openings, since a MOBILE opening has no salon row.
    let locationId: String?
    let scheduledFor: String
    let source: String
    /// Required by the backend when locationType == MOBILE (the service address
    /// the pro travels to); omitted for SALON.
    let clientAddressId: String?
    /// OfferingAddOn link ids already chosen. The hold RESERVES `base +
    /// add-ons`, so sending them here is what makes the held window the window
    /// finalize will take — omitting them reserves the base service alone and
    /// the booking can be refused for time that was never held (B1-A).
    let addOnIds: [String]
    /// Set when this hold is picking a new time for an EXISTING booking. The
    /// server then sizes the reservation from that booking's committed
    /// `totalDurationMinutes` instead of the offering's current base, because
    /// that is what the reschedule will take — the two drift apart whenever a
    /// duration is edited (B3). Mutually exclusive with `addOnIds`: a
    /// reschedule keeps the booking's original add-ons. Omitted (not sent
    /// blank) for an ordinary booking.
    let rescheduleBookingId: String?
    /// Book the Look, B8. Set when the slot is being reserved for a consult's
    /// booking proposal: the server then sizes the reservation from that
    /// proposal's WHOLE estimate — sized for every enhancement she could still
    /// tick — instead of from the floor offering's base.
    ///
    /// 🔴 Mutually exclusive with `addOnIds`, and refused on the wire if both
    /// are sent: B7 answered the enhancement question with the estimate's own
    /// beyond-floor lines, which never travel as add-on ids.
    ///
    /// Optional, so it is omitted entirely from the encoded body for every
    /// ordinary hold — the wire for those paths is byte-identical to before.
    let consultId: String?
}

struct CreateHoldResponse: Decodable, Sendable {
    let hold: BookingHold
}

public struct BookingHold: Decodable, Sendable, Identifiable {
    public let id: String
    public let expiresAt: String
    public let scheduledFor: String
    public let locationType: String
    public let locationId: String?
    /// Minutes actually reserved (base + any add-ons sent with the create),
    /// excluding the location buffer. Optional so an older server that predates
    /// the field still decodes.
    public let durationMinutes: Int?
}

// MARK: - Hold re-sizing (PATCH /api/v1/holds/{id})

struct UpdateHoldAddOnsRequest: Encodable, Sendable {
    let addOnIds: [String]
}

struct UpdateHoldAddOnsResponse: Decodable, Sendable {
    let hold: BookingHoldSizing
}

/// What the hold now RESERVES after a re-size. A narrower shape than
/// `BookingHold` on purpose — the PATCH route answers with the sizing fields
/// only (no `locationType`/`locationId`), because nothing about the placement
/// can change once the hold exists.
public struct BookingHoldSizing: Decodable, Sendable, Identifiable {
    public let id: String
    public let scheduledFor: String
    public let expiresAt: String
    public let durationMinutes: Int
    public let endsAt: String
}

// MARK: - Finalize (POST /api/v1/bookings/finalize)

struct FinalizeBookingRequest: Encodable, Sendable {
    let holdId: String
    let offeringId: String
    let locationType: String
    let addOnIds: [String]
    let source: String
    /// The `LastMinuteOpening.id` when this booking is CLAIMING a last-minute
    /// opening (openings feed / priority offer). The server (finalize →
    /// `writeBoundary`) uses it to consume the opening (flip it to BOOKED, guarding
    /// against a double-claim) AND to apply the tier incentive the client was shown,
    /// so a claimed opening is charged at the advertised discount. `nil` for a normal
    /// booking — and, being optional, it's omitted from the encoded body then, so the
    /// finalize idempotency nonce (derived from the body) is unchanged for those.
    let openingId: String?
    /// The client ticked "I agree to the cancellation policy" at the confirm step
    /// (M15). Required by the server when the pro charges no-show/late-cancel fees.
    let cancellationPolicyAccepted: Bool
    /// Book the Look, B8 — the discovery reference the booking is attributed
    /// to. Present on the consult path because the proposal names the look it
    /// was derived from; `nil` (and omitted) everywhere else.
    let lookPostId: String?
    /// The consult that produced this booking. The write boundary re-derives
    /// the whole proposal under the session lock before it sizes or prices
    /// anything, so this stamps the booking — it does not carry a number.
    let consultId: String?
    /// Book the Look, B8 — the enhancements she TICKED, as estimate-line ids.
    ///
    /// 🔴 This list decides WHICH, never HOW MUCH: the server re-derives each
    /// one's price and duration from the pro's own menu. Absent or empty means
    /// the floor alone, which is what a booking with no consult sends and is
    /// correct.
    ///
    /// Optional rather than an always-sent `[]` so the encoded body — and
    /// therefore the derived idempotency nonce — is unchanged for every
    /// non-consult booking.
    let consultEnhancementLineIds: [String]?
}

struct FinalizeBookingResponse: Decodable, Sendable {
    let booking: FinalizedBooking
}

public struct FinalizedBooking: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let scheduledFor: String
    public let professionalId: String
}

// MARK: - Reschedule (POST /api/v1/bookings/[id]/reschedule)

struct RescheduleBookingRequest: Encodable, Sendable {
    let holdId: String
    let locationType: String
}

struct RescheduleBookingResponse: Decodable, Sendable {
    let booking: RescheduledBooking
}

public struct RescheduledBooking: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let scheduledFor: String
    public let locationType: String?
}

// MARK: - Cancel (POST /api/v1/bookings/[id]/cancel)

/// Honest, client-facing summary of what happened to the client's money on a
/// cancel (M6 / M15). Mirrors the server's `CancelRefundSummary`.
/// `status` ∈ `REFUND_ISSUED | FORFEITED | PROCESSING | FEE_CHARGED | NONE`;
/// `message` is the ready-to-show sentence; `refundedAmountCents` is present only
/// when a refund was actually issued; `lateCancelFeeChargedCents` is present only
/// when a late-cancellation fee was charged to the client's card (M15). The
/// `message` already names any fee, so a client can render it verbatim; the cents
/// field is there for richer surfaces. `FEE_CHARGED` means a fee was charged with
/// no refund/forfeiture — a non-`NONE` status so the alert surfaces it.
public struct CancelRefundSummary: Decodable, Sendable {
    public let status: String
    public let message: String
    public let refundedAmountCents: Int?
    public let lateCancelFeeChargedCents: Int?
}

/// The cancel route returns the fields at the top level (no `booking` wrapper):
/// `{ ok, id, status, sessionStep, meta, refund }`. Unknown keys (`ok`,
/// `sessionStep`, `meta`) are ignored by the synthesized decoder; `refund` is
/// optional so older servers that omit it still decode.
public struct CancelBookingResponse: Decodable, Sendable {
    public let id: String
    public let status: String
    public let refund: CancelRefundSummary?
}
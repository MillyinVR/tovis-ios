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
}

/// A selectable add-on for an offering in a given location mode. The `id` is the
/// OfferingAddOn link id — that's what goes back into finalize's `addOnIds`
/// (NOT `serviceId`). Add-ons don't affect the hold (same as web): they're only
/// applied at finalize, and the server derives the total duration/price.
public struct BookingAddOn: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let serviceId: String
    public let title: String
    public let group: String?
    public let price: String   // formatted money, e.g. "25.00"
    public let minutes: Int
    public let sortOrder: Int
    public let isRecommended: Bool
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
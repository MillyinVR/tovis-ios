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
    let locationId: String
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

/// The cancel route returns the fields at the top level (no `booking` wrapper):
/// `{ ok, id, status, sessionStep, meta }`.
struct CancelBookingResponse: Decodable, Sendable {
    let id: String
    let status: String
}
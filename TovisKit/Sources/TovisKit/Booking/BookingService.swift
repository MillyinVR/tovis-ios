import Foundation

/// The booking flow — the same endpoints the web AvailabilityDrawer uses:
/// availability bootstrap/day → create a hold → finalize the booking. v1 covers
/// SALON, no add-ons, and "request to book" (no in-app payment — that needs the
/// Stripe deep-link return). Authenticated (bearer token; client only).
public final class BookingService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/availability/bootstrap — opening window for an offering.
    /// `locationId` is resolved server-side; we read it back from `request`.
    public func bootstrap(
        professionalId: String,
        serviceId: String,
        offeringId: String,
        durationMinutes: Int,
        locationType: String = "SALON"
    ) async throws -> AvailabilityBootstrap {
        try await api.request("/availability/bootstrap", query: [
            URLQueryItem(name: "professionalId", value: professionalId),
            URLQueryItem(name: "serviceId", value: serviceId),
            URLQueryItem(name: "offeringId", value: offeringId),
            URLQueryItem(name: "locationType", value: locationType),
            URLQueryItem(name: "durationMinutes", value: String(durationMinutes)),
        ])
    }

    /// GET /api/v1/availability/day — exact slots for one date (YYYY-MM-DD).
    public func day(
        professionalId: String,
        serviceId: String,
        offeringId: String,
        locationId: String,
        durationMinutes: Int,
        date: String,
        locationType: String = "SALON"
    ) async throws -> AvailabilityDay {
        try await api.request("/availability/day", query: [
            URLQueryItem(name: "professionalId", value: professionalId),
            URLQueryItem(name: "serviceId", value: serviceId),
            URLQueryItem(name: "offeringId", value: offeringId),
            URLQueryItem(name: "locationType", value: locationType),
            URLQueryItem(name: "locationId", value: locationId),
            URLQueryItem(name: "durationMinutes", value: String(durationMinutes)),
            URLQueryItem(name: "date", value: date),
        ])
    }

    /// POST /api/v1/holds — reserve a slot briefly before finalizing.
    public func createHold(
        offeringId: String,
        locationId: String,
        scheduledFor: String,
        locationType: String = "SALON",
        source: String = "REQUESTED"
    ) async throws -> BookingHold {
        let payload = try JSONEncoder().encode(CreateHoldRequest(
            offeringId: offeringId, locationType: locationType,
            locationId: locationId, scheduledFor: scheduledFor, source: source
        ))
        let response: CreateHoldResponse = try await api.request(
            "/holds", method: .post, body: payload
        )
        return response.hold
    }

    /// POST /api/v1/bookings/finalize — turn a hold into a booking. Requires an
    /// idempotency key so a retry can't double-book.
    public func finalize(
        holdId: String,
        offeringId: String,
        locationType: String = "SALON",
        source: String = "REQUESTED",
        idempotencyKey: String
    ) async throws -> FinalizedBooking {
        let payload = try JSONEncoder().encode(FinalizeBookingRequest(
            holdId: holdId, offeringId: offeringId,
            locationType: locationType, addOnIds: [], source: source
        ))
        let response: FinalizeBookingResponse = try await api.request(
            "/bookings/finalize",
            method: .post,
            body: payload,
            headers: ["idempotency-key": idempotencyKey]
        )
        return response.booking
    }
}
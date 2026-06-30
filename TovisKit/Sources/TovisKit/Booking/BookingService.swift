import Foundation

/// The booking flow — the same endpoints the web AvailabilityDrawer uses:
/// availability bootstrap/day → create a hold → (optional add-ons) → finalize the
/// booking. v1 covers SALON + add-ons and "request to book" (no in-app payment —
/// that needs the Stripe deep-link return). Authenticated (bearer token; client only).
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

    /// GET /api/v1/availability/day — exact slots for one date (YYYY-MM-DD). For a
    /// MOBILE booking pass `clientAddressId` (the client's saved service address)
    /// so the slots respect the pro's travel radius for that location.
    public func day(
        professionalId: String,
        serviceId: String,
        offeringId: String,
        locationId: String,
        durationMinutes: Int,
        date: String,
        locationType: String = "SALON",
        clientAddressId: String? = nil
    ) async throws -> AvailabilityDay {
        var query = [
            URLQueryItem(name: "professionalId", value: professionalId),
            URLQueryItem(name: "serviceId", value: serviceId),
            URLQueryItem(name: "offeringId", value: offeringId),
            URLQueryItem(name: "locationType", value: locationType),
            URLQueryItem(name: "locationId", value: locationId),
            URLQueryItem(name: "durationMinutes", value: String(durationMinutes)),
            URLQueryItem(name: "date", value: date),
        ]
        if let clientAddressId, !clientAddressId.isEmpty {
            query.append(URLQueryItem(name: "clientAddressId", value: clientAddressId))
        }
        return try await api.request("/availability/day", query: query)
    }

    /// GET /api/v1/offerings/add-ons — selectable add-ons for an offering in a
    /// given location mode. Each returned `id` is the link id to pass back in
    /// finalize's `addOnIds`. Add-ons don't affect the hold (matches web).
    public func addOns(
        offeringId: String,
        locationType: String = "SALON"
    ) async throws -> [BookingAddOn] {
        let response: OfferingAddOnsResponse = try await api.request("/offerings/add-ons", query: [
            URLQueryItem(name: "offeringId", value: offeringId),
            URLQueryItem(name: "locationType", value: locationType),
        ])
        return response.addOns.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// POST /api/v1/holds — reserve a slot briefly before finalizing.
    public func createHold(
        offeringId: String,
        locationId: String,
        scheduledFor: String,
        locationType: String = "SALON",
        clientAddressId: String? = nil,
        source: String = "REQUESTED"
    ) async throws -> BookingHold {
        let payload = try JSONEncoder().encode(CreateHoldRequest(
            offeringId: offeringId, locationType: locationType,
            locationId: locationId, scheduledFor: scheduledFor, source: source,
            clientAddressId: clientAddressId
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
        addOnIds: [String] = [],
        source: String = "REQUESTED",
        idempotencyKey: String
    ) async throws -> FinalizedBooking {
        let payload = try JSONEncoder().encode(FinalizeBookingRequest(
            holdId: holdId, offeringId: offeringId,
            locationType: locationType, addOnIds: addOnIds, source: source
        ))
        let response: FinalizeBookingResponse = try await api.request(
            "/bookings/finalize",
            method: .post,
            body: payload,
            headers: ["idempotency-key": idempotencyKey]
        )
        return response.booking
    }

    /// POST /api/v1/bookings/{id}/reschedule — move a booking to a new time. The
    /// new slot must already be held (create the hold for the SAME offering, then
    /// pass its id here). Requires an idempotency key so a retry can't double-apply.
    public func reschedule(
        bookingId: String,
        holdId: String,
        locationType: String = "SALON",
        idempotencyKey: String
    ) async throws -> RescheduledBooking {
        let payload = try JSONEncoder().encode(
            RescheduleBookingRequest(holdId: holdId, locationType: locationType)
        )
        let response: RescheduleBookingResponse = try await api.request(
            "/bookings/\(bookingId)/reschedule",
            method: .post,
            body: payload,
            headers: ["idempotency-key": idempotencyKey]
        )
        return response.booking
    }

    /// POST /api/v1/bookings/{id}/cancel — cancel a booking. No body; the server
    /// applies its own refund policy (a client cancelling ≥24h out is refunded).
    /// Requires an idempotency key so a retry can't double-cancel. Returns the
    /// booking's new status.
    @discardableResult
    public func cancel(
        bookingId: String,
        idempotencyKey: String
    ) async throws -> String {
        let response: CancelBookingResponse = try await api.request(
            "/bookings/\(bookingId)/cancel",
            method: .post,
            body: Data("{}".utf8),
            headers: ["idempotency-key": idempotencyKey]
        )
        return response.status
    }
}
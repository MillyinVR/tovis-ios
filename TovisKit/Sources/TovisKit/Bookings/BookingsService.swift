import Foundation

/// Reads the client's bookings, bucketed (upcoming / pending / pre-booked /
/// waitlist / past) exactly as the web bookings page does
/// (`GET /api/v1/client/bookings`). Authenticated; CLIENT-only.
public final class BookingsService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/client/bookings → the bucketed bookings (envelope unwrapped).
    public func fetch() async throws -> ClientBookingBuckets {
        let response: ClientBookingsResponse = try await api.request("/client/bookings")
        return response.buckets
    }

    /// GET /api/v1/client/bookings/{id}/aftercare — the client's read of their
    /// own aftercare: care notes (once the pro has SENT the summary) + the pro's
    /// featured before/after pair. CLIENT-only, ownership-gated. Returns
    /// `canShowAftercare == false` when the surface shouldn't show yet.
    public func aftercare(bookingId: String) async throws -> ClientAftercareDetail {
        try await api.request("/client/bookings/\(bookingId)/aftercare")
    }

    /// POST /api/v1/client/bookings/{id}/consultation — approve or reject the
    /// pro's proposed consultation plan. The server is idempotent and a decision
    /// on an already-decided proposal still returns 200.
    public func decideConsultation(
        bookingId: String,
        _ decision: ConsultationDecision
    ) async throws {
        let payload = try JSONEncoder().encode(
            ConsultationDecisionRequest(action: decision.wire)
        )
        try await api.requestVoid(
            "/client/bookings/\(bookingId)/consultation",
            method: .post,
            body: payload
        )
    }

    /// POST /api/v1/client/bookings/{id}/media-consent — grant or revoke the pro's
    /// permission to feature this session's photos/video publicly (portfolio/Looks).
    /// Returns the resulting consent state. Idempotent.
    @discardableResult
    public func setMediaConsent(bookingId: String, granted: Bool) async throws -> Bool {
        let payload = try JSONEncoder().encode(MediaConsentRequest(granted: granted))
        let response: MediaConsentResponse = try await api.request(
            "/client/bookings/\(bookingId)/media-consent",
            method: .post,
            body: payload
        )
        return response.mediaUseConsent
    }

    /// POST /api/v1/client/bookings/{id}/aftercare-rebook — confirm or decline the
    /// pro's proposed next appointment. CONFIRM creates the booking at the pro's
    /// proposed time (returns it); DECLINE just records the decline. Idempotent.
    @discardableResult
    public func decideRebook(
        bookingId: String,
        confirm: Bool,
        idempotencyKey: String? = nil
    ) async throws -> RebookedBooking? {
        let payload = try JSONEncoder().encode(
            RebookDecisionRequest(action: confirm ? "CONFIRM" : "DECLINE")
        )
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "booking", entityId: bookingId, action: "aftercare-rebook",
            nonce: idempotencyNonce(payload))
        let response: RebookDecisionResponse = try await api.request(
            "/client/bookings/\(bookingId)/aftercare-rebook",
            method: .post,
            body: payload,
            headers: ["idempotency-key": key]
        )
        return response.booking
    }
}

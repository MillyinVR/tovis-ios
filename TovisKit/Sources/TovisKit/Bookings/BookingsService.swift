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

    /// GET /api/v1/client/aftercare → the client's aftercare inbox: every
    /// aftercare summary they've received (the AFTERCARE_READY feed), enriched
    /// with each visit's title / pro / before-after pair. The native counterpart
    /// to the web /client/aftercare page. CLIENT-only. Envelope unwrapped.
    public func aftercareInbox() async throws -> [ClientAftercareInboxItem] {
        let response: ClientAftercareInboxResponse = try await api.request("/client/aftercare")
        return response.items
    }

    /// Resolve a single `ClientBooking` by id from the bucketed list — there is no
    /// single-booking client GET, so a surface that only carries the booking id
    /// (e.g. the aftercare inbox) finds it here, then pushes `BookingDetailView`.
    /// Returns nil when the booking isn't among the client's recent bookings.
    public func booking(id: String) async throws -> ClientBooking? {
        let buckets = try await fetch()
        let all = buckets.upcoming + buckets.pending + buckets.prebooked + buckets.past
        return all.first { $0.id == id }
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
        let payload = try JSONEncoder.canonical.encode(
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
        let payload = try JSONEncoder.canonical.encode(MediaConsentRequest(granted: granted))
        let response: MediaConsentResponse = try await api.request(
            "/client/bookings/\(bookingId)/media-consent",
            method: .post,
            body: payload
        )
        return response.mediaUseConsent
    }

    /// GET /api/v1/client/waitlist-offers → the client's outstanding pro-proposed
    /// waitlist times (PENDING only), shown alongside priority offers on the
    /// offers screen. Confirm/decline via `respondToWaitlistOffer`. Envelope
    /// unwrapped. CLIENT-only.
    public func waitlistOffers() async throws -> [ClientWaitlistOffer] {
        let response: ClientWaitlistOfferResponse = try await api.request("/client/waitlist-offers")
        return response.offers
    }

    /// POST /api/v1/client/waitlist-offers/{id} — respond to a pro-proposed
    /// waitlist time. CONFIRM books the appointment at the offered slot (returns
    /// it, so the caller can open its detail); DECLINE frees the pro to offer
    /// another time (returns nil). Idempotent (same key ⇒ same body); the key is
    /// derived from the offer + action, matching the web WaitlistOfferCards.
    @discardableResult
    public func respondToWaitlistOffer(
        offerId: String,
        confirm: Bool,
        idempotencyKey: String? = nil
    ) async throws -> RebookedBooking? {
        let action = confirm ? "CONFIRM" : "DECLINE"
        let payload = try JSONEncoder.canonical.encode(WaitlistOfferActionRequest(action: action))
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "client-waitlist-offer", entityId: offerId, action: action)
        let response: WaitlistOfferRespondResponse = try await api.request(
            "/client/waitlist-offers/\(offerId)",
            method: .post,
            body: payload,
            headers: ["idempotency-key": key]
        )
        return response.booking
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
        let payload = try JSONEncoder.canonical.encode(
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

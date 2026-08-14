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
    ///
    /// The gated route **hard-requires** an `idempotency-key` header — without it
    /// it 400s with `IDEMPOTENCY_KEY_REQUIRED` before doing anything — so, like
    /// every other client mutation here (`respondToWaitlistOffer` / `decideRebook`),
    /// we mint a deterministic key. `action` (APPROVE/REJECT) is the only body
    /// field, so folding it into the key keeps approve and reject distinct (no
    /// 409 `IDEMPOTENCY_KEY_CONFLICT`) while a double-tap of the same decision
    /// inside one bucket dedupes.
    public func decideConsultation(
        bookingId: String,
        _ decision: ConsultationDecision,
        idempotencyKey: String? = nil
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ConsultationDecisionRequest(action: decision.wire)
        )
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "client-consultation-decision", entityId: bookingId, action: decision.wire)
        try await api.requestVoid(
            "/client/bookings/\(bookingId)/consultation",
            method: .post,
            body: payload,
            headers: ["idempotency-key": key]
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

    /// POST /api/v1/client/bookings/{id}/prep — tick (or untick) one row of the
    /// pro's "Before you go" checklist. CLIENT-only, ownership-gated.
    ///
    /// Returns the SERVER's resulting `checkedItemIds` — adopt it rather than
    /// toggling locally, because the route can refuse: it re-reads the booking
    /// inside its transaction and answers `409 PREP_NOT_WRITABLE` if the
    /// appointment has been cancelled or completed since the screen rendered,
    /// and `404` for a row belonging to another of the pro's services.
    ///
    /// Deliberately carries NO idempotency key: the route enforces none, and the
    /// write is an upsert/delete keyed on (booking, item), so a double tap of the
    /// same state is already a no-op and a change of mind must not collide with
    /// the client's own earlier tap.
    @discardableResult
    public func setPrepCheck(
        bookingId: String,
        prepItemId: String,
        checked: Bool
    ) async throws -> [String] {
        let payload = try JSONEncoder.canonical.encode(
            PrepCheckRequest(prepItemId: prepItemId, checked: checked)
        )
        let response: PrepCheckResponse = try await api.request(
            "/client/bookings/\(bookingId)/prep",
            method: .post,
            body: payload
        )
        return response.checkedItemIds
    }

    /// POST /api/v1/client/bookings/{id}/board — hand one of the client's own
    /// inspiration boards to the pro for THIS booking, or take it back.
    ///
    /// 🔴 A scoped disclosure, not a visibility change: the board's own
    /// `visibility` is never written, so a private board shared here stays
    /// private to everyone but this pro, on this booking, until it is revoked.
    ///
    /// Granting is refused (`409 PREP_NOT_WRITABLE`) once the appointment can no
    /// longer be prepared for; REVOKING is always allowed, whatever state the
    /// booking reached — a client must be able to withdraw a disclosure.
    /// Returns the server's resulting shared-board id list.
    @discardableResult
    public func setBoardShare(
        bookingId: String,
        boardId: String,
        shared: Bool
    ) async throws -> [String] {
        let payload = try JSONEncoder.canonical.encode(
            BookingBoardShareRequest(boardId: boardId, shared: shared)
        )
        let response: BookingBoardShareResponse = try await api.request(
            "/client/bookings/\(bookingId)/board",
            method: .post,
            body: payload
        )
        return response.sharedBoardIds
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

    /// POST /api/v1/client/bookings/{id}/confirmation — answer the pro's "can
    /// you make it?" from inside the app instead of hunting the reminder SMS
    /// back out of Messages (K13). CLIENT-only, ownership-gated.
    ///
    /// Shares web's locked core with the token link, so the DB outcome is
    /// byte-identical to tapping the SMS: the same stamp, the same refusals, and
    /// a DECLINE still notifies the pro. 🔴 Declining does NOT cancel anything —
    /// the appointment keeps its slot until the pro acts (decision D5).
    ///
    /// Deliberately carries NO idempotency key, unlike every other client
    /// mutation here: web's route enforces none, and re-stamping IS the designed
    /// behaviour (K11's latest-answer-wins), so a double tap or a change of mind
    /// is a feature rather than a replay hazard. Minting one anyway would make a
    /// client who changes their mind inside the same bucket collide with their
    /// own earlier answer.
    ///
    /// Returns the resulting state as the SERVER sees it — adopt that rather
    /// than assuming the answer landed, since the route can still refuse
    /// (`APPOINTMENT_CONFIRMATION_UNAVAILABLE`: loop off, booking cancelled or
    /// already underway).
    @discardableResult
    public func answerAppointmentConfirmation(
        bookingId: String,
        answer: AppointmentConfirmationAnswer
    ) async throws -> AppointmentConfirmationResult {
        let payload = try JSONEncoder.canonical.encode(
            AppointmentConfirmationRequest(answer: answer.rawValue)
        )
        return try await api.request(
            "/client/bookings/\(bookingId)/confirmation",
            method: .post,
            body: payload
        )
    }
}

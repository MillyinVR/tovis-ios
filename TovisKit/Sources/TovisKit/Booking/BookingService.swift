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
    /// A MOBILE placement REQUIRES `clientAddressId` — the server refuses the
    /// whole request with `CLIENT_SERVICE_ADDRESS_REQUIRED` (400) without it, so
    /// callers must resolve the client's service address before asking.
    ///
    /// Pass `rescheduleBookingId` when the flow is MOVING a booking: the server
    /// then sizes the window from that booking's committed duration instead of
    /// the offering's base, so the days marked bookable are the ones the
    /// reschedule can actually fit into (B3-A). It authenticates and checks
    /// ownership for that branch.
    ///
    /// NOTE `durationMinutes` is echoed back in `request` but is NOT an input —
    /// the server resolves the width itself and ignores the query value.
    public func bootstrap(
        professionalId: String,
        serviceId: String,
        offeringId: String,
        durationMinutes: Int,
        locationType: String = "SALON",
        clientAddressId: String? = nil,
        rescheduleBookingId: String? = nil
    ) async throws -> AvailabilityBootstrap {
        var query = [
            URLQueryItem(name: "professionalId", value: professionalId),
            URLQueryItem(name: "serviceId", value: serviceId),
            URLQueryItem(name: "offeringId", value: offeringId),
            URLQueryItem(name: "locationType", value: locationType),
            URLQueryItem(name: "durationMinutes", value: String(durationMinutes)),
        ]
        if let clientAddressId, !clientAddressId.isEmpty {
            query.append(URLQueryItem(name: "clientAddressId", value: clientAddressId))
        }
        if let rescheduleBookingId, !rescheduleBookingId.isEmpty {
            query.append(URLQueryItem(name: "rescheduleBookingId", value: rescheduleBookingId))
        }
        return try await api.request("/availability/bootstrap", query: query)
    }

    /// GET /api/v1/availability/day — exact slots for one date (YYYY-MM-DD). A
    /// MOBILE booking MUST pass `clientAddressId` (the client's saved service
    /// address) so the slots respect the pro's travel radius for that location —
    /// omitting it is a 400 `CLIENT_SERVICE_ADDRESS_REQUIRED`, not a fallback.
    ///
    /// `addOnIds` sizes the OFFER: the server folds each add-on's duration into
    /// the slot length, so a day asked without them offers starts that only fit
    /// the base service. This flow knows the selection before the time is
    /// picked, so it always sends what the client has ticked (B1-A).
    ///
    /// `rescheduleBookingId` sizes it the other way, for a MOVE: the reschedule
    /// commits the BOOKING's duration, which drifts from the offering's base
    /// whenever the pro edits a service. Without it the grid offers starts the
    /// reschedule refuses at the pick (B3-A). The two are mutually exclusive —
    /// a reschedule keeps its original add-ons — and sending both is refused.
    ///
    /// NOTE `durationMinutes` is echoed back but is NOT an input; the server
    /// resolves the width from the offering, the add-ons, or the booking.
    public func day(
        professionalId: String,
        serviceId: String,
        offeringId: String,
        locationId: String,
        durationMinutes: Int,
        date: String,
        locationType: String = "SALON",
        clientAddressId: String? = nil,
        addOnIds: [String] = [],
        rescheduleBookingId: String? = nil
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
        if !addOnIds.isEmpty {
            query.append(URLQueryItem(name: "addOnIds", value: addOnIds.sorted().joined(separator: ",")))
        }
        if let rescheduleBookingId, !rescheduleBookingId.isEmpty {
            query.append(URLQueryItem(name: "rescheduleBookingId", value: rescheduleBookingId))
        }
        return try await api.request("/availability/day", query: query)
    }

    /// GET /api/v1/offerings/add-ons — selectable add-ons for an offering in a
    /// given location mode. Each returned `id` is the link id to pass back in
    /// the availability query, the hold and finalize — all three size their
    /// window on the same selection.
    public func addOns(
        offeringId: String,
        locationType: String = "SALON"
    ) async throws -> OfferingAddOnsResult {
        let response: OfferingAddOnsResponse = try await api.request("/offerings/add-ons", query: [
            URLQueryItem(name: "offeringId", value: offeringId),
            URLQueryItem(name: "locationType", value: locationType),
        ])
        return OfferingAddOnsResult(
            addOns: response.addOns.sorted { $0.sortOrder < $1.sortOrder },
            cancellationPolicy: response.cancellationPolicy
        )
    }

    /// POST /api/v1/holds — reserve a slot briefly before finalizing.
    ///
    /// The reservation is sized `base + addOnIds`, matching what finalize will
    /// enforce. Pass the client's current selection: a base-sized hold leaves
    /// the add-on tail unreserved for someone else to take (B1-A).
    ///
    /// Pass `rescheduleBookingId` when the hold is moving an existing booking:
    /// the reschedule commits that booking's duration, not the offering's, so
    /// without it the reservation is short by however much the two have drifted
    /// (B3).
    public func createHold(
        offeringId: String,
        locationId: String?,
        scheduledFor: String,
        locationType: String = "SALON",
        clientAddressId: String? = nil,
        source: String = "REQUESTED",
        addOnIds: [String] = [],
        rescheduleBookingId: String? = nil
    ) async throws -> BookingHold {
        let payload = try JSONEncoder.canonical.encode(CreateHoldRequest(
            offeringId: offeringId, locationType: locationType,
            locationId: locationId, scheduledFor: scheduledFor, source: source,
            clientAddressId: clientAddressId, addOnIds: addOnIds,
            rescheduleBookingId: rescheduleBookingId
        ))
        let response: CreateHoldResponse = try await api.request(
            "/holds", method: .post, body: payload
        )
        return response.hold
    }

    /// POST /api/v1/bookings/finalize — turn a hold into a booking. Idempotent:
    /// omit `idempotencyKey` to derive a stable key from the hold + payload so a
    /// double-tap can't double-book, while a genuinely different finalize gets a
    /// fresh key.
    public func finalize(
        holdId: String,
        offeringId: String,
        locationType: String = "SALON",
        addOnIds: [String] = [],
        source: String = "REQUESTED",
        openingId: String? = nil,
        cancellationPolicyAccepted: Bool = false,
        idempotencyKey: String? = nil
    ) async throws -> FinalizedBooking {
        let payload = try JSONEncoder.canonical.encode(FinalizeBookingRequest(
            holdId: holdId, offeringId: offeringId,
            locationType: locationType, addOnIds: addOnIds, source: source,
            openingId: openingId,
            cancellationPolicyAccepted: cancellationPolicyAccepted
        ))
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "booking", entityId: holdId, action: "finalize",
            nonce: idempotencyNonce(payload))
        let response: FinalizeBookingResponse = try await api.request(
            "/bookings/finalize",
            method: .post,
            body: payload,
            headers: ["idempotency-key": key]
        )
        return response.booking
    }

    /// POST /api/v1/bookings/{id}/reschedule — move a booking to a new time. The
    /// new slot must already be held (create the hold for the SAME offering, then
    /// pass its id here). Idempotent: omit `idempotencyKey` to derive a stable key
    /// from the target booking + new hold so a retry can't double-apply.
    public func reschedule(
        bookingId: String,
        holdId: String,
        locationType: String = "SALON",
        idempotencyKey: String? = nil
    ) async throws -> RescheduledBooking {
        let payload = try JSONEncoder.canonical.encode(
            RescheduleBookingRequest(holdId: holdId, locationType: locationType)
        )
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "booking", entityId: bookingId, action: "reschedule",
            nonce: idempotencyNonce(payload))
        let response: RescheduleBookingResponse = try await api.request(
            "/bookings/\(bookingId)/reschedule",
            method: .post,
            body: payload,
            headers: ["idempotency-key": key]
        )
        return response.booking
    }

    /// POST /api/v1/bookings/{id}/cancel — cancel a booking. No body; the server
    /// applies its own refund policy (a client cancelling ≥24h out is refunded).
    /// Idempotent: omit `idempotencyKey` to derive a stable per-booking key so a
    /// retry can't double-cancel. Returns the full response, incl. the honest
    /// `refund` summary (M6) so the caller can tell the client what happened to
    /// their money.
    @discardableResult
    public func cancel(
        bookingId: String,
        idempotencyKey: String? = nil
    ) async throws -> CancelBookingResponse {
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "booking", entityId: bookingId, action: "cancel")
        let response: CancelBookingResponse = try await api.request(
            "/bookings/\(bookingId)/cancel",
            method: .post,
            body: Data("{}".utf8),
            headers: ["idempotency-key": key]
        )
        return response
    }
}
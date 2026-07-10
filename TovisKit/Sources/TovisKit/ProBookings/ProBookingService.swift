import Foundation

/// PRO workspace — the bookings *list* (`GET /pro/bookings`, tovis-app PR #435)
/// plus one booking's detail and the management actions the web `/pro/bookings`
/// surfaces offer: **accept** a pending request, **cancel**, and **rebook**
/// (propose the client's next appointment). Authenticated; PRO-only (CLIENT
/// tokens 403). See docs/PRO-BACKEND-CONTRACTS.md.
public final class ProBookingService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/bookings?status= → the bucketed bookings list (web
    /// `/pro/bookings`): today/upcoming/past/cancelled + at-a-glance stats. Pass
    /// nil for the default ALL view.
    public func list(status: String? = nil) async throws -> ProBookingsListResponse {
        let query = status.map { [URLQueryItem(name: "status", value: $0)] }
        return try await api.request("/pro/bookings", query: query)
    }

    /// GET /api/v1/pro/aftercare → the "all aftercare" list (web `/pro/aftercare`):
    /// Draft / Sent / Finished cards + rebook chips + before/after thumbs.
    public func aftercareList() async throws -> [ProAftercareCardItem] {
        let response: ProAftercareListResponse = try await api.request("/pro/aftercare")
        return response.items
    }

    /// GET /api/v1/pro/bookings/{id} → the full booking detail.
    public func detail(bookingId: String) async throws -> ProBookingDetail {
        let response: ProBookingDetailResponse = try await api.request(
            "/pro/bookings/\(bookingId)"
        )
        return response.booking
    }

    /// GET /api/v1/pro/services?locationType=SALON|MOBILE → the pro's sellable
    /// services for that location mode. This is the flat picker source the web
    /// calendar BookingModal uses to edit a booking's services; each row's `id`
    /// is the *serviceId*, paired with its `offeringId`. Pass the booking's own
    /// `locationType` so `selectedMode` resolves to that mode's price + duration.
    public func sellableServices(locationType: String) async throws -> [ProSellableService] {
        let response: ProSellableServicesResponse = try await api.request(
            "/pro/services",
            query: [URLQueryItem(name: "locationType", value: locationType)]
        )
        return response.services
    }

    /// PATCH /api/v1/pro/bookings/{id} { serviceItems } — replace the services on
    /// an existing booking (the web calendar BookingModal's service editor; the
    /// first native "change the services on a booking" write). The server
    /// re-derives every price + duration + BASE/ADD_ON from the offering and sort
    /// position, so only `{ serviceId, offeringId, sortOrder }` per item is sent:
    /// the first item (sortOrder 0) becomes the BASE, the rest ADD_ONs. Never send
    /// a duration alongside — the route cross-checks it and 400s (`DURATION_MISMATCH`)
    /// on a conflict. Set `notifyClient` to text/email the client about the change.
    /// Editable while the booking is non-terminal (the route rejects CANCELLED /
    /// COMPLETED). Idempotent via the idempotency-key header — the body-derived
    /// nonce mints a fresh key whenever the item set changes.
    public func editServiceItems(
        bookingId: String,
        items: [ProBookingServiceItemInput],
        notifyClient: Bool = false,
        idempotencyKey: String? = nil
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProBookingEditServiceItemsRequest(serviceItems: items, notifyClient: notifyClient)
        )
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "pro-booking", entityId: bookingId, action: "edit-service-items",
            nonce: idempotencyNonce(payload))
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)",
            method: .patch,
            body: payload,
            headers: ["idempotency-key": key]
        )
    }

    /// PATCH /api/v1/pro/bookings/{id} {status:"ACCEPTED"} — accept a pending
    /// request (notifies the client). Idempotent via the idempotency-key header.
    public func accept(
        bookingId: String,
        notifyClient: Bool = true,
        idempotencyKey: String? = nil
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProBookingStatusRequest(status: "ACCEPTED", notifyClient: notifyClient)
        )
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "pro-booking", entityId: bookingId, action: "accept",
            nonce: idempotencyNonce(payload))
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)",
            method: .patch,
            body: payload,
            headers: ["idempotency-key": key]
        )
    }

    /// PATCH /api/v1/pro/bookings/{id} {status:"CANCELLED"} — deny a PENDING
    /// request from the calendar's quick-action bar (web management deny). Unlike
    /// `cancel`, this hits the base status route (no refund flow for a pending one).
    public func decline(
        bookingId: String,
        notifyClient: Bool = true,
        idempotencyKey: String? = nil
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProBookingStatusRequest(status: "CANCELLED", notifyClient: notifyClient)
        )
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "pro-booking", entityId: bookingId, action: "decline",
            nonce: idempotencyNonce(payload))
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)",
            method: .patch,
            body: payload,
            headers: ["idempotency-key": key]
        )
    }

    /// PATCH /api/v1/pro/bookings/{id}/cancel — cancel a PENDING/ACCEPTED booking
    /// (auto-refunds the client). Idempotent.
    public func cancel(
        bookingId: String,
        reason: String? = nil,
        idempotencyKey: String? = nil
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(ProBookingCancelRequest(reason: reason))
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "pro-booking", entityId: bookingId, action: "cancel",
            nonce: idempotencyNonce(payload))
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)/cancel",
            method: .patch,
            body: payload,
            headers: ["idempotency-key": key]
        )
    }

    /// POST /api/v1/pro/bookings/{id}/session/start — start the live session for an
    /// ACCEPTED booking (web "Start booking"). Idempotent.
    public func startSession(
        bookingId: String,
        idempotencyKey: String? = nil
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(["explicitSelection": true])
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "pro-booking", entityId: bookingId, action: "session-start")
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)/session/start",
            method: .post,
            body: payload,
            headers: ["idempotency-key": key]
        )
    }

    /// POST /api/v1/bookings/{id}/refund — refund a captured Stripe payment. Omit
    /// `amountCents` to refund in full. Idempotent. (Note: this is the shared
    /// `/bookings` route, not a `/pro` route.)
    public func refund(
        bookingId: String,
        amountCents: Int? = nil,
        reason: String? = nil,
        idempotencyKey: String? = nil
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(ProRefundRequest(amountCents: amountCents, reason: reason))
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "booking", entityId: bookingId, action: "refund",
            nonce: idempotencyNonce(payload))
        try await api.requestVoid(
            "/bookings/\(bookingId)/refund",
            method: .post,
            body: payload,
            headers: ["idempotency-key": key]
        )
    }

    /// GET /api/v1/bookings/{id}/money-trail — the read-only "money trail" for a
    /// booking: every charge, fee, and refund plus the capability flags gating the
    /// refund / waive actions. PRO sees their OWN bookings only (a foreign booking
    /// 404s, indistinguishable from a missing one). Like `refund`, this is the
    /// shared `/bookings` route, not a `/pro` route.
    public func moneyTrail(bookingId: String) async throws -> ProBookingMoneyTrail {
        let response: ProBookingMoneyTrailResponse = try await api.request(
            "/bookings/\(bookingId)/money-trail"
        )
        return response.trail
    }

    /// POST /api/v1/pro/bookings/{id}/rebook — propose the client's next
    /// appointment. `BOOK` schedules it (needs `scheduledFor`); `RECOMMEND_WINDOW`
    /// suggests a date range; `CLEAR` removes a prior proposal. Idempotent.
    public func rebook(
        bookingId: String,
        mode: ProRebookMode,
        scheduledFor: String? = nil,
        windowStart: String? = nil,
        windowEnd: String? = nil,
        idempotencyKey: String? = nil
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProRebookRequest(
                mode: mode.rawValue,
                scheduledFor: scheduledFor,
                windowStart: windowStart,
                windowEnd: windowEnd
            )
        )
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "pro-booking", entityId: bookingId, action: "rebook",
            nonce: idempotencyNonce(payload))
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)/rebook",
            method: .post,
            body: payload,
            headers: ["idempotency-key": key]
        )
    }

    /// POST /api/v1/pro/bookings/{id}/checkout/mark-paid — record that the client
    /// paid in person (for clients who never self-checkout). The chosen method is
    /// stored on the booking and closes checkout. Idempotent.
    public func markPaid(
        bookingId: String,
        selectedPaymentMethod: String,
        idempotencyKey: String? = nil
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(["selectedPaymentMethod": selectedPaymentMethod])
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "pro-booking", entityId: bookingId, action: "mark-paid",
            nonce: idempotencyNonce(payload))
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)/checkout/mark-paid",
            method: .post,
            body: payload,
            headers: ["idempotency-key": key]
        )
    }

    /// POST /api/v1/pro/bookings/{id}/checkout/confirm-payment — confirm receipt of
    /// an off-platform payment the client already marked as sent (checkout state
    /// AWAITING_CONFIRMATION → PAID). Distinct from `markPaid`: the method was
    /// recorded at client checkout, so there is **no body**. Confirming also
    /// auto-approves any aftercare next appointment coupled to this payment — the
    /// approved ids come back in `meta.approvedNextAppointmentBookingIds`. The
    /// route rejects a missing idempotency-key header, so one is always minted.
    @discardableResult
    public func confirmPayment(
        bookingId: String,
        idempotencyKey: String? = nil
    ) async throws -> ProConfirmPaymentResponse {
        // No body ⇒ no nonce; the scope+entity+action key is stable across a 60s
        // double-tap so the server replays instead of re-running the side effect.
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "pro-booking", entityId: bookingId, action: "confirm-payment")
        return try await api.request(
            "/pro/bookings/\(bookingId)/checkout/confirm-payment",
            method: .post,
            headers: ["idempotency-key": key]
        )
    }

    /// POST /api/v1/pro/bookings — create a booking. Pass `clientId` for an
    /// existing client, OR `client` to create a new (unclaimed) one inline — the
    /// backend resolves either. The `idempotencyKey` must follow "same key ⇒ same
    /// body": keep it stable only across an identical network re-send, and mint a
    /// NEW key whenever the body changes (e.g. an override retry that adds an
    /// `allow*` flag) — reusing a key with a changed body is a 409 conflict.
    /// Returns the new booking id plus, for a freshly
    /// created unclaimed client, its claim status and one-time invite token so
    /// the caller can confirm/share the claim link. `locationType` is
    /// "SALON" | "MOBILE"; a MOBILE booking also needs the client's service
    /// address — pass EITHER `clientAddressId` (an existing saved address) OR
    /// `serviceAddress` (a new one). The `allow*` overrides force-create past
    /// scheduling guards (outside hours / short notice / far future); pair them
    /// with `overrideReason` for the audit log.
    @discardableResult
    public func createBooking(
        clientId: String? = nil,
        client: ProNewBookingClient? = nil,
        offeringId: String,
        locationId: String,
        locationType: String,
        scheduledFor: String,
        clientAddressId: String? = nil,
        serviceAddress: ProServiceAddressInput? = nil,
        internalNotes: String? = nil,
        allowOutsideWorkingHours: Bool = false,
        allowShortNotice: Bool = false,
        allowFarFuture: Bool = false,
        overrideReason: String? = nil,
        idempotencyKey: String? = nil
    ) async throws -> ProBookingCreateResult {
        let payload = try JSONEncoder.canonical.encode(
            ProBookingCreateRequest(
                clientId: clientId,
                client: client,
                offeringId: offeringId,
                locationId: locationId,
                locationType: locationType,
                scheduledFor: scheduledFor,
                clientAddressId: clientAddressId,
                serviceAddress: serviceAddress,
                internalNotes: internalNotes,
                allowOutsideWorkingHours: allowOutsideWorkingHours,
                allowShortNotice: allowShortNotice,
                allowFarFuture: allowFarFuture,
                overrideReason: overrideReason,
            )
        )
        // Body-derived fallback: whenever the caller doesn't pin a key, the key
        // tracks the exact body — so an added override flag (a changed body)
        // yields a new key automatically instead of a 409 conflict.
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "pro-booking", entityId: offeringId, action: "create",
            nonce: idempotencyNonce(payload))
        let response: ProBookingCreateResponse = try await api.request(
            "/pro/bookings",
            method: .post,
            body: payload,
            headers: ["idempotency-key": key]
        )
        return ProBookingCreateResult(
            bookingId: response.booking.id,
            clientId: response.client?.id,
            claimStatus: response.client?.claimStatus,
            inviteToken: response.invite?.token
        )
    }

    /// GET /api/v1/pro/bookings/{id}/aftercare — the booking + its existing
    /// aftercare summary (prefill for the authoring screen).
    public func aftercareDetail(bookingId: String) async throws -> ProAftercareBooking {
        let response: ProAftercareDetailResponse = try await api.request(
            "/pro/bookings/\(bookingId)/aftercare"
        )
        return response.booking
    }

    /// POST /api/v1/pro/bookings/{id}/aftercare — save a draft (`sendToClient`
    /// false) or finalize + send to the client (true). Idempotent.
    public func saveAftercare(
        bookingId: String,
        request: ProAftercareSaveRequest,
        idempotencyKey: String? = nil
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(request)
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "pro-booking", entityId: bookingId, action: "aftercare-save",
            nonce: idempotencyNonce(payload))
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)/aftercare",
            method: .post,
            body: payload,
            headers: ["idempotency-key": key]
        )
    }

    /// POST /api/v1/pro/bookings/{id}/aftercare/send — send an already-saved
    /// aftercare draft to the client (the one-tap "Send" on a draft card in the
    /// aftercare list). Flips the draft to sent, queues the magic-link delivery,
    /// and raises AFTERCARE_READY. Idempotent — a no-op if it was already sent.
    public func sendAftercareDraft(bookingId: String) async throws {
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)/aftercare/send",
            method: .post
        )
    }

    /// POST /api/v1/pro/bookings/{id}/aftercare/nudge — re-ping a client about an
    /// aftercare that was already sent (the one-tap "Nudge" on the aftercare list).
    /// Re-issues the aftercare magic link and refreshes the AFTERCARE_READY
    /// notification. Only valid once the summary has been sent. Deliberately
    /// non-idempotent — each call re-sends, so no idempotency key is used; spam is
    /// bounded by the server's pro write rate limit.
    public func nudgeAftercare(bookingId: String) async throws {
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)/aftercare/nudge",
            method: .post
        )
    }

    /// POST /api/v1/pro/bookings/{id}/checkout/waive — waive the booking's checkout
    /// (no payment owed). Idempotent. (Wired for completeness; the web pro screens
    /// don't surface a waive button today.)
    public func waiveCheckout(
        bookingId: String,
        reason: String? = nil,
        idempotencyKey: String? = nil
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(["reason": reason])
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "pro-booking", entityId: bookingId, action: "waive-checkout",
            nonce: idempotencyNonce(payload))
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)/checkout/waive",
            method: .post,
            body: payload,
            headers: ["idempotency-key": key]
        )
    }
}

public enum ProRebookMode: String, Sendable {
    case book = "BOOK"
    case recommendWindow = "RECOMMEND_WINDOW"
    case clear = "CLEAR"
}

struct ProBookingStatusRequest: Encodable {
    let status: String
    let notifyClient: Bool
}

struct ProBookingCancelRequest: Encodable {
    let reason: String?
}

/// PATCH /pro/bookings/{id} body for a service-items edit. Carries only the
/// minimal per-item pair the route reads — the server re-derives name, price,
/// duration, and BASE/ADD_ON from the offering + sort position.
struct ProBookingEditServiceItemsRequest: Encodable {
    let serviceItems: [ProBookingServiceItemInput]
    let notifyClient: Bool
}

/// One requested service item for a `PATCH /pro/bookings/{id}` service-items edit.
/// `sortOrder` 0 is the BASE; the rest are ADD_ONs. No price/duration/name — those
/// are re-derived server-side from the offering.
public struct ProBookingServiceItemInput: Encodable, Sendable {
    public let serviceId: String
    public let offeringId: String
    public let sortOrder: Int

    public init(serviceId: String, offeringId: String, sortOrder: Int) {
        self.serviceId = serviceId
        self.offeringId = offeringId
        self.sortOrder = sortOrder
    }
}

struct ProRebookRequest: Encodable {
    let mode: String
    let scheduledFor: String?
    let windowStart: String?
    let windowEnd: String?
}

/// Refund body. Optionals are dropped from the JSON when nil (synthesized
/// `encodeIfPresent`), so omitting `amountCents` requests a full refund — matching
/// the web RefundButton.
struct ProRefundRequest: Encodable {
    let amountCents: Int?
    let reason: String?
}

/// POST /pro/bookings body (the subset the native form sends — an existing or
/// new client + an offering/location, plus a MOBILE service address). Nil
/// optionals are dropped from the JSON, so the body carries either `clientId` or
/// `client` (never both) and, for MOBILE, either `clientAddressId` or
/// `serviceAddress` (never both); both are omitted for SALON.
struct ProBookingCreateRequest: Encodable {
    let clientId: String?
    let client: ProNewBookingClient?
    let offeringId: String
    let locationId: String
    let locationType: String
    let scheduledFor: String
    let clientAddressId: String?
    let serviceAddress: ProServiceAddressInput?
    let internalNotes: String?
    let allowOutsideWorkingHours: Bool
    let allowShortNotice: Bool
    let allowFarFuture: Bool
    let overrideReason: String?
}

/// A new MOBILE service address sent inline with a booking (the client has no
/// saved address to pick). Mirrors the web NewBookingForm `serviceAddress`
/// payload + the backend `pickServiceAddressPayload` contract. Nil optionals are
/// dropped from the JSON; the backend geocodes when lat/lng are absent.
public struct ProServiceAddressInput: Encodable, Sendable {
    public let label: String?
    public let formattedAddress: String?
    public let addressLine1: String?
    public let addressLine2: String?
    public let city: String?
    public let state: String?
    public let postalCode: String?
    public let countryCode: String?
    public let placeId: String?
    public let lat: Double?
    public let lng: Double?
    public let isDefault: Bool

    public init(
        label: String? = nil,
        formattedAddress: String? = nil,
        addressLine1: String? = nil,
        addressLine2: String? = nil,
        city: String? = nil,
        state: String? = nil,
        postalCode: String? = nil,
        countryCode: String? = nil,
        placeId: String? = nil,
        lat: Double? = nil,
        lng: Double? = nil,
        isDefault: Bool = false
    ) {
        self.label = label
        self.formattedAddress = formattedAddress
        self.addressLine1 = addressLine1
        self.addressLine2 = addressLine2
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.countryCode = countryCode
        self.placeId = placeId
        self.lat = lat
        self.lng = lng
        self.isDefault = isDefault
    }
}

/// A new (unclaimed) client to create inline with a booking. The server requires
/// first + last name + email; phone is optional.
public struct ProNewBookingClient: Encodable, Sendable {
    public let firstName: String
    public let lastName: String
    public let email: String
    public let phone: String?

    public init(firstName: String, lastName: String, email: String, phone: String?) {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phone = phone
    }
}

/// POST /pro/bookings → `{ ok, booking: { id, … }, client: { id, claimStatus },
/// invite?: { id, token } }`. The `invite.token` is the raw claim token, sent
/// back exactly once for immediate display/sharing (the server has already
/// enqueued the SMS/email); it's null for an already-claimed client.
struct ProBookingCreateResponse: Decodable {
    let booking: CreatedBooking
    let client: CreatedClient?
    let invite: CreatedInvite?

    struct CreatedBooking: Decodable { let id: String }
    struct CreatedClient: Decodable {
        let id: String?
        let claimStatus: String?
    }
    struct CreatedInvite: Decodable { let token: String? }
}

/// The outcome of creating a booking: always the new booking id, plus — when
/// the booking created a brand-new unclaimed client — that client's id, its
/// claim status, and the one-time raw claim-invite token (nil for an existing
/// or already-claimed client). Callers can use `invitedUnclaimedClient` to show
/// a "claim invite sent" confirmation or offer to share the link.
public struct ProBookingCreateResult: Sendable {
    public let bookingId: String
    public let clientId: String?
    public let claimStatus: String?
    public let inviteToken: String?

    public init(bookingId: String, clientId: String?, claimStatus: String?, inviteToken: String?) {
        self.bookingId = bookingId
        self.clientId = clientId
        self.claimStatus = claimStatus
        self.inviteToken = inviteToken
    }

    /// True when this booking just created an unclaimed client who was sent a
    /// claim invite (the server delivers it; `inviteToken` is the shareable link
    /// token when present).
    public var invitedUnclaimedClient: Bool {
        claimStatus?.uppercased() == "UNCLAIMED"
    }
}

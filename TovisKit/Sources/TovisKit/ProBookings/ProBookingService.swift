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

    /// PATCH /api/v1/pro/bookings/{id} {status:"ACCEPTED"} — accept a pending
    /// request (notifies the client). Idempotent via the idempotency-key header.
    public func accept(
        bookingId: String,
        notifyClient: Bool = true,
        idempotencyKey: String = UUID().uuidString
    ) async throws {
        let payload = try JSONEncoder().encode(
            ProBookingStatusRequest(status: "ACCEPTED", notifyClient: notifyClient)
        )
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)",
            method: .patch,
            body: payload,
            headers: ["idempotency-key": idempotencyKey]
        )
    }

    /// PATCH /api/v1/pro/bookings/{id} {status:"CANCELLED"} — deny a PENDING
    /// request from the calendar's quick-action bar (web management deny). Unlike
    /// `cancel`, this hits the base status route (no refund flow for a pending one).
    public func decline(
        bookingId: String,
        notifyClient: Bool = true,
        idempotencyKey: String = UUID().uuidString
    ) async throws {
        let payload = try JSONEncoder().encode(
            ProBookingStatusRequest(status: "CANCELLED", notifyClient: notifyClient)
        )
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)",
            method: .patch,
            body: payload,
            headers: ["idempotency-key": idempotencyKey]
        )
    }

    /// PATCH /api/v1/pro/bookings/{id}/cancel — cancel a PENDING/ACCEPTED booking
    /// (auto-refunds the client). Idempotent.
    public func cancel(
        bookingId: String,
        reason: String? = nil,
        idempotencyKey: String = UUID().uuidString
    ) async throws {
        let payload = try JSONEncoder().encode(ProBookingCancelRequest(reason: reason))
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)/cancel",
            method: .patch,
            body: payload,
            headers: ["idempotency-key": idempotencyKey]
        )
    }

    /// POST /api/v1/pro/bookings/{id}/session/start — start the live session for an
    /// ACCEPTED booking (web "Start booking"). Idempotent.
    public func startSession(
        bookingId: String,
        idempotencyKey: String = UUID().uuidString
    ) async throws {
        let payload = try JSONEncoder().encode(["explicitSelection": true])
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)/session/start",
            method: .post,
            body: payload,
            headers: ["idempotency-key": idempotencyKey]
        )
    }

    /// POST /api/v1/bookings/{id}/refund — refund a captured Stripe payment. Omit
    /// `amountCents` to refund in full. Idempotent. (Note: this is the shared
    /// `/bookings` route, not a `/pro` route.)
    public func refund(
        bookingId: String,
        amountCents: Int? = nil,
        reason: String? = nil,
        idempotencyKey: String = UUID().uuidString
    ) async throws {
        let payload = try JSONEncoder().encode(ProRefundRequest(amountCents: amountCents, reason: reason))
        try await api.requestVoid(
            "/bookings/\(bookingId)/refund",
            method: .post,
            body: payload,
            headers: ["idempotency-key": idempotencyKey]
        )
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
        idempotencyKey: String = UUID().uuidString
    ) async throws {
        let payload = try JSONEncoder().encode(
            ProRebookRequest(
                mode: mode.rawValue,
                scheduledFor: scheduledFor,
                windowStart: windowStart,
                windowEnd: windowEnd
            )
        )
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)/rebook",
            method: .post,
            body: payload,
            headers: ["idempotency-key": idempotencyKey]
        )
    }

    /// POST /api/v1/pro/bookings/{id}/checkout/mark-paid — record that the client
    /// paid in person (for clients who never self-checkout). The chosen method is
    /// stored on the booking and closes checkout. Idempotent.
    public func markPaid(
        bookingId: String,
        selectedPaymentMethod: String,
        idempotencyKey: String = UUID().uuidString
    ) async throws {
        let payload = try JSONEncoder().encode(["selectedPaymentMethod": selectedPaymentMethod])
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)/checkout/mark-paid",
            method: .post,
            body: payload,
            headers: ["idempotency-key": idempotencyKey]
        )
    }

    /// POST /api/v1/pro/bookings — create a booking. Pass `clientId` for an
    /// existing client, OR `client` to create a new (unclaimed) one inline — the
    /// backend resolves either. Requires an idempotency key (fresh per attempt).
    /// Returns the new booking id. `locationType` is "SALON" | "MOBILE" (MOBILE
    /// also needs an address — not wired natively yet). The `allow*` overrides
    /// force-create past scheduling guards (outside hours / short notice / far future).
    @discardableResult
    public func createBooking(
        clientId: String? = nil,
        client: ProNewBookingClient? = nil,
        offeringId: String,
        locationId: String,
        locationType: String,
        scheduledFor: String,
        internalNotes: String? = nil,
        allowOutsideWorkingHours: Bool = false,
        allowShortNotice: Bool = false,
        allowFarFuture: Bool = false,
        overrideReason: String? = nil,
        idempotencyKey: String = UUID().uuidString
    ) async throws -> String {
        let payload = try JSONEncoder().encode(
            ProBookingCreateRequest(
                clientId: clientId,
                client: client,
                offeringId: offeringId,
                locationId: locationId,
                locationType: locationType,
                scheduledFor: scheduledFor,
                internalNotes: internalNotes,
                allowOutsideWorkingHours: allowOutsideWorkingHours,
                allowShortNotice: allowShortNotice,
                allowFarFuture: allowFarFuture,
                overrideReason: overrideReason,
            )
        )
        let response: ProBookingCreateResponse = try await api.request(
            "/pro/bookings",
            method: .post,
            body: payload,
            headers: ["idempotency-key": idempotencyKey]
        )
        return response.booking.id
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
        idempotencyKey: String = UUID().uuidString
    ) async throws {
        let payload = try JSONEncoder().encode(request)
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)/aftercare",
            method: .post,
            body: payload,
            headers: ["idempotency-key": idempotencyKey]
        )
    }

    /// POST /api/v1/pro/bookings/{id}/checkout/waive — waive the booking's checkout
    /// (no payment owed). Idempotent. (Wired for completeness; the web pro screens
    /// don't surface a waive button today.)
    public func waiveCheckout(
        bookingId: String,
        reason: String? = nil,
        idempotencyKey: String = UUID().uuidString
    ) async throws {
        let payload = try JSONEncoder().encode(["reason": reason])
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)/checkout/waive",
            method: .post,
            body: payload,
            headers: ["idempotency-key": idempotencyKey]
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
/// new client + a salon offering/location). Nil optionals are dropped from the
/// JSON, so the body carries either `clientId` or `client`, never both.
struct ProBookingCreateRequest: Encodable {
    let clientId: String?
    let client: ProNewBookingClient?
    let offeringId: String
    let locationId: String
    let locationType: String
    let scheduledFor: String
    let internalNotes: String?
    let allowOutsideWorkingHours: Bool
    let allowShortNotice: Bool
    let allowFarFuture: Bool
    let overrideReason: String?
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

/// POST /pro/bookings → `{ ok, booking: { id, … } }` (only the id is read here).
struct ProBookingCreateResponse: Decodable {
    let booking: CreatedBooking
    struct CreatedBooking: Decodable { let id: String }
}

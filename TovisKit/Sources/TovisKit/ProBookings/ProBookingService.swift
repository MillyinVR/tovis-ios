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

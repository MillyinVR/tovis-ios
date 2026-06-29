import Foundation

/// PRO workspace — reads one booking's detail and runs the management actions the
/// web `/pro/bookings/[id]` page offers: **accept** a pending request, **cancel**,
/// and **rebook** (propose the client's next appointment). The bookings *list*
/// lives on the calendar (`GET /pro/calendar`); there is no `GET /pro/bookings`.
/// Authenticated; PRO-only (CLIENT tokens 403). See docs/PRO-BACKEND-CONTRACTS.md.
public final class ProBookingService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
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

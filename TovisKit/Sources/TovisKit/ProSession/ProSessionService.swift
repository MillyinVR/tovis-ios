import Foundation

/// Drives the PRO footer's live-session center button — the native port of the
/// web `useProSession` hook (`tovis-app/app/_components/ProSessionFooter`).
/// Authenticated; PRO-only (a CLIENT token 403s these).
///
/// The server is the single source of truth for the button's state: `session()`
/// returns the mode + the resolved center action/label/href, and start/finish
/// hand back where to navigate next. We never re-derive that here.
public final class ProSessionService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/session → the footer payload (envelope spread).
    public func session() async throws -> ProSessionPayload {
        try await api.request("/pro/session")
    }

    /// GET /api/v1/pro/bookings/{id}/session/state → the authoritative per-booking
    /// session state (status, step, checkout). Drives the session hub.
    public func state(bookingId: String) async throws -> ProSessionState {
        let response: ProSessionStateResponse = try await api.request(
            "/pro/bookings/\(bookingId)/session/state"
        )
        return response.state
    }

    /// POST /api/v1/pro/bookings/{id}/session/start. Returns the `nextHref` the
    /// footer should navigate to (the session hub for that booking). Idempotent —
    /// a fresh key per attempt, same as the web hook.
    @discardableResult
    public func start(
        bookingId: String,
        idempotencyKey: String = UUID().uuidString
    ) async throws -> String? {
        let response: ProSessionActionResponse = try await api.request(
            "/pro/bookings/\(bookingId)/session/start",
            method: .post,
            headers: idempotencyHeaders(idempotencyKey)
        )
        return response.nextHref
    }

    /// POST /api/v1/pro/bookings/{id}/session/finish. Returns the `nextHref`
    /// (typically the final-review / aftercare step).
    @discardableResult
    public func finish(
        bookingId: String,
        idempotencyKey: String = UUID().uuidString
    ) async throws -> String? {
        let response: ProSessionActionResponse = try await api.request(
            "/pro/bookings/\(bookingId)/session/finish",
            method: .post,
            headers: idempotencyHeaders(idempotencyKey)
        )
        return response.nextHref
    }

    /// POST /api/v1/pro/bookings/{id}/session/step — advance the session step
    /// (e.g. consult → session → aftercare). `step` is the lowercase step key.
    public func advanceStep(
        bookingId: String,
        to step: String,
        idempotencyKey: String = UUID().uuidString
    ) async throws {
        let payload = try JSONEncoder().encode(["step": step])
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)/session/step",
            method: .post,
            body: payload,
            headers: idempotencyHeaders(idempotencyKey)
        )
    }

    // MARK: - Consultation

    /// GET /api/v1/pro/bookings/{id}/consultation-services → the bookable services
    /// + add-ons the consultation form's "Add" picker draws from.
    public func consultationServices(
        bookingId: String
    ) async throws -> ProConsultationServicesResponse {
        try await api.request("/pro/bookings/\(bookingId)/consultation-services")
    }

    /// POST /api/v1/pro/bookings/{id}/consultation-proposal — set the line items +
    /// total and send the secure approval link to the client. Returns whether the
    /// proposal saved but couldn't be delivered (no contact method / send failure),
    /// mirroring the web form's "saved, but we couldn't send the secure link" notice.
    @discardableResult
    public func sendConsultationProposal(
        bookingId: String,
        notes: String?,
        proposedTotal: String,
        items: [ProConsultationProposalItem],
        idempotencyKey: String = UUID().uuidString
    ) async throws -> ProConsultationProposalResult {
        let body = try JSONEncoder().encode(
            ConsultationProposalBody(
                notes: notes,
                proposedTotal: proposedTotal,
                proposedServicesJson: .init(currency: "USD", items: items),
            )
        )

        let response: ConsultationProposalResponse = try await api.request(
            "/pro/bookings/\(bookingId)/consultation-proposal",
            method: .post,
            body: body,
            headers: idempotencyHeaders(idempotencyKey),
        )

        let delivery = response.consultationActionDelivery
        let undeliverable = delivery?.attempted == true && delivery?.queued != true
        return ProConsultationProposalResult(undeliverable: undeliverable)
    }

    /// POST /api/v1/pro/bookings/{id}/consultation/in-person-decision — record the
    /// in-person approval/decline fallback (client present, can't use their link).
    public func recordInPersonDecision(
        bookingId: String,
        approve: Bool,
        idempotencyKey: String = UUID().uuidString
    ) async throws {
        let body = try JSONEncoder().encode(["action": approve ? "APPROVED" : "REJECTED"])
        try await api.requestVoid(
            "/pro/bookings/\(bookingId)/consultation/in-person-decision",
            method: .post,
            body: body,
            headers: idempotencyHeaders(idempotencyKey),
        )
    }

    /// The backend accepts the idempotency key under either header name (see the
    /// web hook). Send both so a single key dedupes the write.
    private func idempotencyHeaders(_ key: String) -> [String: String] {
        ["Idempotency-Key": key, "x-idempotency-key": key]
    }
}

/// Outcome of sending a consultation proposal — the proposal always saves on a
/// 200; `undeliverable` flags that the secure link couldn't be sent.
public struct ProConsultationProposalResult: Sendable {
    public let undeliverable: Bool
}

// Request/response shapes local to the proposal POST.
private struct ConsultationProposalBody: Encodable {
    let notes: String?
    let proposedTotal: String
    let proposedServicesJson: ProposedServices

    struct ProposedServices: Encodable {
        let currency: String
        let items: [ProConsultationProposalItem]
    }
}

private struct ConsultationProposalResponse: Decodable {
    let consultationActionDelivery: ConsultationActionDelivery?

    struct ConsultationActionDelivery: Decodable {
        let attempted: Bool?
        let queued: Bool?
    }
}

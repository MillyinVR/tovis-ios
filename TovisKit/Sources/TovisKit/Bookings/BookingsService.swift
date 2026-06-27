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
}

import Foundation

/// Support-ticket filing — the native counterpart of the web `/support` form
/// (app/support/supportForm.tsx), backed by `POST /api/v1/support/tickets`.
/// Authenticated (bearer token); any signed-in role may file.
///
/// Both sides share one server-side writer, so a native ticket is attributed and
/// alerts admins exactly like a web one. That attribution is the point: the
/// ticket has no contact column, so the signed-in user IS how the admin queue
/// replies — which a cookieless in-app browser could never supply.
///
/// Create-only; there is no client-facing ticket read/list surface.
public final class SupportService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// POST /api/v1/support/tickets → the filed ticket (unwrapped).
    ///
    /// The backend caps subject/message length and rejects blanks; the form
    /// clamps to the same limits, so those 400s are backstops, not flows.
    public func createTicket(subject: String, message: String) async throws -> SupportTicket {
        let payload = try JSONEncoder.canonical.encode(SupportTicketCreateRequest(
            subject: subject,
            message: message
        ))
        let response: SupportTicketResponse = try await api.request(
            "/support/tickets",
            method: .post,
            body: payload
        )
        return response.ticket
    }
}

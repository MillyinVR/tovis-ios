import Foundation

// Wire models for native support-ticket filing — POST /api/v1/support/tickets.
// Mirrors SupportTicketDTO (tovis-app lib/dto/supportTicket.ts), the create
// response for the route that backs the web `/support` form (app/support).
//
// The route exists because native auth is bearer-token and cookieless by design:
// a SafariView pointed at `/support` submits anonymously, and a ticket with no
// user attached is one the admin queue cannot reply to. Filing through the API
// is what carries the real user onto the ticket.

/// Envelope for `POST /api/v1/support/tickets` → `{ ok, ticket }`.
struct SupportTicketResponse: Decodable, Sendable {
    let ticket: SupportTicket
}

/// A filed support ticket. Create-only: the backend exposes no client-facing
/// read surface, so this is what a submission returns and nothing more. The
/// message is deliberately not echoed back — the caller just typed it.
public struct SupportTicket: Decodable, Sendable, Equatable {
    public let id: String
    public let subject: String
    /// `OPEN` | `IN_PROGRESS` | `CLOSED` — always `OPEN` on create.
    public let status: String
    /// ISO-8601.
    public let createdAt: String
}

/// POST body for filing a ticket. The web form collects exactly these two
/// fields, so the native form does too.
struct SupportTicketCreateRequest: Encodable, Sendable {
    let subject: String
    let message: String
}

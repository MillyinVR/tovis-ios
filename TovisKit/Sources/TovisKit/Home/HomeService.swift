import Foundation

/// Reads the client home screen — the single backend source the web home page
/// also uses (`GET /api/v1/client/home`). Authenticated (bearer token); the
/// caller must be signed in as a CLIENT or the backend returns 403.
public final class HomeService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/client/home → the home payload (unwrapped from the envelope).
    public func fetch() async throws -> ClientHome {
        let response: ClientHomeResponse = try await api.request("/client/home")
        return response.home
    }

    /// GET /api/v1/client/priority-offer → the client's active priority offers:
    /// last-minute openings they're first in line for, each with a countdown
    /// window. The standalone offers screen renders these with Claim/Pass; the
    /// claim/pass writes reuse `acceptInvite`/`declineInvite` below (same
    /// `/client/priority-offer/{id}` routes). Envelope unwrapped. CLIENT-only.
    public func priorityOffers() async throws -> [ClientPriorityOffer] {
        let response: ClientPriorityOfferResponse = try await api.request("/client/priority-offer")
        return response.offers
    }

    /// Accept a last-minute (priority) offer. `recipientId` is `HomeInvite.id` or
    /// `ClientPriorityOffer.recipientId`. A 410 (expired / opening inactive) or 409
    /// (no longer priority) surfaces as `APIError.server`.
    public func acceptInvite(recipientId: String) async throws {
        try await api.requestVoid(
            "/client/priority-offer/\(recipientId)/accept",
            method: .post
        )
    }

    /// Decline a last-minute (priority) offer. `recipientId` is `HomeInvite.id`.
    public func declineInvite(recipientId: String) async throws {
        try await api.requestVoid(
            "/client/priority-offer/\(recipientId)/decline",
            method: .post
        )
    }

    /// GET /api/v1/client/openings → the client's active last-minute openings feed
    /// (the "see all" of the home invites). Optional filters mirror the web feed
    /// (`serviceId` / `professionalId` / `locationType`). Returns the rows verbatim;
    /// the caller drops non-bookable ones (see `ClientOpening.isBookable`), matching
    /// the web `parseCard` filter.
    public func openings(
        serviceId: String? = nil,
        professionalId: String? = nil,
        locationType: String? = nil
    ) async throws -> [ClientOpening] {
        var query: [URLQueryItem] = []
        if let serviceId { query.append(URLQueryItem(name: "serviceId", value: serviceId)) }
        if let professionalId { query.append(URLQueryItem(name: "professionalId", value: professionalId)) }
        if let locationType { query.append(URLQueryItem(name: "locationType", value: locationType)) }
        let response: ClientOpeningFeedResponse = try await api.request(
            "/client/openings",
            query: query.isEmpty ? nil : query
        )
        return response.notifications
    }
}

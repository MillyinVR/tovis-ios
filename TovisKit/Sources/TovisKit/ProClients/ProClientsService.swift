import Foundation

/// PRO workspace — the clients directory (web `/pro/clients`). Search the pro's
/// clients, read a client's service addresses, and append a chart note. The full
/// chart HISTORY (existing notes/allergies/formula) is server-rendered with no
/// read API — porting it needs a backend aggregate GET first. Authenticated;
/// PRO-only + per-client visibility. See docs/PRO-BACKEND-CONTRACTS.md.
public final class ProClientsService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/clients/search?q= → recent + other matches.
    public func search(query: String = "") async throws -> ProClientSearchResponse {
        let q = query.trimmingCharacters(in: .whitespaces)
        let items = q.isEmpty ? nil : [URLQueryItem(name: "q", value: q)]
        return try await api.request("/pro/clients/search", query: items)
    }

    /// GET /api/v1/pro/clients/{id}/service-addresses.
    public func serviceAddresses(clientId: String) async throws -> [ProClientAddress] {
        let response: ProClientAddressesResponse =
            try await api.request("/pro/clients/\(clientId)/service-addresses")
        return response.addresses
    }

    /// POST /api/v1/pro/clients/{id}/notes — append a chart note. `kind` is
    /// "GENERAL" | "CONSULTATION" | "COMMUNICATION_STYLE".
    public func addNote(
        clientId: String,
        body: String,
        title: String? = nil,
        kind: String = "GENERAL"
    ) async throws {
        let payload = try JSONEncoder().encode(
            ProClientNoteRequest(title: title, body: body, kind: kind)
        )
        try await api.requestVoid(
            "/pro/clients/\(clientId)/notes", method: .post, body: payload
        )
    }
}

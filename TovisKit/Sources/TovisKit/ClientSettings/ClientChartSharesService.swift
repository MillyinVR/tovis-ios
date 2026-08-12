import Foundation

/// The client's own side of chart consent — `GET/PATCH /api/v1/client/chart-shares`.
///
/// The native counterpart of the web settings card
/// (app/client/(gated)/settings/chart-sharing). Until this existed, an iOS
/// client could be ASKED for chart access — the request ships as a push — and
/// had nowhere in the app to answer it, see who already held access, or take it
/// back. The capability existed on the server and could not be reached from the
/// phone.
public final class ClientChartSharesService: Sendable {
    /// What a client can do to a share. Mirrors the route's `ACTIONS`.
    public enum Action: String, Sendable {
        case grant = "GRANT"
        case decline = "DECLINE"
        case revoke = "REVOKE"
    }

    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// Every professional with a share row, newest change first (the server
    /// orders by `updatedAt desc`).
    public func list() async throws -> [ClientChartShare] {
        let response: ClientChartSharesResponse =
            try await api.request("/client/chart-shares")
        return response.shares
    }

    /// Answer an ask, or take access back.
    ///
    /// 🔴 `.revoke` is never refused by the server — it is accepted even for a
    /// pair with no row, because the client asked for "this pro cannot see my
    /// chart" and that is the end state either way. So nothing here should gate
    /// it: gate the grant, never the undo.
    @discardableResult
    public func update(
        professionalId: String,
        action: Action
    ) async throws -> ClientChartShareUpdate {
        let payload = try JSONEncoder.canonical.encode(
            ChartShareUpdateRequest(professionalId: professionalId, action: action.rawValue)
        )
        let response: ClientChartShareUpdateResponse = try await api.request(
            "/client/chart-shares",
            method: .patch,
            body: payload
        )
        return response.chartShare
    }
}

private struct ChartShareUpdateRequest: Encodable {
    let professionalId: String
    let action: String
}

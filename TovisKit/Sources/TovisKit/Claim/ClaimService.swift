import Foundation

/// The public client-claim surface, addressed by a claim **token** — the native
/// counterpart of the web `/claim/[token]` page (which is RSC-only). Sibling of
/// `PublicBoardService` (both are token/handle-addressed public reads).
///
/// - `claimContext(token:)` → GET /api/v1/public/claim/{token}. Public read (no
///   auth). Answers **404** when the token doesn't resolve / is malformed — all
///   indistinguishable by design — so this surfaces every 404 as `nil` (a plain
///   "link not found" empty state, not an error). Any other non-2xx throws.
///
/// After reading the context, the claim screen routes into client signup with
/// `intent = "CLAIM_INVITE"` + the same `token`, which the backend adopts.
public final class ClaimService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// Loads a claim link's booking context by token. Returns `nil` when the
    /// token doesn't resolve (route 404).
    public func claimContext(token: String) async throws -> ClaimContextResponse? {
        do {
            return try await api.request(
                "/public/claim/\(token)",
                authenticated: false
            )
        } catch let error as APIError {
            if case let .server(status, _, _) = error, status == 404 {
                return nil
            }
            throw error
        }
    }
}

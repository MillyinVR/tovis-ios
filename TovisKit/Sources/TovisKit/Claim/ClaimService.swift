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
/// - `acceptClaim(token:)` → POST /api/v1/pro/invites/{token}/accept. **Authenticated**
///   (client bearer). Despite living under a `/pro/` path — it accepts a *pro-created*
///   invite — this is the client-side accept: it is gated by `requireClient()` and
///   wraps the same `acceptClientClaimFromLink` writer the web page's server action
///   calls. That path name is why it reads as unrelated; it is the counterpart.
///
/// A signed-out viewer instead routes into client signup with
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

    /// Accepts the claim as the signed-in client, attaching the pro-created
    /// history to their identity.
    ///
    /// Every documented failure is returned as a `ClaimAcceptOutcome` rather than
    /// thrown — each one is a real state the screen renders, not an error. Only
    /// the genuinely exceptional stays thrown: a 401 (`.unauthorized`), a
    /// transport failure, or an unrecognized `code` (which must surface the
    /// server's own message rather than be silently mapped to something wrong).
    ///
    /// ⚠️ Keyed on the body's top-level `code`, NOT the status — the statuses are
    /// ambiguous (404 = NOT_FOUND | CLIENT_NOT_FOUND; 409 = ALREADY_CLAIMED |
    /// CLIENT_MISMATCH | MERGE_REFUSED | CONFLICT). Pinned by `ClaimServiceTests`
    /// against bodies captured verbatim from the live route.
    public func acceptClaim(token: String) async throws -> ClaimAcceptOutcome {
        do {
            let response: ClaimAcceptResponse = try await api.request(
                "/pro/invites/\(token)/accept",
                method: .post
            )
            return .claimed(bookingId: response.bookingId)
        } catch let error as APIError {
            guard case let .server(_, _, code) = error, let code else { throw error }

            switch code {
            case "NOT_FOUND": return .notFound
            case "REVOKED": return .revoked
            case "ALREADY_CLAIMED": return .alreadyClaimed
            case "CLIENT_NOT_FOUND": return .clientNotFound
            case "CLIENT_MISMATCH": return .clientMismatch
            case "MERGE_REFUSED": return .mergeRefused
            case "CONFLICT": return .conflict
            case "WORKSPACE_MISMATCH": return .notAClient
            default: throw error
            }
        }
    }
}

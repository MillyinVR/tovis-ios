import Foundation

/// The public board surface, addressed by a client's public **handle** + board
/// **slug** — the native counterpart of the web `/u/[handle]/boards/[slug]` page.
/// Sibling of `PublicClientService` (both are handle-addressed public reads).
///
/// - `board(handle:slug:)` → GET /api/v1/u/{handle}/boards/{slug}. The route is
///   public-read (a signed-in CLIENT additionally gets viewer.isOwn /
///   followingOwner; guests/pros view as guests). It answers **404** when the
///   handle/slug doesn't resolve, the board isn't SHARED, or an admin has hidden
///   it — all indistinguishable by design, so this surfaces every 404 as `nil` (a
///   plain "not found" empty state, not an error). Any other non-2xx throws.
public final class PublicBoardService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// Loads a client's shared board by handle + slug. Returns `nil` when the
    /// board doesn't resolve / isn't shared / is hidden (route 404).
    public func board(handle: String, slug: String) async throws -> PublicBoard? {
        do {
            let response: PublicBoardResponse =
                try await api.request("/u/\(handle)/boards/\(slug)")
            return response.board
        } catch let error as APIError {
            if case let .server(status, _, _) = error, status == 404 {
                return nil
            }
            throw error
        }
    }
}

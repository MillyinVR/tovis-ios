import Foundation

/// The Looks feed — the client's social home base (center tab). Same endpoints
/// the web `LooksFeed` uses: a cursor-paginated feed, like/unlike, and the
/// TikTok/IG-style comments (top-level + 1-level replies, like + delete-own).
/// Feed + comment reads work signed-out; writes (like/comment) require auth.
public final class LooksService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// A page of the feed plus the opaque cursor for the next page (nil = end).
    public struct FeedPage: Sendable {
        public let items: [LooksFeedItem]
        public let nextCursor: String?
    }

    /// GET /api/v1/looks. Mirrors the web tabs: the default "Looks" feed (no
    /// args), Following (`following`), Spotlight (`filter: "spotlight"`), or a
    /// service category (`category` slug). `cursor` is the prior page's
    /// `nextCursor`.
    public func feed(
        filter: String? = nil,
        category: String? = nil,
        following: Bool = false,
        cursor: String? = nil,
        limit: Int = 12
    ) async throws -> FeedPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if following { query.append(URLQueryItem(name: "following", value: "true")) }
        if let filter { query.append(URLQueryItem(name: "filter", value: filter)) }
        if let category { query.append(URLQueryItem(name: "category", value: category)) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }

        let response: LooksFeedResponse = try await api.request("/looks", query: query)
        return FeedPage(items: response.items, nextCursor: response.nextCursor)
    }

    /// GET /api/v1/looks/categories — the dynamic service-category tabs.
    public func categories() async throws -> [LooksCategory] {
        let response: LooksCategoriesResponse = try await api.request("/looks/categories")
        return response.categories
    }

    // MARK: - Follow a pro (from the overlay)

    /// POST/DELETE /api/v1/pros/{id}/follow.
    public func setFollow(professionalId: String, following: Bool) async throws -> FollowState {
        try await api.request(
            "/pros/\(professionalId)/follow",
            method: following ? .post : .delete,
            body: Data("{}".utf8)
        )
    }

    // MARK: - Save to board

    /// GET /api/v1/looks/{id}/save — current save state + the viewer's boards.
    public func saveState(lookId: String) async throws -> LooksSaveState {
        try await api.request("/looks/\(lookId)/save")
    }

    /// POST/DELETE /api/v1/looks/{id}/save — add/remove from a board.
    public func setSaved(lookId: String, boardId: String, saved: Bool) async throws -> LooksSaveState {
        let payload = try JSONEncoder().encode(LooksSaveMutationRequest(boardId: boardId))
        return try await api.request(
            "/looks/\(lookId)/save",
            method: saved ? .post : .delete,
            body: payload
        )
    }

    // MARK: - Like a look

    /// POST/DELETE /api/v1/looks/{id}/like.
    public func setLiked(lookId: String, liked: Bool) async throws -> LooksLikeResponse {
        try await api.request(
            "/looks/\(lookId)/like",
            method: liked ? .post : .delete,
            body: Data("{}".utf8)
        )
    }

    // MARK: - Comments

    /// GET /api/v1/looks/{id}/comments — top-level comments (newest first).
    public func comments(lookId: String, limit: Int = 30) async throws -> [LooksComment] {
        let response: LooksCommentsListResponse = try await api.request(
            "/looks/\(lookId)/comments",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
        return response.comments
    }

    /// GET /api/v1/looks/{id}/comments/{commentId}/replies — replies (oldest first).
    public func replies(lookId: String, commentId: String, limit: Int = 50) async throws -> [LooksComment] {
        let response: LooksCommentRepliesListResponse = try await api.request(
            "/looks/\(lookId)/comments/\(commentId)/replies",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
        return response.replies
    }

    /// POST /api/v1/looks/{id}/comments — create a top-level comment or a reply
    /// (`parentCommentId` set). Returns the new comment.
    public func addComment(
        lookId: String,
        body: String,
        parentCommentId: String? = nil
    ) async throws -> LooksComment {
        let payload = try JSONEncoder().encode(
            LooksCommentCreateRequest(body: body, parentCommentId: parentCommentId)
        )
        let response: LooksCommentCreateResponse = try await api.request(
            "/looks/\(lookId)/comments",
            method: .post,
            body: payload
        )
        return response.comment
    }

    /// POST/DELETE /api/v1/looks/{id}/comments/{commentId}/like.
    public func setCommentLiked(
        lookId: String,
        commentId: String,
        liked: Bool
    ) async throws -> LooksCommentLikeResponse {
        try await api.request(
            "/looks/\(lookId)/comments/\(commentId)/like",
            method: liked ? .post : .delete,
            body: Data("{}".utf8)
        )
    }

    /// DELETE /api/v1/looks/{id}/comments/{commentId} — author or admin only.
    public func deleteComment(lookId: String, commentId: String) async throws {
        try await api.requestVoid(
            "/looks/\(lookId)/comments/\(commentId)",
            method: .delete,
            body: Data("{}".utf8)
        )
    }
}

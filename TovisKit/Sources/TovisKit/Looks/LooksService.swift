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

    /// GET /api/v1/looks — `following: true` scopes to pros you follow. `cursor`
    /// is the opaque `nextCursor` from the previous page.
    public func feed(
        following: Bool = false,
        cursor: String? = nil,
        limit: Int = 12
    ) async throws -> FeedPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if following { query.append(URLQueryItem(name: "following", value: "true")) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }

        let response: LooksFeedResponse = try await api.request("/looks", query: query)
        return FeedPage(items: response.items, nextCursor: response.nextCursor)
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

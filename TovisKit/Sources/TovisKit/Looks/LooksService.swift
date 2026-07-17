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
    /// service category (`category` slug). `sort` selects the ordering
    /// (`"ranked"` for the Discover bookable grid, default recency). `cursor` is
    /// the prior page's `nextCursor`.
    ///
    /// `query` is the feed search (web's `LooksTopBar` field): the server matches
    /// it against the look's caption, the pro's business name/handle, and the
    /// service + category names — so results are always looks, never pros. A
    /// blank/whitespace query omits `q` entirely (web parity: `if (query.trim())`),
    /// which matters because a present `q` routes the server off the personalized
    /// feed onto the chronological search path.
    public func feed(
        filter: String? = nil,
        category: String? = nil,
        following: Bool = false,
        sort: String? = nil,
        query: String? = nil,
        cursor: String? = nil,
        limit: Int = 12
    ) async throws -> FeedPage {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if following { items.append(URLQueryItem(name: "following", value: "true")) }
        if let filter { items.append(URLQueryItem(name: "filter", value: filter)) }
        if let category { items.append(URLQueryItem(name: "category", value: category)) }
        if let sort { items.append(URLQueryItem(name: "sort", value: sort)) }
        if let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            items.append(URLQueryItem(name: "q", value: trimmed))
        }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }

        let response: LooksFeedResponse = try await api.request("/looks", query: items)
        return FeedPage(items: response.items, nextCursor: response.nextCursor)
    }

    /// GET /api/v1/looks/{id} — the single-look detail (before/after pair, the
    /// full 5-counter stats, the linked review, tags and the post's other
    /// assets). Guest-readable, like the feed: the same route backs web's
    /// `/looks/[id]` page, which fetches it server-side rather than querying
    /// Prisma — so this is the same contract web renders, not a native twin.
    ///
    /// A look the viewer may not see 404s (`LOOK_NOT_FOUND`) rather than 403ing,
    /// deliberately — the backend does not enumerate hidden looks.
    public func detail(id: String) async throws -> LookDetail {
        let response: LookDetailResponse = try await api.request("/looks/\(id)")
        return response.item
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

    /// GET /api/v1/pros/{id}/follow — hydrate the viewer's follow state.
    public func followState(professionalId: String) async throws -> FollowState {
        try await api.request("/pros/\(professionalId)/follow")
    }

    // MARK: - Save to board

    /// GET /api/v1/looks/{id}/save — current save state + the viewer's boards.
    public func saveState(lookId: String) async throws -> LooksSaveState {
        try await api.request("/looks/\(lookId)/save")
    }

    /// POST/DELETE /api/v1/looks/{id}/save — add/remove from a board.
    public func setSaved(lookId: String, boardId: String, saved: Bool) async throws -> LooksSaveState {
        let payload = try JSONEncoder.canonical.encode(LooksSaveMutationRequest(boardId: boardId))
        return try await api.request(
            "/looks/\(lookId)/save",
            method: saved ? .post : .delete,
            body: payload
        )
    }

    // MARK: - Share ping

    /// POST /api/v1/looks/{id}/share — fire-and-forget share counter (the share
    /// sheet itself is native; this just records that it happened).
    @discardableResult
    public func recordShare(lookId: String) async throws -> LooksShareResponse {
        try await api.request(
            "/looks/\(lookId)/share",
            method: .post,
            body: Data("{}".utf8)
        )
    }

    // MARK: - "Not for me"

    /// POST /api/v1/looks/{id}/hide — the feed's only negative signal.
    ///
    /// Private to the viewer (no counter, no author notification). The server
    /// writes a `LookHide` keyed by USER id and then does two distinct things:
    /// hard-excludes the look from every feed forever, and adds a *decaying*
    /// suppression weight onto its service category (30-day half-life — faster
    /// than the positive-affinity one, so a mis-tap fades sooner). Only the
    /// exclusion is permanent.
    ///
    /// Idempotent: a duplicate hide swallows the unique violation server-side and
    /// still reports `hidden: true`. The route reads no body — `{}` matches the
    /// sibling toggles. There is a DELETE (un-hide), but no client calls it and
    /// neither platform has an un-hide affordance, so it is deliberately unwrapped.
    @discardableResult
    public func hide(lookId: String) async throws -> LooksHideResponse {
        try await api.request(
            "/looks/\(lookId)/hide",
            method: .post,
            body: Data("{}".utf8)
        )
    }

    // MARK: - View tracking

    /// POST /api/v1/looks/views — sampled view impressions (B2). Guest-allowed
    /// and fire-and-forget: the server dedupes/caps the ids and enqueues a job
    /// that denormalizes viewCount. No auth needed (impressions count for
    /// signed-out viewers too).
    ///
    /// `source` tags where the look was surfaced, feeding the §5.6 per-source,
    /// per-day aggregate. It is NOT cosmetic: native previously sent the legacy
    /// untagged body, which the job reads as FEED — so a detail open would have
    /// been counted as a feed impression.
    public func recordViews(lookIds: [String], source: LookViewSource = .feed) async throws {
        let ids = lookIds.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }

        let payload = try JSONEncoder.canonical.encode(
            LooksViewsRequest(
                impressions: ids.map {
                    LooksViewImpression(lookPostId: $0, source: source.rawValue)
                }
            )
        )
        try await api.requestVoid(
            "/looks/views",
            method: .post,
            body: payload,
            authenticated: false,
            retryOn401: false
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
        let payload = try JSONEncoder.canonical.encode(
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

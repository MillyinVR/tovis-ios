import Foundation

// Wire models for the Looks feed — the client's social "home base" (center tab).
// Mirrors lib/looks/types.ts (LooksFeedResponseDto, LooksCommentDto, …) and the
// generated schema/api/tovis-api.schema.json. Only the rendered subset is
// modeled; unknown keys (serviceIds, review*, uploadedByRole, …) are ignored.

// MARK: - Feed (GET /api/v1/looks)

struct LooksFeedResponse: Decodable, Sendable {
    let items: [LooksFeedItem]
    let nextCursor: String?
}

public struct LooksFeedItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let url: String
    public let thumbUrl: String?
    public let mediaType: String        // "IMAGE" | "VIDEO"
    public let caption: String?
    public let createdAt: String

    public let professional: LooksProfessional?
    public let clientAuthor: LooksClientAuthor?

    public let count: LooksCounts
    public let viewerLiked: Bool
    public let viewerSaved: Bool
    public let viewerFollows: Bool

    public let serviceId: String?
    public let serviceName: String?
    public let category: String?
    public let priceStartingAt: Double?

    /// Opt-in before/after pairing on the primary image → the reveal slider.
    public let before: LooksPairedBefore?

    /// Non-banned hashtag / style tags (social-first D1). Decoded optionally so an
    /// older cached payload without the key still decodes; read `tags` to render.
    private let tagsRaw: [LooksTag]?

    /// Tappable hashtag/style tags for this look (never nil for the caller).
    public var tags: [LooksTag] { tagsRaw ?? [] }

    private enum CodingKeys: String, CodingKey {
        case id, url, thumbUrl, mediaType, caption, createdAt
        case professional, clientAuthor
        case count = "_count"
        case viewerLiked, viewerSaved, viewerFollows
        case serviceId, serviceName, category, priceStartingAt
        case before
        case tagsRaw = "tags"
    }

    public var isVideo: Bool { mediaType.uppercased() == "VIDEO" }

    /// The before/after pair to render, when the primary is a paired image.
    /// Nil for videos or unpaired looks (fall back to the single-image slide).
    public var beforeAfterPair: (before: URL, after: URL)? {
        guard !isVideo,
              let before = before?.bestURL,
              let after = URL(string: url) else { return nil }
        return (before, after)
    }

    /// "$120" etc. — the "from" price for booking this look's service.
    public var priceLabel: String? {
        guard let p = priceStartingAt else { return nil }
        return p.truncatingRemainder(dividingBy: 1) == 0
            ? "$\(Int(p))" : String(format: "$%.2f", p)
    }
}

/// The pro credited on a look. Mirrors `LooksProfessionalDto`; carries the
/// name-display toggle so it resolves the same public name the web does
/// (port of `pickProfessionalPublicDisplayName`).
public struct LooksProfessional: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let businessName: String?
    public let firstName: String?
    public let lastName: String?
    public let handle: String?
    public let nameDisplay: ProNameDisplay?
    public let professionType: String?
    public let avatarUrl: String?
    public let location: String?
    public let followerCount: Int

    public var displayName: String {
        let business = Self.trimmed(businessName)
        let real = [Self.trimmed(firstName), Self.trimmed(lastName)]
            .compactMap { $0 }.joined(separator: " ")
        let realName = real.isEmpty ? nil : real
        let handleLabel = Self.trimmed(handle).map { "@\($0)" }

        switch nameDisplay {
        case .realName: return realName ?? business ?? handleLabel ?? Self.fallback
        case .handle: return handleLabel ?? business ?? realName ?? Self.fallback
        case .businessName, .unknown, .none: return business ?? realName ?? Self.fallback
        }
    }

    public var handleLabel: String? { Self.trimmed(handle).map { "@\($0)" } }

    private static let fallback = "A pro"
    private static func trimmed(_ value: String?) -> String? {
        let t = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }
}

/// A client who published a look (PII-safe: handle + avatar only).
public struct LooksClientAuthor: Decodable, Sendable {
    public let handle: String
    public let avatarUrl: String?
    public let profileHref: String?

    public var handleLabel: String { "@\(handle)" }
}

public struct LooksCounts: Decodable, Sendable {
    public let likes: Int
    public let comments: Int
}

/// The chosen "before" of an opt-in before/after pair on the primary (image)
/// asset. Present → render the reveal slider; absent → a single image. Mirrors
/// `PairedBeforeDto` (id + thumb/full URLs). The tile's own `url` is the "after".
public struct LooksPairedBefore: Decodable, Sendable {
    public let id: String
    public let thumbUrl: String?
    public let fullUrl: String?

    /// Full-res when available, else the thumb — the "before" layer of the wipe.
    public var bestURL: URL? {
        let raw = fullUrl ?? thumbUrl
        return raw.flatMap(URL.init(string:))
    }
}

/// A user-facing hashtag / style tag on a look (social-first D1). `slug` is the
/// URL key for the web tag page (/looks/tags/{slug}); `display` is the label.
/// Mirrors `LooksTagDto`.
public struct LooksTag: Decodable, Sendable, Identifiable, Hashable {
    public let slug: String
    public let display: String
    public var id: String { slug }
}

// MARK: - Categories (GET /api/v1/looks/categories)

public struct LooksCategory: Decodable, Sendable, Identifiable, Hashable {
    public let name: String
    public let slug: String
    public var id: String { slug }
}

struct LooksCategoriesResponse: Decodable, Sendable {
    let categories: [LooksCategory]
}

// MARK: - Follow (POST/DELETE /api/v1/pros/{id}/follow)

public struct FollowState: Decodable, Sendable {
    public let following: Bool
    public let followerCount: Int
}

// MARK: - Save to board (GET/POST/DELETE /api/v1/looks/{id}/save)

public struct LooksBoard: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let visibility: String
}

/// The look's save state. Both the GET state and the POST/DELETE mutation
/// responses carry this shape (extra mutation-only keys are ignored).
public struct LooksSaveState: Decodable, Sendable {
    public let isSaved: Bool
    public let saveCount: Int
    public let boardIds: [String]
    public let boards: [LooksBoard]
}

struct LooksSaveMutationRequest: Encodable, Sendable {
    let boardId: String
}

// MARK: - View tracking (POST /api/v1/looks/views)

/// Batched, sampled view impressions (social-first plan B2). The server dedupes
/// + caps, then enqueues a job that increments each look's viewCount.
struct LooksViewsRequest: Encodable, Sendable {
    let lookPostIds: [String]
}

// MARK: - Like (POST/DELETE /api/v1/looks/{id}/like)

public struct LooksLikeResponse: Decodable, Sendable {
    public let lookPostId: String
    public let liked: Bool
    public let likeCount: Int
}

// MARK: - Share ping (POST /api/v1/looks/{id}/share)

public struct LooksShareResponse: Decodable, Sendable {
    public let lookPostId: String
    public let shareCount: Int
}

// MARK: - Comments (GET/POST /api/v1/looks/{id}/comments)

struct LooksCommentsListResponse: Decodable, Sendable {
    let lookPostId: String
    let comments: [LooksComment]
    let commentsCount: Int
}

struct LooksCommentCreateResponse: Decodable, Sendable {
    let comment: LooksComment
    let commentsCount: Int
}

struct LooksCommentRepliesListResponse: Decodable, Sendable {
    let parentCommentId: String
    let replies: [LooksComment]
    let replyCount: Int
}

public struct LooksCommentLikeResponse: Decodable, Sendable {
    public let commentId: String
    public let liked: Bool
    public let likeCount: Int
}

public struct LooksComment: Decodable, Sendable, Identifiable {
    public let id: String
    public let body: String
    public let createdAt: String
    public let user: LooksCommentUser
    public let parentCommentId: String?
    public let likeCount: Int
    public let replyCount: Int
    public let viewerLiked: Bool
    public let viewerCanDelete: Bool

    public var isReply: Bool { parentCommentId != nil }
}

public struct LooksCommentUser: Decodable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let avatarUrl: String?
    public let profileHref: String?
    /// The commenter authored the look this comment sits on ("Creator" badge).
    /// Optional so older API responses still decode.
    public let isLookAuthor: Bool?
    /// The commenter is a professional on the platform ("Pro" badge).
    public let isPro: Bool?

    /// Badge label for the comment row, if any (Creator wins over Pro).
    public var badgeLabel: String? {
        if isLookAuthor == true { return "Creator" }
        if isPro == true { return "Pro" }
        return nil
    }
}

// MARK: - Request bodies

struct LooksCommentCreateRequest: Encodable, Sendable {
    let body: String
    let parentCommentId: String?
}

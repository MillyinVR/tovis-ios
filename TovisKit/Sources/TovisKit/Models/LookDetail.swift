import Foundation

// Wire models for the single-look detail (GET /api/v1/looks/{id}).
//
// Mirrors `LooksDetailResponseDto` / `LooksDetailItemDto` (tovis-app
// lib/looks/types.ts) and the generated schema/api/tovis-api.schema.json.
// Pinned by Fixtures/lookDetail.json — a VERBATIM capture of the live route.
//
// This is a DIFFERENT payload from the feed, not a superset:
//   • the pro is `LooksProProfilePreviewDto` (verificationStatus + isPremium,
//     and NO followerCount) — the feed's is `LooksProfessionalDto`;
//   • `service` is an object, where the feed flattens it to serviceId/
//     serviceName/category;
//   • `primaryMedia.review` is an object, where the feed flattens it to
//     review*/reviewId fields;
//   • `_count` carries saves/shares/views, which the feed's likes+comments
//     `_count` does not;
//   • `priceStartingAt` is selected by the backend but NEVER mapped onto this
//     DTO, so the detail has no price — matching web, whose detail page renders
//     no price either. Do not "fix" that here; it would be a web change.
// Only the rendered subset is modeled; unknown keys (admin, …) are ignored.

struct LookDetailResponse: Decodable, Sendable {
    let item: LookDetail
}

public struct LookDetail: Decodable, Sendable, Identifiable {
    public let id: String
    public let caption: String?
    public let status: String
    public let visibility: String
    public let moderationStatus: String
    public let publishedAt: String?
    public let createdAt: String
    public let updatedAt: String

    /// Required + non-null on this DTO (unlike the feed's, which nulls for a
    /// client-authored look): `LookPost.professionalId` is a NOT NULL column, so
    /// a detail row always credits a pro even when a client authored the post.
    public let professional: LookDetailProfessional
    public let clientAuthor: LooksClientAuthor?
    public let service: LookDetailService?
    public let primaryMedia: LookDetailMedia
    /// Opt-in before/after pairing on the primary image → the reveal slider.
    public let before: LooksPairedBefore?

    private let tagsRaw: [LooksTag]?
    public let assets: [LookDetailAsset]
    public let count: LookDetailCounts
    public let viewerContext: LookDetailViewerContext

    /// Tappable hashtag/style tags (never nil for the caller).
    public var tags: [LooksTag] { tagsRaw ?? [] }

    private enum CodingKeys: String, CodingKey {
        case id, caption, status, visibility, moderationStatus
        case publishedAt, createdAt, updatedAt
        case professional, clientAuthor, service, primaryMedia, before
        case tagsRaw = "tags"
        case assets
        case count = "_count"
        case viewerContext
    }

    public var isVideo: Bool { primaryMedia.isVideo }

    /// The validated focal point of the primary asset, or nil (center).
    public var focalPoint: MediaFocalPoint? { primaryMedia.focalPoint }

    /// The review attached to the primary asset, when the look came out of a
    /// reviewed booking. Web reads the same path (`primaryMedia.review`).
    public var review: LookDetailReview? { primaryMedia.review }

    /// The before/after pair to reveal, when the primary is a paired image.
    /// Nil for videos or unpaired looks (fall back to the single image).
    ///
    /// Mirrors `LooksFeedItem.beforeAfterPair` — same rule, and it reuses the
    /// same `bestURL` (full-res preferred). Web's detail page happens to prefer
    /// the *thumb* here; native keeps the full-res the feed's reveal already
    /// uses, since the native reveal is full-bleed and a thumb visibly softens.
    public var beforeAfterPair: (before: URL, after: URL)? {
        guard !isVideo,
              let before = before?.bestURL,
              let after = URL(string: primaryMedia.url) else { return nil }
        return (before, after)
    }

    /// The post's other assets — web's "More from this post" grid. Filtered by
    /// media id, exactly as web does, so the primary never repeats in the grid.
    public var secondaryAssets: [LookDetailAsset] {
        assets.filter { $0.media.id != primaryMedia.id }
    }
}

/// The pro credited on a look detail (`LooksProProfilePreviewDto`).
///
/// Distinct from the feed's `LooksProfessional` because the wire genuinely
/// differs: this DTO carries no `followerCount` (the detail screen hydrates the
/// live count + follow state from `GET /pros/{id}/follow`, exactly as web's
/// `useProFollow` hook does). The display-name rule is shared, not copied —
/// see `ProPublicNameSource`.
public struct LookDetailProfessional: Decodable, Sendable, Identifiable, Hashable, ProPublicNameSource {
    public let id: String
    public let businessName: String?
    public let firstName: String?
    public let lastName: String?
    public let handle: String?
    public let nameDisplay: ProNameDisplay?
    public let professionType: String?
    public let avatarUrl: String?
    public let location: String?

    /// "A pro" when starved — same copy as the feed's `LooksProfessional`,
    /// because it's the same context: a look's author is a stranger.
    public var displayName: String { publicDisplayName(fallback: "A pro") }
}

/// The service a look is credited to (`LooksDetailServiceDto`).
public struct LookDetailService: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let category: LooksCategory?
}

/// A media asset on a look detail (`LooksDetailMediaDto`).
public struct LookDetailMedia: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let url: String
    public let thumbUrl: String?
    public let mediaType: String        // "IMAGE" | "VIDEO"
    public let caption: String?
    public let createdAt: String
    public let focalX: Double?
    public let focalY: Double?
    public let review: LookDetailReview?

    public var isVideo: Bool { mediaType.uppercased() == "VIDEO" }

    /// The validated focal point to crop on, or nil (center) when absent or
    /// invalid — same degradation as the feed's.
    public var focalPoint: MediaFocalPoint? { MediaFocalPoint(x: focalX, y: focalY) }

    /// Thumb when present, else the full asset — for the grid tiles.
    public var thumbOrFullURL: URL? { URL(string: thumbUrl ?? url) }
}

/// An ordered asset entry on the post (`LooksDetailAssetDto`).
public struct LookDetailAsset: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let sortOrder: Int
    public let mediaAssetId: String
    public let media: LookDetailMedia
}

/// The review surfaced on a look (`LooksDetailReviewDto`). The body is
/// admin-only on the wire, so only the headline is renderable here.
public struct LookDetailReview: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let rating: Int
    public let headline: String?
    public let helpfulCount: Int

    /// "★★★★★" / "★★★☆☆" — port of web's
    /// `'★'.repeat(clamp(rating, 0, 5)).padEnd(5, '☆')`, clamped so a bad
    /// rating can never render a runaway string.
    public var stars: String {
        let filled = min(max(rating, 0), 5)
        return String(repeating: "★", count: filled)
            + String(repeating: "☆", count: 5 - filled)
    }

    /// "Helpful: 12", or nil when nobody has marked it yet.
    ///
    /// ⚠️ A DELIBERATE divergence from web, which renders "Helpful: 0"
    /// unconditionally (LookDetailClient.tsx:522-524). A just-posted review
    /// always reads 0, and "Helpful: 0" on a 5★ review scans as a criticism of
    /// it rather than an absence of votes. Native hides the line until it says
    /// something. Nothing else keys on this.
    public var helpfulLabel: String? {
        helpfulCount > 0 ? "Helpful: \(helpfulCount)" : nil
    }
}

/// The 5 engagement counters on a look detail (`LooksDetailCountsDto`). The feed
/// only carries likes + comments; saves/shares/views are detail-only.
public struct LookDetailCounts: Decodable, Sendable, Hashable {
    public let likes: Int
    public let comments: Int
    public let saves: Int
    public let shares: Int
    public let views: Int
}

/// What the viewer may do with this look (`LooksDetailViewerContextDto`).
public struct LookDetailViewerContext: Decodable, Sendable, Hashable {
    public let isAuthenticated: Bool
    public let viewerLiked: Bool
    public let viewerSaved: Bool
    public let canComment: Bool
    public let canSave: Bool
    public let isOwner: Bool
}

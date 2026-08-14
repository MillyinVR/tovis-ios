import Foundation

// Wire model for a client's PUBLIC creator profile as seen from the pro client
// chart's "public profile" view toggle — decode-only.
// GET /api/v1/pro/clients/{id}/public-profile. Mirrors the web
// `loadPublicClientProfileByClientId` (the exact data the web `?view=public`
// branch renders through `PublicProfileView`). The pro views it as a neutral
// read-only viewer, so `viewer.isOwn`/`following` are always false and no follow
// control is shown. The endpoint returns `profile: null` when the client hasn't
// opted into a public profile — the service surfaces that as `nil` (empty state),
// distinct from a 404 (route not yet deployed → web-pointer fallback). See
// docs/PRO-BACKEND-CONTRACTS.md.
//
// Every field decodes newly-added keys with `decodeIfPresent ?? default` so an
// older/not-yet-deployed backend still decodes cleanly.

/// The client's public creator profile: handle · avatar · bio · follower /
/// following / looks counts · published-looks grid.
public struct ProClientPublicProfile: Decodable, Sendable {
    public let handle: String
    /// Pre-formatted "@handle" — public profiles are addressed by handle, never
    /// by legal name.
    public let displayName: String
    public let avatarUrl: String?
    public let bio: String?
    /// Derived creator standing (tier · percentile · city). Absent on an older
    /// backend, which decodes to `.none` — no badge, never a fake one.
    public let standing: ProClientCreatorStanding
    public let counts: ProClientPublicCounts
    public let looks: [ProClientPublicLook]
    /// The creator's SHARED boards. Empty on an older backend.
    public let boards: [ProClientPublicBoard]
    public let viewer: ProClientPublicViewer

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = try c.decode(String.self, forKey: .handle)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "@\(handle)"
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        bio = try c.decodeIfPresent(String.self, forKey: .bio)
        standing = try c.decodeIfPresent(ProClientCreatorStanding.self, forKey: .standing) ?? .none
        counts = try c.decodeIfPresent(ProClientPublicCounts.self, forKey: .counts) ?? .zero
        looks = try c.decodeIfPresent([ProClientPublicLook].self, forKey: .looks) ?? []
        boards = try c.decodeIfPresent([ProClientPublicBoard].self, forKey: .boards) ?? []
        viewer = try c.decodeIfPresent(ProClientPublicViewer.self, forKey: .viewer) ?? .neutral
    }

    private enum CodingKeys: String, CodingKey {
        case handle, displayName, avatarUrl, bio, standing, counts, looks, boards, viewer
    }
}

/// How widely other people save this creator's looks, as shown beside the name
/// ("✦ Tastemaker · top 5% saver · Brooklyn").
public struct ProClientCreatorStanding: Decodable, Sendable {
    public enum Tier: String, Decodable, Sendable {
        case none = "NONE"
        case rising = "RISING"
        case tastemaker = "TASTEMAKER"
    }

    public let tier: Tier
    /// e.g. 5 for "top 5% saver". Nil when the creator is unranked.
    public let topPercent: Int?
    /// The creator's own opted-in public city.
    public let city: String?

    static let none = ProClientCreatorStanding(tier: .none, topPercent: nil, city: nil)

    public init(tier: Tier, topPercent: Int?, city: String?) {
        self.tier = tier
        self.topPercent = topPercent
        self.city = city
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An unrecognized tier decodes to `.none` rather than throwing: a tier
        // this build doesn't know about must render as no badge, not as a failed
        // profile load.
        let raw = try c.decodeIfPresent(String.self, forKey: .tier)
        tier = raw.flatMap(Tier.init(rawValue:)) ?? .none
        topPercent = try c.decodeIfPresent(Int.self, forKey: .topPercent)
        city = try c.decodeIfPresent(String.self, forKey: .city)
    }

    private enum CodingKeys: String, CodingKey { case tier, topPercent, city }
}

/// One SHARED board on the creator's Boards tab.
public struct ProClientPublicBoard: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let slug: String
    /// The web board path (`/u/{handle}/boards/{slug}`).
    public let href: String
    /// REAL number of publicly-visible looks on the board.
    public let itemCount: Int
    /// Up to four cover images; may be shorter, and the grid pads the rest.
    public let tileImageUrls: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Board"
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        href = try c.decodeIfPresent(String.self, forKey: .href) ?? ""
        itemCount = try c.decodeIfPresent(Int.self, forKey: .itemCount) ?? 0
        tileImageUrls = try c.decodeIfPresent([String].self, forKey: .tileImageUrls) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, slug, href, itemCount, tileImageUrls
    }
}

/// Follower / following / published-looks tallies.
public struct ProClientPublicCounts: Decodable, Sendable {
    public let followers: Int
    public let following: Int
    public let looks: Int

    static let zero = ProClientPublicCounts(followers: 0, following: 0, looks: 0)

    public init(followers: Int, following: Int, looks: Int) {
        self.followers = followers
        self.following = following
        self.looks = looks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        followers = try c.decodeIfPresent(Int.self, forKey: .followers) ?? 0
        following = try c.decodeIfPresent(Int.self, forKey: .following) ?? 0
        looks = try c.decodeIfPresent(Int.self, forKey: .looks) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case followers, following, looks }
}

/// One published look on the public grid.
public struct ProClientPublicLook: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let imageUrl: String?
    public let saveCount: Int
    /// The web look-detail path (`/looks/{id}`). Carried for parity; the native
    /// grid navigates with `id` directly (the same value the server builds this
    /// href from), so no parse is needed.
    public let href: String
    /// The pro whose work the look shows — "Noor Haddad".
    public let proName: String?
    public let serviceName: String?
    /// ⚠️ Already composed by the server as "From $250". A look's price is a
    /// STARTING price, so this is never rendered as a bare figure, and the app
    /// must not reformat it into one.
    public let priceLabel: String?
    /// Bookings citing this look as their source — "12 recreated this".
    public let recreatedCount: Int
    /// A SUPER_ADMIN promoted this look into the editorial Spotlight. Labelled
    /// "Spotlight", not "Viral": an editor picked it, so claiming an engagement
    /// event would be a lie.
    public let spotlighted: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Look"
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        saveCount = try c.decodeIfPresent(Int.self, forKey: .saveCount) ?? 0
        href = try c.decodeIfPresent(String.self, forKey: .href) ?? "/looks/\(id)"
        proName = try c.decodeIfPresent(String.self, forKey: .proName)
        serviceName = try c.decodeIfPresent(String.self, forKey: .serviceName)
        priceLabel = try c.decodeIfPresent(String.self, forKey: .priceLabel)
        recreatedCount = try c.decodeIfPresent(Int.self, forKey: .recreatedCount) ?? 0
        spotlighted = try c.decodeIfPresent(Bool.self, forKey: .spotlighted) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, imageUrl, saveCount, href
        case proName, serviceName, priceLabel, recreatedCount, spotlighted
    }
}

/// Signed-in-viewer flags. Always neutral (`false`/`false`) for the pro chart
/// toggle — the pro is not the profile owner and follow is hidden.
public struct ProClientPublicViewer: Decodable, Sendable {
    public let isOwn: Bool
    public let following: Bool

    static let neutral = ProClientPublicViewer(isOwn: false, following: false)

    public init(isOwn: Bool, following: Bool) {
        self.isOwn = isOwn
        self.following = following
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isOwn = try c.decodeIfPresent(Bool.self, forKey: .isOwn) ?? false
        following = try c.decodeIfPresent(Bool.self, forKey: .following) ?? false
    }

    private enum CodingKeys: String, CodingKey { case isOwn, following }
}

/// Envelope for GET /api/v1/pro/clients/{id}/public-profile — `{ ok, profile }`,
/// where `profile` is null when the client has no public profile.
struct ProClientPublicProfileResponse: Decodable {
    let profile: ProClientPublicProfile?
}

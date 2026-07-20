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
    public let counts: ProClientPublicCounts
    public let looks: [ProClientPublicLook]
    public let viewer: ProClientPublicViewer

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = try c.decode(String.self, forKey: .handle)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "@\(handle)"
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        bio = try c.decodeIfPresent(String.self, forKey: .bio)
        counts = try c.decodeIfPresent(ProClientPublicCounts.self, forKey: .counts) ?? .zero
        looks = try c.decodeIfPresent([ProClientPublicLook].self, forKey: .looks) ?? []
        viewer = try c.decodeIfPresent(ProClientPublicViewer.self, forKey: .viewer) ?? .neutral
    }

    private enum CodingKeys: String, CodingKey {
        case handle, displayName, avatarUrl, bio, counts, looks, viewer
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Look"
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        saveCount = try c.decodeIfPresent(Int.self, forKey: .saveCount) ?? 0
        href = try c.decodeIfPresent(String.self, forKey: .href) ?? "/looks/\(id)"
    }

    private enum CodingKeys: String, CodingKey { case id, name, imageUrl, saveCount, href }
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

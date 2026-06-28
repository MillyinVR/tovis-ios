import Foundation

// Wire models for the client "Me" dashboard — GET /api/v1/me.
// Mirrors `ClientMePageDTO` (lib/dto/clientMe.ts) + the route in
// app/api/v1/me/route.ts, which serializes the SAME loader the web /client/me
// page renders. As elsewhere, only the rendered subset is modeled; nullable
// fields are Swift optionals and unknown keys are ignored.

/// Envelope for `GET /api/v1/me` → `{ ok, me }`.
struct ClientMeResponse: Decodable, Sendable {
    let me: ClientMe
}

public struct ClientMe: Decodable, Sendable {
    public let user: ClientMeUser
    public let profile: ClientMeProfile
    public let boards: [ClientMeBoard]
    public let following: ClientMeFollowing
    public let counts: ClientMeCounts
    public let upcomingNotificationBooking: ClientBooking?
    public let history: [ClientMeHistoryItem]
    public let myLooks: [ClientMeLook]
    public let activityUnreadCount: Int
    public let creator: ClientMeCreator
}

public struct ClientMeUser: Decodable, Sendable {
    public let id: String
    public let email: String?
    public let createdAt: String
}

public struct ClientMeProfile: Decodable, Sendable {
    public let id: String
    public let firstName: String?
    public let lastName: String?
    public let email: String?
    public let avatarUrl: String?
    public let handle: String?
    public let isPublicProfile: Bool
}

public struct ClientMeCounts: Decodable, Sendable {
    public let boards: Int
    public let saved: Int
    public let booked: Int
    public let following: Int
    public let followers: Int
}

// MARK: - Boards (LooksBoardPreviewDto subset)

public struct ClientMeBoard: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let itemCount: Int
    public let items: [ClientMeBoardItem]

    /// Up to 4 preview thumbnails — mirrors the web `buildBoardPreviewImageUrls`
    /// (prefer the thumb, else the full URL).
    public var previewImageUrls: [String] {
        items.compactMap { $0.lookPost?.primaryMedia?.thumbUrl ?? $0.lookPost?.primaryMedia?.url }
    }
}

public struct ClientMeBoardItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let lookPost: ClientMeBoardLookPost?
}

public struct ClientMeBoardLookPost: Decodable, Sendable {
    public let id: String
    public let primaryMedia: ClientMeMedia?
}

public struct ClientMeMedia: Decodable, Sendable {
    public let thumbUrl: String?
    public let url: String?
}

// MARK: - Following (MyFollowingListResponseDto subset)

public struct ClientMeFollowing: Decodable, Sendable {
    public let items: [ClientMeFollowingItem]
}

public struct ClientMeFollowingItem: Decodable, Sendable, Identifiable {
    public let professional: MeProPreview
    public var id: String { professional.id }
}

/// A pro preview (LooksProProfilePreviewDto). Carries the name-display toggle so
/// it resolves the same public name the web does.
public struct MeProPreview: Decodable, Sendable, Identifiable {
    public let id: String
    public let businessName: String?
    public let firstName: String?
    public let lastName: String?
    public let handle: String?
    public let nameDisplay: ProNameDisplay?
    public let location: String?
    public let professionType: String?
    public let avatarUrl: String?

    /// Port of `pickProfessionalPublicDisplayName` — same fallbacks as
    /// `BookingProfessional.displayName`.
    public var displayName: String {
        let business = Self.trimmed(businessName)
        let real = [Self.trimmed(firstName), Self.trimmed(lastName)]
            .compactMap { $0 }.joined(separator: " ")
        let realName = real.isEmpty ? nil : real
        let handleLabel = Self.trimmed(handle).map { "@\($0)" }

        switch nameDisplay {
        case .realName:
            return realName ?? business ?? handleLabel ?? Self.fallback
        case .handle:
            return handleLabel ?? business ?? realName ?? Self.fallback
        case .businessName, .unknown, .none:
            return business ?? realName ?? Self.fallback
        }
    }

    /// "Hairstylist · Los Angeles" — mirrors the web `buildFollowingSubtitle`.
    public var subtitle: String? {
        let parts = [Self.trimmed(professionType), Self.trimmed(location)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let fallback = "Professional"

    private static func trimmed(_ value: String?) -> String? {
        let t = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }
}

// MARK: - History

public struct ClientMeHistoryItem: Decodable, Sendable, Identifiable {
    public let kind: String   // "completed" | "upcoming"
    public let label: String  // "BOOKED" | "UPCOMING"
    public let booking: ClientBooking
    public let heroImageUrl: String?

    public var id: String { booking.id }
}

// MARK: - My looks

public struct ClientMeLook: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let imageUrl: String?
    public let visibility: String

    public var isPublic: Bool { visibility.uppercased() == "PUBLIC" }
}

// MARK: - Creator metrics

public struct ClientMeCreator: Decodable, Sendable {
    public let isCreator: Bool
    public let savesOnYourLooks: Int
    public let bookedFromYou: Int
    public let remixes: [ClientMeRemix]
}

public struct ClientMeRemix: Decodable, Sendable, Identifiable {
    public let id: String
    public let who: String
    public let lookName: String
    public let proName: String
    public let bookedAt: String
}

/// PATCH /api/v1/client/looks/{id} — request body for the visibility toggle.
struct ClientLookVisibilityRequest: Encodable, Sendable {
    let isPublic: Bool
}
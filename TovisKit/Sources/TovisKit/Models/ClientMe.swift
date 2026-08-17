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
    /// Hero photo for the upcoming card — the visit's after-shot, or the look it
    /// was booked from. Optional so an older server still decodes.
    public let upcomingNotificationHeroImageUrl: String?
    public let history: [ClientMeHistoryItem]
    /// The client's authored looks.
    ///
    /// ⚠️ No longer rendered as its own grid — screen 7 folded each look's
    /// visibility switch onto the history card for the visit it came out of
    /// (`ClientMeHistoryItem.look`). Kept because the server still sends it and
    /// older builds require it; do not resurrect the grid from it.
    public let myLooks: [ClientMeLook]
    public let activityUnreadCount: Int
    /// The owner's own tier / percentile / city — the standing a VISITOR to
    /// `/u/{handle}` could already see. Optional so a pre-screen-7 server still
    /// decodes: absent renders no standing row, which is also the correct
    /// rendering for an unranked creator.
    public let standing: ClientMeStanding?
    public let creator: ClientMeCreator
}

/// "✦ Tastemaker · top 2% saver · Brooklyn".
public struct ClientMeStanding: Decodable, Sendable {
    /// `NONE` | `RISING` | `TASTEMAKER`.
    public let tier: String
    /// e.g. 2 for "top 2% saver". Null while the creator is unranked.
    public let topPercent: Int?
    /// The creator's opt-in public city.
    public let city: String?

    public var isTastemaker: Bool { tier.uppercased() == "TASTEMAKER" }
    public var isRising: Bool { tier.uppercased() == "RISING" }
    /// Below Rising there is no standing to state, and a placeholder pill would
    /// flatter a creator the tier job deliberately declined to rank.
    public var isRanked: Bool { isTastemaker || isRising }

    /// "top 2% saver · Brooklyn" — each half only when it is real.
    public var detail: String? {
        var parts: [String] = []
        if let topPercent { parts.append("top \(topPercent)% saver") }
        if let city = city?.trimmedOrNil { parts.append(city) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public var tierLabel: String { isTastemaker ? "Tastemaker" : "Rising" }
}

public struct ClientMeUser: Decodable, Sendable {
    public let id: String
    public let email: String?
    public let createdAt: String

    /// Every workspace this account may act in (web #669). The payload's own
    /// `role` is useless as a capability signal — it is the ACTING role, always
    /// `CLIENT` here — and the session JWT carries only that acting role too, so
    /// this is the ONLY way native can tell a dual-role pro browsing as a client
    /// from a client-only account.
    ///
    /// Optional because it is absent on any server older than that PR: an absent
    /// key must degrade to "no switch offered", never to a decode failure that
    /// would take the whole Me tab down. `Role` decodes unknown values to
    /// `.unknown` rather than throwing, so a future workspace is safe too.
    public let availableWorkspaces: [Role]?

    /// Whether to offer the "Switch to pro" row. False while the field is absent
    /// (pre-#669 servers) — the row simply doesn't appear until web deploys.
    public var canSwitchToPro: Bool {
        availableWorkspaces?.contains(.pro) ?? false
    }
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

    /// `PRIVATE` | `SHARED`. Without it a client could not tell their own
    /// private boards from the ones anyone with the link can open — the same
    /// gap web #889 closed on `/client/me`, which dropped the field when it
    /// mapped a board to its card.
    public let visibility: String

    /// Whether anyone with the link can open this board.
    public var isShared: Bool { visibility.uppercased() == "SHARED" }

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
public struct MeProPreview: Decodable, Sendable, Identifiable, ProPublicNameSource {
    public let id: String
    public let businessName: String?
    public let firstName: String?
    public let lastName: String?
    public let handle: String?
    public let nameDisplay: ProNameDisplay?
    public let location: String?
    public let professionType: String?
    /// The pro's craft as WORDS — "Manicurist", never the raw `MANICURIST`.
    /// Composed by the server (`formatProfessionLabel`) so the enum→label map
    /// has one home. Optional only so an older server still decodes; the
    /// subtitle falls back to omitting the craft rather than shouting the enum.
    public let professionLabel: String?
    public let avatarUrl: String?

    /// The pro's public name — "Professional" when they have no usable name
    /// token (this is a browsing surface, so the neutral noun reads right; it is
    /// also web's own default fallback).
    public var displayName: String { publicDisplayName(fallback: "Professional") }

    /// "Manicurist · Brooklyn, NY".
    ///
    /// This used to join the RAW `professionType`, so the row read
    /// "MANICURIST · Brooklyn, NY" — and `.capitalized` would not have saved it
    /// either: `MASSAGE_THERAPIST` capitalises to "Massage_Therapist". The label
    /// is composed server-side now, which is also why web's own hand-rolled
    /// twin of this could drift without anything noticing.
    public var subtitle: String? {
        let parts = [professionLabel?.trimmedOrNil, location?.trimmedOrNil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - History

public struct ClientMeHistoryItem: Decodable, Sendable, Identifiable {
    public let kind: String   // "completed" | "upcoming"
    public let label: String  // "BOOKED" | "UPCOMING"
    public let booking: ClientBooking
    public let heroImageUrl: String?
    /// The look posted from this visit, when there is one.
    ///
    /// Screen 7 folded the public/private switch onto the history card; a visit
    /// with no look keeps the "Share your look" affordance instead. Optional so
    /// a pre-screen-7 server still decodes — absent simply means no switch.
    public let look: ClientMeHistoryLook?

    public var id: String { booking.id }
}

/// The authored look a history card carries.
public struct ClientMeHistoryLook: Decodable, Sendable {
    public let id: String
    public let name: String
    /// `PUBLIC` | `FOLLOWERS_ONLY` | `UNLISTED`.
    public let visibility: String

    public var isPublic: Bool { visibility.uppercased() == "PUBLIC" }
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
    /// Level + progress, resolved SERVER-side.
    ///
    /// 🔴 The thresholds are deliberately not here. The level is the higher of
    /// two ladders (saves and bookings) and both platforms render the same
    /// computed answer — re-typing the ladders in Swift is how the pill and the
    /// progress line come to disagree the first time either list is edited.
    /// See `lib/clients/creatorLevel.ts`.
    public let level: ClientMeCreatorLevel?
}

/// A creator's level and how far along the next rung they are.
public struct ClientMeCreatorLevel: Decodable, Sendable {
    public let level: Int
    public let nextLevel: Int?
    /// `saves` | `bookings` — which ladder the progress line is about.
    public let nextLadder: String?
    public let nextThreshold: Int?
    public let remaining: Int?
    /// 0–1 along the current rung.
    public let progress: Double

    /// "57 bookings to Lvl 5", or nil at the top of the ladder.
    ///
    /// Names the UNIT because the level is the higher of two ladders, so a bare
    /// "57 to Lvl 5" would not say 57 of what.
    public var progressLabel: String? {
        guard let remaining, let nextLevel else { return nil }
        let one = remaining == 1
        let unit: String
        if nextLadder == "bookings" {
            unit = one ? "booking" : "bookings"
        } else {
            unit = one ? "save" : "saves"
        }
        return "\(remaining) \(unit) to Lvl \(nextLevel)"
    }
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
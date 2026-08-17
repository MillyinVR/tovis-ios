import Foundation

// Wire models for the client home screen — GET /api/v1/client/home.
// Mirrors `ClientHomeDTO` in tovis-app/lib/dto/clientHome.ts. We model only the
// fields the native home renders today; `Decodable` skips unknown keys, so the
// backend can carry richer data and we extend these as new screens need it.
// Every field the backend can null is a Swift optional, so a partial payload
// never fails to decode.

/// Envelope for `GET /api/v1/client/home` → `{ ok: true, home: {...} }`.
struct ClientHomeResponse: Decodable, Sendable {
    let home: ClientHome
}

public struct ClientHome: Decodable, Sendable {
    /// What the greeting calls this client — the server's answer, not ours.
    /// Optional only because the field is optional on the wire; when it is
    /// missing the header falls back rather than inventing a name from the
    /// email, which is what it used to do (`demo-maya@` → "Demo").
    public let displayName: String?
    public let upcoming: HomeBooking?
    public let upcomingCount: Int
    /// Visible-review aggregate for the pro on the next-booking card, or nil
    /// when they have none — no star at all beats an empty one.
    public let upcomingProRating: HomeRating?
    public let action: HomeAction?
    public let invites: [HomeInvite]
    public let waitlists: [HomeWaitlist]
    public let favoritePros: [HomeFavoritePro]
    public let favoriteServices: [HomeFavoriteService]
    public let viralLive: [HomeViral]
    public let viralPending: [HomeViral]
}

public struct HomeRating: Decodable, Sendable {
    public let average: Double
    public let count: Int

    /// One decimal, the way the frame prints it ("4.9").
    public var display: String {
        String(format: "%.1f", average)
    }
}

// MARK: - Shared references

/// A professional reference. Every field except `id` is optional because the
/// backend's various home payloads carry different subsets (a booking's pro has
/// no `professionType`; a favorite pro has no `timeZone`, etc.).
public struct HomeProfessional: Decodable, Sendable, Identifiable {
    public let id: String
    public let businessName: String?
    public let handle: String?
    public let avatarUrl: String?
    public let professionType: String?
    /// The craft as WORDS, composed by the server (`formatProfessionLabel`).
    /// Never derive this from `professionType` on the client: that map lives in
    /// ONE place, and three separate client-side transforms of the raw enum are
    /// exactly how "MANICURIST" and "Massage_Therapist" reached real screens.
    public let professionLabel: String?
    public let location: String?
    public let timeZone: String?

    /// Server-resolved public display name that honors the pro's `nameDisplay`
    /// toggle (business name / real name / @handle). The web loader resolves it
    /// once so every client renders the same string. Optional so a pre-deploy
    /// backend or an older fixture falls back to the local rule below.
    private let serverDisplayName: String?

    private enum CodingKeys: String, CodingKey {
        case id, businessName, handle, avatarUrl, professionType, professionLabel, location, timeZone
        case serverDisplayName = "displayName"
    }

    /// The server-resolved name when present; otherwise the legacy local rule —
    /// solo pros often have no `businessName`, so fall back to the handle, then a
    /// neutral label, never an empty string. (Legacy path is BUSINESS_NAME-biased
    /// and can surface a handle; it's inert once the backend sends `displayName`.)
    public var displayName: String {
        if let resolved = serverDisplayName?.trimmedOrNil { return resolved }
        if let name = businessName, !name.isEmpty { return name }
        if let handle, !handle.isEmpty { return "@\(handle)" }
        return "Your pro"
    }
}

/// A minimal service reference (`{ id, name }`).
public struct HomeServiceRef: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
}

// MARK: - Booking

public struct HomeBooking: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let scheduledFor: String
    public let totalAmount: String?
    public let totalDurationMinutes: Int
    public let locationType: String?
    public let locationTimeZone: String?
    public let service: HomeServiceRef?
    public let professional: HomeProfessional?
    public let location: HomeLocation?
    /// Present on a pending-consultation booking (the proposed plan to review).
    public let consultationApproval: HomeConsultationApproval?

    /// Best timezone to render this booking's time in: the location's, then the
    /// booking-level snapshot, then the pro's. Nil → render in the device zone.
    public var resolvedTimeZone: String? {
        location?.timeZone ?? locationTimeZone ?? professional?.timeZone
    }
}

/// The pro's proposed consultation plan (subset of `consultationApproval`).
public struct HomeConsultationApproval: Decodable, Sendable {
    public let status: String?
    public let proposedTotal: String?
    public let notes: String?
}

public struct HomeLocation: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let formattedAddress: String?
    public let city: String?
    public let state: String?
    public let timeZone: String?
}

// MARK: - Action banner (tagged union on `kind`)

/// The pro's before/after pair for a visit, as the home action card shows it.
/// Every field is optional: a pro who photographed only one phase still has a
/// card worth rendering.
public struct HomeBeforeAfter: Decodable, Sendable {
    public let beforeUrl: String?
    public let afterUrl: String?

    public var hasAny: Bool { beforeUrl != nil || afterUrl != nil }
}

public enum HomeAction: Decodable, Sendable {
    case pendingConsultation(booking: HomeBooking)
    case aftercarePaymentDue(
        booking: HomeBooking,
        aftercare: HomeAftercare,
        beforeAfter: HomeBeforeAfter?
    )

    private enum CodingKeys: String, CodingKey { case kind, booking, aftercare, beforeAfter }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "PENDING_CONSULTATION":
            self = .pendingConsultation(booking: try c.decode(HomeBooking.self, forKey: .booking))
        case "AFTERCARE_PAYMENT_DUE":
            self = .aftercarePaymentDue(
                booking: try c.decode(HomeBooking.self, forKey: .booking),
                aftercare: try c.decode(HomeAftercare.self, forKey: .aftercare),
                beforeAfter: try c.decodeIfPresent(HomeBeforeAfter.self, forKey: .beforeAfter)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "Unknown client-home action kind: \(kind)"
            )
        }
    }
}

public struct HomeAftercare: Decodable, Sendable, Identifiable {
    public let id: String
    public let notes: String?
}

// MARK: - Last-minute invites

public struct HomeInvite: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let opening: HomeOpening
}

public struct HomeOpening: Decodable, Sendable, Identifiable {
    public let id: String
    public let startAt: String
    public let endAt: String?
    public let timeZone: String?
    public let professional: HomeProfessional
    /// Services on this opening (drives the invite title + starting price).
    public let services: [HomeOpeningService]?
    /// The incentive THIS client was matched on, already reduced to display copy
    /// ("20% off", "$40 off", "Free service") by the server — the same block the
    /// openings feed sends, so an offer can't be worded differently on the two
    /// screens. Optional because it is added in a paired web change: absent
    /// against current prod, which simply means no badge until that deploys.
    public let publicIncentive: ClientOpeningIncentive?

    /// Title like the web `inviteTitle`: first service, "+ N more" when multiple.
    public var title: String {
        let names = (services ?? []).map { $0.service.name }.filter { !$0.isEmpty }
        guard let first = names.first else { return "Last-minute opening" }
        return names.count == 1 ? first : "\(first) + \(names.count - 1) more"
    }

    /// Starting price like the web `invitePrice`: salon → mobile → service min.
    public var startingPrice: String? {
        guard let s = services?.first else { return nil }
        return s.offering?.salonPriceStartingAt
            ?? s.offering?.mobilePriceStartingAt
            ?? s.service.minPrice
    }

    /// The offer, upper-cased for the badge that sits beside the service name on
    /// the home card — the first place a client meets a last-minute opening, and
    /// the place the deal has to be legible at a glance.
    public var incentiveHeadline: String? {
        publicIncentive?.label?.trimmedOrNil?.uppercased()
    }
}

public struct HomeOpeningService: Decodable, Sendable, Identifiable {
    public let id: String
    public let offeringId: String?
    public let service: HomeOpeningServiceRef
    public let offering: HomeOpeningOffering?
}

public struct HomeOpeningServiceRef: Decodable, Sendable {
    public let name: String
    public let minPrice: String?
}

public struct HomeOpeningOffering: Decodable, Sendable {
    public let salonPriceStartingAt: String?
    public let mobilePriceStartingAt: String?
}

// MARK: - Waitlists

public struct HomeWaitlist: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String
    /// The client's real FIFO place in this pro's queue for this service, as the
    /// pro's own waitlist ranks it. nil when the server could not establish it —
    /// the row then shows no place at all. NOT the row's index: this screen used
    /// to print `#index + 1`, so a client on one waitlist always read "#1 in
    /// line" however many people were actually ahead of them.
    public let queuePosition: Int?
    public let service: HomeServiceRef?
    public let professional: HomeProfessional?
}

// MARK: - Favorites

public struct HomeFavoritePro: Decodable, Sendable {
    public let professional: HomeProfessional?
}

public struct HomeFavoriteService: Decodable, Sendable, Identifiable {
    public let id: String
    public let service: HomeFavoriteServiceRef?
}

public struct HomeFavoriteServiceRef: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let minPrice: String
    public let defaultDurationMinutes: Int
    public let defaultImageUrl: String?
    public let category: HomeCategoryRef?
}

public struct HomeCategoryRef: Decodable, Sendable {
    public let name: String
}

// MARK: - Viral looks

public struct HomeViral: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let sourceUrl: String?

    /// REQUESTED / IN_REVIEW for pending looks (drives the review pipeline).
    public let status: String?

    /// The picture this look is shown by — the reviewer's cover, else the photo
    /// the submitter attached. The SERVER picks between the two so the phone,
    /// the web and the admin queue cannot each show a different one; nil means
    /// there is no picture yet and the card draws its own gradient.
    public let coverImage: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, sourceUrl, status, coverImage, count = "_count"
    }
    private struct Count: Decodable, Sendable { let approvalFanOuts: Int }

    public let fanOutCount: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        coverImage = try c.decodeIfPresent(String.self, forKey: .coverImage)
        fanOutCount = (try c.decodeIfPresent(Count.self, forKey: .count))?.approvalFanOuts ?? 0
    }

    /// Platform label derived from the source URL ("TikTok", "Instagram", …).
    public var platform: String? {
        guard let host = sourceUrl.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return nil }
        if host.contains("tiktok") { return "TikTok" }
        if host.contains("instagram") || host.contains("instagr.am") { return "Instagram" }
        if host.contains("pinterest") || host.contains("pin.it") { return "Pinterest" }
        if host.contains("youtube") || host.contains("youtu.be") { return "YouTube" }
        return "Link"
    }
}

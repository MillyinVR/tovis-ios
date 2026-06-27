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
    public let upcoming: HomeBooking?
    public let upcomingCount: Int
    public let action: HomeAction?
    public let invites: [HomeInvite]
    public let waitlists: [HomeWaitlist]
    public let favoritePros: [HomeFavoritePro]
    public let favoriteServices: [HomeFavoriteService]
    public let viralLive: [HomeViral]
    public let viralPending: [HomeViral]
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
    public let location: String?
    public let timeZone: String?

    /// Solo pros often have no `businessName` (see the name-starvation audit), so
    /// fall back to the handle, then a neutral label — never an empty string.
    public var displayName: String {
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

    /// Best timezone to render this booking's time in: the location's, then the
    /// booking-level snapshot, then the pro's. Nil → render in the device zone.
    public var resolvedTimeZone: String? {
        location?.timeZone ?? locationTimeZone ?? professional?.timeZone
    }
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

public enum HomeAction: Decodable, Sendable {
    case pendingConsultation(booking: HomeBooking)
    case aftercarePaymentDue(booking: HomeBooking, aftercare: HomeAftercare)

    private enum CodingKeys: String, CodingKey { case kind, booking, aftercare }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "PENDING_CONSULTATION":
            self = .pendingConsultation(booking: try c.decode(HomeBooking.self, forKey: .booking))
        case "AFTERCARE_PAYMENT_DUE":
            self = .aftercarePaymentDue(
                booking: try c.decode(HomeBooking.self, forKey: .booking),
                aftercare: try c.decode(HomeAftercare.self, forKey: .aftercare)
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
}

// MARK: - Waitlists

public struct HomeWaitlist: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String
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
}

// MARK: - Viral looks

public struct HomeViral: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let sourceUrl: String?

    private enum CodingKeys: String, CodingKey { case id, name, sourceUrl, count = "_count" }
    private struct Count: Decodable, Sendable { let approvalFanOuts: Int }

    public let fanOutCount: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl)
        fanOutCount = (try c.decodeIfPresent(Count.self, forKey: .count))?.approvalFanOuts ?? 0
    }
}

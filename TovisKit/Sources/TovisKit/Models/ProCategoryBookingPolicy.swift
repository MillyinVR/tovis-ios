import Foundation

/// P7a-5 — the pro's per-service-category settings: when clients can book, and
/// what deposit that category asks for.
///
/// 🔴 "Right away" is NOT called "book instantly" anywhere the pro can see.
/// `autoAcceptBookings` already means something adjacent but different
/// (request vs auto-confirm), and two settings sharing a name in two screens is
/// a trap the pro pays for.
public enum ProCategoryBookingGate: String, Codable, Sendable, Equatable {
    /// Today's behaviour, and what every category with no row does.
    case instant = "INSTANT"
    /// Hold the slot until the consult's safety answers are in.
    case afterPrep = "AFTER_PREP"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProCategoryBookingGate(rawValue: raw) ?? .unknown
    }
}

/// One category the pro actually sells in, with her setting or the inherited
/// default. The server derives the list from her own offerings — a pro is never
/// shown a control over a category she does not work in.
public struct ProCategoryBookingPolicy: Decodable, Sendable, Equatable, Identifiable {
    public let serviceCategoryId: String
    public let categoryName: String
    public let bookingGate: ProCategoryBookingGate
    /// Null = this category uses the pro's account-wide deposit amount.
    public let depositType: String?
    /// Dollars as a decimal string, the way every money value crosses this wire.
    public let depositFlatAmount: String?
    public let depositPercent: Int?

    public var id: String { serviceCategoryId }
}

/// What a category inherits when it states nothing of its own, so the screen can
/// SHOW the fallback rather than an empty field the pro has to remember.
public struct ProCategoryAccountDeposit: Decodable, Sendable, Equatable {
    public let depositEnabled: Bool
    public let depositType: String?
    public let depositFlatAmount: String?
    public let depositPercent: Int?
    public let stripeReady: Bool
}

public struct ProCategoryBookingPolicyResponse: Decodable, Sendable {
    public let categories: [ProCategoryBookingPolicy]
    public let accountDeposit: ProCategoryAccountDeposit
    /// Why a category deposit cannot be set right now, or nil. The server's own
    /// sentence — it names the setting that fixes it, so it is shown verbatim.
    public let depositBlocker: String?
}

struct ProCategoryBookingPolicySaveResponse: Decodable, Sendable {
    struct Saved: Decodable, Sendable {
        let serviceCategoryId: String
        let bookingGate: ProCategoryBookingGate
        let depositType: String?
        let depositFlatAmount: String?
        let depositPercent: Int?
    }
    let policy: Saved
}

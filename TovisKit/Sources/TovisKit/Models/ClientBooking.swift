import Foundation

// Wire models for the client bookings screen — GET /api/v1/client/bookings.
// Mirrors `ClientBookingDTO` + the bucketed response in lib/dto/clientBooking.ts
// and app/api/v1/client/bookings/route.ts. As elsewhere, only the rendered
// subset is modeled; nullable fields are Swift optionals and unknown keys are
// ignored (so e.g. `consultation.proposedServicesJson` is simply skipped).

/// Envelope for `GET /api/v1/client/bookings` → `{ ok, buckets, meta }`.
struct ClientBookingsResponse: Decodable, Sendable {
    let buckets: ClientBookingBuckets
}

public struct ClientBookingBuckets: Decodable, Sendable {
    public let upcoming: [ClientBooking]
    public let pending: [ClientBooking]
    public let prebooked: [ClientBooking]
    public let past: [ClientBooking]
    public let waitlist: [BookingWaitlistEntry]
}

// MARK: - Pro name display (honors the pro's nameDisplay toggle)

/// Matches the `ProNameDisplay` Prisma enum. Unknown values fall back so the app
/// never fails to decode if the backend adds a mode.
public enum ProNameDisplay: String, Decodable, Sendable {
    case businessName = "BUSINESS_NAME"
    case realName = "REAL_NAME"
    case handle = "HANDLE"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProNameDisplay(rawValue: raw) ?? .unknown
    }
}

/// The richer professional reference carried by bookings (has the real-name
/// fields + the display toggle, unlike the leaner `HomeProfessional`).
public struct BookingProfessional: Decodable, Sendable, Identifiable {
    public let id: String
    public let businessName: String?
    public let firstName: String?
    public let lastName: String?
    public let handle: String?
    public let nameDisplay: ProNameDisplay?
    public let location: String?
    public let timeZone: String?

    /// Port of `pickProfessionalPublicDisplayName` (lib/privacy/professionalDisplayName.ts):
    /// honor the pro's chosen mode, degrading to the other forms so solo pros
    /// never render as a blank or a raw email.
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

    private static let fallback = "Your pro"

    private static func trimmed(_ value: String?) -> String? {
        let t = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }
}

// MARK: - Booking

public struct ClientBooking: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String?
    public let source: String?
    public let sessionStep: String?

    public let scheduledFor: String
    public let totalDurationMinutes: Int
    public let bufferMinutes: Int

    public let timeZone: String?
    public let locationType: String?
    public let locationLabel: String?

    public let professional: BookingProfessional?
    public let bookedLocation: BookingLocation?

    public let display: ClientBookingDisplay
    public let checkout: ClientBookingCheckout
    public let items: [ClientBookingItem]
    public let productSales: [ClientBookingProductSale]
    public let consultation: ClientBookingConsultation?

    public let hasUnreadAftercare: Bool
    public let hasPendingConsultationApproval: Bool
}

public struct BookingLocation: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let formattedAddress: String?
    public let city: String?
    public let state: String?
    public let timeZone: String?
}

public struct ClientBookingDisplay: Decodable, Sendable {
    public let title: String
    public let baseName: String
    public let addOnNames: [String]
    public let addOnCount: Int
}

public struct ClientBookingCheckout: Decodable, Sendable {
    public let subtotalSnapshot: String?
    public let serviceSubtotalSnapshot: String?
    public let productSubtotalSnapshot: String?
    public let tipAmount: String?
    public let taxAmount: String?
    public let discountAmount: String?
    public let totalAmount: String?
    public let checkoutStatus: String?
    public let selectedPaymentMethod: String?
    public let paymentAuthorizedAt: String?
    public let paymentCollectedAt: String?
}

public struct ClientBookingItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let type: String  // "BASE" | "ADD_ON"
    public let serviceId: String
    public let name: String
    public let price: String
    public let durationMinutes: Int
    public let parentItemId: String?
    public let sortOrder: Int

    public var isAddOn: Bool { type.uppercased() == "ADD_ON" }
}

public struct ClientBookingProductSale: Decodable, Sendable, Identifiable {
    public let id: String
    public let productId: String?
    public let name: String
    public let unitPrice: String
    public let quantity: Int
    public let lineTotal: String
}

public struct ClientBookingConsultation: Decodable, Sendable {
    public let consultationNotes: String?
    public let consultationPrice: String?
    public let consultationConfirmedAt: String?
    public let approvalStatus: String?
    public let approvalNotes: String?
    public let proposedTotal: String?
    public let approvedAt: String?
    public let rejectedAt: String?
}

// MARK: - Waitlist (the bookings endpoint returns raw waitlist rows)

public struct BookingWaitlistEntry: Decodable, Sendable, Identifiable {
    public let id: String
    public let createdAt: String
    public let status: String
    public let preferenceType: String
    public let notes: String?
    public let service: HomeServiceRef?
    public let professional: BookingProfessional?
}

// MARK: - Consultation decision

/// The client's response to a pro's proposed consultation plan.
public enum ConsultationDecision: Sendable {
    case approve
    case reject

    var wire: String { self == .approve ? "APPROVE" : "REJECT" }
}

/// POST /api/v1/client/bookings/{id}/consultation — request body.
struct ConsultationDecisionRequest: Encodable, Sendable {
    let action: String  // "APPROVE" | "REJECT"
}

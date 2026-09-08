import Foundation

public enum FounderAudience: String, Codable, Sendable {
    case pro = "PRO"
    case client = "CLIENT"
}

public enum FounderSpecialty: String, Codable, Sendable, CaseIterable, Identifiable {
    case hair = "HAIR"
    case nails = "NAILS"
    case lashesBrows = "LASHES_BROWS"
    case skincare = "SKINCARE"
    case makeup = "MAKEUP"
    case permanentMakeup = "PERMANENT_MAKEUP"
    case extensions = "EXTENSIONS"
    case waxingSprayTan = "WAXING_SPRAY_TAN"
    case barber = "BARBER"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hair: "Hair"
        case .nails: "Nails"
        case .lashesBrows: "Lashes & Brows"
        case .skincare: "Skincare"
        case .makeup: "Makeup"
        case .permanentMakeup: "Permanent Makeup"
        case .extensions: "Extensions"
        case .waxingSprayTan: "Waxing & Spray Tan"
        case .barber: "Barbers"
        }
    }
}

public enum FounderRoomKey: String, Codable, Sendable, Identifiable {
    case proAll = "PRO_ALL"
    case proHair = "PRO_HAIR"
    case proNails = "PRO_NAILS"
    case proLashesBrows = "PRO_LASHES_BROWS"
    case proSkincare = "PRO_SKINCARE"
    case proMakeup = "PRO_MAKEUP"
    case proPermanentMakeup = "PRO_PERMANENT_MAKEUP"
    case proExtensions = "PRO_EXTENSIONS"
    case proWaxingSprayTan = "PRO_WAXING_SPRAY_TAN"
    case proBarber = "PRO_BARBER"
    case clientOne = "CLIENT_ONE"
    case clientTwo = "CLIENT_TWO"
    case clientThree = "CLIENT_THREE"

    public var id: String { rawValue }
}

public enum FounderMessageKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case chat = "CHAT"
    case question = "QUESTION"
    case bug = "BUG"
    case idea = "IDEA"
    case love = "LOVE"
    case announcement = "ANNOUNCEMENT"

    public var id: String { rawValue }
}

public enum FounderMessageReportReason: String, Codable, Sendable {
    case spam = "SPAM"
    case harassment = "HARASSMENT"
    case privateInformation = "PRIVATE_INFORMATION"
    case other = "OTHER"
}

public struct FounderRoom: Codable, Sendable, Identifiable {
    public let key: FounderRoomKey
    public let label: String
    public let description: String
    public let audience: FounderAudience
    public let unreadCount: Int

    public var id: FounderRoomKey { key }
}

public struct FounderPortal: Codable, Sendable {
    public let canModerate: Bool
    public let canAdminister: Bool
    public let isOwner: Bool
    /// This server-filtered list is the only room access source used by iOS.
    public let rooms: [FounderRoom]
}

struct FounderPortalResponse: Decodable, Sendable {
    let portal: FounderPortal
}

public struct FounderMessageAuthor: Codable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let avatarUrl: String?
    public let audience: String
    public let role: String
}

public struct FounderMessage: Codable, Sendable, Identifiable {
    public let id: String
    public let room: FounderRoomKey
    public let kind: FounderMessageKind
    public let body: String
    public let createdAt: String
    public let answeredAt: String?
    public let replyToId: String?
    public let author: FounderMessageAuthor
}

struct FounderMessagesResponse: Decodable, Sendable {
    let room: FounderRoom
    let messages: [FounderMessage]
    let nextCursor: String?
    let hasMore: Bool
}

struct FounderMessageCreateResponse: Decodable, Sendable {
    let message: FounderMessage
}

struct FounderMessageCreateRequest: Encodable, Sendable {
    let body: String
    let kind: FounderMessageKind
    let replyToId: String?
}

public struct FounderAdminMember: Decodable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let audience: FounderAudience
    public let role: String
    public let specialty: String?
    public let clientSlot: Int?
    public let sponsorName: String?
    public let removedAt: String?
}

public struct FounderAdminSummary: Decodable, Sendable {
    public let proSeatsUsed: Int
    public let proSeatsRemaining: Int
    public let activeClients: Int
    public let unansweredQuestions: Int
    public let openReports: Int
    public let reports: [FounderMessageReport]
    public let members: [FounderAdminMember]
}

public struct FounderMessageReport: Decodable, Sendable, Identifiable {
    public let id: String
    public let reason: FounderMessageReportReason
    public let details: String?
    public let createdAt: String
    public let message: FounderMessage
}

struct FounderAdminSummaryResponse: Decodable, Sendable {
    let summary: FounderAdminSummary
}

struct FounderProfessionalEnrollmentRequest: Encodable, Sendable {
    let audience = "PRO"
    let email: String
    let specialty: FounderSpecialty
}

struct FounderClientEnrollmentRequest: Encodable, Sendable {
    let audience = "CLIENT"
    let email: String
    let sponsorEmail: String
}

struct FounderEnrollmentResponse: Decodable, Sendable {
    let memberId: String
    let clientSlot: Int?
}

struct FounderReportRequest: Encodable, Sendable {
    let reason: FounderMessageReportReason
    let details: String?
}

struct FounderReportResponse: Decodable, Sendable {
    let reportId: String
}

struct FounderModerationRequest: Encodable, Sendable {
    let reportId: String
    let action: String
}

struct FounderModerationResponse: Decodable, Sendable {
    let resolved: Bool
}

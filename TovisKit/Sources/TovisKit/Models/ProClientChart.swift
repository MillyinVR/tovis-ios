import Foundation

// Wire model for the aggregate client chart — GET /api/v1/pro/clients/[id]/chart.
// Mirrors the inline shape built by the route (companion to the web `/pro/clients/[id]`
// server-render). Inline backend shape (decode-only). All instants are ISO-8601 UTC;
// money is a decimal string. See docs/PRO-BACKEND-CONTRACTS.md.

/// `GET /api/v1/pro/clients/[id]/chart` → the full chart (envelope `ok` ignored).
public struct ProClientChart: Decodable, Sendable {
    public let header: ProChartHeader
    public let alertBanner: String?
    public let doNotRebook: ProChartDoNotRebook?
    public let allergies: [ProChartAllergy]
    public let noteGroups: [ProChartNoteGroup]
    public let history: [ProChartBooking]
    public let products: [ProChartProduct]
    public let reviewsLeft: [ProChartReview]
    public let proFeedback: [ProChartFeedback]
    public let photos: [ProChartPhoto]
    /// Whether the founder-gated technical record (formulas/consents) is enabled.
    /// Its encrypted free text stays web-only; native shows the gate + a pointer.
    public let technicalEnabled: Bool
}

public struct ProChartHeader: Decodable, Sendable {
    public let id: String
    public let fullName: String
    public let email: String?
    public let phone: String?
    public let dateOfBirth: String?
    public let preferredContactMethod: String?
    public let occupation: String?
    public let socialHandle: String?
    public let accessUntil: String?
    public let bookingCount: Int
    public let reviewCount: Int
}

public struct ProChartDoNotRebook: Decodable, Sendable {
    public let reason: String?
    public let createdAt: String
}

public struct ProChartAllergy: Decodable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let severity: String
    public let description: String?
    public let recordedBy: String
    public let createdAt: String
}

public struct ProChartNoteGroup: Decodable, Sendable, Identifiable {
    public let kind: String
    public let label: String
    public let notes: [ProChartNote]
    public var id: String { kind }
}

public struct ProChartNote: Decodable, Sendable, Identifiable {
    public let id: String
    public let title: String?
    public let body: String
    public let createdAt: String
}

public struct ProChartBooking: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let scheduledFor: String
    public let timeZone: String?
    public let serviceName: String?
    public let categoryName: String?
    public let proName: String
    public let isMine: Bool
    public let total: String?
    public let aftercareNotes: String?
}

public struct ProChartProduct: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let brand: String?
    public let note: String?
}

public struct ProChartReview: Decodable, Sendable, Identifiable {
    public let id: String
    public let rating: Int
    public let headline: String?
    public let body: String?
    public let proName: String
    public let createdAt: String
}

public struct ProChartFeedback: Decodable, Sendable, Identifiable {
    public let id: String
    public let title: String?
    public let body: String
    public let proName: String
    public let createdAt: String
}

public struct ProChartPhoto: Decodable, Sendable, Identifiable {
    public let id: String
    public let bookingId: String?
    public let phase: String
    public let caption: String?
    public let isMine: Bool
    public let serviceName: String?
    public let when: String
    public let imageUrl: String
}

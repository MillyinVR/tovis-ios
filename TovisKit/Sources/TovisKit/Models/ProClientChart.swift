import Foundation

// Wire model for the aggregate client chart — GET /api/v1/pro/clients/[id]/chart.
// Mirrors the inline shape built by the route (companion to the web `/pro/clients/[id]`
// server-render). Inline backend shape (decode-only). All instants are ISO-8601 UTC;
// money is a decimal string. See docs/PRO-BACKEND-CONTRACTS.md.

/// `GET /api/v1/pro/clients/[id]/chart` → the full chart (envelope `ok` ignored).
public struct ProClientChart: Decodable, Sendable {
    public let header: ProChartHeader
    /// Derived "relationship intelligence" (LTV / cadence / lead time / pattern /
    /// rebooking / smart flags). Formatted server-side so this decodes and renders
    /// ready-made strings — the client carries no derivations of its own. Optional
    /// so a pre-deploy backend that predates the field still decodes (card hidden).
    public let relationshipIntelligence: ProChartRelationshipIntelligence?
    /// How many times this client has NOT shown up — across ALL professionals,
    /// by design. Scoped to the viewing pro it would read as "never" for someone
    /// who has stood up five others. Optional so a backend that predates web
    /// PR #1017 still decodes (the stat simply doesn't render).
    public let noShowCount: Int?
    public let alertBanner: String?
    public let doNotRebook: ProChartDoNotRebook?
    public let allergies: [ProChartAllergy]
    public let noteGroups: [ProChartNoteGroup]
    /// Every visit, newest first — each carrying its OWN before/after frames.
    /// The chart has ONE list of visits; there is no separate photo timeline.
    public let history: [ProChartBooking]
    public let products: [ProChartProduct]
    public let reviewsLeft: [ProChartReview]
    public let proFeedback: [ProChartFeedback]
    /// Whether the founder-gated technical record (formulas/consents) is enabled.
    /// Its encrypted free text stays web-only; native shows the gate + a pointer.
    public let technicalEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case header, relationshipIntelligence, noShowCount, alertBanner, doNotRebook
        case allergies, noteGroups, history, products, reviewsLeft, proFeedback
        case technicalEnabled
    }
}

/// The pro chart's relationship-intelligence zone, fully formatted by the backend
/// (`formatRelationshipIntelligence`). Each `Tile` is a rendered value + optional
/// sub-hint; every string is display-ready so web and native show identical copy.
public struct ProChartRelationshipIntelligence: Decodable, Sendable {
    public struct Tile: Decodable, Sendable {
        public let value: String
        public let hint: String?
    }

    public struct Flag: Decodable, Sendable, Identifiable {
        public let key: String
        public let label: String
        /// "warn" | "info" | "success" — mapped to a tone color at the view layer.
        public let tone: String
        public var id: String { key }
    }

    public let lifetimeValue: Tile
    public let visits: Tile
    public let cadence: Tile
    public let leadTime: Tile
    public let pattern: Tile
    public let rebooking: Tile
    public let preferredContactMethod: String?
    public let referralSource: String?
    public let flags: [Flag]
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
    /// The NR/NNR/RR/RNR mark (K5/K6). The server sends it ONLY on the viewing
    /// pro's own rows — the mark answers "did this client request ME", so on
    /// another pro's booking it would misread — so this is nil whenever
    /// `isMine` is false, by construction rather than by the view remembering.
    public let relationshipBadge: ProRelationshipBadge?
    public let total: String?
    /// Booked length in minutes. The web card prints "90 min • $180" as one
    /// line; optional so a backend that predates the field still decodes and the
    /// card simply shows the money half.
    public let durationMinutes: Int?
    public let aftercareNotes: String?
    /// This visit's own before/after frames, BEFORE-first — the SAME rows and the
    /// same order the web chart renders on its card for this booking. Empty when
    /// the visit has no frames this pro is allowed to see.
    ///
    /// The server groups these; the device never re-derives them from a flat
    /// list, so "which visit is this frame from" has exactly one answer.
    public let photos: [ProChartPhoto]

    private enum CodingKeys: String, CodingKey {
        case id, status, scheduledFor, timeZone, serviceName, categoryName
        case proName, isMine, relationshipBadge, total, durationMinutes
        case aftercareNotes, photos
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        status = try c.decode(String.self, forKey: .status)
        scheduledFor = try c.decode(String.self, forKey: .scheduledFor)
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone)
        serviceName = try c.decodeIfPresent(String.self, forKey: .serviceName)
        categoryName = try c.decodeIfPresent(String.self, forKey: .categoryName)
        proName = try c.decode(String.self, forKey: .proName)
        isMine = try c.decode(Bool.self, forKey: .isMine)
        relationshipBadge = try c.decodeIfPresent(ProRelationshipBadge.self, forKey: .relationshipBadge)
        total = try c.decodeIfPresent(String.self, forKey: .total)
        durationMinutes = try c.decodeIfPresent(Int.self, forKey: .durationMinutes)
        aftercareNotes = try c.decodeIfPresent(String.self, forKey: .aftercareNotes)
        // A backend that predates web PR #1017 sends no `photos` on a visit; the
        // card then simply has no frames rather than failing the whole chart.
        photos = try c.decodeIfPresent([ProChartPhoto].self, forKey: .photos) ?? []
    }
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

import Foundation

// Wire models for the PRO clients surface — GET /api/v1/pro/clients/search,
// GET /pro/clients/{id}/service-addresses, POST /pro/clients/{id}/notes.
// Inline backend shapes (decode-only). The full client CHART history (existing
// notes/allergies/formula) is server-rendered with no read API — needs a backend
// aggregate GET before it can be ported. See docs/PRO-BACKEND-CONTRACTS.md.

/// GET /api/v1/pro/clients/search → recent + other matches.
public struct ProClientSearchResponse: Decodable, Sendable {
    public let query: String?
    public let recentClients: [ProClientSummary]
    public let otherClients: [ProClientSummary]
}

public struct ProClientSummary: Decodable, Sendable, Identifiable {
    public let id: String
    public let fullName: String
    /// Whether the pro is currently allowed to open this client's chart.
    public let canViewClient: Bool
    public let email: String?
    public let phone: String?
}

/// GET /api/v1/pro/clients/{id}/service-addresses.
public struct ProClientAddressesResponse: Decodable, Sendable {
    public let clientId: String
    public let addresses: [ProClientAddress]
}

public struct ProClientAddress: Decodable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let formattedAddress: String
    public let isDefault: Bool
}

/// POST /api/v1/pro/clients/{id}/notes body.
struct ProClientNoteRequest: Encodable {
    let title: String?
    let body: String
    let kind: String
}

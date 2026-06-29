import Foundation

// Wire models for the PRO clients surface — GET /api/v1/pro/clients (directory),
// GET /api/v1/pro/clients/search, GET /pro/clients/{id}/service-addresses,
// POST /pro/clients/{id}/notes. Inline backend shapes (decode-only). See
// docs/PRO-BACKEND-CONTRACTS.md.

/// GET /api/v1/pro/clients → the visible client directory (web `/pro/clients`
/// parity). The native list loads this and filters client-side (the web page
/// has no server search either).
public struct ProClientDirectoryResponse: Decodable, Sendable {
    public let clients: [ProClientSummary]
    public let count: Int
}

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
    /// "Last booking: …" / "No bookings yet" — present on the directory list,
    /// absent on search results.
    public let lastBookingLabel: String?

    public init(
        id: String,
        fullName: String,
        canViewClient: Bool,
        email: String?,
        phone: String?,
        lastBookingLabel: String? = nil
    ) {
        self.id = id
        self.fullName = fullName
        self.canViewClient = canViewClient
        self.email = email
        self.phone = phone
        self.lastBookingLabel = lastBookingLabel
    }
}

/// POST /api/v1/pro/clients — create-shadow-client body.
struct ProClientCreateRequest: Encodable {
    let firstName: String
    let lastName: String
    let email: String
    let phone: String?
}

/// POST /api/v1/pro/clients → `{ ok, id, clientId, userId, email }`.
public struct ProClientCreated: Decodable, Sendable {
    public let id: String
    public let clientId: String?
    public let email: String?
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

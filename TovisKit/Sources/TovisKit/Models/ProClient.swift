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

// MARK: - Chart write forms (per-tab edits on the pro client chart)
//
// The web `/pro/clients/[id]` chart edits these via sibling forms; the routes all
// already exist, so the native port is client-only. Free text (allergy label/
// description, occupation) is encrypted server-side — the client sends plaintext.

/// POST /api/v1/pro/clients/{id}/allergies body. `severity` ∈
/// LOW | MODERATE | HIGH | CRITICAL (the route also accepts MILD/SEVERE aliases).
struct ProClientAllergyRequest: Encodable {
    let label: String
    let description: String?
    let severity: String
}

/// PATCH /api/v1/pro/clients/{id}/alert body. An empty string clears the banner
/// (the route treats blank as null).
struct ProClientAlertRequest: Encodable {
    let alertBanner: String
}

/// PUT /api/v1/pro/clients/{id}/do-not-rebook body. `reason` may be empty.
struct ProClientDoNotRebookRequest: Encodable {
    let reason: String
}

/// PATCH /api/v1/pro/clients/{id}/profile-context body. An empty string clears the
/// corresponding field; the route strips a leading `@` from the handle.
struct ProClientProfileContextRequest: Encodable {
    let occupation: String
    let proCapturedSocialHandle: String
}

// MARK: - Technical record write forms (formula · consent · photo-release)
//
// Increment 2 of the pro private-client-view parity. The web routes already exist
// and 404 unless the founder technical-record flag is on. Free text (formula
// result notes, consent notes) is encrypted server-side — the client sends
// plaintext. Dates are ISO-8601 strings.

/// POST /api/v1/pro/clients/{id}/formula body. At least one detail is required;
/// `resultNotes` is encrypted server-side and `processingTimeMinutes` is clamped
/// 1…1440 by the route. `bookingId` optionally ties the entry to a visit.
struct ProClientFormulaRequest: Encodable {
    let brand: String?
    let developer: String?
    let ratio: String?
    let processingTimeMinutes: Int?
    let resultNotes: String?
    let bookingId: String?
}

/// POST /api/v1/pro/clients/{id}/consent body. `kind` ∈ GENERAL_CONSENT |
/// SERVICE_WAIVER | PATCH_TEST. The patch-test result + validity are only
/// meaningful for PATCH_TEST (the route nulls them otherwise). `notes` is
/// encrypted server-side.
struct ProClientConsentRequest: Encodable {
    let kind: String
    let serviceScope: String?
    let proofMethod: String?
    let proofRef: String?
    let signedAt: String?
    let notes: String?
    let patchTestResult: String?
    let validUntil: String?
    let bookingId: String?
}

/// PATCH /api/v1/pro/clients/{id}/photo-release body. `status` ∈ NOT_SET | GRANTED
/// | DECLINED (NOT_SET clears the standing release).
struct ProClientPhotoReleaseRequest: Encodable {
    let status: String
}

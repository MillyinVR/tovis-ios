import Foundation

// Wire models for the founder-gated client TECHNICAL RECORD (PR4) — decode-only.
// GET /api/v1/pro/clients/{id}/technical. Loaded lazily when the technical tab
// opens (mirrors the web page), so the server-decrypted encrypted free text stays
// off the always-fetched chart aggregate. Formula is author-only; consent is
// `full` for the authoring pro / `safety` for another pro's patch test (proof +
// notes redacted, only result/validity + `byName` travel). See
// docs/PRO-BACKEND-CONTRACTS.md.

/// GET /api/v1/pro/clients/{id}/technical → the technical record. 404s when the
/// founder flag is off.
public struct ProClientTechnicalRecord: Decodable, Sendable {
    public let formula: [ProFormulaEntry]
    public let consents: [ProConsentRecord]
    /// NOT_SET | GRANTED | DECLINED — the client's standing photo-release decision.
    public let photoReleaseStatus: String
}

/// One formula entry (author-only, never public).
public struct ProFormulaEntry: Decodable, Sendable, Identifiable {
    public let id: String
    /// The visit date (booking) or the entry's creation time, ISO-8601.
    public let when: String?
    public let timeZone: String?
    public let serviceName: String?
    public let brand: String?
    public let developer: String?
    public let ratio: String?
    public let processingTimeMinutes: Int?
    /// Decrypted result notes — always the authoring pro's own entries.
    public let resultNotes: String?
}

/// One consent / waiver / patch-test record, already scope-redacted server-side.
public struct ProConsentRecord: Decodable, Sendable, Identifiable {
    public let id: String
    /// "full" (authoring pro) | "safety" (another pro's patch test).
    public let scope: String
    /// GENERAL_CONSENT | SERVICE_WAIVER | PATCH_TEST.
    public let kind: String
    public let when: String?
    public let timeZone: String?
    public let serviceScope: String?
    public let signedAt: String?
    public let proofMethod: String?
    public let proofRef: String?
    /// PASS | FAIL | INCONCLUSIVE (patch tests). Travels under both scopes.
    public let patchTestResult: String?
    public let validUntil: String?
    /// Decrypted notes — full scope only; null under safety scope.
    public let notes: String?
    /// The other pro's display name — present only under safety scope.
    public let byName: String?
}

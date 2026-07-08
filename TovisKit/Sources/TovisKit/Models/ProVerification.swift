import Foundation

// Wire models for the pro license / document verification screen. Mirrors the web
// GET /api/v1/pro/verification response (app/api/v1/pro/verification/route.ts) +
// the copy SSOT lib/pro/verification/methods.ts. The mutations reuse existing
// endpoints: license edit (PATCH /pro/license), doc upload (POST /pro/uploads →
// POST /pro/verification-docs), doc delete (DELETE /pro/verification-docs/{id}).

/// Verification status. String-backed with an `.unknown` fallback (same tactic as
/// `Role` / `ProReadinessBlocker`) so a value the app doesn't know yet never fails
/// to decode. Matches Prisma `VerificationStatus`.
public enum ProVerificationStatus: String, Decodable, Sendable, Equatable {
    case pending = "PENDING"
    case pendingManualReview = "PENDING_MANUAL_REVIEW"
    case approved = "APPROVED"
    case rejected = "REJECTED"
    case needsInfo = "NEEDS_INFO"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProVerificationStatus(rawValue: raw) ?? .unknown
    }

    /// Friendly label for the status badge (the web page shows the raw enum; the
    /// native screen humanizes it).
    public var label: String {
        switch self {
        case .pending: return "Pending review"
        case .pendingManualReview: return "Manual review"
        case .approved: return "Approved"
        case .rejected: return "Rejected"
        case .needsInfo: return "Needs info"
        case .unknown: return "Unknown"
        }
    }
}

/// One accepted upload method for the pro's profession — from
/// `verificationMethodsForProfession`. `type` is the raw `VerificationDocumentType`
/// (server SSOT) and is echoed back verbatim on upload.
public struct ProVerificationMethod: Decodable, Sendable, Identifiable, Equatable {
    public let type: String
    public let title: String
    public let description: String
    public var id: String { type }
}

/// A submitted verification document row. `typeLabel` is the server-resolved
/// human label (`verificationDocTypeLabel`); `createdAt` is an ISO-8601 instant.
public struct ProVerificationDoc: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let type: String
    public let typeLabel: String
    public let status: ProVerificationStatus
    public let label: String?
    public let createdAt: String
    public let adminNote: String?
}

/// The pro's license fields. All optional — a non-licensed profession (e.g.
/// makeup) has none. `expiry` is a calendar date "YYYY-MM-DD" (or nil).
public struct ProVerificationLicense: Decodable, Sendable, Equatable {
    public let state: String?
    public let number: String?
    public let expiry: String?
}

/// The full verification snapshot backing the native screen.
public struct ProVerification: Decodable, Sendable, Equatable {
    /// Account-level verification status (drives the badge).
    public let status: ProVerificationStatus
    /// Whether an admin has verified the license.
    public let licenseVerified: Bool
    /// Whether this profession requires a state license (drives whether the
    /// license edit form shows). `false` → "Your certifications" upload only.
    public let isLicensed: Bool
    public let license: ProVerificationLicense
    public let methods: [ProVerificationMethod]
    public let docs: [ProVerificationDoc]
}

/// Envelope for GET /api/v1/pro/verification (`jsonOk({ verification })`).
struct ProVerificationResponse: Decodable, Sendable {
    let verification: ProVerification
}

// MARK: - Request bodies

/// PATCH /api/v1/pro/license — self-edit. `licenseExpiry` is "YYYY-MM-DD" or ""
/// to clear it.
struct VerificationLicenseSaveRequest: Encodable, Sendable {
    let licenseState: String
    let licenseNumber: String
    let licenseExpiry: String
}

/// POST /api/v1/pro/uploads — presign a private verification-doc upload.
/// `kind` is `VERIFY_PRIVATE` (→ media-private bucket, no UploadSession).
struct VerificationUploadInitRequest: Encodable, Sendable {
    let kind: String
    let contentType: String
    let size: Int
}

/// POST /api/v1/pro/uploads → presign target for a `VERIFY_PRIVATE` upload. Unlike
/// the media pipeline this kind has no UploadSession (uploadSessionId is null), so
/// we only model the storage pointer we PUT to.
struct VerificationUploadInit: Decodable, Sendable {
    let bucket: String
    let path: String
    let token: String
}

/// POST /api/v1/pro/verification-docs — record the uploaded doc. `url` is the
/// `supabase://bucket/path` pointer the presign returned.
struct VerificationDocCreateRequest: Encodable, Sendable {
    let type: String
    let label: String
    let url: String
}

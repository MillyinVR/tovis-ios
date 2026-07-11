import Foundation

// Wire models for the pro migration wizard's **clients import** step (increment 2)
// — the native counterpart of the web `/pro/migrate/clients` flow
// (MigrateClientsClient.tsx): pick a CSV → map columns → preview the dedupe →
// commit. Both surfaces POST to existing routes with no DTO/zod on the web side
// (the contract lives as plain types in `tovis-app/lib/migration/clientImport.ts`
// + `clientImportServer.ts`), so these Swift shapes hand-mirror those types:
//   • POST /api/v1/pro/migrate/clients/preview  { rows, mapping } → { rows, summary }
//   • POST /api/v1/pro/migrate/clients/commit    { rows, mapping, excludeIndices } → { rows, summary }
// Both 404 while ENABLE_PRO_MIGRATION is off (same build-dark gate as the entry
// summary route). Import is silent — upsertProClient never messages a client.

// MARK: - Column mapping

/// A logical import field, mapped to the CSV header the pro picked for it. Mirrors
/// the web `ClientImportField` union + `FIELD_ORDER`/`REQUIRED_FIELDS`.
public enum ClientImportField: String, CaseIterable, Sendable {
    case firstName
    case lastName
    case email
    case phone

    /// firstName + lastName are mandatory (the server 400s without them); email +
    /// phone are optional but a row needs at least one to be importable.
    public var isRequired: Bool { self == .firstName || self == .lastName }

    /// Human label — matches the web copy `fields` map.
    public var label: String {
        switch self {
        case .firstName: return "First name"
        case .lastName: return "Last name"
        case .email: return "Email"
        case .phone: return "Phone"
        }
    }
}

/// The `mapping` request field: each logical field → chosen CSV header name.
/// firstName/lastName are required; email/phone are `encodeIfPresent` (omitted
/// when unmapped, exactly like the web deletes unmapped optional keys).
public struct ClientImportMapping: Encodable, Sendable, Equatable {
    public let firstName: String
    public let lastName: String
    public let email: String?
    public let phone: String?

    public init(firstName: String, lastName: String, email: String? = nil, phone: String? = nil) {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phone = phone
    }

    /// Build from a per-field header selection (the mapping-step UI state). Returns
    /// nil until both required fields are chosen — the "Continue" gate. Empty
    /// selections drop out so they encode as omitted, not blank.
    public init?(selection: [ClientImportField: String]) {
        func pick(_ field: ClientImportField) -> String? {
            guard let header = selection[field], !header.isEmpty else { return nil }
            return header
        }
        guard let firstName = pick(.firstName), let lastName = pick(.lastName) else { return nil }
        self.init(firstName: firstName, lastName: lastName, email: pick(.email), phone: pick(.phone))
    }
}

/// Auto-guess a column mapping from the CSV headers by case-insensitive substring
/// — a 1:1 port of the web `guessMapping` (MigrateClientsClient.tsx). First match
/// wins per field; the pro can override every choice in the mapping step.
public func guessClientImportMapping(headers: [String]) -> [ClientImportField: String] {
    let hints: [ClientImportField: [String]] = [
        .firstName: ["first"],
        .lastName: ["last", "surname"],
        .email: ["email", "e-mail"],
        .phone: ["phone", "mobile", "cell"],
    ]
    var mapping: [ClientImportField: String] = [:]
    for field in ClientImportField.allCases {
        guard let needles = hints[field] else { continue }
        if let match = headers.first(where: { header in
            let lower = header.lowercased()
            return needles.contains { lower.contains($0) }
        }) {
            mapping[field] = match
        }
    }
    return mapping
}

// MARK: - Request body

/// The POST body for both preview and commit. `excludeIndices` is
/// `encodeIfPresent` — nil for preview (which ignores it) and the excluded set
/// for commit, matching the web's two fetch bodies.
struct ClientImportRequestBody: Encodable {
    let rows: [[String: String]]
    let mapping: ClientImportMapping
    let excludeIndices: [Int]?
}

// MARK: - Preview response

/// How a row lines up against the pro's existing book (`ClientPreviewMatch`).
/// Kept as the raw string on the model (tolerant of unknown values, like
/// `ProMigrationRaise.stepMode`); `kind` derives the enum for the UI.
public enum ClientImportMatch: String, Sendable {
    case new = "NEW"
    case existing = "EXISTING"
    case missingInfo = "MISSING_INFO"
}

/// One evaluated preview row (`ClientImportPreviewRow`). `index` is the row's
/// zero-based position in the submitted `rows` array — the same index commit uses
/// for `excludeIndices` and reports back, so it must round-trip unchanged.
public struct ClientImportPreviewRow: Decodable, Sendable, Identifiable, Equatable {
    public let index: Int
    public let firstName: String
    public let lastName: String
    public let email: String?
    public let phone: String?
    public let match: String
    public let issues: [String]
    public let importable: Bool

    public var id: Int { index }

    public var kind: ClientImportMatch? { ClientImportMatch(rawValue: match) }

    /// "First Last", trimmed; falls back to a placeholder if both are blank.
    public var displayName: String {
        let name = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Unnamed contact" : name
    }

    /// The contact line the preview card shows — email preferred, else phone, else
    /// nil (the card then reads "No contact info", matching web `copy.noContact`).
    public var contactLine: String? {
        if let email, !email.isEmpty { return email }
        if let phone, !phone.isEmpty { return phone }
        return nil
    }
}

/// Preview totals (`ClientImportPreview.summary`). `new` is remapped to `newCount`
/// to read clearly at call sites.
public struct ClientImportPreviewSummary: Decodable, Sendable, Equatable {
    public let total: Int
    public let importable: Int
    public let existing: Int
    public let newCount: Int
    public let needsAttention: Int

    enum CodingKeys: String, CodingKey {
        case total, importable, existing
        case newCount = "new"
        case needsAttention
    }
}

/// `POST /pro/migrate/clients/preview` envelope (the `ok:true` field is ignored by
/// `Decodable`).
public struct ClientImportPreviewResponse: Decodable, Sendable {
    public let rows: [ClientImportPreviewRow]
    public let summary: ClientImportPreviewSummary
}

// MARK: - Commit response

/// One committed row's outcome (`ClientCommitRowResult`) — a discriminated union
/// on `ok` on the wire, flattened here with optional success/failure fields.
public struct ClientImportCommitRow: Decodable, Sendable, Identifiable, Equatable {
    public let index: Int
    public let ok: Bool
    public let clientId: String?
    public let error: String?
    public let code: String?

    public var id: Int { index }
}

/// Commit tally (`ClientImportCommitResult.summary`): rows sent to upsert
/// (`attempted`) split into `imported`/`failed`, plus `skipped` (non-importable or
/// excluded).
public struct ClientImportCommitSummary: Decodable, Sendable, Equatable {
    public let attempted: Int
    public let imported: Int
    public let failed: Int
    public let skipped: Int
}

/// `POST /pro/migrate/clients/commit` envelope.
public struct ClientImportCommitResponse: Decodable, Sendable {
    public let rows: [ClientImportCommitRow]
    public let summary: ClientImportCommitSummary
}

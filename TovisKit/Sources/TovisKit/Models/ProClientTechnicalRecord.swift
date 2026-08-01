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
    /// K14 — the pro's ACTIVE consent forms, each resolved to the version that
    /// would be signed today. This is what lets the native record sheet offer the
    /// same choices web does; empty is a legitimate answer (a pro who has
    /// authored no forms), so a surface reads emptiness as "none", never as
    /// "failed".
    public let consentForms: [ProConsentFormOption]

    private enum CodingKeys: String, CodingKey {
        case formula, consents, photoReleaseStatus, consentForms
    }

    /// 🔴 Hand-written for ONE reason: the three original fields keep decoding
    /// exactly as they did (an unreadable formula or consent list still surfaces
    /// as a failed load, because a technical record that silently drops half a
    /// client's history is worse than one that says it broke), while the K14
    /// addition CANNOT take the screen down with it. `consentForms` is a
    /// convenience for a picker; arriving malformed it must cost the pro that
    /// picker and nothing else (the K9 lesson, applied at the one seam where the
    /// blast radii genuinely differ).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formula = try container.decode([ProFormulaEntry].self, forKey: .formula)
        consents = try container.decode([ProConsentRecord].self, forKey: .consents)
        photoReleaseStatus = try container.decode(String.self, forKey: .photoReleaseStatus)
        consentForms =
            ((try? container.decodeIfPresent([ProConsentFormOption].self, forKey: .consentForms)) ?? nil) ?? []
    }

    public init(
        formula: [ProFormulaEntry],
        consents: [ProConsentRecord],
        photoReleaseStatus: String,
        consentForms: [ProConsentFormOption] = []
    ) {
        self.formula = formula
        self.consents = consents
        self.photoReleaseStatus = photoReleaseStatus
        self.consentForms = consentForms
    }
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
    /// K14 — the exact form text this record attests to, resolved as it was
    /// signed. Null on every pre-K14 record (free text, still readable), on any
    /// record whose pro attached no form, and on every safety-scoped row: the
    /// signed text is part of the artifact and travels with the proof fields, so
    /// a patch test's safety fields reaching another pro never carry the waiver
    /// text with them.
    ///
    /// Decoding it cannot throw (see `ProConsentFormVersion`), so this stays on
    /// synthesized decode — the surrounding `consents` array is unchanged.
    public let formVersion: ProConsentFormVersion?
}

/// K14 — the immutable form version a consent record attests to.
///
/// 🔴 The point of the whole feature is that this is a SNAPSHOT: the text is
/// stored as it was signed and the database refuses to rewrite it (#809). So the
/// device renders these words verbatim and never reconstructs them from the
/// pro's current form — a pro who edits their waiver must not thereby change
/// what a client already agreed to.
///
/// Decoding is non-throwing: it hangs off a `ProConsentRecord` inside the
/// `consents` array, and one malformed attestation must not blank a client's
/// entire consent history.
public struct ProConsentFormVersion: Decodable, Sendable, Equatable {
    public let id: String?
    /// The version number as signed — 3 means "v3", not "the 3rd form".
    public let version: Int?
    public let title: String?
    /// The full signed text. Long; a surface discloses it rather than inlining it.
    public let body: String?
    /// Server-composed provenance ("Tovis template, unmodified" / "Your own
    /// wording"). Rendered verbatim — never re-derived here, because the rule
    /// that decides it lives in one place on the server.
    public let originLabel: String?

    private enum CodingKeys: String, CodingKey {
        case id, version, title, body, originLabel
    }

    public init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        id = (try? container?.decodeIfPresent(String.self, forKey: .id)) ?? nil
        version = (try? container?.decodeIfPresent(Int.self, forKey: .version)) ?? nil
        title = (try? container?.decodeIfPresent(String.self, forKey: .title)) ?? nil
        body = (try? container?.decodeIfPresent(String.self, forKey: .body)) ?? nil
        originLabel = (try? container?.decodeIfPresent(String.self, forKey: .originLabel)) ?? nil
    }

    public init(id: String?, version: Int?, title: String?, body: String?, originLabel: String?) {
        self.id = id
        self.version = version
        self.title = title
        self.body = body
        self.originLabel = originLabel
    }

    /// The attestation a surface may render, or nil to show nothing.
    ///
    /// A title and a version are the minimum that makes this truthful — "this
    /// record attests to v3 of Corrective colour waiver" is the whole claim, and
    /// half of it is not a weaker claim but a different one. `body` and
    /// `originLabel` are genuinely optional: without them the pro loses the
    /// ability to read the text back, not the knowledge that a version exists.
    public var display: Display? {
        guard let version else { return nil }
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        let text = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = originLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Display(
            title: title,
            version: version,
            body: (text?.isEmpty ?? true) ? nil : text,
            originLabel: (origin?.isEmpty ?? true) ? nil : origin
        )
    }

    /// A validated, renderable attestation.
    public struct Display: Sendable, Equatable {
        public let title: String
        public let version: Int
        public let body: String?
        public let originLabel: String?

        /// What the record card prints beside the proof line: which form, which
        /// version. The version is the part a pro cannot infer from anywhere
        /// else on screen.
        public var summary: String { "\(title) · v\(version)" }
    }
}

/// K14 — one of the pro's ACTIVE consent forms, resolved to the version that
/// would be signed today. The choices a record-entry surface offers.
///
/// Retired forms are absent by design: a form a pro has stopped using should not
/// keep being attached to NEW records, while records already pointing at it keep
/// resolving their own version.
public struct ProConsentFormOption: Decodable, Sendable, Equatable, Identifiable {
    /// Every consent kind the server stores today. A form arriving with a kind
    /// outside this set is one this build cannot label, and `display` drops it
    /// rather than printing a raw enum at a pro.
    public enum Kind: String, Sendable, CaseIterable {
        case generalConsent = "GENERAL_CONSENT"
        case serviceWaiver = "SERVICE_WAIVER"
        case patchTest = "PATCH_TEST"
    }

    /// DERIVED from `Kind`, never hand-listed beside it (the K11/K13 rule).
    public static let knownKinds: Set<String> = Set(Kind.allCases.map(\.rawValue))

    public let formId: String?
    /// The version row that would be signed today — NOT the form id. A record is
    /// pinned to this, which is why the two ids travel separately.
    public let versionId: String?
    public let version: Int?
    public let kind: String?
    public let title: String?

    /// `Identifiable` needs a key that cannot trap; a row without one never
    /// reaches a list (see `display`).
    public var id: String { formId ?? versionId ?? title ?? "" }

    private enum CodingKeys: String, CodingKey {
        case formId, versionId, version, kind, title
    }

    public init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        formId = (try? container?.decodeIfPresent(String.self, forKey: .formId)) ?? nil
        versionId = (try? container?.decodeIfPresent(String.self, forKey: .versionId)) ?? nil
        version = (try? container?.decodeIfPresent(Int.self, forKey: .version)) ?? nil
        kind = (try? container?.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        title = (try? container?.decodeIfPresent(String.self, forKey: .title)) ?? nil
    }

    public init(formId: String?, versionId: String?, version: Int?, kind: String?, title: String?) {
        self.formId = formId
        self.versionId = versionId
        self.version = version
        self.kind = kind
        self.title = title
    }

    /// The option a picker may offer, or nil to drop it.
    ///
    /// A form the pro can choose needs an id to send, a name to show and a kind
    /// this build can label. `version` completes the name — two forms can share
    /// a title across versions and the pro is choosing between artifacts.
    public var display: Display? {
        guard let formId = formId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !formId.isEmpty else { return nil }
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        guard let kind, let known = Kind(rawValue: kind) else { return nil }
        guard let version else { return nil }
        return Display(formId: formId, versionId: versionId, version: version, kind: known, title: title)
    }

    /// A validated, offerable option.
    public struct Display: Sendable, Equatable, Identifiable {
        public let formId: String
        public let versionId: String?
        public let version: Int
        public let kind: Kind
        public let title: String

        public var id: String { formId }

        /// What a picker row prints: the form, then the version it would pin.
        public var label: String { "\(title) · v\(version)" }
    }
}

public extension Array where Element == ProConsentFormOption {
    /// The options worth offering, in wire order (the server orders by creation,
    /// which is the order the pro authored them in).
    var offerable: [ProConsentFormOption.Display] {
        compactMap(\.display)
    }
}

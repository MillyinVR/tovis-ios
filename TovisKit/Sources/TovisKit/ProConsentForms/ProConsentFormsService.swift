import Foundation

/// PRO workspace — the pro's consent form LIBRARY: write a waiver, adopt a
/// platform template, publish a revision, retire one they no longer use.
///
/// Every call here 404s while the technical-record gate is off for this pro —
/// deliberately the same gate as the chart tab these forms attach to, never a
/// second switch. Ask `ProSettingsService.capabilities()` first and hide the
/// entry point rather than navigating a pro into that 404.
///
/// 🔴 There is no "edit". A form's text lives on append-only versions, so
/// changing the words is `publishVersion`, which creates version n+1 and leaves
/// every earlier version exactly as it was. That is the whole model: a client
/// who signed v1 agreed to v1's words, and nothing in this service may rewrite
/// that. The only mutable thing about a form is whether it is still in use.
public final class ProConsentFormsService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/consent-forms → the pro's own forms plus the platform
    /// templates on offer, and the title/body limits the write routes enforce.
    ///
    /// Throws `APIError.server(404, …)` while the gate is off. An EMPTY library
    /// is a different answer and arrives as a 200 with empty arrays — a surface
    /// must not read one as the other.
    public func library() async throws -> ProConsentFormLibrary {
        try await api.request("/pro/consent-forms")
    }

    /// POST /api/v1/pro/consent-forms → a new form of the pro's own, published
    /// as v1 in the same transaction (a form with no text has nothing to sign).
    ///
    /// The server canonicalizes the text — line endings normalized, surrounding
    /// blank lines dropped, the title flattened to one line — and REFUSES rather
    /// than truncating past the limits, so pass what the pro typed.
    public func create(kind: String, title: String, body: String) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProConsentFormCreateRequest(kind: kind, title: title, body: body)
        )
        try await api.requestVoid("/pro/consent-forms", method: .post, body: payload)
    }

    /// POST /api/v1/pro/consent-forms with `sourceTemplateId` → adopt a platform
    /// template as a form of the pro's OWN, carrying the template's current text
    /// verbatim and remembering which template version it came from.
    ///
    /// Copying rather than referencing is what lets the pro edit it afterwards
    /// without touching the platform's words; the provenance it keeps is what
    /// makes "edited" distinguishable from "adopted as-is" on every surface.
    ///
    /// Refuses a template already adopted (409) — offer it only while
    /// `ProConsentFormTemplate.adopted` is false.
    public func adoptTemplate(templateId: String) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProConsentFormAdoptRequest(sourceTemplateId: templateId)
        )
        try await api.requestVoid("/pro/consent-forms", method: .post, body: payload)
    }

    /// POST /api/v1/pro/consent-forms/{id}/versions → publish version n+1.
    ///
    /// This is what "editing a form" means. Every earlier version is untouched,
    /// and every record already signed keeps resolving its own.
    ///
    /// Refuses text identical to the current version (409, "Nothing changed") —
    /// publishing it would grow the history without changing anything a client
    /// could read.
    public func publishVersion(formId: String, title: String, body: String) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProConsentFormVersionRequest(title: title, body: body)
        )
        try await api.requestVoid(
            "/pro/consent-forms/\(formId)/versions", method: .post, body: payload
        )
    }

    /// PATCH /api/v1/pro/consent-forms/{id} → retire a form, or put it back.
    ///
    /// The ONLY mutable thing about a form. Retiring touches no history: records
    /// signed against it keep resolving their version, and the form simply stops
    /// being offered when a new record is written.
    public func setActive(formId: String, isActive: Bool) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProConsentFormActiveRequest(isActive: isActive)
        )
        try await api.requestVoid(
            "/pro/consent-forms/\(formId)", method: .patch, body: payload
        )
    }
}

// MARK: - Request bodies

struct ProConsentFormCreateRequest: Encodable, Sendable {
    let kind: String
    let title: String
    let body: String
}

struct ProConsentFormAdoptRequest: Encodable, Sendable {
    let sourceTemplateId: String
}

struct ProConsentFormVersionRequest: Encodable, Sendable {
    let title: String
    let body: String
}

struct ProConsentFormActiveRequest: Encodable, Sendable {
    let isActive: Bool
}

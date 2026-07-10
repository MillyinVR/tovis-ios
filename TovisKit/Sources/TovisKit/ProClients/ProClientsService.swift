import Foundation

/// PRO workspace — the clients directory (web `/pro/clients`). Search the pro's
/// clients, read a client's service addresses, and append a chart note. The full
/// chart HISTORY (existing notes/allergies/formula) is server-rendered with no
/// read API — porting it needs a backend aggregate GET first. Authenticated;
/// PRO-only + per-client visibility. See docs/PRO-BACKEND-CONTRACTS.md.
public final class ProClientsService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/clients → the visible client directory (web `/pro/clients`
    /// parity). Returns every client the pro currently has access to, ordered by
    /// name, with a per-client "Last booking: …" label. The view filters this
    /// client-side; the web page has no server search.
    public func directory() async throws -> ProClientDirectoryResponse {
        try await api.request("/pro/clients")
    }

    /// GET /api/v1/pro/clients/search?q= → recent + other matches.
    public func search(query: String = "") async throws -> ProClientSearchResponse {
        let q = query.trimmingCharacters(in: .whitespaces)
        let items = q.isEmpty ? nil : [URLQueryItem(name: "q", value: q)]
        return try await api.request("/pro/clients/search", query: items)
    }

    /// POST /api/v1/pro/clients — add a shadow client. Returns the created
    /// client/user ids. `phone` is optional.
    @discardableResult
    public func createClient(
        firstName: String,
        lastName: String,
        email: String,
        phone: String?
    ) async throws -> ProClientCreated {
        let payload = try JSONEncoder.canonical.encode(
            ProClientCreateRequest(firstName: firstName, lastName: lastName, email: email, phone: phone)
        )
        return try await api.request("/pro/clients", method: .post, body: payload)
    }

    /// GET /api/v1/pro/clients/{id}/chart → the aggregate client chart (header +
    /// safety strip + allergies + notes + history + products + reviews + feedback +
    /// photos + technical gate). 404 when the pro can't currently view the client.
    public func chart(clientId: String) async throws -> ProClientChart {
        try await api.request("/pro/clients/\(clientId)/chart")
    }

    /// GET /api/v1/pro/clients/{id}/service-addresses.
    public func serviceAddresses(clientId: String) async throws -> [ProClientAddress] {
        let response: ProClientAddressesResponse =
            try await api.request("/pro/clients/\(clientId)/service-addresses")
        return response.addresses
    }

    /// POST /api/v1/pro/clients/{id}/notes — append a chart note. `kind` is
    /// "GENERAL" | "CONSULTATION" | "COMMUNICATION_STYLE".
    public func addNote(
        clientId: String,
        body: String,
        title: String? = nil,
        kind: String = "GENERAL"
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProClientNoteRequest(title: title, body: body, kind: kind)
        )
        try await api.requestVoid(
            "/pro/clients/\(clientId)/notes", method: .post, body: payload
        )
    }

    // MARK: - Chart write forms (per-tab edits)

    /// POST /api/v1/pro/clients/{id}/allergies — record an allergy/sensitivity on
    /// the safety strip. `severity` ∈ LOW | MODERATE | HIGH | CRITICAL. The label
    /// and description are encrypted server-side.
    public func addAllergy(
        clientId: String,
        label: String,
        description: String?,
        severity: String
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProClientAllergyRequest(label: label, description: description, severity: severity)
        )
        try await api.requestVoid(
            "/pro/clients/\(clientId)/allergies", method: .post, body: payload
        )
    }

    /// PATCH /api/v1/pro/clients/{id}/alert — set the pinned safety alert banner.
    /// An empty string clears it.
    public func updateAlertBanner(clientId: String, alertBanner: String) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProClientAlertRequest(alertBanner: alertBanner)
        )
        try await api.requestVoid(
            "/pro/clients/\(clientId)/alert", method: .patch, body: payload
        )
    }

    /// PUT /api/v1/pro/clients/{id}/do-not-rebook — flag the client do-not-rebook
    /// (author-scoped; never shown to other pros or the client). `reason` may be
    /// empty.
    public func setDoNotRebook(clientId: String, reason: String) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProClientDoNotRebookRequest(reason: reason)
        )
        try await api.requestVoid(
            "/pro/clients/\(clientId)/do-not-rebook", method: .put, body: payload
        )
    }

    /// DELETE /api/v1/pro/clients/{id}/do-not-rebook — clear the flag.
    public func clearDoNotRebook(clientId: String) async throws {
        try await api.requestVoid(
            "/pro/clients/\(clientId)/do-not-rebook", method: .delete
        )
    }

    /// PATCH /api/v1/pro/clients/{id}/profile-context — pro-captured occupation +
    /// social handle (occupation is encrypted server-side; the handle is normalized).
    /// An empty string clears the corresponding field.
    public func updateProfileContext(
        clientId: String,
        occupation: String,
        socialHandle: String
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProClientProfileContextRequest(
                occupation: occupation, proCapturedSocialHandle: socialHandle
            )
        )
        try await api.requestVoid(
            "/pro/clients/\(clientId)/profile-context", method: .patch, body: payload
        )
    }

    // MARK: - Technical record (founder-gated: formula · consent · photo-release)

    /// GET /api/v1/pro/clients/{id}/technical → the technical record: the authoring
    /// pro's formula history, scope-redacted consent/patch-test records, and the
    /// client's photo-release status. 404s when the founder technical-record flag is
    /// off. Loaded lazily by the technical tab so decrypted free text stays off the
    /// chart aggregate.
    public func technicalRecord(clientId: String) async throws -> ProClientTechnicalRecord {
        try await api.request("/pro/clients/\(clientId)/technical")
    }

    /// GET /api/v1/pro/clients/{id}/public-profile → the client's PUBLIC creator
    /// profile (handle · avatar · bio · follower/following/looks counts · looks
    /// grid), keyed by clientId. Mirrors the web `?view=public` toggle; the pro is
    /// a neutral read-only viewer (`viewer.isOwn`/`following` always false). Returns
    /// `nil` when the client has no public profile — distinct from a thrown 404
    /// (route not deployed → the view falls back to a web pointer).
    public func publicProfile(clientId: String) async throws -> ProClientPublicProfile? {
        let response: ProClientPublicProfileResponse =
            try await api.request("/pro/clients/\(clientId)/public-profile")
        return response.profile
    }

    /// POST /api/v1/pro/clients/{id}/formula — add a formula entry (author-only,
    /// never public). At least one detail is required; `resultNotes` is encrypted
    /// server-side. Optionally tie it to one of this client's bookings.
    public func addFormula(
        clientId: String,
        brand: String?,
        developer: String?,
        ratio: String?,
        processingTimeMinutes: Int?,
        resultNotes: String?,
        bookingId: String? = nil
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProClientFormulaRequest(
                brand: brand, developer: developer, ratio: ratio,
                processingTimeMinutes: processingTimeMinutes,
                resultNotes: resultNotes, bookingId: bookingId
            )
        )
        try await api.requestVoid(
            "/pro/clients/\(clientId)/formula", method: .post, body: payload
        )
    }

    /// POST /api/v1/pro/clients/{id}/consent — add a consent / waiver / patch-test
    /// record. `kind` ∈ GENERAL_CONSENT | SERVICE_WAIVER | PATCH_TEST; the patch-test
    /// result + validity apply only to PATCH_TEST. `notes` is encrypted server-side.
    public func addConsent(
        clientId: String,
        kind: String,
        serviceScope: String?,
        proofMethod: String?,
        proofRef: String?,
        signedAt: String?,
        notes: String?,
        patchTestResult: String?,
        validUntil: String?,
        bookingId: String? = nil
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProClientConsentRequest(
                kind: kind, serviceScope: serviceScope, proofMethod: proofMethod,
                proofRef: proofRef, signedAt: signedAt, notes: notes,
                patchTestResult: patchTestResult, validUntil: validUntil,
                bookingId: bookingId
            )
        )
        try await api.requestVoid(
            "/pro/clients/\(clientId)/consent", method: .post, body: payload
        )
    }

    /// PATCH /api/v1/pro/clients/{id}/photo-release — set the client's standing
    /// photo-release decision. `status` ∈ NOT_SET | GRANTED | DECLINED (NOT_SET
    /// clears it). This does NOT change the public-sharing path.
    public func updatePhotoRelease(clientId: String, status: String) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProClientPhotoReleaseRequest(status: status)
        )
        try await api.requestVoid(
            "/pro/clients/\(clientId)/photo-release", method: .patch, body: payload
        )
    }
}

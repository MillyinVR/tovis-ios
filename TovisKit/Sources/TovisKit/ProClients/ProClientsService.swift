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
}

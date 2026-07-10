import Foundation

/// PRO manual reminders — the pro's own follow-up / rebook / product-check-in
/// to-dos (web `/pro/reminders`), distinct from the appointment-reminder cadence
/// (`ProReminderSettings`). All three routes already exist, so this is an iOS-only
/// port — no backend change. Authenticated; PRO-only. See docs/PRO-BACKEND-CONTRACTS.md.
public final class ProRemindersService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/reminders — the pro's reminders (open + completed), `dueAt`
    /// ascending. The view splits open vs. completed client-side like the web page.
    public func list() async throws -> [ProReminder] {
        let response: ProRemindersResponse = try await api.request("/pro/reminders")
        return response.reminders
    }

    /// POST /api/v1/pro/reminders — create a reminder. The route parses a form body
    /// (`req.formData()`), so this sends `application/x-www-form-urlencoded`, not
    /// JSON. `dueAt` is an ISO-8601 UTC instant (native picks a real instant, so —
    /// unlike the web `datetime-local` field — the stored time is unambiguous). The
    /// optional `clientId` must be a client the pro can currently view (the route
    /// re-checks). `type` stays `GENERAL` to match the web page's create form.
    /// Returns the created reminder's id.
    @discardableResult
    public func create(
        title: String,
        body: String?,
        dueAt: String,
        clientId: String? = nil,
        type: String = "GENERAL"
    ) async throws -> String {
        var fields: [(String, String)] = [
            ("title", title),
            ("dueAt", dueAt),
            ("type", type),
        ]
        if let body, !body.isEmpty { fields.append(("body", body)) }
        if let clientId, !clientId.isEmpty { fields.append(("clientId", clientId)) }

        let response: ProReminderMutationResponse = try await api.request(
            "/pro/reminders",
            method: .post,
            body: ProRemindersService.formEncode(fields),
            headers: ["Content-Type": "application/x-www-form-urlencoded"]
        )
        return response.id
    }

    /// POST /api/v1/pro/reminders/{id}/complete — mark a reminder done (stamps
    /// `completedAt`). The route returns the completed id as JSON for API callers
    /// (browsers get a 303 back to the page). We only need the 2xx, then reload.
    public func complete(id: String) async throws {
        try await api.requestVoid("/pro/reminders/\(id)/complete", method: .post)
    }

    /// Encode `application/x-www-form-urlencoded` key/value pairs. Percent-encodes
    /// everything outside the unreserved set (RFC 3986) so spaces, `&`, `=`, and
    /// non-ASCII round-trip through the server's `URLSearchParams`-based parser.
    static func formEncode(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { key, value -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        return Data(encoded.joined(separator: "&").utf8)
    }
}

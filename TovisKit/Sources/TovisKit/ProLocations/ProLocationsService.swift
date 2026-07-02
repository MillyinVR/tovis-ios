import Foundation

/// PRO workspace — full CRUD for the pro's locations (web `/pro/locations`
/// `LocationsClient`). Authenticated; PRO-only.
///
/// Create goes through the onboarding endpoint (it geocodes the address / ZIP,
/// resolves the timezone, and creates a DRAFT location); `publish()` flips
/// publishable drafts to bookable; `update` does a sparse edit of name / primary /
/// lead time; the mobile-base sub-route edits a travel base's ZIP + radius; and
/// `remove` deletes a location (the server hard-deletes it when nothing references
/// it and archives it — keeping booking history — when bookings still point at it).
public final class ProLocationsService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/locations → the pro's (non-archived) locations.
    public func list() async throws -> [ProLocationSummary] {
        let res: ProLocationsResponse = try await api.request("/pro/locations")
        return res.locations
    }

    /// POST /api/v1/pro/onboarding/location — create a SALON/SUITE draft from a
    /// resolved Google place. `kind` is `"SALON"` or `"SUITE"`. The location is a
    /// draft (not bookable) until `publish()`.
    public func createFixed(
        kind: String,
        placeId: String,
        name: String?,
        advanceNoticeMinutes: Int,
        makePrimary: Bool
    ) async throws {
        var fields: [String: JSONValue] = [
            "mode": .string(kind),
            "placeId": .string(placeId),
            "advanceNoticeMinutes": .int(advanceNoticeMinutes),
            "makePrimary": .bool(makePrimary),
        ]
        fields["locationName"] = .stringOrNull(name)
        let body = try JSONEncoder().encode(fields)
        try await api.requestVoid("/pro/onboarding/location", method: .post, body: body)
    }

    /// POST /api/v1/pro/onboarding/location — create a MOBILE travel base draft from
    /// a base ZIP + travel `radiusMiles`. Draft until `publish()`.
    public func createMobileBase(
        postalCode: String,
        radiusMiles: Int,
        name: String?,
        advanceNoticeMinutes: Int,
        makePrimary: Bool
    ) async throws {
        var fields: [String: JSONValue] = [
            "mode": .string("MOBILE"),
            "postalCode": .string(postalCode),
            "radiusMiles": .int(radiusMiles),
            "advanceNoticeMinutes": .int(advanceNoticeMinutes),
            "makePrimary": .bool(makePrimary),
        ]
        fields["locationName"] = .stringOrNull(name)
        let body = try JSONEncoder().encode(fields)
        try await api.requestVoid("/pro/onboarding/location", method: .post, body: body)
    }

    /// PATCH /api/v1/pro/locations/[id] — sparse edit of name / primary / lead time.
    /// Only the provided fields change. Note: `isPrimary` can only be turned ON
    /// (the server refuses to unset the primary directly — set another instead),
    /// and bookability is not flipped here (use `publish()`).
    public func update(
        id: String,
        name: String?? = nil,
        isPrimary: Bool? = nil,
        advanceNoticeMinutes: Int? = nil
    ) async throws {
        var fields: [String: JSONValue] = [:]
        if let name { fields["name"] = .stringOrNull(name) }
        if let isPrimary { fields["isPrimary"] = .bool(isPrimary) }
        if let advanceNoticeMinutes { fields["advanceNoticeMinutes"] = .int(advanceNoticeMinutes) }

        let body = try JSONEncoder().encode(fields)
        try await api.requestVoid("/pro/locations/\(id)", method: .patch, body: body)
    }

    /// PATCH /api/v1/pro/locations/[id]/mobile-base — edit a MOBILE base's ZIP
    /// and/or travel `radiusMiles`. Both optional; send at least one. Changing the
    /// ZIP re-geocodes the base and refreshes its timezone server-side.
    public func updateMobileBase(
        id: String,
        postalCode: String?,
        radiusMiles: Int?
    ) async throws {
        var fields: [String: JSONValue] = [:]
        if let postalCode { fields["postalCode"] = .string(postalCode) }
        if let radiusMiles { fields["radiusMiles"] = .int(radiusMiles) }

        let body = try JSONEncoder().encode(fields)
        try await api.requestVoid("/pro/locations/\(id)/mobile-base", method: .patch, body: body)
    }

    /// POST /api/v1/pro/schedule/publish — flip every publishable draft location to
    /// bookable. Throws `APIError.server(422,…)` with a user-facing message when
    /// blockers remain (missing timezone / hours / address).
    public func publish() async throws {
        try await api.requestVoid("/pro/schedule/publish", method: .post)
    }

    /// DELETE /api/v1/pro/locations/[id] — remove a location. The server hard-deletes
    /// it when nothing references it, and archives it (hidden, but booking history
    /// preserved) when bookings/holds/openings still reference it.
    public func remove(id: String) async throws {
        try await api.requestVoid("/pro/locations/\(id)", method: .delete)
    }
}

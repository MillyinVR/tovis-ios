import Foundation

/// Reads the PRO calendar — bookings, blocks, and the management buckets
/// (`GET /api/v1/pro/calendar`). Authenticated; PRO-only. The web page renders
/// the same payload server-side; this is the native client's only schedule
/// source (the `/pro/bookings` route is POST-only).
public final class ProCalendarService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/calendar. With no range the server returns its default
    /// window; pass `from`/`to` (ISO-8601) to scope it. `locationId` selects a
    /// specific location when the pro has more than one.
    public func calendar(
        from: String? = nil,
        to: String? = nil,
        locationId: String? = nil
    ) async throws -> ProCalendarResponse {
        var query: [URLQueryItem] = []
        if let from { query.append(URLQueryItem(name: "from", value: from)) }
        if let to { query.append(URLQueryItem(name: "to", value: to)) }
        if let locationId { query.append(URLQueryItem(name: "locationId", value: locationId)) }
        return try await api.request("/pro/calendar", query: query.isEmpty ? nil : query)
    }

    // MARK: - Blocked time (web BlockTimeModal / EditBlockModal)

    /// GET /api/v1/pro/locations — the pro's locations. Block creation must pin to
    /// a bookable one, so the calendar loads these to populate the location picker.
    public func locations() async throws -> [ProLocationSummary] {
        let res: ProLocationsResponse = try await api.request("/pro/locations")
        return res.locations
    }

    /// GET /api/v1/pro/calendar/blocked/[id] — one block (carries the `note` the
    /// calendar BLOCK event doesn't, so the editor can pre-fill it).
    public func block(id: String) async throws -> ProCalendarBlock {
        let res: ProCalendarBlockResponse = try await api.request("/pro/calendar/blocked/\(id)")
        return res.block
    }

    /// POST /api/v1/pro/calendar/blocked — create a block. `startsAt`/`endsAt` are
    /// ISO-8601; `locationId` is required. Server validates the 15min–24h window
    /// and rejects overlaps (booking/hold/block) with a user-facing message.
    @discardableResult
    public func createBlock(
        startsAt: String,
        endsAt: String,
        note: String?,
        locationId: String
    ) async throws -> ProCalendarBlock {
        let body = try JSONEncoder.canonical.encode(CreateBlockRequest(
            startsAt: startsAt, endsAt: endsAt, note: note, locationId: locationId))
        let res: ProCalendarBlockResponse = try await api.request(
            "/pro/calendar/blocked", method: .post, body: body)
        return res.block
    }

    /// PATCH /api/v1/pro/calendar/blocked/[id] — edit a block's window / note.
    @discardableResult
    public func updateBlock(
        id: String,
        startsAt: String,
        endsAt: String,
        note: String?
    ) async throws -> ProCalendarBlock {
        let body = try JSONEncoder.canonical.encode(UpdateBlockRequest(
            startsAt: startsAt, endsAt: endsAt, note: note))
        let res: ProCalendarBlockResponse = try await api.request(
            "/pro/calendar/blocked/\(id)", method: .patch, body: body)
        return res.block
    }

    /// DELETE /api/v1/pro/calendar/blocked/[id] — remove a block.
    public func deleteBlock(id: String) async throws {
        try await api.requestVoid("/pro/calendar/blocked/\(id)", method: .delete)
    }

    /// PATCH /api/v1/pro/settings { autoAcceptBookings } — flip whether new
    /// bookings auto-accept (web calendar auto-accept bar). Returns the saved value.
    @discardableResult
    public func setAutoAccept(_ enabled: Bool) async throws -> Bool {
        let body = try JSONEncoder.canonical.encode(ProSettingsUpdateRequest(autoAcceptBookings: enabled))
        let res: ProSettingsResponse = try await api.request(
            "/pro/settings", method: .patch, body: body)
        return res.professionalProfile.autoAcceptBookings
    }
}

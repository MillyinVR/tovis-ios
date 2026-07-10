import Foundation

/// PRO workspace — weekly working hours (web `/pro/calendar` working-hours form).
/// Reads the resolved week and saves edits. Authenticated; PRO-only.
/// See docs/PRO-BACKEND-CONTRACTS.md.
public final class ProScheduleService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/last-minute/workspace — the last-minute settings (master
    /// toggle, priority offer, tiers, per-day disables) + service rules + blocks +
    /// active offerings (web `/pro/last-minute`).
    public func lastMinuteWorkspace() async throws -> ProLastMinuteWorkspace {
        return try await api.request("/pro/last-minute/workspace")
    }

    /// PATCH /api/v1/pro/last-minute/settings — persist the "Last-minute defaults"
    /// (master toggle, default visibility, floor, tier anchors, priority offer,
    /// per-day disables). The route applies each present key; we send the whole
    /// form. Callers reload `lastMinuteWorkspace()` to reflect the saved state.
    public func updateLastMinuteSettings(_ request: ProLastMinuteSettingsPatchRequest) async throws {
        let body = try JSONEncoder.canonical.encode(request)
        try await api.requestVoid("/pro/last-minute/settings", method: .patch, body: body)
    }

    /// PATCH /api/v1/pro/last-minute/rules — upsert one per-service eligibility
    /// rule. `minCollectedSubtotal` nil inherits the global floor.
    public func updateLastMinuteServiceRule(
        serviceId: String,
        enabled: Bool,
        minCollectedSubtotal: String?
    ) async throws {
        let body = try JSONEncoder.canonical.encode(
            ProLastMinuteServiceRulePatchRequest(
                serviceId: serviceId, enabled: enabled, minCollectedSubtotal: minCollectedSubtotal
            )
        )
        try await api.requestVoid("/pro/last-minute/rules", method: .patch, body: body)
    }

    /// POST /api/v1/pro/last-minute/blocks — block a time range from ever being
    /// offered as a last-minute opening. Instants are ISO-8601 UTC; the server
    /// rejects a window that overlaps an existing block (409, surfaced inline).
    public func addLastMinuteBlock(startAt: String, endAt: String, reason: String?) async throws {
        let body = try JSONEncoder.canonical.encode(
            ProLastMinuteBlockCreateRequest(startAt: startAt, endAt: endAt, reason: reason)
        )
        try await api.requestVoid("/pro/last-minute/blocks", method: .post, body: body)
    }

    /// DELETE /api/v1/pro/last-minute/blocks?id= — remove a blocked range.
    public func deleteLastMinuteBlock(id: String) async throws {
        try await api.requestVoid(
            "/pro/last-minute/blocks",
            method: .delete,
            query: [URLQueryItem(name: "id", value: id)]
        )
    }

    // MARK: - Waitlist outreach

    /// GET /api/v1/pro/waitlist — the clients waiting for this pro's services,
    /// grouped by service and FIFO-ranked (web `/pro/waitlist` outreach feed). The
    /// pro works the list top-down to fill a spot; each entry carries a
    /// server-formatted preference label and join instant. Pair with
    /// `offerWaitlistSlot(...)` (offer a time) or `MessagesService.openWaitlistThread`.
    public func waitlistOutreach() async throws -> ProWaitlistOutreach {
        return try await api.request("/pro/waitlist")
    }

    /// POST /api/v1/pro/waitlist/{entryId}/offer — propose a concrete in-salon
    /// appointment time to a waitlisted client (web `WaitlistOfferModal`). Creates a
    /// PENDING `WaitlistOffer` and notifies the client to Confirm/Decline; it does
    /// NOT book anything (the client's confirm does). SALON-only for v1. The route
    /// derives the client + service from the entry, so only the chosen slot + the
    /// in-salon `locationId` travel in the body — pick the slot from the pro's live
    /// availability (`BookingService.day`). Idempotent, mirroring web
    /// (`buildClientIdempotencyKey`): the key is scoped to the entry + the ISO start
    /// instant (no nonce — the start already distinguishes one offer from another),
    /// so a double-tap of the same slot replays instead of double-offering, while a
    /// different slot mints a fresh key. The route rejects a missing idempotency-key
    /// header, so one is always sent.
    @discardableResult
    public func offerWaitlistSlot(
        waitlistEntryId: String,
        scheduledFor: String,
        endsAt: String,
        locationId: String,
        durationMinutes: Int,
        idempotencyKey: String? = nil
    ) async throws -> ProWaitlistOffer {
        let payload = try JSONEncoder.canonical.encode(
            ProWaitlistOfferRequest(
                scheduledFor: scheduledFor,
                endsAt: endsAt,
                locationId: locationId,
                locationType: "SALON",
                durationMinutes: durationMinutes
            )
        )
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "pro-waitlist-offer", entityId: waitlistEntryId, action: scheduledFor)
        let response: ProWaitlistOfferResponse = try await api.request(
            "/pro/waitlist/\(waitlistEntryId)/offer",
            method: .post,
            body: payload,
            headers: ["idempotency-key": key]
        )
        return response.offer
    }

    // MARK: - Last-minute openings (create / list / cancel)

    /// GET /api/v1/pro/openings — the pro's upcoming last-minute openings within
    /// the lookahead window (default next 48h), each with its services, tier
    /// plans, and recipient count (web `/pro/last-minute` openings list).
    public func listOpenings(hours: Int = 48, take: Int = 100) async throws -> [ProOpeningDto] {
        let response: ProOpeningsListResponse = try await api.request(
            "/pro/openings",
            query: [
                URLQueryItem(name: "hours", value: String(hours)),
                URLQueryItem(name: "take", value: String(take)),
            ]
        )
        return response.openings
    }

    /// POST /api/v1/pro/openings — create a last-minute opening (slot + tier
    /// plans). The server validates the window, floors, and tier plans and owns
    /// the rollout schedule; typed `status/code` errors surface inline. Returns
    /// the created opening.
    @discardableResult
    public func createOpening(_ request: ProOpeningCreateRequest) async throws -> ProOpeningDto {
        let body = try JSONEncoder.canonical.encode(request)
        let response: ProOpeningCreateResponse = try await api.request(
            "/pro/openings",
            method: .post,
            body: body
        )
        return response.opening
    }

    /// DELETE /api/v1/pro/openings?id= — cancel an active opening. The server
    /// refuses to cancel a booked opening (409) and treats an already-cancelled
    /// one as a no-op.
    public func cancelOpening(id: String) async throws {
        try await api.requestVoid(
            "/pro/openings",
            method: .delete,
            query: [URLQueryItem(name: "id", value: id)]
        )
    }

    /// GET /api/v1/pro/working-hours — the saved (or default) week for a location
    /// type. `locationType` is "SALON" or "MOBILE".
    public func workingHours(
        locationType: String? = nil,
        locationId: String? = nil
    ) async throws -> ProWorkingHoursResponse {
        var query: [URLQueryItem] = []
        if let locationType { query.append(URLQueryItem(name: "locationType", value: locationType)) }
        if let locationId { query.append(URLQueryItem(name: "locationId", value: locationId)) }
        return try await api.request("/pro/working-hours", query: query.isEmpty ? nil : query)
    }

    /// POST /api/v1/pro/working-hours — persist the week. Returns the saved result.
    @discardableResult
    public func updateWorkingHours(
        _ week: ProWeekHours,
        locationType: String? = nil,
        locationId: String? = nil
    ) async throws -> ProWorkingHoursResponse {
        var query: [URLQueryItem] = []
        if let locationType { query.append(URLQueryItem(name: "locationType", value: locationType)) }
        if let locationId { query.append(URLQueryItem(name: "locationId", value: locationId)) }
        let body = try JSONEncoder.canonical.encode(ProWorkingHoursUpdateRequest(workingHours: week))
        return try await api.request(
            "/pro/working-hours",
            method: .post,
            query: query.isEmpty ? nil : query,
            body: body
        )
    }
}

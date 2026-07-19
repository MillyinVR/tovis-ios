import Foundation

/// Presence on the last-minute opening claim path — the read half
/// (`GET /api/v1/presence/signals`) and the write half
/// (`POST /api/v1/client/presence/heartbeat`) of web's `lib/presence` hooks.
///
/// Contract driven against the running routes 2026-07-19 (local server, minted
/// CLIENT jwt); every note below is a captured fact, not an inference:
///
/// **The read is PUBLIC.** No `requireClient` — it answers 200 with no
/// Authorization header at all. We still send the bearer because every other
/// call does and the claim path is only reachable signed in.
///
/// **The read never 404s.** An unknown, expired or outright invented
/// `resourceId` — and an unknown `professionalId` — both return
/// `200 {"watching":0,"waitlisted":0}`. So a stale opening id degrades to
/// counts that fall below threshold and render nothing; it can never surface an
/// error to a client who is just looking at a booking screen. Only a malformed
/// REQUEST is a 400 (bad `resourceType`, or a missing `resourceId` /
/// `professionalId`).
///
/// **The heartbeat genuinely reads its body** (unlike the comment-report and
/// mark-no-show routes, whose handlers ignore it): an invalid `resourceType`,
/// `{}`, no body at all and malformed JSON are each a 400. A `clientId` in the
/// body is ignored — the server uses the session's.
///
/// **The heartbeat is naturally idempotent and unthrottled.** It is a Redis
/// `ZADD` keyed on the caller's client id, so a repeat only refreshes their
/// score: ten rapid POSTs still read back `watching:1`. Driven: no rate limit
/// (10/10 → 200) and no `withRouteIdempotency` (the same `Idempotency-Key` twice
/// with different bodies processed both). That is why this service sends no
/// idempotency key — there is no double-submit to defeat, and a key would imply
/// a replay contract the route does not have.
public final class PresenceService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/presence/signals — the raw counts for one resource.
    ///
    /// `serviceId` narrows the waitlist count to that service; omitted, it
    /// counts every ACTIVE waitlist entry for the pro. Web passes the opening's
    /// service on the claim page, so callers here should too.
    public func signals(
        resourceType: PresenceResourceType,
        resourceId: String,
        professionalId: String,
        serviceId: String? = nil
    ) async throws -> PresenceSignals {
        var query = [
            URLQueryItem(name: "resourceType", value: resourceType.rawValue),
            URLQueryItem(name: "resourceId", value: resourceId),
            URLQueryItem(name: "professionalId", value: professionalId),
        ]
        if let serviceId { query.append(URLQueryItem(name: "serviceId", value: serviceId)) }

        let response: PresenceSignalsResponse = try await api.request(
            "/presence/signals",
            query: query
        )
        return response.signals
    }

    /// POST /api/v1/client/presence/heartbeat — mark the caller as watching.
    ///
    /// Returns the server's `recorded` flag, which is `false` when Redis is
    /// unconfigured. Callers on the claim path ignore it: there is nothing
    /// useful to tell a client about their own presence not being counted, and
    /// the read half already reports the same outage as `watching: null`.
    @discardableResult
    public func heartbeat(
        resourceType: PresenceResourceType,
        resourceId: String
    ) async throws -> Bool {
        let body = try JSONEncoder.canonical.encode(
            PresenceHeartbeatRequest(
                resourceType: resourceType.rawValue,
                resourceId: resourceId
            )
        )
        let response: PresenceHeartbeatResponse = try await api.request(
            "/client/presence/heartbeat",
            method: .post,
            body: body
        )
        return response.recorded
    }
}

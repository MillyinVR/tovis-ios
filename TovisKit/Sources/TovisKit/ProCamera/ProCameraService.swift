import Foundation

/// PRO workspace — camera support content (trending shot packs; tovis-app
/// PR #453) + Claude-vision analysis (look briefs and set critiques;
/// tovis-app PR #454). Authenticated; PRO-only (CLIENT tokens 403).
public final class ProCameraService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/camera/shot-packs → the current trending shot packs,
    /// hottest first. The camera matches packs to the booking's service
    /// client-side and drops pose-rule kinds it doesn't recognize.
    public func shotPacks() async throws -> ProShotPacksResponse {
        try await api.request("/pro/camera/shot-packs")
    }

    /// POST /api/v1/pro/camera/look-brief → Claude-vision enhance of a
    /// "Match a look" reference photo: extra pose rules (same vocabulary as
    /// packs) + spoken direction lines for what geometry can't measure.
    /// Consent-gated in the UI — this is the only place the reference photo
    /// leaves the device; the server analyzes in-flight and stores nothing.
    /// Free with a daily cap (429 when exhausted).
    public func lookBrief(_ request: ProLookBriefRequest) async throws -> ProLookBrief {
        let body = try JSONEncoder().encode(request)
        let response: ProLookBriefResponse = try await api.request(
            "/pro/camera/look-brief", method: .post, body: body)
        return response.brief
    }

    /// POST /api/v1/pro/camera/set-critique → a photographer's review of the
    /// captured before/after set (per-photo portfolio/keep/retake verdicts,
    /// strengths, an overall read). Same consent + storage story as
    /// `lookBrief`; free with a daily cap (429 when exhausted).
    public func setCritique(_ request: ProSetCritiqueRequest) async throws -> ProSetCritique {
        let body = try JSONEncoder().encode(request)
        let response: ProSetCritiqueResponse = try await api.request(
            "/pro/camera/set-critique", method: .post, body: body)
        return response.critique
    }
}

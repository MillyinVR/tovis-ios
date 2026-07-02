import Foundation

/// PRO workspace — camera support content (trending shot packs; tovis-app
/// PR #453). Authenticated; PRO-only (CLIENT tokens 403).
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
}

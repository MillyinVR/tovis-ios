import Foundation

/// PRO workspace — the "am I bookable yet?" readiness check that powers the
/// onboarding checklist + the not-bookable banner. Mirrors web's GET
/// /api/v1/pro/readiness (lib/pro/readiness/proReadiness.ts). Authenticated;
/// PRO-only (a CLIENT token 403s).
///
/// The endpoint evaluates readiness at the SPECIFIC_SEARCH entry point, so the
/// broad-discovery-only `VERIFICATION_NOT_BROADLY_DISCOVERABLE` blocker never
/// appears here; verification only surfaces when the account is actively
/// REJECTED / NEEDS_INFO (or a required license has expired).
public final class ProReadinessService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/readiness → whether the pro is bookable, plus any blockers.
    public func readiness() async throws -> ProReadiness {
        let response: ProReadinessResponse = try await api.request("/pro/readiness")
        return response.readiness
    }
}

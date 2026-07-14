import Foundation
import Testing
@testable import TovisKit

// Locks the AI-camera error contract the app relies on to distinguish the
// monthly image quota (403 CAMERA_QUOTA_EXCEEDED → upgrade route) from the
// daily per-feature vision cap (429 → "try again tomorrow"). Mirrors
// lib/pro/cameraQuotaResponse.ts + lib/rateLimit/policies.ts.
@Suite struct ProCameraAIErrorTests {
    @Test func quota403MapsToUpgradeableQuotaExceeded() {
        let server = APIError.server(
            status: 403,
            message: "You’ve used all 30 AI photographer images included this month. Upgrade your membership for a bigger monthly allowance.",
            code: "CAMERA_QUOTA_EXCEEDED"
        )
        let mapped = ProCameraAIError.from(server)
        #expect(mapped == .quotaExceeded(message:
            "You’ve used all 30 AI photographer images included this month. Upgrade your membership for a bigger monthly allowance."))
        #expect(mapped.offersUpgrade)
        // The server's copy (which names the allowance + upgrade) is shown verbatim.
        #expect(mapped.userMessage.contains("Upgrade your membership"))
    }

    @Test func quota403WithoutBodyMessageFallsBackToDefaultCopy() {
        let mapped = ProCameraAIError.from(
            APIError.server(status: 403, message: nil, code: "CAMERA_QUOTA_EXCEEDED"))
        #expect(mapped.offersUpgrade)
        #expect(mapped.userMessage.contains("Upgrade your membership"))
    }

    @Test func dailyCap429MapsToDailyLimit() {
        let mapped = ProCameraAIError.from(
            APIError.server(status: 429, message: "Too many requests. Please slow down.", code: "RATE_LIMITED"))
        #expect(mapped == .dailyLimitReached)
        #expect(!mapped.offersUpgrade)
        #expect(mapped.userMessage == "Daily AI limit reached — try again tomorrow.")
    }

    @Test func plainForbiddenIsNotTreatedAsQuota() {
        // A 403 that ISN'T the quota code must not offer an upgrade.
        let mapped = ProCameraAIError.from(
            APIError.server(status: 403, message: "Forbidden.", code: "FORBIDDEN"))
        #expect(!mapped.offersUpgrade)
        #expect(mapped == .other(message: "Forbidden."))
    }

    @Test func otherServerErrorCarriesItsMessage() {
        let mapped = ProCameraAIError.from(
            APIError.server(status: 502, message: "The AI photographer is unavailable right now. Please try again.", code: nil))
        #expect(!mapped.offersUpgrade)
        #expect(mapped == .other(message: "The AI photographer is unavailable right now. Please try again."))
    }

    @Test func transportErrorFallsBackToOther() {
        let mapped = ProCameraAIError.from(APIError.transport("offline"))
        #expect(!mapped.offersUpgrade)
        #expect(mapped == .other(message: APIError.transport("offline").userMessage))
    }

    @Test func nonApiErrorFallsBackToGenericOther() {
        struct Boom: Error {}
        let mapped = ProCameraAIError.from(Boom())
        #expect(!mapped.offersUpgrade)
        if case .other = mapped { } else { Issue.record("expected .other") }
    }
}

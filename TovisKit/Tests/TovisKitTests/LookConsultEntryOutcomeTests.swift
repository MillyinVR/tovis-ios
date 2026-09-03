import Foundation
import Testing
@testable import TovisKit

/// Book tapped while acting as PRO (Tori, 2026-09-02): the consult probe is a
/// client-only route, so the server answers 403 `WORKSPACE_MISMATCH` — and the
/// tap used to swallow that as "no door" and open a booking sheet that could
/// only dead-end at the hold. That one refusal is now its own outcome, so the
/// surface can offer the switch instead.
@Suite struct LookConsultEntryOutcomeTests {
    @Test func theServersWorkspaceMismatchIsNamedAndNothingElseIs() {
        #expect(APIError.server(status: 403, message: "Forbidden", code: "WORKSPACE_MISMATCH")
                .isWorkspaceMismatch)
        // A plain 403 (no switchable workspace — an admin, or a pro with no
        // client profile) is still "may not", not "not from here".
        #expect(!APIError.server(status: 403, message: "Forbidden", code: nil).isWorkspaceMismatch)
        #expect(!APIError.server(status: 404, message: nil, code: "NOT_FOUND").isWorkspaceMismatch)
        #expect(!APIError.unauthorized.isWorkspaceMismatch)
        #expect(!APIError.transport("offline").isWorkspaceMismatch)
    }

    @Test func onlyAWorkspaceMismatchBecomesAnOfferEveryOtherRefusalIsNoDoor() {
        #expect(LookConsultEntry.outcome(
            refusedBy: APIError.server(status: 403, message: "Forbidden", code: "WORKSPACE_MISMATCH"))
            == .workspaceMismatch)
        // The cases that made the probe safe to ship before any server had the
        // route: a 404, a plain 403, an expired session, being offline. All of
        // them still hand the tap to the ordinary sheet.
        #expect(LookConsultEntry.outcome(
            refusedBy: APIError.server(status: 404, message: nil, code: nil)) == .noConsult)
        #expect(LookConsultEntry.outcome(
            refusedBy: APIError.server(status: 403, message: "Forbidden", code: nil)) == .noConsult)
        #expect(LookConsultEntry.outcome(refusedBy: APIError.unauthorized) == .noConsult)
        #expect(LookConsultEntry.outcome(refusedBy: APIError.transport("offline")) == .noConsult)
        #expect(LookConsultEntry.outcome(refusedBy: URLError(.cancelled)) == .noConsult)
    }
}

import Foundation
import Testing
@testable import Tovis

// K15/K17-A: which proof methods a pro may CLAIM by hand on the technical
// record, and the one they may not.
//
// 🔴 Why this suite exists: `ConsentProofMethod.CLIENT_TOKEN` means "the platform
// witnessed this signature through a link it sent". Since K15 the only writer of
// it is the signing route behind that link, which also stamps
// `signatureTokenId` — the unique column that proves a real link existed — and
// `POST /pro/clients/{id}/consent` REFUSES a hand-typed one outright. The iOS
// sheet went on offering "Client link" anyway, so the only thing a pro could get
// from picking it was a 400: a control the server can only say no to
// ([[kill-switch-must-reach-the-control]], and K14-B's original finding —
// the option had been lying since it shipped).
//
// The list is file-scope in ProClientTechnicalEditSheets purely so this can be
// asserted; inline `Text(...).tag(...)` rows in a Picker are untestable, which
// is exactly why the gap survived K14.

@Suite struct ProConsentProofMethodTests {

    @Test("a pro cannot hand-claim a link signature")
    func clientTokenIsNotOfferable() {
        #expect(!proConsentProofMethodOptions.contains { $0.value == "CLIENT_TOKEN" })
        #expect(!proConsentProofMethodOptions.contains { $0.label.lowercased().contains("link") })
    }

    @Test("the methods a pro CAN attest to are still offered")
    func theHonestMethodsSurvive() {
        // Removing the refused option must not quietly remove the working ones —
        // a picker with nothing in it is a different bug wearing the same fix.
        #expect(proConsentProofMethodOptions.map(\.value) == ["IN_PERSON", "PAPER_ON_FILE"])
        #expect(proConsentProofMethodOptions.allSatisfy { !$0.label.isEmpty })
    }
}

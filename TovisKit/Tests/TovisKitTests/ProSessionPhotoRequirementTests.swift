import Foundation
import Testing
@testable import TovisKit

// The session photo requirement — one BEFORE, one AFTER, extras optional.
// These are the assertions that keep the app from quietly asking for more than
// it needs (device feedback, 2026-08-01).
struct ProSessionPhotoRequirementTests {
    @Test func requiresExactlyOnePhotoPerPhase() {
        #expect(ProSessionPhotoRequirement.requiredPerPhase == 1)
    }

    @Test func oneCapturedPhotoMeetsTheRequirement() {
        #expect(ProSessionPhotoRequirement.isMet(captured: 0) == false)
        #expect(ProSessionPhotoRequirement.isMet(captured: 1) == true)
        // Extras never un-meet it, and never become a new requirement.
        #expect(ProSessionPhotoRequirement.isMet(captured: 7) == true)
    }

    @Test func outstandingCountsDownToZeroAndStops() {
        #expect(ProSessionPhotoRequirement.outstanding(captured: 0) == 1)
        #expect(ProSessionPhotoRequirement.outstanding(captured: 1) == 0)
        #expect(ProSessionPhotoRequirement.outstanding(captured: 4) == 0)
    }

    // MARK: - Copy
    //
    // Screens quote these verbatim, so the wording is the contract: nothing may
    // ask for photos plural, and nothing may say "1 photos".

    @Test func requirementCopyNamesOnePhotoOfThePhase() {
        #expect(ProSessionPhotoRequirement.requiredNoun(.before) == "1 before photo")
        #expect(ProSessionPhotoRequirement.requiredNoun(.after) == "1 after photo")
        #expect(ProSessionPhotoRequirement.requiredNoun(.other) == "1 session photo")
    }

    @Test func gateSentenceAsksForOneAndCallsExtrasOptional() {
        let sentence = ProSessionPhotoRequirement.gateSentence(
            .before, action: "Add", purpose: "to continue to service")
        #expect(sentence == "Add 1 before photo to continue to service — extras are optional.")
    }

    @Test func capturedSentencePluralisesOnTheCount() {
        #expect(ProSessionPhotoRequirement.capturedSentence(1) == "1 photo captured")
        #expect(ProSessionPhotoRequirement.capturedSentence(3) == "3 photos captured")
    }

    @Test func outstandingAndGuideCopyNameTheSingleRequirement() {
        #expect(ProSessionPhotoRequirement.outstandingSentence(.after)
                == "This session still needs 1 after photo.")
        #expect(ProSessionPhotoRequirement.guideNote(.before)
                == "Only 1 before photo is required — the rest of this set is optional.")
        #expect(ProSessionPhotoRequirement.leavingWithoutTitle(.before)
                == "Leave without a before photo?")
    }
}

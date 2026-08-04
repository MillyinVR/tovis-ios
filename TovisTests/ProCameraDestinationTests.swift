import Testing
import TovisKit
@testable import Tovis

/// `ProCameraDestination` is the ONLY difference between the session camera and
/// the standalone one. Everything the two shoots do differently is derived here,
/// so these are the assertions that stop the practice camera behaving like a
/// client shoot (or vice versa).
@Suite struct ProCameraDestinationTests {

    // MARK: - Custody namespace

    /// 🔴 The load-bearing one. The byte vault, the clip vault and the stored
    /// white-balance / card calibration all key on this string. If practice and
    /// a booking ever shared it, a stranded practice photo would be swept into
    /// that booking's owed-upload queue and posted to a client who never
    /// appeared in it — and a calibration solved at home would silently
    /// re-colour their before/after.
    @Test func practiceAndABookingNeverShareACustodyScope() {
        let booking = ProCameraDestination.session(bookingId: "bk_1", phase: .before)
        #expect(booking.custodyScope == "bk_1")
        #expect(ProCameraDestination.practice.custodyScope == "practice")
        #expect(booking.custodyScope != ProCameraDestination.practice.custodyScope)
    }

    /// Both phases of one booking DO share a scope — that is deliberate: a
    /// BEFORE photo stranded by a crash is swept up during the AFTER shoot, and
    /// its own stored phase is what puts it back in BEFORE.
    @Test func bothPhasesOfABookingShareItsScope() {
        let before = ProCameraDestination.session(bookingId: "bk_1", phase: .before)
        let after = ProCameraDestination.session(bookingId: "bk_1", phase: .after)
        #expect(before.custodyScope == after.custodyScope)
    }

    /// The practice scope is a reserved literal, so it can only collide with a
    /// booking whose id is exactly "practice". Booking ids are cuids — 25-odd
    /// characters starting with 'c' — so this is a shape check, not a hope.
    @Test func theReservedScopeCannotLookLikeABookingId() {
        let scope = ProCameraDestination.practice.custodyScope
        #expect(scope == "practice")
        #expect(scope.count < 20)
        #expect(!scope.hasPrefix("c") || scope.count != 25)
    }

    // MARK: - What is owed

    @Test func aSessionPhaseOwesAPhotoAndPracticeOwesNothing() {
        #expect(ProCameraDestination.session(bookingId: "bk_1", phase: .before).owesAPhoto)
        #expect(ProCameraDestination.session(bookingId: "bk_1", phase: .after).owesAPhoto)
        #expect(ProCameraDestination.practice.owesAPhoto == false)
    }

    /// Practice is satisfied at zero photos — there is nothing to satisfy. This
    /// is what keeps the requirement card, the accented Done and the "you still
    /// owe a photo" exit sentence out of a shoot that owes nobody anything.
    @Test func practiceIsAlwaysSatisfied() {
        #expect(ProCameraDestination.practice.requirementMet(captured: 0))
        #expect(ProCameraDestination.practice.requirementMet(captured: 7))
    }

    /// A session still defers to the ONE place the rule lives
    /// (`ProSessionPhotoRequirement`) — this must not become a second copy of it.
    @Test func aSessionStillAsksTheOneRequirementType() {
        let destination = ProCameraDestination.session(bookingId: "bk_1", phase: .before)
        for captured in 0...3 {
            #expect(
                destination.requirementMet(captured: captured)
                    == ProSessionPhotoRequirement.isMet(captured: captured)
            )
        }
    }

    @Test func practiceHasNoOutstandingSentenceToSay() {
        #expect(ProCameraDestination.practice.outstandingSentence.isEmpty)
        #expect(
            !ProCameraDestination.session(bookingId: "bk_1", phase: .after)
                .outstandingSentence.isEmpty
        )
    }

    /// The guide note is the line a pro reads to learn what's required. Practice
    /// must say plainly that nothing is — not repeat a session's "add 1 before
    /// photo", which would be a lie about a shoot with no client in it.
    @Test func theGuideNoteNeverPromisesPracticeOwesSomething() {
        let note = ProCameraDestination.practice.guideNote(requirementMet: false)
        #expect(!note.isEmpty)
        #expect(!note.lowercased().contains("required"))
        #expect(note.lowercased().contains("aren’t attached")
                || note.lowercased().contains("later"))
    }

    @Test func aSessionGuideNoteChangesOnceTheRequirementIsMet() {
        let destination = ProCameraDestination.session(bookingId: "bk_1", phase: .before)
        #expect(
            destination.guideNote(requirementMet: true)
                != destination.guideNote(requirementMet: false)
        )
    }

    // MARK: - Phase

    /// Practice shoots `.other`, which is also what the server records — there
    /// is no before/after when there is no transformation being documented.
    @Test func practiceShootsTheOtherPhase() {
        #expect(ProCameraDestination.practice.phase == .other)
        #expect(ProCameraDestination.practice.bookingId == nil)
        #expect(ProCameraDestination.practice.isPractice)
    }

    @Test func aSessionCarriesItsBookingAndPhase() {
        let destination = ProCameraDestination.session(bookingId: "bk_9", phase: .after)
        #expect(destination.bookingId == "bk_9")
        #expect(destination.phase == .after)
        #expect(destination.isPractice == false)
    }
}

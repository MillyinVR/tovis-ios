// Booking vocabulary in the coach's mouth (camera plan P3) — the pure half.
//
// Three things are worth pinning here: the REFUSAL rules that decide whether a
// stored name is safe to say out loud at all, which moments get the booking's
// words (and, just as important, which deliberately don't), and the invariant
// that this substitution leaves #974's look script still able to take the line.
//
// The other half — whether the longest sentence this can build survives the
// fixed 56pt lane — is `CameraLaneLineFitTests`, because a string literal
// cannot tell you that.
import Testing
import TovisKit
@testable import Tovis

@Suite struct CoachBookingVocabularyTests {
    private let maya = CoachBookingVocabulary(serviceName: "Caramel Balayage",
                                              clientFullName: "Maya Lopez")

    private func nudge(_ moment: CoachMoment?, _ message: String = "canonical",
                       category: CoachCategory = .composition,
                       ctx: CoachPhraseContext? = nil) -> CoachNudge {
        CoachNudge(category: category, message: message, moment: moment, phraseCtx: ctx)
    }

    // MARK: - Is this name safe to say?

    @Test func takesTheFirstNameOffAStoredFullName() {
        #expect(CoachBookingVocabulary.firstName(from: "Maya Lopez") == "Maya")
        #expect(CoachBookingVocabulary.firstName(from: "  Maya  ") == "Maya")
        #expect(CoachBookingVocabulary.firstName(from: "Anne-Marie Dubois") == "Anne-Marie")
        #expect(CoachBookingVocabulary.firstName(from: "O'Brien") == "O'Brien")
    }

    @Test func readsAHonorificAsATitleRatherThanAName() {
        #expect(CoachBookingVocabulary.firstName(from: "Dr. Amara Okafor") == "Amara")
        #expect(CoachBookingVocabulary.firstName(from: "Ms Priya Raman") == "Priya")
        // A bare title is not a name; "Center Dr" is worse than "Center your subject".
        #expect(CoachBookingVocabulary.firstName(from: "Dr") == nil)
        #expect(CoachBookingVocabulary.firstName(from: "Mrs.") == nil)
    }

    @Test func capitalizesOnlyAWordTheProTypedAllInLowerCase() {
        #expect(CoachBookingVocabulary.firstName(from: "maya lopez") == "Maya")
        // Spelled the way it's spelled — the coach doesn't correct people's names.
        #expect(CoachBookingVocabulary.firstName(from: "McKenzie Reed") == "McKenzie")
        #expect(CoachBookingVocabulary.firstName(from: "MAYA") == "MAYA")
    }

    /// The refusals. Saying a client's name WRONG, out loud, in front of that
    /// client is worse than saying "your subject" — so anything that isn't
    /// plainly a spoken first name has to fall back to the canonical line.
    @Test func refusesAnythingThatIsNotPlainlyASpokenFirstName() {
        #expect(CoachBookingVocabulary.firstName(from: nil) == nil)
        #expect(CoachBookingVocabulary.firstName(from: "   ") == nil)
        #expect(CoachBookingVocabulary.firstName(from: "J. Smith") == nil)      // an initial
        #expect(CoachBookingVocabulary.firstName(from: "+15551234567") == nil)  // a phone number
        #expect(CoachBookingVocabulary.firstName(from: "maya@example.com") == nil)
        #expect(CoachBookingVocabulary.firstName(from: "Bartholomewfitzgerald") == nil) // 21 chars
    }

    // MARK: - What is being photographed

    @Test func speaksTheBookingsOwnWordsForTheWork() {
        #expect(CoachBookingVocabulary.workNoun(from: "Balayage") == "the balayage")
        #expect(CoachBookingVocabulary.workNoun(from: "Caramel Balayage") == "the caramel balayage")
        #expect(CoachBookingVocabulary.workNoun(from: "Gel Manicure") == "the gel manicure")
        // Already articled — don't stutter.
        #expect(CoachBookingVocabulary.workNoun(from: "The Works") == "the works")
        // A menu typed in caps is formatting; an acronym is a spelling.
        #expect(CoachBookingVocabulary.workNoun(from: "BALAYAGE") == "the balayage")
        #expect(CoachBookingVocabulary.workNoun(from: "IPL Facial") == "the IPL facial")
    }

    @Test func cutsAnAddOnListDownToTheThingInTheFrame() {
        #expect(CoachBookingVocabulary.workNoun(from: "Balayage + Toner") == "the balayage")
        #expect(CoachBookingVocabulary.workNoun(from: "Full Highlights & Toner") == "the full highlights")
        // "w/" loses its slash to the cut; a one-letter tail is debris.
        #expect(CoachBookingVocabulary.workNoun(from: "Silk Press w/ Trim") == "the silk press")
    }

    @Test func refusesAServiceNameThatIsNotAWordForWhatIsInThePicture() {
        #expect(CoachBookingVocabulary.workNoun(from: nil) == nil)
        #expect(CoachBookingVocabulary.workNoun(from: "  ") == nil)
        #expect(CoachBookingVocabulary.workNoun(from: "60 min Blowout") == nil)   // a duration
        #expect(CoachBookingVocabulary.workNoun(from: "Full Set 2") == nil)       // a size
        #expect(CoachBookingVocabulary.workNoun(from: "Keratin Smoothing Treatment") == nil) // 27 chars
    }

    // MARK: - Which lines get the booking's words

    @Test func namesTheClientOnTheLinesThatAreAboutTheClient() {
        #expect(maya.line(replacing: nudge(.compositionTooLow)) == "Raise the camera — Maya’s too low")
        #expect(maya.line(replacing: nudge(.compositionFaceRequired)) == "Frame Maya’s face for this shot")
        #expect(maya.line(replacing: nudge(.compositionOffFrame))
                == "Maya’s outside the feed crop — center them")
        #expect(maya.line(replacing: nudge(.poseClipped, category: .pose))
                == "Maya’s getting clipped — pull back")
        #expect(maya.line(replacing: nudge(.lightingBacklit, category: .lighting))
                == "Light’s behind Maya — turn them to face the window")
    }

    @Test func namesTheWorkOnTheOneLineThatIsAboutTheWork() {
        #expect(maya.line(replacing: nudge(.compositionTooFar))
                == "Move in closer — fill the frame with the caramel balayage")
        // No usable service name → the canonical "fill the frame" stands, even
        // though the client is named everywhere else.
        let noService = CoachBookingVocabulary(serviceName: "60 min", clientFullName: "Maya Lopez")
        #expect(noService.line(replacing: nudge(.compositionTooFar)) == nil)
    }

    /// Vision-grounded: the coach says which side of centre it can SEE them on.
    /// A POSITION, never a "move left" — that sign convention is the one
    /// `LevelCoach` still has flagged unverified, and this must not become a
    /// second one.
    @Test func saysWhichSideOfCentreTheLensSeesThemOn() {
        let left = CoachPhraseContext(direction: "left", namesAPerson: true)
        #expect(maya.line(replacing: nudge(.compositionRecenter, ctx: left))
                == "Center Maya — off to the left")
        let right = CoachPhraseContext(direction: "right", namesAPerson: true)
        #expect(maya.line(replacing: nudge(.compositionRecenter, ctx: right))
                == "Center Maya — off to the right")
        // No side measured → name them, claim nothing about where they are.
        #expect(maya.line(replacing: nudge(.compositionRecenter)) == "Center Maya")
    }

    /// `lightingTooDark`/`lightingBlownOut` carry TWO canonical lines each — a
    /// face variant and a flat-lay one. Naming the client on a tray of nails
    /// would be exactly the confidently-wrong advice the north star rules out.
    @Test func onlyNamesTheClientOnTheVariantThatMeasuredAFace() {
        let face = CoachPhraseContext(namesAPerson: true)
        #expect(maya.line(replacing: nudge(.lightingTooDark, category: .lighting, ctx: face))
                == "Maya’s face is too dark — turn them toward the light")
        #expect(maya.line(replacing: nudge(.lightingBlownOut, category: .lighting, ctx: face))
                == "Maya’s face is blown out — turn away from the bright light")
        // The detail/flat-lay variant, where there is no face and no person.
        #expect(maya.line(replacing: nudge(.lightingTooDark, category: .lighting)) == nil)
        #expect(maya.line(replacing: nudge(.lightingBlownOut, category: .lighting)) == nil)
    }

    /// The room and the camera are not the client. A booking name pasted onto
    /// "Mixed light" would be specificity theatre, not knowledge.
    @Test func leavesTheLinesThatAreAboutTheRoomOrTheCameraAlone() {
        for moment in [CoachMoment.colorMixed, .colorGreenish, .colorWarm, .levelTilted,
                       .levelAlmostLevel, .backgroundBusy, .sharpnessHoldSteady,
                       .sharpnessTapToFocus, .compositionTooClose, .compositionNoHeadroom] {
            #expect(maya.line(replacing: nudge(moment, category: .color)) == nil,
                    "\(moment) should keep its canonical line")
        }
        // A pose-rule tip carries no moment at all — pack-neutral by design.
        #expect(maya.line(replacing: nudge(nil, category: .pose)) == nil)
    }

    @Test func anEmptyVocabularyChangesNothing() {
        #expect(CoachBookingVocabulary.empty.isEmpty)
        for moment in CoachMoment.allCases {
            #expect(CoachBookingVocabulary.empty.line(
                replacing: nudge(moment, ctx: CoachPhraseContext(direction: "left",
                                                                 namesAPerson: true))) == nil)
        }
    }

    // MARK: - What the substitution must not disturb

    @Test func keepsTheCategoryTheMomentAndTheContext() {
        let ctx = CoachPhraseContext(direction: "left", namesAPerson: true)
        let raw = nudge(.compositionRecenter, "Center your subject", ctx: ctx)
        let spoken = maya.applied(to: raw)
        #expect(spoken.message == "Center Maya — off to the left")
        #expect(spoken.category == raw.category)
        #expect(spoken.moment == raw.moment)
        #expect(spoken.phraseCtx == ctx)
    }

    /// The drawer's row and the lane's line come out of the SAME substitution,
    /// so the two surfaces cannot disagree about what the coach just said.
    @Test func theDrawerRowIsRewrittenTheSameWayTheLaneLineIs() {
        let ctx = CoachPhraseContext(namesAPerson: true)
        let status = CoachStatus(category: .lighting, score: 0.3,
                                 message: "Their face is too dark — turn them toward the light",
                                 why: "why", moment: .lightingTooDark, phraseCtx: ctx)
        let spoken = maya.applied(to: status)
        #expect(spoken.message == "Maya’s face is too dark — turn them toward the light")
        #expect(spoken.why == status.why)
        #expect(spoken.score == status.score)
        // A passing fundamental has no line to rewrite.
        let good = CoachStatus(category: .lighting, score: 1.0, message: nil)
        #expect(maya.applied(to: good).message == nil)
    }

    /// 🔴 The hazard this pins: #974's look script matches on `nudge.moment`.
    /// A substitution that dropped the moment the way a LOOK line does would
    /// silently switch trigger-bound direction back off, and nothing else in
    /// the suite would notice.
    @Test func theLookStillTakesTheLineBackFromTheBookingsVocabulary() {
        let script = LookDirectionScript(wire: [
            ProLookBriefDirection(trigger: "subjectTooFar", line: "Step in — I want the ends sharp"),
        ])
        let raw = nudge(.compositionTooFar, "Move in closer — fill the frame")
        let spoken = maya.applied(to: raw)
        #expect(spoken.message == "Move in closer — fill the frame with the caramel balayage")
        #expect(script.line(replacing: spoken) == "Step in — I want the ends sharp")
    }
}

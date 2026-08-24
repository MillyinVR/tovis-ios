import Foundation
import Testing
@testable import Tovis

// The lane is the whole subtraction pass in one function: fourteen rows that
// could co-occur now compete for one slot. What matters is the ORDER — a
// refusal must never be hidden behind a coaching tip, and a coaching tip must
// never be hidden behind a step hint that should have expired.
@Suite struct CameraCoachLaneTests {

    // MARK: - Priority order

    @Test func terminalFailureOutranksEverything() {
        var i = CameraLane.Inputs()
        i.terminalCount = 2
        i.retryableCount = 3
        i.bestShotCount = 4
        i.lightDrifted = true
        i.stepTransient = "45° to the window"
        i.coachTip = "Too dark — step toward the window"
        i.isReady = true

        let message = CameraLane.message(i)
        #expect(message?.text == "2 photos can’t be saved here")
        #expect(message?.tone == .alert)
        #expect(message?.action?.kind == .terminalOptions)
        // Retry is deliberately absent: retrying a refusal reproduces it.
        #expect(message?.action?.label == "OPTIONS")
    }

    @Test func retryableOutranksEverythingBelowIt() {
        var i = CameraLane.Inputs()
        i.retryableCount = 2
        i.bestShotCount = 4
        i.lightDrifted = true
        i.coachTip = "Too dark"

        let message = CameraLane.message(i)
        #expect(message?.text == "2 photos waiting on signal")
        #expect(message?.action?.kind == .retryUploads)
    }

    /// Photos and clips both queue behind the one RETRY action, so a pro with
    /// one of each sees one row and one tap — not two competing for the lane.
    @Test func owedPhotosAndClipsShareOneRow() {
        var i = CameraLane.Inputs()
        i.retryableCount = 1
        i.failedClipCount = 2
        #expect(CameraLane.message(i)?.text == "3 photos waiting on signal")
    }

    @Test func bestShotsOutrankCoachingAndLight() {
        var i = CameraLane.Inputs()
        i.bestShotCount = 3
        i.lightDrifted = true
        i.coachTip = "Too dark"

        let message = CameraLane.message(i)
        #expect(message?.text == "3 keepers from that burst")
        #expect(message?.tone == .accent)
        #expect(message?.action?.kind == .reviewBestShots)
    }

    @Test func driftOutranksTheCoachTip() {
        var i = CameraLane.Inputs()
        i.lightDrifted = true
        i.coachTip = "Too dark"
        #expect(CameraLane.message(i)?.action?.kind == .recalibrate)
    }

    @Test func stepTransientOutranksTheCoachTipWhileItLasts() {
        var i = CameraLane.Inputs()
        i.stepTransient = "45° to the window, chin slightly down"
        i.stepProgress = (index: 0, total: 5)
        i.coachTip = "Too dark"

        let message = CameraLane.message(i)
        #expect(message?.text == "45° to the window, chin slightly down")
        #expect(message?.trailing == "1/5")
        // The step row reads as a title, not a verdict — no state dot.
        #expect(message?.showsDot == false)
    }

    /// The transient's whole point: once the view clears it, the coach gets the
    /// lane back. A step hint that never expired would silence coaching.
    @Test func coachTipReturnsWhenTheStepTransientExpires() {
        var i = CameraLane.Inputs()
        i.stepTransient = "45° to the window"
        i.coachTip = "Too dark — step toward the window"
        #expect(CameraLane.message(i)?.text == "45° to the window")

        i.stepTransient = nil
        let message = CameraLane.message(i)
        #expect(message?.text == "Too dark — step toward the window")
        #expect(message?.tone == .warn)
    }

    // MARK: - The resting state

    @Test func readyBeatsTheCoachTip() {
        var i = CameraLane.Inputs()
        i.isReady = true
        i.coachTip = "Too dark"
        let message = CameraLane.message(i)
        #expect(message?.text == "Hold it — shooting")
        #expect(message?.tone == .accent)
    }

    @Test func stepHintIsTheQuietRestingState() {
        var i = CameraLane.Inputs()
        i.stepHint = "45° to the window"
        let message = CameraLane.message(i)
        #expect(message?.text == "45° to the window")
        #expect(message?.tone == .neutral)
    }

    @Test func setCompleteLineOnlyAfterTheCardIsDismissed() {
        var i = CameraLane.Inputs()
        i.setComplete = true
        #expect(CameraLane.message(i)?.text == "That’s the full set — beautiful work")
    }

    @Test func nothingToSayLeavesTheLaneEmpty() {
        #expect(CameraLane.message(CameraLane.Inputs()) == nil)
    }

    // MARK: - Copy discipline

    /// "Instructions, never scores" — the lane must never render a number the
    /// pro is being marked against, and singular/plural must both read as English.
    @Test func failureCopyIsSingularAndPluralCorrect() {
        var one = CameraLane.Inputs(); one.terminalCount = 1
        #expect(CameraLane.message(one)?.text == "1 photo can’t be saved here")

        var many = CameraLane.Inputs(); many.terminalCount = 4
        #expect(CameraLane.message(many)?.text == "4 photos can’t be saved here")

        var owed = CameraLane.Inputs(); owed.retryableCount = 1
        #expect(CameraLane.message(owed)?.text == "1 photo waiting on signal")

        var keeper = CameraLane.Inputs(); keeper.bestShotCount = 1
        #expect(CameraLane.message(keeper)?.text == "1 keeper from that burst")
    }

    // MARK: - Expandability (the swipe-up affordance must be honest)

    @Test func onlyCoachingTiersOfferTheSevenDimensions() {
        var coaching = CameraLane.Inputs()
        coaching.coachTip = "Too dark"
        coaching.hasDimensions = true
        #expect(CameraLane.message(coaching)?.expandable == true)

        // A failure row is not a coaching read — swiping it up would open a
        // drawer that has nothing to do with what it says.
        var failure = CameraLane.Inputs()
        failure.terminalCount = 1
        failure.hasDimensions = true
        #expect(CameraLane.message(failure)?.expandable == false)
    }

    /// With the fundamentals setting off there is nothing behind the line, so it
    /// must not advertise a swipe that opens an empty drawer.
    @Test func noAffordanceWhenThereAreNoDimensions() {
        var i = CameraLane.Inputs()
        i.coachTip = "Too dark"
        i.hasDimensions = false
        #expect(CameraLane.message(i)?.expandable == false)
    }

    // MARK: - Errors

    /// A capture that didn't happen is a failure with words — above coaching,
    /// below the durable queues (which are state, and outlive any one message).
    @Test func errorSitsBetweenTheQueuesAndCoaching() {
        var i = CameraLane.Inputs()
        i.errorText = "Couldn’t take that photo. Please try again."
        i.coachTip = "Too dark"
        #expect(CameraLane.message(i)?.text == "Couldn’t take that photo. Please try again.")

        i.retryableCount = 1
        #expect(CameraLane.message(i)?.text == "1 photo waiting on signal")
    }

    // MARK: - Accessibility

    /// Losing the seven pills must not lose their information: the collapsed
    /// line has to carry the whole picture in one utterance.
    @Test func accessibilityValueCarriesTheWholePicture() {
        let statuses = [
            CoachStatus(category: .lighting, score: 0.3, message: "Too dark"),
            CoachStatus(category: .color, score: 0.9, message: nil),
            CoachStatus(category: .level, score: 0.9, message: nil),
            CoachStatus(category: .composition, score: 0.9, message: nil),
            CoachStatus(category: .sharpness, score: 0.9, message: nil),
            CoachStatus(category: .background, score: 0.6, message: "Trolley in frame"),
            CoachStatus(category: .pose, score: 0.9, message: nil),
        ]
        let message = LaneMessage(text: "Too dark — step toward the window", tone: .warn)
        let spoken = CameraLane.accessibilityValue(message: message, statuses: statuses)

        // The weakest fundamental, by name and not by abbreviation…
        #expect(spoken.contains("Lighting needs work."))
        // …how many are fine…
        #expect(spoken.contains("5 of 7 good."))
        // …and the instruction itself.
        #expect(spoken.contains("Too dark — step toward the window"))
    }

    @Test func accessibilityValueSurvivesAnEmptyRead() {
        #expect(CameraLane.accessibilityValue(message: nil, statuses: []) == "Nothing to fix")
    }

    /// VoiceOver should never read a pill abbreviation aloud.
    @Test func spokenCategoryNamesAreWords() {
        #expect(CoachCategory.sharpness.spokenName == "Focus")
        #expect(CoachCategory.composition.spokenName == "Framing")
        #expect(CoachCategory.sharpness.shortLabel == "FOCUS")
    }

    // MARK: - The fixed-height promise

    /// The shutter's muscle memory depends on this: the lane reserves its height
    /// whether or not anything is speaking.
    @Test func laneHeightIsFixed() {
        #expect(CameraLane.height == 56)
    }

    // MARK: - Room memory: the offer and its answer (P4.1)

    /// The offer ADDS a word to the coach's own line. It must not be able to
    /// put a row on the lane or take one off — the lane's priority order is
    /// exactly what it was.
    @Test func theRoomMemoryOfferRidesOnTheCoachLineAndChangesNothingElse() {
        var i = CameraLane.Inputs()
        i.coachTip = "Mixed light — turn off the overheads"
        i.coachTipMoment = .colorMixed
        i.hasDimensions = true
        let without = CameraLane.message(i)
        i.coachTipDismissible = true
        let with = CameraLane.message(i)

        #expect(with?.text == without?.text)
        #expect(with?.tone == without?.tone)
        #expect(with?.pulses == without?.pulses)
        #expect(with?.expandable == true, "the seven dimensions stay reachable while the offer stands")
        #expect(without?.action == nil)
        #expect(with?.action?.kind == .dismissRoomTip)
        #expect(with?.action?.label == CameraLane.dismissRoomTipLabel)
    }

    /// No coaching line, no offer — the word has nothing to agree with.
    @Test func theOfferCannotAppearWithoutACoachLine() {
        var i = CameraLane.Inputs()
        i.coachTipDismissible = true
        i.stepHint = "Move in close on the finished work"
        let message = CameraLane.message(i)
        #expect(message?.action == nil)
    }

    /// A failure that needs a tap still takes the lane whole, offer or not.
    @Test func theOfferNeverOutranksSomethingTheProMustDecide() {
        var i = CameraLane.Inputs()
        i.terminalCount = 1
        i.coachTip = "Busy background — find a cleaner backdrop"
        i.coachTipMoment = .backgroundBusy
        i.coachTipDismissible = true
        #expect(CameraLane.message(i)?.action?.kind == .terminalOptions)
    }

    /// The answer to the pro's own tap. It outranks the coaching line
    /// underneath it: the tip it is about has just gone away, and a control
    /// that produces no visible answer reads as one that did nothing.
    @Test func theConfirmationTakesTheLaneBackFromTheCoachForItsWindow() {
        var i = CameraLane.Inputs()
        i.coachTip = "Move in closer — fill the frame"
        i.coachTipMoment = .compositionTooFar
        i.roomTipDismissed = "Got it — the overheads stay on here"
        let message = CameraLane.message(i)
        #expect(message?.text == "Got it — the overheads stay on here")
        #expect(message?.tone == .accent)
        #expect(message?.action == nil, "there is nothing left to tap")
    }

    /// The way back, for exactly as long as the confirmation is on screen.
    @Test func theConfirmationCarriesTheUndoWhileThereIsSomethingToPutBack() {
        var i = CameraLane.Inputs()
        i.roomTipDismissed = "Got it — the overheads stay on here"
        i.roomTipDismissalUndoable = true
        #expect(CameraLane.message(i)?.action?.kind == .undoRoomDismissal)
        #expect(CameraLane.message(i)?.action?.label == CameraLane.undoRoomDismissalLabel)
        // …and not once it has been taken.
        i.roomTipDismissed = "That tip is back"
        i.roomTipDismissalUndoable = false
        #expect(CameraLane.message(i)?.action == nil)
    }

    /// It arrives already rendered in the pro's voice (`CoachEngine`
    /// .dismissRoomTip), so the lane shows it verbatim — flourishing it a
    /// second time is how two packs' voices end up stacked in one sentence.
    @Test func theConfirmationIsShownVerbatimInEveryVoice() {
        var i = CameraLane.Inputs()
        i.roomTipDismissed = "Got it — the overheads stay on here. Noted, bestie!"
        for personality in CoachPersonality.allCases {
            #expect(CameraLane.message(i, voice: personality.voice)?.text
                    == "Got it — the overheads stay on here. Noted, bestie!",
                    "\(personality) re-rendered a line that was already rendered")
        }
    }
}

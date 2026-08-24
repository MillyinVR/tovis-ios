// The short-horizon half of P4's memory: the coach noticing that repeating
// itself has stopped working (`CoachBackOff`).
//
// These pin the ARITHMETIC — the whole feature is one comparison ("did this
// rung's score go up?") plus a clock, and there is deliberately nothing else in
// it to test: no sentiment, no emotion, no inference about the pro. The
// LADDER's side of it — what happens to the lock, to the compliment, and to
// readiness — is pinned in `CoachTipArbiterTests`.
//
// ⚠️ Nothing here mutates `CoachTuning`'s process-global `static var`s. Swift
// Testing runs suites in parallel, and #359 backed out exactly that pattern:
// the windows are read off the real tuning values and time is driven by
// passing `now`, which is race-free and also measures what actually ships.
import Testing
@testable import Tovis

@Suite struct CoachBackOffTests {
    private let patience = CoachBackOff.simplifyAfter
    private let silence = CoachBackOff.quietAfter

    /// One rung broken at a constant score, observed from `0` to `until` at the
    /// analyzer's real cadence, with that rung locked throughout.
    private func hold(_ backOff: inout CoachBackOff, rung: FocusRung, score: Double,
                      from: Double = 0, to until: Double) -> Double {
        let step = 1.0 / CoachTuning.analysisFPS
        var now = from
        while now <= until {
            backOff.update(brokenScores: [rung: score], locked: rung, now: now)
            now += step
        }
        return now - step
    }

    // MARK: - The three stages

    @Test func aFreshRungIsSpokenNormally() {
        var backOff = CoachBackOff()
        backOff.update(brokenScores: [.color: 0.45], locked: .color, now: 0)
        #expect(backOff.stage(of: .color) == .speaking)
        #expect(backOff.quietedRungs.isEmpty)
    }

    @Test func aStalledRungIsSimplifiedOnceBeforeItGoesQuiet() {
        var backOff = CoachBackOff()
        _ = hold(&backOff, rung: .color, score: 0.45, to: patience - 1)
        #expect(backOff.stage(of: .color) == .speaking, "still inside the coach's patience")

        _ = hold(&backOff, rung: .color, score: 0.45, from: patience - 1 + 1 / CoachTuning.analysisFPS,
                 to: silence - 1)
        #expect(backOff.stage(of: .color) == .simplified,
                "said once more, plainer — not yet silent")
        #expect(backOff.quietedRungs.isEmpty)

        _ = hold(&backOff, rung: .color, score: 0.45, from: silence - 1 + 1 / CoachTuning.analysisFPS,
                 to: silence + 1)
        #expect(backOff.stage(of: .color) == .quiet)
        #expect(backOff.quietedRungs == [.color])
    }

    // MARK: - Progress buys the patience back

    /// The one measurement the whole feature is made of. A score that moves is
    /// the pro acting on the line, so the coach starts over — it is not
    /// counting how long it has been talking, it is counting how long it has
    /// been talking for NOTHING.
    @Test func anImprovingScoreResetsTheCoachsPatience() {
        var backOff = CoachBackOff()
        _ = hold(&backOff, rung: .centering, score: 0.45, to: silence - 1)
        #expect(backOff.stage(of: .centering) == .simplified)

        // 0.45 → 0.50 is the real step `CompositionCoach` takes between "leave
        // a little headroom" and "raise the camera": measurable progress.
        backOff.update(brokenScores: [.centering: 0.50], locked: .centering, now: silence)
        #expect(backOff.stage(of: .centering) == .speaking)
    }

    @Test func aScoreThatDipsAndRecoversIsNotProgress() {
        var backOff = CoachBackOff()
        _ = hold(&backOff, rung: .background, score: 0.5, to: patience - 1)
        // Worse, then back to exactly where it was. `best` is a high-water
        // mark, so this buys nothing — otherwise sensor noise alone would
        // renew the coach's patience forever.
        backOff.update(brokenScores: [.background: 0.4], locked: .background, now: patience - 0.5)
        backOff.update(brokenScores: [.background: 0.5], locked: .background, now: patience)
        #expect(backOff.stage(of: .background) == .simplified)
    }

    @Test func aChangeNoBiggerThanTheEpsilonIsNotProgress() {
        var backOff = CoachBackOff()
        _ = hold(&backOff, rung: .background, score: 0.5, to: patience - 1)
        backOff.update(brokenScores: [.background: 0.5 + CoachBackOff.improvementEpsilon],
                       locked: .background, now: patience)
        #expect(backOff.stage(of: .background) == .simplified,
                "the epsilon is the floor of what counts, not a value that counts")
    }

    // MARK: - Only the rung the pro is actually reading spends the patience

    /// A rung that has been broken all along but never said out loud cannot
    /// have worn out its welcome. Otherwise the coach would advance to a
    /// correction and immediately have nothing to say about it.
    @Test func aRungTheCoachHasNeverSaidCannotBackOff() {
        var backOff = CoachBackOff()
        let step = 1.0 / CoachTuning.analysisFPS
        var now = 0.0
        while now <= silence + 5 {
            backOff.update(brokenScores: [.color: 0.45, .background: 0.5],
                           locked: .color, now: now)
            now += step
        }
        #expect(backOff.quietedRungs == [.color])
        #expect(backOff.stage(of: .background) == .speaking,
                "the backdrop line has never been on screen — it gets full patience")
    }

    /// …and a rung the ladder was pulled AWAY from keeps the time it had
    /// served, not the wall clock. Fifteen seconds on the lane, two minutes of
    /// something else, then back: it resumes at fifteen seconds.
    @Test func timeSpentCoachingSomethingElseIsNotSpentOnThisRung() {
        var backOff = CoachBackOff()
        let step = 1.0 / CoachTuning.analysisFPS
        _ = hold(&backOff, rung: .color, score: 0.45, to: patience - 2)

        // Lighting regresses and takes the lock for a long while. Colour is
        // still broken the whole time, but nobody is reading it.
        var now = patience
        while now <= patience + 300 {
            backOff.update(brokenScores: [.lighting: 0.4, .color: 0.45],
                           locked: .lighting, now: now)
            now += step
        }
        #expect(backOff.stage(of: .color) == .speaking,
                "colour had served two seconds short of its patience, and served none since")
        #expect(!backOff.quietedRungs.contains(.color))
        // Lighting, which HAS been on the lane that whole time, has of course
        // backed off — that is the feature working, not a leak into colour.
        #expect(backOff.quietedRungs == [.lighting])

        // Back on colour: it needs only the seconds it hadn't served yet.
        while now <= patience + 300 + 3 {
            backOff.update(brokenScores: [.lighting: 0.4, .color: 0.45], locked: .color, now: now)
            now += step
        }
        #expect(backOff.stage(of: .color) == .simplified)
    }

    // MARK: - Coming back

    /// Backing off is the coach's own reading of the last minute, not a verdict
    /// — so the moment the pro starts moving the number, the words come back.
    @Test func aQuietedRungSpeaksAgainAsSoonAsItsScoreMoves() {
        var backOff = CoachBackOff()
        _ = hold(&backOff, rung: .color, score: 0.45, to: silence + 1)
        #expect(backOff.quietedRungs == [.color])

        backOff.update(brokenScores: [.color: 0.55], locked: .background, now: silence + 2)
        #expect(backOff.quietedRungs.isEmpty)
        #expect(backOff.stage(of: .color) == .speaking)
    }

    /// A rung that stops being broken at all is forgotten outright — the next
    /// time it breaks, the coach starts with its full patience rather than
    /// picking up where an old grievance left off.
    @Test func aRungThatIsFixedForgetsItsHistory() {
        var backOff = CoachBackOff()
        _ = hold(&backOff, rung: .color, score: 0.45, to: silence + 1)
        #expect(backOff.quietedRungs == [.color])

        backOff.update(brokenScores: [:], locked: nil, now: silence + 2)
        #expect(backOff.quietedRungs.isEmpty)
        #expect(backOff.stage(of: .color) == .speaking)

        backOff.update(brokenScores: [.color: 0.45], locked: .color, now: silence + 3)
        #expect(backOff.stage(of: .color) == .speaking)
    }

    /// The stateless path — `CoachAggregate.evaluate(_:_:)`, which the offline
    /// tuning bench and every pinned `CoachReadinessTests` assertion run
    /// through — asks a fresh instance exactly once, so nothing can ever have
    /// stalled and canonical behaviour cannot drift.
    @Test func aSingleFrameNeverBacksAnythingOff() {
        var backOff = CoachBackOff()
        backOff.update(brokenScores: [.color: 0.45, .sharpness: 0.3], locked: .color, now: 0)
        #expect(backOff.quietedRungs.isEmpty)
        #expect(backOff.stage(of: .color) == .speaking)
    }

    // MARK: - The wording half (`CoachPlainLine`)
    //
    // The DECISION to simplify is arithmetic and lives above; the WORDS are a
    // substitution on a correction already chosen, at the same seam as #974 and
    // #358. These pin the substitution itself — what it keeps, what it refuses
    // to touch, and that it only ever fires when the coach has actually backed
    // off. Whether every line FITS the 56pt lane is measured (and LOOKED at) in
    // `CameraLaneLineFitTests`.

    private var maya: CoachBookingVocabulary {
        CoachBookingVocabulary(serviceName: "Caramel Balayage", clientFullName: "Maya Lopez")
    }

    @Test func nothingIsSimplifiedUntilTheCoachHasActuallyBackedOff() {
        let nudge = CoachNudge(category: .color, message: "Mixed light — turn off the overheads",
                               moment: .colorMixed)
        #expect(CoachPlainLine.applied(to: nudge, simplified: false, vocabulary: .empty) == nudge)
    }

    @Test func theSimplifiedFormKeepsTheMomentAndTheContext() {
        let ctx = CoachPhraseContext(direction: "right", namesAPerson: true)
        let nudge = CoachNudge(category: .composition, message: "Center Maya — off to the right",
                               moment: .compositionRecenter, phraseCtx: ctx)
        let plain = CoachPlainLine.applied(to: nudge, simplified: true, vocabulary: maya)
        #expect(plain.message == "Center Maya")
        #expect(plain.moment == .compositionRecenter,
                "dropping the moment would flatten every pack's flourish to save four words")
        #expect(plain.phraseCtx == ctx)
        #expect(plain.category == .composition)
    }

    /// The booking's words run UNDER the plain form: the coach still says who,
    /// because that is the half of the sentence #358 added and the half that
    /// makes it sound like a person.
    @Test func thePlainFormStillNamesTheClient() {
        let nudge = CoachNudge(category: .lighting, message: "x", moment: .lightingBacklit,
                               phraseCtx: CoachPhraseContext(namesAPerson: true))
        #expect(CoachPlainLine.line(for: nudge, vocabulary: maya)
                == "Turn Maya to face the window")
        #expect(CoachPlainLine.line(for: nudge, vocabulary: .empty)
                == "Turn them to face the window",
                "no booking, no name — the coach's own canonical word for the client")
    }

    /// A line that is already a single instruction has nothing to take away, so
    /// the coach says it once more exactly as it was rather than rewording it
    /// for the sake of looking busy.
    @Test func aLineWithNothingToTakeAwayIsLeftAlone() {
        let nudge = CoachNudge(category: .composition, message: "Frame their face for this shot",
                               moment: .compositionFaceRequired)
        #expect(CoachPlainLine.line(for: nudge, vocabulary: maya) == nil)
        #expect(CoachPlainLine.applied(to: nudge, simplified: true, vocabulary: maya) == nudge)

        // …and "Center your subject" only gains a plain form when there is a
        // name to make it plainer WITH.
        let recenter = CoachNudge(category: .composition, message: "Center your subject",
                                  moment: .compositionRecenter)
        #expect(CoachPlainLine.line(for: recenter, vocabulary: .empty) == nil)
    }

    /// A moment-less signal — a server-driven `PoseRule.tip` — has no plain
    /// form, so its stage one is a no-op in words. It still goes quiet on
    /// schedule, which is the half that matters and is decided at the rung.
    @Test func aMomentLessTipHasNoPlainFormAndIsSaidUnchanged() {
        let nudge = CoachNudge(category: .pose, message: "Drop the shoulder nearest the camera")
        #expect(CoachPlainLine.applied(to: nudge, simplified: true, vocabulary: maya) == nudge)
    }
}

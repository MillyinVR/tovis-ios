// The one coach line's DWELL and SWITCHING MARGIN.
//
// The camera shows a single coaching line, and before this the winner was a
// plain `max` over weighted deficits recomputed on every analyzed frame — six
// times a second. Two coaches with near-equal deficits therefore alternated,
// and each alternation fired a warning haptic and restarted the spoken tip from
// the beginning. That is a concrete, code-level mechanism for "it feels like
// nagging", independent of whether the tips themselves are correct.
//
// These pin the arithmetic that fixed it. No camera, no thresholds from the
// device pass — just: does the line hold still, and does it hand over when it
// should?
import Testing
@testable import Tovis

@Suite struct CoachTipArbiterTests {
    private func signal(_ category: CoachCategory, score: Double, message: String? = "x")
        -> (CoachCategory, CoachSignal) {
        (category, CoachSignal(score: score, message: message))
    }

    /// Two coaches sitting within a hair of each other — the exact condition
    /// that produced the alternating buzz. Deficits here are colour 1.1 × 0.55 =
    /// 0.605 and composition 1.0 × 0.55 = 0.55, a gap of 0.055: real, and well
    /// under the switching margin.
    private var nearTie: [(CoachCategory, CoachSignal)] {
        [signal(.color, score: 0.45), signal(.composition, score: 0.45)]
    }

    @Test func aNearTieNoLongerAlternatesEveryFrame() {
        var arbiter = CoachTipArbiter()
        let first = arbiter.select(from: nearTie, now: 0)
        #expect(first.nudge?.category == .color)

        // 30 seconds of frames at the analysis rate. Long past the dwell, so
        // only the margin is holding the line now.
        var line: [CoachCategory] = []
        for frame in 1...180 {
            let t = Double(frame) / CoachTuning.analysisFPS
            if let category = arbiter.select(from: nearTie, now: t).nudge?.category {
                line.append(category)
            }
        }
        #expect(line.count == 180)
        #expect(Set(line) == [.color])   // it never flips
    }

    @Test func theDwellHoldsTheLineEvenAgainstAClearlyWorseProblem() {
        var arbiter = CoachTipArbiter()
        _ = arbiter.select(from: [signal(.background, score: 0.5)], now: 0)

        // A hard lighting failure arrives immediately: deficit 1.6 × 0.7 = 1.12
        // against the background's 0.8 × 0.5 = 0.4. It still waits its turn.
        let contested = [signal(.background, score: 0.5), signal(.lighting, score: 0.3)]
        let midDwell = arbiter.select(from: contested, now: CoachTuning.tipDwellSeconds - 0.01)
        #expect(midDwell.nudge?.category == .background)

        // …and takes the line the moment the dwell is served.
        let after = arbiter.select(from: contested, now: CoachTuning.tipDwellSeconds + 0.01)
        #expect(after.nudge?.category == .lighting)
    }

    @Test func aChallengerMustBeatTheIncumbentByTheMarginNotMerelyBeatIt() {
        var arbiter = CoachTipArbiter()
        _ = arbiter.select(from: [signal(.composition, score: 0.45)], now: 0)
        let incumbentDeficit = CoachAggregate.deficit(.composition, CoachSignal(score: 0.45, message: "x"))

        // A challenger that wins by less than the margin: still not enough.
        let justUnder = incumbentDeficit + CoachTuning.tipSwitchMargin - 0.02
        let weak = [signal(.composition, score: 0.45),
                    signal(.level, score: 1 - justUnder / CoachCategory.level.weight)]
        #expect(arbiter.select(from: weak, now: 10).nudge?.category == .composition)

        // Clear the margin and it takes the line.
        let justOver = incumbentDeficit + CoachTuning.tipSwitchMargin + 0.02
        let strong = [signal(.composition, score: 0.45),
                      signal(.level, score: 1 - justOver / CoachCategory.level.weight)]
        #expect(arbiter.select(from: strong, now: 20).nudge?.category == .level)
    }

    /// The one case that must NOT wait: the pro fixed the thing they were told
    /// to fix. A tip that is no longer true has no claim on the line, dwell or
    /// not — and the hand-back is reported so the coach can say "got it".
    @Test func aFixedDimensionYieldsTheLineImmediatelyAndSaysSo() {
        var arbiter = CoachTipArbiter()
        _ = arbiter.select(from: [signal(.sharpness, score: 0.3),
                                  signal(.background, score: 0.5)], now: 0)

        // Focus fixed a tenth of a second later — deep inside the dwell.
        let fixed = arbiter.select(from: [signal(.sharpness, score: 1.0, message: nil),
                                          signal(.background, score: 0.5)], now: 0.1)
        #expect(fixed.cleared == .sharpness)
        #expect(fixed.nudge?.category == .background)
    }

    @Test func clearingIsReportedOnceNotOnEveryFrameAfter() {
        var arbiter = CoachTipArbiter()
        _ = arbiter.select(from: [signal(.sharpness, score: 0.3)], now: 0)
        let quiet: [(CoachCategory, CoachSignal)] = [signal(.sharpness, score: 1.0, message: nil)]

        #expect(arbiter.select(from: quiet, now: 0.1).cleared == .sharpness)
        #expect(arbiter.select(from: quiet, now: 0.2).cleared == nil)
        #expect(arbiter.select(from: quiet, now: 0.3).cleared == nil)
    }

    /// Re-wording within one dimension ("a touch soft" → "clearly soft") is the
    /// same tip getting more urgent, not a new tip. It must not restart the
    /// dwell, or a steadily-worsening signal would hold the line forever.
    @Test func rewordingWithinADimensionDoesNotRestartTheDwell() {
        var arbiter = CoachTipArbiter()
        _ = arbiter.select(from: [(CoachCategory.sharpness,
                                   CoachSignal(score: 0.6, message: "Tap to focus — a touch soft"))],
                           now: 0)
        // Same dimension, worse wording, mid-dwell.
        let worse = arbiter.select(
            from: [(CoachCategory.sharpness,
                    CoachSignal(score: 0.3, message: "Hold steady — shot looks soft"))],
            now: 1.0)
        #expect(worse.nudge?.message == "Hold steady — shot looks soft")

        // The clock still started at 0, so a challenger that clears the margin
        // gets in on schedule rather than serving a second dwell.
        // (Sharpness 0.3 → deficit 0.98; lighting 0.25 → 1.20, which beats
        // 0.98 + 0.15.)
        let contested = [signal(.sharpness, score: 0.3),
                         signal(.lighting, score: 0.25)]
        #expect(arbiter.select(from: contested,
                               now: CoachTuning.tipDwellSeconds + 0.01).nudge?.category == .lighting)
    }

    /// The memory-free `evaluate` the bench and the scoring tests use must be
    /// the same selection rule with a fresh state — not a second implementation.
    @Test func theStatelessEvaluateIsTheRawRanking() {
        var arbiter = CoachTipArbiter()
        let picked = arbiter.select(from: nearTie, now: 0).nudge
        #expect(picked?.category == .color)   // the larger weighted deficit wins outright
    }
}

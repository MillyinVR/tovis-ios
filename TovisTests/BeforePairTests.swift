// The before-parity recognition line (camera plan P5.3): does it say the good
// news about the PAIR, and does it stay quiet the rest of the time?
//
// Two halves, both pure:
//   - `BeforePair.verdict` — WHAT is true of this frame. It must never claim
//     parity on a comparison the app cannot actually make.
//   - `BeforePairAnnouncer` — WHEN the lane says it. This is the half that
//     decides whether the feature is warmth or a nag, and it is the reason the
//     timing lives in a pure type instead of in the view.
//
// ⚠️ Swift Testing runs suites in PARALLEL and `CoachTuning`'s knobs are
// process-global `static var`s. Nothing here mutates one: the clock is driven
// RELATIVE to `CoachTuning.settleLineMinInterval` as it stands, and the fill
// fixtures are built from the before stamp's own number rather than from a
// threshold. (`CoachBackOffTests` / `CoachStationReadTests` are the same shape.)
import CoreGraphics
import Foundation
import Testing
import TovisKit
@testable import Tovis

@Suite struct BeforePairVerdictTests {
    /// A before whose light and framing are both measured — the ordinary case.
    private func stamp(fill: Double? = 0.40) -> BeforeShotStamp {
        BeforeShotStamp(luma: 0.5, warmth: 0.0, backgroundLuma: 0.55,
                        backgroundWarmth: 0.0, subjectFill: fill, faceBounds: nil)
    }

    private func reading(luma: Double = 0.55, warmth: Double = 0.0) -> LightMatch.Reading {
        LightMatch.Reading(luma: 0.5, warmth: warmth,
                           backgroundLuma: luma, backgroundWarmth: warmth)
    }

    /// A luma far enough off to break the light half whatever the tolerance is
    /// set to — derived from the live knob, never by mutating it.
    private var mismatchedLuma: Double {
        0.55 + CoachTuning.lightMatchLumaTolerance * 4
    }

    @Test func lightAndFramingTogetherRecognizeThePair() {
        let before = stamp()
        let verdict = BeforePair.verdict(
            live: reading(), target: reading(), noun: "before",
            pairing: before, liveFill: 0.40, isDetail: false)
        #expect(verdict.paired)
        #expect(verdict.ok)
        #expect(verdict.moment == .pairedWithBefore)
        #expect(verdict.label == BeforePair.pairedLabel)
    }

    /// The half that already ships must be untouched: matched light with the
    /// framing still wrong is today's line, today's moment.
    @Test func matchedLightAloneIsStillJustMatchedLight() throws {
        let before = stamp()
        let band = try #require(BeforeShotMeasure.pairFillBand(of: before, isDetail: false))
        let verdict = BeforePair.verdict(
            live: reading(), target: reading(), noun: "before",
            pairing: before, liveFill: band.lowerBound - 0.05, isDetail: false)
        #expect(!verdict.paired)
        #expect(verdict.ok)
        #expect(verdict.moment == .lightMatched)
        #expect(verdict.label == "Light matches the before")
    }

    /// …and a light MISMATCH is never upgraded, however well the frame is
    /// framed. Half a pair is not a pair.
    @Test func perfectFramingNeverRecognizesAPairWhoseLightIsWrong() {
        let before = stamp()
        let verdict = BeforePair.verdict(
            live: reading(luma: mismatchedLuma), target: reading(), noun: "before",
            pairing: before, liveFill: 0.40, isDetail: false)
        #expect(!verdict.paired)
        #expect(!verdict.ok)
        #expect(verdict.moment == .lightBrighterThan)
    }

    /// A "match a look" reference is not the other half of this booking's
    /// pair. The light verdict passes through exactly as it ships today.
    @Test func aMatchLookReferenceIsNeverRecognizedAsAPair() {
        let verdict = BeforePair.verdict(
            live: reading(), target: reading(), noun: "reference",
            pairing: nil, liveFill: 0.40, isDetail: false)
        #expect(!verdict.paired)
        #expect(verdict.ok)
        #expect(verdict.moment == .lightMatched)
        #expect(verdict.label == "Light matches the reference")
    }

    /// A detail/macro close-up of the work has no framing pair to match —
    /// `matchingFraming` declines to re-target it, so recognition must decline
    /// to congratulate it, or the coach congratulates a framing it never asked
    /// for.
    @Test func aDetailShotHasNoFramingPairSoItIsNeverRecognized() {
        let verdict = BeforePair.verdict(
            live: reading(), target: reading(), noun: "before",
            pairing: stamp(), liveFill: 0.40, isDetail: true)
        #expect(!verdict.paired)
        #expect(verdict.moment == .lightMatched)
    }

    /// Nothing to compare against on either side ⇒ no claim. A missing
    /// measurement must read as "don't know", never as "matched".
    @Test func anUnmeasurableFramingIsNeverRecognized() {
        #expect(!BeforePair.verdict(live: reading(), target: reading(), noun: "before",
                                    pairing: stamp(), liveFill: nil,
                                    isDetail: false).paired)
        #expect(!BeforePair.verdict(live: reading(), target: reading(), noun: "before",
                                    pairing: stamp(fill: nil), liveFill: 0.40,
                                    isDetail: false).paired)
        // A before that never found a subject at all (`fillBand` refuses ≤0.02).
        #expect(!BeforePair.verdict(live: reading(), target: reading(), noun: "before",
                                    pairing: stamp(fill: 0.01), liveFill: 0.01,
                                    isDetail: false).paired)
    }

    /// The recognition and the coaching read the SAME band — the whole reason
    /// `pairFillBand` has one definition. If they ever diverged, the coach
    /// would be saying "move in closer" and "framing matches" about one frame.
    @Test func recognitionAgreesWithTheBandTheCoachIsActuallyCoachingTo() throws {
        let before = stamp()
        let coached = try #require(ShotExpectations.portrait.matchingFraming(of: before).fillBand)
        let recognized = try #require(BeforeShotMeasure.pairFillBand(of: before, isDetail: false))
        #expect(coached == recognized)
        // …and the edges of that band are inside the recognition, not outside.
        for fill in [recognized.lowerBound, recognized.upperBound] {
            #expect(BeforePair.verdict(live: reading(), target: reading(), noun: "before",
                                       pairing: before, liveFill: fill,
                                       isDetail: false).paired)
        }
        for fill in [recognized.lowerBound - 0.001, recognized.upperBound + 0.001] {
            #expect(!BeforePair.verdict(live: reading(), target: reading(), noun: "before",
                                        pairing: before, liveFill: fill,
                                        isDetail: false).paired)
        }
    }

    /// The property that keeps the lane from arguing with itself: recognition
    /// reads the SAME fill `CompositionCoach` judged the frame by
    /// (`FrameContext.judgedFill`). Driven through the real coach, so the two
    /// answers come from the code that actually ships.
    ///
    /// Asserted with the publish-crop guide ON, because that is the ONLY
    /// configuration where `judgedFill` and the whole-frame fill differ — and
    /// so the only one where a layer picking its own number would produce
    /// "Too tight — step back a touch" beside "Light and framing match the
    /// before". (The underlying whole-frame-vs-crop skew is pre-existing and
    /// written up in docs/camera-tuning-bench.md; this pins CONSISTENCY, not
    /// that the shared number is the right one.)
    @Test func recognitionAndTheCoachAlwaysReadTheSameFill() throws {
        let before = stamp(fill: 0.45)
        let band = try #require(BeforeShotMeasure.pairFillBand(of: before, isDetail: false))
        let crop = PublishCrop.feedRect
        let expects = ShotExpectations.portrait.matchingFraming(of: before)

        // A frame the coach calls TOO TIGHT inside the crop must not be
        // recognized as a pair, even though its WHOLE-FRAME fill is in band.
        let wholeFrameFill = 0.45
        let cropFill = min(1.0, wholeFrameFill / crop.width)
        #expect(band.contains(wholeFrameFill), "fixture no longer exercises the disagreement")
        #expect(!band.contains(cropFill), "fixture no longer exercises the disagreement")

        let ctx = FrameContext(
            avgLuma: 0.5, faceBounds: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.4),
            faceLuma: 0.5, backgroundLuma: 0.5, sharpness: 1, backgroundClutter: 0,
            subjectFill: wholeFrameFill, cropGuide: crop, cropSubjectFill: cropFill,
            pose: nil, deviceTilt: 0, color: nil, expectations: expects)
        let signal = CompositionCoach().evaluate(ctx)
        #expect(signal.moment == .compositionTooClose,
                "the coach no longer calls this too tight — re-derive the fixture")

        // Recognition, handed the coach's OWN number, agrees with it.
        let verdict = BeforePair.verdict(
            live: reading(), target: reading(), noun: "before",
            pairing: before, liveFill: ctx.judgedFill, isDetail: false)
        #expect(!verdict.paired,
                "recognition disagreed with the tip on screen: “\(signal.message ?? "")” beside “\(verdict.label)”")
    }

    /// The line is a FACT the app measured, not a feeling. Pinned because the
    /// north star rules out simulated emotion ahead of everything else, and
    /// this is the one moment in the coach's vocabulary most able to drift
    /// into it.
    @Test func theRecognitionLineNamesWhatMatchedAndPraisesNobody() {
        let line = BeforePair.pairedLabel
        #expect(line.lowercased().contains("light"))
        #expect(line.lowercased().contains("framing"))
        for flattery in ["great", "perfect", "amazing", "you're", "well done", "nice work"] {
            #expect(!line.lowercased().contains(flattery), "“\(line)” praises rather than reports")
        }
    }
}

@Suite struct BeforePairAnnouncerTests {
    private let matched = BeforePair.Verdict(
        label: "Light matches the before", ok: true, paired: false,
        moment: .lightMatched, noun: "before")
    private let paired = BeforePair.Verdict(
        label: BeforePair.pairedLabel, ok: true, paired: true,
        moment: .pairedWithBefore, noun: "before")
    private let mismatched = BeforePair.Verdict(
        label: "Brighter than the before — dim a touch", ok: false, paired: false,
        moment: .lightBrighterThan, noun: "before")

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000)

    /// The case the whole step exists for: the pro fixes the light, and moves
    /// in TEN SECONDS LATER. Firing on the light verdict alone would say
    /// "light matches" and then never mention that the pair landed.
    @Test func parityReachedInTwoMovesIsStillRecognized() {
        var announcer = BeforePairAnnouncer()
        #expect(announcer.announcement(for: mismatched, now: t0) != nil)
        #expect(announcer.announcement(for: matched, now: t0 + 4)?.moment == .lightMatched)
        #expect(announcer.announcement(for: paired, now: t0 + 14)?.moment == .pairedWithBefore)
    }

    /// …and it is said ONCE. Recognition on every matching frame would be a
    /// nag wearing a compliment's clothes.
    @Test func aSteadyPairIsRecognizedExactlyOnce() {
        var announcer = BeforePairAnnouncer()
        _ = announcer.announcement(for: matched, now: t0)
        #expect(announcer.announcement(for: paired, now: t0 + 1) != nil)
        for step in 2...60 {
            #expect(announcer.announcement(for: paired, now: t0 + Double(step)) == nil,
                    "recognized again at +\(step)s")
        }
    }

    /// A frame hovering on the edge of the before's fill band re-crosses it
    /// over and over. The floor `settleLineMinInterval` already exists for is
    /// what stops that becoming a stutter.
    @Test func reCrossingTheBandIsFlooredBySettleLineMinInterval() {
        var announcer = BeforePairAnnouncer()
        _ = announcer.announcement(for: matched, now: t0)
        #expect(announcer.announcement(for: paired, now: t0 + 1) != nil)
        let floor = CoachTuning.settleLineMinInterval
        // Out and back in, well inside the floor — silent.
        #expect(announcer.announcement(for: matched, now: t0 + 2) == nil)
        #expect(announcer.announcement(for: paired, now: t0 + 3) == nil)
        // Out and back in once the floor has elapsed — said again.
        #expect(announcer.announcement(for: matched, now: t0 + floor) == nil)
        #expect(announcer.announcement(for: paired, now: t0 + floor + 2) != nil)
    }

    /// Dropping out of parity says NOTHING. The framing rung's own tip is what
    /// the pro needs then; re-announcing "light matches" underneath it would
    /// be the coach talking about the half that isn't the problem.
    @Test func losingParityIsSilent() {
        var announcer = BeforePairAnnouncer()
        _ = announcer.announcement(for: matched, now: t0)
        _ = announcer.announcement(for: paired, now: t0 + 1)
        #expect(announcer.announcement(for: matched, now: t0 + 2) == nil)
    }

    /// The light half's behaviour is unchanged by this step: it fires on a
    /// change of its verdict and never on a steady state.
    @Test func theLightHalfStillFiresOnlyOnAChange() {
        var announcer = BeforePairAnnouncer()
        #expect(announcer.announcement(for: matched, now: t0)?.moment == .lightMatched)
        #expect(announcer.announcement(for: matched, now: t0 + 1) == nil)
        #expect(announcer.announcement(for: mismatched, now: t0 + 2)?.ok == false)
        #expect(announcer.announcement(for: mismatched, now: t0 + 3) == nil)
        // A different mismatch under the same verdict is not a new thing to
        // say — the coach's own tip is already naming the fix.
        let cooler = BeforePair.Verdict(label: "Cooler than the before — warm the light",
                                        ok: false, paired: false,
                                        moment: .lightCoolerThan, noun: "before")
        #expect(announcer.announcement(for: cooler, now: t0 + 4) == nil)
    }

    /// Light and framing landing on the SAME frame is one piece of good news,
    /// not two: the recognition is said, and no second line follows it.
    @Test func lightAndFramingLandingTogetherSaysThePairLineOnce() {
        var announcer = BeforePairAnnouncer()
        #expect(announcer.announcement(for: mismatched, now: t0) != nil)
        #expect(announcer.announcement(for: paired, now: t0 + 1)?.moment == .pairedWithBefore)
        #expect(announcer.announcement(for: paired, now: t0 + 2) == nil)
        // …and the floor started at the recognition, not before it.
        #expect(announcer.announcement(for: matched, now: t0 + 3) == nil)
        #expect(announcer.announcement(for: paired, now: t0 + 4) == nil)
    }

    /// KNOWN LIMITATION, pinned so it stays visible rather than becoming a
    /// surprise: a light verdict flickering across its own tolerance
    /// re-announces on every crossing. That is exactly what ships TODAY —
    /// this step inherits it and does not worsen it (the same number of lines,
    /// with the matched side now naming the pair). Flooring this path would
    /// mean suppressing today's light lines, which is not this step's to
    /// change; the FRAMING re-cross, which is the new way in, IS floored.
    @Test func aFlickeringLightVerdictStillReAnnouncesJustAsItDoesToday() {
        var announcer = BeforePairAnnouncer()
        for step in 0..<4 {
            #expect(announcer.announcement(for: mismatched,
                                           now: t0 + Double(step * 2)) != nil)
            #expect(announcer.announcement(for: paired,
                                           now: t0 + Double(step * 2 + 1)) != nil)
        }
    }

    /// …and that path still starts the floor, so a light flicker followed by a
    /// FRAMING re-cross does not stack a second recognition on top of it.
    @Test func theLightPathStillArmsTheFloorForTheFramingReCross() {
        var announcer = BeforePairAnnouncer()
        #expect(announcer.announcement(for: mismatched, now: t0) != nil)
        #expect(announcer.announcement(for: paired, now: t0 + 1) != nil)
        #expect(announcer.announcement(for: matched, now: t0 + 2) == nil)
        #expect(announcer.announcement(for: paired, now: t0 + 3) == nil)
    }

    /// A different BEFORE is a different pair — the next guided step, or a
    /// manual cycle through the references — so recognition re-arms.
    @Test func aNewPairingReArmsTheRecognition() {
        var announcer = BeforePairAnnouncer()
        _ = announcer.announcement(for: matched, now: t0)
        #expect(announcer.announcement(for: paired, now: t0 + 1) != nil)
        announcer.newPairing()
        // Still floored: cycling references cannot fire the line over and over.
        #expect(announcer.announcement(for: paired, now: t0 + 2) == nil)
        announcer.newPairing()
        #expect(announcer.announcement(for: paired,
                                       now: t0 + CoachTuning.settleLineMinInterval + 2) != nil)
    }

    /// …and re-arming does NOT re-fire the light half. The light half's timing
    /// is not this step's to change.
    @Test func aNewPairingDoesNotReAnnounceTheLightHalf() {
        var announcer = BeforePairAnnouncer()
        #expect(announcer.announcement(for: matched, now: t0) != nil)
        announcer.newPairing()
        #expect(announcer.announcement(for: matched, now: t0 + 1) == nil)
    }
}

// Composition judged inside the crop that ships, framing parity taken from the
// booking's own before shot, and the virtual-camera zoom arithmetic.
//
// All three are threshold-free by construction: the crop is fixed geometry, the
// framing target IS the before's measured number, and the zoom factor is read
// off the device. Nothing here is waiting on the salon pass.
import CoreGraphics
import CoreMedia
import Testing
import TovisKit
@testable import Tovis

@Suite struct CameraCompositionTests {
    private func ctx(
        face: CGRect?,
        fill: Double?,
        cropFill: Double? = nil,
        crop: CGRect? = nil,
        expects: ShotExpectations = .portrait
    ) -> FrameContext {
        FrameContext(
            avgLuma: 0.47, faceBounds: face, faceLuma: 0.47, backgroundLuma: 0.47,
            sharpness: 0.6, backgroundClutter: 0, subjectFill: fill,
            cropGuide: crop, cropSubjectFill: cropFill,
            pose: nil, deviceTilt: 0,
            color: ColorSignal(mixed: 0, greenTint: 0, warmth: 0),
            expectations: expects)
    }

    // MARK: - The coach judges what ships (plan §2.4)

    /// The gap the crop guide has always drawn and the coach never knew about:
    /// a subject filling a comfortable third of the SENSOR frame fills much less
    /// of the 9:16 box the feed publishes — the crop takes a quarter of the
    /// width off. The coach used to call this frame perfectly composed.
    @Test func aFrameThatFillsTheSensorButNotTheFeedCropIsCaught() {
        let face = CGRect(x: 0.40, y: 0.20, width: 0.20, height: 0.18)
        // Fills 0.30 of the whole frame, but only 0.18 of the feed crop.
        let ignoringCrop = CompositionCoach().evaluate(ctx(face: face, fill: 0.30))
        #expect(ignoringCrop.message == nil)   // passes against the sensor frame

        let judgingCrop = CompositionCoach().evaluate(
            ctx(face: face, fill: 0.30, cropFill: 0.18, crop: PublishCrop.feedRect))
        #expect(judgingCrop.message == "Move in closer — fill the frame")
        // …and it says WHY it disagrees with what the pro can see.
        #expect(judgingCrop.why?.contains("9:16") == true)
    }

    /// The subject is in the picture the pro is looking at and will not be in
    /// the one that ships. That is its own nameable problem, not "centre them".
    @Test func aSubjectOutsideTheFeedCropIsNamedAsSuch() {
        let offToTheSide = CGRect(x: 0.02, y: 0.20, width: 0.14, height: 0.16)
        let signal = CompositionCoach().evaluate(
            ctx(face: offToTheSide, fill: 0.30, cropFill: 0.30, crop: PublishCrop.feedRect))
        #expect(signal.message == "They’re outside the feed crop — center them")
    }

    /// Centering is judged in the crop's own space, so a face that reads as
    /// "on a third" of the sensor may be nearly centred once published.
    @Test func centeringIsMeasuredInTheCropsOwnSpace() {
        // midX 0.25 in frame space → (0.25 − 0.125) / 0.75 = 0.1667 in crop
        // space: further from center, not closer. The crop makes the miss worse.
        let leftOfThird = CGRect(x: 0.18, y: 0.20, width: 0.14, height: 0.16)
        let framed = CompositionCoach().evaluate(ctx(face: leftOfThird, fill: 0.5))
        let cropped = CompositionCoach().evaluate(
            ctx(face: leftOfThird, fill: 0.5, cropFill: 0.5, crop: PublishCrop.feedRect))
        #expect(framed.message == nil)                       // near the left third
        #expect(cropped.message == "Center them")             // not once published
    }

    @Test func withTheCropGuideOffNothingChanges() {
        let face = CGRect(x: 0.40, y: 0.20, width: 0.20, height: 0.18)
        let signal = CompositionCoach().evaluate(ctx(face: face, fill: 0.30, crop: nil))
        #expect(signal.message == nil)
    }

    // MARK: - Framing parity from the booking's own before shot (plan §2.3)

    private func stamp(fill: Double?) -> BeforeShotStamp {
        BeforeShotStamp(luma: 0.5, warmth: 0.0, backgroundLuma: 0.5,
                        backgroundWarmth: 0.0, subjectFill: fill, faceBounds: nil)
    }

    /// Shooting the before tight and the after loose is the most-cited
    /// before/after mistake — the brain reads "the after looks bigger because
    /// it IS bigger". The after's band is now the before's own measured fill.
    @Test func theAfterInheritsTheBeforesMeasuredFraming() {
        let tightBefore = ShotExpectations.portrait.matchingFraming(of: stamp(fill: 0.62))
        #expect(tightBefore.fillBand == 0.5...0.74)
        // The generic portrait band would have accepted anything from 0.22.
        #expect(ShotExpectations.portrait.fillBand == 0.22...0.85)

        // An after framed to the GENERIC band but far looser than the before is
        // now caught, where before it passed.
        let loose = CompositionCoach().evaluate(ctx(face: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.18),
                                                    fill: 0.30, expects: tightBefore))
        #expect(loose.message == "Move in closer — fill the frame")
    }

    @Test func detailStepsAndUnmeasurableBeforesAreLeftAlone() {
        // A close-up of the work has no framing pair to match.
        #expect(ShotExpectations.detail.matchingFraming(of: stamp(fill: 0.62)).fillBand == nil)
        // A before with no segmentable subject can't set a target.
        #expect(ShotExpectations.portrait.matchingFraming(of: stamp(fill: nil)).fillBand
                    == ShotExpectations.portrait.fillBand)
        // Neither can a subject that barely registered.
        #expect(BeforeShotMeasure.fillBand(matching: 0.01) == nil)
    }

    @Test func theBandIsClampedAtBothEnds() {
        let low = BeforeShotMeasure.fillBand(matching: 0.05)
        #expect(low?.lowerBound == 0.05)                       // clamped, not −0.07
        #expect(abs((low?.upperBound ?? 0) - 0.17) < 1e-9)

        let high = BeforeShotMeasure.fillBand(matching: 0.95)
        #expect(abs((high?.lowerBound ?? 0) - 0.83) < 1e-9)
        #expect(high?.upperBound == 0.98)                      // clamped, not 1.07
    }

    @Test func matchingFramingPreservesEverythingElseAboutTheStep() {
        let step = ShotExpectations(face: .absent, fillBand: 0.22...0.9, isDetail: false,
                                    allowsClosedEyes: true,
                                    poseRules: [PoseRule(kind: .bothHandsVisible, params: [:], tip: "t")])
        let retargeted = step.matchingFraming(of: stamp(fill: 0.5))
        #expect(retargeted.face == .absent)
        #expect(retargeted.allowsClosedEyes)
        #expect(retargeted.poseRules.count == 1)
        #expect(retargeted.fillBand == 0.38...0.62)
    }

    // MARK: - The virtual camera keeps today's framing (plan §2.7)

    /// Adopting `builtInTripleCamera` for macro auto-switch and zoom is only
    /// safe if the default framing is unchanged — and on a triple camera zoom
    /// factor 1.0 is the ULTRA-WIDE, so taking the device without this would
    /// silently make every shot in the app 0.5×.
    @Test func aTripleCameraIsParkedOnItsWideConstituent() {
        // Constituents widest-first: [ultra, wide, tele]; switch-overs [2, 6].
        #expect(CameraController.wideAngleZoomFactor(wideIndex: 1,
                                                     switchOverFactors: [2, 6]) == 2)
    }

    @Test func aWideFirstDeviceNeedsNoZoomOffset() {
        // Dual camera: [wide, tele] — the wide IS constituent zero.
        #expect(CameraController.wideAngleZoomFactor(wideIndex: 0,
                                                     switchOverFactors: [2]) == 1)
        // A plain single wide-angle device reports no constituents at all.
        #expect(CameraController.wideAngleZoomFactor(wideIndex: 0,
                                                     switchOverFactors: []) == 1)
    }

    /// A device whose switch-over list doesn't line up with its constituents
    /// must fall back to today's framing rather than to an arbitrary zoom.
    @Test func inconsistentDeviceDataFallsBackToNoZoom() {
        #expect(CameraController.wideAngleZoomFactor(wideIndex: 2,
                                                     switchOverFactors: [2]) == 1)
        #expect(CameraController.wideAngleZoomFactor(wideIndex: 1,
                                                     switchOverFactors: [0]) == 1)
    }

    // MARK: - The still-size ceiling (the crash surface)

    // `AVCapturePhotoOutput.maxPhotoDimensions` is one of the few properties on
    // the entry path that answers a bad value with an ObjC exception rather than
    // an error — and Swift cannot catch those, so a wrong answer here is not a
    // degraded camera, it is the app dying the instant the pro taps it. The
    // choice therefore has to hold for ANY list a device hands over, not just
    // the tidy ascending one a single wide-angle camera happens to report.
    //
    // Virtual devices (triple / dual-wide, adopted in #268) report richer and
    // differently-ordered lists than the wide-angle-only device this code was
    // written against, which is what makes the two rules below load-bearing now
    // when they were merely true before.

    private func dims(_ w: Int32, _ h: Int32) -> CMVideoDimensions {
        CMVideoDimensions(width: w, height: h)
    }

    /// 🔴 The list is NOT promised in ascending order. Picking "the last one
    /// under the cap" quietly means "the last one under the cap that happens to
    /// sit before a bigger one", so a device that reports 24 MP before 48 MP
    /// loses the 24 and ships 12 — the pro's stills silently halve in
    /// resolution with nothing anywhere saying so.
    @Test func theLargestAllowedSizeIsFoundWhateverOrderTheDeviceListsThem() {
        let unsorted = [dims(5712, 4284), dims(4032, 3024), dims(8064, 6048)]
        let chosen = CameraController.maxPhotoDimensions(for: unsorted)
        #expect(chosen?.width == 5712 && chosen?.height == 4284)
    }

    /// 🔴 When everything on offer is over the cap, the fallback must be the
    /// SMALLEST — the cap exists because full-sensor stills piled into the
    /// jetsam kills. Falling back to "whatever is listed first" can hand back
    /// the largest size on the device, i.e. the exact opposite of the cap.
    @Test func aDeviceWithNothingUnderTheCapFallsBackToItsSmallest() {
        let allTooBig = [dims(12000, 9000), dims(8064, 6048)]
        let chosen = CameraController.maxPhotoDimensions(for: allTooBig)
        #expect(chosen?.width == 8064 && chosen?.height == 6048)
    }

    /// Whatever comes back must be a size the format actually offers — a
    /// synthesized "capped" value is precisely what throws.
    @Test func theChosenSizeIsAlwaysOneTheFormatOffered() {
        let offered = [dims(4032, 3024), dims(5712, 4284), dims(8064, 6048)]
        let chosen = CameraController.maxPhotoDimensions(for: offered)
        #expect(offered.contains { $0.width == chosen?.width && $0.height == chosen?.height })
    }

    /// A format that offers nothing must leave the output's ceiling alone
    /// rather than assign a zero one.
    @Test func aFormatOfferingNothingLeavesTheCeilingUntouched() {
        #expect(CameraController.maxPhotoDimensions(for: []) == nil)
    }

    /// The number the coach SAYS has to be the number the geometry DOES.
    /// These drifted: the coach told the pro the feed crop takes "~40% of the
    /// width" while `feedRect` took 25%, and nothing connected the sentence to
    /// the arithmetic. Now something does.
    @Test func theCoachSaysTheFractionTheCropActuallyTakes() {
        let lost = 1 - PublishCrop.feedRect.width
        #expect(abs(lost - 0.25) < 1e-9)

        let tooFar = CompositionCoach().evaluate(
            ctx(face: CGRect(x: 0.44, y: 0.30, width: 0.06, height: 0.08),
                fill: 0.05, cropFill: 0.05, crop: PublishCrop.feedRect))
        guard let why = tooFar.why else {
            Issue.record("no `why` on the step-closer line — the copy under test never rendered")
            return
        }
        #expect(why.contains("a quarter of the width"),
                "the crop copy no longer states the fraction the geometry takes: “\(why)”")
        #expect(!why.contains("40%"))
    }
}

// MARK: - Before/after light matching on the background (plan §2.3)

/// The signal that used to punish the transformation. `lightMatch` compared
/// WHOLE-FRAME luma, so a dark-to-blonde colour service — the work itself —
/// moved the number past the tolerance and the coach told the pro to dim the
/// light about a job that had gone right.
@Suite struct LightMatchTests {
    private func reading(luma: Double, warmth: Double? = 0,
                         bgLuma: Double? = nil, bgWarmth: Double? = nil)
        -> LightMatch.Reading {
        LightMatch.Reading(luma: luma, warmth: warmth,
                           backgroundLuma: bgLuma, backgroundWarmth: bgWarmth)
    }

    /// THE CASE. The room is unchanged — background luma identical on both
    /// sides — but the client went from dark hair to blonde, which moves the
    /// whole-frame luma well past `lightMatchLumaTolerance` (0.08).
    @Test func aColourTransformationNoLongerReadsAsALightChange() {
        let before = reading(luma: 0.42, bgLuma: 0.55, bgWarmth: 0.02)
        let after = reading(luma: 0.58, bgLuma: 0.55, bgWarmth: 0.02)
        #expect(abs(after.luma - before.luma) > CoachTuning.lightMatchLumaTolerance)

        let verdict = LightMatch.verdict(live: after, target: before, noun: "before")
        #expect(verdict.ok)
        #expect(verdict.label == "Light matches the before")
    }

    /// …while the room's light genuinely changing is still caught.
    @Test func theRoomGettingBrighterIsStillCaught() {
        let before = reading(luma: 0.42, bgLuma: 0.45, bgWarmth: 0.02)
        let after = reading(luma: 0.42, bgLuma: 0.62, bgWarmth: 0.02)
        let verdict = LightMatch.verdict(live: after, target: before, noun: "before")
        #expect(!verdict.ok)
        #expect(verdict.label == "Brighter than the before — dim a touch")
    }

    @Test func theRoomGoingWarmIsCaughtAndNamedSeparately() {
        let before = reading(luma: 0.5, bgLuma: 0.5, bgWarmth: 0.00)
        let after = reading(luma: 0.5, bgLuma: 0.5, bgWarmth: 0.20)
        #expect(LightMatch.verdict(live: after, target: before, noun: "before").label
                    == "Warmer than the before — cool the light")
    }

    /// Mixing scopes would invent a mismatch: a background luma and a
    /// whole-frame luma are different quantities. When either side has no mask,
    /// both fall back to the whole frame — the old behaviour, honestly applied.
    @Test func aMissingMaskOnEitherSideFallsBackToWholeFrameOnBothSides() {
        let before = reading(luma: 0.42, bgLuma: nil)          // before had no mask
        let after = reading(luma: 0.44, bgLuma: 0.90)          // live does
        let verdict = LightMatch.verdict(live: after, target: before, noun: "before")
        // 0.44 vs 0.42 is inside tolerance; had it compared 0.90 against 0.42
        // it would have shouted about a light change that isn't there.
        #expect(verdict.ok)
    }

    @Test func noWarmthReadingIsTreatedAsMatchedNotAsAMismatch() {
        let before = reading(luma: 0.5, warmth: nil, bgLuma: 0.5, bgWarmth: nil)
        let after = reading(luma: 0.5, warmth: nil, bgLuma: 0.5, bgWarmth: nil)
        #expect(LightMatch.verdict(live: after, target: before, noun: "before").ok)
    }

    @Test func theNounFollowsWhatIsBeingMatched() {
        let r = reading(luma: 0.5, bgLuma: 0.5, bgWarmth: 0)
        #expect(LightMatch.verdict(live: r, target: r, noun: "reference").label
                    == "Light matches the reference")
    }
}

// The coach's SCORING ARITHMETIC — what combinations of ordinary imperfections
// can still reach the green ring, and which tip wins the one on-screen line.
//
// The perception THRESHOLDS in CoachTuning need a device (the file says so).
// The arithmetic on top of them does not, and it is where the "coach isn't
// helping me" behavior is decided. These tests pin the numbers a device pass
// would otherwise silently invalidate.
//
// Measured against 23 real photographs (see docs/camera-tuning-bench.md); the
// values here are the shipping thresholds' actual consequences, not targets.
import CoreGraphics
import Testing
@testable import Tovis

@Suite struct CoachReadinessTests {
    private let coaches: [ShotCoach] = [
        LightingCoach(), CompositionCoach(), SharpnessCoach(),
        BackgroundCoach(), PoseCoach(), LevelCoach(), ColorCoach(),
    ]

    /// A well-framed portrait: face centered with headroom, subject filling ~half.
    private let face = CGRect(x: 0.35, y: 0.15, width: 0.30, height: 0.25)
    private var pose: PoseSignal {
        PoseSignal(edgeClipped: false, joints: [
            .leftShoulder: CGPoint(x: 0.32, y: 0.48),
            .rightShoulder: CGPoint(x: 0.68, y: 0.48),
            .neck: CGPoint(x: 0.5, y: 0.44),
            .nose: CGPoint(x: 0.5, y: 0.28),
        ])
    }

    private func ctx(
        luma: Double = 0.47,      // CoachTuning.lumaIdeal
        faceLuma: Double? = nil,  // defaults to `luma` — face and room agree
        backgroundLuma: Double? = nil,
        sharpness: Double = 0.6,  // scores a clean 1.0
        mixed: Double = 0.0,
        warmth: Double = 0.15,
        tilt: Double = 0.0,
        clutter: Double = 0.0,
        fill: Double = 0.5
    ) -> FrameContext {
        FrameContext(
            avgLuma: luma, faceBounds: face, faceLuma: faceLuma ?? luma,
            backgroundLuma: backgroundLuma, sharpness: sharpness,
            backgroundClutter: clutter, subjectFill: fill, pose: pose, deviceTilt: tilt,
            color: ColorSignal(mixed: mixed, greenTint: 0, warmth: warmth),
            expectations: .portrait
        )
    }

    // MARK: - Ceiling

    @Test func aFlawlessPortraitNowActuallyScoresOne() {
        let v = CoachAggregate.evaluate(coaches, ctx())
        // `PoseCoach` used to return 0.9 the moment a body was detected — with
        // no message — which in a portrait session is always: a permanent 0.06
        // readiness tax the pro could never clear and was never told about. A
        // coach with nothing to say now scores like one.
        #expect(abs(v.readiness - 1.0) < 1e-6)
        #expect(v.readiness >= CoachTuning.readyThreshold)
        #expect(v.readiness >= CoachTuning.harvestThreshold)
        #expect(v.nudge == nil)
    }

    // MARK: - How much ordinary imperfection fits under the gate

    @Test func twoOrdinarySalonConditionsStayGreenAndFourDoNot() {
        // Each of these is a condition a working salon routinely presents, not
        // operator error: mixed light, a busy backdrop, a hand-held few degrees
        // off level, and a frame that is a touch soft.
        let mixedOnly = CoachAggregate.evaluate(coaches, ctx(mixed: 0.20))
        let plusBusyBg = CoachAggregate.evaluate(coaches, ctx(mixed: 0.20, clutter: 0.70))
        let plusOffLevel = CoachAggregate.evaluate(coaches, ctx(mixed: 0.20, tilt: 3.5, clutter: 0.70))
        let plusSoft = CoachAggregate.evaluate(coaches, ctx(sharpness: 0.30, mixed: 0.20,
                                                            tilt: 3.5, clutter: 0.70))

        #expect(mixedOnly.readiness >= CoachTuning.readyThreshold)
        #expect(plusBusyBg.readiness >= CoachTuning.readyThreshold)
        #expect(plusOffLevel.readiness >= CoachTuning.readyThreshold)
        // The fourth ordinary condition drops it out of the green ring entirely —
        // auto-capture stops firing and the ring sits amber.
        #expect(plusSoft.readiness < CoachTuning.readyThreshold)
        #expect(plusSoft.readiness >= CoachTuning.readyWarnThreshold)
    }

    /// The green ring and the Session Reel disagree in an ordinary salon: the
    /// shot reads "good to shoot" while nothing is ever harvested.
    @Test func aFrameCanBeGreenAndStillNeverHarvest() {
        let v = CoachAggregate.evaluate(coaches, ctx(mixed: 0.20, tilt: 3.5, clutter: 0.70))
        #expect(v.readiness >= CoachTuning.readyThreshold)   // ring is green
        #expect(v.readiness < CoachTuning.harvestThreshold)  // reel collects nothing
    }

    // MARK: - Which tip wins the one on-screen line
    //
    // `deficit` no longer PICKS the surfaced tip — sequential focus coaching
    // (docs/design, 2026-08-06) locks onto the earliest broken rung of a
    // fixed big-to-small order instead (`CoachTipArbiter` / `FocusRung`).
    // It's still exactly what READINESS (the ring) is the weighted mean of,
    // which is what these arithmetic assertions below actually pin.

    /// Where the mixed-light penalty sits in the READINESS weighting.
    /// `ColorCoach` scores 0.45 on mixed light at weight 1.1 → deficit 0.605,
    /// which drags the ring down more than every other coach's shortfall
    /// except an outright lighting failure or a clearly soft frame.
    @Test func mixedLightOutranksEveryTipExceptHardLightOrFocusFailure() {
        let mixedLight = CoachAggregate.deficit(.color, CoachSignal(score: 0.45, message: "x"))

        // Loses only to the two genuine failures.
        #expect(CoachAggregate.deficit(.lighting, CoachSignal(score: 0.40, message: "x")) > mixedLight)
        #expect(CoachAggregate.deficit(.sharpness, CoachSignal(score: 0.30, message: "x")) > mixedLight)

        // Beats everything else — including a soft frame and a clearly tilted camera.
        #expect(mixedLight > CoachAggregate.deficit(.sharpness, CoachSignal(score: 0.60, message: "x")))
        #expect(mixedLight > CoachAggregate.deficit(.level, CoachSignal(score: 0.40, message: "x")))
        #expect(mixedLight > CoachAggregate.deficit(.composition, CoachSignal(score: 0.45, message: "x")))
        #expect(mixedLight > CoachAggregate.deficit(.background, CoachSignal(score: 0.50, message: "x")))
        #expect(mixedLight > CoachAggregate.deficit(.pose, CoachSignal(score: 0.50, message: "x")))
    }

    /// The frame is amber because it is SOFT, but the one line the pro is
    /// shown tells them to turn off the overheads. Both problems are real —
    /// color comes before sharpness on the focus ladder (fixing the room's
    /// light is the bigger adjustment; holding the shot still for a crisp
    /// capture is the last, finest step), so it's what the pro hears about,
    /// even though sharpness is what's actually failing THIS frame.
    @Test func theCoachTalksAboutLightWhileTheFrameIsFailingOnFocus() {
        let v = CoachAggregate.evaluate(coaches, ctx(sharpness: 0.30, mixed: 0.20,
                                                     tilt: 3.5, clutter: 0.70))
        #expect(v.readiness < CoachTuning.readyThreshold)

        // Focus really is broken this frame…
        let sharpness = v.statuses.first { $0.category == .sharpness }
        #expect(sharpness?.message != nil)

        // …but the single surfaced line is about the colour of the light.
        #expect(v.nudge?.category == .color)
        #expect(v.nudge?.message == "Mixed light — turn off the overheads")
    }

    // MARK: - Guards on the structural caps

    /// The silent pose cap is gone: a detected body with nothing wrong with it
    /// costs exactly the same as no body at all. An unexplained standing
    /// penalty the pro can't clear and isn't told about is a bug either way —
    /// and it was the difference between a portrait session that could reach
    /// the harvest gate and one that couldn't.
    @Test func detectingABodyNoLongerCostsReadiness() {
        let withBody = CoachAggregate.evaluate(coaches, ctx())
        let noBody = CoachAggregate.evaluate(coaches, FrameContext(
            avgLuma: 0.47, faceBounds: face, faceLuma: 0.47, sharpness: 0.6,
            backgroundClutter: 0, subjectFill: 0.5, pose: nil, deviceTilt: 0,
            color: ColorSignal(mixed: 0, greenTint: 0, warmth: 0.15),
            expectations: .portrait))

        #expect(abs(noBody.readiness - withBody.readiness) < 1e-6)
        #expect(abs(withBody.readiness - 1.0) < 1e-6)
        #expect(noBody.nudge == nil && withBody.nudge == nil)
        // A pose the coach DOES have something to say about still costs.
        let clipped = CoachAggregate.evaluate(coaches, FrameContext(
            avgLuma: 0.47, faceBounds: face, faceLuma: 0.47, sharpness: 0.6,
            backgroundClutter: 0, subjectFill: 0.5,
            pose: PoseSignal(edgeClipped: true, joints: pose.joints), deviceTilt: 0,
            color: ColorSignal(mixed: 0, greenTint: 0, warmth: 0.15),
            expectations: .portrait))
        #expect(clipped.readiness < withBody.readiness)
        #expect(clipped.nudge?.category == .pose)
    }

    // MARK: - Exposure is judged on the SKIN, not the room (plan §2.1)

    /// The headline failure the relocation exists for: the face is
    /// under-exposed while the ROOM average sits comfortably inside the band,
    /// so nothing in the stack ever said "their face is dark". The frame
    /// passed, the ring went green, and the photo was wrong — and the failure
    /// is not evenly distributed, because whole-frame luma is least
    /// representative of the subject exactly when the subject is darker than
    /// their surroundings.
    @Test func anUnderexposedFaceIsNamedEvenWhenTheRoomAverageLooksFine() {
        // Room reads 0.30 — above `lumaTooDark`, so the old whole-frame rule
        // said nothing at all. The face is at 0.20, below it.
        let v = CoachAggregate.evaluate(coaches, ctx(luma: 0.30, faceLuma: 0.20,
                                                     backgroundLuma: 0.30))
        #expect(v.nudge?.category == .lighting)
        #expect(v.nudge?.message == "Their face is too dark — turn them toward the light")

        // The same frame judged the old way — face luma standing in for the
        // whole frame, i.e. no relocation — passes silently.
        let asRoom = LightingCoach().evaluate(ctx(luma: 0.30, faceLuma: 0.30,
                                                  backgroundLuma: 0.30))
        #expect(asRoom.message == nil)
        // …and it costs real readiness, where before it cost none.
        let unrelocated = CoachAggregate.evaluate(coaches, ctx(luma: 0.30, faceLuma: 0.30,
                                                               backgroundLuma: 0.30))
        #expect(unrelocated.readiness - v.readiness > 0.09)
    }

    /// ⚠️ A finding this exposes, pinned for the salon pass because it is the
    /// thing that decides whether naming the problem is ENOUGH.
    ///
    /// An outright lighting failure, alone, does not drop the frame out of the
    /// green ring — and does not even fall short of the harvest gate. Lighting
    /// is the heaviest coach and still only 1.6 of 7.5 total weight, so scoring
    /// it 0.3 costs 0.149, landing at 0.851: over `readyThreshold` (0.80) AND
    /// over `harvestThreshold` (0.85).
    ///
    /// So the coach now correctly says "their face is too dark" while
    /// auto-capture fires anyway and the Session Reel keeps the frame. Fixing
    /// that means moving `readyThreshold`, the lighting weight, or the failure
    /// score — all three of which the plan reserves for the device pass. This
    /// test states the consequence rather than quietly changing one.
    @Test func aLightingFailureAloneStillClearsBothTheRingAndTheHarvestGate() {
        let v = CoachAggregate.evaluate(coaches, ctx(luma: 0.30, faceLuma: 0.20,
                                                     backgroundLuma: 0.30))
        #expect(v.nudge?.category == .lighting)
        #expect(abs(v.readiness - 0.851) < 0.002)
        #expect(v.readiness >= CoachTuning.readyThreshold)
        #expect(v.readiness >= CoachTuning.harvestThreshold)
    }

    /// ⚠️ THE DIRECTION THE SALON PASS MUST SET, pinned so it can't surprise
    /// anyone. Moving the backlit comparison off the whole frame and onto the
    /// segmented background makes the rule MORE sensitive at the current
    /// `backlitFaceRatio`, not less: the background is brighter than a frame
    /// average the darker subject was dragging down, so `background × ratio` is
    /// a higher bar to clear than `frame × ratio`.
    ///
    /// The relocation is still right — face-vs-background is what "the light is
    /// behind them" actually means — but it is a structural fix, NOT a fix for
    /// the deep-complexion false positive. No ratio of skin reflectance to
    /// background illumination separates "less light on their face" from "less
    /// light coming back off their face". Only §3.1's per-complexion
    /// measurement does, and until it lands `backlitFaceMaxLuma` is the cap.
    @Test func relocatingTheBacklitTestMakesItMoreSensitiveNotLess() {
        // Face 0.24, background 0.42, whole frame 0.36 (the darker subject
        // pulls the average below the background).
        let faceLuma = 0.24, background = 0.42, frame = 0.36

        // Against the whole frame: 0.24 < 0.36 × 0.6 = 0.216 → false. Silent.
        #expect(!(faceLuma < frame * CoachTuning.backlitFaceRatio))
        // Against the background: 0.24 < 0.42 × 0.6 = 0.252 → true. It fires.
        #expect(faceLuma < background * CoachTuning.backlitFaceRatio)

        let signal = LightingCoach().evaluate(ctx(luma: frame, faceLuma: faceLuma,
                                                  backgroundLuma: background))
        #expect(signal.message == "Light’s behind them — turn them to face the window")
    }

    /// The absolute gate is what bounds the above until the ratio is measured:
    /// however much brighter the background is, a face that is not actually
    /// dark is never called backlit.
    @Test func abrightFaceIsNeverCalledBacklitHoweverBrightTheBackground() {
        let signal = LightingCoach().evaluate(ctx(luma: 0.60, faceLuma: 0.55,
                                                  backgroundLuma: 0.95))
        #expect(signal.message == nil)
        #expect(CoachTuning.backlitFaceMaxLuma == 0.4)   // the cap this relies on
    }

    /// With no segmentation there is no background to compare against, so the
    /// coach makes no backlit claim rather than making one from the frame
    /// average that contains the face. Silence beats a confident wrong answer.
    @Test func withoutAMaskTheCoachDeclinesToCallBacklight() {
        let noMask = ctx(luma: 0.55, faceLuma: 0.18, backgroundLuma: nil)
        let signal = LightingCoach().evaluate(noMask)
        #expect(signal.message != "Light’s behind them — turn them to face the window")
        // The face is genuinely under-exposed, and THAT is still said.
        #expect(signal.message == "Their face is too dark — turn them toward the light")
    }

    /// No face (flat-lay, nail detail, back-of-cut): the whole frame is the
    /// subject, and the old behaviour is exactly right there.
    @Test func withoutAFaceExposureFallsBackToTheWholeFrame() {
        let flatLay = FrameContext(
            avgLuma: 0.10, faceBounds: nil, faceLuma: nil, sharpness: 0.6,
            backgroundClutter: nil, subjectFill: nil, pose: nil, deviceTilt: 0,
            color: nil, expectations: .detail)
        #expect(LightingCoach().evaluate(flatLay).message == "Too dark — move toward the light")
    }

    /// LevelCoach is neutral without CoreMotion, so every reading taken on the
    /// Simulator is one coach short of the truth. Pinned so a device pass that
    /// changes it is a deliberate act.
    @Test func levelCoachIsNeutralWithoutMotionSoSimulatorScoresRunHigh() {
        let noMotion = FrameContext(
            avgLuma: 0.47, faceBounds: face, faceLuma: 0.47, sharpness: 0.6,
            backgroundClutter: 0, subjectFill: 0.5, pose: pose, deviceTilt: nil,
            color: ColorSignal(mixed: 0, greenTint: 0, warmth: 0.15),
            expectations: .portrait)

        #expect(LevelCoach().evaluate(noMotion).score == 1.0)
        #expect(LevelCoach().evaluate(noMotion).message == nil)
        // Same frame held 8° off level loses 0.08 readiness outright.
        let tilted = CoachAggregate.evaluate(coaches, ctx(tilt: 8))
        #expect(abs(CoachAggregate.evaluate(coaches, noMotion).readiness
                    - tilted.readiness - 0.08) < 1e-6)
    }
}

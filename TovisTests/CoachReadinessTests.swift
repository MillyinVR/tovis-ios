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
        sharpness: Double = 0.6,  // scores a clean 1.0
        mixed: Double = 0.0,
        warmth: Double = 0.15,
        tilt: Double = 0.0,
        clutter: Double = 0.0,
        fill: Double = 0.5
    ) -> FrameContext {
        FrameContext(
            avgLuma: luma, faceBounds: face, faceLuma: luma, sharpness: sharpness,
            backgroundClutter: clutter, subjectFill: fill, pose: pose, deviceTilt: tilt,
            color: ColorSignal(mixed: mixed, greenTint: 0, warmth: warmth),
            expectations: .portrait
        )
    }

    // MARK: - Ceiling

    @Test func aFlawlessPortraitClearsEveryGateButNeverScoresOne() {
        let v = CoachAggregate.evaluate(coaches, ctx())
        // PoseCoach caps at 0.9 whenever a body is detected — which, in a portrait
        // session, is always. So a perfect frame tops out just under 1.
        #expect(abs(v.readiness - 0.992) < 1e-6)
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

    /// Where the mixed-light penalty sits in the tip ranking. `ColorCoach` scores
    /// 0.45 on mixed light at weight 1.1 → deficit 0.605, which outranks every
    /// other coach's tip except an outright lighting failure or a clearly soft
    /// frame. Step 2 reduced the camera to ONE coach line, so whichever tip wins
    /// here is very nearly the whole coaching voice.
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

    /// The consequence: the frame is amber because it is SOFT, and the one line
    /// the pro is shown tells them to turn off the overheads. Both problems are
    /// real; the coach surfaces the one they usually cannot act on.
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

    /// `PoseCoach` returns 0.9 the moment a body is detected and 1.0 when none is.
    /// A portrait session therefore pays a permanent readiness tax that a
    /// flat-lay does not.
    @Test func detectingABodyPermanentlyCostsReadiness() {
        let withBody = CoachAggregate.evaluate(coaches, ctx())
        let noBody = CoachAggregate.evaluate(coaches, FrameContext(
            avgLuma: 0.47, faceBounds: face, faceLuma: 0.47, sharpness: 0.6,
            backgroundClutter: 0, subjectFill: 0.5, pose: nil, deviceTilt: 0,
            color: ColorSignal(mixed: 0, greenTint: 0, warmth: 0.15),
            expectations: .portrait))

        #expect(noBody.readiness > withBody.readiness)
        #expect(abs(noBody.readiness - 1.0) < 1e-6)
        #expect(noBody.nudge == nil && withBody.nudge == nil)
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

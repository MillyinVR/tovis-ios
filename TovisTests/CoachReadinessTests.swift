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
        fill: Double = 0.5,
        color: ColorSignal?? = nil  // outer nil = "build one from mixed/warmth"
    ) -> FrameContext {
        FrameContext(
            avgLuma: luma, faceBounds: face, faceLuma: faceLuma ?? luma,
            backgroundLuma: backgroundLuma, sharpness: sharpness,
            backgroundClutter: clutter, subjectFill: fill, pose: pose, deviceTilt: tilt,
            color: color ?? ColorSignal(mixed: mixed, greenTint: 0, warmth: warmth),
            expectations: .portrait
        )
    }

    // MARK: - The skin-filled close-up (B3)

    /// Eyes and brows filling the frame under NEUTRAL light. There is too
    /// little background left to read the colour of the light off, so
    /// `FrameMath.colorSignal` hands the coach nil. The ring has to be able to
    /// go green anyway — before this, the whole-frame fallback measured the
    /// client's skin, `ColorCoach` fired the warm-light line at 0.6, and the
    /// close-up could never reach `readyThreshold` however good it was.
    @Test func aCloseUpWithNoMeasurableLightSignalStillReachesGreen() {
        let unmeasurable = CoachAggregate.evaluate(
            coaches, ctx(fill: 0.97, color: .some(nil)))
        #expect(unmeasurable.readiness >= CoachTuning.readyThreshold)
        #expect(unmeasurable.statuses.first { $0.category == .color }?.score == 1.0)
        #expect(unmeasurable.statuses.first { $0.category == .color }?.message == nil)

        // The old behaviour, for contrast: the same frame with the whole-frame
        // warmth the fallback used to hand over.
        let skinReadAsRoom = CoachAggregate.evaluate(
            coaches,
            ctx(warmth: CoachTuning.warmCastWarmth + 0.1, fill: 0.97))
        #expect(skinReadAsRoom.statuses.first { $0.category == .color }?.score == 0.6)
        #expect(skinReadAsRoom.readiness < unmeasurable.readiness)
    }

    /// The nil is silence, not blanket permission: a frame that DOES have
    /// background to read, and reads warm off it, still says so.
    @Test func aMeasurableWarmRoomStillFiresTheWarmLightLine() {
        let warmRoom = CoachAggregate.evaluate(
            coaches, ctx(warmth: CoachTuning.warmCastWarmth + 0.1))
        let color = warmRoom.statuses.first { $0.category == .color }
        #expect(color?.score == 0.6)
        #expect(color?.moment == .colorWarm)
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

    // REWRITTEN 2026-08-23 (plan item 2, the backstop harvest). This pair
    // replaces the single test `aFrameCanBeGreenAndStillNeverHarvest`, which
    // pinned the band between `readyThreshold` and `harvestThreshold` as a
    // KNOWN DEFECT: an ordinary salon frame scored green, auto-capture fired on
    // it, and the Session Reel took nothing — so a pro could shoot a whole
    // session that read green from the first frame to the last and find an
    // empty tray at the end of it, when the session is over and unrepeatable.
    // The ARITHMETIC that puts the frame in the band is unchanged and still
    // worth pinning. What it COSTS is what changed, so the two are now separate
    // tests: one measurement, one promise.

    /// UNCHANGED, and meant to be: the ordinary-salon frame really does land
    /// between the green ring and the peak gate. That is a measurement of the
    /// coach weighting, not a defect — and it is the number that any future
    /// move of either threshold has to face.
    @Test func anOrdinarySalonFrameLandsBetweenTheRingAndThePeakGate() {
        let v = CoachAggregate.evaluate(coaches, ctx(mixed: 0.20, tilt: 3.5, clutter: 0.70))
        #expect(abs(v.readiness - 0.826) < 0.002)
        #expect(v.readiness >= CoachTuning.readyThreshold)    // the ring is green
        #expect(v.readiness < CoachTuning.harvestThreshold)   // and it is no peak
    }

    /// THE FIX, wired end to end — the real scored frame driving the real gate,
    /// so the scoring arithmetic and the harvest policy cannot drift apart
    /// while each stays green on its own. The frame the peak gate refuses is
    /// banked once the pro has held it as steady as the guided shutter itself
    /// requires, which is what makes the green ring's promise survive to the
    /// end of the session.
    @Test func theSameFrameIsBankedOnceTheHoldIsSteady() {
        let readiness = CoachAggregate.evaluate(
            coaches, ctx(mixed: 0.20, tilt: 3.5, clutter: 0.70)).readiness
        // The peak path alone still refuses it — that refusal IS the band.
        #expect(readiness < CoachTuning.harvestThreshold)

        var gate = CoachHarvestGate()
        // Green from the first frame, but a hold has to BE one before it counts.
        #expect(gate.shouldHarvest(readiness: readiness, now: 0) == .skip)
        // …and once it is, the reel takes it.
        #expect(gate.shouldHarvest(readiness: readiness,
                                   now: CoachTuning.autoCaptureHoldSeconds) == .steadyHold)
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

    // REWRITTEN 2026-08-23 (plan item 1.3). This pair replaces the single test
    // `theCoachTalksAboutLightWhileTheFrameIsFailingOnFocus`, which pinned the
    // behaviour as a KNOWN DEFECT: a frame failing on focus was shown "turn off
    // the overheads". `CoachSeverity` now lets a hard failure outrank its rung,
    // so that case is fixed — but only for a frame that is genuinely being
    // thrown away. The two tests below separate what changed from what did not,
    // because the old test conflated them: its frame was only a TOUCH soft
    // (sharpness 0.30 → `.sharpnessTapToFocus`, score 0.6), which is an ordinary
    // correction and still yields to colour, deliberately.

    /// UNCHANGED, and meant to be: a frame that is merely a touch soft is a
    /// correction, not a failure. The ladder's order stands — fixing the room's
    /// light is the bigger adjustment, and "tap to focus" is polish that waits
    /// its turn. Severity is not a back door for re-ranking ordinary tips.
    @Test func aTouchSoftFrameStillYieldsTheLineToTheRoomsLight() {
        let v = CoachAggregate.evaluate(coaches, ctx(sharpness: 0.30, mixed: 0.20,
                                                     tilt: 3.5, clutter: 0.70))
        #expect(v.readiness < CoachTuning.readyThreshold)

        // Sharpness is speaking up, at its gentle wording…
        let sharpness = v.statuses.first { $0.category == .sharpness }
        #expect(sharpness?.moment == .sharpnessTapToFocus)
        #expect(sharpness?.score == 0.6)

        // …and colour, earlier on the ladder, still owns the one line.
        #expect(v.nudge?.category == .color)
        #expect(v.nudge?.message == "Mixed light — turn off the overheads")
    }

    /// THE FIX. The same ordinary-salon frame, but now genuinely soft rather
    /// than a touch soft: motion blur no edit recovers. The photo is being
    /// thrown away, so telling the pro about the overheads is advice about a
    /// frame that no longer exists. A hard failure outranks its rung, and the
    /// coach says the thing that is actually losing the shot.
    @Test func aClearlySoftFrameTakesTheLineBackFromTheRoomsLight() {
        let v = CoachAggregate.evaluate(coaches, ctx(sharpness: 0.15, mixed: 0.20,
                                                     tilt: 3.5, clutter: 0.70))
        #expect(v.readiness < CoachTuning.readyThreshold)

        // Colour is still broken and still EARLIER on the ladder…
        let color = v.statuses.first { $0.category == .color }
        #expect(color?.message == "Mixed light — turn off the overheads")
        #expect(FocusRung.color < FocusRung.sharpness)

        // …and is nonetheless outranked, because this frame is unrecoverable.
        #expect(v.nudge?.category == .sharpness)
        #expect(v.nudge?.message == "Hold steady — shot looks soft")
    }

    // MARK: - Which signals are hard failures (plan item 1.3)

    /// The hard-failure SET, pinned deliberately. Severity is the one thing
    /// allowed to jump the focus ladder, so the only guard against it quietly
    /// growing into "everything that feels important" is a list somebody has to
    /// edit on purpose. The rule it encodes: a `.failure` is a frame no edit
    /// afterwards recovers — clipped highlights, an underexposed face that
    /// lifts into noise, motion blur. Everything else is a choice the next
    /// frame can make differently at no cost to the file.
    @Test func onlyAnUnrecoverableCaptureCountsAsAHardFailure() {
        // Unrecoverable — the three lighting failures and a genuinely soft frame.
        #expect(LightingCoach().evaluate(ctx(luma: 0.10, faceLuma: 0.10)).severity == .failure)
        #expect(LightingCoach().evaluate(ctx(luma: 0.90, faceLuma: 0.90)).severity == .failure)
        #expect(LightingCoach().evaluate(
            ctx(luma: 0.36, faceLuma: 0.24, backgroundLuma: 0.42)).severity == .failure)
        #expect(SharpnessCoach().evaluate(ctx(sharpness: 0.15)).severity == .failure)

        // Recoverable — every other corrective the coach can give, including
        // the GENTLE half of sharpness. Same rung, different verdict.
        #expect(SharpnessCoach().evaluate(ctx(sharpness: 0.30)).severity == .correction)
        #expect(ColorCoach().evaluate(ctx(mixed: 0.20)).severity == .correction)
        #expect(ColorCoach().evaluate(ctx(warmth: 0.50)).severity == .correction)
        #expect(LevelCoach().evaluate(ctx(tilt: 8)).severity == .correction)
        #expect(BackgroundCoach().evaluate(ctx(clutter: 0.90)).severity == .correction)
        #expect(CompositionCoach().evaluate(ctx(fill: 0.10)).severity == .correction)
        #expect(PoseCoach().evaluate(FrameContext(
            avgLuma: 0.47, faceBounds: face, faceLuma: 0.47, sharpness: 0.6,
            backgroundClutter: 0, subjectFill: 0.5,
            pose: PoseSignal(edgeClipped: true, joints: pose.joints), deviceTilt: 0,
            color: ColorSignal(mixed: 0, greenTint: 0, warmth: 0.15),
            expectations: .portrait)).severity == .correction)
    }

    /// A passing signal's severity is meaningless and must never be read as a
    /// failure — the arbiter only ever consults it for a rung it already knows
    /// is broken, and this keeps that assumption honest.
    @Test func aPassingSignalIsNeverAFailure() {
        #expect(LightingCoach().evaluate(ctx()).message == nil)
        #expect(LightingCoach().evaluate(ctx()).severity == .correction)
        #expect(SharpnessCoach().evaluate(ctx()).severity == .correction)
    }

    // MARK: - The backdrop coach can actually fire (plan item 1.2)
    //
    // Measured 2026-08-23 over the 21 corpus PORTRAITS — the only frames with a
    // segmented person, so the only ones with a real background to judge. Raw
    // area-normalized background edge energy ran 0.0000 … 0.0968, median
    // 0.0371. `clutterReference` was 0.18, putting the "busy" line at 0.108 —
    // above the busiest portrait in the corpus, so `BackgroundCoach` could not
    // fire on a portrait at all. These pin the tuning DECISION, not a target:
    // a future retune has to face the same numbers to move them.

    /// The measured portrait distribution, either side of the busy line: the
    /// busiest backdrop is now coachable, and an ordinary one still says
    /// nothing. The second half is the half that matters — `mixedLightSpread`
    /// became noise precisely by sitting ON the median of ordinary frames.
    @Test func theBusiestPortraitIsCoachableAndTheMedianOneIsStillSilent() {
        let medianPortrait = 0.0371, busiestPortrait = 0.0968
        func normalized(_ raw: Double) -> Double { min(1, raw / CoachTuning.clutterReference) }

        #expect(normalized(busiestPortrait) > CoachTuning.clutterBusy)
        #expect(normalized(medianPortrait) <= CoachTuning.clutterBusy)
        // The margin that keeps this from becoming the next mixedLightSpread:
        // "busy" sits at roughly TWICE the median portrait, not on top of it.
        let busyLine = CoachTuning.clutterBusy * CoachTuning.clutterReference
        #expect(busyLine > medianPortrait * 1.8)
    }

    /// End to end: the busiest measured portrait now reaches the pro as a line.
    /// A cluttered backdrop is a `.correction` — a few feet sideways fixes it,
    /// and the file is fine either way — so it must NOT jump the ladder.
    @Test func aBusyBackdropNowReachesTheProAsALine() {
        let busiest = 0.0968 / CoachTuning.clutterReference
        let signal = BackgroundCoach().evaluate(ctx(clutter: busiest))
        #expect(signal.message == "Busy background — find a cleaner backdrop")
        #expect(signal.severity == .correction)
    }

    /// What waking it costs, stated rather than discovered later: normalizing
    /// against a smaller reference raises every frame's clutter, so an ordinary
    /// portrait pays a little more readiness than it used to. About 0.01 — real,
    /// bounded, and worth knowing next to the 0.8/0.85 ring-vs-harvest band.
    @Test func wakingTheBackdropCoachCostsAMedianPortraitAboutAHundredth() {
        let medianPortrait = 0.0371
        let now = CoachAggregate.evaluate(
            coaches, ctx(clutter: min(1, medianPortrait / CoachTuning.clutterReference)))
        let before = CoachAggregate.evaluate(
            coaches, ctx(clutter: min(1, medianPortrait / 0.18)))   // the old reference

        let cost = before.readiness - now.readiness
        #expect(cost > 0.005 && cost < 0.015)
        #expect(now.nudge == nil, "an ordinary backdrop still says nothing at all")
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

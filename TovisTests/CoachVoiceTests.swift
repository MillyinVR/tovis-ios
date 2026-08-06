// The personality-pack guardrail from docs/design/camera-personality-packs.md
// §0, made concrete:
//
//   Personalities never change advice, timing thresholds, or metering logic —
//   only phrasing, energy, and chattiness level.
//
// Two suites: coverage (every new pack has a line for every moment, so none
// of them silently fall back to Calm Mentor text on a moment it "should
// own") and the guardrail itself (the SAME frame sequence, run under every
// personality, decides identically — only the rendered string differs).
import CoreGraphics
import Testing
@testable import Tovis

@Suite struct CoachVoiceCoverageTests {
    private let newPacks: [CoachVoice] = [
        HypeBestieVoice(), StraightShooterVoice(), EditorialDirectorVoice(), DragQueenBestieVoice(),
    ]

    @Test func everyMomentHasCopyInEveryNewPack() {
        for voice in newPacks {
            for moment in CoachMoment.allCases {
                let phrase = voice.phrase(for: moment, ctx: CoachPhraseContext())
                #expect(phrase != nil, "\(voice.displayName) has no line for \(moment)")
                #expect(phrase?.isEmpty == false, "\(voice.displayName) has an empty line for \(moment)")
            }
        }
    }

    /// Calm Mentor isn't in `newPacks` above on purpose: returning nil for
    /// every moment IS its byte-identical port (the renderer falls through
    /// to the canonical fallback, which is today's text unchanged) — not a
    /// coverage gap the way it would be for the four new packs.
    @Test func calmMentorDefersToTheCanonicalFallbackForEveryMoment() {
        let calmMentor = CalmMentorVoice()
        for moment in CoachMoment.allCases {
            #expect(calmMentor.phrase(for: moment, ctx: CoachPhraseContext()) == nil)
        }
    }

    @Test func everyPersonalityResolvesToADistinctVoice() {
        let ids = Set(CoachPersonality.allCases.map { $0.voice.id })
        #expect(ids.count == CoachPersonality.allCases.count)
    }
}

@Suite struct CoachVoiceGuardrailTests {
    private let coaches: [ShotCoach] = [
        LightingCoach(), CompositionCoach(), SharpnessCoach(),
        BackgroundCoach(), PoseCoach(), LevelCoach(), ColorCoach(),
    ]
    private let face = CGRect(x: 0.35, y: 0.15, width: 0.30, height: 0.25)
    private var pose: PoseSignal {
        PoseSignal(edgeClipped: false, joints: [
            .leftShoulder: CGPoint(x: 0.32, y: 0.48),
            .rightShoulder: CGPoint(x: 0.68, y: 0.48),
        ])
    }

    private func ctx(luma: Double = 0.47, faceLuma: Double? = nil, backgroundLuma: Double? = 0.5,
                     sharpness: Double = 0.6, mixed: Double = 0.0, clutter: Double = 0.0,
                     tilt: Double = 0.0, fill: Double = 0.5) -> FrameContext {
        FrameContext(avgLuma: luma, faceBounds: face, faceLuma: faceLuma ?? luma,
                    backgroundLuma: backgroundLuma, sharpness: sharpness,
                    backgroundClutter: clutter, subjectFill: fill, pose: pose, deviceTilt: tilt,
                    color: ColorSignal(mixed: mixed, greenTint: 0, warmth: 0.15),
                    expectations: .portrait)
    }

    /// A short session: clean → too dark → tilted → mixed light + busy
    /// background → backlit → clean again (lets a `cleared` event fire).
    /// Exercises every render site's underlying signal at least once.
    private func frames() -> [FrameContext] {
        [
            ctx(),
            // `backgroundLuma` explicit and equal to `faceLuma` — left at the
            // default (0.5) this reads as BACKLIT (0.10 < 0.5 × 0.6), not
            // too dark, which would make the "too dark" fixture below the
            // one actually exercising `lightingBacklit` instead.
            ctx(luma: 0.10, faceLuma: 0.10, backgroundLuma: 0.10),
            ctx(tilt: 8),
            ctx(mixed: 0.20, clutter: 0.70),
            ctx(luma: 0.36, faceLuma: 0.24, backgroundLuma: 0.42),
            ctx(),
        ]
    }

    private struct StatusSnapshot: Equatable {
        let category: CoachCategory
        let score: Double
        let message: String?
        let why: String?
        let moment: CoachMoment?
    }

    private struct FrameDecision: Equatable {
        let readiness: Double
        let nudgeCategory: CoachCategory?
        let nudgeMoment: CoachMoment?
        let cleared: CoachCategory?
        let statuses: [StatusSnapshot]
    }

    /// Runs the real decision pipeline — `CoachAggregate.evaluate` with a
    /// stateful `CoachTipArbiter`, exactly what `CoachEngine` calls per
    /// frame — over the fixture sequence. `personality` labels the run for
    /// the assertion below; `CoachAggregate`/`CoachTipArbiter` never see it,
    /// which is the architectural guarantee this test exists to pin.
    private func decide(personality: CoachPersonality) -> [FrameDecision] {
        var arbiter = CoachTipArbiter()
        return frames().enumerated().map { index, frame in
            let now = Double(index) * (CoachTuning.tipDwellSeconds + 1)
            let verdict = CoachAggregate.evaluate(coaches, frame, arbiter: &arbiter, now: now)
            return FrameDecision(
                readiness: verdict.readiness,
                nudgeCategory: verdict.nudge?.category,
                nudgeMoment: verdict.nudge?.moment,
                cleared: verdict.cleared,
                statuses: verdict.statuses.map {
                    StatusSnapshot(category: $0.category, score: $0.score, message: $0.message,
                                  why: $0.why, moment: $0.moment)
                })
        }
    }

    @Test func decisionsAreIdenticalAcrossEveryPersonality() {
        let baseline = decide(personality: .calmMentor)
        #expect(!baseline.isEmpty)
        for personality in CoachPersonality.allCases where personality != .calmMentor {
            #expect(decide(personality: personality) == baseline,
                   "\(personality) changed a DECISION, not just its wording")
        }
    }

    /// The other half of §0: personalities DO change the string. If every
    /// pack silently fell back to Calm Mentor text, the test above would be
    /// green for the wrong reason — this is what rules that out.
    @Test func personalitiesActuallyChangeTheRenderedLine() {
        let canonicalTooDark = "Their face is too dark — turn them toward the light"
        let canonicalHoldShooting = "Hold it — shooting"
        for personality in CoachPersonality.allCases where personality != .calmMentor {
            let tooDark = personality.voice.phrase(for: .lightingTooDark, ctx: CoachPhraseContext())
            let holdShooting = personality.voice.phrase(for: .laneHoldShooting, ctx: CoachPhraseContext())
            #expect(tooDark != nil && tooDark != canonicalTooDark)
            #expect(holdShooting != nil && holdShooting != canonicalHoldShooting)
        }
    }

    /// Straight Shooter is `.minimal` chattiness: `why` never rides along,
    /// by the `CoachVoice` default. The other three packs keep it.
    @Test func chattinessMatchesTheDesignDoc() {
        #expect(StraightShooterVoice().chattiness == .minimal)
        #expect(CalmMentorVoice().chattiness == .standard)
        #expect(EditorialDirectorVoice().chattiness == .standard)
        #expect(HypeBestieVoice().chattiness == .expressive)
        #expect(DragQueenBestieVoice().chattiness == .expressive)

        #expect(StraightShooterVoice().includesWhy(for: .lightingTooDark) == false)
        #expect(CalmMentorVoice().includesWhy(for: .lightingTooDark) == true)
        #expect(HypeBestieVoice().includesWhy(for: .lightingTooDark) == true)
    }
}

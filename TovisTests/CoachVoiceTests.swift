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
import TovisKit
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
            let now = Double(index) * (CoachTuning.focusStabilityWindow + 1)
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

/// Phase 4 (docs/design/camera-personality-packs.md §4, sites E–I): the same
/// §0 guardrail, for the copy sites that sit downstream of `ShotCoach` rather
/// than inside it. None of `PhotoQC.evaluate`, `LightMatch.verdict`, or
/// `ProCameraDestination`'s decision surface (`passed`, `sharpness`, `ok`,
/// `owesAPhoto`, `requirementMet`) takes a `CoachVoice` at all — personality
/// only reaches the STRING, at the render call downstream of the decision.
/// These tests pin that: the decision is fixed before a voice is ever
/// involved, and every new pack still renders a real line for it.
@Suite struct CoachVoicePhase4GuardrailTests {
    private let newPacks: [CoachVoice] = [
        HypeBestieVoice(), StraightShooterVoice(), EditorialDirectorVoice(), DragQueenBestieVoice(),
    ]

    // MARK: - E, PhotoQC

    /// `PhotoQCReport`'s decision fields don't mention `CoachVoice` in their
    /// type at all — this is the architectural guarantee, not just a runtime
    /// coincidence. Rendering `retakeMoment` for every personality must not
    /// touch `passed`/`sharpness`/`luma`/`focalPoint`.
    @Test func photoQCDecisionFieldsAreUnreachableFromAnyVoice() {
        let report = PhotoQCReport(retakeReason: "\("Their face") came out too dark",
                                   retakeMoment: .qcTooDark,
                                   retakePhraseCtx: CoachPhraseContext(subjectNoun: "Their face"),
                                   sharpness: 0.7, luma: 0.2, faceLuma: 0.2, eyesClosed: false, focalPoint: nil)
        for personality in CoachPersonality.allCases {
            _ = CoachVoiceRenderer.render(report.retakeMoment, fallback: report.retakeReason,
                                          ctx: report.retakePhraseCtx ?? CoachPhraseContext(),
                                          voice: personality.voice)
            #expect(report.sharpness == 0.7)
            #expect(report.luma == 0.2)
            #expect(report.focalPoint == nil)
            #expect(!report.passed)
        }
    }

    @Test func everyNewPackRendersEveryQCRetakeMoment() {
        for voice in newPacks {
            for moment in [CoachMoment.qcEyesClosed, .qcSoft, .qcTooDark, .qcBlownOut] {
                let phrase = voice.phrase(for: moment, ctx: CoachPhraseContext(subjectNoun: "It"))
                #expect(phrase?.isEmpty == false, "\(voice.displayName) has no line for \(moment)")
            }
        }
    }

    @Test func calmMentorLeavesTheQCReasonByteIdentical() {
        let canonical = "It came out soft"
        let report = PhotoQCReport(retakeReason: canonical, retakeMoment: .qcSoft,
                                   sharpness: 0.1, luma: 0.5, faceLuma: nil, eyesClosed: false, focalPoint: nil)
        let rendered = CoachVoiceRenderer.render(report.retakeMoment, fallback: report.retakeReason,
                                                 ctx: report.retakePhraseCtx ?? CoachPhraseContext(),
                                                 voice: CalmMentorVoice()) ?? report.retakeReason
        #expect(rendered == canonical)
    }

    // MARK: - F, BeforeShotMeasure.LightMatch

    /// `LightMatch.verdict`'s `ok` is decided before any voice renders
    /// `label` — proven by rendering the SAME verdict through all five
    /// personalities and confirming `ok` never moves.
    @Test func lightMatchOKIsIndependentOfVoice() {
        let before = LightMatch.Reading(luma: 0.42, warmth: 0.02, backgroundLuma: 0.55, backgroundWarmth: 0.02)
        let after = LightMatch.Reading(luma: 0.58, warmth: 0.02, backgroundLuma: 0.55, backgroundWarmth: 0.02)
        let verdict = LightMatch.verdict(live: after, target: before, noun: "before")
        for personality in CoachPersonality.allCases {
            let rendered = CoachVoiceRenderer.render(verdict.moment, fallback: verdict.label,
                                                      ctx: CoachPhraseContext(subjectNoun: "before"),
                                                      voice: personality.voice) ?? verdict.label
            #expect(!rendered.isEmpty)
        }
        #expect(verdict.ok)
        #expect(verdict.moment == .lightMatched)
    }

    @Test func everyNewPackRendersEveryLightMatchMoment() {
        for voice in newPacks {
            for moment in [CoachMoment.lightMatched, .lightBrighterThan, .lightDarkerThan,
                          .lightWarmerThan, .lightCoolerThan] {
                let phrase = voice.phrase(for: moment, ctx: CoachPhraseContext(subjectNoun: "before"))
                #expect(phrase?.isEmpty == false, "\(voice.displayName) has no line for \(moment)")
            }
        }
    }

    // MARK: - I, ProCameraDestination

    /// `owesAPhoto`/`requirementMet` never take a voice — the "what's owed"
    /// decision and the "how it's said" render are different call surfaces
    /// entirely. This pins that a session's decision is identical whichever
    /// voice later renders `guideNote`/`leavingWithoutTitle`.
    @Test func sessionDestinationDecisionIsIndependentOfVoice() {
        let destination = ProCameraDestination.session(bookingId: "bk_1", phase: .before)
        for personality in CoachPersonality.allCases {
            let note = destination.guideNote(requirementMet: true, voice: personality.voice)
            #expect(!note.isEmpty)
            #expect(destination.owesAPhoto)
            #expect(destination.requirementMet(captured: 1))
        }
    }

    @Test func calmMentorLeavesSessionDestinationCopyByteIdentical() {
        let destination = ProCameraDestination.session(bookingId: "bk_1", phase: .after)
        #expect(destination.guideNote(requirementMet: true) == ProSessionPhotoRequirement.metDetail(.after))
        #expect(destination.guideNote(requirementMet: false) == ProSessionPhotoRequirement.guideNote(.after))
        #expect(destination.leavingWithoutTitle() == ProSessionPhotoRequirement.leavingWithoutTitle(.after))
        #expect(destination.outstandingSentence() == ProSessionPhotoRequirement.outstandingSentence(.after))
    }

    @Test func everyNewPackRendersEverySessionAndPracticeMoment() {
        let momentsWithDetail: [CoachMoment] = [
            .sessionGuideNoteMet, .sessionGuideNoteOutstanding, .sessionOutstandingSentence,
            .leavingWithoutTitleSession,
        ]
        let momentsWithoutCtx: [CoachMoment] = [.practiceGuideNote, .leavingWithoutTitlePractice]
        for voice in newPacks {
            for moment in momentsWithDetail {
                let phrase = voice.phrase(for: moment, ctx: CoachPhraseContext(detail: "One before photo is required."))
                #expect(phrase?.isEmpty == false, "\(voice.displayName) has no line for \(moment)")
            }
            for moment in momentsWithoutCtx {
                let phrase = voice.phrase(for: moment, ctx: CoachPhraseContext())
                #expect(phrase?.isEmpty == false, "\(voice.displayName) has no line for \(moment)")
            }
        }
    }

    // MARK: - G/H, ShotGuide + ProCapturePhotosView announcements

    @Test func everyNewPackRendersEveryShotGuideAndAnnounceMoment() {
        let moments: [CoachMoment] = [
            .shotStepHint, .shotStepAnnounce, .shotCaptured, .trendingSetIntro,
            .matchingReferenceLook, .aiDirectionReady, .retakeConfirm, .retakeAnnounce,
        ]
        for voice in newPacks {
            for moment in moments {
                let phrase = voice.phrase(for: moment,
                                          ctx: CoachPhraseContext(subjectNoun: "Front", detail: "Square to the camera"))
                #expect(phrase?.isEmpty == false, "\(voice.displayName) has no line for \(moment)")
            }
        }
    }
}

/// Delivery (rate/pitch/lead-in) — the "make it sound natural, not robotic"
/// pass. Same tone-only guardrail as the words: `CoachEngine.speak` is the
/// only place these numbers are read, downstream of every decision, same as
/// `CoachVoiceRenderer`.
@Suite struct CoachVoiceSpeechDeliveryTests {
    private let allVoices: [CoachVoice] = [
        CalmMentorVoice(), HypeBestieVoice(), StraightShooterVoice(), EditorialDirectorVoice(), DragQueenBestieVoice(),
    ]

    @Test func everyPackHasSpeechParamsInValidAVSpeechRanges() {
        for voice in allVoices {
            #expect(voice.speechRateMultiplier > 0)
            #expect(voice.speechPitch >= 0.5 && voice.speechPitch <= 2.0)
            #expect(voice.preUtteranceDelay >= 0)
        }
    }

    @Test func packsAreDeliveredDistinctlyNotJustWordedDistinctly() {
        let rates = Set(allVoices.map { $0.speechRateMultiplier })
        let pitches = Set(allVoices.map { $0.speechPitch })
        #expect(rates.count > 1, "every pack speaking at the same rate defeats the point of tuning it per personality")
        #expect(pitches.count > 1)
    }

    /// The actual bug this whole pass exists to fix: flat default rate and
    /// neutral pitch with no lead-in is what made even warm WORDS read as a
    /// machine talking. Calm Mentor gets a deliberate delivery now, same as
    /// the other four — its TEXT is still the byte-identical launch pack.
    @Test func calmMentorNoLongerSpeaksAtTheBareSystemDefault() {
        let calm = CalmMentorVoice()
        #expect(calm.speechRateMultiplier != 1.0)
        #expect(calm.speechPitch != 1.0)
    }

    /// The two ends of the energy spectrum, concretely: Hype Bestie reads
    /// faster and brighter than Editorial Director's composed, lower pace.
    @Test func hypeBestieIsBriskerAndBrighterThanEditorialDirector() {
        let hype = HypeBestieVoice()
        let editorial = EditorialDirectorVoice()
        #expect(hype.speechRateMultiplier > editorial.speechRateMultiplier)
        #expect(hype.speechPitch > editorial.speechPitch)
        #expect(hype.preUtteranceDelay < editorial.preUtteranceDelay)
    }
}

/// The regression this suite exists to pin: rendering a QC reason through
/// its OWN moment and then splicing that already-flourished line into
/// ANOTHER flourished wrapper stacks two personality treatments into one
/// utterance — which reads (and sounds, spoken) like a machine repeating
/// itself: "It came out too dark, bestie — one more! — retake while
/// they're right there, bestie?". The fix: the wrapping moment always gets
/// the CANONICAL reason, so exactly one flourish happens per utterance.
@Suite struct CoachVoiceRetakeCompositionTests {
    private let newPacks: [CoachVoice] = [
        HypeBestieVoice(), StraightShooterVoice(), EditorialDirectorVoice(), DragQueenBestieVoice(),
    ]

    @Test func retakeConfirmRendersTheCanonicalReasonExactlyOnce() {
        let canonicalReason = "Their face came out too dark"
        for voice in newPacks {
            let confirm = voice.phrase(for: .retakeConfirm, ctx: CoachPhraseContext(detail: canonicalReason))
            #expect(confirm?.contains(canonicalReason) == true, "\(voice.displayName) dropped or re-flourished the reason")
            guard let confirm else { continue }
            let mentions = confirm.lowercased().components(separatedBy: "retake").count - 1
            #expect(mentions <= 1, "\(voice.displayName) mentions retaking more than once: \(confirm)")
        }
    }

    @Test func retakeAnnounceRendersTheCanonicalReasonExactlyOnce() {
        let canonicalReason = "It came out soft"
        for voice in newPacks {
            let announce = voice.phrase(for: .retakeAnnounce, ctx: CoachPhraseContext(detail: canonicalReason))
            #expect(announce?.contains(canonicalReason) == true, "\(voice.displayName) dropped or re-flourished the reason")
        }
    }
}

/// Sequential focus coaching (docs/design, 2026-08-06) — the SAME §0
/// guardrail applied to a new decision: `CoachTipArbiter` never sees a
/// `CoachVoice`, so which rung advances, and when, is identical no matter
/// which pack ends up speaking the compliment+next line.
@Suite struct CoachFocusLadderVoiceTests {
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
                     mixed: Double = 0.0, warmth: Double = 0.15) -> FrameContext {
        FrameContext(avgLuma: luma, faceBounds: face, faceLuma: faceLuma ?? luma,
                    backgroundLuma: backgroundLuma, sharpness: 0.6,
                    backgroundClutter: 0, subjectFill: 0.5, pose: pose, deviceTilt: 0,
                    color: ColorSignal(mixed: mixed, greenTint: 0, warmth: warmth),
                    expectations: .portrait)
    }

    /// Lighting broken (alongside a still-broken color) → fixed → held stable
    /// past `focusStabilityWindow` — the ladder must advance from lighting to
    /// color. Runs the REAL pipeline (`CoachAggregate.evaluate` +
    /// `CoachTipArbiter`), then renders the resulting `advanced` event the
    /// same way `CoachEngine.apply` does, in `voice`.
    private func advanceEvent(voice: CoachVoice) -> (category: CoachCategory, line: String)? {
        var arbiter = CoachTipArbiter()
        _ = CoachAggregate.evaluate(
            coaches, ctx(luma: 0.15, faceLuma: 0.15, backgroundLuma: 0.15, mixed: 0.20),
            arbiter: &arbiter, now: 0)
        _ = CoachAggregate.evaluate(coaches, ctx(mixed: 0.20), arbiter: &arbiter, now: 1)
        let verdict = CoachAggregate.evaluate(
            coaches, ctx(mixed: 0.20), arbiter: &arbiter, now: 1 + CoachTuning.focusStabilityWindow + 0.1)
        guard let advanced = verdict.advanced, let nudge = verdict.nudge else { return nil }

        // Mirrors `CoachEngine.apply`: the SENTENCE form, because this line
        // is built by concatenation below. (This helper re-implements the
        // engine, so it has to be changed with it or it stops testing what
        // ships — which is how the run-on survived this long.)
        let complimentFallback = advanced.canonicalGoodSentence
        let compliment = CoachVoiceRenderer.render(advanced.goodMoment, fallback: complimentFallback, voice: voice)
            ?? complimentFallback
        let next = CoachVoiceRenderer.render(
            nudge.moment, fallback: nudge.message, ctx: nudge.phraseCtx ?? CoachPhraseContext(), voice: voice)
            ?? nudge.message
        let fallback = "\(compliment) \(next)"
        let line = CoachVoiceRenderer.render(
            .focusRungAdvanced, fallback: fallback,
            ctx: CoachPhraseContext(subjectNoun: compliment, detail: next), voice: voice) ?? fallback
        return (advanced, line)
    }

    @Test func theAdvanceEventFiresForTheSameRungAtTheSameMomentAcrossEveryPersonality() {
        let events = CoachPersonality.allCases.map { advanceEvent(voice: $0.voice) }
        #expect(events.allSatisfy { $0 != nil }, "every personality must see the SAME decision fire")
        let categories = Set(events.compactMap { $0?.category })
        #expect(categories.count == 1, "the ladder decision changed between personalities — it must not")
        #expect(categories.first == .lighting)
    }

    @Test func everyNewPackRendersADistinctFocusRungAdvancedLine() {
        guard let calm = advanceEvent(voice: CalmMentorVoice())?.line else {
            Issue.record("Calm Mentor produced no advance event")
            return
        }
        for personality in CoachPersonality.allCases where personality != .calmMentor {
            guard let line = advanceEvent(voice: personality.voice)?.line else {
                Issue.record("\(personality) produced no advance event")
                continue
            }
            #expect(!line.isEmpty)
            #expect(line != calm, "\(personality) must not silently fall back to Calm Mentor's transition line")
        }
    }

    // MARK: - The default voice's own register (camera plan P5.1)

    /// The advance line is `"\(compliment) \(next)"` — a bare concatenation.
    /// A compliment with no terminal punctuation therefore runs straight into
    /// the next instruction and is spoken as one breath.
    ///
    /// Every personality pack already ended its good line with a full stop,
    /// even the terse one ("Sharp."). The DEFAULT voice was the only one that
    /// did not: it renders nil and defers to canonical text, and canonical
    /// only had the dimensions drawer's row LABEL, which is unpunctuated on
    /// purpose. So the one voice every pro starts on produced "Sharp Center
    /// them" while every opt-in pack produced two clean sentences.
    @Test func everyVoiceEndsItsComplimentAsAWholeSentence() {
        for personality in CoachPersonality.allCases {
            for category in CoachCategory.allCases {
                let fallback = category.canonicalGoodSentence
                let compliment = CoachVoiceRenderer.render(
                    category.goodMoment, fallback: fallback, voice: personality.voice) ?? fallback
                let last = compliment.last
                #expect(last.map { ".!?".contains($0) } == true,
                        "\(personality) ends \(category)'s compliment without a full stop: “\(compliment)”")
            }
        }
    }

    /// …and the fix must not be "put full stops in `canonicalGoodPhrase`".
    /// That string is the drawer's row label, sitting in a column of statuses
    /// where a trailing full stop would be wrong. The two forms stay separate.
    @Test func theDrawerLabelStaysALabel() {
        for category in CoachCategory.allCases {
            let label = category.canonicalGoodPhrase
            #expect(label.last.map { ".!?".contains($0) } == false,
                    "\(category)'s drawer label has become a sentence: “\(label)”")
            #expect(label != category.canonicalGoodSentence)
        }
    }

    /// Packs are opt-in, and the pro who never opens settings gets Calm
    /// Mentor. Tori's call, 2026-08-24 (camera plan decision D4).
    @Test func theDefaultVoiceIsCalmMentorSoThePacksAreOptIn() {
        // No stored preference, and anything unreadable, resolves to the
        // default voice — the four packs only ever arrive by being chosen.
        #expect(CoachSettings.personality(fromStored: nil) == .calmMentor)
        #expect(CoachSettings.personality(fromStored: "") == .calmMentor)
        #expect(CoachSettings.personality(fromStored: "aPackThatNoLongerExists") == .calmMentor)
        // …and a real stored choice is still honoured.
        #expect(CoachSettings.personality(fromStored: "hypeBestie") == .hypeBestie)
    }

    /// The coach's canonical lines are read aloud by `AVSpeechSynthesizer`
    /// whenever the pro turns speech on, so they have to be sayable. A slash
    /// is not: "Warm/yellow light" has no pronunciation.
    @Test func noCanonicalGoodOrCorrectiveCopyContainsAnUnspeakableSlash() {
        for category in CoachCategory.allCases {
            #expect(!category.canonicalGoodSentence.contains("/"))
            #expect(!category.canonicalGoodPhrase.contains("/"))
        }
        let warm = ColorCoach().evaluate(ctx(mixed: 0.02, warmth: 0.5))
        #expect(warm.message?.contains("/") == false,
                "the warm-light line is spoken aloud: “\(warm.message ?? "")”")
    }
}

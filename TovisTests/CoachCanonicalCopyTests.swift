// The canonical copy table's own guardrails — `Tovis/CoachCanonicalCopy.swift`.
//
// Three jobs, and the third is the one that outlives this refactor:
//
//  1. COMPLETENESS, derived from the SSOT. Every `CoachMoment` outside
//     `CoachCanonicalCopy.openSet` has words, for every context it declares.
//     The list comes from `CoachMoment.allCases`, never a hand-written array —
//     a completeness check that can itself be incomplete is not one.
//  2. The DOMAIN declaration is honest. A moment that declares no context
//     domain really renders the same words for any context, and one that
//     declares a domain really varies across it. That pair is what stops an
//     interpolation being added without a domain — which would silently cost
//     the default voice its recordable audio for that line, the exact hole
//     this table was built to close.
//  3. THE TRANSCRIPT. Every line the default voice can say, pinned. This is
//     what "the default voice is one file you can read" buys: a copy edit
//     now shows up here as a diff of the words, deliberately, instead of
//     landing unnoticed in one of eight files.
//
// The transcript was generated from `scripts/coach-voice-manifest/manifest.json`
// at the commit that centralized the table, and every string in it was proved
// byte-identical to the literal it moved from. It is a PIN, not a second
// source: nothing reads it but this test.
import Foundation
import Testing
@testable import Tovis

@Suite struct CoachCanonicalCopyTests {
    /// A context carrying a value in every field a canonical line could read,
    /// so "does this moment interpolate?" is answered by rendering rather than
    /// by reading the switch.
    private let probe = CoachPhraseContext(
        direction: "left", subjectNoun: "PROBE", count: 7, detail: "DETAIL", namesAPerson: true)

    private func key(_ moment: CoachMoment, _ ctx: CoachPhraseContext) -> String {
        var parts: [String] = []
        if let direction = ctx.direction { parts.append("direction=\(direction)") }
        if let noun = ctx.subjectNoun { parts.append("subjectNoun=\(noun)") }
        if ctx.namesAPerson { parts.append("namesAPerson=true") }
        return parts.isEmpty ? "\(moment)" : "\(moment) [\(parts.joined(separator: ", "))]"
    }

    private var inScope: [CoachMoment] {
        CoachMoment.allCases.filter { !CoachCanonicalCopy.openSet.contains($0) }
    }

    // MARK: - 1. Completeness

    @Test func everyInScopeMomentHasWordsForEveryContextItDeclares() {
        for moment in inScope {
            let contexts = CoachCanonicalCopy.contexts(for: moment)
            #expect(!contexts.isEmpty, "\(moment) declares no context at all")
            for ctx in contexts {
                let line = CoachCanonicalCopy.line(for: moment, ctx: ctx)
                #expect(line != nil, "no canonical line for \(key(moment, ctx))")
                #expect(line?.isEmpty == false, "empty canonical line for \(key(moment, ctx))")
            }
        }
    }

    /// `ownedLine`'s `?? ""` is unreachable, and this is what makes it so.
    @Test func theOwnedLineAccessorNeverFallsThroughToTheEmptyString() {
        for moment in inScope {
            for ctx in CoachCanonicalCopy.contexts(for: moment) {
                #expect(!CoachCanonicalCopy.ownedLine(for: moment, ctx: ctx).isEmpty,
                        "ownedLine fell through for \(key(moment, ctx))")
            }
        }
    }

    /// The open set is exactly the moments with no fixed words — asked with a
    /// context that supplies everything, so a nil here can only mean "this
    /// table does not own these words", never "you forgot the noun".
    @Test func theOpenSetIsExactlyTheMomentsWithNoCanonicalText() {
        let wordless = Set(CoachMoment.allCases.filter {
            CoachCanonicalCopy.line(for: $0, ctx: probe) == nil
        })
        #expect(wordless == CoachCanonicalCopy.openSet)
    }

    // MARK: - 2. The domain declaration is honest

    @Test func aMomentDeclaringNoDomainRendersTheSameWordsForAnyContext() {
        for moment in inScope where CoachCanonicalCopy.contexts(for: moment).count == 1 {
            #expect(CoachCanonicalCopy.line(for: moment, ctx: probe)
                    == CoachCanonicalCopy.line(for: moment, ctx: CoachPhraseContext()),
                    "\(moment) interpolates but declares no domain — its audio can never be pre-baked")
        }
    }

    @Test func aMomentDeclaringADomainRendersADistinctLineForEveryValueInIt() {
        for moment in inScope {
            let contexts = CoachCanonicalCopy.contexts(for: moment)
            guard contexts.count > 1 else { continue }
            let rendered = Set(contexts.compactMap { CoachCanonicalCopy.line(for: moment, ctx: $0) })
            #expect(rendered.count == contexts.count,
                    "\(moment) declares \(contexts.count) contexts but says only \(rendered.count) distinct things")
        }
    }

    // MARK: - The guardrail this refactor must not have moved

    /// Canonical is the BOTTOM of the vocabulary precedence `CoachEngine.apply`
    /// builds — look → booking → plain → room → canonical. Centralizing the
    /// words must not turn the default voice into a renderer: a `CalmMentorVoice`
    /// that returned text would win over every one of those layers, because
    /// `CoachVoiceRenderer` asks the voice first.
    @Test func theDefaultVoiceStillRendersNothingItself() {
        let calm = CalmMentorVoice()
        for moment in CoachMoment.allCases {
            #expect(calm.phrase(for: moment, ctx: probe) == nil,
                    "CalmMentorVoice started rendering \(moment) — that jumps the vocabulary layers")
        }
    }

    /// A voice with ONE line and one deliberate hole. The shipping packs pick
    /// `lines.randomElement()!`, so asking one of them twice is a coin flip —
    /// a test written against a real pack passes or fails by luck, which is
    /// the worst kind of green.
    private struct OneLineVoice: CoachVoice {
        let id: CoachPersonality = .hypeBestie
        let displayName = "One Line"
        let chattiness: CoachChattiness = .standard
        let speechRateMultiplier: Float = 1
        let speechPitch: Float = 1
        let preUtteranceDelay: TimeInterval = 0
        func phrase(for moment: CoachMoment, ctx: CoachPhraseContext) -> String? {
            moment == .laneHoldShooting ? "GO." : nil
        }
    }

    @Test func renderCanonicalPrefersThePacksLineAndFallsBackToTheTable() {
        let voice = OneLineVoice()
        #expect(CoachVoiceRenderer.renderCanonical(.laneHoldShooting, voice: voice) == "GO.")
        // The hole falls through to canonical, not to a blank.
        #expect(CoachVoiceRenderer.renderCanonical(.laneSetComplete, voice: voice)
                == CoachCanonicalCopy.line(for: .laneSetComplete))
        // …and the default voice, which is one big hole, always does.
        #expect(CoachVoiceRenderer.renderCanonical(.laneHoldShooting, voice: CalmMentorVoice())
                == CoachCanonicalCopy.line(for: .laneHoldShooting))
    }

    // MARK: - 3. The transcript

    @Test func theDefaultVoiceSaysExactlyWhatItSaidBeforeItHadOneHome() {
        var seen: Set<String> = []
        for moment in inScope {
            for ctx in CoachCanonicalCopy.contexts(for: moment) {
                let id = key(moment, ctx)
                seen.insert(id)
                #expect(CoachCanonicalCopy.line(for: moment, ctx: ctx) == Self.transcript[id],
                        "canonical copy changed for \(id)")
            }
        }
        #expect(seen == Set(Self.transcript.keys),
                "the transcript and the table disagree on which lines exist")
    }

    /// Every line the default voice can say. Read it top to bottom — that is
    /// the point of the table.
    private static let transcript: [String: String] = [
        "lightingBacklit":
            "Light’s behind them — turn them to face the window",
        "lightingTooDark":
            "Too dark — move toward the light",
        "lightingTooDark [namesAPerson=true]":
            "Their face is too dark — turn them toward the light",
        "lightingBlownOut":
            "Blown out — turn away from the bright light",
        "lightingBlownOut [namesAPerson=true]":
            "Their face is blown out — turn away from the bright light",
        "compositionTooFar":
            "Move in closer — fill the frame",
        "compositionTooClose":
            "Too tight — step back a touch",
        "compositionFaceRequired":
            "Frame their face for this shot",
        "compositionOffFrame":
            "They’re outside the feed crop — center them",
        "compositionNoHeadroom":
            "Leave a little headroom — lower the camera",
        "compositionTooLow":
            "Raise the camera — they’re too low",
        "compositionRecenter":
            "Center them",
        "sharpnessHoldSteady":
            "Hold steady — shot looks soft",
        "sharpnessTapToFocus":
            "Tap to focus — a touch soft",
        "backgroundBusy":
            "Busy background — find a cleaner backdrop",
        "poseClipped":
            "They’re getting clipped — pull back",
        "levelTilted [direction=left]":
            "Camera’s tilted left — straighten it",
        "levelTilted [direction=right]":
            "Camera’s tilted right — straighten it",
        "levelAlmostLevel":
            "Almost level — straighten up",
        "colorMixed":
            "Mixed light — turn off the overheads",
        "colorGreenish":
            "Greenish light — switch to one clean source",
        "colorWarm":
            "Warm light — daylight reads truer",
        "goodLighting":
            "Light's good now.",
        "goodColor":
            "Color's true now.",
        "goodLevel":
            "That's level now.",
        "goodFraming":
            "Framing's good now.",
        "goodSharpness":
            "That's sharp now.",
        "goodBackground":
            "Background's clean now.",
        "goodPose":
            "Pose reads now.",
        "laneHoldShooting":
            "Hold it — shooting",
        "laneSetComplete":
            "That’s the full set — beautiful work",
        "laneCalibrationDrift":
            "Light’s changed — re-scan the card",
        "dimensionCleared [subjectNoun=Lighting]":
            "Lighting — got it",
        "dimensionCleared [subjectNoun=Framing]":
            "Framing — got it",
        "dimensionCleared [subjectNoun=Focus]":
            "Focus — got it",
        "dimensionCleared [subjectNoun=Background]":
            "Background — got it",
        "dimensionCleared [subjectNoun=Pose]":
            "Pose — got it",
        "dimensionCleared [subjectNoun=Level]":
            "Level — got it",
        "dimensionCleared [subjectNoun=Color]":
            "Color — got it",
        "qcEyesClosed":
            "Their eyes were closed",
        "qcSoft":
            "It came out soft",
        "qcTooDark [subjectNoun=It]":
            "It came out too dark",
        "qcTooDark [subjectNoun=Their face]":
            "Their face came out too dark",
        "qcBlownOut [subjectNoun=It]":
            "It came out blown out",
        "qcBlownOut [subjectNoun=Their face]":
            "Their face came out blown out",
        "lightMatched [subjectNoun=before]":
            "Light matches the before",
        "lightMatched [subjectNoun=reference]":
            "Light matches the reference",
        "lightBrighterThan [subjectNoun=before]":
            "Brighter than the before — dim a touch",
        "lightBrighterThan [subjectNoun=reference]":
            "Brighter than the reference — dim a touch",
        "lightDarkerThan [subjectNoun=before]":
            "Darker than the before — add light",
        "lightDarkerThan [subjectNoun=reference]":
            "Darker than the reference — add light",
        "lightWarmerThan [subjectNoun=before]":
            "Warmer than the before — cool the light",
        "lightWarmerThan [subjectNoun=reference]":
            "Warmer than the reference — cool the light",
        "lightCoolerThan [subjectNoun=before]":
            "Cooler than the before — warm the light",
        "lightCoolerThan [subjectNoun=reference]":
            "Cooler than the reference — warm the light",
        "matchingReferenceLook":
            "Matching your reference look.",
        "practiceGuideNote":
            "Practice shots aren’t attached to anyone. Shoot as many as you like — you can attach one to a client or a look later.",
        "leavingWithoutTitlePractice":
            "Leave the camera?",
        "pairedWithBefore":
            "Light and framing match the before",
    ]
}

// Coach voice line-extraction pipeline — chunk 1 of
// docs/design/custom-coach-voices-brief.md (tovis-app repo).
//
// Compiled and run by run.sh against the REAL Tovis/CoachVoice.swift and
// Tovis/CoachVoicePacks.swift sources (see run.sh's comment for how — no
// parallel copy of any pack's copy exists anywhere in this file). This is
// the ENTIRE reason the pipeline can't drift from the shipping app: it
// isn't reading a description of the packs, it's running them.
//
// Emits manifest.json: one entry per (personality, moment, ctx, variant)
// that's addressable and pre-generatable per the brief's §1 dynamic-segment
// table. Two things are NOT in this manifest, on purpose:
//
//   1. Moments that wrap open-set, runtime-composed text (a ShotStep's
//      title/hint, a trending pack's tagline, an AI direction line, a
//      retake reason, a session requirement sentence, or — for
//      focusRungAdvanced — another moment's own already-rendered line).
//      Brief §1: these stay on system TTS permanently; decision 4 accepts
//      that gap. `excludedMoments` below documents each with its real
//      call-site source, so this list is a citation, not a guess.
//
//   2. Everything about Calm Mentor except the 7 "good" moments. Its
//      `phrase(for:ctx:)` always returns nil by design — it defers to
//      canonical text that, for those 7 moments, really is centralized
//      (`CoachCategory.canonicalGoodPhrase`). Everywhere else, the
//      canonical text is scattered as literals and runtime-interpolated
//      strings across ShotCoach.swift, PhotoQC.swift, BeforeShotMeasure.swift,
//      ProCapturePhotosView.swift, CameraCoachLane.swift, CoachEngine.swift,
//      and ProCameraDestination.swift — there is no single source of truth
//      to read the way the 4 packs are one. Hand-copying that text here
//      would be exactly the parallel-copy drift risk this pipeline exists
//      to avoid, so `calmMentorGap` documents it as open work instead of
//      papering over it.
import Foundation
import CryptoKit

// MARK: - Personality registry
//
// A structural pairing of (id, real voice instance) — not a copy of
// CoachSettings.CoachPersonality.voice, just the same mapping inlined so
// this tool doesn't need CoachSettings.swift's SwiftUI import.

let personalities: [(id: String, voice: CoachVoice)] = [
    ("hypeBestie", HypeBestieVoice()),
    ("straightShooter", StraightShooterVoice()),
    ("editorialDirector", EditorialDirectorVoice()),
    ("dragQueenBestie", DragQueenBestieVoice()),
]

// MARK: - Scope

/// Finite ctx domains, each traced to the real call site that supplies the
/// value in the shipping app (not invented here):
///   - dimensionCleared: CoachCategory.spokenName (CameraCoachLane.swift),
///     via CoachEngine.swift:558's `cleared.spokenName`.
///   - QC verdicts: PhotoQC.swift's `faceLuma == nil ? "It" : "Their face"`.
///   - light-match verdicts: ProCapturePhotosView.swift:1765/1767's
///     `noun = "reference"` / `noun = "before"`.
let dimensionClearedNouns = ["Lighting", "Colour", "Level", "Framing", "Focus", "Background", "Pose"]
let qcSubjectNouns = ["It", "Their face"]
let lightMatchNouns = ["reference", "before"]

// `.pairedWithBefore` (P5.3) is deliberately ABSENT from this table: its copy
// interpolates nothing. Parity is only ever claimed about the booking's own
// BEFORE (`BeforePair.verdict` takes no stamp for a "match a look" reference),
// so there is no noun that varies — it cross-products like any static moment.
let ctxDomains: [CoachMoment: [String]] = [
    .dimensionCleared: dimensionClearedNouns,
    .qcTooDark: qcSubjectNouns,
    .qcBlownOut: qcSubjectNouns,
    .lightMatched: lightMatchNouns,
    .lightBrighterThan: lightMatchNouns,
    .lightDarkerThan: lightMatchNouns,
    .lightWarmerThan: lightMatchNouns,
    .lightCoolerThan: lightMatchNouns,
]

// `levelTilted`'s `ctx.direction` is deliberately absent from `ctxDomains`:
// grepped all four packs — none of them read `ctx.direction`. It's dead
// today (brief §1), so `levelTilted` cross-products like any static moment.

/// Moments excluded from pre-bake because their copy wraps open-set text
/// that isn't known until runtime — see the file header. Each reason cites
/// the real call site so this list can be checked against the code, not
/// just trusted.
let excludedMoments: [CoachMoment: String] = [
    .shotStepHint: "wraps ShotStep.hint — open-set app copy (ProCapturePhotosView.swift, CameraCoachLane.swift, CameraDrawers.swift)",
    .shotStepAnnounce: "wraps ShotStep.title/.hint — open-set (ProCapturePhotosView.swift ~532)",
    .shotCaptured: "wraps a shot title — open-set (ProCapturePhotosView.swift ~1503)",
    .trendingSetIntro: "wraps a server-driven trending-pack name/tagline — open-set (ProCapturePhotosView.swift ~1636, ProShotPacks.swift)",
    .aiDirectionReady: "wraps an AI-generated direction line — open-set (ProCapturePhotosView.swift ~1695)",
    .retakeConfirm: "wraps a QC/retake reason sentence — classed open-set by brief §1 (ProCapturePhotosView.swift ~854)",
    .retakeAnnounce: "wraps a QC/retake reason sentence — classed open-set by brief §1 (ProCapturePhotosView.swift ~2301)",
    .sessionGuideNoteMet: "wraps ProSessionPhotoRequirement.guideNote(phase) — open-set (ProCameraDestination.swift ~97)",
    .sessionGuideNoteOutstanding: "wraps ProSessionPhotoRequirement.guideNote(phase) — open-set (ProCameraDestination.swift ~98)",
    .sessionOutstandingSentence: "wraps ProSessionPhotoRequirement.outstandingSentence(phase) — open-set (ProCameraDestination.swift ~124)",
    .leavingWithoutTitleSession: "wraps ProSessionPhotoRequirement.leavingWithoutTitle(phase) — open-set (ProCameraDestination.swift ~110)",
    .roomTipDismissed: "wraps CoachRoomMemory.confirmation(for:) — one sentence per dismissible room condition, chosen at runtime from the tip being retired (CoachEngine.dismissRoomTip; CoachRoomMemory.swift)",
    .focusRungAdvanced: "wraps two ALREADY-rendered lines from other moments, composed at runtime — not fixed text (CoachEngine.swift ~549; see CoachPhraseContext.detail's doc comment)",
]

let inScopeMoments = CoachMoment.allCases.filter { excludedMoments[$0] == nil }

// MARK: - Variant discovery
//
// `pick()` in CoachVoicePacks.swift is `lines.randomElement()!` — there is
// no addressable array to read directly, so the full variant set is
// discovered by sampling `phrase(for:ctx:)` many times and collecting
// distinct results. 1000 draws makes missing a real variant astronomically
// unlikely even at the largest variant count seen in these packs (4):
// P(miss) ≈ 4×(3/4)^1000 ≈ 10⁻¹²⁴. Sorting before assigning `variantIndex`
// keeps output deterministic across runs regardless of sampling order —
// required for the CI drift check not to false-positive on re-generation.
let samplesPerCombo = 1000

func discoverVariants(voice: CoachVoice, moment: CoachMoment, ctx: CoachPhraseContext) -> [String] {
    var found = Set<String>()
    for _ in 0..<samplesPerCombo {
        if let phrase = voice.phrase(for: moment, ctx: ctx), !phrase.isEmpty {
            found.insert(phrase)
        }
    }
    return found.sorted()
}

// MARK: - Content hash

func contentHash(_ text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
}

// MARK: - Manifest shape

struct ManifestLine: Codable {
    let id: String
    let personality: String
    let moment: String
    let variantIndex: Int
    let ctx: [String: String]
    let text: String
}

struct ExcludedMoment: Codable {
    let moment: String
    let reason: String
}

struct ManifestScope: Codable {
    let inScope: [String]
    let excluded: [ExcludedMoment]
}

struct CalmMentorGap: Codable {
    let coveredMoments: [String]
    let uncoveredInScopeMoments: [String]
    let note: String
}

struct Manifest: Codable {
    let schemaVersion: Int
    let scope: ManifestScope
    let calmMentorGap: CalmMentorGap
    let lines: [ManifestLine]
}

// MARK: - Build

var lines: [ManifestLine] = []
var gaps: [String] = []

for (personalityID, voice) in personalities {
    for moment in inScopeMoments {
        let ctxValues: [(label: String, ctx: CoachPhraseContext)]
        if let domain = ctxDomains[moment] {
            ctxValues = domain.map { ($0, CoachPhraseContext(subjectNoun: $0)) }
        } else {
            ctxValues = [("", CoachPhraseContext())]
        }
        for (ctxLabel, ctx) in ctxValues {
            let variants = discoverVariants(voice: voice, moment: moment, ctx: ctx)
            if variants.isEmpty {
                let suffix = ctxLabel.isEmpty ? "" : " [ctx.subjectNoun=\(ctxLabel)]"
                gaps.append("\(personalityID) has no line for \(moment)\(suffix)")
                continue
            }
            for (index, text) in variants.enumerated() {
                lines.append(ManifestLine(
                    id: contentHash(text), personality: personalityID, moment: "\(moment)",
                    variantIndex: index,
                    ctx: ctxLabel.isEmpty ? [:] : ["subjectNoun": ctxLabel],
                    text: text))
            }
        }
    }
}

// Calm Mentor — only the 7 "good" moments; see file header + calmMentorGap.
let calmMentorCategories: [CoachCategory] = [
    .lighting, .composition, .sharpness, .background, .pose, .level, .color,
]
var calmMentorCoveredMoments: [String] = []
for category in calmMentorCategories {
    let moment = category.goodMoment
    let text = category.canonicalGoodPhrase
    calmMentorCoveredMoments.append("\(moment)")
    lines.append(ManifestLine(id: contentHash(text), personality: "calmMentor",
                              moment: "\(moment)", variantIndex: 0, ctx: [:], text: text))
}
let calmMentorUncovered = inScopeMoments
    .map { "\($0)" }
    .filter { !calmMentorCoveredMoments.contains($0) }
    .sorted()

// MARK: - Fail loud on any gap — never ship a personality with a silent
// hole that falls back to system TTS invisibly (brief §4, Validation).

if !gaps.isEmpty {
    FileHandle.standardError.write("error: coach-voice-manifest completeness check failed:\n".data(using: .utf8)!)
    for gap in gaps.sorted() {
        FileHandle.standardError.write("  - \(gap)\n".data(using: .utf8)!)
    }
    exit(1)
}

// MARK: - Emit

let manifest = Manifest(
    schemaVersion: 1,
    scope: ManifestScope(
        inScope: inScopeMoments.map { "\($0)" },
        excluded: excludedMoments
            .map { ExcludedMoment(moment: "\($0.key)", reason: $0.value) }
            .sorted { $0.moment < $1.moment }
    ),
    calmMentorGap: CalmMentorGap(
        coveredMoments: calmMentorCoveredMoments.sorted(),
        uncoveredInScopeMoments: calmMentorUncovered,
        note: "Calm Mentor's phrase(for:ctx:) always returns nil by design — it defers to canonical " +
              "text. Only these 7 \"good\" moments have a centralized canonical source " +
              "(CoachCategory.canonicalGoodPhrase, Tovis/CoachVoice.swift). The remaining in-scope " +
              "moments' canonical text is scattered across ShotCoach.swift, PhotoQC.swift, " +
              "BeforeShotMeasure.swift, ProCapturePhotosView.swift, CameraCoachLane.swift, " +
              "CoachEngine.swift, and ProCameraDestination.swift as literals and runtime-interpolated " +
              "strings, not a single lookup this tool can read without duplicating that text. Needs a " +
              "centralization refactor (a CoachMoment -> String canonical table) before Calm Mentor's " +
              "audio can be pre-generated for those moments."
    ),
    lines: lines
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try! encoder.encode(manifest)

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "manifest.json"
try! data.write(to: URL(fileURLWithPath: outputPath))

let byPersonality = Dictionary(grouping: lines, by: { $0.personality }).mapValues(\.count)
FileHandle.standardError.write("wrote \(outputPath): \(lines.count) lines\n".data(using: .utf8)!)
for id in ["calmMentor", "hypeBestie", "straightShooter", "editorialDirector", "dragQueenBestie"] {
    let count = byPersonality[id] ?? 0
    FileHandle.standardError.write("  \(id): \(count)\n".data(using: .utf8)!)
}

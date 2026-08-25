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
//   2. Nothing about Calm Mentor any more. It used to be everything except
//      the 7 "good" moments: its `phrase(for:ctx:)` returns nil by design
//      (canonical sits at the BOTTOM of the vocabulary precedence, so a
//      default voice that returned text would jump the whole stack), and the
//      canonical words it defers to were literals and runtime-interpolated
//      fragments across eight app files — nothing a tool could read without
//      hand-copying it, which is the parallel-copy drift this pipeline exists
//      to prevent. `Tovis/CoachCanonicalCopy.swift` is now that single
//      source, compiled here like the packs are, so the default voice is
//      sampled from the same code the camera runs. `calmMentorGap` is kept
//      as the record that the hole is closed rather than deleted.
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

/// The finite ctx domains come from `CoachCanonicalCopy.contexts(for:)` — the
/// app's own declaration of what each canonical line varies over, sourced from
/// `CoachCategory.spokenName`, `PhotoQC`'s "It"/"Their face",
/// `BeforeShotMeasure`'s "before"/"reference", `LevelCoach`'s "left"/"right"
/// and `LightingCoach`'s `faceLuma != nil`.
///
/// They used to be hand-written here, and they drifted: this file still said
/// "Colour" for months after iOS #363 made `spokenName` say "Color", so five
/// pack lines in the committed manifest interpolated a noun the app never
/// produces — and `--check` stayed green, because the stale copy was the
/// tool's own. Reading the app removes the place that could be stale.
///
/// `.pairedWithBefore` (P5.3) is deliberately absent from any domain: parity
/// is only ever claimed about the booking's own BEFORE (`BeforePair.verdict`
/// takes no stamp for a "match a look" reference), so there is no noun that
/// varies — it cross-products like any static moment.

/// The contexts a PACK's copy varies over. All four read `ctx.subjectNoun`
/// and nothing else — grepped: none of them reads `direction`,
/// `namesAPerson` or `count` (brief §1) — so a canonical domain over one of
/// those fields would cross-product into identical pack lines and is dropped
/// here rather than duplicated into the manifest.
func packContexts(for moment: CoachMoment) -> [CoachPhraseContext] {
    let nouns = CoachCanonicalCopy.contexts(for: moment).compactMap(\.subjectNoun)
    guard !nouns.isEmpty else { return [CoachPhraseContext()] }
    return nouns.map { CoachPhraseContext(subjectNoun: $0) }
}

/// Which ctx fields actually VARY across a moment's context list — the only
/// ones worth putting in a manifest entry's `ctx`. A moment with one context
/// gets `{}`; `lightingTooDark` gets `namesAPerson` because that Bool is what
/// picks between its two canonical forms.
func varyingFields(_ contexts: [CoachPhraseContext]) -> Set<String> {
    var fields: Set<String> = []
    if Set(contexts.map { $0.direction ?? "" }).count > 1 { fields.insert("direction") }
    if Set(contexts.map { $0.subjectNoun ?? "" }).count > 1 { fields.insert("subjectNoun") }
    if Set(contexts.map(\.namesAPerson)).count > 1 { fields.insert("namesAPerson") }
    return fields
}

func ctxLabel(_ ctx: CoachPhraseContext, varying fields: Set<String>) -> [String: String] {
    var out: [String: String] = [:]
    if fields.contains("direction"), let direction = ctx.direction { out["direction"] = direction }
    if fields.contains("subjectNoun"), let noun = ctx.subjectNoun { out["subjectNoun"] = noun }
    if fields.contains("namesAPerson") { out["namesAPerson"] = ctx.namesAPerson ? "true" : "false" }
    return out
}

func describe(_ label: [String: String]) -> String {
    label.isEmpty ? "" : " [" + label.sorted { $0.key < $1.key }
        .map { "ctx.\($0.key)=\($0.value)" }.joined(separator: ", ") + "]"
}

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

// The app declares the same set as `CoachCanonicalCopy.openSet` — the moments
// it has no fixed words for. This table adds the REASON for each, which is
// documentation the app has no use for. If the two ever disagree, one of them
// is wrong about what the default voice can say, so fail rather than guess.
let openSetMismatch = Set(excludedMoments.keys).symmetricDifference(CoachCanonicalCopy.openSet)
if !openSetMismatch.isEmpty {
    FileHandle.standardError.write(
        ("error: excludedMoments here and CoachCanonicalCopy.openSet disagree on: "
         + openSetMismatch.map { "\($0)" }.sorted().joined(separator: ", ") + "\n").data(using: .utf8)!)
    exit(1)
}

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
        let ctxValues = packContexts(for: moment)
        let fields = varyingFields(ctxValues)
        for ctx in ctxValues {
            let label = ctxLabel(ctx, varying: fields)
            let variants = discoverVariants(voice: voice, moment: moment, ctx: ctx)
            if variants.isEmpty {
                gaps.append("\(personalityID) has no line for \(moment)\(describe(label))")
                continue
            }
            for (index, text) in variants.enumerated() {
                lines.append(ManifestLine(
                    id: contentHash(text), personality: personalityID, moment: "\(moment)",
                    variantIndex: index, ctx: label, text: text))
            }
        }
    }
}

// Calm Mentor — the DEFAULT voice, read out of `CoachCanonicalCopy` the same
// way the packs are read out of their own `phrase(for:ctx:)`. No sampling:
// canonical is a pure function of (moment, ctx), so there are no random
// variants to discover — every moment has exactly one line per context.
//
// For the 7 "good" moments that is the SPOKEN form (`canonicalGoodSentence`),
// not the dimensions drawer's row label: this manifest keys AUDIO, and audio
// only ever exists for text the synthesizer says.
var calmMentorCoveredMoments: [String] = []
for moment in inScopeMoments {
    let ctxValues = CoachCanonicalCopy.contexts(for: moment)
    let fields = varyingFields(ctxValues)
    var covered = false
    for ctx in ctxValues {
        let label = ctxLabel(ctx, varying: fields)
        guard let text = CoachCanonicalCopy.line(for: moment, ctx: ctx), !text.isEmpty else {
            gaps.append("calmMentor has no canonical line for \(moment)\(describe(label))")
            continue
        }
        covered = true
        lines.append(ManifestLine(id: contentHash(text), personality: "calmMentor",
                                  moment: "\(moment)", variantIndex: 0, ctx: label, text: text))
    }
    if covered { calmMentorCoveredMoments.append("\(moment)") }
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
        note: "CLOSED. Calm Mentor's phrase(for:ctx:) still returns nil by design — canonical sits at " +
              "the bottom of the vocabulary precedence and a default voice that returned text would " +
              "jump it — but the canonical words it defers to now live in one place, " +
              "Tovis/CoachCanonicalCopy.swift, keyed by (CoachMoment, CoachPhraseContext) exactly as " +
              "a pack's phrase(for:ctx:) is. This tool compiles and calls that table, so the default " +
              "voice is sampled from the code the camera runs, not from a copy of it. Every in-scope " +
              "moment is covered and uncoveredInScopeMoments is empty; the 7 \"good\" moments resolve " +
              "to CoachCategory.canonicalGoodSentence (the spoken form) as they always did. " +
              "Kept as the record that the gap is closed, and as the check that it stays closed: " +
              "generate.swift exits non-zero if any in-scope moment has no canonical line."
    ),
    lines: lines
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try! encoder.encode(manifest)

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "manifest.json"
try! data.write(to: URL(fileURLWithPath: outputPath))

let byPersonality = Dictionary(grouping: lines, by: { $0.personality }).mapValues(\.count)

// MARK: - The README is prose, and prose drifts
//
// `--check` diffs manifest.json and nothing else, so README.md's counts went
// stale and stayed stale: it claimed "42 moments in scope / 12 excluded" and
// "301 total lines" long after the real numbers moved. Nothing was wrong with
// the pipeline — the only description of it a person reads was wrong. So the
// tool that knows the numbers now checks the sentences that state them.
//
// Substrings, not a format: the README can be rewritten freely as long as the
// numbers in it are the numbers this run produced.

if CommandLine.arguments.count > 2 {
    let readmePath = CommandLine.arguments[2]
    guard let readme = try? String(contentsOfFile: readmePath, encoding: .utf8) else {
        FileHandle.standardError.write("error: could not read \(readmePath)\n".data(using: .utf8)!)
        exit(1)
    }
    let order = ["hypeBestie": "Hype Bestie", "straightShooter": "Straight Shooter",
                 "editorialDirector": "Editorial Director", "dragQueenBestie": "Drag Queen Bestie",
                 "calmMentor": "Calm Mentor"]
    var expected = [
        "In scope (\(inScopeMoments.count) moments)",
        "Excluded (\(excludedMoments.count) moments)",
        "\(lines.count) total",
    ]
    for id in ["hypeBestie", "straightShooter", "editorialDirector", "dragQueenBestie", "calmMentor"] {
        expected.append("\(byPersonality[id] ?? 0) \(order[id]!)")
    }
    // Markdown hard-wraps, so "67 Editorial Director" can span two lines.
    // Compare against the prose with every whitespace run collapsed to a
    // single space — this checks the NUMBERS, not the line breaks.
    let flattened = readme.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let missing = expected.filter { !flattened.contains($0) }
    if !missing.isEmpty {
        FileHandle.standardError.write(
            ("error: \(readmePath) is stale — this run produced numbers it does not state: "
             + missing.map { "\"\($0)\"" }.joined(separator: ", ") + "\n").data(using: .utf8)!)
        exit(1)
    }
}

FileHandle.standardError.write("wrote \(outputPath): \(lines.count) lines\n".data(using: .utf8)!)
for id in ["calmMentor", "hypeBestie", "straightShooter", "editorialDirector", "dragQueenBestie"] {
    let count = byPersonality[id] ?? 0
    FileHandle.standardError.write("  \(id): \(count)\n".data(using: .utf8)!)
}

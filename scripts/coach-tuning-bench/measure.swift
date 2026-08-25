// Offline coach tuning bench — see docs/camera-tuning-bench.md.
//
// Runs the REAL shipping perception math (Tovis/FrameMath.swift,
// Tovis/VisionDetect.swift) and the REAL coaches (Tovis/ShotCoach.swift) with
// the REAL thresholds (Tovis/CoachTuning.swift) over a folder of photographs,
// and prints the raw signal each threshold in CoachTuning is calibrated
// against — plus the coach line each image would actually produce. `run.sh`
// compiles this against the current sources, so it cannot drift from what the
// camera does.
//
// It used to keep its own copies of the analyzer's segmentation and colour
// math, which could silently disagree with the camera. Those now live in
// FrameMath and are called directly, so there is one implementation.
//
// This does NOT replace the on-device pass: a decoded still is not a live
// preview frame, and CoreMotion (LevelCoach) has no reading here. It measures
// the CoreImage/Vision aggregates on real photographic content — which is
// exactly what `sharpnessReference`, `clutterReference`, `mixedLightSpread`
// and now `backlitFaceRatio` were guesses about.
import CoreImage
import Foundation
import Vision

let ciContext = FrameMath.context

struct Measured {
    let name: String
    let luma: Double
    /// §2.1's headline pair: what the coach used to judge, and what it judges now.
    let faceLuma: Double?
    let backgroundLuma: Double?
    let rawEdgeEnergy: Double
    let sharpness: Double
    let hasFace: Bool
    let subjectFill: Double?
    let rawBgEdgeMean: Double?
    let clutter: Double?
    /// Colour measured on the segmented BACKGROUND (what ships today)…
    let color: ColorSignal?
    /// …and on the whole frame (what shipped before), so the bench can show the
    /// size of the content confound rather than asserting it.
    let wholeFrameColor: ColorSignal?
    let poseJoints: Int
    /// The single line this image would put on screen, and the readiness ring.
    let nudge: CoachNudge?
    let readiness: Double

    var faceOverLuma: Double? { faceLuma.map { luma > 0 ? $0 / luma : 0 } }
    var faceOverBackground: Double? {
        guard let faceLuma, let backgroundLuma, backgroundLuma > 0 else { return nil }
        return faceLuma / backgroundLuma
    }
}

let coaches: [ShotCoach] = [
    LightingCoach(), CompositionCoach(), SharpnessCoach(),
    BackgroundCoach(), PoseCoach(), LevelCoach(), ColorCoach(),
]

func measure(_ url: URL) -> Measured? {
    guard let full = CIImage(contentsOf: url) else { return nil }
    // Stills are already upright; the live path applies .oriented(.right) to the
    // camera buffer to land in this same upright space.
    let working = FrameMath.downscaled(full, maxDim: CoachTuning.workingMaxDim)
    guard working.extent.width > 0 else { return nil }

    func handler() -> VNImageRequestHandler {
        VNImageRequestHandler(ciImage: working, orientation: .up, options: [:])
    }
    let face = VisionDetect.largestFace(performing: handler())
    let pose = VisionDetect.poseSignal(performing: handler())

    // Same call the analyzer makes, minus the pixel-buffer plumbing.
    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .balanced
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    try? handler().perform([request])
    var seg: FrameMath.SegmentedFrame?
    if let maskBuffer = request.results?.first?.pixelBuffer {
        seg = FrameMath.segmentSignals(maskBuffer: maskBuffer, working: working,
                                       cropGuide: nil, context: ciContext)
    }

    let color = FrameMath.colorSignal(working, background: seg?.background, context: ciContext)
    let wholeFrameColor = FrameMath.colorSignal(working, background: nil, context: ciContext)
    let faceLuma = face.map {
        FrameMath.averageLuma(FrameMath.crop(working, normalizedTopLeft: $0), context: ciContext)
    }

    let ctx = FrameContext(
        avgLuma: FrameMath.averageLuma(working, context: ciContext),
        faceBounds: face,
        faceLuma: faceLuma,
        backgroundLuma: seg?.backgroundLuma,
        sharpness: FrameMath.sharpness(working, subject: face, context: ciContext),
        backgroundClutter: seg?.clutter,
        subjectFill: seg?.subjectFill,
        pose: pose,
        // No CoreMotion on a still: LevelCoach stays neutral, so every bench
        // readiness is one coach short of a real frame and runs high.
        deviceTilt: nil,
        color: color,
        expectations: face != nil ? .portrait : nil)
    let verdict = CoachAggregate.evaluate(coaches, ctx)

    let target = face.map { FrameMath.crop(working, normalizedTopLeft: FrameMath.expandToHead($0)) }
        ?? working

    return Measured(
        name: url.lastPathComponent,
        luma: ctx.avgLuma,
        faceLuma: faceLuma,
        backgroundLuma: seg?.backgroundLuma,
        rawEdgeEnergy: FrameMath.averageLuma(FrameMath.edges(target), context: ciContext),
        sharpness: ctx.sharpness,
        hasFace: face != nil,
        subjectFill: seg?.subjectFill,
        rawBgEdgeMean: seg?.rawBackgroundEdge,
        clutter: seg?.clutter,
        color: color,
        wholeFrameColor: wholeFrameColor,
        poseJoints: pose?.joints.count ?? 0,
        nudge: verdict.nudge,
        readiness: verdict.readiness)
}

// MARK: - Corpus

// `--pin` switches the output to the digest at the bottom of this file:
// only the values that are reproducible on a DIFFERENT MACHINE, so CI can diff
// them. See the digest's own comment for what is left out and why.
let pinOnly = CommandLine.arguments.dropFirst().contains("--pin")

var urls: [URL] = []
for path in CommandLine.arguments.dropFirst() where path != "--pin" {
    let u = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
        let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
        urls += items.filter { ["jpg", "jpeg", "heic", "png"].contains($0.pathExtension.lowercased()) }
    } else {
        urls.append(u)
    }
}
urls.sort { $0.lastPathComponent < $1.lastPathComponent }

guard !urls.isEmpty else {
    FileHandle.standardError.write(Data("no images found\n".utf8))
    exit(1)
}

/// Fixed-width columns. `String(format:)` does not honour width specifiers on
/// `%@`, which is why the tables used to run together — plain padding instead.
func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}
func rpad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}
func f(_ d: Double?, _ p: Int = 3, _ width: Int = 8) -> String {
    guard let d else { return rpad("—", width) }
    return rpad(String(format: "%.\(p)f", d), width)
}
/// The corpus names are long UUIDs; the leading token is what identifies them.
func shortName(_ n: String) -> String {
    n.count <= 30 ? n : String(n.prefix(27)) + "…"
}

// MARK: - The pin
//
// Everything below the tables is for a person to read. THIS is for CI to diff.
//
// It carries only values with no Vision dependency: whole-frame luma, raw edge
// energy, normalized sharpness, whole-frame colour, and the thresholds those
// are judged against. Measured 2026-08-25, an Apple Silicon Mac vs a
// macos-latest runner: every one of them agreed to the digit.
//
// 🔴 What is deliberately NOT pinned is anything derived from the person
// segmentation mask — `fill`, `clutter`, `bgLuma`, background-scoped colour,
// and the readiness/coach line that depends on them. Those did NOT agree:
// bgLuma 0.520 vs 0.522, fill 0.00 vs 0.01, background edge median 0.0157 vs
// 0.0158. `VNGeneratePersonSegmentationRequest` is an ML model that ships with
// the OS, and a hosted runner's is not this Mac's. Pinning a value the machine
// decides would buy a check that goes red for reasons no one in this repo
// caused — which is worse than no check, because it teaches people to ignore
// red.
func printPin(_ results: [Measured]) {
    print("=== bench pin — machine-reproducible values only ===")
    print(String(format: "thresholds  sharpnessReference=%.3f  mixedLightSpread=%.3f  lumaTooDark=%.3f  lumaIdeal=%.3f  lumaTooBright=%.3f  sharpnessSoft=%.3f  sharpnessSlightlySoft=%.3f  warmCastWarmth=%.3f  greenCastTint=%.3f",
                 CoachTuning.sharpnessReference, CoachTuning.mixedLightSpread,
                 CoachTuning.lumaTooDark, CoachTuning.lumaIdeal, CoachTuning.lumaTooBright,
                 CoachTuning.sharpnessSoft, CoachTuning.sharpnessSlightlySoft,
                 CoachTuning.warmCastWarmth, CoachTuning.greenCastTint))
    for m in results.sorted(by: { $0.name < $1.name }) {
        print(String(format: "%@  luma=%.4f  rawEdge=%.4f  sharp=%.4f  mixed_wf=%.4f  warm_wf=%.4f  face=%@",
                     m.name, m.luma, m.rawEdgeEnergy, m.sharpness,
                     m.wholeFrameColor?.mixed ?? -1, m.wholeFrameColor?.warmth ?? -1,
                     m.hasFace ? "yes" : "no"))
    }
    print("=== end pin ===")
}

if !pinOnly {
    print("=== Raw perception signals on \(urls.count) image(s) ===")
    print("sharpnessReference=\(CoachTuning.sharpnessReference)  clutterReference=\(CoachTuning.clutterReference)  mixedLightSpread=\(CoachTuning.mixedLightSpread)  backlitFaceRatio=\(CoachTuning.backlitFaceRatio)\n")
}

var results: [Measured] = []
for url in urls {
    guard let m = measure(url) else { print("  (skipped \(url.lastPathComponent))"); continue }
    results.append(m)
}

// A corpus of files that all fail to decode is not an empty corpus — the guard
// above only catches "no images found". Without this, every table below prints
// from nothing and the run exits 0, which reads exactly like a clean bench.
guard !results.isEmpty else {
    FileHandle.standardError.write(
        Data("error: \(urls.count) file(s) found, none could be measured\n".utf8))
    exit(1)
}

if pinOnly {
    printPin(results)
    exit(0)
}

// MARK: - Table 1 — exposure: the room vs the skin (plan §2.1 / §3.1)
//
// The whole point of the face relocation is that these columns disagree. This
// table is the offline half of the complexion sweep: run it over a
// complexion-diverse corpus and §3.1 becomes a confirmation rather than a
// discovery.

print("--- exposure: what the coach used to judge (luma) vs what it judges now (faceLuma) ---")
print(pad("image", 31) + rpad("luma", 8) + rpad("faceLuma", 9) + rpad("bgLuma", 9)
        + rpad("face/luma", 11) + rpad("face/bg", 9) + "  backlit?")
for m in results {
    let firesNow = (m.faceLuma).flatMap { f in m.backgroundLuma.map { b in
        f < b * CoachTuning.backlitFaceRatio && f < CoachTuning.backlitFaceMaxLuma } } ?? false
    let firedBefore = (m.faceLuma).map {
        $0 < m.luma * CoachTuning.backlitFaceRatio && $0 < CoachTuning.backlitFaceMaxLuma } ?? false
    let flag: String
    switch (firedBefore, firesNow) {
    case (false, false): flag = ""
    case (true, true): flag = "  yes (unchanged)"
    case (false, true): flag = "  NEW — relocation fires this one"
    case (true, false): flag = "  no longer"
    }
    print(pad(shortName(m.name), 31) + f(m.luma, 3, 8) + f(m.faceLuma, 3, 9)
            + f(m.backgroundLuma, 3, 9) + f(m.faceOverLuma, 3, 11)
            + f(m.faceOverBackground, 3, 9) + flag)
}

// MARK: - Table 2 — colour: content-confounded vs background-scoped (plan §2.2)

print("\n--- colour: whole frame (was) vs segmented background (now) ---")
print(pad("image", 31) + rpad("mixed_wf", 9) + rpad("mixed_bg", 9)
        + rpad("warm_wf", 9) + rpad("warm_bg", 9) + rpad("scope", 8))
for m in results {
    print(pad(shortName(m.name), 31) + f(m.wholeFrameColor?.mixed, 3, 9)
            + f(m.color?.mixed, 3, 9) + f(m.wholeFrameColor?.warmth, 3, 9)
            + f(m.color?.warmth, 3, 9)
            + rpad(m.color?.backgroundScoped == true ? "bg" : "frame", 8))
}

// MARK: - Table 3 — the rest, plus the line the pro would actually see

print("\n--- frame signals + the one coach line ---")
print(pad("image", 31) + rpad("rawEdge", 9) + rpad("sharp", 8) + rpad("face", 6)
        + rpad("fill", 7) + rpad("clutter", 9) + rpad("jnts", 6) + rpad("READY", 7)
        + "  coach line")
for m in results {
    print(pad(shortName(m.name), 31) + f(m.rawEdgeEnergy, 4, 9) + f(m.sharpness, 3, 8)
            + rpad(m.hasFace ? "YES" : "no", 6) + f(m.subjectFill, 2, 7)
            + f(m.clutter, 2, 9) + rpad("\(m.poseJoints)", 6) + f(m.readiness, 2, 7)
            + "  [" + (m.nudge?.category.rawValue ?? "—") + "] "
            + (m.nudge?.message ?? "(nothing to fix)"))
}

// MARK: - Summaries

func stats(_ xs: [Double]) -> (min: Double, med: Double, max: Double)? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return (s.first!, s[s.count / 2], s.last!)
}

print("\n=== Threshold sanity against measured values ===")

let withFaces = results.filter(\.hasFace)
if let fl = stats(withFaces.compactMap(\.faceLuma)) {
    print(String(format: "faceLuma (%d with a face)  min %.3f  median %.3f  max %.3f",
                 withFaces.count, fl.min, fl.med, fl.max))
    let dark = withFaces.filter { ($0.faceLuma ?? 1) < CoachTuning.lumaTooDark }.count
    let bright = withFaces.filter { ($0.faceLuma ?? 0) > CoachTuning.lumaTooBright }.count
    print("  \(dark) faces below lumaTooDark=\(CoachTuning.lumaTooDark), \(bright) above lumaTooBright=\(CoachTuning.lumaTooBright)")
    print("  → §3.1 sets the target face-luma band from this, PER COMPLEXION.")
}
if let r = stats(withFaces.compactMap(\.faceOverBackground)) {
    print(String(format: "faceLuma / backgroundLuma  min %.3f  median %.3f  max %.3f  (backlitFaceRatio %.2f)",
                 r.min, r.med, r.max, CoachTuning.backlitFaceRatio))
    let firesNow = withFaces.filter { m in
        guard let f = m.faceLuma, let b = m.backgroundLuma else { return false }
        return f < b * CoachTuning.backlitFaceRatio && f < CoachTuning.backlitFaceMaxLuma
    }.count
    let firesOnFrame = withFaces.filter { m in
        guard let f = m.faceLuma else { return false }
        return f < m.luma * CoachTuning.backlitFaceRatio && f < CoachTuning.backlitFaceMaxLuma
    }.count
    print("  \(firesNow) trip 'Light's behind them' against the BACKGROUND; \(firesOnFrame) did against the whole frame.")
    print("  → the relocation is MORE sensitive at this ratio. Setting it is §3.1's job.")
}
if let e = stats(results.map(\.rawEdgeEnergy)) {
    print(String(format: "raw edge energy      min %.4f  median %.4f  max %.4f", e.min, e.med, e.max))
    print(String(format: "  sharpnessReference=%.3f → normalized median %.3f",
                 CoachTuning.sharpnessReference, min(1.0, e.med / CoachTuning.sharpnessReference)))
    let soft = results.filter { $0.sharpness < CoachTuning.sharpnessSoft }.count
    let touch = results.filter { $0.sharpness >= CoachTuning.sharpnessSoft
        && $0.sharpness < CoachTuning.sharpnessSlightlySoft }.count
    let saturated = results.filter { $0.sharpness >= 0.999 }.count
    print("  \(soft) judged 'clearly soft', \(touch) 'a touch soft', \(saturated) saturated at 1.0")
}
if let c = stats(results.compactMap(\.rawBgEdgeMean)) {
    print(String(format: "raw bg edge (area-norm)  min %.4f  median %.4f  max %.4f", c.min, c.med, c.max))
    let all = results.compactMap(\.clutter)
    print("  \(all.filter { $0 > CoachTuning.clutterBusy }.count)/\(all.count) judged 'busy background'")

    // Only a frame with a real segmented PERSON has a real background. Without
    // a subject the mask is empty, the "background" IS the whole frame, and the
    // number measures how busy the PICTURE is rather than how busy the BACKDROP
    // behind a client is. `clutterReference` must be set from the portrait rows
    // alone — the faceless ones would tune the coach on the wrong quantity.
    let portraits = results.filter(\.hasFace).compactMap(\.rawBgEdgeMean)
    if let p = stats(portraits) {
        print(String(format: "  PORTRAITS ONLY (%d of %d)  min %.4f  median %.4f  max %.4f",
                     portraits.count, results.count, p.min, p.med, p.max))
        let busyAt = CoachTuning.clutterBusy * CoachTuning.clutterReference
        let firing = portraits.filter { $0 > busyAt }.count
        print(String(format: "  'busy' needs raw bg edge > %.4f (clutterBusy %.2f × clutterReference %.3f) → %d/%d portraits",
                     busyAt, CoachTuning.clutterBusy, CoachTuning.clutterReference, firing, portraits.count))
        // The tuning sweep, so the chosen value is auditable rather than
        // asserted: what each candidate reference would fire on. Beware the
        // `mixedLightSpread` lesson — a cutoff at the MEDIAN fires on half of
        // ordinary frames and becomes noise the pro learns to ignore.
        print("  candidate clutterReference → portraits that would read 'busy':")
        for candidate in [0.18, 0.15, 0.14, 0.13, 0.125, 0.12, 0.11, 0.10, 0.08] {
            let cut = CoachTuning.clutterBusy * candidate
            let n = portraits.filter { $0 > cut }.count
            let pct = portraits.isEmpty ? 0 : Double(n) / Double(portraits.count) * 100
            print(String(format: "    %.3f  (busy above %.4f)  %2d/%d  %4.0f%%",
                         candidate, cut, n, portraits.count, pct))
        }
    }
}
if let m = stats(results.compactMap { $0.color?.mixed }),
   let wf = stats(results.compactMap { $0.wholeFrameColor?.mixed }) {
    print(String(format: "mixed-light spread   BACKGROUND min %.3f  median %.3f  max %.3f  (threshold %.2f)",
                 m.min, m.med, m.max, CoachTuning.mixedLightSpread))
    print(String(format: "                     whole frame min %.3f  median %.3f  max %.3f",
                 wf.min, wf.med, wf.max))
    let bg = results.compactMap { $0.color?.mixed }
    let frame = results.compactMap { $0.wholeFrameColor?.mixed }
    print("  \(bg.filter { $0 > CoachTuning.mixedLightSpread }.count)/\(bg.count) trip 'Mixed light' on the background; \(frame.filter { $0 > CoachTuning.mixedLightSpread }.count)/\(frame.count) did on the whole frame.")
    print("  → §3.2 re-measures mixedLightSpread on the BACKGROUND column, not the frame one.")
}
if let w = stats(results.compactMap { $0.color?.warmth }) {
    print(String(format: "warmth (background)  min %.3f  median %.3f  max %.3f  (warmCastWarmth %.2f)",
                 w.min, w.med, w.max, CoachTuning.warmCastWarmth))
}
if let l = stats(results.map(\.luma)) {
    print(String(format: "luma (whole frame)   min %.3f  median %.3f  max %.3f  (dark<%.2f ideal %.2f bright>%.2f)",
                 l.min, l.med, l.max, CoachTuning.lumaTooDark, CoachTuning.lumaIdeal, CoachTuning.lumaTooBright))
}

print("\n--- which line wins, across the corpus ---")
let byCategory = Dictionary(grouping: results.compactMap { $0.nudge?.category.rawValue },
                            by: { $0 }).mapValues(\.count)
let silent = results.filter { $0.nudge == nil }.count
// Ties broken by name, not by luck. `sorted(by: { $0.value > $1.value })`
// leaves equal counts in Dictionary order, and Swift randomizes its hash seed
// per process — so two categories on the same count came out in either order
// from one run to the next. The real 35-image corpus never showed it because
// its counts are all distinct (19/11/3/1/1); the self-test corpus ties at 2
// and caught it the day the output was first pinned.
for (category, count) in byCategory.sorted(by: {
    $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
}) {
    print("  \(count)/\(results.count)  \(category)")
}
print("  \(silent)/\(results.count)  (nothing to fix)")
print("\nNote: LevelCoach is neutral here (no CoreMotion), so every readiness above")
print("runs high by up to 0.08 versus a real hand-held frame.")

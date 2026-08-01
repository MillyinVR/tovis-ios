// Offline coach tuning bench — see docs/camera-tuning-bench.md.
//
// Runs the REAL shipping perception math (Tovis/FrameMath.swift,
// Tovis/VisionDetect.swift) and the REAL coaches (Tovis/ShotCoach.swift) with
// the REAL thresholds (Tovis/CoachTuning.swift) over a folder of photographs,
// and prints the raw signal each threshold in CoachTuning is calibrated
// against. `run.sh` compiles this against the current sources, so it cannot
// drift from what the camera actually does.
//
// This does NOT replace the on-device pass: a decoded still is not a live
// preview frame, and CoreMotion (LevelCoach) has no reading here. It measures
// the CoreImage/Vision aggregates on real photographic content — which is
// exactly what `sharpnessReference`, `clutterReference` and `mixedLightSpread`
// were guesses about.
import CoreImage
import Foundation
import Vision

let ciContext = FrameMath.context

struct Measured {
    let name: String
    let luma: Double
    let rawEdgeEnergy: Double
    let sharpness: Double
    let hasFace: Bool
    let subjectFill: Double?
    let rawBgEdgeMean: Double?
    let clutter: Double?
    let mixed: Double?
    let warmth: Double?
    let greenTint: Double?
    let poseJoints: Int
}

/// Mirrors CoachAnalyzer.segment (Tovis/CoachEngine.swift) minus the pixel-buffer
/// plumbing — same FrameMath calls, same normalization.
func segment(handler: VNImageRequestHandler, working: CIImage)
    -> (clutter: Double?, fill: Double, rawBg: Double?)? {
    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .balanced
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    try? handler.perform([request])
    guard let maskBuffer = request.results?.first?.pixelBuffer,
          let seg = FrameMath.segmentation(maskBuffer: maskBuffer, working: working,
                                           context: ciContext) else { return nil }
    guard seg.backgroundFraction > CoachTuning.minBackgroundFraction else {
        return (nil, seg.subjectFill, nil)
    }
    let bgEdges = FrameMath.edges(working).applyingFilter("CIMultiplyCompositing", parameters: [
        kCIInputBackgroundImageKey: seg.background,
    ])
    let bgEdgeMean = FrameMath.averageLuma(bgEdges.cropped(to: working.extent), context: ciContext)
    let normalized = bgEdgeMean / seg.backgroundFraction
    return (min(1.0, max(0.0, normalized / CoachTuning.clutterReference)), seg.subjectFill, normalized)
}

/// Mirrors CoachAnalyzer.colorSignal (Tovis/CoachEngine.swift).
func colorSignal(_ working: CIImage) -> ColorSignal? {
    let e = working.extent
    guard e.width > 0, e.height > 0,
          let global = FrameMath.averageRGB(working, context: ciContext) else { return nil }
    let third = e.width / 3
    let warms: [Double] = (0..<3).compactMap { i in
        let rect = CGRect(x: e.minX + CGFloat(i) * third, y: e.minY, width: third, height: e.height)
        return FrameMath.averageRGB(working.cropped(to: rect), context: ciContext).map(FrameMath.warmth)
    }
    let mixed = warms.count >= 2 ? ((warms.max() ?? 0) - (warms.min() ?? 0)) : 0
    let greenTint = (2 * global.g - global.r - global.b) / (2 * global.g + global.r + global.b + 1e-3)
    return ColorSignal(mixed: max(0, mixed), greenTint: greenTint, warmth: FrameMath.warmth(global))
}

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
    let seg = segment(handler: handler(), working: working)
    let color = colorSignal(working)

    let target = face.map { FrameMath.crop(working, normalizedTopLeft: FrameMath.expandToHead($0)) } ?? working

    return Measured(
        name: url.lastPathComponent,
        luma: FrameMath.averageLuma(working, context: ciContext),
        rawEdgeEnergy: FrameMath.averageLuma(FrameMath.edges(target), context: ciContext),
        sharpness: FrameMath.sharpness(working, subject: face, context: ciContext),
        hasFace: face != nil,
        subjectFill: seg?.fill,
        rawBgEdgeMean: seg?.rawBg,
        clutter: seg?.clutter,
        mixed: color?.mixed,
        warmth: color?.warmth,
        greenTint: color?.greenTint,
        poseJoints: pose?.joints.count ?? 0
    )
}

// MARK: - Corpus

var urls: [URL] = []
for path in CommandLine.arguments.dropFirst() {
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

print("=== Raw perception signals on \(urls.count) image(s) ===")
print("sharpnessReference=\(CoachTuning.sharpnessReference)  clutterReference=\(CoachTuning.clutterReference)  mixedLightSpread=\(CoachTuning.mixedLightSpread)\n")
print(String(format: "%-26@ %6@ %9@ %7@ %5@ %6@ %9@ %8@ %7@ %7@ %5@",
             "image" as NSString, "luma" as NSString, "rawEdge" as NSString, "sharp" as NSString,
             "face" as NSString, "fill" as NSString, "rawBgEdge" as NSString, "clutter" as NSString,
             "mixed" as NSString, "warmth" as NSString, "jnts" as NSString))

var results: [Measured] = []
for url in urls {
    guard let m = measure(url) else { print("  (skipped \(url.lastPathComponent))"); continue }
    results.append(m)
    func f(_ d: Double?, _ p: Int = 3) -> NSString {
        guard let d else { return "—" as NSString }
        return String(format: "%.\(p)f", d) as NSString
    }
    print(String(format: "%-26@ %6@ %9@ %7@ %5@ %6@ %9@ %8@ %7@ %7@ %5d",
                 m.name as NSString, f(m.luma), f(m.rawEdgeEnergy, 4), f(m.sharpness),
                 (m.hasFace ? "YES" : "no") as NSString, f(m.subjectFill, 2),
                 f(m.rawBgEdgeMean, 4), f(m.clutter, 2), f(m.mixed), f(m.warmth), m.poseJoints))
}

func stats(_ xs: [Double]) -> (min: Double, med: Double, max: Double)? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return (s.first!, s[s.count / 2], s.last!)
}

print("\n=== Threshold sanity against measured values ===")
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
    print(String(format: "  clutterReference=%.3f → normalized median %.3f",
                 CoachTuning.clutterReference, min(1.0, c.med / CoachTuning.clutterReference)))
    let all = results.compactMap(\.clutter)
    print("  \(all.filter { $0 > CoachTuning.clutterBusy }.count)/\(all.count) judged 'busy background'")
}
if let m = stats(results.compactMap(\.mixed)) {
    print(String(format: "mixed-light spread   min %.3f  median %.3f  max %.3f  (threshold %.2f)",
                 m.min, m.med, m.max, CoachTuning.mixedLightSpread))
    let all = results.compactMap(\.mixed)
    print("  \(all.filter { $0 > CoachTuning.mixedLightSpread }.count)/\(all.count) trip 'Mixed light — turn off the overheads'")
}
if let w = stats(results.compactMap(\.warmth)) {
    print(String(format: "warmth               min %.3f  median %.3f  max %.3f  (warmCastWarmth %.2f)",
                 w.min, w.med, w.max, CoachTuning.warmCastWarmth))
}
if let l = stats(results.map(\.luma)) {
    print(String(format: "luma                 min %.3f  median %.3f  max %.3f  (dark<%.2f ideal %.2f bright>%.2f)",
                 l.min, l.med, l.max, CoachTuning.lumaTooDark, CoachTuning.lumaIdeal, CoachTuning.lumaTooBright))
}

// The AI-photographer brain: turns the live camera stream into a readiness score
// + one prioritized coaching tip, and (per the pro's toggles) speaks / buzzes it.
//
// `CoachAnalyzer` is the AVFoundation frame delegate — it runs Vision + CoreImage
// off the main thread on a throttled subset of frames and emits a `CoachResult`.
// `CoachEngine` (MainActor) publishes that to the UI and fires voice/haptics.
import AVFoundation
import CoreImage
import QuartzCore
import UIKit
import Vision

// MARK: - Analyzer (frame queue)

final class CoachAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let coaches: [ShotCoach]
    private let ciContext = CIContext(options: [.priorityRequestLow: true])
    private let minInterval = 1.0 / CoachTuning.analysisFPS   // light-signal cadence
    private var lastSampleAt: CFTimeInterval = 0

    // The light signals (luma, face, sharpness) run every analyzed frame; the heavy
    // Vision requests (person segmentation + body pose) are far costlier, so they run
    // on a slower cadence and their last result is reused between runs.
    private let heavyInterval = 1.0 / CoachTuning.heavyFPS
    private var lastHeavyAt: CFTimeInterval = 0
    private var cachedClutter: Double?
    private var cachedSubjectFill: Double?
    private var cachedPose: PoseSignal?
    private var cachedColor: ColorSignal?
    /// Working resolution for the CoreImage / Vision math — full-res frames are
    /// needless cost for these aggregate signals.
    private let workingMaxDim = CoachTuning.workingMaxDim

    /// Set once before the camera starts; called on the frame queue.
    nonisolated(unsafe) var sink: (@Sendable (CoachResult) -> Void)?

    // Latest device roll (degrees off level) from CoreMotion, written on the main
    // queue and read on the frame queue — a small lock keeps the cross-queue scalar
    // safe. Nil until the first motion sample (or on the Simulator).
    private let tiltLock = NSLock()
    private var _deviceTilt: Double?
    func setDeviceTilt(_ value: Double?) { tiltLock.lock(); _deviceTilt = value; tiltLock.unlock() }
    private func currentDeviceTilt() -> Double? { tiltLock.lock(); defer { tiltLock.unlock() }; return _deviceTilt }

    // MARK: - Best-shot harvesting (Session Reel)
    /// When on, the analyzer grabs a high-res still whenever quality peaks — the
    /// "captures across the session, keeps the best frames" behavior. Synced from
    /// the pro's toggle.
    nonisolated(unsafe) var autoHarvestEnabled = false
    /// Emits a harvested JPEG + its readiness. The engine stages it for review.
    nonisolated(unsafe) var onHarvest: (@Sendable (Data, Double) -> Void)?
    private var lastHarvestAt: CFTimeInterval = 0
    private var harvestCount = 0
    private let minHarvestInterval = CoachTuning.minHarvestInterval
    private let maxHarvest = CoachTuning.maxHarvest
    private let harvestThreshold = CoachTuning.harvestThreshold

    init(coaches: [ShotCoach]) {
        self.coaches = coaches
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        guard now - lastSampleAt >= minInterval else { return }
        lastSampleAt = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // One upright, downscaled image drives all the CoreImage math so face/luma/
        // sharpness math share a single coordinate space (upright, top-left normalized).
        let working = downscaled(CIImage(cvPixelBuffer: pixelBuffer).oriented(.right))

        let face = detectFace(pixelBuffer)
        // Heavy Vision (segmentation + pose) on its own slower cadence; reuse last.
        if now - lastHeavyAt >= heavyInterval {
            lastHeavyAt = now
            let seg = segment(pixelBuffer, working: working)
            cachedClutter = seg?.clutter
            cachedSubjectFill = seg?.subjectFill
            cachedPose = bodyPose(pixelBuffer)
            cachedColor = colorSignal(working)
        }

        let ctx = FrameContext(
            avgLuma: averageLuma(working),
            faceBounds: face,
            faceLuma: face.map { regionLuma(working, normalizedTopLeft: $0) },
            sharpness: sharpness(working, subject: face),
            backgroundClutter: cachedClutter,
            subjectFill: cachedSubjectFill,
            pose: cachedPose,
            deviceTilt: currentDeviceTilt(),
            color: cachedColor
        )

        let signals = coaches.map { ($0.category, $0.evaluate(ctx)) }
        // Readiness is the importance-weighted mean — light + focus count for more
        // than a clean backdrop, per the beauty-photography priority order.
        let totalWeight = signals.reduce(0.0) { $0 + $1.0.weight }
        let readiness = totalWeight == 0 ? 0
            : signals.reduce(0.0) { $0 + $1.1.score * $1.0.weight } / totalWeight
        // The fix to surface = the biggest *weighted* deficiency among coaches that
        // have a tip — so a lighting problem outranks a slightly-busy background.
        let worst = signals
            .filter { $0.1.message != nil }
            .max { $0.0.weight * (1 - $0.1.score) < $1.0.weight * (1 - $1.1.score) }
        let nudge = worst.flatMap { entry in entry.1.message.map { CoachNudge(category: entry.0, message: $0) } }
        let statuses = signals.map { CoachStatus(category: $0.0, score: $0.1.score, message: $0.1.message) }

        sink?(CoachResult(readiness: readiness, nudge: nudge, statuses: statuses))

        // Harvest a keeper when quality peaks (rate-limited + capped).
        if autoHarvestEnabled,
           readiness >= harvestThreshold,
           now - lastHarvestAt >= minHarvestInterval,
           harvestCount < maxHarvest,
           let data = harvest(pixelBuffer) {
            lastHarvestAt = now
            harvestCount += 1
            onHarvest?(data, readiness)
        }
    }

    /// Convert the current frame to an upright JPEG for the best-shots tray. High
    /// JPEG quality — these can end up on the profile / Looks feed.
    private func harvest(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ciContext.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [quality: 0.95]
        )
    }

    // MARK: - Signals

    /// Average color of an image (CIAreaAverage → one pixel), each channel 0…1.
    /// Nil when the extent is degenerate.
    private func averageRGB(_ image: CIImage) -> (r: Double, g: Double, b: Double)? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: image,
                  kCIInputExtentKey: CIVector(cgRect: extent),
              ]),
              let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    private func averageLuma(_ image: CIImage) -> Double {
        guard let c = averageRGB(image) else { return 0.5 }
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
    }

    /// Color-of-light read: mixed light (warm↔cool spread across vertical thirds —
    /// window on one side, bulb on the other) + global green / warmth cast.
    private func colorSignal(_ working: CIImage) -> ColorSignal? {
        let e = working.extent
        guard e.width > 0, e.height > 0, let global = averageRGB(working) else { return nil }

        func warmth(_ c: (r: Double, g: Double, b: Double)) -> Double {
            (c.r - c.b) / (c.r + c.b + 1e-3)
        }
        let third = e.width / 3
        let warms: [Double] = (0..<3).compactMap { i in
            let rect = CGRect(x: e.minX + CGFloat(i) * third, y: e.minY, width: third, height: e.height)
            return averageRGB(working.cropped(to: rect)).map(warmth)
        }
        let mixed = warms.count >= 2 ? ((warms.max() ?? 0) - (warms.min() ?? 0)) : 0
        let greenTint = (2 * global.g - global.r - global.b) / (2 * global.g + global.r + global.b + 1e-3)
        return ColorSignal(mixed: max(0, mixed), greenTint: greenTint, warmth: warmth(global))
    }

    /// Largest face, normalized with a TOP-LEFT origin. Back camera in portrait →
    /// orient `.right` so Vision works in an upright frame.
    private func detectFace(_ pixelBuffer: CVPixelBuffer) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([request])
        guard let faces = request.results, !faces.isEmpty else { return nil }
        let largest = faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
        guard let bb = largest?.boundingBox else { return nil }
        // Vision origin is bottom-left → flip Y to top-left.
        return CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height)
    }

    /// Scale an image down so its largest side ≈ `workingMaxDim` (cheap aggregate math).
    private func downscaled(_ image: CIImage) -> CIImage {
        let maxSide = max(image.extent.width, image.extent.height)
        guard maxSide > workingMaxDim else { return image }
        let s = workingMaxDim / maxSide
        return image.transformed(by: CGAffineTransform(scaleX: s, y: s))
    }

    /// Average luma inside a normalized top-left rect of `image` (upright space).
    private func regionLuma(_ image: CIImage, normalizedTopLeft rect: CGRect) -> Double {
        averageLuma(crop(image, normalizedTopLeft: rect))
    }

    /// Crop an upright image to a normalized top-left rect, mapping to CIImage's
    /// bottom-left pixel space. Returns the full image if the rect is degenerate.
    private func crop(_ image: CIImage, normalizedTopLeft rect: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let px = CGRect(
            x: e.minX + rect.minX * e.width,
            y: e.minY + (1 - rect.maxY) * e.height,
            width: rect.width * e.width,
            height: rect.height * e.height
        ).intersection(e)
        guard !px.isNull, px.width >= 1, px.height >= 1 else { return image }
        return image.cropped(to: px)
    }

    /// Focus quality 0…1 from edge energy — measured on the subject region when a
    /// face is present (focus on the face, not a busy background), else whole frame.
    private func sharpness(_ image: CIImage, subject face: CGRect?) -> Double {
        let target = face.map { crop(image, normalizedTopLeft: expandToHead($0)) } ?? image
        // Edge energy: low for soft/blurred frames. Normalize against the reference
        // "sharp" edge-mean (CoachTuning).
        let energy = averageLuma(edges(target))
        return min(1.0, energy / CoachTuning.sharpnessReference)
    }

    /// Person-segmentation read for one frame: how much of the frame the subject
    /// fills (drives "get closer") and how busy the background is (drives "cleaner
    /// backdrop"). Nil when no person is found — flat-lay / detail shots aren't
    /// pushed toward an empty frame or nagged to get closer.
    private struct SegmentSignal { let clutter: Double?; let subjectFill: Double }

    private func segment(_ pixelBuffer: CVPixelBuffer, working: CIImage) -> SegmentSignal? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([request])
        guard let maskBuffer = request.results?.first?.pixelBuffer else { return nil }

        // Scale the (upright) mask onto the working extent. Mask: white = person.
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        let me = mask.extent
        guard me.width > 0, me.height > 0 else { return nil }
        mask = mask.transformed(by: CGAffineTransform(
            scaleX: working.extent.width / me.width,
            y: working.extent.height / me.height
        )).cropped(to: working.extent)
        let background = mask.applyingFilter("CIColorInvert")  // 1 - mask → background weight

        let bgFraction = averageLuma(background)
        let subjectFill = min(1.0, max(0.0, 1 - bgFraction))

        // Only judge clutter when there's enough background to judge (subject not
        // filling the whole frame).
        guard bgFraction > CoachTuning.minBackgroundFraction else {
            return SegmentSignal(clutter: nil, subjectFill: subjectFill)
        }
        // Edge energy that falls in the background = edges × background weight.
        let bgEdges = edges(working).applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: background,
        ])
        let bgEdgeMean = averageLuma(bgEdges.cropped(to: working.extent))
        // Normalize by background area, then against the "fully cluttered" reference.
        let clutter = min(1.0, max(0.0, (bgEdgeMean / bgFraction) / CoachTuning.clutterReference))
        return SegmentSignal(clutter: clutter, subjectFill: subjectFill)
    }

    /// Edge magnitude image (CIEdges) for energy measurement.
    private func edges(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIEdges", parameters: ["inputIntensity": 1.0])
    }

    /// Expand a face rect to roughly head-and-shoulders so subject-focused math
    /// (sharpness) doesn't sample only skin. Clamped to the unit square.
    private func expandToHead(_ face: CGRect) -> CGRect {
        let cx = face.midX
        let w = min(1.0, face.width * 2.0)
        let h = min(1.0, face.height * 2.2)
        let x = max(0.0, min(1.0 - w, cx - w / 2))
        let y = max(0.0, min(1.0 - h, face.minY - face.height * 0.3))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Body-pose framing read (upright, top-left normalized). Nil unless a body is
    /// confidently detected. Drives the level-shoulders / clipping tips.
    private func bodyPose(_ pixelBuffer: CVPixelBuffer) -> PoseSignal? {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first,
              let points = try? observation.recognizedPoints(.all) else { return nil }

        func point(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = points[name], p.confidence > CoachTuning.poseJointConfidence else { return nil }
            // Vision origin bottom-left → flip Y to top-left.
            return CGPoint(x: p.location.x, y: 1 - p.location.y)
        }

        // Clipping: any confident joint hard against a frame edge.
        let edgePad = CoachTuning.poseEdgePad
        let clipped = [VNHumanBodyPoseObservation.JointName.leftShoulder, .rightShoulder,
                       .leftHip, .rightHip, .leftWrist, .rightWrist, .neck]
            .compactMap(point)
            .contains { $0.x <= edgePad || $0.x >= 1 - edgePad || $0.y <= edgePad || $0.y >= 1 - edgePad }

        guard clipped else { return nil }
        return PoseSignal(edgeClipped: clipped)
    }
}

// MARK: - Engine (MainActor)

/// A high-res still the coach auto-harvested at a quality peak — staged for the
/// pro to review (keep/upload) rather than uploaded silently.
struct HarvestedShot: Identifiable {
    let id = UUID()
    let image: UIImage
    let data: Data
    let readiness: Double
}

@Observable
@MainActor
final class CoachEngine {
    private(set) var readiness: Double = 0
    private(set) var nudge: CoachNudge?
    /// Per-fundamental live status for the checklist HUD (light/level/frame/…).
    private(set) var statuses: [CoachStatus] = []
    /// Auto-harvested best shots awaiting review (newest first).
    private(set) var harvested: [HarvestedShot] = []
    /// Live device roll (degrees off level) for the on-screen horizon indicator.
    /// Nil until the first motion sample (or on the Simulator).
    private(set) var deviceRoll: Double?

    let analyzer: CoachAnalyzer
    private let settings: CoachSettings
    private let synthesizer = AVSpeechSynthesizer()
    private let level = DeviceLevelProvider()
    private var wasReady = false

    /// Readiness at/above this reads as "good to shoot" (green ring).
    static let readyThreshold = CoachTuning.readyThreshold

    var isReady: Bool { readiness >= Self.readyThreshold }

    init(settings: CoachSettings) {
        self.settings = settings
        self.analyzer = CoachAnalyzer(coaches: [
            LightingCoach(), CompositionCoach(), SharpnessCoach(),
            BackgroundCoach(), PoseCoach(), LevelCoach(), ColorCoach(),
        ])
        analyzer.autoHarvestEnabled = settings.autoHarvest
        analyzer.sink = { [weak self] result in
            Task { @MainActor in self?.apply(result) }
        }
        analyzer.onHarvest = { [weak self] data, readiness in
            Task { @MainActor in self?.addHarvest(data, readiness) }
        }
        // Feed device roll to both the live horizon UI and the level coach.
        level.onUpdate = { [weak self] roll in
            self?.deviceRoll = roll
            self?.analyzer.setDeviceTilt(roll)
        }
        level.start()
    }

    /// Stop the motion stream when the camera leaves the screen.
    func stop() { level.stop() }

    /// Drop reviewed shots (kept or discarded) from the tray.
    func removeHarvested(_ ids: Set<UUID>) {
        harvested.removeAll { ids.contains($0.id) }
    }

    private func addHarvest(_ data: Data, _ readiness: Double) {
        guard let image = UIImage(data: data) else { return }
        harvested.insert(HarvestedShot(image: image, data: data, readiness: readiness), at: 0)
    }

    private func apply(_ result: CoachResult) {
        // Keep the harvest gate in sync with the live toggle.
        analyzer.autoHarvestEnabled = settings.autoHarvest
        readiness = result.readiness
        statuses = result.statuses

        if result.nudge != nudge {
            nudge = result.nudge
            if let nudge = result.nudge {
                if settings.haptics { tap(.warning) }
                if settings.speak { speak(nudge.message) }
            }
        }

        let nowReady = isReady
        if nowReady && !wasReady && settings.haptics { tap(.success) }
        wasReady = nowReady
    }

    private func speak(_ text: String) {
        // Don't stack utterances — replace any in-flight tip.
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    private func tap(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

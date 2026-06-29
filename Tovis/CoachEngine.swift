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
    private var cachedPose: PoseSignal?
    /// Working resolution for the CoreImage / Vision math — full-res frames are
    /// needless cost for these aggregate signals.
    private let workingMaxDim = CoachTuning.workingMaxDim

    /// Set once before the camera starts; called on the frame queue.
    nonisolated(unsafe) var sink: (@Sendable (CoachResult) -> Void)?

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
            cachedClutter = backgroundClutter(pixelBuffer, working: working)
            cachedPose = bodyPose(pixelBuffer)
        }

        let ctx = FrameContext(
            avgLuma: averageLuma(working),
            faceBounds: face,
            faceLuma: face.map { regionLuma(working, normalizedTopLeft: $0) },
            sharpness: sharpness(working, subject: face),
            backgroundClutter: cachedClutter,
            pose: cachedPose
        )

        let signals = coaches.map { ($0.category, $0.evaluate(ctx)) }
        let readiness = signals.isEmpty ? 0 : signals.map { $0.1.score }.reduce(0, +) / Double(signals.count)
        // The single most important fix = the lowest-scoring coach that has a tip.
        let worst = signals.filter { $0.1.message != nil }.min { $0.1.score < $1.1.score }
        let nudge = worst.flatMap { entry in entry.1.message.map { CoachNudge(category: entry.0, message: $0) } }

        sink?(CoachResult(readiness: readiness, nudge: nudge))

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

    /// Convert the current frame to an upright JPEG for the best-shots tray.
    private func harvest(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        return ciContext.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [:]
        )
    }

    // MARK: - Signals

    private func averageLuma(_ image: CIImage) -> Double {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: image,
                  kCIInputExtentKey: CIVector(cgRect: extent),
              ]),
              let output = filter.outputImage else { return 0.5 }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let r = Double(pixel[0]) / 255, g = Double(pixel[1]) / 255, b = Double(pixel[2]) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b
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

    /// Busy-ness of the background, 0 (clean) … 1 (cluttered), via person
    /// segmentation: edge energy in the non-person area, area-normalized. Nil when
    /// no person is found (don't push non-portrait shots toward an empty frame).
    private func backgroundClutter(_ pixelBuffer: CVPixelBuffer, working: CIImage) -> Double? {
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
        ))
        let background = mask
            .applyingFilter("CIColorInvert")            // 1 - mask → background weight
            .cropped(to: working.extent)

        let bgFraction = averageLuma(background)
        guard bgFraction > CoachTuning.minBackgroundFraction else { return nil }  // subject fills frame

        // Edge energy that falls in the background = edges × background weight.
        let bgEdges = edges(working).applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: background,
        ])
        let bgEdgeMean = averageLuma(bgEdges.cropped(to: working.extent))
        // Normalize by background area, then against the "fully cluttered" reference.
        let clutter = (bgEdgeMean / bgFraction) / CoachTuning.clutterReference
        return min(1.0, max(0.0, clutter))
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

        // Shoulder tilt off horizontal.
        var tilt: Double?
        if let l = point(.leftShoulder), let r = point(.rightShoulder) {
            tilt = Double(atan2(l.y - r.y, l.x - r.x)) * 180 / .pi
            // Normalize to the acute deviation from a level line.
            if let t = tilt {
                let a = abs(t).truncatingRemainder(dividingBy: 180)
                tilt = min(a, 180 - a)
            }
        }

        // Clipping: any confident joint hard against a frame edge.
        let edgePad = CoachTuning.poseEdgePad
        let clipped = [VNHumanBodyPoseObservation.JointName.leftShoulder, .rightShoulder,
                       .leftHip, .rightHip, .leftWrist, .rightWrist, .neck]
            .compactMap(point)
            .contains { $0.x <= edgePad || $0.x >= 1 - edgePad || $0.y <= edgePad || $0.y >= 1 - edgePad }

        guard tilt != nil || clipped else { return nil }
        return PoseSignal(shoulderTilt: tilt, edgeClipped: clipped)
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
    /// Auto-harvested best shots awaiting review (newest first).
    private(set) var harvested: [HarvestedShot] = []

    let analyzer: CoachAnalyzer
    private let settings: CoachSettings
    private let synthesizer = AVSpeechSynthesizer()
    private var wasReady = false

    /// Readiness at/above this reads as "good to shoot" (green ring).
    static let readyThreshold = CoachTuning.readyThreshold

    var isReady: Bool { readiness >= Self.readyThreshold }

    init(settings: CoachSettings) {
        self.settings = settings
        self.analyzer = CoachAnalyzer(coaches: [
            LightingCoach(), CompositionCoach(), SharpnessCoach(), BackgroundCoach(), PoseCoach(),
        ])
        analyzer.autoHarvestEnabled = settings.autoHarvest
        analyzer.sink = { [weak self] result in
            Task { @MainActor in self?.apply(result) }
        }
        analyzer.onHarvest = { [weak self] data, readiness in
            Task { @MainActor in self?.addHarvest(data, readiness) }
        }
    }

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

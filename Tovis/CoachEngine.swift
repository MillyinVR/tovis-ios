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

    // The current guided shot's expectations (nil = freeform), written from the
    // camera view on step change and read per frame — same cross-queue pattern.
    private let expectationsLock = NSLock()
    private var _expectations: ShotExpectations?
    func setExpectations(_ value: ShotExpectations?) {
        expectationsLock.lock(); _expectations = value; expectationsLock.unlock()
    }
    private func currentExpectations() -> ShotExpectations? {
        expectationsLock.lock(); defer { expectationsLock.unlock() }; return _expectations
    }

    // MARK: - Best-shot harvesting (Session Reel)
    /// When on, the analyzer grabs a high-res still whenever quality peaks — the
    /// "captures across the session, keeps the best frames" behavior. Synced from
    /// the pro's toggle.
    nonisolated(unsafe) var autoHarvestEnabled = false
    /// Emits a harvested JPEG + its readiness. The engine stages it for review.
    nonisolated(unsafe) var onHarvest: (@Sendable (Data, Double) -> Void)?
    private var lastHarvestAt: CFTimeInterval = 0
    /// How many harvested shots are currently staged (unreviewed) in the tray.
    /// The engine writes the authoritative tray count after every add/review, so
    /// reviewing shots re-opens harvest headroom — the cap bounds the *tray*, not
    /// the whole session. Same cross-queue pattern as `autoHarvestEnabled`.
    nonisolated(unsafe) var stagedCount = 0

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

        // Every analyzed frame allocates a lot of transient CoreImage/Vision backing
        // (downscaled CIImages, GPU render intermediates, Vision mask buffers, the
        // harvest JPEG). CoreImage/Vision hand those back as *autoreleased* objects,
        // and on this busy serial frame queue the thread's pool is not drained
        // reliably between back-to-back frames — so without an explicit pool the
        // footprint climbs until iOS jetsam-kills the app a few seconds in. Draining
        // per frame keeps peak memory flat. (Runs fully only with a real subject in
        // frame — an empty test scene short-circuits the heavy path, which is why
        // this only bit during a live session.)
        autoreleasepool {
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

            let avgLuma = averageLuma(working)
            let ctx = FrameContext(
                avgLuma: avgLuma,
                faceBounds: face,
                faceLuma: face.map { regionLuma(working, normalizedTopLeft: $0) },
                sharpness: sharpness(working, subject: face),
                backgroundClutter: cachedClutter,
                subjectFill: cachedSubjectFill,
                pose: cachedPose,
                deviceTilt: currentDeviceTilt(),
                color: cachedColor,
                expectations: currentExpectations()
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

            // Center-region average color — the neutral sample for gray-card WB.
            let e = working.extent
            let centerRect = CGRect(x: e.minX + e.width * 0.3, y: e.minY + e.height * 0.3,
                                    width: e.width * 0.4, height: e.height * 0.4)
            let center = averageRGB(working.cropped(to: centerRect)) ?? (0.5, 0.5, 0.5)

            var debug: [DebugSignal]?
            if CoachDebug.captureSignals {
                debug = [
                    DebugSignal(name: "luma", value: avgLuma),
                    DebugSignal(name: "faceLuma", value: ctx.faceLuma ?? -1),
                    DebugSignal(name: "sharpness", value: ctx.sharpness),
                    DebugSignal(name: "clutter", value: ctx.backgroundClutter ?? -1),
                    DebugSignal(name: "fill", value: ctx.subjectFill ?? -1),
                    DebugSignal(name: "tilt°", value: ctx.deviceTilt ?? 0),
                    DebugSignal(name: "mixed", value: ctx.color?.mixed ?? -1),
                    DebugSignal(name: "green", value: ctx.color?.greenTint ?? -1),
                    DebugSignal(name: "warmth", value: ctx.color?.warmth ?? -1),
                    DebugSignal(name: "READY", value: readiness),
                ]
            }

            sink?(CoachResult(readiness: readiness, nudge: nudge, statuses: statuses,
                              centerR: center.r, centerG: center.g, centerB: center.b,
                              faceCenter: face.map { CGPoint(x: $0.midX, y: $0.midY) },
                              frameLuma: avgLuma, frameWarmth: cachedColor?.warmth,
                              debug: debug))

            // Harvest a keeper when quality peaks (rate-limited + capped).
            if autoHarvestEnabled,
               readiness >= CoachTuning.harvestThreshold,
               now - lastHarvestAt >= CoachTuning.minHarvestInterval,
               stagedCount < CoachTuning.maxHarvest,
               let data = harvest(pixelBuffer) {
                lastHarvestAt = now
                stagedCount += 1   // engine overwrites with the real tray count
                onHarvest?(data, readiness)
            }
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
    // (Shared measurement math lives in FrameMath — one implementation for the
    // live coach, post-capture QC, and the before/after light matcher.)

    private func averageRGB(_ image: CIImage) -> (r: Double, g: Double, b: Double)? {
        FrameMath.averageRGB(image, context: ciContext)
    }

    private func averageLuma(_ image: CIImage) -> Double {
        FrameMath.averageLuma(image, context: ciContext)
    }

    /// Color-of-light read: mixed light (warm↔cool spread across vertical thirds —
    /// window on one side, bulb on the other) + global green / warmth cast.
    private func colorSignal(_ working: CIImage) -> ColorSignal? {
        let e = working.extent
        guard e.width > 0, e.height > 0, let global = averageRGB(working) else { return nil }

        let third = e.width / 3
        let warms: [Double] = (0..<3).compactMap { i in
            let rect = CGRect(x: e.minX + CGFloat(i) * third, y: e.minY, width: third, height: e.height)
            return averageRGB(working.cropped(to: rect)).map(FrameMath.warmth)
        }
        let mixed = warms.count >= 2 ? ((warms.max() ?? 0) - (warms.min() ?? 0)) : 0
        let greenTint = (2 * global.g - global.r - global.b) / (2 * global.g + global.r + global.b + 1e-3)
        return ColorSignal(mixed: max(0, mixed), greenTint: greenTint, warmth: FrameMath.warmth(global))
    }

    /// Largest face (upright top-left normalized). Back camera in portrait →
    /// orient `.right` so Vision works in an upright frame. Shared extraction
    /// lives in VisionDetect (the reference-look analyzer uses the same eyes).
    private func detectFace(_ pixelBuffer: CVPixelBuffer) -> CGRect? {
        VisionDetect.largestFace(performing: VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer, orientation: .right, options: [:]))
    }

    /// Scale an image down so its largest side ≈ `workingMaxDim` (cheap aggregate math).
    private func downscaled(_ image: CIImage) -> CIImage {
        FrameMath.downscaled(image, maxDim: workingMaxDim)
    }

    /// Average luma inside a normalized top-left rect of `image` (upright space).
    private func regionLuma(_ image: CIImage, normalizedTopLeft rect: CGRect) -> Double {
        averageLuma(FrameMath.crop(image, normalizedTopLeft: rect))
    }

    /// Focus quality 0…1 from edge energy on the subject region (see FrameMath).
    private func sharpness(_ image: CIImage, subject face: CGRect?) -> Double {
        FrameMath.sharpness(image, subject: face, context: ciContext)
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
        guard let maskBuffer = request.results?.first?.pixelBuffer,
              let seg = FrameMath.segmentation(maskBuffer: maskBuffer, working: working,
                                               context: ciContext) else { return nil }

        // Only judge clutter when there's enough background to judge (subject not
        // filling the whole frame).
        guard seg.backgroundFraction > CoachTuning.minBackgroundFraction else {
            return SegmentSignal(clutter: nil, subjectFill: seg.subjectFill)
        }
        // Edge energy that falls in the background = edges × background weight.
        let bgEdges = FrameMath.edges(working).applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: seg.background,
        ])
        let bgEdgeMean = averageLuma(bgEdges.cropped(to: working.extent))
        // Normalize by background area, then against the "fully cluttered" reference.
        let clutter = min(1.0, max(0.0, (bgEdgeMean / seg.backgroundFraction) / CoachTuning.clutterReference))
        return SegmentSignal(clutter: clutter, subjectFill: seg.subjectFill)
    }

    /// Body-pose read (upright, top-left normalized). Nil unless a body is
    /// confidently detected. Shared extraction lives in VisionDetect.
    private func bodyPose(_ pixelBuffer: CVPixelBuffer) -> PoseSignal? {
        VisionDetect.poseSignal(performing: VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer, orientation: .right, options: [:]))
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
    /// How long the shot has been continuously good, 0…1 toward the auto-capture
    /// hold — drives the shutter "filling" ring so the pro sees it deciding.
    private(set) var holdProgress: Double = 0
    /// True once the shot has been good + steady long enough to auto-capture.
    private(set) var isSteadyReady = false
    private var readySince: Date?
    /// Latest center-region average color — the neutral sample for gray-card WB.
    private(set) var centerSample: (r: Double, g: Double, b: Double) = (0.5, 0.5, 0.5)
    /// Live whole-frame luma + warmth — the before/after light matcher compares
    /// these against the before shot's stamp.
    private(set) var frameLuma: Double = 0.5
    private(set) var frameWarmth: Double?
    /// Face-priority exposure feed — the camera view wires this to
    /// `CameraController.setFaceExposure` so the camera meters for the face.
    var onFaceCenter: ((CGPoint?) -> Void)?
    /// Raw perception values for the DEBUG tuning console (empty when closed).
    private(set) var debugSignals: [DebugSignal] = []

    let analyzer: CoachAnalyzer
    private let settings: CoachSettings
    private let synthesizer = AVSpeechSynthesizer()
    private let level = DeviceLevelProvider()
    private var wasReady = false
    /// Whether we've claimed the audio session for spoken tips (lazily, on the
    /// first utterance — so camera sessions with voice off never touch audio).
    private var audioSessionConfigured = false

    /// Readiness at/above the tuning threshold reads as "good to shoot" (green
    /// ring). Read live (not captured) so the tuning console applies instantly.
    var isReady: Bool { readiness >= CoachTuning.readyThreshold }

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

    /// Restart the motion stream when the camera (re)appears. `init` starts it,
    /// but presenting a fullScreenCover (the frame scrubber) fires the camera
    /// view's `onDisappear` → `stop()`, and the engine is reused on return — so
    /// the view's `.task` must re-arm the level or the horizon freezes stale.
    func start() { level.start() }

    /// Stop the motion stream when the camera leaves the screen.
    func stop() {
        level.stop()
        // Release the speech audio session so ducked audio (salon music) recovers.
        if audioSessionConfigured {
            audioSessionConfigured = false
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    /// Drop reviewed shots (kept or discarded) from the tray. Reviewing re-opens
    /// harvest headroom (the cap bounds the unreviewed tray, not the session).
    func removeHarvested(_ ids: Set<UUID>) {
        harvested.removeAll { ids.contains($0.id) }
        analyzer.stagedCount = harvested.count
    }

    private func addHarvest(_ data: Data, _ readiness: Double) {
        guard let image = UIImage(data: data) else { return }
        harvested.insert(HarvestedShot(image: image, data: data, readiness: readiness), at: 0)
        analyzer.stagedCount = harvested.count
    }

    private func apply(_ result: CoachResult) {
        // Keep the harvest gate in sync with the live toggle.
        analyzer.autoHarvestEnabled = settings.autoHarvest
        readiness = result.readiness
        statuses = result.statuses
        centerSample = (result.centerR, result.centerG, result.centerB)
        frameLuma = result.frameLuma
        if let warmth = result.frameWarmth { frameWarmth = warmth }
        if let debug = result.debug { debugSignals = debug }
        onFaceCenter?(result.faceCenter)

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

        // Track how long the shot has held good, for auto-capture + the filling ring.
        if nowReady {
            if readySince == nil { readySince = Date() }
            let held = Date().timeIntervalSince(readySince ?? Date())
            holdProgress = min(1, held / CoachTuning.autoCaptureHoldSeconds)
            isSteadyReady = held >= CoachTuning.autoCaptureHoldSeconds
        } else {
            readySince = nil
            holdProgress = 0
            isSteadyReady = false
        }
    }

    /// Re-arm the auto-capture hold after a shot fires (so it doesn't immediately
    /// re-trigger before the pro moves to the next angle).
    func resetHold() {
        readySince = nil
        holdProgress = 0
        isSteadyReady = false
    }

    /// Speak a one-off line (guided directives / capture confirmations). The caller
    /// decides whether voice is enabled.
    func announce(_ text: String) { speak(text) }

    private func speak(_ text: String) {
        // `.playback` sounds through the silent switch — a salon phone is almost
        // always on silent, which would otherwise mute every spoken tip. Duck
        // (don't stop) any music playing in the salon.
        if !audioSessionConfigured {
            audioSessionConfigured = true
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            try? session.setActive(true)
        }
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

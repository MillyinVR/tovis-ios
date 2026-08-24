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
    private var cachedCropSubjectFill: Double?
    private var cachedBackgroundLuma: Double?
    private var cachedPose: PoseSignal?
    private var cachedColor: ColorSignal?
    /// Dwell + switching margin for the one on-screen tip. Frame-queue-confined
    /// (this delegate is serial), which is where the ranking already happens.
    private var tipArbiter = CoachTipArbiter()
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

    // The publish crop the pro is composing to, when the crop-safe guide is on
    // — written from the camera view, read per frame, same cross-queue pattern.
    // Nil = the guide is off, so composition is judged over the whole frame.
    private let cropLock = NSLock()
    private var _cropGuide: CGRect?
    func setCropGuide(_ value: CGRect?) {
        cropLock.lock(); _cropGuide = value; cropLock.unlock()
    }
    private func currentCropGuide() -> CGRect? {
        cropLock.lock(); defer { cropLock.unlock() }; return _cropGuide
    }

    // Room-condition tips the pro has retired at THIS salon location
    // (`CoachRoomMemory`) — written from the engine when the memory is set and
    // when the pro taps the offer, read per frame, same cross-queue pattern as
    // the tilt/expectations/crop above. Empty = the coach says everything it
    // always did, which is what practice, a mobile shoot and every unmemorised
    // room get.
    private let dismissedLock = NSLock()
    private var _dismissedMoments: Set<CoachMoment> = []
    func setDismissedMoments(_ value: Set<CoachMoment>) {
        dismissedLock.lock(); _dismissedMoments = value; dismissedLock.unlock()
    }
    private func currentDismissedMoments() -> Set<CoachMoment> {
        dismissedLock.lock(); defer { dismissedLock.unlock() }; return _dismissedMoments
    }

    // MARK: - Best-shot harvesting (Session Reel)
    /// When on, the analyzer grabs a high-res still whenever a frame earns it —
    /// a readiness peak, or the best frame of a steady green hold (see
    /// `CoachHarvestGate`). The "captures across the session, keeps the best
    /// frames" behavior. Synced from the pro's toggle.
    nonisolated(unsafe) var autoHarvestEnabled = false
    /// Emits a harvested JPEG + its readiness + the frame's face center (camera
    /// C6, normalized top-left; nil when no face). The engine stages it for review.
    nonisolated(unsafe) var onHarvest: (@Sendable (Data, Double, CGPoint?) -> Void)?
    /// WHICH frames the reel admits — the readiness peak it always took, plus
    /// the steady-green-hold backstop that keeps an ordinary session from
    /// ending with an empty tray. Pure policy, pulled out into its own type so
    /// it can be driven a frame at a time without a camera (CoachHarvestGate.swift).
    /// Frame-queue-confined, like `tipArbiter`: this delegate is serial.
    private var harvestGate = CoachHarvestGate()

    /// The full-res JPEG encode is expensive and mustn't run inline on the serial
    /// frame queue (it would stall analysis for the whole encode). It runs on this
    /// serial queue instead, with its own CIContext so a full-res harvest render
    /// never contends with the per-frame analysis renders.
    private let harvestQueue = DispatchQueue(label: "tovis.coach.harvest", qos: .utility)
    private let harvestContext = CIContext(options: [.priorityRequestLow: true])

    /// Unreviewed-tray headroom, capped at `maxHarvest`. Single-owner: the count
    /// is mutated ONLY through the lock-guarded reserve/release helpers below —
    /// the frame queue reserves a slot before it hands a frame to the encode, the
    /// encode releases it if the JPEG fails, and the engine releases slots as
    /// reviewed shots leave the tray. It stays equal to (staged tray + in-flight
    /// encodes), so the cap bounds both. (Replaces a plain cross-queue `Int` that
    /// the frame queue and the main actor both wrote — a real data race.)
    private let harvestCountLock = NSLock()
    private var _harvestSlots = 0

    /// Claim a harvest slot; true only while the tray (+ in-flight encodes) is
    /// still under the cap. Called on the frame queue.
    private func reserveHarvestSlot() -> Bool {
        harvestCountLock.lock(); defer { harvestCountLock.unlock() }
        guard _harvestSlots < CoachTuning.maxHarvest else { return false }
        _harvestSlots += 1
        return true
    }

    /// Give slots back — a failed encode (1), or shots leaving the tray on review
    /// (n). Called from the encode queue and the main actor; the lock makes both safe.
    func releaseHarvestSlots(_ n: Int = 1) {
        harvestCountLock.lock(); defer { harvestCountLock.unlock() }
        _harvestSlots = max(0, _harvestSlots - n)
    }

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
            let cropGuide = currentCropGuide()
            // Heavy Vision (segmentation + pose) on its own slower cadence; reuse last.
            //
            // The mask's derived numbers are cached; the mask IMAGE is not. It
            // is measured through here, while the Vision buffer backing it is
            // still alive, and released with this frame's pool — holding it
            // across frames would pin a buffer in exactly the path that has
            // already been jetsam-killed once.
            if now - lastHeavyAt >= heavyInterval {
                lastHeavyAt = now
                let seg = segment(pixelBuffer, working: working, cropGuide: cropGuide)
                cachedClutter = seg?.clutter
                cachedSubjectFill = seg?.subjectFill
                cachedCropSubjectFill = seg?.cropSubjectFill
                cachedBackgroundLuma = seg?.backgroundLuma
                cachedPose = bodyPose(pixelBuffer)
                cachedColor = FrameMath.colorSignal(working, background: seg?.background,
                                                    context: ciContext)
            }

            let avgLuma = averageLuma(working)
            let ctx = FrameContext(
                avgLuma: avgLuma,
                faceBounds: face,
                faceLuma: face.map { regionLuma(working, normalizedTopLeft: $0) },
                backgroundLuma: cachedBackgroundLuma,
                sharpness: sharpness(working, subject: face),
                backgroundClutter: cachedClutter,
                subjectFill: cachedSubjectFill,
                cropGuide: cropGuide,
                cropSubjectFill: cachedCropSubjectFill,
                pose: cachedPose,
                deviceTilt: currentDeviceTilt(),
                color: cachedColor,
                expectations: currentExpectations()
            )

            // Scoring arithmetic lives in CoachAggregate (pure, camera-free) so it
            // can be tuned and tested without hardware. The arbiter carries the
            // tip's dwell across frames so the one line stops being re-ranked
            // six times a second.
            // The arbiter is frame-queue-confined, so the retired set is read
            // across the queue boundary here and handed to it as a plain value
            // — the ranking itself stays pure.
            tipArbiter.dismissed = currentDismissedMoments()
            let verdict = CoachAggregate.evaluate(coaches, ctx, arbiter: &tipArbiter, now: now)
            let readiness = verdict.readiness
            let nudge = verdict.nudge
            let statuses = verdict.statuses

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
                    // The complexion sweep's key column: the whole point of the
                    // face-vs-room fix is that these two disagree.
                    DebugSignal(name: "bgLuma", value: ctx.backgroundLuma ?? -1),
                    DebugSignal(name: "face/bg", value: (ctx.faceLuma).flatMap { f in
                        ctx.backgroundLuma.map { $0 > 0 ? f / $0 : -1 }
                    } ?? -1),
                    DebugSignal(name: "sharpness", value: ctx.sharpness),
                    DebugSignal(name: "clutter", value: ctx.backgroundClutter ?? -1),
                    DebugSignal(name: "fill", value: ctx.subjectFill ?? -1),
                    DebugSignal(name: "cropFill", value: ctx.cropSubjectFill ?? -1),
                    DebugSignal(name: "tilt°", value: ctx.deviceTilt ?? 0),
                    DebugSignal(name: "mixed", value: ctx.color?.mixed ?? -1),
                    DebugSignal(name: "green", value: ctx.color?.greenTint ?? -1),
                    DebugSignal(name: "warmth", value: ctx.color?.warmth ?? -1),
                    // 1 = colour was measured on the background (subject
                    // excluded); 0 = whole frame stood in.
                    DebugSignal(name: "bgScoped", value: ctx.color?.backgroundScoped == true ? 1 : 0),
                    DebugSignal(name: "READY", value: readiness),
                ]
            }

            sink?(CoachResult(readiness: readiness, nudge: nudge, statuses: statuses,
                              centerR: center.r, centerG: center.g, centerB: center.b,
                              faceCenter: face.map { CGPoint(x: $0.midX, y: $0.midY) },
                              frameLuma: avgLuma, frameWarmth: cachedColor?.warmth,
                              frameBackgroundLuma: cachedBackgroundLuma,
                              cleared: verdict.cleared, advanced: verdict.advanced,
                              simplified: verdict.simplified,
                              debug: debug))

            // Harvest a keeper when the frame earns it (rate-limited + capped) —
            // a readiness peak, or the best frame of a steady green hold, which
            // is `CoachHarvestGate`'s call and not this queue's. `shouldHarvest`
            // sees EVERY analyzed frame, not only the ones that might pass: the
            // hold it measures is made of the frames that don't.
            //
            // Reserve the slot here, but run the full-res JPEG encode OFF this
            // frame queue so it never stalls analysis mid-burst. Retaining
            // `pixelBuffer` for the async encode is safe: the output discards
            // late frames, so a held buffer just drops the next frame or two
            // rather than backing up.
            let decision = harvestGate.shouldHarvest(readiness: readiness, now: now)
            if autoHarvestEnabled, decision.banks, reserveHarvestSlot() {
                harvestGate.didHarvest(readiness: readiness, at: now)
                let frame = pixelBuffer
                let banked = readiness
                // The subject focal for the smart 9:16 feed crop (camera C6): the
                // face center already computed for THIS frame, in the same upright
                // top-left space as the harvested JPEG (both from `.oriented(.right)`),
                // so it maps directly onto the render. Free — no extra detection.
                let faceCenter = face.map { CGPoint(x: $0.midX, y: $0.midY) }
                harvestQueue.async { [weak self] in
                    guard let self else { return }
                    guard let data = self.harvest(frame) else {
                        self.releaseHarvestSlots()   // encode failed — hand the slot back
                        return
                    }
                    self.onHarvest?(data, banked, faceCenter)
                }
            }
        }
    }

    /// Convert the current frame to an upright JPEG for the best-shots tray. High
    /// JPEG quality — these can end up on the profile / Looks feed. Runs on the
    /// harvest queue against its own CIContext (never the frame queue's).
    private func harvest(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return harvestContext.jpegRepresentation(
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

    /// Person-segmentation read for one frame: how much of the frame (and of the
    /// publish crop) the subject fills, how busy the background is, how bright
    /// it is, and the mask itself for the colour-of-light measurement. Nil when
    /// no person is found — flat-lay / detail shots aren't pushed toward an
    /// empty frame or nagged to get closer.
    ///
    /// The derivation lives in `FrameMath.segmentSignals`; this is only the
    /// pixel-buffer plumbing, so the offline bench measures the same numbers
    /// from the same code rather than from a copy of it.
    private func segment(_ pixelBuffer: CVPixelBuffer, working: CIImage, cropGuide: CGRect?)
        -> FrameMath.SegmentedFrame? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([request])
        guard let maskBuffer = request.results?.first?.pixelBuffer else { return nil }
        return FrameMath.segmentSignals(maskBuffer: maskBuffer, working: working,
                                        cropGuide: cropGuide, context: ciContext)
    }

    /// Body-pose read (upright, top-left normalized). Nil unless a body is
    /// confidently detected. Shared extraction lives in VisionDetect.
    private func bodyPose(_ pixelBuffer: CVPixelBuffer) -> PoseSignal? {
        VisionDetect.poseSignal(performing: VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer, orientation: .right, options: [:]))
    }
}

// MARK: - Engine (MainActor)

/// A high-res still the coach auto-harvested off a frame that earned it — a
/// readiness peak, or the best frame of a steady green hold (`CoachHarvestGate`)
/// — staged for the pro to review (keep/upload) rather than uploaded silently.
struct HarvestedShot: Identifiable {
    let id = UUID()
    /// Tray-cell thumbnail (640px). The full still is spilled to disk — holding
    /// up to 24 full-res JPEGs in RAM (~120–240 MB) is an OOM the camera can't
    /// afford — and read back from `fileURL` only at upload.
    let image: UIImage
    let fileURL: URL
    let readiness: Double
    /// Subject focal for the smart 9:16 feed crop (camera C6), normalized top-left;
    /// nil when the harvest frame had no face → center. Sent at upload.
    let focalPoint: CGPoint?
}

@Observable
@MainActor
final class CoachEngine: NSObject {
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
    /// Live whole-frame luma + the light's warmth — the before/after light
    /// matcher compares these against the before shot's stamp.
    private(set) var frameLuma: Double = 0.5
    private(set) var frameWarmth: Double?
    /// Live background-only luma, when a person is segmented. The light matcher
    /// prefers it: it changes when the ROOM's light changes, and doesn't change
    /// just because the client's hair went four shades lighter.
    private(set) var frameBackgroundLuma: Double?
    /// Face-priority exposure feed — the camera view wires this to
    /// `CameraController.setFaceExposure` so the camera meters for the face.
    var onFaceCenter: ((CGPoint?) -> Void)?
    /// Raw perception values for the DEBUG tuning console (empty when closed).
    private(set) var debugSignals: [DebugSignal] = []

    let analyzer: CoachAnalyzer
    /// Read on the main actor for each result so persisted pro toggles remain
    /// live, while an immutable caller can reuse the engine without touching
    /// those defaults.
    private let runtimeOptions: @MainActor () -> CoachRuntimeOptions
    private let synthesizer = AVSpeechSynthesizer()
    private let level = DeviceLevelProvider()
    private var wasReady = false
    /// When the last coaching buzz fired — the floor under haptic frequency.
    private var lastNudgeHapticAt: Date?
    /// Whether we've claimed the audio session for spoken tips (lazily, on the
    /// first utterance — so camera sessions with voice off never touch audio).
    private var audioSessionConfigured = false
    /// Pacing/coalescing/priority-interrupt + per-category repeat suppression
    /// — the whole "when does a request actually reach the synthesizer, and
    /// does it repeat itself" policy, pulled out into a pure type so it's
    /// testable without a live `AVSpeechSynthesizer` (see CoachSpeechScheduler.swift).
    private var speechScheduler = CoachSpeechScheduler()
    /// The active match look's trigger-bound direction lines (tovis-app #974)
    /// — set by the camera view while an AI-enhanced look drives the shoot,
    /// `.empty` otherwise. When a coaching moment fires that the look wrote a
    /// line for, that line REPLACES the generic correction in the published
    /// `nudge` (see `apply`), so it reaches every surface the same — spoken
    /// tip, lane chip, dimensions headline — on the same scheduler and
    /// per-category cooldown: the look changes the words, never the pacing.
    var lookDirections: LookDirectionScript = .empty
    /// What this shoot is OF, in the booking's own words — set by the camera
    /// view at a session, `.empty` when practising. Substituted into the
    /// coach's canonical text in `apply` (below), on the same scheduler and
    /// per-category cooldown as everything else: the booking changes the
    /// words, never the pacing. See `CoachBookingVocabulary`.
    var bookingVocabulary: CoachBookingVocabulary = .empty
    /// This salon room's memory of what the pro has already been told here —
    /// nil for practice, for a mobile shoot, and for any booking without a
    /// salon location, all of which coach exactly as they do today. Set once
    /// by the camera view at start-up via `setRoomMemory(_:)`.
    private(set) var roomMemory: CoachRoomMemory?
    /// The room-condition tip currently on the lane that this pro has now met
    /// often enough HERE to be offered a way to retire it, or nil (the normal
    /// case). The camera view turns this into the lane's one trailing word.
    private(set) var dismissalOffer: CoachMoment?
    /// The tip retired by the most recent tap, so the confirmation row can
    /// offer to put it back for the couple of seconds it is on screen.
    private var lastRoomDismissal: CoachMoment?
    /// When the look's settle line (`ready` trigger) last spoke — the floor
    /// under re-speaks when readiness flickers around the threshold.
    private var lastSettleLineAt: Date?

    /// Readiness at/above the tuning threshold reads as "good to shoot" (green
    /// ring). Read live (not captured) so the tuning console applies instantly.
    var isReady: Bool { readiness >= CoachTuning.readyThreshold }

    /// The pro's chosen coaching voice — read live off `settings` so changing
    /// it mid-session takes effect on the very next tip, same as every other
    /// coach toggle.
    var voice: CoachVoice { runtimeOptions().personality.voice }

    /// The nudge's line, in the active voice, with `why` appended when the
    /// voice's chattiness calls for it (`CoachVoice.includesWhy(for:)`) — the
    /// corrective itself is always canonical-or-personality text; only
    /// whether the reasoning rides along varies by pack.
    ///
    /// `simplified` is the back-off's "once more, simpler" pass (P4.3) — the
    /// `why` is dropped there, which on the DEFAULT voice is the longest thing
    /// in the utterance and the whole reason the line stopped being short. It
    /// is also the half of stage one that reaches every pack, since a pack's
    /// own words for the moment still win on screen.
    private func spokenLine(for nudge: CoachNudge, simplified: Bool = false) -> String {
        let rendered = CoachVoiceRenderer.render(
            nudge.moment, fallback: nudge.message,
            ctx: nudge.phraseCtx ?? CoachPhraseContext(), voice: voice) ?? nudge.message
        guard !simplified, let moment = nudge.moment, voice.includesWhy(for: moment),
              let why = statuses.first(where: { $0.category == nudge.category })?.why
        else { return rendered }
        return "\(rendered) \(why)"
    }

    convenience init(settings: CoachSettings) {
        self.init(runtimeOptions: { settings.runtimeOptions },
                  resetsProSessionByteVault: true)
    }

    /// Reuse the live analyzer/engine with memory-only behavior. This path does
    /// not sweep or stage the pro camera's disk-backed byte vault.
    convenience init(runtimeOptions: CoachRuntimeOptions) {
        self.init(runtimeOptions: { runtimeOptions }, resetsProSessionByteVault: false)
    }

    private init(runtimeOptions: @escaping @MainActor () -> CoachRuntimeOptions,
                 resetsProSessionByteVault: Bool) {
        self.runtimeOptions = runtimeOptions
        // A new engine == a fresh camera session. Sweep the session-scoped byte
        // store so best-shot / failed-upload spills stranded by a previous
        // dismiss or crash don't accumulate (they're discarded on exit anyway).
        if resetsProSessionByteVault { SessionByteVault.reset() }
        self.analyzer = CoachAnalyzer(coaches: [
            LightingCoach(), CompositionCoach(), SharpnessCoach(),
            BackgroundCoach(), PoseCoach(), LevelCoach(), ColorCoach(),
        ])
        super.init()
        // `didFinish`/`didCancel` is the only place a coalesced pending
        // utterance ever actually starts playing (`speechChannelFreed`) — see
        // the AVSpeechSynthesizerDelegate conformance below.
        synthesizer.delegate = self
        analyzer.autoHarvestEnabled = runtimeOptions().autoHarvest
        analyzer.sink = { [weak self] result in
            // Bind the weak reference before the Task — referencing the captured
            // optional from concurrently-executing code is an error under the
            // Swift 6 language mode. This closure is called from the live-frame
            // queue, so the crossing is real, not theoretical.
            guard let self else { return }
            Task { @MainActor in self.apply(result) }
        }
        analyzer.onHarvest = { [weak self] data, readiness, focalPoint in
            guard let self else { return }
            Task { @MainActor in self.addHarvest(data, readiness, focalPoint) }
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
    /// harvest headroom (the cap bounds the unreviewed tray, not the session):
    /// each removed shot releases its slot and its spilled bytes.
    func removeHarvested(_ ids: Set<UUID>) {
        let removed = harvested.filter { ids.contains($0.id) }
        for shot in removed { SessionByteVault.remove(shot.fileURL) }
        harvested.removeAll { ids.contains($0.id) }
        if !removed.isEmpty { analyzer.releaseHarvestSlots(removed.count) }
    }

    private func addHarvest(_ data: Data, _ readiness: Double, _ focalPoint: CGPoint?) {
        // Tray-cell decode only (up to 24 staged — full decodes would be GBs), then
        // spill the full-res bytes to disk so only the 640px thumb stays in memory.
        // If either step fails, hand back the slot the frame queue reserved so the
        // cap doesn't leak (the bytes are dropped rather than pinned in RAM).
        guard let image = ImageDownsample.thumbnailSync(from: data, maxPixel: 640),
              let url = SessionByteVault.write(data, to: .harvest) else {
            analyzer.releaseHarvestSlots()
            return
        }
        harvested.insert(
            HarvestedShot(image: image, fileURL: url, readiness: readiness, focalPoint: focalPoint),
            at: 0)
    }

    private func apply(_ result: CoachResult) {
        // Keep the harvest gate in sync with the live toggle.
        let options = runtimeOptions()
        analyzer.autoHarvestEnabled = options.autoHarvest
        readiness = result.readiness
        // The booking's vocabulary reaches the drawer's rows through the SAME
        // substitution as the lane's line below, so the two can't disagree
        // about what the coach just said.
        statuses = result.statuses.map { bookingVocabulary.applied(to: $0) }
        centerSample = (result.centerR, result.centerG, result.centerB)
        frameLuma = result.frameLuma
        if let warmth = result.frameWarmth { frameWarmth = warmth }
        frameBackgroundLuma = result.frameBackgroundLuma
        if let debug = result.debug { debugSignals = debug }
        onFaceCenter?(result.faceCenter)

        // The match look's own line for this correction, substituted ONCE,
        // here — so every surface downstream says the same words: the spoken
        // tip, the lane chip and the dimensions headline all read `nudge`,
        // and a pro shooting with voice OFF still gets the look's direction.
        // The moment is stripped on purpose: a look line is already a complete
        // direction, and both renderers (spokenLine, the lane) would otherwise
        // re-render the personality's canonical text for that moment OVER the
        // look's words — nil moment means "show/say this verbatim" on every
        // surface, the pre-personalities contract.
        //
        // The booking's vocabulary runs FIRST and UNDER the look: it only ever
        // swaps a noun in the canonical text ("Center Maya" for "Center your
        // subject"), keeping the moment so a personality pack still gets to
        // flourish, while a look line is a bespoke sentence that replaces the
        // whole correction. Both are pure word substitutions on a correction
        // the coach had already decided to give.
        //
        // The back-off's "once more, simpler" pass (P4.3) runs LAST and only
        // when the look hasn't already replaced the whole correction: a look
        // line is a bespoke sentence written for this shot, and shortening
        // someone else's sentence is not this layer's business — the same call
        // #359 made when it withheld the room-memory offer from a look line.
        // Under a booking, the plain form still names the client, because
        // `CoachPlainLine` builds from the vocabulary rather than from the
        // canonical text.
        let effectiveNudge = result.nudge.map { raw -> CoachNudge in
            let spoken = bookingVocabulary.applied(to: raw)
            if let look = lookDirections.line(replacing: spoken) {
                return CoachNudge(category: spoken.category, message: look)
            }
            return CoachPlainLine.applied(to: spoken, simplified: result.simplified,
                                          vocabulary: bookingVocabulary)
        }

        // Room memory (P4.1): count this shoot's sighting of the tip, and
        // decide whether the lane offers a way to retire it. The rule lives on
        // `CoachRoomMemory` so it is testable without a camera; nothing it
        // does touches `readiness`, `statuses` or the speech scheduler — it
        // decides whether ONE trailing word is offered.
        dismissalOffer = roomMemory?.offer(forRaw: result.nudge?.moment,
                                           published: effectiveNudge?.moment)

        // Sequential focus coaching: the ladder just moved off a rung that
        // read stable-good. `CoachTipArbiter` only reports either of these on
        // the single frame it happens — the debouncing (was this REALLY
        // fixed, not a flicker?) already happened at the decision layer, via
        // its own stability window, so neither needs a speech-side trust
        // guard the way the old un-debounced arbiter did.
        if let advanced = result.advanced, let nudge = effectiveNudge {
            // Compliment the rung that just cleared, then redirect to the
            // next one — ONE utterance, built from two ALREADY fully-voiced
            // complete sentences (this voice's own `goodMoment` line, this
            // voice's own line for `nudge`), never re-flourished against
            // each other. See `CoachMoment.focusRungAdvanced`.
            let complimentFallback = advanced.canonicalGoodPhrase
            let complimentRendered = CoachVoiceRenderer.render(
                advanced.goodMoment, fallback: complimentFallback, voice: voice) ?? complimentFallback
            let nextRendered = spokenLine(for: nudge, simplified: result.simplified)
            let fallback = "\(complimentRendered) \(nextRendered)"
            if options.speak {
                let line = CoachVoiceRenderer.render(
                    .focusRungAdvanced, fallback: fallback,
                    ctx: CoachPhraseContext(subjectNoun: complimentRendered, detail: nextRendered),
                    voice: voice) ?? fallback
                speakSchedulerTip(line, category: nudge.category)
            }
        } else if let cleared = result.cleared, options.speak {
            let fallback = "\(cleared.spokenName) — got it"
            let line = CoachVoiceRenderer.render(
                .dimensionCleared, fallback: fallback,
                ctx: CoachPhraseContext(subjectNoun: cleared.spokenName), voice: voice) ?? fallback
            speak(line, priority: .tip)
        }

        if effectiveNudge != nudge {
            let previous = nudge
            nudge = effectiveNudge
            if let nudge = effectiveNudge {
                // Buzz for NEWS. A haptic per re-rank is the mechanism behind
                // "it feels like nagging": with two near-tied coaches it was a
                // continuous warning vibration. Now it fires only when a
                // different dimension takes the line, and not twice in a beat.
                let now = Date()
                let sinceLast = lastNudgeHapticAt.map { now.timeIntervalSince($0) }
                    ?? .greatestFiniteMagnitude
                if options.haptics, nudge.category != previous?.category,
                   sinceLast >= CoachTuning.nudgeHapticMinInterval {
                    lastNudgeHapticAt = now
                    tap(.warning)
                }
                // Skip on an advance frame — the combined compliment+next
                // line above already spoke this exact nudge once.
                if options.speak, result.advanced == nil {
                    speakTip(nudge, simplified: result.simplified)
                }
            }
        }

        let nowReady = isReady
        if nowReady && !wasReady && options.haptics { tap(.success) }
        // The look's settle line — the `ready` trigger's "last word before the
        // shutter". Fires on the transition INTO ready (the same edge as the
        // success haptic), floored by `settleLineMinInterval` so readiness
        // flickering at the threshold can't re-speak it every crossing. A tip
        // priority: it never interrupts a line mid-flight, and with every gate
        // green there's no correction competing for the channel anyway.
        if nowReady, !wasReady, options.speak,
           let settle = lookDirections.line(for: .ready) {
            let now = Date()
            let sinceLast = lastSettleLineAt.map { now.timeIntervalSince($0) }
                ?? .greatestFiniteMagnitude
            if sinceLast >= CoachTuning.settleLineMinInterval {
                lastSettleLineAt = now
                speak(settle, priority: .tip)
            }
        }
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

    // MARK: - Room memory (P4.1)

    /// Hand the coach this shoot's room, or nil for one it shouldn't remember
    /// (practice, mobile, a booking with no salon location). Pushes the
    /// already-retired tips down to the analyzer so the very first analyzed
    /// frame of the shoot is already quiet about them — a pro who retired the
    /// overheads last week must not hear about them once more on the way in.
    func setRoomMemory(_ memory: CoachRoomMemory?) {
        roomMemory = memory
        dismissalOffer = nil
        lastRoomDismissal = nil
        analyzer.setDismissedMoments(memory?.dismissedMoments ?? [])
    }

    /// The pro tapped the lane's offer: this room's condition isn't theirs to
    /// change, so stop mentioning it HERE. Returns the confirmation sentence
    /// to put on the lane — already rendered in the pro's chosen voice, so the
    /// lane shows it verbatim rather than flourishing it a second time — or
    /// nil when there was nothing on offer.
    ///
    /// ⚠️ Suppression only. The retired condition still scores exactly what it
    /// scored, the ring still reads it, and the dimensions drawer still names
    /// it. See `CoachTipArbiter.dismissed`.
    @discardableResult
    func dismissRoomTip() -> String? {
        guard let moment = dismissalOffer, let roomMemory,
              roomMemory.dismiss(moment),
              let fallback = CoachRoomMemory.confirmation(for: moment)
        else { return nil }
        analyzer.setDismissedMoments(roomMemory.dismissedMoments)
        dismissalOffer = nil
        lastRoomDismissal = moment
        // The retired line is still the published nudge until the next
        // analyzed frame arrives (~1/6 s). Clear it now so the lane can't
        // flash the tip the pro just retired underneath its own confirmation.
        if nudge?.moment == moment { nudge = nil }
        let options = runtimeOptions()
        let line = CoachVoiceRenderer.render(
            .roomTipDismissed, fallback: fallback,
            ctx: CoachPhraseContext(detail: fallback), voice: voice) ?? fallback
        if options.haptics {
            tap(.success)
            // The next analyzed frame hands the lane to a different rung,
            // which normally earns its own "a new dimension is talking" buzz.
            // Landing that a fifth of a second after this confirmation is the
            // double-tap `nudgeHapticMinInterval` exists to stop, so this
            // counts as the beat.
            lastNudgeHapticAt = Date()
        }
        // `.tip` priority: warm, but it never interrupts a line mid-flight.
        if options.speak { speak(line, priority: .tip) }
        return line
    }

    /// Put back the tip the pro just retired. Only ever reachable from the
    /// confirmation row's own transient window — the lane stops offering it
    /// the moment that expires — so this is the misfire escape, not a second
    /// standing control. Returns the sentence to show, or nil if there was
    /// nothing to put back.
    @discardableResult
    func undoRoomDismissal() -> String? {
        guard let moment = lastRoomDismissal, let roomMemory,
              roomMemory.restore(moment) else { return nil }
        analyzer.setDismissedMoments(roomMemory.dismissedMoments)
        lastRoomDismissal = nil
        // Not re-offered here: `dismissalOffer` means "the tip ON THE LANE can
        // be retired", and the restored tip is not back on the lane yet — the
        // ladder takes up to `focusRegressionWindow` to preempt back to it.
        // The next analyzed frame establishes the truth, and because the shoot
        // count was left alone, a pro who DID mean it is one tap away again
        // the moment the tip returns.
        dismissalOffer = nil
        // Deliberately moment-less: this is a state announcement about a
        // CONTROL, in the same tier as the lane's own operational rows ("1
        // photo waiting on signal"), and it is not spoken. The coaching
        // sentence in this feature is `.roomTipDismissed`, which is.
        return "That tip is back"
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
    func announce(_ text: String) { speak(text, priority: .directive) }

    /// Ask `speechScheduler` what to do with a request, then carry it out —
    /// the only place this class actually touches `AVSpeechSynthesizer` to
    /// START something. What TEXT gets said is decided entirely by the
    /// callers above (`apply`, `announce`); this only ever decides WHEN a
    /// request actually reaches the synthesizer, never what fires.
    private func speak(_ text: String, priority: CoachSpeechScheduler.Priority) {
        ensureAudioSessionConfigured()
        perform(speechScheduler.request(text, priority: priority))
    }

    /// The coaching tip's speech path specifically — `apply`'s other callers
    /// of `speak` (`announce`, the `.dimensionCleared` line) aren't subject to
    /// per-fundamental repeat suppression, only the ongoing correction is.
    /// (A match look's substitution happened upstream, in `apply` — by the
    /// time a nudge reaches here its message IS the line to say.)
    private func speakTip(_ nudge: CoachNudge, simplified: Bool = false) {
        speakSchedulerTip(spokenLine(for: nudge, simplified: simplified),
                          category: nudge.category)
    }

    /// The per-category-cooldown speech path with pre-built text — used by
    /// `speakTip` for an ordinary nudge, and by the focus ladder's advance
    /// handling for the combined compliment+next line (which is ABOUT the
    /// next rung's category, for cooldown purposes, even though its text is
    /// two sentences).
    private func speakSchedulerTip(_ text: String, category: CoachCategory) {
        ensureAudioSessionConfigured()
        let action = speechScheduler.requestTip(text, category: category, now: Date().timeIntervalSinceReferenceDate)
        perform(action)
    }

    /// `.playback` sounds through the silent switch — a salon phone is almost
    /// always on silent, which would otherwise mute every spoken tip. Duck
    /// (don't stop) any music playing in the salon.
    private func ensureAudioSessionConfigured() {
        guard !audioSessionConfigured else { return }
        audioSessionConfigured = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? session.setActive(true)
    }

    /// Carry out whatever `CoachSpeechScheduler` decided. `.interruptThenSpeak`
    /// only stops the current utterance here — `didCancel` → `speechChannelFreed`
    /// is the only place a new utterance ever actually STARTS, so there's
    /// exactly one code path that begins one, regardless of how it got there.
    private func perform(_ action: CoachSpeechScheduler.Action) {
        switch action {
        case let .speak(text): startSpeaking(text)
        case .interruptThenSpeak: synthesizer.stopSpeaking(at: .immediate)
        case .none: break
        }
    }

    private func startSpeaking(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        // The best Enhanced/Premium voice actually installed for this device
        // (CoachSpeechVoice) — personalities never pick a DIFFERENT voice,
        // only how it's paced (rate/pitch/lead-in), same as everywhere else
        // "tone only" applies. `nil` here (no voice installed at all, never
        // happens in practice) just leaves AVSpeechUtterance's own default.
        utterance.voice = CoachSpeechVoice.best
        let rawRate = AVSpeechUtteranceDefaultSpeechRate * voice.speechRateMultiplier
        utterance.rate = min(max(rawRate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        utterance.pitchMultiplier = min(max(voice.speechPitch, 0.5), 2.0)
        utterance.preUtteranceDelay = voice.preUtteranceDelay
        synthesizer.speak(utterance)
    }

    /// The channel just freed up (an utterance finished or was interrupted) —
    /// play whatever's coalesced behind it, if anything.
    private func speechChannelFreed() {
        perform(speechScheduler.channelFreed())
    }

    private func tap(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

extension CoachEngine: AVSpeechSynthesizerDelegate {
    /// Delivered off the main thread — same cross-actor pattern as every
    /// other AVFoundation callback this engine handles (`CoachAnalyzer.sink`).
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speechChannelFreed() }
    }

    /// Fires when `stopSpeaking(at:)` interrupts an utterance (the directive-
    /// over-tip case in `speak(_:priority:)`) — the channel is just as free as
    /// on a normal finish, so the same handler applies.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speechChannelFreed() }
    }
}

// The one-time station read (camera plan P4.2): the pro points the camera at
// their empty station once, the coach measures the room's light, and
// `CoachRoomMemory` remembers it — see `CoachStationRead` for what the read
// is allowed to move and what it refuses to.
//
// Its OWN screen, deliberately — not the camera lane. The lane is the
// mid-shoot voice and every word on it is rationed; setup is a quiet moment
// with the room empty, which is exactly when the hub offers this sheet.
//
// ⚠️ No photo exists at any point. The sampler below measures live analysis
// frames at the coach's own working resolution and keeps only the numbers —
// nothing is captured, encoded, staged, uploaded or attested, and there are
// no bytes to delete because none are ever written. (The hard line: a
// station frame is a photo of a workplace outside any booking, and it must
// never reach the Session Reel, the publish path or the attestation chain.
// The strongest way to keep a photo out of every path is for it never to be
// a photo.)
import AVFoundation
import CoreImage
import SwiftUI
import Vision

// MARK: - The sampler (frame queue)

/// Feeds ~1s of live frames through `CoachStationRead.Accumulator` and hands
/// back the outcome. Same frame-queue patterns as `CoachAnalyzer` — throttled
/// cadence, one downscaled upright image, an autoreleasepool per frame — but
/// none of the coaches: this measures a room, not a photograph.
final class StationReadSampler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let ciContext = CIContext(options: [.priorityRequestLow: true])
    private let minInterval = 1.0 / CoachTuning.analysisFPS
    /// Guards the collection state — `begin()` is called on the main actor,
    /// frames arrive on the capture queue.
    private let lock = NSLock()
    private var collecting = false
    private var accumulator = CoachStationRead.Accumulator()
    private var lastSampleAt: CFTimeInterval = 0

    /// Called once per `begin()`, on the frame queue — the view hops home.
    nonisolated(unsafe) var onOutcome: (@Sendable (CoachStationRead.Outcome) -> Void)?

    /// Start one read attempt (discarding any half-finished previous one).
    func begin() {
        lock.lock(); defer { lock.unlock() }
        accumulator = CoachStationRead.Accumulator()
        collecting = true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        let active = collecting
        lock.unlock()
        guard active else { return }

        let now = CACurrentMediaTime()
        guard now - lastSampleAt >= minInterval else { return }
        lastSampleAt = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        autoreleasepool {
            // Upright + downscaled, exactly the live coach's working image —
            // the numbers stored must be the numbers the coach measures.
            let working = FrameMath.downscaled(
                CIImage(cvPixelBuffer: pixelBuffer).oriented(.right),
                maxDim: CoachTuning.workingMaxDim)
            let face = VisionDetect.largestFace(performing: VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer, orientation: .right, options: [:]))

            func thirdWarmth(_ i: Int) -> Double? {
                let rect = CGRect(x: Double(i) / 3.0, y: 0, width: 1.0 / 3.0, height: 1)
                return FrameMath.averageRGB(FrameMath.crop(working, normalizedTopLeft: rect),
                                            context: ciContext).map(FrameMath.warmth)
            }
            guard let global = FrameMath.averageRGB(working, context: ciContext),
                  let left = thirdWarmth(0), let middle = thirdWarmth(1),
                  let right = thirdWarmth(2)
            else { return }

            let sample = CoachStationRead.Sample(
                thirdWarmths: [left, middle, right],
                warmth: FrameMath.warmth(global),
                greenTint: FrameMath.greenTint(global),
                luma: FrameMath.luma(global),
                faceSeen: face != nil)

            lock.lock()
            accumulator.add(sample)
            let outcome = accumulator.outcome(readAt: Date())
            if outcome != nil { collecting = false }
            lock.unlock()
            if let outcome { onOutcome?(outcome) }
        }
    }
}

// MARK: - The sheet

/// The setup sheet the session hub presents for a salon room. Owns its own
/// `CameraController` — the shoot camera, its engine, its reel and its upload
/// paths are never involved.
struct StationReadView: View {
    let locationId: String?
    let locationType: String?

    @Environment(\.dismiss) private var dismiss
    @State private var camera = CameraController()
    @State private var sampler = StationReadSampler()

    private enum Phase: Equatable {
        case aiming
        case reading
        case done(CoachStationRead.Profile)
        case refused(String)
    }
    @State private var phase: Phase = .aiming

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch camera.status {
                // Not `CameraDeadEndView`: its second door is a library
                // import, and this screen deliberately has no media path at
                // all — a read can wait for the camera; a photo must not
                // stand in for one.
                case .denied:
                    cameraUnavailable("Camera access is off. Enable it in Settings to read the room — or just keep shooting; the coach works without a read.")
                case let .failed(message):
                    cameraUnavailable("The camera couldn’t start (\(message)). Close this and try again — the coach works without a read.")
                default:
                    CameraPreview(session: camera.session).ignoresSafeArea()
                    StationReadOverlay(phase: overlayPhase,
                                       onRead: beginRead,
                                       onDone: { dismiss() })
                }
            }
            .navigationTitle("Read your room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            // The bar is painted BLACK in both modes, so its contents have to
            // be told they are on a dark ground — otherwise the title and
            // Cancel render dark-on-black for a pro in light mode. Same class
            // of defect the render test caught in the overlay below.
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .task {
            sampler.onOutcome = { outcome in
                Task { @MainActor in handle(outcome) }
            }
            await camera.start(frameDelegate: sampler)
        }
        .onDisappear { camera.stop() }
    }

    private func cameraUnavailable(_ message: String) -> some View {
        VStack(spacing: 12) {
            // Fixed light-on-dark, same as the overlay: this sits on the
            // sheet's black ground in both modes.
            Text(message)
                .font(BrandFont.body(14)).foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Close") { dismiss() }
                .font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.accent)
        }
        .padding(24)
    }

    private var overlayPhase: StationReadOverlay.Phase {
        switch phase {
        case .aiming: return .aiming
        case .reading: return .reading
        case let .done(profile): return .done(summary: profile.summary)
        case let .refused(message): return .refused(message: message)
        }
    }

    private func beginRead() {
        phase = .reading
        sampler.begin()
    }

    private func handle(_ outcome: CoachStationRead.Outcome) {
        switch outcome {
        case let .read(profile):
            // The memory's own `init?` is the salon-only gate — a room this
            // sheet should never have been offered for records nothing.
            CoachRoomMemory(locationId: locationId, locationType: locationType)?
                .recordStationRead(profile)
            phase = .done(profile)
        case .someoneInFrame:
            phase = .refused("Someone’s in frame — this read is of the empty station, so the room’s light isn’t mixed up with skin and clothes.")
        case .tooDark:
            phase = .refused("Too dark to read. Bring the room up to the light you actually shoot in, then try again.")
        }
    }
}

/// The sheet's copy and controls, split from the preview so render tests can
/// look at every state without a live capture session.
struct StationReadOverlay: View {
    enum Phase: Equatable {
        case aiming
        case reading
        case done(summary: String)
        case refused(message: String)
    }

    let phase: Phase
    let onRead: () -> Void
    let onDone: () -> Void

    // Fixed light-on-dark styles, NOT BrandColor.text*: this sits over the
    // live preview on a black sheet, the one surface that is dark in both
    // modes — the same reason every other overlay in the camera chrome uses
    // plain `.white` (`ProCapturePhotosView`). The render test caught the
    // brand tokens disappearing here in light mode.
    private func headline(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.display(17)).foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func body13(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.body(13)).foregroundStyle(.white.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                switch phase {
                case .aiming:
                    headline("Snap your station once")
                    body13("Stand where you usually shoot and point the camera at your station — chair, mirror, backdrop, nobody in frame. The coach reads the window and the overheads and remembers this room.")
                    Text("No photo is kept — only the light reading.")
                        .font(BrandFont.body(12)).foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    actionButton("Read this room", action: onRead)
                case .reading:
                    headline("Reading the light…")
                    body13("Hold steady for a second.")
                case let .done(summary):
                    headline("Got it — \(summary)")
                    body13("The coach knows this room now. Re-read any time the light changes — a new bulb, a moved chair, a different backdrop.")
                    HStack(spacing: 10) {
                        actionButton("Done", action: onDone)
                        actionButton("Read again", prominent: false, action: onRead)
                    }
                case let .refused(message):
                    headline("Couldn’t read the room")
                    body13(message)
                    actionButton("Try again", action: onRead)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(16)
        }
    }

    private func actionButton(_ label: String, prominent: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .padding(.vertical, 10)
                .padding(.horizontal, 18)
                .background(prominent ? AnyShapeStyle(BrandColor.accent)
                                      : AnyShapeStyle(.white.opacity(0.14)))
                .clipShape(Capsule())
        }
    }
}

// MARK: - The hub's card / summary row

/// What the session hub shows for a salon room: an invitation while the room
/// has no (unexpired) station read, and a one-line summary with a re-read
/// affordance once it does — the standing answer to "the salon changed a
/// bulb". Renders nothing at all for practice, mobile, or no location, which
/// is `CoachRoomMemory.init?`'s call, not a second copy of that rule.
struct StationReadHubSection: View {
    let locationId: String?
    let locationType: String?
    /// Bumped by the hub when the sheet dismisses, so the row re-reads the
    /// stored profile.
    let refresh: Int
    let onRead: () -> Void
    /// Injectable for the render tests; the hub uses the real store.
    var store: UserDefaults = .standard

    var body: some View {
        if let memory = CoachRoomMemory(locationId: locationId, locationType: locationType,
                                        store: store) {
            if let profile = memory.stationProfile() {
                BrandSurface {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Room read · \(profile.summary)")
                                .font(BrandFont.body(13, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("The coach uses this in its tips here. Re-read if the light changes.")
                                .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Re-read") { onRead() }
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(BrandColor.accent)
                    }
                }
                .id(refresh)
            } else {
                BrandSurface {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Let the coach read your room")
                            .font(BrandFont.body(14, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text("Snap your station once — the coach learns the window and the overheads, and its tips here start from what your room actually is.")
                            .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Read this room") { onRead() }
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(BrandColor.accent)
                            .padding(.top, 2)
                    }
                }
                .id(refresh)
            }
        }
    }
}

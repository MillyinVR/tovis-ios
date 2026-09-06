import AVFoundation
import CoreImage
import Testing
import UIKit
@testable import Tovis

/// Whether this machine HAS a front/rear camera pair, and permission to use
/// it. Evaluated once, at file scope, because `@Test(.enabled(if:))` needs the
/// answer before an instance exists.
///
/// 🔴 A trait, not a `#require`. `try #require` FAILS a test; it does not skip
/// it — so guarding these with one turned every simulator run red, which is
/// every run in CI. A camera test on a machine with no camera is not a failure,
/// it is not applicable.
private let cameraPairAvailable: Bool =
    CameraController.preferredCaptureDevice(position: .front)?.position == .front
        && CameraController.preferredCaptureDevice(position: .back)?.position == .back

private let cameraUsable: Bool =
    cameraPairAvailable
        && AVCaptureDevice.authorizationStatus(for: .video) == .authorized

/// One live frame from the camera, captured off the frame queue.
private final class OneFrameGrabber: NSObject,
                                     AVCaptureVideoDataOutputSampleBufferDelegate,
                                     @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CIImage?

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); defer { lock.unlock() }
        guard stored == nil else { return }
        // Copied out of the pool buffer: the sample buffer is recycled the
        // moment this returns, so holding the CIImage that wraps it would leave
        // the test comparing whatever frame came later.
        stored = CIImage(cvPixelBuffer: buffer).applyingFilter(
            "CIAffineTransform", parameters: [kCIInputTransformKey: CGAffineTransform.identity]
        )
    }

    var frame: CIImage? { lock.lock(); defer { lock.unlock() }; return stored }
}

/// P3's flip, against the real capture stack.
///
/// 🔴 These are DEVICE tests and they are worth their runtime for one reason:
/// nothing in this path fails loudly. `preferredCaptureDevice` returning nil,
/// an input that cannot be added, `isVideoMirrored` raising on a connection
/// that does not support it — every one of those produces a camera that looks
/// fine and behaves wrong, and the simulator has no camera at all, so a green
/// simulator run says nothing about any of it.
///
/// They are gated on `.enabled(if:)` so a machine with no camera — every CI
/// runner, every simulator — SKIPS them rather than failing, which is what
/// keeps them armed on real hardware instead of being deleted for being red.
///
/// ⚠️ ONE suite, deliberately. `.serialized` orders tests WITHIN a suite;
/// separate suites still run in parallel, and two of them each opening a
/// capture session fail with AVFoundation -11803 "Cannot Record" — which
/// looks exactly like a broken flip and is not. Every test that claims the
/// camera belongs in here.
@Suite(.serialized) @MainActor struct CameraDeviceTests {

    /// Wait for the previous test's session to actually let go of the camera.
    ///
    /// `CameraController.stop()` enqueues `stopRunning()` and returns, so a
    /// `defer { camera.stop() }` has NOT released the hardware by the time the
    /// next test starts. Claiming it too early fails with AVFoundation -11803
    /// "Cannot Record", which reads as a broken flip and is not one.
    private func releaseCamera() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    @Test(.enabled(if: cameraPairAvailable))
    func bothCamerasResolveToTheSideThatWasAskedFor() throws {
        // The fallback in `preferredCaptureDevice` returns SOME camera when the
        // requested side has none, so a caller that does not check the position
        // it got back can silently open the wrong one. This is that check.
        #expect(CameraController.preferredCaptureDevice(position: .front)?.position == .front)
        #expect(CameraController.preferredCaptureDevice(position: .back)?.position == .back)
    }

    @Test(.enabled(if: cameraUsable))
    func aConsultCameraOpensOnTheSideThePolicyAsksForAndFlipsBack() async throws {
        try await releaseCamera()

        let camera = CameraController()
        // The eyes shot: front by policy, because she has to be able to compose
        // her own face.
        #expect(ConsultCaptureCrop.defaultCamera(for: .eyesCloseup) == .front)
        await camera.start(position: .front)
        defer { camera.stop() }

        #expect(camera.status == .ready)
        #expect(camera.cameraPosition == .front)

        let flipped = await camera.flip()
        #expect(flipped == .back)
        #expect(camera.cameraPosition == .back)
        // Still a live session after a reconfigure — a flip that left the
        // session torn down would be a black preview that still says `.ready`.
        #expect(camera.status == .ready)
        #expect(camera.session.isRunning)

        let backAgain = await camera.flip()
        #expect(backAgain == .front)
        #expect(camera.cameraPosition == .front)
        #expect(camera.session.isRunning)
    }

    @Test(.enabled(if: cameraUsable))
    func aStillCanStillBeTakenAfterAFlip() async throws {
        try await releaseCamera()

        let camera = CameraController()
        await camera.start(position: .front)
        defer { camera.stop() }
        try #require(camera.status == .ready)

        _ = await camera.flip()
        // The photo output's connection is reconfigured by the flip
        // (`pinConnectionGeometry`), and `applyFormatDependentSettings` re-reads
        // `activeFormat` for the NEW camera. Both are settings whose wrong value
        // is an uncatchable ObjC exception on the next capture rather than an
        // error return — so taking a picture is the only real test of them.
        let jpeg = try await camera.capturePhoto()
        #expect(jpeg.count > 1_000, "a real still, not an empty buffer")
    }

    @Test func bothCamerasShareOneOrientationBecauseMirroringIsPinnedOff() {
        // Measured, not assumed — see `CameraDeviceTests`,
        // which is the test that actually decides this and which rejected the
        // conventional `.leftMirrored` answer on real hardware. This one only
        // pins the conclusion so a casual edit has to argue with it.
        #expect(CameraController.sourceOrientation(for: .back) == .right)
        #expect(CameraController.sourceOrientation(for: .front) == .right)
    }



    private static let candidates: [CGImagePropertyOrientation] = [
        .up, .down, .left, .right,
        .upMirrored, .downMirrored, .leftMirrored, .rightMirrored,
    ]

    /// A small grayscale grid of an image, for comparing two renderings of the
    /// same scene regardless of resolution.
    private func signature(_ image: CIImage, context: CIContext) -> [Double]? {
        let side = 16
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(side) / extent.width, y: CGFloat(side) / extent.height
        ))
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        context.render(scaled,
                       toBitmap: &bytes,
                       rowBytes: side * 4,
                       bounds: CGRect(x: 0, y: 0, width: side, height: side),
                       format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        // Spelled out in statements rather than one expression: as a single
        // `map` closure this took the type checker past its budget on a CI
        // runner (fine locally, "unable to type-check in reasonable time"
        // there) — an inference cost, not a complexity one.
        var luma: [Double] = []
        luma.reserveCapacity(side * side)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let r = Double(bytes[i])
            let g = Double(bytes[i + 1])
            let b = Double(bytes[i + 2])
            let y: Double = 0.299 * r + 0.587 * g + 0.114 * b
            luma.append(y / 255.0)
        }
        return luma
    }

    /// Pearson correlation — brightness- and contrast-invariant, so an exposure
    /// difference between the preview stream and the still does not decide the
    /// answer. Only the GEOMETRY does.
    private func correlation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let ma = a.reduce(0, +) / Double(a.count)
        let mb = b.reduce(0, +) / Double(b.count)
        var num = 0.0, da = 0.0, db = 0.0
        for (x, y) in zip(a, b) {
            num += (x - ma) * (y - mb); da += (x - ma) * (x - ma); db += (y - mb) * (y - mb)
        }
        guard da > 0, db > 0 else { return 0 }
        return num / (da * db).squareRoot()
    }

    private func variance(_ v: [Double]) -> Double {
        let m = v.reduce(0, +) / Double(v.count)
        return v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)
    }

    /// Is `CameraController.sourceOrientation(for:)` RIGHT, on this hardware?
    ///
    /// 🔴 The orientation a camera's buffers need is the one thing in P3 that
    /// cannot be established by reading: a wrong value does not crash, log, or
    /// fail a build. Vision simply stops finding faces, so the coach never
    /// greens and the eyes crop falls back to the guide box on every shot — a
    /// feature that looks built and is not.
    ///
    /// So it is MEASURED. The still is ground truth (`UIImage(data:)` applies
    /// the photo's own EXIF, which AVFoundation writes correctly for both
    /// cameras); the live buffer is oriented by each of the eight candidates in
    /// turn, and the one that best matches wins. No face required — any scene
    /// with structure in it will do.
    ///
    /// It has already earned its keep: `.leftMirrored` is the conventional
    /// answer for a front camera, this code shipped it, and this measurement
    /// rejected it — 0.899 for `.right` against 0.148 for `.leftMirrored`.
    private func measure(_ position: AVCaptureDevice.Position) async throws {
        try await releaseCamera()

        let camera = CameraController()
        let grabber = OneFrameGrabber()
        await camera.start(frameDelegate: grabber, position: position)
        defer { camera.stop() }
        try #require(camera.status == .ready)
        // Let AE/AWB settle so the live frame and the still are of the same
        // scene at roughly the same exposure.
        try await Task.sleep(for: .milliseconds(900))

        let stillData = try await camera.capturePhoto()
        let live = try #require(grabber.frame, "no live frame arrived")
        let stillImage = try #require(UIImage(data: stillData))
        let context = CIContext()
        // Ground truth: the still, decoded through its own EXIF.
        let uprightStill = try #require(ConsultPhotoPreparation.uprightCGImage(stillImage))
        let truth = try #require(signature(CIImage(cgImage: uprightStill), context: context))

        // A blank wall correlates with everything. Refuse to conclude from one.
        try #require(variance(truth) > 0.0005,
                     "scene is too flat to orient from — point the phone at something")

        var scores: [(CGImagePropertyOrientation, Double)] = []
        for candidate in Self.candidates {
            guard let sig = signature(live.oriented(candidate), context: context) else { continue }
            scores.append((candidate, correlation(truth, sig)))
        }
        let ranked = scores.sorted { $0.1 > $1.1 }
        let winner = try #require(ranked.first)
        let expected = CameraController.sourceOrientation(for: position)

        let report = ranked.map { "\($0.0.rawValue):\(String(format: "%.3f", $0.1))" }
            .joined(separator: " ")
        #expect(
            winner.0 == expected,
            """
            \(position == .front ? "FRONT" : "REAR") camera orientation is wrong.
            Measured best match: \(winner.0.rawValue). Code says: \(expected.rawValue).
            Scores (orientation:correlation, best first) — \(report)
            """
        )
        // The winner has to actually WIN. A near-tie means the scene had no
        // usable structure and the ranking is noise, not a result.
        if ranked.count > 1 {
            #expect(winner.1 - ranked[1].1 > 0.05,
                    "no clear winner (\(report)) — the scene was too ambiguous to conclude from")
        }
    }

    @Test(.enabled(if: cameraUsable))
    func theRearCameraOrientationMatchesItsOwnStill() async throws {
        try await measure(.back)
    }

    @Test(.enabled(if: cameraUsable))
    func theFrontCameraOrientationMatchesItsOwnStill() async throws {
        try await measure(.front)
    }
}

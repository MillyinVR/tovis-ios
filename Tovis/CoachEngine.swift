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
    private let minInterval: CFTimeInterval = 1.0 / 6.0   // ~6 analyses/sec
    private var lastSampleAt: CFTimeInterval = 0

    /// Set once before the camera starts; called on the frame queue.
    nonisolated(unsafe) var sink: (@Sendable (CoachResult) -> Void)?

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
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        let ctx = FrameContext(
            avgLuma: averageLuma(ciImage),
            faceBounds: detectFace(pixelBuffer),
            faceLuma: nil   // backlit (face-region luma) lands with the lighting upgrade
        )

        let signals = coaches.map { ($0.category, $0.evaluate(ctx)) }
        let readiness = signals.isEmpty ? 0 : signals.map { $0.1.score }.reduce(0, +) / Double(signals.count)
        // The single most important fix = the lowest-scoring coach that has a tip.
        let worst = signals.filter { $0.1.message != nil }.min { $0.1.score < $1.1.score }
        let nudge = worst.flatMap { entry in entry.1.message.map { CoachNudge(category: entry.0, message: $0) } }

        sink?(CoachResult(readiness: readiness, nudge: nudge))
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
}

// MARK: - Engine (MainActor)

@Observable
@MainActor
final class CoachEngine {
    private(set) var readiness: Double = 0
    private(set) var nudge: CoachNudge?

    let analyzer: CoachAnalyzer
    private let settings: CoachSettings
    private let synthesizer = AVSpeechSynthesizer()
    private var wasReady = false

    /// Readiness at/above this reads as "good to shoot" (green ring).
    static let readyThreshold = 0.8

    var isReady: Bool { readiness >= Self.readyThreshold }

    init(settings: CoachSettings) {
        self.settings = settings
        self.analyzer = CoachAnalyzer(coaches: [LightingCoach(), CompositionCoach()])
        analyzer.sink = { [weak self] result in
            Task { @MainActor in self?.apply(result) }
        }
    }

    private func apply(_ result: CoachResult) {
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

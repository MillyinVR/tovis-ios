import CoreImage
import Testing
import UIKit
import TovisKit
@testable import Tovis

// PhotoQC is the post-capture safety net — it verifies the ACTUAL captured JPEG
// (sharpness / exposure / blinks) so a weak frame never reaches the portfolio.
// Blink/face verdicts need real face fixtures, so these cover the synthesizable
// surface: the non-blocking unreadable path, the flat-frame "soft" verdict, the
// passed flag, and the C6 focal-point bridge.
@Suite struct PhotoQCTests {
    private func solidJPEG(_ color: UIColor) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120))
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }

    @Test func unreadableBytesPassNonBlocking() async {
        // Garbage bytes must NOT block the flow — the upload will surface a real
        // problem; QC failing shut here would strand a good take.
        let report = await PhotoQC.evaluate(Data([0x00, 0x01, 0x02, 0x03]))
        #expect(report.passed)
        #expect(report.retakeReason == nil)
        #expect(report.sharpness == 1)
        #expect(report.luma == 0.5)
        #expect(report.focalPoint == nil)
    }

    @Test func flatFrameFailsAsSoft() async {
        // A solid frame has no edge energy → sharpness ~0 → the "soft" verdict
        // (checked before exposure), even with a normal mid-gray luma.
        let report = await PhotoQC.evaluate(solidJPEG(.gray), checkBlink: false)
        #expect(report.retakeReason == "It came out soft")
        #expect(!report.passed)
    }

    @Test func reportPassedReflectsRetakeReason() {
        let ok = PhotoQCReport(retakeReason: nil, sharpness: 0.5, luma: 0.5,
                               eyesClosed: false, focalPoint: nil)
        #expect(ok.passed)

        let bad = PhotoQCReport(retakeReason: "It came out too dark", sharpness: 0.5,
                                luma: 0.05, eyesClosed: false, focalPoint: nil)
        #expect(!bad.passed)
    }

    @Test func focalPointBridgeValidatesFaceCenter() {
        // No face → nil focal → the feed cover-crop stays centered.
        #expect(MediaFocalPoint(faceCenter: nil) == nil)

        let centered = MediaFocalPoint(faceCenter: CGPoint(x: 0.4, y: 0.6))
        #expect(centered?.x == 0.4)
        #expect(centered?.y == 0.6)

        // An out-of-range center can't reach the wire (designated init validates).
        #expect(MediaFocalPoint(faceCenter: CGPoint(x: 1.5, y: 0.5)) == nil)
    }
}

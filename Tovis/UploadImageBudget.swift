// How big a photo is allowed to be when it leaves the phone.
//
// This exists because the camera's shots were never budgeted at all. A capture
// went up at full sensor resolution — `AVCapturePhotoSettings.maxPhotoDimensions`
// is set to the sensor's maximum and quality prioritization to `.quality`, which
// on a modern iPhone is a 3–10 MB JPEG — and a library import was explicitly
// matched to it (a 4032px long edge, capped only by the signing route's 30 MB
// refusal). That is fine for one photo on good wifi and catastrophic for a real
// shoot: a before/after session fires a dozen uploads within a minute, and on a
// salon connection measured at roughly 100 KB/s none of them finished before the
// pro closed the camera. Every one was lost.
//
// So the bytes are bounded here, once, and both doors — a live capture and a
// library import — go through it. 2560px on the long edge is still comfortably
// more than a phone gallery, the web feed, or a printed 8x10 can show, and it is
// roughly a third of what was being sent.
//
// ⚠️ Orientation is baked into the PIXELS, not left in EXIF: `UprightImageDecode`
// (via `ImageDownsample`) applies the transform while decoding. The capture path
// already produced upright pixels, but a library photo may not have, and the web
// gallery reads pixels — so normalizing here is what makes the two doors
// indistinguishable downstream.
import CoreGraphics
import Foundation
import UIKit

enum UploadImageBudget {
    /// Long-edge budget, in pixels, for anything uploaded as session or practice
    /// media. Chosen with Tori (2026-08-20) as the balance between "still a
    /// portfolio-grade image" and "actually arrives on salon wifi".
    nonisolated static let maxPixel: CGFloat = 2560

    /// Soft byte target. The quality ladder steps down until the encode fits, so
    /// a busy, high-detail frame costs quality rather than transfer time.
    nonisolated static let targetBytes = 2 * 1024 * 1024

    /// Hard ceiling. The signing route refuses anything over 30 MB
    /// (`UPLOAD_MAX_BYTES`) before a byte transfers, so an encode that somehow
    /// stays huge must be shrunk here rather than fail at presign.
    nonisolated static let maxBytes = 24 * 1024 * 1024

    /// Decode → downscale → re-encode as a baseline JPEG inside the budget.
    /// Nil only when the bytes don't decode as an image at all.
    ///
    /// Deliberately unconditional, including for bytes that are already JPEG:
    /// passing those through would save a re-encode but leave the dimensions,
    /// orientation and byte count unbounded — which is exactly the bug.
    nonisolated static func prepareSync(_ data: Data) -> Data? {
        guard let image = ImageDownsample.thumbnailSync(from: data, maxPixel: maxPixel) else {
            return nil
        }
        // Six steps from 0.85 reaches 0.35. In practice a 2560px frame clears
        // the target on the first or second step; the lower rungs only exist so
        // a pathological frame degrades instead of failing.
        for quality in stride(from: 0.85, through: 0.35, by: -0.1) {
            guard let encoded = image.jpegData(compressionQuality: quality) else { return nil }
            if encoded.count <= targetBytes { return encoded }
        }
        // Still over target at the floor: shrink the pixels rather than degrade
        // further, and only give up if even that won't fit the hard ceiling.
        guard let smaller = ImageDownsample.thumbnailSync(from: data, maxPixel: maxPixel / 2),
              let encoded = smaller.jpegData(compressionQuality: 0.8) else { return nil }
        return encoded.count <= maxBytes ? encoded : nil
    }

    /// `prepareSync` off the caller's actor — the camera view is MainActor and
    /// must not block on a decode + re-encode between shutter presses.
    static func prepare(_ data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) { prepareSync(data) }.value
    }
}

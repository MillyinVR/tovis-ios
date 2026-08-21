// "Choose from library instead" — the second door out of a dead-end camera.
//
// When the camera can't run (permission off, or AVCaptureSession refused to
// start) the session used to simply stop: there was no way to put a BEFORE or
// AFTER photo on a booking without a working preview. A pro standing in front
// of a finished client is not going to reschedule over a permissions dialog, so
// the dead-end states get a route that keeps the session moving — pick photos
// the pro already has, and push them through the SAME presign→PUT→confirm
// pipeline a captured shot uses.
//
// Two things are genuinely different about a library photo, and both are
// handled here rather than pretended away:
//
//   • It skipped capture-time QC. We do NOT re-apply the retake gate — the pro
//     deliberately chose this frame, and refusing it would be the app arguing
//     with a professional. We only READ it, for the focal point.
//   • Its bytes are whatever the picker hands over: HEIC, PNG, a 60-megapixel
//     panorama, EXIF orientation in the metadata rather than the pixels. The
//     upload declares `image/jpeg`, so it must actually BE a JPEG — a mismatch
//     is exactly the "HTTP 415 · unsupported media" refusal this whole chain
//     started with. Everything is transcoded, orientation baked in.
import CoreGraphics
import Foundation
import ImageIO
import TovisKit
import UIKit
import UniformTypeIdentifiers

enum CameraLibraryImport {
    /// Long-edge budget for an imported photo — the SHARED upload budget, so an
    /// import and a live capture are bounded identically (`UploadImageBudget`).
    ///
    /// This used to be 4032px, deliberately matched to the full-frame capture
    /// path "so a library import isn't visibly softer". That reasoning held only
    /// while capture itself was unbudgeted; both are now bounded together, and
    /// matching them still costs nothing visible in a gallery.
    nonisolated static var maxPixel: CGFloat { UploadImageBudget.maxPixel }

    /// Hard ceiling for the encoded bytes. The signing route rejects anything
    /// over 30MB (`UPLOAD_MAX_BYTES`) before a byte is transferred, so an
    /// oversized import must be re-encoded rather than fail at presign.
    nonisolated static var maxBytes: Int { UploadImageBudget.maxBytes }

    /// A library photo, made ready for the existing upload pipeline.
    struct Imported: Sendable {
        /// Baseline JPEG bytes, orientation applied, under `maxBytes`.
        let jpeg: Data
        /// Subject focal (camera C6), read the same way a captured shot's is, so
        /// the feed's cover-crop centres on the client either way. Nil when the
        /// photo has no face in it — a back-of-the-cut shot, or nail work.
        let focal: MediaFocalPoint?
    }

    /// Decode → downscale → re-encode as JPEG → read the focal.
    /// Nil when the bytes don't decode as an image at all.
    static func prepare(_ data: Data) async -> Imported? {
        guard let jpeg = await Task.detached(priority: .userInitiated, operation: {
            transcodeToJPEG(data)
        }).value else { return nil }
        // Read-only: the report's retake verdict is deliberately ignored (see
        // the file header). Blink detection is off — an imported photo was
        // chosen on purpose, closed eyes included.
        let report = await PhotoQC.evaluate(jpeg, checkBlink: false)
        return Imported(jpeg: jpeg, focal: MediaFocalPoint(faceCenter: report.focalPoint))
    }

    /// Re-encode arbitrary picker bytes as a baseline JPEG inside the upload
    /// budget, with EXIF orientation baked into the pixels (the capture path's
    /// bytes already have it, and the web gallery reads the pixels).
    ///
    /// The encode itself is `UploadImageBudget`'s — there is one place that
    /// decides how big a photo may be when it leaves the phone, and both the
    /// import door and the shutter go through it.
    nonisolated static func transcodeToJPEG(_ data: Data) -> Data? {
        UploadImageBudget.prepareSync(data)
    }
}

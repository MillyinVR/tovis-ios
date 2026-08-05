// Decode-bounded, orientation-correct image decoding — the one implementation.
//
// A full-sensor capture decodes to a bitmap in the hundreds of MB, so anything
// that HOLDS a decoded shot (the captured strip, the best-shots tray, the onion
// ghost, the export renderer) must hold a bitmap sized for its job rather than
// for the sensor. Retaining full decodes is what jetsam-killed the camera
// mid-session. ImageIO thumbnailing decodes straight to the target size; the
// full-resolution bitmap never materializes.
//
// `kCGImageSourceCreateThumbnailWithTransform` is the other half and matters just
// as much here: a `CGImage` has no orientation of its own, so without it a photo
// shot in portrait comes back on its side and every crop is computed against the
// wrong axis. The export renderer's geometry assumes upright pixels.
//
// This bounds pixels we HOLD, never pixels we SEND — a save-to-Photos writes the
// original file byte for byte and never comes through here.
import CoreGraphics
import Foundation
import ImageIO

public enum UprightImageDecode {
    /// Long-edge budget for a full-screen preview (≈ 3× display scale).
    public static let screenMaxPixel: CGFloat = 2048

    /// Decode `data` to at most `maxPixel` on its long edge, with EXIF
    /// orientation baked into the pixels. Nil when the bytes don't decode.
    public nonisolated static func cgImage(from data: Data, maxPixel: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as [CFString: Any] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

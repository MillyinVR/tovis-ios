// Decode-bounded image loading. A full-sensor capture decodes to a bitmap in
// the hundreds of MB, so every place that only DISPLAYS a shot (captured
// strip, best-shots tray, onion ghost) must hold a bitmap sized for its frame,
// not the sensor — retaining full decodes is what jetsam-killed the camera
// mid-session. ImageIO thumbnailing decodes straight to the target size; the
// full-resolution bitmap never materializes. Upload payloads stay full-res —
// this bounds pixels we HOLD, never pixels we SEND.
import ImageIO
import SwiftUI
import UIKit

enum ImageDownsample {
    /// Long-edge budget for a full-screen ghost/preview (≈ 3x display scale).
    static let screenMaxPixel: CGFloat = 2048

    /// Decode `data` to at most `maxPixel` on its long edge, applying EXIF
    /// orientation. Nil when the bytes don't decode.
    nonisolated static func thumbnailSync(from data: Data, maxPixel: CGFloat) -> UIImage? {
        autoreleasepool {
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
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }
    }

    /// `thumbnailSync` off the caller's actor — the camera view is MainActor
    /// and shouldn't block on JPEG decode.
    static func thumbnail(from data: Data, maxPixel: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            thumbnailSync(from: data, maxPixel: maxPixel)
        }.value
    }
}

/// A remote image decoded at display size, filling its frame — the AsyncImage
/// replacement for ORIGINAL uploads (the media pipeline serves full capture
/// resolution, which AsyncImage would decode and pin in full).
struct DownsampledRemoteImage<Placeholder: View>: View {
    let url: URL
    var maxPixel: CGFloat = ImageDownsample.screenMaxPixel
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            image = nil
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            image = await ImageDownsample.thumbnail(from: data, maxPixel: maxPixel)
        }
    }
}

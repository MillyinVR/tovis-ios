// Decode-bounded image loading, as UIImage.
//
// The decode itself lives in `TovisKit.UprightImageDecode` — the export renderer
// needs the same bounded, orientation-baked CGImage and CI only compiles TovisKit,
// so there is one implementation and this is the UIKit wrapper over it. See that
// file for why both the size bound and the transform flag matter.
import SwiftUI
import TovisKit
import UIKit

enum ImageDownsample {
    /// Long-edge budget for a full-screen ghost/preview (≈ 3x display scale).
    static let screenMaxPixel: CGFloat = UprightImageDecode.screenMaxPixel

    /// Decode `data` to at most `maxPixel` on its long edge, applying EXIF
    /// orientation. Nil when the bytes don't decode.
    nonisolated static func thumbnailSync(from data: Data, maxPixel: CGFloat) -> UIImage? {
        autoreleasepool {
            UprightImageDecode.cgImage(from: data, maxPixel: maxPixel).map(UIImage.init(cgImage:))
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

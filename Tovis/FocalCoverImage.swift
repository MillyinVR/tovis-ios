// A remote image that fills + cover-crops its frame, centering the crop window on
// a subject focal point (camera C6 / C6c) when one is supplied. It is the SwiftUI
// counterpart of the web feed's `object-fit: cover` + `object-position` (see
// `MediaFocalPoint.coverCrop`): a 3:4 capture in the full-screen 9:16 feed loses
// ~40% of its width blind-center, so we place the visible window on the face.
//
// Two paths, by design:
//  • No focal (the common case, and every row until web C6a #613 deploys) →
//    a plain center `.scaledToFill()` AsyncImage. Byte-identical to pre-C6c, and
//    it keeps AsyncImage's in-memory decoded cache for the nil-focal majority.
//  • A focal present → the decode-bounded UIImage path (like DownsampledRemoteImage)
//    so we know the intrinsic size and can offset the fill exactly. Only the
//    images that actually carry a focal pay for the extra decode.
//
// The caller supplies the bounding frame + clip (every call site is a fill
// context); this view fills whatever space it's given.
import SwiftUI
import TovisKit
import UIKit

struct FocalCoverImage<Placeholder: View, Failure: View>: View {
    let url: URL
    /// The subject focal point to center the cover-crop on, or nil for a plain
    /// centered fill (identical to `.scaledToFill()`).
    let focal: MediaFocalPoint?
    /// Long-edge decode budget for the focal path (the nil path lets AsyncImage
    /// decide). Grids can pass a smaller value than a full-screen slide.
    var maxPixel: CGFloat = ImageDownsample.screenMaxPixel
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var failure: () -> Failure

    @State private var focalImage: UIImage?
    @State private var focalLoadFailed = false

    var body: some View {
        if let focal {
            GeometryReader { geo in
                Group {
                    if let focalImage {
                        focalFill(focalImage, focal: focal, container: geo.size)
                    } else if focalLoadFailed {
                        failure()
                    } else {
                        placeholder()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .task(id: url) { await loadFocalImage() }
        } else {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image): image.resizable().scaledToFill()
                case .failure: failure()
                default: placeholder()
                }
            }
        }
    }

    /// Draw the image at cover scale, offset so `focal` lands where CSS
    /// `object-position` would put it, then clip to the container.
    private func focalFill(_ image: UIImage, focal: MediaFocalPoint, container: CGSize) -> some View {
        let layout = focal.coverCrop(imageSize: image.size, containerSize: container)
        return Image(uiImage: image)
            .resizable()
            .frame(width: layout.size.width, height: layout.size.height)
            .offset(x: layout.offset.width, y: layout.offset.height)
            .frame(width: container.width, height: container.height, alignment: .topLeading)
            .clipped()
    }

    private func loadFocalImage() async {
        focalImage = nil
        focalLoadFailed = false
        guard let (data, _) = try? await URLSession.shared.data(from: url) else {
            focalLoadFailed = true
            return
        }
        if let image = await ImageDownsample.thumbnail(from: data, maxPixel: maxPixel) {
            focalImage = image
        } else {
            focalLoadFailed = true
        }
    }
}

extension FocalCoverImage where Failure == Placeholder {
    /// Convenience: reuse the placeholder as the failure view (grid tiles whose
    /// placeholder is already a neutral fill don't need a distinct error state).
    init(
        url: URL,
        focal: MediaFocalPoint?,
        maxPixel: CGFloat = ImageDownsample.screenMaxPixel,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.init(url: url, focal: focal, maxPixel: maxPixel, placeholder: placeholder, failure: placeholder)
    }
}

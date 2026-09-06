// Mapping a rect in the UPRIGHT capture frame onto the preview layer.
//
// Extracted from ProCapturePhotosView (P3): the consult camera needs the same
// mapping to draw its guide box, and a second copy of an axis-swapping
// coordinate conversion is the kind of duplicate that drifts silently — one
// caller gets a fix, the other keeps drawing a box that lies about what it
// contains.

import AVFoundation
import CoreGraphics

enum CameraPreviewGeometry {
    /// A rect given in UPRIGHT, top-left-normalized capture-frame coordinates,
    /// converted to preview-layer points.
    ///
    /// The layer's own `layerRectConverted(fromMetadataOutputRect:)` is what
    /// makes the box honest under `.resizeAspectFill`, which crops: a naive
    /// multiply by the view size would draw a box promising content the preview
    /// is not actually showing. Metadata-output space is the SENSOR's, so x and
    /// y swap on the way in.
    ///
    /// ⚠️ Exact only for rects centered in both axes — the upright→sensor axis
    /// swap hides the flip when they are. An off-centre rect (P3's eyes band is
    /// one) should be derived by insetting an already-mapped centred box rather
    /// than mapped directly; `coverSafeBand` in ProCapturePhotosView does this
    /// and says so.
    ///
    /// Falls back to a plain proportional rect when there is no layer yet (the
    /// first frames, and the SwiftUI previews).
    static func previewRect(
        uprightNormalized rect: CGRect,
        in size: CGSize,
        layer: AVCaptureVideoPreviewLayer?
    ) -> CGRect {
        if let layer, layer.bounds.width > 0 {
            let metadata = CGRect(x: rect.minY, y: rect.minX,
                                  width: rect.height, height: rect.width)
            return layer.layerRectConverted(fromMetadataOutputRect: metadata)
        }
        return CGRect(x: size.width * rect.minX, y: size.height * rect.minY,
                      width: size.width * rect.width, height: size.height * rect.height)
    }
}

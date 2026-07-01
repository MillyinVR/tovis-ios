// Shared CoreImage measurement math for the live coach (CoachAnalyzer), the
// post-capture quality check (PhotoQC), and the before/after light matcher —
// ONE implementation of the aggregate signals so preview scoring and full-res
// verification can't drift apart. All coordinates normalized top-left unless
// noted; callers supply the CIContext (the analyzer keeps its own on the frame
// queue; everything else shares `FrameMath.context`).
import CoreImage

enum FrameMath {
    /// Shared low-priority context for off-frame-queue callers (QC, reference
    /// light stamps). CIContext is thread-safe.
    nonisolated(unsafe) static let context = CIContext(options: [.priorityRequestLow: true])

    /// Average color of an image (CIAreaAverage → one pixel), each channel 0…1.
    /// Nil when the extent is degenerate.
    static func averageRGB(_ image: CIImage, context: CIContext) -> (r: Double, g: Double, b: Double)? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: image,
                  kCIInputExtentKey: CIVector(cgRect: extent),
              ]),
              let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    static func averageLuma(_ image: CIImage, context: CIContext) -> Double {
        guard let c = averageRGB(image, context: context) else { return 0.5 }
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
    }

    /// Signed warmth of a color: + = warm/yellow, − = cool/blue.
    static func warmth(_ c: (r: Double, g: Double, b: Double)) -> Double {
        (c.r - c.b) / (c.r + c.b + 1e-3)
    }

    /// Edge magnitude image (CIEdges) for energy measurement.
    static func edges(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIEdges", parameters: ["inputIntensity": 1.0])
    }

    /// Scale an image down so its largest side ≈ `maxDim` (cheap aggregate math).
    static func downscaled(_ image: CIImage, maxDim: CGFloat) -> CIImage {
        let maxSide = max(image.extent.width, image.extent.height)
        guard maxSide > maxDim else { return image }
        let s = maxDim / maxSide
        return image.transformed(by: CGAffineTransform(scaleX: s, y: s))
    }

    /// Crop an upright image to a normalized top-left rect, mapping to CIImage's
    /// bottom-left pixel space. Returns the full image if the rect is degenerate.
    static func crop(_ image: CIImage, normalizedTopLeft rect: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let px = CGRect(
            x: e.minX + rect.minX * e.width,
            y: e.minY + (1 - rect.maxY) * e.height,
            width: rect.width * e.width,
            height: rect.height * e.height
        ).intersection(e)
        guard !px.isNull, px.width >= 1, px.height >= 1 else { return image }
        return image.cropped(to: px)
    }

    /// Focus quality 0…1 from edge energy — measured on the subject region when a
    /// face is present (focus on the face, not a busy background), else whole frame.
    /// Normalized against the reference "sharp" edge-mean (CoachTuning).
    static func sharpness(_ image: CIImage, subject face: CGRect?, context: CIContext) -> Double {
        let target = face.map { crop(image, normalizedTopLeft: expandToHead($0)) } ?? image
        let energy = averageLuma(edges(target), context: context)
        return min(1.0, energy / CoachTuning.sharpnessReference)
    }

    /// Expand a face rect to roughly head-and-shoulders so subject-focused math
    /// (sharpness) doesn't sample only skin. Clamped to the unit square.
    static func expandToHead(_ face: CGRect) -> CGRect {
        let cx = face.midX
        let w = min(1.0, face.width * 2.0)
        let h = min(1.0, face.height * 2.2)
        let x = max(0.0, min(1.0 - w, cx - w / 2))
        let y = max(0.0, min(1.0 - h, face.minY - face.height * 0.3))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

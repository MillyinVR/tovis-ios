// Shared CoreImage measurement math for the live coach (CoachAnalyzer), the
// post-capture quality check (PhotoQC), and the before/after light matcher —
// ONE implementation of the aggregate signals so preview scoring and full-res
// verification can't drift apart. All coordinates normalized top-left unless
// noted; callers supply the CIContext (the analyzer keeps its own on the frame
// queue; everything else shares `FrameMath.context`).
import CoreImage

/// `nonisolated` as a whole: every member is a pure function of its arguments
/// with no state to protect, and every caller that matters (the frame queue, the
/// QC/reference detached tasks) runs off the main actor. Under the project's
/// default main-actor isolation the whole namespace would otherwise belong to
/// the main actor, which is exactly backwards for the one file guaranteed never
/// to touch main-actor state.
nonisolated enum FrameMath {
    /// Shared low-priority context for off-frame-queue callers (QC, reference
    /// light stamps). CIContext is thread-safe.
    static let context = CIContext(options: [.priorityRequestLow: true])

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
        return luma(c)
    }

    /// Rec.601 luma of a colour — the one place the coefficients live.
    static func luma(_ c: (r: Double, g: Double, b: Double)) -> Double {
        0.299 * c.r + 0.587 * c.g + 0.114 * c.b
    }

    /// Average colour of the BACKGROUND ONLY — the subject excluded — inside an
    /// optional normalized top-left sub-rect. `weight` is the background-weight
    /// image from `segmentation` (1 = background, 0 = subject), already in
    /// `image`'s space.
    ///
    /// Why the subject has to be excluded: every colour-of-LIGHT signal the
    /// coach reports (warmth, green tint, the warm↔cool spread that reads as
    /// mixed light) is measured on content today, so a red top on one side and
    /// a cool wall on the other reads as mixed light under perfectly uniform
    /// illumination — and the confound scales with how much of the frame is
    /// skin, i.e. it is worst on the close-ups that matter most.
    ///
    /// How the division is legitimate: `image × weight` and `weight` are both
    /// area-averaged and rendered through the SAME transfer curve, so their
    /// ratio is that curve applied to the true background-only mean — the same
    /// domain plain `averageRGB` reports. The existing thresholds keep meaning
    /// what they meant; only the pixels they are measured over change.
    ///
    /// Nil when there is too little background in the region to measure: below
    /// that the division amplifies quantization into a confident wrong answer,
    /// and no reading is better than an invented one.
    static func backgroundAverageRGB(
        _ image: CIImage,
        background weight: CIImage,
        in rect: CGRect? = nil,
        minFraction: Double = CoachTuning.minBackgroundFraction,
        context: CIContext
    ) -> (rgb: (r: Double, g: Double, b: Double), fraction: Double)? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let masked = image
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weight])
            .cropped(to: extent)
        let bg = weight.cropped(to: extent)

        func region(_ i: CIImage) -> CIImage {
            guard let rect else { return i }
            return crop(i, normalizedTopLeft: rect)
        }
        guard let numerator = averageRGB(region(masked), context: context),
              let denominator = averageRGB(region(bg), context: context) else { return nil }
        let fraction = luma(denominator)
        guard fraction >= minFraction else { return nil }
        return ((numerator.r / fraction, numerator.g / fraction, numerator.b / fraction), fraction)
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

    /// Scale a person-segmentation mask (white = person) onto `working` and
    /// derive the background-weight image + fractions — shared by the live
    /// coach (clutter/fill) and the reference-look analyzer (fill).
    static func segmentation(
        maskBuffer: CVPixelBuffer, working: CIImage, context: CIContext
    ) -> (background: CIImage, backgroundFraction: Double, subjectFill: Double)? {
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        let me = mask.extent
        guard me.width > 0, me.height > 0 else { return nil }
        mask = mask.transformed(by: CGAffineTransform(
            scaleX: working.extent.width / me.width,
            y: working.extent.height / me.height
        )).cropped(to: working.extent)
        let background = mask.applyingFilter("CIColorInvert")  // 1 - mask → background weight
        let backgroundFraction = averageLuma(background, context: context)
        let subjectFill = min(1.0, max(0.0, 1 - backgroundFraction))
        return (background, backgroundFraction, subjectFill)
    }

    /// Everything one frame's person-segmentation mask yields. Assembled here,
    /// not in the analyzer, so the live coach and the offline bench read the
    /// same numbers from the same code instead of the bench keeping a mirror
    /// copy that can quietly drift.
    struct SegmentedFrame {
        /// Busy-ness of the area behind the subject, 0…1. Nil when the subject
        /// fills the frame (nothing left worth judging).
        let clutter: Double?
        /// The area-normalized background edge energy `clutter` is derived
        /// from, BEFORE the divide by `clutterReference` and the 0…1 clamp.
        /// Nil exactly when `clutter` is.
        ///
        /// Carried because it is the quantity a tuning pass actually sets the
        /// reference from, and `clutter` cannot be inverted back into it once
        /// it saturates: every frame busier than the reference reports 1.0, so
        /// reconstructing `clutter × clutterReference` silently reads back as
        /// "exactly the reference" and flattens the top of the distribution.
        /// The offline bench quoted a max that was really that clamp.
        let rawBackgroundEdge: Double?
        /// Fraction of the whole frame the subject fills.
        let subjectFill: Double
        /// Fraction of `crop` the subject fills — what the pro is actually
        /// composing when the publish-crop guide is on. Nil without a crop.
        let cropSubjectFill: Double?
        /// Average luma BEHIND the subject. The backlit test compares the face
        /// against this rather than against a frame average that includes it.
        let backgroundLuma: Double?
        /// The background-weight image (1 = background, 0 = subject), in
        /// `working`'s space. Valid only while the mask buffer lives — measure
        /// through it now, don't cache it across frames.
        let background: CIImage
    }

    static func segmentSignals(
        maskBuffer: CVPixelBuffer, working: CIImage, cropGuide: CGRect?, context: CIContext
    ) -> SegmentedFrame? {
        guard let seg = segmentation(maskBuffer: maskBuffer, working: working, context: context)
        else { return nil }

        let cropFill = cropGuide.map { rect in
            min(1.0, max(0.0, 1 - averageLuma(crop(seg.background, normalizedTopLeft: rect),
                                              context: context)))
        }

        // Only judge clutter (and only trust a background reading) when there's
        // enough background to judge — a subject filling the frame leaves
        // scraps, and a mean over scraps is noise wearing a number's clothes.
        guard seg.backgroundFraction > CoachTuning.minBackgroundFraction else {
            return SegmentedFrame(clutter: nil, rawBackgroundEdge: nil,
                                  subjectFill: seg.subjectFill,
                                  cropSubjectFill: cropFill, backgroundLuma: nil,
                                  background: seg.background)
        }
        // Edge energy that falls in the background = edges × background weight.
        let bgEdges = edges(working).applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: seg.background,
        ])
        let bgEdgeMean = averageLuma(bgEdges.cropped(to: working.extent), context: context)
        // Normalize by background area, then against the "fully cluttered" reference.
        let rawBackgroundEdge = bgEdgeMean / seg.backgroundFraction
        let clutter = min(1.0, max(0.0, rawBackgroundEdge / CoachTuning.clutterReference))
        let backgroundLuma = backgroundAverageRGB(working, background: seg.background,
                                                  context: context).map { luma($0.rgb) }
        return SegmentedFrame(clutter: clutter, rawBackgroundEdge: rawBackgroundEdge,
                              subjectFill: seg.subjectFill,
                              cropSubjectFill: cropFill, backgroundLuma: backgroundLuma,
                              background: seg.background)
    }

    /// Signed green excess of a colour (+green / −magenta). Strong + = fluorescent.
    static func greenTint(_ c: (r: Double, g: Double, b: Double)) -> Double {
        (2 * c.g - c.r - c.b) / (2 * c.g + c.r + c.b + 1e-3)
    }

    /// The colour-of-LIGHT read for one frame: the warm↔cool spread across the
    /// left / middle / right thirds (window on one side, bulb on the other) plus
    /// the global green and warmth cast.
    ///
    /// Measured on the segmented BACKGROUND when a mask is available, because
    /// every one of these is otherwise measured on content: a red top on one
    /// side and a cool wall on the other reads as mixed light under perfectly
    /// uniform illumination, and the confound scales with how much of the frame
    /// is skin — so it is worst on exactly the tight beauty close-ups that
    /// matter most.
    ///
    /// With no mask the whole frame stands in. That is not a compromise on a
    /// flat-lay or a detail shot: there, the frame IS the background.
    static func colorSignal(_ working: CIImage, background: CIImage?, context: CIContext)
        -> ColorSignal? {
        let e = working.extent
        guard e.width > 0, e.height > 0 else { return nil }

        func thirdRect(_ i: Int) -> CGRect {
            CGRect(x: Double(i) / 3.0, y: 0, width: 1.0 / 3.0, height: 1)
        }

        if let background,
           let global = backgroundAverageRGB(working, background: background, context: context) {
            let warms: [Double] = (0..<3).compactMap { i in
                backgroundAverageRGB(working, background: background, in: thirdRect(i),
                                     context: context).map { warmth($0.rgb) }
            }
            // Two thirds with measurable background is enough for a spread; one
            // is not a spread at all, so fall through rather than invent one.
            if warms.count >= 2 {
                return ColorSignal(
                    mixed: max(0, (warms.max() ?? 0) - (warms.min() ?? 0)),
                    greenTint: greenTint(global.rgb),
                    warmth: warmth(global.rgb),
                    backgroundScoped: true)
            }
        }

        guard let global = averageRGB(working, context: context) else { return nil }
        let warms: [Double] = (0..<3).compactMap { i in
            averageRGB(crop(working, normalizedTopLeft: thirdRect(i)), context: context)
                .map(warmth)
        }
        let mixed = warms.count >= 2 ? ((warms.max() ?? 0) - (warms.min() ?? 0)) : 0
        return ColorSignal(mixed: max(0, mixed), greenTint: greenTint(global),
                           warmth: warmth(global), backgroundScoped: false)
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

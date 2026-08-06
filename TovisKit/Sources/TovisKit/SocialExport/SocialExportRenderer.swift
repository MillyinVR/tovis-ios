// The pixels. Crops the source to the plan, lays the halves of a diptych, and
// signs the result.
//
// 🔴 It takes a NON-OPTIONAL `ExportWatermark`, and that is the point. A plain
// save-to-Photos has no watermark to give it (`SocialExportPolicy.watermark`
// returns nil for `.saveOriginal`), so a save physically cannot be routed through
// this file — "plain saves are always clean" is enforced by the type rather than
// by everyone remembering. A save writes the original bytes to the library and
// never comes near a re-encode, which is also how its EXIF survives.
//
// CoreGraphics + CoreText + ImageIO only, no UIKit, so it compiles and is TESTED
// on the macOS CI runner. This is the only place in the repo where a wrong number
// silently defaces a pro's published work, so it had to be somewhere CI runs.
import CoreGraphics
import CoreText
import Foundation
import ImageIO

public enum SocialExportRenderError: Error, Equatable {
    /// One image per placement, in the plan's order. Anything else is a caller bug.
    case imageCountMismatch(expected: Int, got: Int)
    case contextUnavailable
    case cropFailed
    case encodeFailed
}

public enum SocialExportRenderer {
    // MARK: - Look

    /// Behind the diptych hairline (and any sliver rounding leaves). Near-black
    /// rather than white: an export is a photograph, and a dark seam recedes
    /// between two frames where a white one reads as a border someone added.
    private static let seam: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.04, 0.04, 0.04)

    /// Signature size as a fraction of the canvas's SHORT edge, so 4:5 and 9:16
    /// sign at the same physical size instead of the taller box shouting.
    private static let signaturePointFraction: CGFloat = 0.030
    /// The platform mark rides at three-quarters of the signature — present,
    /// clearly secondary, never competing with the name of the person who did the
    /// work.
    private static let markScale: CGFloat = 0.75
    /// A photographer's signature is legible, not loud.
    private static let signatureAlpha: CGFloat = 0.82
    private static let markAlpha: CGFloat = 0.62
    private static let beforeAfterAlpha: CGFloat = 0.70
    /// Gap between the signature and the mark, in signature points.
    private static let markGapFraction: CGFloat = 0.55

    /// JPEG quality. High enough that a re-compress on the way to Instagram
    /// doesn't compound visibly; not 1.0, which buys nothing but megabytes.
    public static let jpegQuality: CGFloat = 0.92

    // MARK: - Render

    /// Render `plan` from `images` (one per placement, in the plan's order) and
    /// return JPEG bytes ready to share or save.
    public static func render(
        plan: SocialExportPlan,
        images: [CGImage],
        watermark: ExportWatermark
    ) throws -> Data {
        guard images.count == plan.placements.count else {
            throw SocialExportRenderError.imageCountMismatch(
                expected: plan.placements.count, got: images.count
            )
        }

        let width = Int(plan.canvasSize.width.rounded())
        let height = Int(plan.canvasSize.height.rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { throw SocialExportRenderError.contextUnavailable }

        let canvas = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        context.setFillColor(red: seam.r, green: seam.g, blue: seam.b, alpha: 1)
        context.fill(canvas)

        context.interpolationQuality = .high

        for (placement, image) in zip(plan.placements, images) {
            guard let cropped = image.cropping(to: pixelCrop(placement.sourceCrop, in: image))
            else { throw SocialExportRenderError.cropFailed }
            context.draw(cropped, in: flipped(placement.destination, in: canvas))
        }

        if plan.placements.count > 1 {
            drawPairLabels(plan: plan, canvas: canvas, in: context)
        }
        draw(watermark, canvas: canvas, format: plan.format, in: context)

        guard let output = context.makeImage() else {
            throw SocialExportRenderError.encodeFailed
        }
        return try jpeg(from: output)
    }

    // MARK: - Geometry helpers

    /// A normalized top-left rect of the source, as pixels of `image`, clamped to
    /// the image and never empty (`CGImage.cropping` returns nil on an out-of-
    /// bounds or zero-sized rect, which would fail an export over a rounding
    /// error on the last row).
    static func pixelCrop(_ normalized: CGRect, in image: CGImage) -> CGRect {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let raw = CGRect(
            x: normalized.minX * w,
            y: normalized.minY * h,
            width: normalized.width * w,
            height: normalized.height * h
        ).integral
        let clamped = raw.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard clamped.width >= 1, clamped.height >= 1 else {
            return CGRect(x: 0, y: 0, width: w, height: h)
        }
        return clamped
    }

    /// Top-left canvas rect → the bottom-left space a `CGContext` draws in.
    static func flipped(_ rect: CGRect, in canvas: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: canvas.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Signature

    private static func draw(
        _ watermark: ExportWatermark,
        canvas: CGRect,
        format: SocialExportFormat,
        in context: CGContext
    ) {
        let pointSize = min(canvas.width, canvas.height) * signaturePointFraction
        // The planner speaks top-left like the rest of the geometry; the context
        // draws bottom-left. Flip once, here, so `box.minY` really is the baseline.
        let box = flipped(
            SocialExportPlanner.signatureBox(in: canvas.size, format: format),
            in: canvas
        )
        drawSignature(watermark, pointSize: pointSize, box: box, in: context)
    }

    /// The signature + platform mark, right-aligned along the bottom of `box`
    /// (already in the context's bottom-left space), shared baselines so the
    /// mark sits ON the signature's line rather than beside it at its own
    /// height. The one place either caller of this file's watermark drawing
    /// touches text — `draw(_:canvas:format:in:)` for a full picture composite
    /// and `watermarkOverlay(_:canvasSize:)` for a standalone overlay both
    /// funnel through here so there is exactly one copy of the visual design.
    private static func drawSignature(
        _ watermark: ExportWatermark,
        pointSize: CGFloat,
        box: CGRect,
        in context: CGContext
    ) {
        guard !watermark.isEmpty else { return }

        var runs: [TextRun] = []
        if let signature = watermark.signature {
            runs.append(TextRun(
                text: signature,
                font: font(.display, size: pointSize),
                alpha: signatureAlpha,
                tracking: 0
            ))
        }
        if watermark.showsPlatformMark {
            runs.append(TextRun(
                text: watermark.platformMark.uppercased(),
                font: font(.mono, size: pointSize * markScale),
                alpha: markAlpha,
                tracking: pointSize * 0.08
            ))
        }
        guard !runs.isEmpty else { return }

        let gap = pointSize * markGapFraction
        let widths = runs.map { $0.width }
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, runs.count - 1))

        var x = box.maxX - total
        let baselineY = box.minY
        for (run, width) in zip(runs, widths) {
            run.draw(at: CGPoint(x: x, y: baselineY), in: context)
            x += width + gap
        }
    }

    /// The signature + platform mark alone, on an otherwise transparent canvas
    /// — for a caller that composites onto something this file has no picture
    /// path for (video frames; see `SocialVideoExportRenderer` in the app
    /// target). Same drawing code as the image path's `draw(_:canvas:format:in:)`
    /// via `drawSignature`, so the mark is pixel-for-pixel the same design; the
    /// only difference is where the safe box sits — a plain inset from the
    /// canvas edge rather than `SocialExportPlanner.signatureBox`'s
    /// format-specific cover-safe band, since a video clip ships at its own
    /// source aspect rather than one of the two known export canvases.
    ///
    /// Nil only on a degenerate `canvasSize` (matches `render`'s own guard).
    /// An empty watermark returns a fully transparent image rather than nil —
    /// still a valid image to composite, it just adds nothing.
    public static func watermarkOverlay(
        _ watermark: ExportWatermark,
        canvasSize: CGSize
    ) -> CGImage? {
        let width = Int(canvasSize.width.rounded())
        let height = Int(canvasSize.height.rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let canvas = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let pointSize = min(canvas.width, canvas.height) * signaturePointFraction
        let inset = min(canvas.width, canvas.height) * SocialExportPlanner.signatureInsetFraction
        // Symmetric inset needs no top-left/bottom-left flip — unlike the
        // planner's format-specific box, `insetBy` reads the same in either space.
        let box = canvas.insetBy(dx: inset, dy: inset)
        drawSignature(watermark, pointSize: pointSize, box: box, in: context)

        return context.makeImage()
    }

    private static func drawPairLabels(
        plan: SocialExportPlan,
        canvas: CGRect,
        in context: CGContext
    ) {
        let pointSize = min(canvas.width, canvas.height) * signaturePointFraction * markScale
        let inset = pointSize * 1.1

        for placement in plan.placements {
            guard placement.role != .single else { continue }
            let run = TextRun(
                text: placement.role == .before ? "BEFORE" : "AFTER",
                font: font(.mono, size: pointSize),
                alpha: beforeAfterAlpha,
                tracking: pointSize * 0.12
            )
            let slot = flipped(placement.destination, in: canvas)
            run.draw(
                at: CGPoint(x: slot.minX + inset, y: slot.maxY - inset - pointSize),
                in: context
            )
        }
    }

    // MARK: - Type

    private enum BrandFace {
        case display  // Space Grotesk — the signature
        case mono     // Space Mono — the mark and the BEFORE/AFTER labels
    }

    /// The brand faces, registered by the app via `UIAppFonts`. CoreText falls
    /// back to the system font when a family is missing, which is what happens on
    /// the CI runner — the geometry under test is identical either way.
    private static func font(_ face: BrandFace, size: CGFloat) -> CTFont {
        let name: CFString = switch face {
        case .display: "Space Grotesk" as CFString
        case .mono: "Space Mono" as CFString
        }
        return CTFontCreateWithName(name, size, nil)
    }

    /// One drawn string. Kept as a value so the signature and the mark are laid
    /// out from measured widths rather than guessed offsets.
    private struct TextRun {
        let text: String
        let font: CTFont
        let alpha: CGFloat
        let tracking: CGFloat

        /// CoreText's own attribute keys, not `NSAttributedString.Key` — those
        /// live in UIKit/AppKit, and this file stays clear of both so CI can
        /// compile and run it.
        private var attributes: CFDictionary {
            let white = CGColor(
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                components: [1, 1, 1, alpha]
            ) ?? CGColor(gray: 1, alpha: alpha)
            return [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: white,
                kCTKernAttributeName: tracking as CFNumber,
            ] as CFDictionary
        }

        var line: CTLine {
            let attributed = CFAttributedStringCreate(nil, text as CFString, attributes)
            return CTLineCreateWithAttributedString(attributed ?? CFAttributedStringCreate(nil, "" as CFString, nil)!)
        }

        var width: CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }

        /// Drawn twice: a soft dark pass offset down, then the light pass. A flat
        /// white signature vanishes on a blonde balayage and a flat dark one
        /// vanishes on dark hair; the pair reads on both without a plate behind it.
        func draw(at origin: CGPoint, in context: CGContext) {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -CTFontGetSize(font) * 0.05),
                blur: CTFontGetSize(font) * 0.35,
                color: CGColor(gray: 0, alpha: 0.45)
            )
            context.textMatrix = .identity
            context.textPosition = origin
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    // MARK: - Encode

    private static func jpeg(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { throw SocialExportRenderError.encodeFailed }

        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ] as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw SocialExportRenderError.encodeFailed
        }
        return data as Data
    }
}

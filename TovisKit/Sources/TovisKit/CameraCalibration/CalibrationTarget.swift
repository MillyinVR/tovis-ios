// A physical calibration reference the camera can scan — bundling the geometry
// (where each swatch sits inside the detected + rectified target, plus the
// neutral region used for white balance), the rectangle-detection aspect band,
// and the known reference colors. This lets the scan pipeline support more than
// the printed Tovis card: notably a standard ColorChecker Classic chart, whose
// factory-known colors make it a TRUSTWORTHY reference with no printing at all —
// exactly what's needed to validate the color pipeline against a real reference.
//
// The `CameraCalibration` math is target-agnostic (it takes a `CardReferenceProfile`
// + a measured-swatch array), and the reading order is shared across targets
// (1–24, gray ramp last, neutral-5 at index 21), so `looksLikeGrayRamp` and the
// 3×3 solve need ZERO per-target knowledge — a target only supplies geometry +
// the profile.
import CoreGraphics
import Foundation

public struct CalibrationTarget: Sendable, Equatable {
    /// Stable id (e.g. persisted alongside a scan, shown in the dev console).
    public let id: String
    /// Human-facing name for the picker / dev console.
    public let displayName: String
    /// Alignment-box aspect (width / height) drawn over the preview.
    public let aspect: Double
    /// VNDetectRectangles aspect band for locating this target in the frame.
    public let detectionAspectMin: Double
    public let detectionAspectMax: Double
    /// Swatch sampling rects (normalized to the rectified target, top-left
    /// origin) in the profile's reading order (1–24).
    public let swatchSampleRects: [CGRect]
    /// The neutral region sampled for the white-balance lock + exposure anchor.
    public let wbSampleRect: CGRect
    /// Nominal sRGB of `wbSampleRect`'s neutral — the exposure-anchor reference.
    public let wbNominalSRGB: RGB
    /// The target's known reference colors (reading order == swatchSampleRects).
    public let profile: CardReferenceProfile

    public init(
        id: String,
        displayName: String,
        aspect: Double,
        detectionAspectMin: Double,
        detectionAspectMax: Double,
        swatchSampleRects: [CGRect],
        wbSampleRect: CGRect,
        wbNominalSRGB: RGB,
        profile: CardReferenceProfile
    ) {
        // The geometry must line up 1:1 with the profile it will be solved
        // against — a mismatch would sample the wrong number of swatches and
        // silently drop the solve to nil (or map colors onto the wrong reference).
        precondition(
            swatchSampleRects.count == profile.referenceSwatches.count,
            "\(id): \(swatchSampleRects.count) sample rects for \(profile.referenceSwatches.count) reference swatches")
        self.id = id
        self.displayName = displayName
        self.aspect = aspect
        self.detectionAspectMin = detectionAspectMin
        self.detectionAspectMax = detectionAspectMax
        self.swatchSampleRects = swatchSampleRects
        self.wbSampleRect = wbSampleRect
        self.wbNominalSRGB = wbNominalSRGB
        self.profile = profile
    }

    /// Row-major grid of sampling rects normalized to the target's bounds. Each
    /// cell is inset toward its center by `inset` (fraction of the cell shaved
    /// off EACH side) so a slightly misaligned hand-held target still samples the
    /// patch, not its border/gap. Reading order is left→right, top→bottom — which
    /// matches the ColorChecker (and Tovis) 1–24 order.
    public static func gridRects(
        cols: Int,
        rows: Int,
        borderX: Double,
        borderY: Double,
        gapX: Double,
        gapY: Double,
        inset: Double
    ) -> [CGRect] {
        precondition(cols > 0 && rows > 0)
        let cellW = (1 - 2 * borderX - gapX * Double(cols - 1)) / Double(cols)
        let cellH = (1 - 2 * borderY - gapY * Double(rows - 1)) / Double(rows)
        var rects: [CGRect] = []
        rects.reserveCapacity(cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let x = borderX + Double(c) * (cellW + gapX)
                let y = borderY + Double(r) * (cellH + gapY)
                let insetX = cellW * inset, insetY = cellH * inset
                rects.append(CGRect(
                    x: x + insetX,
                    y: y + insetY,
                    width: cellW - 2 * insetX,
                    height: cellH - 2 * insetY))
            }
        }
        return rects
    }

    // MARK: - Built-in targets

    /// The printed Tovis CR-80 card (v0) — byte-identical to the pre-target scan
    /// path: it just re-expresses the existing `CardGeometry` + placeholder
    /// profile as a target so the pipeline can be parameterized without changing
    /// today's behavior.
    public static let tovisCardV0 = CalibrationTarget(
        id: "tovis-card-v0",
        displayName: "Tovis card",
        aspect: CardGeometry.aspect,
        detectionAspectMin: 0.5,
        detectionAspectMax: 0.78,
        swatchSampleRects: CardGeometry.swatchSampleRects(),
        wbSampleRect: CardGeometry.wbSampleRect,
        wbNominalSRGB: CardGeometry.wbNominalSRGB,
        profile: .placeholderClassic
    )

    // ColorChecker Classic geometry — fractions of the DETECTED + rectified
    // target rectangle. ⚠️ DEVICE-TUNE (P3): these are first-pass estimates that
    // assume rectangle detection returns roughly the patch-array bounding region.
    // They isolate every physical unknown of the 6×4 chart in one place; adjust
    // against a real Passport in the dev console until the sampled grid lands on
    // the patches (the gray-ramp gate + a near-identity solve confirm alignment).
    static let ccCols = 6, ccRows = 4
    static let ccBorderX = 0.03, ccBorderY = 0.03
    static let ccGapX = 0.015, ccGapY = 0.02
    static let ccInset = 0.30
    // WB off "neutral 8" (patch 20, reading-order index 19) — a bright, low-noise
    // gray; brighter than the neutral-5 the matrix gain-strip anchors on.
    static let ccWBPatchIndex = 19
    static let ccWBNominalSRGB = RGB(200.0 / 255, 200.0 / 255, 200.0 / 255)

    /// A standard ColorChecker Classic (24-patch) chart — e.g. the Calibrite /
    /// X-Rite ColorChecker Passport's classic target. Because the physical chart
    /// genuinely matches its published reference (`.colorCheckerClassic`), this
    /// target validates the whole color pipeline against a trustworthy reference
    /// with NO printing. Reading order (1–24, gray ramp last) matches the Tovis
    /// card, so the calibration math is unchanged.
    public static let colorCheckerClassic: CalibrationTarget = {
        let rects = gridRects(
            cols: ccCols, rows: ccRows,
            borderX: ccBorderX, borderY: ccBorderY,
            gapX: ccGapX, gapY: ccGapY,
            inset: ccInset)
        return CalibrationTarget(
            id: "colorchecker-classic",
            displayName: "ColorChecker",
            aspect: 1.5,               // 6 wide × 4 tall square-ish patches
            detectionAspectMin: 1.15,
            detectionAspectMax: 1.9,
            swatchSampleRects: rects,
            wbSampleRect: rects[ccWBPatchIndex],
            wbNominalSRGB: ccWBNominalSRGB,
            profile: .colorCheckerClassic)
    }()

    /// Every built-in target, in picker order (Tovis card first = default).
    public static let all: [CalibrationTarget] = [.tovisCardV0, .colorCheckerClassic]
}

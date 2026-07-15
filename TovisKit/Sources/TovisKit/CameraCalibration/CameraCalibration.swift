// Camera color calibration — the math behind "true color for before/afters."
//
// Two tiers, both live here (pure + testable) so the app-side camera code just
// calls in:
//   1. Gray-card white balance — neutralize a gray/white sample into device WB
//      gains. Forgiving, needs no special card (a white towel works). USABLE NOW.
//   2. ColorChecker correction — solve a 3×3 color-correction matrix from measured
//      swatches vs. a card's known reference values. Accurate but only as good as
//      the printed card's *measured* swatches, keyed by the NFC card-version id.
//      SCAFFOLD — the reference profile below is a placeholder until a real card
//      batch is measured.
import CoreGraphics
import Foundation

/// A linear RGB triple in 0…1 (working space for the calibration math).
public struct RGB: Sendable, Equatable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
}

public enum CameraCalibration {

    // MARK: - Tier 1: gray-card white balance (usable now)

    /// White-balance gain multipliers that neutralize a supposedly-neutral (gray /
    /// white) `sample`, starting from the device's `current` gains. Anchors on the
    /// green channel and scales red/blue by the sample's channel ratios, then clamps
    /// each gain to the device's valid `[1, maxGain]` range. This is the "custom
    /// white balance off a grey card / white towel" path — forgiving, no card needed.
    public static func neutralizingGains(sample: RGB, current: RGB, maxGain: Double) -> RGB {
        let r = sample.r > 0 ? current.r * (sample.g / sample.r) : current.r
        let b = sample.b > 0 ? current.b * (sample.g / sample.b) : current.b
        func clamp(_ x: Double) -> Double { min(max(x, 1.0), maxGain) }
        return RGB(clamp(r), clamp(current.g), clamp(b))
    }

    // MARK: - Tier 2: ColorChecker 3×3 correction (scaffold)

    /// Solve the least-squares 3×3 color-correction matrix `X` mapping the camera's
    /// `measured` swatch colors onto the card's `reference` values (so applying `X`
    /// to any captured color corrects it toward truth). Nil if under-determined or
    /// singular. Pure — unit-tested; wired into the capture path once a real card's
    /// measured references exist.
    public static func correctionMatrix(measured: [RGB], reference: [RGB]) -> ColorMatrix3x3? {
        guard measured.count == reference.count, measured.count >= 3 else { return nil }
        // Normal equations per output channel: X_row = (MᵀM)⁻¹ Mᵀ t
        var gram = [Double](repeating: 0, count: 9)
        for s in measured {
            let v = [s.r, s.g, s.b]
            for i in 0..<3 { for j in 0..<3 { gram[i * 3 + j] += v[i] * v[j] } }
        }
        guard let inv = invert3x3(gram) else { return nil }

        func row(_ channel: (RGB) -> Double) -> [Double] {
            var mt = [0.0, 0.0, 0.0]
            for k in measured.indices {
                let s = measured[k], t = channel(reference[k])
                mt[0] += s.r * t; mt[1] += s.g * t; mt[2] += s.b * t
            }
            return [
                inv[0] * mt[0] + inv[1] * mt[1] + inv[2] * mt[2],
                inv[3] * mt[0] + inv[4] * mt[1] + inv[5] * mt[2],
                inv[6] * mt[0] + inv[7] * mt[1] + inv[8] * mt[2],
            ]
        }
        let rr = row { $0.r }, rg = row { $0.g }, rb = row { $0.b }
        return ColorMatrix3x3([rr[0], rr[1], rr[2], rg[0], rg[1], rg[2], rb[0], rb[1], rb[2]])
    }

    // MARK: - sRGB ↔ linear (color math belongs in linear light)

    /// sRGB EOTF: gamma-encoded 0…1 → linear 0…1.
    public static func srgbToLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    public static func srgbToLinear(_ c: RGB) -> RGB {
        RGB(srgbToLinear(c.r), srgbToLinear(c.g), srgbToLinear(c.b))
    }

    /// Rec.709 luma of a LINEAR color.
    public static func linearLuma(_ c: RGB) -> Double {
        0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    // MARK: - Card-applied correction (chromatic matrix + exposure anchor)

    /// The full card solve, from gamma-encoded sRGB samples (what the camera
    /// pipeline hands back) to a LINEAR-space chromatic correction matrix:
    /// linearize both sides, least-squares solve, then normalize overall gain so
    /// the neutral swatch keeps its measured luma — the matrix corrects COLOR
    /// only. Exposure is anchored separately (`exposureBiasEV`) at the camera,
    /// because auto-exposure re-meters between the card shot and the subject
    /// shot, so baking the card shot's gain into the matrix would mis-expose
    /// every other frame. Nil when the solve fails or reads as implausible
    /// (badly aligned card, glare) — callers should tell the pro to re-scan.
    public static func chromaticCorrection(
        measuredSRGB: [RGB],
        profile: CardReferenceProfile
    ) -> ColorMatrix3x3? {
        guard measuredSRGB.count == profile.referenceSwatches.count else { return nil }
        let measured = measuredSRGB.map(srgbToLinear)
        let reference = profile.referenceSwatches.map(srgbToLinear)
        guard var matrix = correctionMatrix(measured: measured, reference: reference) else { return nil }

        // Strip the exposure component: the neutral swatch's luma must survive
        // the correction unchanged.
        let neutral = measured[profile.neutralPatchIndex]
        let before = linearLuma(neutral)
        let after = linearLuma(matrix.apply(neutral))
        guard before > 1e-4, after > 1e-4 else { return nil }
        let gain = after / before
        matrix = ColorMatrix3x3(matrix.m.map { $0 / gain })

        guard isPlausible(matrix) else { return nil }
        return matrix
    }

    /// Exposure anchor from the card's neutral region: how many EV the camera
    /// should bias so the neutral renders at its reference luma. Positive =
    /// scene under-exposed → push exposure up. Clamped — a huge value means a
    /// bad read, not a huge correction.
    public static func exposureBiasEV(
        measuredNeutralSRGB: RGB,
        referenceNeutralSRGB: RGB,
        clampEV: Double = 1.5
    ) -> Double? {
        let measured = linearLuma(srgbToLinear(measuredNeutralSRGB))
        let reference = linearLuma(srgbToLinear(referenceNeutralSRGB))
        guard measured > 1e-4, reference > 1e-4 else { return nil }
        let ev = log2(reference / measured)
        return min(max(ev, -clampEV), clampEV)
    }

    /// Sanity gate for a solved matrix: near-diagonal-dominant with a healthy
    /// determinant. A wildly off matrix means the swatches weren't actually
    /// read (misaligned card, glare, occlusion) — better to reject and re-scan
    /// than to "correct" every photo with garbage.
    public static func isPlausible(_ matrix: ColorMatrix3x3) -> Bool {
        let m = matrix.m
        for d in [m[0], m[4], m[8]] where !(0.4...2.5).contains(d) { return false }
        for o in [m[1], m[2], m[3], m[5], m[6], m[7]] where abs(o) > 0.6 { return false }
        let det = m[0] * (m[4] * m[8] - m[5] * m[7])
                - m[1] * (m[3] * m[8] - m[5] * m[6])
                + m[2] * (m[3] * m[7] - m[4] * m[6])
        return det > 0.05
    }

    /// "Did we actually read a card?" — the last six swatches are a gray ramp
    /// (light → dark). A real read shows monotonically decreasing, near-neutral
    /// luma; a misaligned card or a random scene won't. Cheap and decisive.
    public static func looksLikeGrayRamp(measuredSRGB: [RGB]) -> Bool {
        guard measuredSRGB.count >= CardGeometry.swatchCount else { return false }
        // Ramp indices are defined against the full swatch grid; the count guard
        // above keeps them in range.
        let rampIndices = CardGeometry.grayRampIndices
        assert(rampIndices.upperBound <= measuredSRGB.count,
               "gray-ramp indices \(rampIndices) exceed \(measuredSRGB.count) swatches")
        let ramp = rampIndices.map { srgbToLinear(measuredSRGB[$0]) }
        let lumas = ramp.map(linearLuma)
        // Monotonic decreasing with real spread end-to-end.
        for i in 1..<lumas.count where lumas[i] >= lumas[i - 1] - 1e-4 { return false }
        guard lumas[0] > lumas[lumas.count - 1] * 2 else { return false }
        // Near-neutral: no channel dominates (WB is locked before this check).
        for c in ramp {
            let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
            if mx > 1e-3, (mx - mn) / mx > 0.35 { return false }
        }
        return true
    }

    /// Invert a row-major 3×3 matrix (adjugate / determinant). Nil if singular.
    static func invert3x3(_ m: [Double]) -> [Double]? {
        let a = m[0], b = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], i = m[8]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard abs(det) > 1e-12 else { return nil }
        let inv = 1.0 / det
        return [
            (e * i - f * h) * inv, (c * h - b * i) * inv, (b * f - c * e) * inv,
            (f * g - d * i) * inv, (a * i - c * g) * inv, (c * d - a * f) * inv,
            (d * h - e * g) * inv, (b * g - a * h) * inv, (a * e - b * d) * inv,
        ]
    }
}

/// A row-major 3×3 color-correction matrix, applied to a color as `X · c`.
public struct ColorMatrix3x3: Sendable, Equatable {
    public var m: [Double]  // 9 entries, row-major
    public init(_ m: [Double]) { precondition(m.count == 9); self.m = m }

    public static let identity = ColorMatrix3x3([1, 0, 0, 0, 1, 0, 0, 0, 1])

    public func apply(_ c: RGB) -> RGB {
        RGB(
            m[0] * c.r + m[1] * c.g + m[2] * c.b,
            m[3] * c.r + m[4] * c.g + m[5] * c.b,
            m[6] * c.r + m[7] * c.g + m[8] * c.b
        )
    }
}

/// Where things are on the printed v0 card — mirrors `docs/calibration/
/// generate_card.py` exactly (CR-80 85.6×54 mm, landscape: 12 swatches top,
/// 12 bottom, big neutral-gray band center). All rects are normalized to the
/// card's own bounds (top-left origin) so the sampler just needs the card's
/// region in the photo.
public enum CardGeometry {
    public static let widthMM = 85.6
    public static let heightMM = 54.0
    /// Card aspect (w/h) for the on-screen alignment box.
    public static let aspect = widthMM / heightMM

    // Layout constants from generate_card.py (mm, top-left origin).
    private static let border = 2.5
    private static let topY = 2.5, topH = 11.0
    private static let botY = 38.5, botH = 10.0
    private static let swatchPad = 0.75, gap = 0.5

    /// Swatches per row, and the full grid count (top row + bottom row). A
    /// reference profile must carry exactly `swatchCount` values — see
    /// `CardReferenceProfile.init`.
    public static let swatchesPerRow = 12
    public static var swatchCount: Int { swatchesPerRow * 2 }

    /// The gray ramp is the last `grayRampCount` swatches (light → dark); a real
    /// card read shows them monotonically decreasing and near-neutral (see
    /// `CameraCalibration.looksLikeGrayRamp`).
    public static let grayRampCount = 6
    /// Reading-order indices of the gray-ramp swatches (the last `grayRampCount`).
    public static var grayRampIndices: Range<Int> { (swatchCount - grayRampCount)..<swatchCount }

    /// The `swatchCount` swatch sampling rects in reading order (top row 1–12,
    /// bottom row 13–24), each inset toward its swatch's center so a slightly
    /// misaligned hand-held card still samples paint, not borders. `inset` is the
    /// fraction shaved off EACH side (0.28 keeps the central ~44%).
    public static func swatchSampleRects(inset: Double = 0.28) -> [CGRect] {
        rowRects(y: topY, h: topH, inset: inset) + rowRects(y: botY, h: botH, inset: inset)
    }

    private static func rowRects(y: Double, h: Double, inset: Double) -> [CGRect] {
        let innerW = widthMM - 2 * border
        let w = (innerW - gap * Double(swatchesPerRow - 1)) / Double(swatchesPerRow)
        let swatchY = y + swatchPad
        let swatchH = h - 2 * swatchPad
        return (0..<swatchesPerRow).map { i in
            let x = border + Double(i) * (w + gap)
            let insetX = w * inset, insetY = swatchH * inset
            return CGRect(
                x: (x + insetX) / widthMM,
                y: (swatchY + insetY) / heightMM,
                width: (w - 2 * insetX) / widthMM,
                height: (swatchH - 2 * insetY) / heightMM
            )
        }
    }

    /// Sampling rect inside the central neutral-gray band — kept below the
    /// band's printed label text and well inside its edges.
    public static let wbSampleRect = CGRect(x: 0.30, y: 0.40, width: 0.40, height: 0.22)
    /// The band's nominal paint (pure 128-gray). ⚠️ Like the swatches, replace
    /// with the batch's MEASURED value once cards are printed and measured.
    public static let wbNominalSRGB = RGB(128.0 / 255, 128.0 / 255, 128.0 / 255)
}

/// A calibration card's known reference values, keyed by the print-batch version
/// the NFC tag reports. ⚠️ The swatch values must be *measured per batch* — the
/// built-in profile below is a placeholder (nominal ColorChecker sRGB), NOT a
/// measured card, so the 3×3 matrix it produces is illustrative until a real card
/// is measured and its values keyed here by `cardVersion`.
public struct CardReferenceProfile: Sendable, Equatable {
    public let cardVersion: String
    /// Index (into `referenceSwatches`) of the neutral-gray patch used for WB.
    public let neutralPatchIndex: Int
    /// Known swatch colors in reading order (linear-ish sRGB 0…1).
    public let referenceSwatches: [RGB]

    public init(cardVersion: String, neutralPatchIndex: Int, referenceSwatches: [RGB]) {
        // The profile must line up 1:1 with the card's physical sampling grid — a
        // mismatched count would silently map every measured color onto the wrong
        // reference (or drop the solve to nil), and an out-of-range neutral index
        // would crash the exposure-strip step in `chromaticCorrection`.
        precondition(
            referenceSwatches.count == CardGeometry.swatchCount,
            "CardReferenceProfile '\(cardVersion)' needs \(CardGeometry.swatchCount) swatches, got \(referenceSwatches.count)")
        precondition(
            referenceSwatches.indices.contains(neutralPatchIndex),
            "neutralPatchIndex \(neutralPatchIndex) out of range for \(referenceSwatches.count) swatches")
        self.cardVersion = cardVersion
        self.neutralPatchIndex = neutralPatchIndex
        self.referenceSwatches = referenceSwatches
    }

    /// Nominal 24-patch ColorChecker Classic sRGB (X-Rite / BabelColor published
    /// averages), reading order 1–24, normalized 0…1. Deliberately SHARED by two
    /// profiles with opposite trust levels: as the printed Tovis card's
    /// placeholder these are only illustrative (a dye-sub print is not
    /// color-accurate — measure the batch), but as a *real* ColorChecker's
    /// reference they're legitimate (the chart is manufactured to ~these values,
    /// ΔE a few; a per-unit spectrophotometer read refines them).
    public static let colorCheckerNominalSRGB: [RGB] = [
        RGB(115, 82, 68), RGB(194, 150, 130), RGB(98, 122, 157), RGB(87, 108, 67),
        RGB(133, 128, 177), RGB(103, 189, 170), RGB(214, 126, 44), RGB(80, 91, 166),
        RGB(193, 90, 99), RGB(94, 60, 108), RGB(157, 188, 64), RGB(224, 163, 46),
        RGB(56, 61, 150), RGB(70, 148, 73), RGB(175, 54, 60), RGB(231, 199, 31),
        RGB(187, 86, 149), RGB(8, 133, 161), RGB(243, 243, 242), RGB(200, 200, 200),
        RGB(160, 160, 160), RGB(122, 122, 121), RGB(85, 85, 85), RGB(52, 52, 52),
    ].map { RGB($0.r / 255, $0.g / 255, $0.b / 255) }

    /// PLACEHOLDER profile for the printed TOVIS card — nominal values, NOT the
    /// card's *measured* colors, so its 3×3 matrix is illustrative until a batch
    /// is measured and keyed by `cardVersion`. (A real ColorChecker chart uses
    /// `.colorCheckerClassic`, whose nominal values it genuinely matches.)
    public static let placeholderClassic = CardReferenceProfile(
        cardVersion: "placeholder-classic-v0",
        neutralPatchIndex: 21,  // "neutral 5" gray
        referenceSwatches: colorCheckerNominalSRGB
    )

    /// A real ColorChecker Classic (24-patch) chart. Unlike a dye-sub print, the
    /// physical chart genuinely matches these published nominal sRGB values, so
    /// this profile is TRUSTWORTHY for calibrating/validating the color pipeline
    /// with no printing (see `CalibrationTarget.colorCheckerClassic`). Reading
    /// order + neutral index match the Tovis card's (gray ramp last, neutral-5 at
    /// 21). Refine with a per-unit spectrophotometer read for sub-ΔE accuracy.
    public static let colorCheckerClassic = CardReferenceProfile(
        cardVersion: "colorchecker-classic",
        neutralPatchIndex: 21,  // "neutral 5" gray (row 4, patch 22)
        referenceSwatches: colorCheckerNominalSRGB
    )
}

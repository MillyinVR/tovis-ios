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
        self.cardVersion = cardVersion
        self.neutralPatchIndex = neutralPatchIndex
        self.referenceSwatches = referenceSwatches
    }

    /// PLACEHOLDER profile — nominal 24-patch ColorChecker sRGB values (X-Rite),
    /// normalized 0…1. Replace with a real batch's *measured* values, selected by
    /// the NFC card-version id, before trusting the 3×3 matrix.
    public static let placeholderClassic = CardReferenceProfile(
        cardVersion: "placeholder-classic-v0",
        neutralPatchIndex: 21,  // "neutral 5" gray
        referenceSwatches: [
            RGB(115, 82, 68), RGB(194, 150, 130), RGB(98, 122, 157), RGB(87, 108, 67),
            RGB(133, 128, 177), RGB(103, 189, 170), RGB(214, 126, 44), RGB(80, 91, 166),
            RGB(193, 90, 99), RGB(94, 60, 108), RGB(157, 188, 64), RGB(224, 163, 46),
            RGB(56, 61, 150), RGB(70, 148, 73), RGB(175, 54, 60), RGB(231, 199, 31),
            RGB(187, 86, 149), RGB(8, 133, 161), RGB(243, 243, 242), RGB(200, 200, 200),
            RGB(160, 160, 160), RGB(122, 122, 121), RGB(85, 85, 85), RGB(52, 52, 52),
        ].map { RGB($0.r / 255, $0.g / 255, $0.b / 255) }
    )
}

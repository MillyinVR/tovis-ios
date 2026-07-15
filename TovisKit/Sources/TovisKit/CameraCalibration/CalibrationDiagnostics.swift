// Everything a card scan learned about a read, whether or not it passed — the
// data a DEBUG diagnostics sheet needs to TUNE a target's geometry against a real
// chart. A scan that only says "Card locked" / "couldn't read" gives no signal
// about WHY the ColorChecker geometry constants (border/gap/inset/aspect) are or
// aren't landing on the patches; this exposes the gray-ramp gate result, the
// solved matrix (even one the plausibility gate rejects) with its determinant and
// diagonal shape, the exposure anchor, and per-patch measured-vs-reference sRGB —
// turning geometry tuning into a tight loop.
//
// Pure (no camera, no CoreImage) so it's unit-tested; the app computes it off the
// scan's already-sampled swatches + neutral band and renders it in a DEBUG sheet.
import Foundation

/// A read-out of one card scan for tuning/validation, computed from the sampled
/// swatches (reading order 1–24, gray ramp last) + neutral band and the target
/// they were sampled against.
public struct CalibrationDiagnostics: Sendable, Equatable {

    /// One swatch's measured sample vs the target's known reference (both
    /// gamma-encoded sRGB 0…1), in reading order.
    public struct Patch: Sendable, Equatable {
        public let index: Int          // 0-based reading order
        public let measuredSRGB: RGB
        public let referenceSRGB: RGB
        public init(index: Int, measuredSRGB: RGB, referenceSRGB: RGB) {
            self.index = index
            self.measuredSRGB = measuredSRGB
            self.referenceSRGB = referenceSRGB
        }
    }

    /// The target this read was sampled against (id for the sheet header).
    public let targetId: String
    /// Whether the read-gate (`looksLikeGrayRamp`) accepted this read. A failed
    /// gate with a plausible-looking ramp below usually means near-miss geometry.
    public let grayRampPasses: Bool
    /// Linear luma of each gray-ramp swatch, light→dark — should be monotonically
    /// decreasing with real spread when the grid lands on the ramp.
    public let grayRampLumas: [Double]
    /// The gain-stripped chromatic matrix from the solve, reported EVEN when the
    /// plausibility gate would reject it (nil only when the solve can't run).
    public let matrix: ColorMatrix3x3?
    /// Determinant of `matrix` (nil when there's no matrix).
    public let determinant: Double?
    /// Whether `matrix` passes the same plausibility gate `chromaticCorrection`
    /// applies — i.e. whether this scan would actually calibrate.
    public let isPlausible: Bool
    /// EV the neutral would anchor exposure to (nil when the neutral is unreadable).
    public let exposureBiasEV: Double?
    /// The neutral band's measured sample and the target's nominal reference.
    public let neutralMeasuredSRGB: RGB
    public let neutralReferenceSRGB: RGB
    /// Per-swatch measured vs reference, reading order (empty on a count mismatch).
    public let patches: [Patch]

    public init(
        targetId: String,
        grayRampPasses: Bool,
        grayRampLumas: [Double],
        matrix: ColorMatrix3x3?,
        determinant: Double?,
        isPlausible: Bool,
        exposureBiasEV: Double?,
        neutralMeasuredSRGB: RGB,
        neutralReferenceSRGB: RGB,
        patches: [Patch]
    ) {
        self.targetId = targetId
        self.grayRampPasses = grayRampPasses
        self.grayRampLumas = grayRampLumas
        self.matrix = matrix
        self.determinant = determinant
        self.isPlausible = isPlausible
        self.exposureBiasEV = exposureBiasEV
        self.neutralMeasuredSRGB = neutralMeasuredSRGB
        self.neutralReferenceSRGB = neutralReferenceSRGB
        self.patches = patches
    }

    /// Whether a real scan with this read would actually calibrate — the AND of
    /// every gate `scanCard` applies (ramp gate, a plausible solved matrix, a
    /// readable exposure anchor). A `false` here with numbers that look close is
    /// the geometry-tuning signal.
    public var wouldCalibrate: Bool {
        grayRampPasses && matrix != nil && isPlausible && exposureBiasEV != nil
    }

    /// The matrix diagonal `[m00, m11, m22]` (per-channel gain), or nil.
    public var matrixDiagonal: [Double]? { matrix.map { [$0.m[0], $0.m[4], $0.m[8]] } }
    /// The six off-diagonal terms (cross-channel bleed), or nil.
    public var matrixOffDiagonal: [Double]? {
        matrix.map { [$0.m[1], $0.m[2], $0.m[3], $0.m[5], $0.m[6], $0.m[7]] }
    }
    /// Largest absolute off-diagonal term — the plausibility gate rejects > 0.6.
    public var maxOffDiagonal: Double? { matrixOffDiagonal.map { $0.map(abs).max() ?? 0 } }
}

public extension CameraCalibration {
    /// Read out everything one card scan learned, for a DEBUG diagnostics sheet.
    /// Runs the SAME primitives the scan does (`looksLikeGrayRamp`,
    /// `solvedChromaticMatrix`, `isPlausible`, `exposureBiasEV`) so the numbers
    /// shown are exactly the ones that gate a real scan — but reports the solved
    /// matrix even when the gate would reject it, which is precisely what's needed
    /// to tell a near-miss geometry read from a genuinely bad one.
    static func diagnose(
        measuredSRGB: [RGB],
        neutralBand: RGB,
        target: CalibrationTarget
    ) -> CalibrationDiagnostics {
        let profile = target.profile
        let grayRampPasses = looksLikeGrayRamp(measuredSRGB: measuredSRGB)
        // Ramp lumas use the same indices as the gate; only compute when the
        // grid is present (the gate's own count guard).
        let rampLumas: [Double] = measuredSRGB.count >= CardGeometry.swatchCount
            ? CardGeometry.grayRampIndices.map { linearLuma(srgbToLinear(measuredSRGB[$0])) }
            : []
        let matrix = solvedChromaticMatrix(measuredSRGB: measuredSRGB, profile: profile)
        let patches: [CalibrationDiagnostics.Patch] = measuredSRGB.count == profile.referenceSwatches.count
            ? measuredSRGB.indices.map {
                .init(index: $0, measuredSRGB: measuredSRGB[$0], referenceSRGB: profile.referenceSwatches[$0])
            }
            : []
        return CalibrationDiagnostics(
            targetId: target.id,
            grayRampPasses: grayRampPasses,
            grayRampLumas: rampLumas,
            matrix: matrix,
            determinant: matrix.map(determinant),
            isPlausible: matrix.map(isPlausible) ?? false,
            exposureBiasEV: exposureBiasEV(
                measuredNeutralSRGB: neutralBand, referenceNeutralSRGB: target.wbNominalSRGB),
            neutralMeasuredSRGB: neutralBand,
            neutralReferenceSRGB: target.wbNominalSRGB,
            patches: patches)
    }
}

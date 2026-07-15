// A persisted card calibration, tagged with the reference it was solved against.
//
// The scan solves a chromatic matrix + exposure anchor for ONE physical target
// (the printed Tovis card, or — in DEBUG — a real ColorChecker) and caches it per
// booking so the AFTER shoot re-applies the BEFORE's calibration automatically.
// But a matrix is only meaningful for the target it came from: restoring a
// ColorChecker-solved matrix into a Tovis-card session (or a matrix from a stale
// card batch into a newer one) would silently mis-correct every photo. So the
// cache is tagged with the target id + the profile's card version, and only
// restored when BOTH match the active target — otherwise the pro must re-scan.
//
// Pure keying/restore logic (no UserDefaults) so it's unit-tested; the app
// JSON-encodes it under the per-booking key and gates the decode with
// `restorable(for:)`.
import Foundation

public struct StoredCardCalibration: Codable, Equatable, Sendable {
    /// The `CalibrationTarget.id` this calibration was solved against.
    public let targetId: String
    /// The target profile's `cardVersion` — distinguishes card batches sharing a
    /// target id (e.g. a future measured Tovis card vs today's placeholder).
    public let cardVersion: String
    /// The 9 row-major chromatic-matrix values.
    public let matrix: [Double]
    /// The exposure-bias EV anchored from the neutral band.
    public let exposureBiasEV: Double
    /// Scene warmth at scan time (the drift detector's baseline), if captured.
    public let calibrationWarmth: Double?

    public init(
        targetId: String,
        cardVersion: String,
        matrix: [Double],
        exposureBiasEV: Double,
        calibrationWarmth: Double?
    ) {
        self.targetId = targetId
        self.cardVersion = cardVersion
        self.matrix = matrix
        self.exposureBiasEV = exposureBiasEV
        self.calibrationWarmth = calibrationWarmth
    }

    /// Build a record tagging `matrix`/`ev` with the target that produced them.
    public init(
        target: CalibrationTarget,
        matrix: ColorMatrix3x3,
        exposureBiasEV: Double,
        calibrationWarmth: Double?
    ) {
        self.init(
            targetId: target.id,
            cardVersion: target.profile.cardVersion,
            matrix: matrix.m,
            exposureBiasEV: exposureBiasEV,
            calibrationWarmth: calibrationWarmth)
    }

    /// The stored matrix as a `ColorMatrix3x3`, or nil if the payload is the
    /// wrong shape (corrupt / cross-version data) — never crashes on restore.
    public var colorMatrix: ColorMatrix3x3? {
        matrix.count == 9 ? ColorMatrix3x3(matrix) : nil
    }

    /// This calibration IFF it was solved against `target` (same id AND card
    /// version) — otherwise nil, so a mismatched matrix is never silently reused
    /// and the caller falls back to "re-scan against the active target".
    public func restorable(for target: CalibrationTarget) -> StoredCardCalibration? {
        guard targetId == target.id,
              cardVersion == target.profile.cardVersion else { return nil }
        return self
    }
}

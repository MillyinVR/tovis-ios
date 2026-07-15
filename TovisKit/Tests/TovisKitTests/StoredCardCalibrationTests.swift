import Foundation
import Testing
@testable import TovisKit

// The target-tagged calibration cache. A solved matrix is only meaningful for the
// reference it came from, so the per-booking cache must refuse to restore a
// calibration produced against a different target (id) or card batch (version) —
// otherwise switching the DEBUG "Ref" target (or a future measured card) would
// silently reuse a mismatched matrix on every photo. Pure keying/restore logic.
struct StoredCardCalibrationTests {

    private let sampleMatrix = [1.1, -0.05, 0.02, 0.03, 0.95, 0.01, -0.02, 0.04, 1.2]

    @Test func restoresWhenTargetMatches() {
        let target = CalibrationTarget.tovisCardV0
        let record = StoredCardCalibration(
            target: target, matrix: ColorMatrix3x3(sampleMatrix),
            exposureBiasEV: 0.4, calibrationWarmth: 0.1)
        #expect(record.targetId == target.id)
        #expect(record.cardVersion == target.profile.cardVersion)
        #expect(record.restorable(for: target) == record)
        #expect(record.colorMatrix == ColorMatrix3x3(sampleMatrix))
    }

    @Test func refusesWhenTargetIdDiffers() {
        // Solved against the ColorChecker → must NOT restore into a Tovis-card
        // session (the default, production) — a ColorChecker matrix would
        // mis-correct against the printed card's spectrum.
        let record = StoredCardCalibration(
            target: .colorCheckerClassic, matrix: ColorMatrix3x3(sampleMatrix),
            exposureBiasEV: 0, calibrationWarmth: nil)
        #expect(record.restorable(for: .colorCheckerClassic) != nil)
        #expect(record.restorable(for: .tovisCardV0) == nil)
    }

    @Test func refusesWhenCardVersionDiffers() {
        // Same target id, a different card batch (a future measured profile) →
        // refuse: the reference swatches changed, so the old matrix is stale.
        let record = StoredCardCalibration(
            targetId: CalibrationTarget.tovisCardV0.id,
            cardVersion: "measured-batch-2027",
            matrix: sampleMatrix, exposureBiasEV: 0, calibrationWarmth: nil)
        #expect(record.restorable(for: .tovisCardV0) == nil)
    }

    @Test func codableRoundTrips() throws {
        let record = StoredCardCalibration(
            target: .tovisCardV0, matrix: ColorMatrix3x3(sampleMatrix),
            exposureBiasEV: 0.7, calibrationWarmth: 0.2)
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(StoredCardCalibration.self, from: data) == record)
        // A nil warmth survives the round-trip too.
        let noWarmth = StoredCardCalibration(
            target: .tovisCardV0, matrix: ColorMatrix3x3(sampleMatrix),
            exposureBiasEV: 0, calibrationWarmth: nil)
        let decoded = try JSONDecoder().decode(
            StoredCardCalibration.self, from: JSONEncoder().encode(noWarmth))
        #expect(decoded.calibrationWarmth == nil)
    }

    @Test func colorMatrixGuardsShape() {
        // A wrong-length payload (corrupt data) → nil, never a precondition crash.
        let bad = StoredCardCalibration(
            targetId: "x", cardVersion: "y", matrix: [1, 2, 3],
            exposureBiasEV: 0, calibrationWarmth: nil)
        #expect(bad.colorMatrix == nil)
    }

    @Test func legacyArrayPayloadDoesNotDecode() {
        // The pre-tagging format was a bare [Double] (matrix + ev [+ warmth]); it
        // must fail to decode as the tagged record so the caller falls back to
        // "re-scan" rather than restoring an untagged (possibly cross-target)
        // matrix. A one-time re-scan is the correct, safe migration.
        let legacy = try! JSONEncoder().encode(sampleMatrix + [0.4])
        #expect((try? JSONDecoder().decode(StoredCardCalibration.self, from: legacy)) == nil)
    }
}

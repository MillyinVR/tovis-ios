import Foundation
import Testing
@testable import TovisKit

// The DEBUG scan read-out. `diagnose` runs the same primitives a real scan gates
// on, but reports them (and the solved matrix) even on a failed read — the signal
// that makes tuning a target's geometry a tight loop. These lock that contract:
// a clean read reads as "would calibrate", a bad read still reports numbers, and
// a malformed read degrades without crashing.
struct CalibrationDiagnosticsTests {

    @Test func perfectReadWouldCalibrate() {
        // Measured == reference (a real ColorChecker under neutral light) → the
        // gold-standard read: ramp passes, matrix ~identity + plausible, EV ~0.
        let target = CalibrationTarget.colorCheckerClassic
        let d = CameraCalibration.diagnose(
            measuredSRGB: target.profile.referenceSwatches,
            neutralBand: target.wbNominalSRGB,
            target: target)
        #expect(d.targetId == target.id)
        #expect(d.grayRampPasses)
        #expect(d.matrix != nil)
        #expect(d.isPlausible)
        #expect(d.wouldCalibrate)
        #expect(d.patches.count == 24)
        // Identity-ish diagonal, no off-diagonal bleed.
        for v in try! #require(d.matrixDiagonal) { #expect(abs(v - 1) < 1e-6) }
        #expect((d.maxOffDiagonal ?? 1) < 1e-6)
        #expect(abs((d.determinant ?? 0) - 1) < 1e-6)
        // Neutral measured == reference → ~0 EV.
        #expect(abs(d.exposureBiasEV ?? 99) < 1e-6)
        // Ramp lumas strictly decreasing (light→dark), real spread.
        let lumas = d.grayRampLumas
        #expect(lumas.count == 6)
        for i in 1..<lumas.count { #expect(lumas[i] < lumas[i - 1]) }
    }

    @Test func offGridReadReportsButDoesNotCalibrate() {
        // A grid landing off the patches (here: reversed reading order, so the
        // gray ramp isn't at the tail) fails the gate — but STILL reports every
        // patch + the ramp read, which is exactly what tuning needs.
        let target = CalibrationTarget.colorCheckerClassic
        let measured = Array(target.profile.referenceSwatches.reversed())
        let d = CameraCalibration.diagnose(
            measuredSRGB: measured, neutralBand: target.wbNominalSRGB, target: target)
        #expect(!d.grayRampPasses)
        #expect(!d.wouldCalibrate)
        #expect(d.patches.count == 24)          // still fully reported
        #expect(d.grayRampLumas.count == 6)
        // The measured side of patch 0 is the reference's LAST swatch (reversed).
        #expect(d.patches[0].measuredSRGB == target.profile.referenceSwatches[23])
        #expect(d.patches[0].referenceSRGB == target.profile.referenceSwatches[0])
    }

    @Test func countMismatchDegradesGracefully() {
        // A wrong-sized read (grid geometry way off) must not crash: no patches,
        // no ramp, no matrix, does-not-calibrate.
        let target = CalibrationTarget.colorCheckerClassic
        let d = CameraCalibration.diagnose(
            measuredSRGB: Array(target.profile.referenceSwatches.prefix(10)),
            neutralBand: target.wbNominalSRGB, target: target)
        #expect(d.patches.isEmpty)
        #expect(d.grayRampLumas.isEmpty)
        #expect(d.matrix == nil)
        #expect(d.determinant == nil)
        #expect(!d.grayRampPasses)
        #expect(!d.isPlausible)
        #expect(!d.wouldCalibrate)
        // The exposure anchor is independent of the swatch grid → still readable.
        #expect(d.exposureBiasEV != nil)
    }

    @Test func unreadableNeutralHasNilExposureButStillReportsSwatches() {
        // A pitch-black neutral band (luma ~0) can't anchor exposure → nil EV, so
        // the read wouldn't calibrate even with a clean grid.
        let target = CalibrationTarget.colorCheckerClassic
        let d = CameraCalibration.diagnose(
            measuredSRGB: target.profile.referenceSwatches,
            neutralBand: RGB(0, 0, 0),
            target: target)
        #expect(d.exposureBiasEV == nil)
        #expect(!d.wouldCalibrate)
        #expect(d.grayRampPasses)               // the grid itself is still clean
        #expect(d.matrix != nil)
    }
}

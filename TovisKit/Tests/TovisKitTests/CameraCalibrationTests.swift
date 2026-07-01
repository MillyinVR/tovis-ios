import Foundation
import Testing
@testable import TovisKit

// Pure calibration math (no camera). Gray-card WB gains + the ColorChecker 3×3
// least-squares solve.
struct CameraCalibrationTests {

    // MARK: - Gray-card white balance

    @Test func neutralGraySampleLeavesGainsPutClamped() {
        // A perfectly neutral sample → no ratio correction (gains stay, clamped ≥1).
        let gains = CameraCalibration.neutralizingGains(
            sample: RGB(0.5, 0.5, 0.5), current: RGB(1.4, 1.0, 1.8), maxGain: 4.0)
        #expect(abs(gains.r - 1.4) < 1e-9)
        #expect(abs(gains.g - 1.0) < 1e-9)
        #expect(abs(gains.b - 1.8) < 1e-9)
    }

    @Test func warmSampleBoostsBlueGainToNeutralize() {
        // A warm (red-heavy, blue-poor) gray → push blue gain up, red gain down.
        let sample = RGB(0.6, 0.5, 0.4)   // r>g>b (warm cast)
        let gains = CameraCalibration.neutralizingGains(
            sample: sample, current: RGB(1.0, 1.0, 1.0), maxGain: 8.0)
        #expect(gains.b > gains.g)   // lift the deficient blue
        #expect(gains.r <= gains.g + 1e-9)  // red was over — clamped to floor 1.0
        // Applying the gains to the sample should even the channels out.
        let corrected = RGB(sample.r * gains.r, sample.g * gains.g, sample.b * gains.b)
        #expect(abs(corrected.g - corrected.b) < 1e-9)
    }

    @Test func gainsClampToMax() {
        let gains = CameraCalibration.neutralizingGains(
            sample: RGB(0.9, 0.5, 0.1), current: RGB(1.0, 1.0, 1.0), maxGain: 2.0)
        #expect(gains.b <= 2.0 + 1e-9)
        #expect(gains.r >= 1.0 - 1e-9)
    }

    // MARK: - ColorChecker 3×3 solve

    @Test func recoversAKnownLinearTransform() {
        // Manufacture measured→reference by a known matrix, then confirm the solver
        // recovers it (well-conditioned inputs).
        let truth = ColorMatrix3x3([1.1, -0.05, 0.02, 0.03, 0.95, 0.01, -0.02, 0.04, 1.2])
        let measured = [
            RGB(0.1, 0.2, 0.3), RGB(0.8, 0.1, 0.4), RGB(0.3, 0.7, 0.2),
            RGB(0.5, 0.5, 0.5), RGB(0.9, 0.8, 0.1), RGB(0.2, 0.3, 0.9),
        ]
        let reference = measured.map { truth.apply($0) }
        let solved = CameraCalibration.correctionMatrix(measured: measured, reference: reference)
        let s = try! #require(solved)
        for i in 0..<9 { #expect(abs(s.m[i] - truth.m[i]) < 1e-6) }
    }

    @Test func identityWhenMeasuredEqualsReference() {
        let colors = [RGB(0.2, 0.4, 0.6), RGB(0.7, 0.1, 0.3), RGB(0.5, 0.9, 0.2), RGB(0.1, 0.1, 0.8)]
        let solved = try! #require(CameraCalibration.correctionMatrix(measured: colors, reference: colors))
        let id = ColorMatrix3x3.identity
        for i in 0..<9 { #expect(abs(solved.m[i] - id.m[i]) < 1e-6) }
    }

    @Test func underdeterminedReturnsNil() {
        #expect(CameraCalibration.correctionMatrix(measured: [RGB(0.5, 0.5, 0.5)],
                                                   reference: [RGB(0.5, 0.5, 0.5)]) == nil)
    }

    @Test func placeholderProfileIsWellFormed() {
        let p = CardReferenceProfile.placeholderClassic
        #expect(p.referenceSwatches.count == 24)
        #expect(p.referenceSwatches.indices.contains(p.neutralPatchIndex))
        // The neutral patch really is near-gray (channels close).
        let n = p.referenceSwatches[p.neutralPatchIndex]
        #expect(abs(n.r - n.g) < 0.02 && abs(n.g - n.b) < 0.02)
    }
}

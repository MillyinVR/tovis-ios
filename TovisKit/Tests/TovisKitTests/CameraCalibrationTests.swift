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

    // MARK: - sRGB ↔ linear

    @Test func linearizationMatchesKnownAnchors() {
        #expect(abs(CameraCalibration.srgbToLinear(0.0)) < 1e-12)
        #expect(abs(CameraCalibration.srgbToLinear(1.0) - 1.0) < 1e-9)
        // 50% sRGB gray is ~21.4% linear — the classic anchor.
        #expect(abs(CameraCalibration.srgbToLinear(0.5) - 0.2140) < 1e-3)
    }

    // MARK: - Chromatic correction (card-applied)

    @Test func perfectReadYieldsNearIdentity() {
        // Measured == reference → nothing to correct.
        let profile = CardReferenceProfile.placeholderClassic
        let solved = CameraCalibration.chromaticCorrection(
            measuredSRGB: profile.referenceSwatches, profile: profile)
        let m = try! #require(solved)
        for i in 0..<9 {
            #expect(abs(m.m[i] - ColorMatrix3x3.identity.m[i]) < 1e-6)
        }
    }

    @Test func uniformDimmingIsAbsorbedByGainNormalization() {
        // The whole card measured darker (AE under-exposed) but color-true →
        // the CHROMATIC matrix must stay ~identity-shaped (scaled), preserving
        // the neutral's luma: exposure is the EV anchor's job, not the matrix's.
        let profile = CardReferenceProfile.placeholderClassic
        // Dim in LINEAR light: linearize, halve, re-encode.
        func dim(_ c: RGB) -> RGB {
            let l = CameraCalibration.srgbToLinear(c)
            func enc(_ v: Double) -> Double {
                v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
            }
            return RGB(enc(l.r * 0.5), enc(l.g * 0.5), enc(l.b * 0.5))
        }
        let measured = profile.referenceSwatches.map(dim)
        let solved = try! #require(CameraCalibration.chromaticCorrection(
            measuredSRGB: measured, profile: profile))
        // Neutral swatch luma survives the correction unchanged.
        let neutral = CameraCalibration.srgbToLinear(measured[profile.neutralPatchIndex])
        let before = CameraCalibration.linearLuma(neutral)
        let after = CameraCalibration.linearLuma(solved.apply(neutral))
        #expect(abs(after - before) < 1e-9)
        // And the matrix is still plausible (no wild gain baked in).
        #expect(CameraCalibration.isPlausible(solved))
    }

    @Test func implausibleMatrixIsRejected() {
        #expect(!CameraCalibration.isPlausible(ColorMatrix3x3([5, 0, 0, 0, 1, 0, 0, 0, 1])))
        #expect(!CameraCalibration.isPlausible(ColorMatrix3x3([1, 0.9, 0, 0, 1, 0, 0, 0, 1])))
        #expect(CameraCalibration.isPlausible(.identity))
    }

    // MARK: - Exposure anchor

    @Test func halfLumaNeutralReadsAsPlusOneEV() {
        // Neutral measured at half its reference LINEAR luma → +1 EV.
        let reference = RGB(0.5, 0.5, 0.5)
        let refLinear = CameraCalibration.srgbToLinear(0.5)
        func enc(_ v: Double) -> Double {
            v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        let half = enc(refLinear * 0.5)
        let ev = try! #require(CameraCalibration.exposureBiasEV(
            measuredNeutralSRGB: RGB(half, half, half), referenceNeutralSRGB: reference))
        #expect(abs(ev - 1.0) < 1e-6)
    }

    @Test func exposureBiasClampsWildReads() {
        let ev = try! #require(CameraCalibration.exposureBiasEV(
            measuredNeutralSRGB: RGB(0.02, 0.02, 0.02),
            referenceNeutralSRGB: RGB(0.9, 0.9, 0.9)))
        #expect(abs(ev - 1.5) < 1e-9)   // clamped, not ±6 EV
    }

    // MARK: - Card-read validation (gray ramp)

    @Test func realGrayRampPasses() {
        #expect(CameraCalibration.looksLikeGrayRamp(
            measuredSRGB: CardReferenceProfile.placeholderClassic.referenceSwatches))
    }

    @Test func nonMonotonicOrColorfulRampFails() {
        var shuffled = CardReferenceProfile.placeholderClassic.referenceSwatches
        shuffled.swapAt(19, 22)   // break monotonicity
        #expect(!CameraCalibration.looksLikeGrayRamp(measuredSRGB: shuffled))

        var tinted = CardReferenceProfile.placeholderClassic.referenceSwatches
        tinted[20] = RGB(0.8, 0.4, 0.3)   // a "gray" that isn't
        #expect(!CameraCalibration.looksLikeGrayRamp(measuredSRGB: tinted))
    }

    // MARK: - Card geometry

    @Test func cardGeometryIsSane() {
        let rects = CardGeometry.swatchSampleRects()
        #expect(rects.count == 24)
        for r in rects {
            #expect(r.minX >= 0 && r.maxX <= 1 && r.minY >= 0 && r.maxY <= 1)
            #expect(r.width > 0 && r.height > 0)
        }
        // Reading order: 12 top-row rects strictly left→right, then 12 bottom.
        for i in 1..<12 { #expect(rects[i].minX > rects[i - 1].minX) }
        for i in 13..<24 { #expect(rects[i].minX > rects[i - 1].minX) }
        // Top row sits above the WB band; bottom row below it.
        for i in 0..<12 { #expect(rects[i].maxY < CardGeometry.wbSampleRect.minY) }
        for i in 12..<24 { #expect(rects[i].minY > CardGeometry.wbSampleRect.maxY) }
        // The WB band sample avoids the swatch rows entirely.
        #expect(CardGeometry.aspect > 1.5 && CardGeometry.aspect < 1.7)
    }

    @Test func swatchGridCouplesToProfileAndRamp() {
        // The sampling grid, the swatch-count constant, and the reference profile
        // must all agree — the profile init depends on it.
        #expect(CardGeometry.swatchCount == 24)
        #expect(CardGeometry.swatchSampleRects().count == CardGeometry.swatchCount)
        #expect(CardReferenceProfile.placeholderClassic.referenceSwatches.count
                == CardGeometry.swatchCount)

        // The gray ramp is the last `grayRampCount` swatches, in range.
        let ramp = CardGeometry.grayRampIndices
        #expect(ramp.count == CardGeometry.grayRampCount)
        #expect(ramp.upperBound == CardGeometry.swatchCount)
        #expect(ramp.lowerBound >= 0)
    }
}

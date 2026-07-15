import CoreGraphics
import Foundation
import Testing
@testable import TovisKit

// The CalibrationTarget geometry + the real ColorChecker profile. The scan
// pipeline's math is exercised by CameraCalibrationTests; here we prove that (a)
// a real ColorChecker target is a trustworthy reference (its published values
// solve to a clean identity, its gray ramp validates), (b) the 6×4 geometry is
// well-formed, and (c) the Tovis-card target is byte-identical to the pre-target
// scan path (no regression).
struct CalibrationTargetTests {

    // MARK: - ColorChecker reference profile

    @Test func colorCheckerProfileIsWellFormed() {
        let p = CardReferenceProfile.colorCheckerClassic
        #expect(p.referenceSwatches.count == CardGeometry.swatchCount)   // 24
        #expect(p.referenceSwatches.indices.contains(p.neutralPatchIndex))
        // Shares the nominal ColorChecker values with the printed-card placeholder
        // (same chart colors, different trust level) — not a second hand-typed copy.
        #expect(p.referenceSwatches == CardReferenceProfile.placeholderClassic.referenceSwatches)
        #expect(p.cardVersion != CardReferenceProfile.placeholderClassic.cardVersion)
    }

    @Test func colorCheckerReferenceSolvesToIdentity() {
        // Photographing a real ColorChecker under neutral light (measured ==
        // reference) must yield ~no correction — the gold-standard validation the
        // Passport enables: a wrong pipeline could not produce this.
        let profile = CardReferenceProfile.colorCheckerClassic
        let m = try! #require(CameraCalibration.chromaticCorrection(
            measuredSRGB: profile.referenceSwatches, profile: profile))
        for i in 0..<9 {
            #expect(abs(m.m[i] - ColorMatrix3x3.identity.m[i]) < 1e-6)
        }
        #expect(CameraCalibration.isPlausible(m))
    }

    @Test func colorCheckerGrayRampValidates() {
        // The last six patches (white → black, row 4) are the gray ramp the read
        // gate checks — identical reading order to the Tovis card.
        #expect(CameraCalibration.looksLikeGrayRamp(
            measuredSRGB: CardReferenceProfile.colorCheckerClassic.referenceSwatches))
    }

    // MARK: - ColorChecker geometry

    @Test func colorCheckerTargetGeometryIsSane() {
        let t = CalibrationTarget.colorCheckerClassic
        // One sample rect per reference swatch (the target init enforces this too).
        #expect(t.swatchSampleRects.count == t.profile.referenceSwatches.count)
        #expect(t.swatchSampleRects.count == 24)
        // Every rect sits inside the unit square with positive area.
        for r in t.swatchSampleRects {
            #expect(r.minX >= 0 && r.minY >= 0 && r.maxX <= 1 && r.maxY <= 1)
            #expect(r.width > 0 && r.height > 0)
        }
        // The WB rect is the neutral-8 patch (index 19) and is also in-bounds.
        #expect(t.wbSampleRect == t.swatchSampleRects[19])
        #expect(t.aspect > 1)   // ColorChecker is landscape (6 wide × 4 tall)
    }

    @Test func gridRectsAreRowMajorAndNonOverlapping() {
        let rects = CalibrationTarget.gridRects(
            cols: 6, rows: 4, borderX: 0.03, borderY: 0.03,
            gapX: 0.015, gapY: 0.02, inset: 0.30)
        #expect(rects.count == 24)
        // Reading order is left→right then top→bottom: x increases across a row,
        // y increases from row to row.
        #expect(rects[0].midX < rects[1].midX)              // col 0 left of col 1
        #expect(rects[0].midY < rects[6].midY)              // row 0 above row 1
        // Patches in a row don't overlap (inset keeps a gap between samples).
        for r in 0..<4 {
            for c in 0..<5 {
                let a = rects[r * 6 + c], b = rects[r * 6 + c + 1]
                #expect(a.maxX <= b.minX + 1e-9)
            }
        }
    }

    // MARK: - Tovis card target — no regression

    @Test func tovisCardTargetMatchesLegacyGeometry() {
        let t = CalibrationTarget.tovisCardV0
        #expect(t.swatchSampleRects == CardGeometry.swatchSampleRects())
        #expect(t.wbSampleRect == CardGeometry.wbSampleRect)
        #expect(t.wbNominalSRGB == CardGeometry.wbNominalSRGB)
        #expect(t.aspect == CardGeometry.aspect)
        #expect(t.profile == CardReferenceProfile.placeholderClassic)
    }

    @Test func allTargetsListsTovisCardFirst() {
        #expect(CalibrationTarget.all.first?.id == CalibrationTarget.tovisCardV0.id)
        #expect(CalibrationTarget.all.contains { $0.id == CalibrationTarget.colorCheckerClassic.id })
    }
}
